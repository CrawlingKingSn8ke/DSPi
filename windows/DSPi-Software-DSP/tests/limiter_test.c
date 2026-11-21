#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e)do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float left[48000],right[48000],a[48000],b[48000],ref_a[48000],ref_b[48000];
static void run(DspiGraph *g){const float *ip[]={left,right};float *op[]={a,b};CHECK(dspi_graph_process(g,ip,op,48000));}
int main(void){
    LimiterOutputConfig cfg={true,0,-6,100};
    /* All outputs share the exact 32-sample lookahead, even unprotected ones. */
    DspiGraph *g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;
    left[0]=right[0]=.1f;CHECK(dspi_graph_limiter(g,0,&cfg));CHECK(dspi_limiter_latency(g->limiter)==32);run(g);
    bool impulse=true;for(unsigned i=0;i<48000;i++)if(a[i]!=(i==32?.1f:0)||b[i]!=(i==32?.1f:0))impulse=false;CHECK(impulse);dspi_graph_destroy(g);
    /* Alternating peaks and block-edge impulses must never pass the ceiling. */
    for(unsigned i=0;i<48000;i++){left[i]=(i%37==0?4.0f:(float)(.8*sin(i*.17)));right[i]=left[i]*.25f;}
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;cfg.link_group=1;
    CHECK(dspi_graph_limiter(g,0,&cfg));CHECK(dspi_graph_limiter(g,1,&cfg));run(g);
    double peak=0,error=0;for(unsigned i=0;i<48000;i++){if(fabs(a[i])>peak)peak=fabs(a[i]);double e=fabs(b[i]-.25*a[i]);if(e>error)error=e;}
    printf("Limiter peak %.8f at -6 dBFS ceiling %.8f\n",peak,pow(10,-6.0/20));
    CHECK(peak<=pow(10,-6.0/20)*1.000003);CHECK(error<0.000001);
    memcpy(ref_a,a,sizeof a);memcpy(ref_b,b,sizeof b);dspi_graph_destroy(g);
    /* Arbitrary callback boundaries preserve peak history, ring and ramps. */
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_limiter(g,0,&cfg));CHECK(dspi_graph_limiter(g,1,&cfg));
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;const float *ip[]={left+i,right+i};float *op[]={a+i,b+i};CHECK(dspi_graph_process(g,ip,op,n));i+=n;}
    CHECK(memcmp(a,ref_a,sizeof a)==0&&memcmp(b,ref_b,sizeof b)==0);
    /* Joining a group adopts its settings; edits to a member reach the group. */
    LimiterOutputConfig change=cfg;change.threshold_db=-12;change.release_ms=50;CHECK(dspi_graph_limiter(g,1,&change));
    LimiterOutputConfig got;CHECK(dspi_limiter_get(g->limiter,0,&got));CHECK(got.threshold_db==-12&&got.release_ms==50);
    change.link_group=0;CHECK(dspi_graph_limiter(g,1,&change));change.threshold_db=-18;CHECK(dspi_graph_limiter(g,1,&change));
    CHECK(dspi_limiter_get(g->limiter,0,&got));CHECK(got.threshold_db==-12);
    change.link_group=1;CHECK(dspi_graph_limiter(g,1,&change));CHECK(dspi_limiter_get(g->limiter,1,&got));CHECK(got.threshold_db==-12);
    change=got;change.threshold_db=NAN;CHECK(!dspi_graph_limiter(g,1,&change));CHECK(dspi_limiter_get(g->limiter,1,&change));CHECK(change.threshold_db==-12);
    change.enabled=false;CHECK(dspi_graph_limiter(g,1,&change));CHECK(dspi_limiter_latency(g->limiter)==0);run(g);
    CHECK(memcmp(a,left,sizeof a)==0&&memcmp(b,right,sizeof b)==0);dspi_graph_destroy(g);
    /* Release returns smoothly to unity after an initial loud block. */
    for(unsigned i=0;i<48000;i++)left[i]=i<160?2.0f:.1f;
    g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;cfg=(LimiterOutputConfig){true,0,-6,100};CHECK(dspi_graph_limiter(g,0,&cfg));run(g);
    CHECK(a[400]>.02f&&a[400]<.1f);CHECK(a[4000]>a[400]);CHECK(fabs(a[47999]-.1)<0.000001);
    CHECK(dspi_limiter_reduction_db(g->limiter,0)<0.001);dspi_graph_destroy(g);
    /* Peak control across sample rates and threshold/release extremes. */
    uint32_t rng=12345;
    for(unsigned i=0;i<48000;i++){rng=rng*1664525u+1013904223u;left[i]=((float)(rng>>8)/8388608-1)*16;right[i]=left[i]*.25f;}
    const float rates[]={8000,44100,96000,192000};
    for(unsigned r=0;r<4;r++)for(unsigned extreme=0;extreme<2;extreme++){
        cfg=(LimiterOutputConfig){true,0,extreme?-30:0,extreme?1000:10};
        g=dspi_graph_create(rates[r],2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_limiter(g,0,&cfg));run(g);
        float ceiling=powf(10,cfg.threshold_db/20);bool bounded=true;
        for(unsigned i=0;i<48000;i++)if(!isfinite(a[i])||fabsf(a[i])>ceiling*1.000003f)bounded=false;
        CHECK(bounded);
        bool aligned=true;for(unsigned i=32;i<48000;i++)if(b[i]!=right[i-32])aligned=false;CHECK(aligned);
        dspi_graph_destroy(g);
    }
    /* All four link groups across eight channels share the deepest reduction. */
    g=dspi_graph_create(48000,8,8);CHECK(g);if(!g)return 1;
    float many_in[8][256],many_out[8][256];const float *ip8[8];float *op8[8];
    for(unsigned o=0;o<8;o++){
        cfg=(LimiterOutputConfig){true,(uint8_t)(1+o/2),-12,100};CHECK(dspi_graph_limiter(g,o,&cfg));
        for(unsigned i=0;i<256;i++)many_in[o][i]=(float)(2*(o+1));ip8[o]=many_in[o];op8[o]=many_out[o];
    }
    CHECK(dspi_graph_process(g,ip8,op8,256));
    for(unsigned o=0;o<8;o++){
        CHECK(many_out[o][255]<=powf(10,-12.0f/20)*1.000003f);
        if(!(o&1))CHECK(fabsf(many_out[o][255]/(float)(o+1)-many_out[o+1][255]/(float)(o+2))<0.000001);
    }
    dspi_graph_destroy(g);
    /* Final placement must also contain peaks from existing effects and gain. */
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;
    CrossfeedConfig xf={true,true,0,700,4.5f,1};CHECK(dspi_graph_crossfeed(g,&xf));
    TubeConfig tube=dspi_tube_defaults();tube.enabled=true;tube.output_mask=3;tube.drive_db=6;CHECK(dspi_graph_tube(g,&tube));
    CHECK(dspi_graph_volume(g,-20));CHECK(dspi_graph_loudness(g,83,200,3));
    for(unsigned o=0;o<2;o++){
        CHECK(dspi_set_peq(&g->channel[o],0,FILTER_PEAKING,1000,1,20,0,false));
        CHECK(dspi_graph_gain(g,o,12));CHECK(dspi_graph_delay(g,o,1));
        cfg=(LimiterOutputConfig){true,1,-12,100};CHECK(dspi_graph_limiter(g,o,&cfg));
    }
    run(g);bool bounded=true;for(unsigned i=0;i<48000;i++)if(!isfinite(a[i])||!isfinite(b[i])||fabsf(a[i])>0.251189f||fabsf(b[i])>0.251189f)bounded=false;CHECK(bounded);
    dspi_graph_destroy(g);
    printf("%s limiter peak/link/latency/release checks: %d failures\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}
