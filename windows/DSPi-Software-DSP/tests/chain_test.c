#include "../src/engine.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(e) do{if(!(e)){printf("FAIL %d: %s\n",__LINE__,#e);failures++;}}while(0)
static float input[48000],a[48000],b[48000];
static void tone(float hz,float rate) {
    for(unsigned i=0;i<48000;i++) input[i]=(float)(0.1*sin(6.283185307179586*hz*i/rate));
}
static double response(DspiChannel *c,float hz) {
    tone(hz,c->sample_rate); memcpy(a,input,sizeof a);
    dspi_channel_process(c,a,48000);
    double x=0,y=0;
    for(unsigned i=24000;i<48000;i++){x+=input[i]*input[i]; y+=a[i]*a[i];}
    return 10*log10(y/x);
}
int main(void) {
    DspiChannel c,split;
    CHECK(dspi_channel_init(&c,48000));
    CHECK(dspi_set_peq(&c,0,FILTER_PEAKING,1000,0.707f,6,0,false));
    CHECK(dspi_set_peq(&c,1,FILTER_PEAKING,1000,0.707f,-3,0,false));
    CHECK(fabs(response(&c,1000)-3)<0.005); /* Catches omitted or shared bands. */
    /* Independent channels: a second default channel must remain transparent. */
    CHECK(dspi_channel_init(&split,48000));
    CHECK(fabs(response(&split,1000))<0.00001);
    /* Known center-frequency responses for both hybrid paths/first-order arms. */
    for(unsigned hi=0;hi<2;hi++) for(unsigned type=1;type<=13;type++) {
        if(type==FILTER_LINKWITZ_TRANSFORM) continue;
        float hz=hi?10000:1000;
        CHECK(dspi_channel_init(&c,48000));
        CHECK(dspi_set_peq(&c,0,(uint8_t)type,hz,0.70710678f,6,0,false));
        double db=response(&c,hz),want=0;
        if(type==FILTER_PEAKING)want=6;
        if(type==FILTER_LOWSHELF||type==FILTER_HIGHSHELF||type==FILTER_LOWSHELF1||type==FILTER_HIGHSHELF1)want=3;
        if(type==FILTER_LOWPASS||type==FILTER_HIGHPASS||type==FILTER_LOWPASS1||type==FILTER_HIGHPASS1)want=-3.0103;
        if(type==FILTER_NOTCH) CHECK(db< -90);
        else CHECK(fabs(db-want)<0.01);
        CHECK(c.peq[0].use_svf==!hi);
    }
    /* All crossover families/orders: cutoff plus passband/stopband direction. */
    for(unsigned type=32;type<=63;type++) for(unsigned hi=0;hi<2;hi++) {
        float hz=hi?10000:1000;
        CHECK(dspi_channel_init(&c,48000));
        CHECK(dspi_set_crossover(&c,0,(uint8_t)type,hz,false));
        double db=response(&c,hz);
        if(type<40) CHECK(fabs(db+6.0206)<0.02);
        else if(type<56) CHECK(fabs(db+3.0103)<0.02);
        else CHECK(fabs(db+3.0103)<0.02);
        if(!hi) {
            dspi_channel_init(&c,48000);
            dspi_set_crossover(&c,0,(uint8_t)type,hz,false);
            double low=response(&c,100);
            dspi_channel_init(&c,48000);
            dspi_set_crossover(&c,0,(uint8_t)type,hz,false);
            double high=response(&c,10000);
            if(type&1) { CHECK(low< -15); CHECK(fabs(high)<0.15); }
            else { CHECK(high< -15); CHECK(fabs(low)<0.15); }
        }
    }
    /* Real stereo crossover: LR4 LP + HP sum has flat magnitude at crossover. */
    dspi_channel_init(&c,48000); dspi_channel_init(&split,48000);
    CHECK(dspi_set_crossover(&c,0,FILTER_LR4_LP,1000,false));
    CHECK(dspi_set_crossover(&split,0,FILTER_LR4_HP,1000,false));
    tone(1000,48000); memcpy(a,input,sizeof a); memcpy(b,input,sizeof b);
    dspi_channel_process(&c,a,48000); dspi_channel_process(&split,b,48000);
    double x=0,y=0;
    for(unsigned i=24000;i<48000;i++){x+=input[i]*input[i]; y+=(a[i]+b[i])*(a[i]+b[i]);}
    CHECK(fabs(10*log10(y/x))<0.01);
    /* Ten bands + four crossovers: no state resets across uneven blocks. */
    dspi_channel_init(&c,48000);
    for(unsigned i=0;i<10;i++) CHECK(dspi_set_peq(&c,i,FILTER_PEAKING,100+500*i,1,-1,0,false));
    for(unsigned i=0;i<4;i++) CHECK(dspi_set_crossover(&c,i,FILTER_BW3_HP,30+10*i,false));
    split=c; tone(1000,48000); memcpy(a,input,sizeof a); memcpy(b,input,sizeof b);
    dspi_channel_process(&c,a,48000);
    for(unsigned i=0;i<48000;){unsigned n=127;if(n>48000-i)n=48000-i;dspi_channel_process(&split,b+i,n);i+=n;}
    CHECK(memcmp(a,b,sizeof a)==0);
    /* Same-topology edits must preserve memory, invalid edits leave it untouched. */
    float state=c.peq[0].svic1eq;
    CHECK(dspi_set_peq(&c,0,FILTER_PEAKING,200,1,-2,0,false));
    CHECK(c.peq[0].svic1eq==state);
    DspiChannel before=c;
    CHECK(!dspi_set_peq(&c,10,FILTER_PEAKING,1000,1,1,0,false));
    CHECK(!dspi_set_peq(&c,0,31,1000,1,1,0,false));
    CHECK(!dspi_set_peq(&c,0,FILTER_PEAKING,NAN,1,1,0,false));
    CHECK(!dspi_set_crossover(&c,4,FILTER_LR4_LP,1000,false));
    CHECK(!dspi_set_crossover(&c,0,FILTER_PEAKING,1000,false));
    CHECK(memcmp(&c,&before,sizeof c)==0);
    /* LT uses the firmware target Q slot; unity alignment must be transparent. */
    dspi_channel_init(&c,48000);
    CHECK(dspi_set_peq(&c,0,FILTER_LINKWITZ_TRANSFORM,80,1,80,1,false));
    CHECK(fabs(response(&c,80))<0.01);
    /* Sample rate changes affect design; test centers without 48k assumptions. */
    const float rates[]={44100,96000,192000};
    for(unsigned i=0;i<3;i++) {
        dspi_channel_init(&c,rates[i]);
        CHECK(dspi_set_peq(&c,0,FILTER_PEAKING,1000,1,-9,0,false));
        CHECK(fabs(response(&c,1000)+9)<0.01);
        dspi_channel_init(&c,rates[i]);
        CHECK(dspi_set_crossover(&c,0,FILTER_LR4_HP,1000,false));
        CHECK(fabs(response(&c,1000)+6.0206)<0.02);
    }
    /* Empty callbacks cannot advance state. Bypassed crossover/EQ stays flat. */
    before=c; dspi_channel_process(&c,NULL,5); dspi_channel_process(&c,a,0);
    CHECK(memcmp(&c,&before,sizeof c)==0);
    dspi_channel_init(&c,48000);
    CHECK(dspi_set_peq(&c,0,FILTER_PEAKING,1000,1,12,0,true));
    CHECK(dspi_set_crossover(&c,0,FILTER_LR8_HP,2000,true));
    CHECK(fabs(response(&c,1000))<0.00001);
    printf("%s chain/filter/crossover checks: %d failures\n",failures?"FAIL":"PASS",failures);
    return failures?1:0;
}
