/* GPL-3.0. Single producer control handoff, single audio consumer. */
#include "host_api.h"
#include "recipe.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
enum Transition { STEADY, FADE_OUT, FADE_IN, WARMING, CROSSFADE };
typedef struct {
    float rate;unsigned inputs,outputs,ramp,remaining;
    enum Transition phase,next_phase;
    DspiGraph *active,*candidate;
    _Atomic(DspiGraph *) pending,retired;
    atomic_flag processing;
    _Atomic int reset;
    _Atomic(uint64_t) active_revision;
    _Atomic(uint32_t) input_peak[8],output_peak[8],clips;
    float in[8][DSPI_BLOCK_FRAMES],out[8][DSPI_BLOCK_FRAMES],warm[8][DSPI_BLOCK_FRAMES];
} DspiRuntime;
void *dspi_host_prepare(float rate,unsigned inputs,unsigned outputs,const char *tokens){
    if(!tokens)return NULL;size_t len=0;while(len<=262144&&tokens[len])len++;if(len>262144)return NULL;
    DspiGraph *g=dspi_graph_create(rate,inputs,outputs);if(!g)return NULL;
    if(!len)return g;
    char *copy=malloc(len+1);char **argv=calloc(4099,sizeof(char *));
    if(!copy||!argv){free(copy);free(argv);dspi_graph_destroy(g);return NULL;}
    memcpy(copy,tokens,len+1);argv[0]=argv[1]=argv[2]="host";unsigned argc=3;char *start=copy;
    bool valid=true;
    for(size_t i=0;i<=len;i++)if(copy[i]=='\n'||copy[i]==0){
        char end=copy[i];copy[i]=0;
        if(!*start||argc>=4099){valid=false;break;}argv[argc++]=start;start=copy+i+1;if(!end)break;
    }
    if(valid)valid=dspi_recipe_configure((int)argc,argv,g);
    free(copy);free(argv);if(!valid){dspi_graph_destroy(g);return NULL;}return g;
}
void dspi_host_graph_revision(void *graph,uint64_t revision){if(graph)((DspiGraph*)graph)->revision=revision;}
uint64_t dspi_host_active_revision(void *runtime){return runtime?atomic_load(&((DspiRuntime*)runtime)->active_revision):0;}
void dspi_host_reset(void *runtime){if(runtime)atomic_store(&((DspiRuntime*)runtime)->reset,1);}
void dspi_host_graph_destroy(void *graph){dspi_graph_destroy(graph);}
void *dspi_host_create(void *graph,unsigned ramp_samples){
    DspiGraph *g=graph;if(!g||!ramp_samples||ramp_samples>g->rate)return NULL;
    DspiRuntime *r=calloc(1,sizeof *r);if(!r)return NULL;
    r->rate=g->rate;r->inputs=g->inputs;r->outputs=g->outputs;r->active=g;r->ramp=ramp_samples;
    atomic_init(&r->reset,0);atomic_init(&r->active_revision,g->revision);
    atomic_init(&r->pending,NULL);atomic_init(&r->retired,NULL);atomic_flag_clear(&r->processing);
    atomic_init(&r->clips,0);for(unsigned i=0;i<8;i++){atomic_init(&r->input_peak[i],0);atomic_init(&r->output_peak[i],0);}return r;
}
void dspi_host_collect(void *runtime){DspiRuntime *r=runtime;if(r)dspi_graph_destroy(atomic_exchange(&r->retired,NULL));}
int dspi_host_submit(void *runtime,void *graph){
    DspiRuntime *r=runtime;DspiGraph *g=graph;if(!r||!g||g->rate!=r->rate||g->inputs!=r->inputs||g->outputs!=r->outputs)return 0;
    dspi_host_collect(r);DspiGraph *replaced=atomic_exchange(&r->pending,g);dspi_graph_destroy(replaced);return 1;
}
static void peak(_Atomic(uint32_t) *slot,float v){
    uint32_t bits;memcpy(&bits,&v,sizeof bits);uint32_t old=atomic_load(slot);
    while(bits>old&&!atomic_compare_exchange_weak(slot,&old,bits)){}
}
static bool ranges_overlap(const float *a,unsigned ac,float *b,unsigned bc,uint32_t n){
    uintptr_t ap=(uintptr_t)a,bp=(uintptr_t)b;uint64_t as=(uint64_t)n*ac*sizeof(float),bs=(uint64_t)n*bc*sizeof(float);
    if(as>UINTPTR_MAX-ap||bs>UINTPTR_MAX-bp)return true;
    return ap<bp+bs&&bp<ap+as;
}
static unsigned effect_latency(const DspiGraph *g){
    return dspi_graph_input_latency(g)+dspi_limiter_latency(g->limiter);
}
unsigned dspi_host_graph_latency(const void *graph){
    const DspiGraph *g=graph;
    return effect_latency(g)+g->padding_frames;
}
void *dspi_host_prepare_fixed_latency(float rate,unsigned inputs,unsigned outputs,const char *tokens){
    DspiGraph *g=dspi_host_prepare(rate,inputs,outputs,tokens);
    if(!g)return NULL;
    unsigned frames=(unsigned)ceil((double)rate*7.0/1000.0);
    unsigned max_lookahead=(unsigned)(sizeof g->control_in[0]/sizeof g->control_in[0][0])
        + LEVELLER_LOOKAHEAD_SAMPLES + LIMITER_DELAY;
    if(frames<max_lookahead)frames=max_lookahead;

    unsigned intrinsic=effect_latency(g);
    if(intrinsic>frames){dspi_graph_destroy(g);return NULL;}
    g->padding_frames=frames-intrinsic;
    if(g->padding_frames){
        g->padding_delay=calloc((size_t)outputs*g->padding_frames,sizeof(float));
        if(!g->padding_delay){dspi_graph_destroy(g);return NULL;}
    }
    return g;
}
static void apply_padding(DspiGraph *g,float *const *output,uint32_t frames){
    if(!g->padding_frames)return;
    unsigned position=g->padding_position;
    for(uint32_t f=0;f<frames;f++){
        for(unsigned o=0;o<g->outputs;o++){
            float *slot=&g->padding_delay[(size_t)o*g->padding_frames+position];
            float delayed=*slot;
            *slot=output[o][f];
            output[o][f]=delayed;
        }
        if(++position==g->padding_frames)position=0;
    }
    g->padding_position=position;
}
static unsigned warm_frames(const DspiGraph *g){
    unsigned input=0,output=0;
    for(unsigned i=0;i<g->inputs;i++)if(g->input_delay_samples[i]>input)input=g->input_delay_samples[i];
    for(unsigned o=0;o<g->outputs;o++)if(g->delay_samples[o]>output)output=g->delay_samples[o];
    unsigned n=input+output+dspi_host_graph_latency(g);
    /* Conservative bound for the surround's Haas and allpass delay path.
     * Their IIR tails continue normally; no full-amplitude empty-ring start. */
    if(g->upmix.enabled&&g->upmix.surround_mode!=UPMIX_SURROUND_OFF)
        n+=(unsigned)ceilf(g->rate*(g->upmix.surround_delay_ms+UPMIX_DECORR_DELAY_MS)/1000);
    return n;
}
int dspi_host_process(void *runtime,const float *input,float *output,uint32_t frames){
    DspiRuntime *r=runtime;if(!r)return 0;if(!frames)return 1;
    if(!input||!output||ranges_overlap(input,r->inputs,output,r->outputs,frames))return 0;
    for(uint64_t i=0;i<(uint64_t)frames*r->inputs;i++)if(!isfinite(input[i]))return 0;
    if(atomic_flag_test_and_set(&r->processing))return 0;
    if(atomic_exchange(&r->reset,0)){dspi_graph_reset(r->active);if(r->candidate)dspi_graph_reset(r->candidate);}
    bool ok=true;uint32_t pos=0;
    while(pos<frames){
        if(!r->phase&&!atomic_load(&r->retired)){
            r->candidate=atomic_exchange(&r->pending,NULL);
            if(r->candidate){
                unsigned warm=warm_frames(r->candidate);
                r->next_phase=dspi_host_graph_latency(r->active)==dspi_host_graph_latency(r->candidate)?CROSSFADE:FADE_OUT;
                if(r->next_phase==CROSSFADE&&warm<r->ramp)warm=r->ramp;
                r->phase=warm?WARMING:r->next_phase;
                r->remaining=warm?warm:r->ramp;
            }
        }
        uint32_t n=frames-pos;if(n>DSPI_BLOCK_FRAMES)n=DSPI_BLOCK_FRAMES;if(r->phase&&n>r->remaining)n=r->remaining;
        const float *ip[8];float *op[8],*wp[8];
        for(unsigned i=0;i<r->inputs;i++){
            ip[i]=r->in[i];float pk=0;for(uint32_t f=0;f<n;f++){float v=input[((uint64_t)pos+f)*r->inputs+i];r->in[i][f]=v;pk=fmaxf(pk,fabsf(v));}
            peak(&r->input_peak[i],pk);if(pk>1)atomic_fetch_or(&r->clips,1u<<i);
        }
        for(unsigned o=0;o<r->outputs;o++){op[o]=r->out[o];wp[o]=r->warm[o];}
        if(!dspi_graph_process(r->active,ip,op,n)||(r->candidate&&!dspi_graph_process(r->candidate,ip,wp,n))){ok=false;break;}
        /* A graph owns its delay line, so both sides of a transition stay aligned. */
        apply_padding(r->active,op,n);
        if(r->candidate)apply_padding(r->candidate,wp,n);
        for(uint32_t f=0;f<n;f++){
            float active_gain=1,new_gain=0;
            if(r->phase==FADE_OUT)active_gain=(float)(r->remaining-f-1)/r->ramp;
            else if(r->phase==FADE_IN||r->phase==CROSSFADE){
                float progress=(float)(r->ramp-r->remaining+f+1)/r->ramp;
                if(r->phase==FADE_IN)active_gain=progress;
                else{active_gain=1-progress;new_gain=progress;}
            }
            for(unsigned o=0;o<r->outputs;o++){
                float v=r->out[o][f]*active_gain;
                if(new_gain)v+=r->warm[o][f]*new_gain;
                if(!isfinite(v)){ok=false;v=0;}
                output[((uint64_t)pos+f)*r->outputs+o]=v;peak(&r->output_peak[o],fabsf(v));if(fabsf(v)>1)atomic_fetch_or(&r->clips,1u<<(8+o));
            }
        }
        pos+=n;
        if(r->phase){
            r->remaining-=n;
            if(!r->remaining){
                if(r->phase==WARMING){r->phase=r->next_phase;r->remaining=r->ramp;}
                else if(r->phase==FADE_OUT||r->phase==CROSSFADE){
                    DspiGraph *old=r->active;
                    r->active=r->candidate;
                    atomic_store(&r->active_revision,r->active->revision);
                    r->candidate=NULL;
                    r->phase=r->phase==FADE_OUT?FADE_IN:STEADY;
                    r->remaining=r->phase==FADE_IN?r->ramp:0;
                    atomic_store(&r->retired,old);
                }
                else r->phase=STEADY;
            }
        }
    }
    atomic_flag_clear(&r->processing);return ok?1:0;
}
void dspi_host_meters(void *runtime,float *inputs,float *outputs,uint32_t *clips){
    DspiRuntime *r=runtime;if(!r||!inputs||!outputs||!clips)return;
    for(unsigned i=0;i<8;i++){uint32_t b=atomic_exchange(&r->input_peak[i],0);memcpy(&inputs[i],&b,sizeof b);b=atomic_exchange(&r->output_peak[i],0);memcpy(&outputs[i],&b,sizeof b);}
    *clips=atomic_exchange(&r->clips,0);
}
void dspi_host_destroy(void *runtime){
    DspiRuntime *r=runtime;if(!r)return;dspi_graph_destroy(r->active);dspi_graph_destroy(r->candidate);
    dspi_graph_destroy(atomic_load(&r->pending));dspi_graph_destroy(atomic_load(&r->retired));free(r);
}
