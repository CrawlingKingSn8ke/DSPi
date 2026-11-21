/* GPL-3.0. Allocation-free reset preserving all configured coefficients. */
#include "graph.h"
#include <string.h>
void dspi_limiter_reset_state(DspiLimiter*);
void dspi_upmix_reset_state(DspiUpmixer*);
static void filter_reset(Filter *f){f->s1=f->s2=f->svic1eq=f->svic2eq=0;}
static void channel_reset(DspiChannel *c){
    for(unsigned b=0;b<MAX_BANDS;b++)filter_reset(&c->peq[b]);
    for(unsigned b=0;b<MAX_XOVER_BANDS;b++)for(unsigned s=0;s<MAX_XOVER_BAND_SECTIONS;s++)filter_reset(&c->crossover[b].sections[s]);
}
void dspi_graph_reset(DspiGraph *g){
    for(unsigned i=0;i<g->inputs;i++){
        channel_reset(&g->input_channel[i]);g->input_position[i]=0;
        memset(g->input_delay_line[i],0,g->capacity*sizeof(float));
    }
    for(unsigned o=0;o<g->outputs;o++){
        channel_reset(&g->channel[o]);g->position[o]=0;memset(g->delay[o],0,g->capacity*sizeof(float));
        loudness_reset_output_state(&g->loudness_state[o]);tube_reset_output_state(&g->tube_state[o]);
        psybass_reset_output_state(&g->psybass_state[o]);subharm_reset_output_state(&g->subharm_state[o]);
    }
    for(unsigned p=0;p<DSPI_MAX_CHANNELS/2;p++)crossfeed_reset_pair_state(&g->crossfeed_state[p]);
    leveller_reset_state(&g->leveller_state);dspi_limiter_reset_state(g->limiter);dspi_upmix_reset_state(g->upmixer);
    g->subharm_phase=0;g->control_pos=0;
    memset(g->control_in,0,sizeof g->control_in);memset(g->control_out,0,sizeof g->control_out);
    g->padding_position=0;
    if(g->padding_delay)memset(g->padding_delay,0,(size_t)g->outputs*g->padding_frames*sizeof(float));
    memset(g->sources,0,sizeof g->sources);memset(g->work,0,sizeof g->work);
}
