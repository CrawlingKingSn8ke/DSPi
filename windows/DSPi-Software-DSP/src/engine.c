#include "engine.h"
#include "../vendor/dspi/dsp_biquad.h"
#include "../vendor/dspi/dsp_svf.h"
#include "../vendor/dspi/dsp_pipeline.h"
#include "../vendor/dspi/dsp_cascade.h"
#include <math.h>
#include <string.h>
_Thread_local uint16_t peq_qp_x512[NUM_CHANNELS][MAX_BANDS];
bool dspi_channel_init(DspiChannel *c,float rate) {
    if(!c || !isfinite(rate) || rate<8000 || rate>192000) return false;
    memset(c,0,sizeof *c); c->sample_rate=rate;
    for(unsigned i=0;i<MAX_BANDS;i++) c->peq[i].bypass=true;
    for(unsigned i=0;i<MAX_XOVER_BANDS;i++) c->crossover[i].bypass=true;
    return true;
}
bool dspi_set_peq(DspiChannel *c,unsigned band,uint8_t type,float hz,
                  float q,float gain,float target_q,bool bypass) {
    if(!c || !isfinite(c->sample_rate) || c->sample_rate<8000 || c->sample_rate>192000 ||
       band>=MAX_BANDS || type>FILTER_HIGHPASS1 || !isfinite(hz) || hz<=0 ||
       hz>=c->sample_rate/2 || !isfinite(q) || q<=0 || !isfinite(gain) ||
       !isfinite(target_q) || target_q<0 || target_q>20) return false;
    if(type==FILTER_LINKWITZ_TRANSFORM) {
        if(gain<=0 || gain>=c->sample_rate/2 || (target_q>0 && target_q<0.1f))return false;
    } else if(gain< -30 || gain>30) return false;
    EqParamPacket p={0,0,type,bypass?1:0,hz,q,gain};
    /* Only the designer reads this slot. Per-thread storage avoids unrelated
     * channel builders racing; designed Filters own their resulting coefficients. */
    peq_qp_x512[0][0]=target_q>0?(uint16_t)lroundf(target_q*512):0;
    dsp_compute_coefficients(&p,&c->peq[band],c->sample_rate);
    return true;
}
bool dspi_set_crossover(DspiChannel *c,unsigned band,uint8_t type,float hz,bool bypass) {
    if(!c || !isfinite(c->sample_rate) || c->sample_rate<8000 || c->sample_rate>192000 ||
       band>=MAX_XOVER_BANDS || type<FILTER_XOVER_FIRST || type>FILTER_XOVER_LAST ||
       !isfinite(hz) || hz<=0 || hz>=c->sample_rate/2) return false;
    EqParamPacket p={0,(uint8_t)(XOVER_BAND_BASE+band),type,bypass?1:0,hz,0.707f,0};
    xover_design_filter(&p,&c->crossover[band],c->sample_rate);
    return true;
}
void dspi_channel_process(DspiChannel *c,float *samples,uint32_t count) {
    if(!c || !samples || !count) return;
    /* Firmware output stage order: crossover first, then per-output PEQ. */
    xover_process_channel_block(c->crossover,samples,count);
    dsp_cascade_block(c->peq,MAX_BANDS,samples,count);
}
bool dspi_peak(Filter *f, double rate, double hz, double q, double gain_db) {
    if (!f || !isfinite(rate) || !isfinite(hz) || !isfinite(q) ||
        !isfinite(gain_db) || rate<8000 || rate>192000 ||
        hz<=0 || hz>=rate/2 || q<0.1 || q>100 || gain_db< -30 || gain_db>30)
        return false;
    memset(f,0,sizeof *f);
    EqParamPacket p={0,0,FILTER_PEAKING,0,(float)hz,(float)q,(float)gain_db};
    dsp_compute_coefficients(&p,f,(float)rate);
    return true;
}
void dspi_process(Filter *f, float *samples, uint32_t count) {
    if (!f || !samples || !count || f->bypass) return;
    if(f->use_svf) {
        if(f->first_order) dsp_svf_first_order(f,samples,count);
        else dsp_svf_second_order(f,samples,count);
    } else {
        if(f->first_order) dsp_biquad_first_order(f,samples,count);
        else dsp_biquad_second_order(f,samples,count);
    }
}
void dsp_cascade_block(Filter *sections,uint32_t n,float *samples,uint32_t count) {
    for(uint32_t i=0;i<n;i++) dspi_process(&sections[i],samples,count);
}
