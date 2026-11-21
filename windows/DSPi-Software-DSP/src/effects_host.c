/* GPL-3.0. Host settings/lifetime around unchanged firmware effect math. */
#include "graph.h"
#include <math.h>
#include <string.h>
static bool range(float v,float lo,float hi){return isfinite(v)&&v>=lo&&v<=hi;}
bool dspi_graph_psybass(DspiGraph *g,const PsybassConfig *c){
    if(!g||!c||(c->output_mask&~((1u<<g->outputs)-1))||
       !range(c->cutoff_hz,30,300)||!range(c->harmonics_db,-24,12)||!range(c->drive_db,0,18)||
       !range(c->character_pct,0,100)||!range(c->original_db,-60,0))return false;
    g->psybass=*c;psybass_compute_coefficients(&g->psybass_coeffs,c,g->rate);
    memset(g->psybass_state,0,sizeof g->psybass_state);return true;
}
bool dspi_graph_subharm(DspiGraph *g,const SubharmConfig *c){
    if(!g||!c||(c->output_mask&~((1u<<g->outputs)-1))||!range(c->low_db,-30,12)||
       !range(c->high_db,-30,12)||!range(c->top_db,-30,12)||!range(c->boost_db,0,6)||
       c->select_mode>2||!range(c->select_depth,0,100)||!range(c->select_hold_ms,50,400)||!range(c->ceiling_db,-40,0))return false;
    g->subharm=*c;subharm_compute_coefficients(&g->subharm_coeffs,c,g->rate);g->subharm_phase=0;
    for(unsigned o=0;o<8;o++)subharm_reset_output_state(&g->subharm_state[o]);return true;
}
static void reset_inputs(DspiGraph *g){
    g->control_pos=0;memset(g->control_in,0,sizeof g->control_in);memset(g->control_out,0,sizeof g->control_out);
    leveller_reset_state(&g->leveller_state);dspi_upmix_configure(g->upmixer,&g->upmix,g->rate);
}
bool dspi_graph_leveller(DspiGraph *g,const LevellerConfig *c){
    if(!g||!c||!range(c->amount,0,100)||c->speed>=LEVELLER_SPEED_COUNT||!range(c->max_gain_db,0,35)||
       !range(c->gate_threshold_db,-96,0)||((c->detector_mask|c->apply_mask)&~((1u<<g->inputs)-1)))return false;
    g->leveller=*c;leveller_compute_coefficients(&g->leveller_coeffs,c,g->rate);reset_inputs(g);return true;
}
bool dspi_graph_upmix(DspiGraph *g,const UpmixConfig *c){
    if(!g||!c||c->center_mode>2||c->surround_mode>2||(c->enabled&&(g->inputs!=2||g->rate>48000))||
       !range(c->strength_pct,0,100)||!range(c->center_width_pct,0,100)||!range(c->corr_threshold_pct,0,95)||
       !range(c->attack_ms,1,500)||!range(c->release_ms,5,2000)||!range(c->detector_hpf_hz,20,1000)||
       !range(c->surround_delay_ms,0,20)||!range(c->surround_hpf_hz,20,2000)||
       !range(c->surround_lpf_hz,1000,20000)||!range(c->decorr_pct,0,100)||!range(c->presence_db,-12,12))return false;
    g->upmix=*c;reset_inputs(g);return true;
}
unsigned dspi_graph_sources(const DspiGraph *g){return g?(g->upmix.enabled?5:g->inputs):0;}
unsigned dspi_graph_input_latency(const DspiGraph *g){return g?((g->upmix.enabled||g->leveller.enabled)?48:0)+(g->leveller.enabled&&g->leveller.lookahead?240:0):0;}
void dspi_graph_prepare_inputs(DspiGraph *g,const float *const *in,uint32_t offset,uint32_t n){
    unsigned sources=dspi_graph_sources(g);
    dspi_graph_process_inputs(g,in,offset,n);
    if(!g->upmix.enabled&&!g->leveller.enabled)return;
    for(uint32_t f=0;f<n;f++){
        unsigned pos=g->control_pos;
        for(unsigned i=0;i<g->inputs;i++)g->control_in[i][pos]=g->sources[i][f];
        for(unsigned i=0;i<sources;i++)g->sources[i][f]=g->control_out[i][pos];
        if(++g->control_pos==48){
            float *p[8];for(unsigned i=0;i<g->inputs;i++)p[i]=g->control_in[i];
            if(g->leveller.enabled)leveller_process_block(&g->leveller_state,&g->leveller_coeffs,&g->leveller,p,g->inputs,48);
            if(g->upmix.enabled)dspi_upmix_process(g->upmixer,g->control_in);
            for(unsigned i=0;i<sources;i++)memcpy(g->control_out[i],g->control_in[i],48*sizeof(float));
            g->control_pos=0;
        }
    }
}
static bool eligible(DspiGraph *g,unsigned o){return g->subharm.enabled&&((g->subharm.output_mask>>o)&1)&&!g->mute[o];}
static void seed(DspiGraph *g,unsigned o){
    if((o^1)>=g->outputs)return;
    SubharmOutputState *s=&g->subharm_state[o],*p=&g->subharm_state[o^1];
    if(!s->active&&p->active){SubharmSvfState bell=s->bell;*s=*p;s->bell=bell;}
}
void dspi_graph_subharm_process(DspiGraph *g,uint32_t n){
    /* Seed from the partner's state at the same time instant, before processing
     * either channel. This also keeps independent dividers callback-invariant. */
    for(unsigned o=0;o<g->outputs;o++)if(eligible(g,o))seed(g,o);
    for(unsigned o=0;o<g->outputs;o++){
        if(!eligible(g,o)){subharm_reset_output_state(&g->subharm_state[o]);continue;}
        if(g->subharm.link_pairs&&!(o&1)&&o+1<g->outputs&&eligible(g,o+1)){
            subharm_process_block(&g->subharm_coeffs,&g->subharm_state[o],&g->subharm_state[o+1],g->work[o],g->work[o+1],n,g->subharm_phase,g->subharm.solo);o++;
        }else subharm_process_block(&g->subharm_coeffs,&g->subharm_state[o],NULL,g->work[o],NULL,n,g->subharm_phase,g->subharm.solo);
    }
    if(g->subharm.enabled)g->subharm_phase=(g->subharm_phase+n)%g->subharm_coeffs.decim;
}
