/* Actual producer/consumer overlap, no devices or system audio. */
#include "../src/host_api.h"
#include <windows.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
static atomic_bool stop,failed;
static atomic_uint blocks;
static DWORD WINAPI audio(void *runtime){
    float input[128],output[128];for(unsigned i=0;i<128;i++)input[i]=.1f;
    while(!atomic_load(&stop)){
        if(!dspi_host_process(runtime,input,output,64))atomic_store(&failed,true);
        for(unsigned i=0;i<128;i++)if(!isfinite(output[i])||fabsf(output[i])>.101f)atomic_store(&failed,true);
        atomic_fetch_add(&blocks,1);
    }
    return 0;
}
int main(void){
    void *g=dspi_host_prepare(48000,2,2,"");if(!g)return 1;void *r=dspi_host_create(g,48);if(!r)return 1;
    HANDLE worker=CreateThread(NULL,0,audio,r,0,NULL);if(!worker)return 1;
    for(unsigned i=0;i<200;i++){
        g=dspi_host_prepare(48000,2,2,(i&1)?"--gain\n-6":"--limiter\n-24\n100");
        if(!g||!dspi_host_submit(r,g)){atomic_store(&failed,true);if(g)dspi_host_graph_destroy(g);break;}
        float input[8],output[8];uint32_t clips;dspi_host_meters(r,input,output,&clips);
        if(clips)atomic_store(&failed,true);
    }
    atomic_store(&stop,true);WaitForSingleObject(worker,INFINITE);CloseHandle(worker);
    unsigned count=atomic_load(&blocks);dspi_host_collect(r);dspi_host_destroy(r);
    if(atomic_load(&failed)||!count){fputs("FAIL concurrent runtime handoff\n",stderr);return 1;}
    printf("PASS concurrent control/audio handoff, 200 prepared edits, %u audio blocks\n",count);return 0;
}
