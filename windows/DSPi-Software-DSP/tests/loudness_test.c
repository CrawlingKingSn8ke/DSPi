#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e)do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float input[48000],a[48000],b[48000],c[48000];
static double measure(DspiGraph *g,float hz){
    for(unsigned i=0;i<48000;i++)input[i]=(float)(0.05*sin(6.283185307179586*hz*i/g->rate));
    const float *ip[]={input};float *op[]={a,b};
    CHECK(dspi_graph_process(g,ip,op,48000));double x=0,y=0;
    for(unsigned i=24000;i<48000;i++){x+=input[i]*input[i];y+=a[i]*a[i];}
    return 10*log10(y/x);
}
int main(void){
    /* Golden responses calculated independently with double ISO equations and
     * complex RBJ shelf transfer functions. They include -20 dB volume. */
    const float hz[]={50,1000,10000};
    const double want[]={-11.7656798323,-19.9837721201,-18.6732956905};
    for(unsigned k=0;k<3;k++){
        DspiGraph *g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;
        CHECK(dspi_graph_volume(g,-20));CHECK(dspi_graph_loudness(g,83,100,1));
        double db=measure(g,hz[k]);printf("Loudness %.0f Hz: %.6f dB, expected %.6f\n",hz[k],db,want[k]);
        CHECK(fabs(db-want[k])<0.015);dspi_graph_destroy(g);
    }
    /* At reference volume or zero intensity the correction must be transparent. */
    DspiGraph *g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;
    CHECK(dspi_graph_loudness(g,83,100,1));CHECK(fabs(measure(g,50))<0.00001);
    CHECK(dspi_graph_volume(g,-20));CHECK(dspi_graph_loudness(g,83,0,1));
    CHECK(fabs(measure(g,50)+20)<0.005);
    /* Extra output trim does not change the loudness curve's volume key. */
    CHECK(dspi_graph_loudness(g,83,100,1));CHECK(dspi_graph_gain(g,0,-6));
    CHECK(fabs(measure(g,50)-(want[0]-6))<0.015);
    CHECK(dspi_graph_gain(g,0,0));
    double boost20=measure(g,50)+20;
    CHECK(dspi_graph_volume(g,-40));double boost40=measure(g,50)+40;
    CHECK(boost40>boost20+1); /* A stale coefficient pointer would keep boost equal. */
    CHECK(dspi_graph_volume(g,-20.2f));CHECK(g->volume_step==39);
    CHECK(dspi_graph_volume(g,-60));measure(g,50);
    bool silent=true;for(unsigned i=0;i<48000;i++)if(a[i]!=0)silent=false;CHECK(silent);
    CHECK(!dspi_graph_volume(g,NAN));CHECK(!dspi_graph_volume(g,1));CHECK(!dspi_graph_volume(g,-61));
    CHECK(!dspi_graph_loudness(g,39,100,1));CHECK(!dspi_graph_loudness(g,83,201,1));CHECK(!dspi_graph_loudness(g,83,NAN,1));
    CHECK(!dspi_graph_loudness(g,83,100,2));dspi_graph_destroy(g);
    /* Each graph/selected output has separate filter state and coefficients. */
    g=dspi_graph_create(48000,1,2);CHECK(g);if(!g)return 1;
    CHECK(dspi_graph_route(g,0,1,0,false,true));CHECK(dspi_graph_volume(g,-20));
    CHECK(dspi_graph_loudness(g,83,100,1));measure(g,50);
    double p=0,q=0;for(unsigned i=24000;i<48000;i++){p+=b[i]*b[i];q+=input[i]*input[i];}
    CHECK(fabs(10*log10(p/q)+20)<0.005);dspi_graph_destroy(g);
    /* Long blocks and uneven callbacks must retain identical shelf states. */
    g=dspi_graph_create(48000,1,1);DspiGraph *split=dspi_graph_create(48000,1,1);
    CHECK(g&&split);if(!g||!split)return 1;
    CHECK(dspi_graph_volume(g,-20));CHECK(dspi_graph_loudness(g,83,100,1));
    CHECK(dspi_graph_volume(split,-20));CHECK(dspi_graph_loudness(split,83,100,1));
    CHECK(dspi_graph_delay(g,0,5));CHECK(dspi_graph_delay(split,0,5));
    CHECK(dspi_set_peq(&g->channel[0],0,FILTER_PEAKING,500,1,-3,0,false));
    CHECK(dspi_set_peq(&split->channel[0],0,FILTER_PEAKING,500,1,-3,0,false));
    measure(g,50);memcpy(c,a,sizeof a);
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;const float *ip[]={input+i};float *op[]={b+i};CHECK(dspi_graph_process(split,ip,op,n));i+=n;}
    CHECK(memcmp(c,b,sizeof c)==0);
    CHECK(dspi_graph_loudness(g,83,100,0));
    CHECK(dspi_set_peq(&g->channel[0],0,FILTER_FLAT,500,1,0,0,false));
    CHECK(fabs(measure(g,50)+20)<0.005);
    dspi_graph_destroy(g);dspi_graph_destroy(split);
    /* Firmware's fixed 6k shelf needs a sample rate above 12k. */
    g=dspi_graph_create(8000,1,1);CHECK(g);if(!g)return 1;
    CHECK(!dspi_graph_loudness(g,83,100,1));CHECK(dspi_graph_volume(g,-20));dspi_graph_destroy(g);
    /* Rate/reference/intensity extremes must remain finite and stable. */
    const float rates[]={16000,44100,96000,192000};
    for(unsigned r=0;r<4;r++){
        g=dspi_graph_create(rates[r],1,1);CHECK(g);if(!g)return 1;
        CHECK(dspi_graph_volume(g,-59));CHECK(dspi_graph_loudness(g,40,200,1));
        CHECK(isfinite(measure(g,50)));
        CHECK(dspi_graph_volume(g,-20));CHECK(dspi_graph_loudness(g,100,200,1));
        CHECK(isfinite(measure(g,6000)));
        dspi_graph_destroy(g);
    }
    printf("%s loudness checks: %d failures\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}
