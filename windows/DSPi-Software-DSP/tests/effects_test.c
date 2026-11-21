/* GPL-3.0. Signal-level checks: spectral content, gain, timing and routing. */
#include "../src/graph.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define N 192000
static float x[2][N],y[8][N],z[8][N];
static unsigned checks;
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static void tone(float hz,float amp,bool opposite){for(unsigned i=0;i<N;i++){x[0][i]=amp*sinf(6.28318530718f*hz*i/48000);x[1][i]=opposite?-x[0][i]:x[0][i];}}
static double energy(const float *v,unsigned start){double s=0;for(unsigned i=start;i<N;i++)s+=(double)v[i]*v[i];return sqrt(s/(N-start));}
static double harmonic(const float *v,float hz){double a=0,b=0;for(unsigned i=96000;i<N;i++){double p=6.283185307179586*hz*i/48000;a+=v[i]*cos(p);b+=v[i]*sin(p);}return 2*hypot(a,b)/(N-96000);}
static void run(DspiGraph *g,float dst[8][N],unsigned chunk){
    for(unsigned k=0;k<N;){unsigned n=N-k;if(n>chunk)n=chunk;const float *in[2]={x[0]+k,x[1]+k};float *out[8];for(unsigned o=0;o<g->outputs;o++)out[o]=dst[o]+k;CHECK(dspi_graph_process(g,in,out,n));k+=n;}
}
static void bass(void){
    tone(50,.3f,false);DspiGraph *g=dspi_graph_create(48000,2,2);CHECK(g);
    PsybassConfig p=g->psybass;p.enabled=true;p.output_mask=1;p.character_pct=0;p.cutoff_hz=80;
    CHECK(dspi_graph_psybass(g,&p));run(g,y,N);
    CHECK(harmonic(y[0],100)>.01);CHECK(harmonic(y[1],100)<.0001);CHECK(!memcmp(y[1],x[1],sizeof x[1]));
    p.character_pct=100;CHECK(dspi_graph_psybass(g,&p));run(g,y,N);CHECK(harmonic(y[0],150)>.0005);
    p.cutoff_hz=NAN;CHECK(!dspi_graph_psybass(g,&p));dspi_graph_destroy(g);
    tone(60,.3f,false);g=dspi_graph_create(48000,2,2);SubharmConfig s=g->subharm;s.enabled=true;s.output_mask=3;s.solo=true;
    CHECK(dspi_graph_subharm(g,&s));run(g,y,N);CHECK(harmonic(y[0],30)>.01);CHECK(!memcmp(y[0],y[1],sizeof y[0]));
    printf("Subharmonic: 60 Hz input -> 30 Hz amplitude %.6f\n",harmonic(y[0],30));
    tone(90,.3f,false);CHECK(dspi_graph_subharm(g,&s));run(g,y,N);CHECK(harmonic(y[0],45)>.01);
    s.low_db=s.high_db=s.top_db=-30;s.solo=false;CHECK(dspi_graph_subharm(g,&s));run(g,y,N);CHECK(!memcmp(y[0],x[0],sizeof x[0]));
    s.low_db=13;CHECK(!dspi_graph_subharm(g,&s));dspi_graph_destroy(g);
}
static void leveller(void){
    tone(1000,.01f,false);DspiGraph *g=dspi_graph_create(48000,2,2);LevellerConfig l=g->leveller;l.enabled=true;l.speed=2;l.max_gain_db=12;l.apply_mask=1;
    CHECK(dspi_graph_leveller(g,&l));CHECK(dspi_graph_input_latency(g)==288);run(g,y,N);
    double gain=energy(y[0],96000)/energy(y[1],96000);CHECK(gain>3.5&&gain<4.0);
    printf("Leveller quiet-signal boost: %.4f dB (12 dB maximum)\n",20*log10(gain));
    CHECK(!memcmp(y[1]+288,x[1],(N-288)*sizeof(float)));for(unsigned i=0;i<288;i++)CHECK(y[1][i]==0);
    l.gate_threshold_db=-20;CHECK(dspi_graph_leveller(g,&l));run(g,y,N);CHECK(energy(y[0],96000)/energy(y[1],96000)<1.001);
    l.gate_threshold_db=-96;l.apply_mask=3;CHECK(dspi_graph_leveller(g,&l));tone(1000,.9f,false);run(g,y,N);
    CHECK(energy(y[0],96000)/energy(y[1],96000)>.999);CHECK(energy(y[0],96000)<.637);
    l.amount=101;CHECK(!dspi_graph_leveller(g,&l));dspi_graph_destroy(g);
}
static void routes(DspiGraph *g){dspi_graph_clear_routes(g);for(unsigned i=0;i<5;i++)CHECK(dspi_graph_route(g,i,i,0,false,true));}
static void upmix(void){
    DspiGraph *g=dspi_graph_create(48000,2,5);UpmixConfig u=g->upmix;u.enabled=true;u.center_mode=0;u.surround_mode=1;
    CHECK(dspi_graph_upmix(g,&u));routes(g);CHECK(dspi_graph_sources(g)==5);CHECK(dspi_graph_input_latency(g)==48);
    tone(1000,.1f,false);run(g,y,N);CHECK(energy(y[2],96000)>.099);CHECK(energy(y[3],96000)<1e-6);
    tone(1000,.1f,true);CHECK(dspi_graph_upmix(g,&u));run(g,y,N);CHECK(energy(y[2],96000)<1e-6);CHECK(energy(y[3],96000)>.03);
    u.center_mode=2;CHECK(dspi_graph_upmix(g,&u));run(g,y,N);CHECK(!memcmp(y[0]+48,x[0],(N-48)*sizeof(float)));CHECK(energy(y[2],96000)==0);
    u.center_mode=1;u.surround_mode=2;CHECK(dspi_graph_upmix(g,&u));tone(1000,.1f,false);run(g,y,N);CHECK(energy(y[2],96000)>.095);
    u.strength_pct=INFINITY;CHECK(!dspi_graph_upmix(g,&u));dspi_graph_destroy(g);
    g=dspi_graph_create(96000,2,5);u=dspi_upmix_defaults();u.enabled=true;CHECK(!dspi_graph_upmix(g,&u));dspi_graph_destroy(g);
    g=dspi_graph_create(48000,1,5);CHECK(!dspi_graph_upmix(g,&u));dspi_graph_destroy(g);
}
static DspiGraph *combined(void){
    DspiGraph *g=dspi_graph_create(48000,2,5);UpmixConfig u=g->upmix;u.enabled=true;CHECK(dspi_graph_upmix(g,&u));routes(g);
    LevellerConfig l=g->leveller;l.enabled=true;CHECK(dspi_graph_leveller(g,&l));
    PsybassConfig p=g->psybass;p.enabled=true;p.output_mask=31;CHECK(dspi_graph_psybass(g,&p));
    SubharmConfig s=g->subharm;s.enabled=true;s.output_mask=31;CHECK(dspi_graph_subharm(g,&s));
    TubeConfig t=g->tube;t.enabled=true;t.output_mask=31;CHECK(dspi_graph_tube(g,&t));
    CrossfeedConfig cf=g->crossfeed;cf.enabled=true;cf.output_pair_mask=1;CHECK(dspi_graph_crossfeed(g,&cf));
    CHECK(dspi_set_peq(&g->channel[0],0,FILTER_PEAKING,1000,.707f,3,0,false));
    CHECK(dspi_set_crossover(&g->channel[1],0,FILTER_LR4_HP,30,false));CHECK(dspi_graph_delay(g,2,3));
    CHECK(dspi_graph_loudness(g,83,100,31));CHECK(dspi_graph_volume(g,-6));
    for(unsigned o=0;o<5;o++){LimiterOutputConfig c={.enabled=true,.threshold_db=-6,.release_ms=100,.link_group=1};CHECK(dspi_graph_limiter(g,o,&c));}
    return g;
}
static void together(void){
    for(unsigned i=0;i<N;i++){x[0][i]=.3f*sinf(6.2831853f*60*i/48000)+.2f*sinf(6.2831853f*997*i/48000);x[1][i]=.2f*sinf(6.2831853f*90*i/48000)-.1f*sinf(6.2831853f*997*i/48000);}
    DspiGraph *a=combined(),*b=combined();run(a,y,N);run(b,z,127);
    for(unsigned o=0;o<5;o++){CHECK(!memcmp(y[o],z[o],sizeof y[o]));CHECK(energy(y[o],96000)>.0001);for(unsigned i=0;i<N;i++)CHECK(isfinite(y[o][i])&&fabsf(y[o][i])<.503f);}
    CHECK(dspi_graph_mute(a,0,true));run(a,y,127);CHECK(energy(y[0],0)==0);
    dspi_graph_destroy(a);dspi_graph_destroy(b);
}
static void rates_and_channels(void){
    static const float rates[]={8000,44100,48000,96000,192000};
    float in[8][1024],a[8][1024],b[8][1024];
    for(unsigned r=0;r<5;r++){
        DspiGraph *g=dspi_graph_create(rates[r],8,8);CHECK(g);
        LevellerConfig l=g->leveller;l.enabled=true;l.amount=0;l.apply_mask=85;CHECK(dspi_graph_leveller(g,&l));
        const float *ip[8];float *op[8];
        for(unsigned k=0;k<8;k++){ip[k]=in[k];op[k]=a[k];for(unsigned i=0;i<1024;i++)in[k][i]=.1f*sinf(6.2831853f*(50+k*10)*i/rates[r]);}
        CHECK(dspi_graph_process(g,ip,op,1024));
        for(unsigned k=0;k<8;k++){for(unsigned i=0;i<288;i++)CHECK(a[k][i]==0);CHECK(!memcmp(a[k]+288,in[k],736*sizeof(float)));}
        dspi_graph_destroy(g);
        DspiGraph *h[2]={dspi_graph_create(rates[r],2,2),dspi_graph_create(rates[r],2,2)};
        for(unsigned j=0;j<2;j++){
            PsybassConfig p=h[j]->psybass;p.enabled=true;p.output_mask=3;p.drive_db=18;p.harmonics_db=12;CHECK(dspi_graph_psybass(h[j],&p));
            SubharmConfig s=h[j]->subharm;s.enabled=true;s.output_mask=3;s.link_pairs=false;s.top_db=12;s.low_db=12;s.high_db=12;CHECK(dspi_graph_subharm(h[j],&s));
            for(unsigned pos=0;pos<1024;){unsigned n=j?17:1024;if(n>1024-pos)n=1024-pos;
                const float *pi[2]={in[0]+pos,in[1]+pos};float *po[2]={j?b[0]+pos:a[0]+pos,j?b[1]+pos:a[1]+pos};CHECK(dspi_graph_process(h[j],pi,po,n));pos+=n;}
        }
        for(unsigned k=0;k<2;k++){CHECK(!memcmp(a[k],b[k],sizeof a[k]));for(unsigned i=0;i<1024;i++)CHECK(isfinite(a[k][i]));}
        dspi_graph_destroy(h[0]);dspi_graph_destroy(h[1]);
    }
}
int main(void){bass();leveller();upmix();together();rates_and_channels();printf("Four-effect checks passed (%u assertions)\n",checks);return 0;}
