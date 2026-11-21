/* GPL-3.0. Physical input gain, firmware PEQ and host alignment delay. */
#include "graph.h"
#include <math.h>
#include <string.h>
bool dspi_graph_input_preamp(DspiGraph *g,unsigned i,float db){
    if(!g||i>=g->inputs||!isfinite(db)||db< -60||db>12)return false;
    g->input_gain[i]=powf(10,db/20);return true;
}
bool dspi_graph_input_delay(DspiGraph *g,unsigned i,float ms){
    if(!g||i>=g->inputs||!isfinite(ms)||ms<0||ms>DSPI_MAX_DELAY_MS)return false;
    uint32_t delay=(uint32_t)(g->rate*ms/1000);
    if(delay!=g->input_delay_samples[i]){
        memset(g->input_delay_line[i],0,g->capacity*sizeof(float));g->input_position[i]=0;g->input_delay_samples[i]=delay;
    }
    return true;
}
bool dspi_graph_input_eq(DspiGraph *g,unsigned i,unsigned band,uint8_t type,float hz,float q,float gain,float target_q,bool bypass){
    return g&&i<g->inputs&&dspi_set_peq(&g->input_channel[i],band,type,hz,q,gain,target_q,bypass);
}
bool dspi_graph_input_eq_clear(DspiGraph *g,unsigned i){return g&&i<g->inputs&&dspi_channel_init(&g->input_channel[i],g->rate);}
void dspi_graph_process_inputs(DspiGraph *g,const float *const *in,uint32_t offset,uint32_t n){
    for(unsigned i=0;i<g->inputs;i++){
        float *bus=g->sources[i];
        for(uint32_t f=0;f<n;f++)bus[f]=in[i][offset+f]*g->input_gain[i];
        for(unsigned b=0;b<MAX_BANDS;b++)dspi_process(&g->input_channel[i].peq[b],bus,n);
        uint32_t pos=g->input_position[i],delay=g->input_delay_samples[i];
        for(uint32_t f=0;f<n;f++){
            g->input_delay_line[i][pos]=bus[f];
            bus[f]=g->input_delay_line[i][(pos+g->capacity-delay)%g->capacity];
            if(++pos==g->capacity)pos=0;
        }
        g->input_position[i]=pos;
    }
}
