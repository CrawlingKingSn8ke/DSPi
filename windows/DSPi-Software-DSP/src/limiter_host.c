#include "limiter_host.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
typedef float lm_gain_t;
#define LM_UNITY 1.0f
#define LM_G_UNITY 1.0f
#include "../build/limiter_kernel.inc"
#define HOST_LIMITER_OUTPUTS 8
struct DspiLimiter {
    unsigned outputs,pos;
    float rate;
    uint16_t enabled;
    LimiterOutputConfig config[HOST_LIMITER_OUTPUTS];
    LimiterOutputState state[HOST_LIMITER_OUTPUTS];
    float threshold[HOST_LIMITER_OUTPUTS],release[HOST_LIMITER_OUTPUTS];
    float envelope[HOST_LIMITER_OUTPUTS][LIMITER_MAX_BOUNDS];
};
DspiLimiter *dspi_limiter_create(float rate,unsigned outputs){
    if(!isfinite(rate)||rate<8000||rate>192000||!outputs||outputs>HOST_LIMITER_OUTPUTS)return NULL;
    DspiLimiter *lm=calloc(1,sizeof *lm);if(!lm)return NULL;lm->rate=rate;lm->outputs=outputs;
    for(unsigned o=0;o<outputs;o++){
        lm->config[o]=(LimiterOutputConfig){false,0,LIMITER_DEFAULT_THRESHOLD,LIMITER_DEFAULT_RELEASE};
        lm_clear_output(&lm->state[o]);
    }
    return lm;
}
void dspi_limiter_destroy(DspiLimiter *lm){free(lm);}
/* Stream discontinuity; preserve settings and release coefficients. */
void dspi_limiter_reset_state(DspiLimiter *lm){
    if(!lm)return;lm->pos=0;memset(lm->envelope,0,sizeof lm->envelope);
    for(unsigned o=0;o<lm->outputs;o++){lm_clear_output(&lm->state[o]);lm->state[o].rel=lm->release[o];}
}
bool dspi_limiter_get(const DspiLimiter *lm,unsigned o,LimiterOutputConfig *c){if(!lm||!c||o>=lm->outputs)return false;*c=lm->config[o];return true;}
bool dspi_limiter_set(DspiLimiter *lm,unsigned o,const LimiterOutputConfig *c){
    if(!lm||!c||o>=lm->outputs||c->link_group>LIMITER_LINK_GROUP_MAX||
       !isfinite(c->threshold_db)||c->threshold_db<LIMITER_THRESHOLD_MIN||c->threshold_db>LIMITER_THRESHOLD_MAX||
       !isfinite(c->release_ms)||c->release_ms<LIMITER_RELEASE_MIN||c->release_ms>LIMITER_RELEASE_MAX)return false;
    LimiterOutputConfig next[HOST_LIMITER_OUTPUTS];memcpy(next,lm->config,sizeof next);
    LimiterOutputConfig requested=*c;
    if(requested.link_group&&requested.link_group!=lm->config[o].link_group){
        for(unsigned m=0;m<lm->outputs;m++)if(m!=o&&next[m].link_group==requested.link_group){
            requested.enabled=next[m].enabled;requested.threshold_db=next[m].threshold_db;requested.release_ms=next[m].release_ms;break;
        }
    }
    next[o]=requested;
    if(requested.link_group)for(unsigned m=0;m<lm->outputs;m++)if(next[m].link_group==requested.link_group){
        next[m].enabled=requested.enabled;next[m].threshold_db=requested.threshold_db;next[m].release_ms=requested.release_ms;
    }
    memcpy(lm->config,next,sizeof next);lm->enabled=0;lm->pos=0;
    for(unsigned m=0;m<lm->outputs;m++){
        lm->threshold[m]=powf(10,lm->config[m].threshold_db/20);
        lm->release[m]=expf((float)LIMITER_BLOCK/(lm->config[m].release_ms*1e-3f*lm->rate));
        if(lm->config[m].enabled)lm->enabled|=(uint16_t)(1u<<m);
        lm_clear_output(&lm->state[m]);lm->state[m].rel=lm->release[m];
    }
    return true;
}
unsigned dspi_limiter_latency(const DspiLimiter *lm){return lm&&lm->enabled?LIMITER_DELAY:0;}
float dspi_limiter_reduction_db(const DspiLimiter *lm,unsigned o){
    if(!lm||o>=lm->outputs||!lm->config[o].enabled)return 0;
    return -20*log10f(fmaxf(lm->state[o].meter,1e-6f));
}
bool dspi_limiter_process(DspiLimiter *lm,float (*buffers)[AUDIO_BUFFER_SAMPLES],uint32_t count){
    if(!lm)return false;if(!count)return true;
    if(!buffers||count>AUDIO_BUFFER_SAMPLES)return false;
    if(!lm->enabled)return true;
    unsigned phase=lm->pos&(LIMITER_BLOCK-1),nb=(phase+count)/LIMITER_BLOCK;
    /* All detectors complete before group minima are used by any output. */
    for(unsigned o=0;o<lm->outputs;o++)if((lm->enabled>>o)&1u)
        lm_detect(&lm->state[o],buffers[o],count,phase,lm->threshold[o],lm->release[o],lm->envelope[o]);
    for(unsigned o=0;o<lm->outputs;o++){
        if(!((lm->enabled>>o)&1u)){lm_ring_only(&lm->state[o],buffers[o],count,lm->pos);continue;}
        float linked[LIMITER_MAX_BOUNDS];const float *gains=lm->envelope[o];
        unsigned group=lm->config[o].link_group;
        if(group){
            for(unsigned b=0;b<nb;b++)linked[b]=gains[b];
            for(unsigned m=0;m<lm->outputs;m++)if(((lm->enabled>>m)&1u)&&lm->config[m].link_group==group)
                for(unsigned b=0;b<nb;b++)linked[b]=fminf(linked[b],lm->envelope[m][b]);
            gains=linked;
        }
        lm_apply(&lm->state[o],buffers[o],count,lm->pos,gains);
    }
    lm->pos=(lm->pos+count)&(LIMITER_DELAY-1);return true;
}
