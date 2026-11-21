/* GPL-3.0. No installation, directory creation or callback I/O. */
#define COBJMACROS
#include "live.h"
#include <bcrypt.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <math.h>
#include "spectrum.h"
#include "../src/host_api.h"
#include "../src/graph.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
struct DspiApoLive {
    HANDLE stop,thread; wchar_t directory[2048],status[2200];
    DspiSpectrum *spectrum;
    void *runtime; unsigned rate,channels,latency;
    uint64_t id,accepted,rejected,pending,lastProcessed,lastFrames;
    _Atomic(uint64_t) frames;
    unsigned state,error;
};
static LONG serial;
static uint32_t u32(const unsigned char *b){uint32_t x;memcpy(&x,b,4);return x;}
static uint64_t u64(const unsigned char *b){uint64_t x;memcpy(&x,b,8);return x;}
static void put32(unsigned char*b,uint32_t x){memcpy(b,&x,4);}
static void put64(unsigned char*b,uint64_t x){memcpy(b,&x,8);}
static uint64_t now(void){FILETIME t;GetSystemTimeAsFileTime(&t);return ((uint64_t)t.dwHighDateTime<<32)|t.dwLowDateTime;}
int dspi_apo_key_valid(const wchar_t *key){if(!key||wcslen(key)!=64)return 0;for(unsigned i=0;i<64;i++)if(!((key[i]>=L'0'&&key[i]<=L'9')||(key[i]>=L'a'&&key[i]<=L'f')))return 0;return 1;}
BOOL dspi_apo_endpoint_key(const wchar_t *endpoint,wchar_t key[65]){
    /* Windows endpoint IDs are ASCII. Match the Console's lowercase UTF-8 hash. */
    unsigned char id[128], digest[32];
    static const wchar_t prefix[]=L"{0.0.0.00000000}.";
    const size_t length=wcslen(endpoint), prefixLength=wcslen(prefix);
    BOOL valid=length==prefixLength+38&&!wcsncmp(endpoint,prefix,prefixLength)&&
        endpoint[prefixLength]==L'{'&&endpoint[length-1]==L'}';
    for(size_t i=0;valid&&i<length;i++){
        wchar_t c=endpoint[i];
        if(c>127){valid=FALSE;break;}
        id[i]=(unsigned char)((c>=L'A'&&c<=L'Z')?c+(L'a'-L'A'):c);
    }
    if(!valid)return FALSE;
    BCRYPT_ALG_HANDLE algorithm=NULL;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0)return FALSE;
    NTSTATUS status=BCryptHash(algorithm,NULL,0,id,(ULONG)length,digest,sizeof digest);
    BCryptCloseAlgorithmProvider(algorithm,0);
    if(status<0)return FALSE;
    static const wchar_t hex[]=L"0123456789abcdef";
    for(unsigned i=0;i<sizeof digest;i++){key[2*i]=hex[digest[i]>>4];key[2*i+1]=hex[digest[i]&15];}
    key[64]=0;
    return TRUE;
}
static uint32_t crc(const unsigned char *b,size_t n){uint32_t x=~0u;for(size_t i=0;i<n;i++){x^=b[i];for(unsigned j=0;j<8;j++)x=(x>>1)^(0xedb88320u&-(x&1));}return ~x;}
static int utf8(const unsigned char *b,unsigned n){return n==0||MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,(const char*)b,n,NULL,0)>0;}
char *dspi_apo_profile(const wchar_t *directory,unsigned rate,unsigned channels,uint64_t *revision,unsigned *error){
    wchar_t path[2200];*revision=0;*error=0;swprintf(path,2200,L"%ls\\profile.bin",directory);
    HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE){if(GetLastError()!=ERROR_FILE_NOT_FOUND)*error=5;return NULL;}
    LARGE_INTEGER size;unsigned char h[64];DWORD got;char *result=NULL;unsigned char *payload=NULL;
    *error=1;
    if(!GetFileSizeEx(f,&size)||size.QuadPart<64||size.QuadPart>64+262144+1048576)goto done;
    if(!ReadFile(f,h,64,&got,NULL)||got!=64)goto done;
    *revision=u64(h+16);
    unsigned rn=u32(h+32),jn=u32(h+36);
    if(memcmp(h,"DSPIAPO1",8)||u32(h+8)!=1||u32(h+12)!=64||!*revision||rn>262144||jn>1048576||size.QuadPart!=64+(uint64_t)rn+jn)goto done;
    for(unsigned i=44;i<64;i++)if(h[i])goto done;
    payload=malloc((size_t)rn+jn+1);if(!payload)goto done;
    if(!ReadFile(f,payload,rn+jn,&got,NULL)||got!=rn+jn||crc(payload,rn+jn)!=u32(h+40))goto done;
    unsigned char extra;LARGE_INTEGER finalSize;
    if(!ReadFile(f,&extra,1,&got,NULL)||got||!GetFileSizeEx(f,&finalSize)||finalSize.QuadPart!=size.QuadPart)goto done;
    if(memchr(payload,0,rn)||(rn&&payload[rn-1]=='\n')||!utf8(payload,rn)||!utf8(payload+rn,jn))goto done;
    if(u32(h+24)!=rate||u32(h+28)!=channels){*error=2;goto done;}
    result=malloc((size_t)rn+1);if(!result)goto done;memcpy(result,payload,rn);result[rn]=0;*error=0;
