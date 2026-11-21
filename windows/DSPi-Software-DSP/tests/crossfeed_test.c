#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e)do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float left[48000],right[48000],a[48000],b[48000],ref_l[48000],ref_r[48000];
static CrossfeedConfig config(void){return (CrossfeedConfig){true,true,0,700,4.5f,1};}
static void run(DspiGraph *g){const float *ip[]={left,right};float *op[]={a,b};CHECK(dspi_graph_process(g,ip,op,48000));}
int main(void){
    /* Hard-panned DC: complementary mix reaches the known 4.5 dB ratio. */
    for(unsigned i=0;i<48000;i++)left[i]=0.25f;
    DspiGraph *g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CrossfeedConfig c=config();
    CHECK(dspi_graph_crossfeed(g,&c));run(g);
    CHECK(fabs(a[47999]-0.25*0.626699081666732)<0.000002);
    CHECK(fabs(b[47999]-0.25*0.373300918333268)<0.000002);
    printf("Crossfeed DC direct %.8f, opposite %.8f\n",a[47999]/0.25,b[47999]/0.25);
    memcpy(right,left,sizeof left);run(g);CHECK(fabs(a[47999]-.25)<0.000002&&fabs(b[47999]-.25)<0.000002);dspi_graph_destroy(g);
    memset(right,0,sizeof right);
    /* Custom 2k/6dB ITD impulse: gold values from independent transfer functions. */
    const double want_l[]={.923100362076584,-.0591869915429069,-.0455541802601053,-.0350614769406854,-.0269856061121748,-.0207698876597071};
    const double want_r[]={-.0581858251972056,-.0119100675857986,.0157068820061034,.0309095979442842,.038030550774892,.0400458227000371};
    memset(left,0,sizeof left);left[0]=1;c=(CrossfeedConfig){true,true,3,2000,6,1};
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_crossfeed(g,&c));run(g);
    for(unsigned i=0;i<6;i++){CHECK(fabs(a[i]-want_l[i])<0.000002);CHECK(fabs(b[i]-want_r[i])<0.000002);}
    memcpy(ref_l,a,sizeof a);memcpy(ref_r,b,sizeof b);dspi_graph_destroy(g);
    /* Every callback size must preserve all four state variables per pair. */
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_crossfeed(g,&c));
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;const float *ip[]={left+i,right+i};float *op[]={a+i,b+i};CHECK(dspi_graph_process(g,ip,op,n));i+=n;}
    CHECK(memcmp(a,ref_l,sizeof a)==0&&memcmp(b,ref_r,sizeof b)==0);dspi_graph_destroy(g);
    /* Reconfiguring ITD resets the old all-pass state, preventing a stale tail. */
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_crossfeed(g,&c));
    const float *one_in[]={left,right};float *one_out[]={a,b};CHECK(dspi_graph_process(g,one_in,one_out,1));
    c.itd_enabled=false;CHECK(dspi_graph_crossfeed(g,&c));left[0]=0;
    CHECK(dspi_graph_process(g,one_in,one_out,256));bool reset=true;for(unsigned i=0;i<256;i++)if(a[i]!=0||b[i]!=0)reset=false;CHECK(reset);dspi_graph_destroy(g);
    /* Equal mono signals with ITD off are complementary at every sample. */
    for(unsigned i=0;i<48000;i++)left[i]=right[i]=(float)(0.2*sin(i*.17));c=config();c.itd_enabled=false;
    g=dspi_graph_create(48000,2,2);CHECK(g);if(!g)return 1;CHECK(dspi_graph_crossfeed(g,&c));run(g);
    float error=0;for(unsigned i=0;i<48000;i++){float e=fabsf(a[i]-left[i])+fabsf(b[i]-right[i]);if(e>error)error=e;}CHECK(error<0.000001);
    CrossfeedConfig before=g->crossfeed,bad=c;bad.custom_fc=NAN;CHECK(!dspi_graph_crossfeed(g,&bad));bad=c;bad.output_pair_mask=2;CHECK(!dspi_graph_crossfeed(g,&bad));
    CHECK(memcmp(&before,&g->crossfeed,sizeof before)==0);
    c.enabled=false;CHECK(dspi_graph_crossfeed(g,&c));run(g);CHECK(memcmp(a,left,sizeof a)==0&&memcmp(b,right,sizeof b)==0);dspi_graph_destroy(g);
    /* All four pairs run independently. A lone third output stays untouched. */
    g=dspi_graph_create(48000,8,8);CHECK(g);if(!g)return 1;c=config();c.output_pair_mask=15;CHECK(dspi_graph_crossfeed(g,&c));
    float source[8][256]={{0}},dest[8][256];const float *ip[8];float *op[8];source[0][0]=1;
    for(unsigned i=0;i<8;i++){ip[i]=source[i];op[i]=dest[i];}CHECK(dspi_graph_process(g,ip,op,256));
    bool silent=true;for(unsigned ch=2;ch<8;ch++)for(unsigned i=0;i<256;i++)if(dest[ch][i]!=0)silent=false;CHECK(silent);CHECK(dest[1][0]!=0);dspi_graph_destroy(g);
    g=dspi_graph_create(48000,2,3);CHECK(g);if(!g)return 1;c=config();CHECK(dspi_graph_crossfeed(g,&c));CHECK(dspi_graph_route(g,0,2,0,false,true));
    const float *odd_in[]={left,right};float *odd_out[]={a,b,ref_l};CHECK(dspi_graph_process(g,odd_in,odd_out,48000));CHECK(memcmp(ref_l,left,sizeof left)==0);dspi_graph_destroy(g);
    const float rates[]={8000,44100,96000,192000};
    for(unsigned r=0;r<4;r++)for(unsigned preset=0;preset<4;preset++){
        g=dspi_graph_create(rates[r],2,2);CHECK(g);if(!g)return 1;c=config();c.preset=(uint8_t)preset;c.custom_fc=2000;c.custom_feed_db=15;
        CHECK(dspi_graph_crossfeed(g,&c));run(g);bool finite=true;for(unsigned i=0;i<48000;i++)if(!isfinite(a[i])||!isfinite(b[i]))finite=false;CHECK(finite);dspi_graph_destroy(g);
    }
    /* Full existing chain remains continuous when crossfeed couples channels. */
    DspiGraph *graphs[2]={dspi_graph_create(48000,2,2),dspi_graph_create(48000,2,2)};
    CHECK(graphs[0]&&graphs[1]);if(!graphs[0]||!graphs[1])return 1;
    for(unsigned k=0;k<2;k++){
        c=config();CHECK(dspi_graph_crossfeed(graphs[k],&c));
        TubeConfig tube=dspi_tube_defaults();tube.enabled=true;tube.output_mask=1;tube.drive_db=6;CHECK(dspi_graph_tube(graphs[k],&tube));
        CHECK(dspi_set_crossover(&graphs[k]->channel[0],0,FILTER_LR4_HP,80,false));
        CHECK(dspi_set_peq(&graphs[k]->channel[0],0,FILTER_PEAKING,1000,1,-3,0,false));
        CHECK(dspi_graph_volume(graphs[k],-20));CHECK(dspi_graph_loudness(graphs[k],83,100,3));CHECK(dspi_graph_delay(graphs[k],0,3));
    }
    for(unsigned i=0;i<48000;i++){left[i]=(float)(.2*sin(i*.13));right[i]=(float)(.1*cos(i*.23));}
    run(graphs[0]);memcpy(ref_l,a,sizeof a);memcpy(ref_r,b,sizeof b);
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;const float *ip[]={left+i,right+i};float *op[]={a+i,b+i};CHECK(dspi_graph_process(graphs[1],ip,op,n));i+=n;}
    CHECK(memcmp(a,ref_l,sizeof a)==0&&memcmp(b,ref_r,sizeof b)==0);
    CHECK(dspi_graph_mute(graphs[0],1,true));run(graphs[0]);bool muted=true;for(unsigned i=0;i<48000;i++)if(b[i]!=0)muted=false;CHECK(muted);
    dspi_graph_destroy(graphs[0]);dspi_graph_destroy(graphs[1]);
    printf("%s crossfeed response/pair/state checks: %d failures\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}
