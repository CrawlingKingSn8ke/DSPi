#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e)do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float left[48000],right[48000],a[48000],b[48000],c[48000],d[48000];
int main(void){
    for(unsigned i=0;i<48000;i++){left[i]=(float)(0.1*sin(i*0.17));right[i]=(float)(0.1*cos(i*0.23));}
    const float *in[]={left,right};float *out[]={a,b};
    DspiGraph *g=dspi_graph_create(48000,2,2);CHECK(g!=NULL);if(!g)return 1;
    CHECK(dspi_graph_process(g,in,out,48000));
    CHECK(memcmp(left,a,sizeof a)==0&&memcmp(right,b,sizeof b)==0);
    /* Swap channels: catches incorrect matrix indexing/default route leakage. */
    dspi_graph_clear_routes(g);
    CHECK(dspi_graph_route(g,0,1,0,false,true));CHECK(dspi_graph_route(g,1,0,0,false,true));
    CHECK(dspi_graph_process(g,in,out,48000));
    CHECK(memcmp(left,b,sizeof b)==0&&memcmp(right,a,sizeof a)==0);
    /* Exact L-R cancellation and -6.0206 dB averaging without normalization. */
    dspi_graph_clear_routes(g);
    CHECK(dspi_graph_route(g,0,0,0,false,true));CHECK(dspi_graph_route(g,1,0,0,true,true));
    const float *same[]={left,left};CHECK(dspi_graph_process(g,same,out,48000));
    bool silent=true;for(unsigned i=0;i<48000;i++)if(a[i]!=0||b[i]!=0)silent=false;CHECK(silent);
    CHECK(dspi_graph_route(g,1,0,-6.0205999f,false,true));
    CHECK(dspi_graph_route(g,0,0,-6.0205999f,false,true));
    CHECK(dspi_graph_gain(g,0,-6.0205999f));CHECK(dspi_graph_process(g,same,out,48000));
    float max_error=0;for(unsigned i=0;i<48000;i++){float e=fabsf(a[i]-left[i]*0.5f);if(e>max_error)max_error=e;}
    CHECK(max_error<0.000001);
    CHECK(dspi_graph_mute(g,0,true));CHECK(dspi_graph_process(g,in,out,48000));
    silent=true;for(unsigned i=0;i<48000;i++)if(a[i]!=0)silent=false;CHECK(silent);
    dspi_graph_destroy(g);
    /* Muting must suppress already-buffered audio immediately, not after delay. */
    g=dspi_graph_create(48000,1,1);CHECK(g!=NULL);if(!g)return 1;
    CHECK(dspi_graph_delay(g,0,10));
    const float *buffered_in[]={left};float *buffered_out[]={a};
    CHECK(dspi_graph_process(g,buffered_in,buffered_out,100));
    CHECK(dspi_graph_mute(g,0,true));
    CHECK(dspi_graph_process(g,buffered_in,buffered_out,1000));
    silent=true;for(unsigned i=0;i<1000;i++)if(a[i]!=0)silent=false;CHECK(silent);
    CHECK(dspi_graph_mute(g,0,false));
    memset(a,0,sizeof a);const float *silence_in[]={a};float *unmuted_out[]={b};
    CHECK(dspi_graph_process(g,silence_in,unmuted_out,1000));
    silent=true;for(unsigned i=0;i<1000;i++)if(b[i]!=0)silent=false;CHECK(silent);
    dspi_graph_destroy(g);
    /* Impulse timing, maximum delay, and wrap-around at multiple sample rates. */
    const float rates[]={44100,48000,96000,192000};
    memset(left,0,sizeof left);left[0]=1;const float *impulse[]={left};float *single[]={a};
    for(unsigned r=0;r<4;r++)for(unsigned mx=0;mx<2;mx++){
        g=dspi_graph_create(rates[r],1,1);CHECK(g!=NULL);if(!g)return 1;
        float ms=mx?170:1;unsigned n=(unsigned)(rates[r]*ms/1000);
        CHECK(dspi_graph_delay(g,0,ms));CHECK(dspi_graph_process(g,impulse,single,48000));
        bool correct=true;for(unsigned i=0;i<48000;i++)if(a[i]!=(i==n?1.0f:0.0f))correct=false;
        CHECK(correct);dspi_graph_destroy(g);
    }
    /* Continuous state over arbitrary callbacks, combining matrix/filter/gain/delay. */
    g=dspi_graph_create(48000,2,2);DspiGraph *split=dspi_graph_create(48000,2,2);CHECK(g&&split);if(!g||!split)return 1;
    DspiGraph *graphs[]={g,split};
    for(unsigned k=0;k<2;k++){
        CHECK(dspi_graph_route(graphs[k],1,0,-9,true,true));
        CHECK(dspi_graph_gain(graphs[k],0,-3));CHECK(dspi_graph_delay(graphs[k],0,7.5f));
        CHECK(dspi_set_crossover(&graphs[k]->channel[0],0,FILTER_LR4_HP,80,false));
        CHECK(dspi_set_peq(&graphs[k]->channel[0],0,FILTER_PEAKING,1000,1,-3,0,false));
    }
    CHECK(dspi_graph_process(g,in,out,48000));
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;
        const float *si[]={left+i,right+i};float *so[]={c+i,d+i};CHECK(dspi_graph_process(split,si,so,n));i+=n;}
    CHECK(memcmp(a,c,sizeof a)==0&&memcmp(b,d,sizeof b)==0);
    uint32_t pos=g->position[0];CHECK(dspi_graph_process(g,NULL,NULL,0));CHECK(g->position[0]==pos);
    CHECK(!dspi_graph_process(g,NULL,out,10));CHECK(g->position[0]==pos);
    CHECK(!dspi_graph_delay(g,0,171));CHECK(!dspi_graph_delay(g,0,NAN));
    CHECK(!dspi_graph_gain(g,0,INFINITY));CHECK(!dspi_graph_route(g,2,0,0,false,true));
    dspi_graph_destroy(g);dspi_graph_destroy(split);
    /* Every input/output of an 8x8 matrix can be addressed independently. */
    g=dspi_graph_create(48000,8,8);CHECK(g!=NULL);if(!g)return 1;
    float source[8][1],dest[8][1];const float *ip[8];float *op[8];
    dspi_graph_clear_routes(g);
    for(unsigned i=0;i<8;i++){source[i][0]=(float)(i+1)/16;ip[i]=source[i];op[i]=dest[i];CHECK(dspi_graph_route(g,i,7-i,0,false,true));}
    CHECK(dspi_graph_process(g,ip,op,1));for(unsigned i=0;i<8;i++)CHECK(dest[i][0]==source[7-i][0]);
    dspi_graph_destroy(g);
    CHECK(!dspi_graph_create(48000,0,2));CHECK(!dspi_graph_create(48000,2,9));CHECK(!dspi_graph_create(NAN,2,2));
    printf("%s matrix/gain/mute/delay checks: %d failures\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}
