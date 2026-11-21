#include "../src/host_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"Runtime FAIL %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static float input[4096*2],output[4096*2],other[4096*2];
static void *graph(const char *recipe){return dspi_host_prepare(48000,2,2,recipe);}
int main(void){
    CHECK(!graph("--gain\nNaN"));CHECK(!graph("--outputs\n3"));CHECK(!graph("--unknown"));
    void *g=graph("");CHECK(g);void *rt=dspi_host_create(g,480);CHECK(rt);
    for(unsigned i=0;i<8192;i++)input[i]=.25f;
    CHECK(dspi_host_process(rt,input,output,256));for(unsigned i=0;i<512;i++)CHECK(output[i]==.25f);
    CHECK(!dspi_host_process(rt,input,input,256));input[1]=NAN;CHECK(!dspi_host_process(rt,input,output,256));input[1]=.25f;
    void *bad=dspi_host_prepare(44100,2,2,"");CHECK(bad);CHECK(!dspi_host_submit(rt,bad));dspi_host_graph_destroy(bad);
    CHECK(dspi_host_submit(rt,graph("--gain\n-6")));CHECK(dspi_host_process(rt,input,output,2048));
    float last=.25f,min=1,max_jump=0;for(unsigned i=0;i<2048;i++){float v=output[2*i];CHECK(isfinite(v));min=fminf(min,v);max_jump=fmaxf(max_jump,fabsf(v-last));last=v;CHECK(output[2*i+1]==v);}
    CHECK(min>=.12528f);CHECK(max_jump<.001f);CHECK(fabsf(last-.1252968f)<.00001f);
    float ip[8],op[8];uint32_t clips;dspi_host_meters(rt,ip,op,&clips);CHECK(ip[0]==.25f&&op[0]==.25f&&clips==0);
    dspi_host_meters(rt,ip,op,&clips);CHECK(ip[0]==0&&op[0]==0);
    /* Queue coalescing: the newest pending target wins, no intermediate gain. */
    CHECK(dspi_host_submit(rt,graph("--gain\n6")));CHECK(dspi_host_submit(rt,graph("--gain\n-12")));
    CHECK(dspi_host_process(rt,input,output,2048));CHECK(fabsf(output[4094]-.06279716f)<.00001f);
    /* Switching limiter on/off cannot reset audible samples at full amplitude. */
    CHECK(dspi_host_submit(rt,graph("--limiter\n-12\n100")));CHECK(dspi_host_process(rt,input,output,2048));
    CHECK(dspi_host_submit(rt,graph("")));CHECK(dspi_host_process(rt,input,output,2048));
    for(unsigned i=0;i<4096;i++)CHECK(isfinite(output[i])&&fabsf(output[i])<=.251f);
    dspi_host_collect(rt);dspi_host_destroy(rt);
    /* External packet boundaries do not affect either transition ramp. */
    void *a=dspi_host_create(graph(""),480),*b=dspi_host_create(graph(""),480);CHECK(a&&b);
    CHECK(dspi_host_submit(a,graph("--gain\n-9")));CHECK(dspi_host_submit(b,graph("--gain\n-9")));
    CHECK(dspi_host_process(a,input,output,4096));for(unsigned p=0;p<4096;){unsigned n=17;if(n>4096-p)n=4096-p;CHECK(dspi_host_process(b,input+2*p,other+2*p,n));p+=n;}
    CHECK(!memcmp(output,other,sizeof output));dspi_host_destroy(a);dspi_host_destroy(b);
    /* Long delay lines must be filled BEFORE the switch, not start abruptly
     * after an already completed fade-up. DC makes the discontinuity visible. */
    rt=dspi_host_create(graph(""),480);CHECK(rt);CHECK(dspi_host_submit(rt,graph("--input-delay\n170\n--delay\n170\n--leveller\n0\nfast\n0\n--limiter\n-1\n100")));
    last=.25f;max_jump=0;for(unsigned block=0;block<30;block++){
        CHECK(dspi_host_process(rt,input,output,1024));for(unsigned f=0;f<1024;f++){max_jump=fmaxf(max_jump,fabsf(output[2*f]-last));last=output[2*f];}
    }
    CHECK(max_jump<.001f);CHECK(fabsf(last-.25f)<.00001f);dspi_host_destroy(rt);
    g=graph("--input-lt\n80\n.7\n40\n.6\n--lt\n80\n.7\n40\n.6");CHECK(g);dspi_host_graph_destroy(g);
    rt=dspi_host_create(graph("--master-gain\n-6\n--volume\n-6"),480);CHECK(rt);CHECK(dspi_host_process(rt,input,output,256));CHECK(fabsf(output[0]-.06279716f)<.00001f);dspi_host_destroy(rt);
    rt=dspi_host_create(graph("--master-gain\n-128"),480);CHECK(rt);CHECK(dspi_host_process(rt,input,output,256));CHECK(output[0]==0);dspi_host_destroy(rt);CHECK(!graph("--master-gain\n-129"));
    puts("PASS native runtime validation, fade/limiter switching, queue coalescing, meters and packet boundaries");return 0;
}