done:free(payload);CloseHandle(f);return result;
}
static void publish(DspiApoLive *w){
    unsigned char b[192]={0};memcpy(b,"DSPIMTR1",8);put32(b+8,1);put32(b+12,192);put64(b+16,w->id);put64(b+24,now());
    put64(b+32,w->accepted);put64(b+40,dspi_host_active_revision(w->runtime));put64(b+48,w->rejected);put64(b+56,w->pending);
    uint64_t frames=atomic_load(&w->frames);if(frames!=w->lastFrames){w->lastProcessed=now();w->lastFrames=frames;}
    if(frames&&w->state==0)w->state=1;
    put64(b+64,frames);put32(b+72,w->rate);put32(b+76,w->channels);put32(b+80,w->state);put32(b+84,w->error);
    float in[8]={0},out[8]={0};uint32_t clips=0;dspi_host_meters(w->runtime,in,out,&clips);memcpy(b+88,in,32);memcpy(b+120,out,32);
    put32(b+152,clips);put32(b+156,w->latency);put64(b+160,w->lastProcessed);
    wchar_t temp[2250];swprintf(temp,2250,L"%ls.tmp",w->status);
    HANDLE f=CreateFileW(temp,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);if(f==INVALID_HANDLE_VALUE)return;
    DWORD n;BOOL ok=WriteFile(f,b,192,&n,NULL)&&n==192;CloseHandle(f);
    if(!ok||!MoveFileExW(temp,w->status,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))DeleteFileW(temp);
}
/* Match the profile's endpoint, even when it is not Windows' default output. */
static IAudioEndpointVolume *open_endpoint_volume(const wchar_t *directory){
    const wchar_t *profile=wcsrchr(directory,L'\\');
    if(!profile||!dspi_apo_key_valid(++profile))return NULL;

    IMMDeviceEnumerator *enumerator=NULL;
    IMMDeviceCollection *devices=NULL;
    IAudioEndpointVolume *volume=NULL;
    if(FAILED(CoCreateInstance(&CLSID_MMDeviceEnumerator,NULL,CLSCTX_INPROC_SERVER,
                               &IID_IMMDeviceEnumerator,(void**)&enumerator)))return NULL;
    if(SUCCEEDED(IMMDeviceEnumerator_EnumAudioEndpoints(enumerator,eRender,DEVICE_STATE_ACTIVE,&devices))){
        UINT count=0;
        IMMDeviceCollection_GetCount(devices,&count);
        for(UINT i=0;i<count&&!volume;i++){
            IMMDevice *device=NULL;
            LPWSTR id=NULL;
            wchar_t key[65];
            if(FAILED(IMMDeviceCollection_Item(devices,i,&device)))continue;
            if(SUCCEEDED(IMMDevice_GetId(device,&id))&&id&&dspi_apo_endpoint_key(id,key)&&!wcscmp(profile,key))
                IMMDevice_Activate(device,&IID_IAudioEndpointVolume,CLSCTX_ALL,NULL,(void**)&volume);
            CoTaskMemFree(id);
            IMMDevice_Release(device);
        }
        IMMDeviceCollection_Release(devices);
    }
    IMMDeviceEnumerator_Release(enumerator);
    return volume;
}
static DWORD WINAPI worker(void *arg){
    DspiApoLive *w=arg;
    uint64_t seen=w->accepted;
    BOOL com=SUCCEEDED(CoInitializeEx(NULL,COINIT_MULTITHREADED));
    IAudioEndpointVolume *volume=NULL;
    ULONGLONG nextVolumeRead=0;
    int endpointDb=0,appliedDb=0;
    bool loudness=seen!=0;
    do {
        uint64_t rev=0;unsigned error=0;char *recipe=dspi_apo_profile(w->directory,w->rate,w->channels,&rev,&error);
        ULONGLONG tick=GetTickCount64();
        if(com&&recipe&&tick>=nextVolumeRead){
            if(!volume)volume=open_endpoint_volume(w->directory);
            float db=0;
            if(volume&&SUCCEEDED(IAudioEndpointVolume_GetMasterVolumeLevel(volume,&db))&&isfinite(db)){
                endpointDb=(int)floorf(fminf(0,fmaxf(-60,db)));
            }else if(volume){
                IAudioEndpointVolume_Release(volume);
                volume=NULL;
            }
            nextVolumeRead=tick+(volume?150:2000);
        }
        if(rev>seen||(recipe&&rev==seen&&rev==w->accepted&&loudness&&endpointDb!=appliedDb)){
            if(!recipe){w->rejected=rev;w->error=error;w->state=2;}
            else {
                DspiGraph *g=dspi_host_prepare_fixed_latency((float)w->rate,w->channels,w->channels,recipe);
                if(!g){w->rejected=rev;w->error=3;w->state=2;}
                else if(dspi_host_graph_latency(g)!=w->latency){seen=rev;w->pending=rev;w->error=4;w->state=3;dspi_host_graph_destroy(g);}
                else {
                    bool nextLoudness=g->loudness_mask!=0;
                    dspi_graph_loudness_endpoint_volume(g,endpointDb);
                    dspi_host_graph_revision(g,rev);
                    if(dspi_host_submit(w->runtime,g)){
                        seen=rev;w->accepted=rev;w->pending=0;w->state=1;w->error=0;
                        loudness=nextLoudness;appliedDb=endpointDb;
                    }else{dspi_host_graph_destroy(g);w->rejected=rev;w->state=4;w->error=3;}
                }
            }
        } else if(recipe&&rev==seen){
            /* A temporary sharing/short-read failure must recover when the
               same accepted profile is readable again; no graph resubmission. */
            w->state=w->pending==rev?3:1;w->error=w->pending==rev?4:0;
        } else if(!rev&&error){w->state=2;w->error=error;}
        free(recipe);dspi_host_collect(w->runtime);publish(w);dspi_spectrum_tick(w->spectrum);
    }while(WaitForSingleObject(w->stop,50)==WAIT_TIMEOUT);
    if(volume)IAudioEndpointVolume_Release(volume);
    if(com)CoUninitialize();
    w->state=5;publish(w);return 0;
}
DspiApoLive *dspi_apo_live_start(const wchar_t *dir,void *runtime,unsigned rate,unsigned channels,unsigned latency,uint64_t initial){
    DspiApoLive *w=calloc(1,sizeof *w);if(!w)return NULL;wcscpy(w->directory,dir);w->runtime=runtime;w->rate=rate;w->channels=channels;w->latency=latency;w->accepted=initial;
    w->id=((uint64_t)GetCurrentProcessId()<<32)|(uint32_t)InterlockedIncrement(&serial);atomic_init(&w->frames,0);
    swprintf(w->status,2200,L"%ls\\telemetry\\status-%lu-%lu.bin",dir,GetCurrentProcessId(),(unsigned long)(uint32_t)w->id);
    w->stop=CreateEventW(NULL,TRUE,FALSE,NULL);if(!w->stop){free(w);return NULL;}
    w->spectrum=dspi_spectrum_create(dir,rate,channels,w->id);
    w->thread=CreateThread(NULL,0,worker,w,0,NULL);if(!w->thread){dspi_spectrum_destroy(w->spectrum);CloseHandle(w->stop);free(w);return NULL;}return w;
}
void dspi_apo_live_processed(DspiApoLive *w,unsigned frames){if(w)atomic_fetch_add(&w->frames,frames);}
void dspi_apo_live_spectrum(DspiApoLive *w,const float *in,const float *out,unsigned count){if(w)dspi_spectrum_capture(w->spectrum,in,out,count);}
void dspi_apo_live_stop(DspiApoLive *w){if(!w)return;SetEvent(w->stop);WaitForSingleObject(w->thread,INFINITE);CloseHandle(w->thread);CloseHandle(w->stop);dspi_spectrum_destroy(w->spectrum);free(w);}
