#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e)do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float input[48000],a[48000],b[48000],reference[48000];
static void tone(float hz,float amplitude){for(unsigned i=0;i<48000;i++)input[i]=(float)(amplitude*sin(6.283185307179586*hz*i/48000));}
static void run(DspiGraph *g){const float *ip[]={input};float *op[]={a,b};CHECK(dspi_graph_process(g,ip,op,48000));}
static double harmonic(const float *x,unsigned hz){double re=0,im=0;for(unsigned i=24000;i<48000;i++){double p=6.283185307179586*hz*i/48000;re+=x[i]*cos(p);im+=x[i]*sin(p);}return 2*hypot(re,im)/24000;}
static TubeConfig cubic(void){TubeConfig c=dspi_tube_defaults();c.enabled=true;c.output_mask=1;c.tube_type=0;c.drive_db=0;c.bias_pct=0;c.asym_db=0;c.hardness_pct=0;c.sag_pct=0;c.rectifier=0;c.xfmr_enabled=false;return c;}
int main(void){
    TubeConfig cfg=cubic();DspiGraph *g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;
    CHECK(dspi_graph_tube(g,&cfg));tone(1000,0.5f);run(g);
    /* Exact cubic at drive=0: y=x-x^3/3. A=0.5 gives fundamental .46875,
     * H3=.0104166667, H3/H1=1/45 (-33.064250 dBc), before the 2.5 Hz blocker. */
    double h1=harmonic(a,1000),h2=harmonic(a,2000),h3=harmonic(a,3000);
    printf("Tube cubic H1 %.8f, H3 %.6f dBc\n",h1,20*log10(h3/h1));
    CHECK(fabs(h1-0.46875)<0.0005);CHECK(fabs(20*log10(h3/h1)+33.0642503)<0.02);CHECK(h2/h1<0.00003);
    /* Nonlinear stage must precede listening volume, not follow attenuation. */
    CHECK(dspi_graph_volume(g,-20));run(g);
    CHECK(fabs(harmonic(a,1000)-0.046875)<0.00005);
    CHECK(fabs(20*log10(harmonic(a,3000)/harmonic(a,1000))+33.0642503)<0.02);
    cfg.mix_pct=0;CHECK(dspi_graph_tube(g,&cfg));CHECK(dspi_graph_volume(g,0));run(g);
    CHECK(memcmp(a,input,sizeof a)==0);dspi_graph_destroy(g);
    /* A nonlinear stage after crossover would regenerate removed harmonics.
     * LR4 LP magnitude is 1/(1+r^4), r=tan(pi*f/Fs)/tan(pi*fc/Fs). */
    cfg=cubic();g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;
    CHECK(dspi_graph_tube(g,&cfg));CHECK(dspi_set_crossover(&g->channel[0],0,FILTER_LR4_LP,1000,false));run(g);
    double r=tan(3.141592653589793*3000/48000)/tan(3.141592653589793*1000/48000);
    double expected_h3=-33.0642503+20*log10(2/(1+pow(r,4)));
    CHECK(fabs(20*log10(harmonic(a,3000)/harmonic(a,1000))-expected_h3)<0.08);dspi_graph_destroy(g);
    cfg=cubic();cfg.bias_pct=10;cfg.asym_db=3;cfg.hardness_pct=40;
    g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;CHECK(dspi_graph_tube(g,&cfg));run(g);
    CHECK(harmonic(a,2000)/harmonic(a,1000)>0.001);dspi_graph_destroy(g);
    /* Original row mapping; invalid styles do not mutate the config. */
    cfg=dspi_tube_defaults();CHECK(dspi_tube_style(&cfg,16));
    CHECK(cfg.bias_pct==12&&cfg.asym_db==6&&cfg.hardness_pct==10&&cfg.sag_pct==12);
    TubeConfig before=cfg;CHECK(!dspi_tube_style(&cfg,17));CHECK(memcmp(&cfg,&before,sizeof cfg)==0);
    /* Sag must develop over time; solid-state rectification disables it. */
    cfg=cubic();cfg.sag_pct=100;cfg.rectifier=3;
    g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;CHECK(dspi_graph_tube(g,&cfg));tone(1000,0.5f);run(g);
    double early=0,late=0;for(unsigned i=0;i<240;i++){early+=a[i]*a[i];late+=a[47040+i]*a[47040+i];}
    CHECK(late<early*0.95);CHECK(g->tube_state[0].env>0.01);dspi_graph_destroy(g);
    cfg.rectifier=0;g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;CHECK(dspi_graph_tube(g,&cfg));run(g);
    CHECK(g->tube_coeffs.sag_on==0&&g->tube_state[0].env==0);dspi_graph_destroy(g);
    /* Transformer stage lift at its 95 Hz speaker resonance. */
    cfg=cubic();cfg.drive_db=-30;g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;
    CHECK(dspi_graph_tube(g,&cfg));tone(95,0.001f);run(g);double dry=harmonic(a,95);dspi_graph_destroy(g);
    cfg.xfmr_enabled=true;cfg.xfmr_damping=2;cfg.xfmr_res_hz=95;
    g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;CHECK(dspi_graph_tube(g,&cfg));run(g);
    double lift=20*log10(harmonic(a,95)/dry);printf("Tube output-stage resonance lift %.6f dB\n",lift);CHECK(lift>2.4&&lift<2.6);dspi_graph_destroy(g);
    /* Independent output states: a second silent channel must stay silent. */
    g=dspi_graph_create(48000,1,2);CHECK(g);if(!g)return 1;cfg=dspi_tube_defaults();cfg.enabled=true;cfg.output_mask=3;cfg.drive_db=6;
    CHECK(dspi_graph_tube(g,&cfg));tone(1000,0.5f);run(g);
    bool silent=true;for(unsigned i=0;i<48000;i++)if(b[i]!=0)silent=false;CHECK(silent);
    memcpy(reference,a,sizeof a);dspi_graph_destroy(g);
    g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;cfg.output_mask=1;CHECK(dspi_graph_tube(g,&cfg));
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;const float *ip[]={input+i};float *op[]={a+i};CHECK(dspi_graph_process(g,ip,op,n));i+=n;}
    CHECK(memcmp(reference,a,sizeof a)==0);
    before=g->tube;TubeConfig bad=cfg;bad.drive_db=NAN;CHECK(!dspi_graph_tube(g,&bad));bad=cfg;bad.mix_pct=101;CHECK(!dspi_graph_tube(g,&bad));
    bad=cfg;bad.output_mask=2;CHECK(!dspi_graph_tube(g,&bad));CHECK(memcmp(&before,&g->tube,sizeof before)==0);
    cfg.enabled=false;CHECK(dspi_graph_tube(g,&cfg));run(g);CHECK(memcmp(input,a,sizeof a)==0);dspi_graph_destroy(g);
    /* Every original tube style must yield finite signal at strong drive. */
    for(unsigned style=1;style<=16;style++){
        g=dspi_graph_create(48000,1,1);CHECK(g);if(!g)return 1;cfg=dspi_tube_defaults();dspi_tube_style(&cfg,style);cfg.enabled=true;cfg.output_mask=1;cfg.drive_db=24;
        CHECK(dspi_graph_tube(g,&cfg));tone(1000,0.9f);run(g);
        bool finite=true;for(unsigned i=0;i<48000;i++)if(!isfinite(a[i]))finite=false;CHECK(finite);dspi_graph_destroy(g);
    }
    const float rates[]={8000,44100,96000,192000};
    for(unsigned k=0;k<4;k++){
        g=dspi_graph_create(rates[k],1,1);CHECK(g);if(!g)return 1;cfg=dspi_tube_defaults();cfg.enabled=true;cfg.output_mask=1;
        cfg.bias_pct=-100;cfg.asym_db=12;cfg.hardness_pct=100;cfg.sag_pct=100;cfg.rectifier=3;
        cfg.xfmr_damping=1;cfg.xfmr_res_hz=150;cfg.drive_db=24;cfg.trim_db=12;
        CHECK(dspi_graph_tube(g,&cfg));run(g);bool finite=true;for(unsigned i=0;i<48000;i++)if(!isfinite(a[i]))finite=false;
        CHECK(finite);dspi_graph_destroy(g);
    }
    printf("%s tube shaper/sag/output-stage checks: %d failures\n",failures?"FAIL":"PASS",failures);return failures?1:0;
}
