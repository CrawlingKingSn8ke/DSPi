#include "graph.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
DspiGraph *dspi_graph_create(float rate,unsigned inputs,unsigned outputs) {
    if(!isfinite(rate)||rate<8000||rate>192000||!inputs||inputs>DSPI_MAX_CHANNELS||!outputs||outputs>DSPI_MAX_CHANNELS)return NULL;
    DspiGraph *g=calloc(1,sizeof *g); if(!g)return NULL;
    g->rate=rate;g->inputs=inputs;g->outputs=outputs;
    g->volume_step=60;g->volume_gain=1;g->reference_spl=83;g->intensity=100;g->master_gain=1;
    g->tube=dspi_tube_defaults();
    g->crossfeed=(CrossfeedConfig){false,true,CROSSFEED_PRESET_DEFAULT,700,4.5f,0};
    g->limiter=dspi_limiter_create(rate,outputs);
    g->upmixer=dspi_upmix_create();
    if(!g->limiter||!g->upmixer){dspi_graph_destroy(g);return NULL;}
    g->upmix=dspi_upmix_defaults();
    g->psybass=(PsybassConfig){false,80,0,6,50,0,0};
    g->subharm=(SubharmConfig){.low_db=0,.high_db=0,.top_db=-30,.select_depth=100,.select_hold_ms=150,.link_pairs=true};
    g->leveller=(LevellerConfig){false,50,LEVELLER_SPEED_SLOW,15,true,-96,(uint8_t)((1u<<inputs)-1),(uint8_t)((1u<<inputs)-1)};
    leveller_reset_state(&g->leveller_state);
    g->capacity=(uint32_t)(rate*DSPI_MAX_DELAY_MS/1000)+1;
    for(unsigned i=0;i<inputs;i++){
        g->input_delay_line[i]=calloc(g->capacity,sizeof(float));
        if(!g->input_delay_line[i]){dspi_graph_destroy(g);return NULL;}
        dspi_channel_init(&g->input_channel[i],rate);g->input_gain[i]=1;
    }
    for(unsigned o=0;o<outputs;o++) {
        g->delay[o]=calloc(g->capacity,sizeof(float));
        if(!g->delay[o]){dspi_graph_destroy(g);return NULL;}
        dspi_channel_init(&g->channel[o],rate);g->gain[o]=1;
        if(o<inputs)g->route[o][o]=1;
    }
    return g;
}
void dspi_graph_destroy(DspiGraph *g){if(g){for(unsigned o=0;o<g->outputs;o++)free(g->delay[o]);for(unsigned i=0;i<g->inputs;i++)free(g->input_delay_line[i]);dspi_limiter_destroy(g->limiter);dspi_upmix_destroy(g->upmixer);free(g->padding_delay);free(g);}}
void dspi_graph_clear_routes(DspiGraph *g){if(g)memset(g->route,0,sizeof g->route);}
bool dspi_graph_route(DspiGraph *g,unsigned i,unsigned o,float db,bool invert,bool enabled){
    if(!g||i>=dspi_graph_sources(g)||o>=g->outputs||!isfinite(db)||db< -120||db>12)return false;
    g->route[i][o]=enabled?powf(10,db/20)*(invert?-1.0f:1.0f):0;
    return true;
}
bool dspi_graph_gain(DspiGraph *g,unsigned o,float db){
    if(!g||o>=g->outputs||!isfinite(db)||db< -120||db>12)return false;
    g->gain[o]=powf(10,db/20);return true;
}
bool dspi_graph_delay(DspiGraph *g,unsigned o,float ms){
    if(!g||o>=g->outputs||!isfinite(ms)||ms<0||ms>DSPI_MAX_DELAY_MS)return false;
    uint32_t samples=(uint32_t)(g->rate*ms/1000);
    if(samples!=g->delay_samples[o]){
        memset(g->delay[o],0,g->capacity*sizeof(float));g->position[o]=0;
        g->delay_samples[o]=samples;
    }
    return true;
}
bool dspi_graph_mute(DspiGraph *g,unsigned o,bool mute){
    if(!g||o>=g->outputs)return false;
    if(g->mute[o]!=mute){
        memset(g->delay[o],0,g->capacity*sizeof(float));
        loudness_reset_output_state(&g->loudness_state[o]);
        tube_reset_output_state(&g->tube_state[o]);
    }
    g->mute[o]=mute;return true;
}
bool dspi_graph_volume(DspiGraph *g,float db){
    if(!g||!isfinite(db)||db< -60||db>0)return false;
    unsigned step=(unsigned)(db+60); /* Same downward 1-dB quantization as firmware. */
    g->volume_step=step;
    g->volume_gain=step?powf(10,((float)step-60)/20):0;
    if(g->loudness_mask)dspi_loudness_design((int)step,g->reference_spl,g->intensity,g->rate,g->loudness);
    if(!step)for(unsigned o=0;o<g->outputs;o++){
        memset(g->delay[o],0,g->capacity*sizeof(float));
        loudness_reset_output_state(&g->loudness_state[o]);
    }
    return true;
}
bool dspi_graph_master_gain(DspiGraph *g,float db){
    if(!g||!isfinite(db)||db< -128||db>12)return false;
    g->master_gain=db<= -128?0:powf(10,db/20);return true;
}
bool dspi_graph_loudness(DspiGraph *g,float ref,float intensity,uint8_t mask){
    if(!g||!isfinite(ref)||ref<LOUDNESS_REF_SPL_MIN||ref>LOUDNESS_REF_SPL_MAX||
       !isfinite(intensity)||intensity<LOUDNESS_INTENSITY_MIN||intensity>LOUDNESS_INTENSITY_MAX||
       (mask&~((1u<<g->outputs)-1))||(mask&&g->rate<=12000))return false;
    if(mask)dspi_loudness_design((int)g->volume_step,ref,intensity,g->rate,g->loudness);
    for(unsigned o=0;o<g->outputs;o++)if(((g->loudness_mask^mask)>>o)&1u)
        loudness_reset_output_state(&g->loudness_state[o]);
    g->reference_spl=ref;g->intensity=intensity;g->loudness_mask=mask;
    return true;
}
void dspi_graph_loudness_endpoint_volume(DspiGraph *g,int db){
    if(!g->loudness_mask)return;
    /* The endpoint gain is already applied by Windows. Only change the shelves. */
    int step=(int)g->volume_step+db;
    if(step<0)step=0;
    if(step>60)step=60;
    dspi_loudness_design(step,g->reference_spl,g->intensity,g->rate,g->loudness);
}
static bool within(float v,float lo,float hi){return isfinite(v)&&v>=lo&&v<=hi;}
bool dspi_graph_tube(DspiGraph *g,const TubeConfig *c){
    if(!g||!c||c->tube_type>TUBE_TYPE_MAX||c->rectifier>TUBE_RECT_MAX||
       (c->output_mask&~((1u<<g->outputs)-1))||
       !within(c->drive_db,TUBE_DRIVE_MIN,TUBE_DRIVE_MAX)||
       !within(c->bias_pct,TUBE_BIAS_MIN,TUBE_BIAS_MAX)||
       !within(c->asym_db,TUBE_ASYM_MIN,TUBE_ASYM_MAX)||
       !within(c->hardness_pct,TUBE_HARDNESS_MIN,TUBE_HARDNESS_MAX)||
       !within(c->sag_pct,TUBE_SAG_MIN,TUBE_SAG_MAX)||
       !within(c->xfmr_damping,TUBE_XFMR_DAMPING_MIN,TUBE_XFMR_DAMPING_MAX)||
       !within(c->xfmr_res_hz,TUBE_XFMR_RES_MIN,TUBE_XFMR_RES_MAX)||
       !within(c->mix_pct,TUBE_MIX_MIN,TUBE_MIX_MAX)||
       !within(c->trim_db,TUBE_TRIM_MIN,TUBE_TRIM_MAX))return false;
    TubeCoeffs next={0};tube_compute_coefficients(&next,c,g->rate);
    unsigned old_mask=g->tube.enabled?g->tube.output_mask:0;
    unsigned new_mask=c->enabled?c->output_mask:0;
    for(unsigned o=0;o<g->outputs;o++)if(((old_mask^new_mask)>>o)&1u)
        tube_reset_output_state(&g->tube_state[o]);
    g->tube=*c;g->tube_coeffs=next;return true;
}
bool dspi_graph_crossfeed(DspiGraph *g,const CrossfeedConfig *c){
    if(!g||!c||c->preset>CROSSFEED_PRESET_CUSTOM||
       !within(c->custom_fc,CROSSFEED_FREQ_MIN,CROSSFEED_FREQ_MAX)||
       !within(c->custom_feed_db,CROSSFEED_FEED_MIN,CROSSFEED_FEED_MAX))return false;
    unsigned allowed=(1u<<(g->outputs/2))-1;
    if((c->output_pair_mask&~allowed)||(c->enabled&&!c->output_pair_mask))return false;
    CrossfeedCoeffs next={0};crossfeed_compute_coefficients(&next,c,g->rate);
    unsigned old_mask=g->crossfeed.enabled?g->crossfeed.output_pair_mask:0;
    unsigned new_mask=c->enabled?c->output_pair_mask:0;
    bool changed=next.lp_a0!=g->crossfeed_coeffs.lp_a0||next.lp_b1!=g->crossfeed_coeffs.lp_b1||next.ap_a!=g->crossfeed_coeffs.ap_a;
    for(unsigned p=0;p<DSPI_MAX_CHANNELS/2;p++)if(changed||(((old_mask^new_mask)>>p)&1u))
        crossfeed_reset_pair_state(&g->crossfeed_state[p]);
    g->crossfeed=*c;g->crossfeed_coeffs=next;return true;
}
bool dspi_graph_limiter(DspiGraph *g,unsigned output,const LimiterOutputConfig *config){return g&&dspi_limiter_set(g->limiter,output,config);}
bool dspi_graph_process(DspiGraph *g,const float *const *in,float *const *out,uint32_t count){
    if(!g)return false;if(!count)return true;
    if(!in||!out)return false;
    for(unsigned i=0;i<g->inputs;i++)if(!in[i])return false;
    for(unsigned o=0;o<g->outputs;o++)if(!out[o])return false;
    for(uint32_t offset=0;offset<count;){
        uint32_t n=count-offset;if(n>DSPI_BLOCK_FRAMES)n=DSPI_BLOCK_FRAMES;
        dspi_graph_prepare_inputs(g,in,offset,n);
        /* Output-major matrix, input accumulation order matches firmware. */
        for(unsigned o=0;o<g->outputs;o++){
            float *work=g->work[o];memset(work,0,n*sizeof(float));
            for(unsigned i=0;i<dspi_graph_sources(g);i++){
                float gain=g->route[i][o];if(gain==0)continue;
                for(uint32_t f=0;f<n;f++)work[f]+=g->sources[i][f]*gain;
            }
        }
        /* Crossfeed needs both matrix outputs before either one enters effects. */
        for(unsigned p=0;p<g->outputs/2;p++){
            if(g->crossfeed.enabled&&((g->crossfeed.output_pair_mask>>p)&1u))
                crossfeed_process_pair_block(&g->crossfeed_coeffs,&g->crossfeed_state[p],g->work[2*p],g->work[2*p+1],n);
            else crossfeed_reset_pair_state(&g->crossfeed_state[p]);
        }
        dspi_graph_subharm_process(g,n);
        for(unsigned o=0;o<g->outputs;o++){
            float *work=g->work[o];
            if(g->psybass.enabled&&((g->psybass.output_mask>>o)&1u)&&!g->mute[o])
                psybass_process_output_block(&g->psybass_coeffs,&g->psybass_state[o],work,n);
            else psybass_reset_output_state(&g->psybass_state[o]);
            /* Firmware tube placement: post-matrix, before crossover and PEQ. */
            if(g->tube.enabled&&((g->tube.output_mask>>o)&1u)&&!g->mute[o])
                tube_process_output_block(&g->tube_coeffs,&g->tube_state[o],work,n);
            else tube_reset_output_state(&g->tube_state[o]);
            dspi_channel_process(&g->channel[o],work,n);
            float output_gain=g->gain[o]*g->volume_gain*g->master_gain;
            for(uint32_t f=0;f<n;f++)work[f]=g->mute[o]?0:work[f]*output_gain;
            if(((g->loudness_mask>>o)&1u)&&!g->mute[o]&&output_gain!=0)
                loudness_process_output_block(g->loudness,&g->loudness_state[o],work,n);
            else loudness_reset_output_state(&g->loudness_state[o]);
        }
        /* Peak limiting is after every gain stage and before alignment delay. */
        if(!dspi_limiter_process(g->limiter,g->work,n))return false;
        for(unsigned o=0;o<g->outputs;o++){
            float *work=g->work[o];
            uint32_t pos=g->position[o],delay=g->delay_samples[o];
            for(uint32_t f=0;f<n;f++){
                g->delay[o][pos]=work[f];
                uint32_t read=(pos+g->capacity-delay)%g->capacity;
                out[o][offset+f]=(g->mute[o]||g->volume_gain==0||g->master_gain==0)?0:g->delay[o][read];
                if(++pos==g->capacity)pos=0;
            }
            g->position[o]=pos;
        }
        offset+=n;
    }
    return true;
}
