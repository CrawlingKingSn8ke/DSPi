#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define N 48000
static float x[8][N],y[8][N],z[8][N];
static unsigned checks;
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"Input FAIL line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static void run(DspiGraph *g,float dst[8][N],unsigned chunk){for(unsigned pos=0;pos<N;){unsigned n=N-pos;if(n>chunk)n=chunk;const float *in[8];float *out[8];for(unsigned i=0;i<g->inputs;i++)in[i]=x[i]+pos;for(unsigned i=0;i<g->outputs;i++)out[i]=dst[i]+pos;CHECK(dspi_graph_process(g,in,out,n));pos+=n;}}
static double rms(float *v,unsigned start){double sum=0;for(unsigned i=start;i<N;i++)sum+=(double)v[i]*v[i];return sqrt(sum/(N-start));}
static void gain_eq(void){
    for(unsigned i=0;i<N;i++)x[0][i]=x[1][i]=.1f*sinf(6.28318530718f*1000*i/48000);
    DspiGraph *g=dspi_graph_create(48000,2,3);CHECK(g);
    CHECK(dspi_graph_input_preamp(g,0,-6));CHECK(dspi_graph_input_eq(g,0,0,FILTER_PEAKING,1000,.707f,12,0,false));
    CHECK(dspi_graph_route(g,0,2,0,false,true));run(g,y,N);
    double db=20*log10(rms(y[0],12000)/rms(x[0],12000));CHECK(fabs(db-6)<.001);CHECK(!memcmp(y[0],y[2],sizeof y[0]));CHECK(!memcmp(y[1],x[1],sizeof x[1]));
    printf("Input preamp -6 + EQ +12: %.6f dB; both matrix destinations match\n",db);
    CHECK(!dspi_graph_input_preamp(g,2,0));CHECK(!dspi_graph_input_preamp(g,0,NAN));CHECK(!dspi_graph_input_preamp(g,0,12.1f));CHECK(!dspi_graph_input_delay(g,0,-1));CHECK(!dspi_graph_input_delay(g,0,171));
    CHECK(!dspi_graph_input_eq(g,0,10,FILTER_PEAKING,1000,.707f,0,0,false));CHECK(!dspi_graph_input_eq(g,0,1,FILTER_PEAKING,24000,.707f,0,0,false));
    CHECK(dspi_graph_input_eq(g,0,0,FILTER_PEAKING,1000,.707f,12,0,true));run(g,y,N);CHECK(fabs(20*log10(rms(y[0],12000)/rms(x[0],12000))+6)<.001);
    dspi_graph_destroy(g);
}
static void delays(void){
    const float rates[]={8000,44100,48000,96000,192000};
    for(unsigned r=0;r<5;r++){
        memset(x,0,sizeof x);for(unsigned i=0;i<8;i++)x[i][0]=(i+1)*.05f;
        DspiGraph *g=dspi_graph_create(rates[r],8,8);CHECK(g);
        for(unsigned i=0;i<8;i++){CHECK(dspi_graph_input_delay(g,i,(float)i));CHECK(dspi_graph_delay(g,i,2));}
        run(g,y,127);
        for(unsigned i=0;i<8;i++){
            unsigned delay=(unsigned)(rates[r]*(float)i/1000)+(unsigned)(rates[r]*2/1000);
            for(unsigned f=0;f<N;f++)CHECK(y[i][f]==(f==delay?x[i][0]:0));
        }
        CHECK(dspi_graph_input_delay(g,7,170));memset(x,0,sizeof x);x[7][0]=.25f;run(g,y,N);
        unsigned delay=(unsigned)(rates[r]*170/1000)+(unsigned)(rates[r]*2/1000);
        if(delay<N)CHECK(y[7][delay]==.25f);
        dspi_graph_destroy(g);
    }
}
static DspiGraph *chain(void){
    DspiGraph *g=dspi_graph_create(48000,2,5);CHECK(g);CHECK(dspi_graph_input_preamp(g,0,-3));CHECK(dspi_graph_input_delay(g,1,3));
    CHECK(dspi_graph_input_eq(g,0,0,FILTER_PEAKING,1000,.707f,-4,0,false));
    LevellerConfig l=g->leveller;l.enabled=true;CHECK(dspi_graph_leveller(g,&l));UpmixConfig u=g->upmix;u.enabled=true;CHECK(dspi_graph_upmix(g,&u));
    for(unsigned i=2;i<5;i++)CHECK(dspi_graph_route(g,i,i,0,false,true));return g;
}
static void combined(void){
    for(unsigned i=0;i<N;i++){x[0][i]=.1f*sinf(6.2831853f*997*i/48000);x[1][i]=x[0][i]+.05f*sinf(6.2831853f*61*i/48000);}
    DspiGraph *a=chain(),*b=chain();float saved[2][N];memcpy(saved,x,sizeof saved);run(a,y,N);run(b,z,17);
    CHECK(!memcmp(saved,x,sizeof saved));for(unsigned i=0;i<5;i++){CHECK(!memcmp(y[i],z[i],sizeof y[i]));CHECK(rms(y[i],12000)>0);}
    dspi_graph_destroy(a);dspi_graph_destroy(b);
    /* The leveller must detect preamplified input, before matrix gain. */
    memcpy(x[1],x[0],sizeof x[0]);a=dspi_graph_create(48000,2,2);CHECK(dspi_graph_input_preamp(a,0,-6));LevellerConfig l=a->leveller;l.enabled=true;l.amount=0;CHECK(dspi_graph_leveller(a,&l));run(a,y,N);
    CHECK(fabs(a->leveller_state.env_sq[0]/a->leveller_state.env_sq[1]-.25118864)<.00001);CHECK(!memcmp(y[1]+288,x[1],(N-288)*sizeof(float)));dspi_graph_destroy(a);
}
int main(void){gain_eq();delays();combined();printf("PASS input EQ/preamp/delay (%u assertions)\n",checks);return 0;}
