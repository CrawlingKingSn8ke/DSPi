/* GPL-3.0. Unregistered standalone APO core. See docs for deployment status. */
#include "dspi_apo.h"
#include "live.h"
#include <propsys.h>
#include <mmdeviceapi.h>
#include "../src/host_api.h"
#include "../src/graph.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

typedef struct {
    IUnknown inner;
    IUnknown *outer;
    IAudioProcessingObject apo;
    IAudioProcessingObjectConfiguration config;
    IAudioProcessingObjectRT rt;
    IAudioSystemEffects fx;
    DspiApoControl control;
    LONG refs;
    BOOL initialized,locked;
    _Atomic int reset;
    unsigned channels,maxframes;
    float rate;
    HNSTIME latency;
    char *recipe;
    wchar_t directory[2048];
    DspiApoLive *live;
    void *runtime;
    float input[DSPI_BLOCK_FRAMES*8],output[DSPI_BLOCK_FRAMES*8];
} Apo;
typedef struct {IClassFactory iface;LONG refs;} Factory;
static LONG objects,server_locks;
#ifdef DSPI_LOCAL_PROBE
static _Atomic unsigned probe_lines;
static void probe(const char *stage,unsigned a,unsigned b){
    if(atomic_fetch_add(&probe_lines,1)>=256)return;
    WCHAR path[2048];
    DWORD n=GetEnvironmentVariableW(L"ProgramData",path,1400);
    if(!n||n>=1400)return;
    swprintf(path+n,2048-n,L"\\DSPi\\Profiles\\73610d00ce7c1d84228fc7fe9d14039026d7916eaab219c71d36c4599d28cb09\\telemetry\\status-%lu-0.bin.tmp",(unsigned long)GetCurrentProcessId());
    HANDLE file=CreateFileW(path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return;
    char line[112];int length=snprintf(line,sizeof line,"%s %08x %08x\n",stage,a,b);
    DWORD written;
    if(length>0&&(size_t)length<sizeof line)WriteFile(file,line,(DWORD)length,&written,NULL);
    CloseHandle(file);
}
#else
#define probe(stage,a,b) ((void)0)
#endif
#define OWNER(p,field) ((Apo*)((char*)(p)-offsetof(Apo,field)))
static HRESULT query(Apo *a,REFIID iid,void **out){
    probe("QueryInterface",iid?iid->Data1:0,0);
    if(!out)return E_POINTER;*out=NULL;if(!iid)return E_POINTER;
    if(IsEqualIID(iid,&IID_IUnknown)){
        *out=a->outer?(void*)&a->inner:(void*)&a->apo;
        InterlockedIncrement(&a->refs);
        return S_OK;
    }
    if(IsEqualIID(iid,&DSPI_IID_APO))*out=&a->apo;
    else if(IsEqualIID(iid,&DSPI_IID_CONFIG))*out=&a->config;
    else if(IsEqualIID(iid,&DSPI_IID_RT))*out=&a->rt;
    else if(IsEqualIID(iid,&DSPI_IID_FX))*out=&a->fx;
    else if(IsEqualIID(iid,&DSPI_IID_CONTROL))*out=&a->control;
    else return E_NOINTERFACE;
    if(a->outer)IUnknown_AddRef(a->outer);else InterlockedIncrement(&a->refs);
    return S_OK;
}
static ULONG release(Apo *a){
    LONG n=InterlockedDecrement(&a->refs);
    if(!n){dspi_apo_live_stop(a->live);dspi_host_destroy(a->runtime);free(a->recipe);free(a);InterlockedDecrement(&objects);}return n;
}
/* Aggregated interfaces share the controlling object's public COM identity.
   Only the private inner IUnknown manages the DSPi object's own lifetime. */
static HRESULT STDMETHODCALLTYPE inner_q(IUnknown *p,REFIID i,void **v){return query(OWNER(p,inner),i,v);}
static ULONG STDMETHODCALLTYPE inner_a(IUnknown *p){return InterlockedIncrement(&OWNER(p,inner)->refs);}
static ULONG STDMETHODCALLTYPE inner_r(IUnknown *p){return release(OWNER(p,inner));}
static IUnknownVtbl inner_vt={inner_q,inner_a,inner_r};
#define UNKNOWN(prefix,type,field) \
static HRESULT STDMETHODCALLTYPE prefix##_q(type *p,REFIID i,void **v){Apo *a=OWNER(p,field);return a->outer?IUnknown_QueryInterface(a->outer,i,v):query(a,i,v);} \
static ULONG STDMETHODCALLTYPE prefix##_a(type *p){Apo *a=OWNER(p,field);return a->outer?IUnknown_AddRef(a->outer):InterlockedIncrement(&a->refs);} \
static ULONG STDMETHODCALLTYPE prefix##_r(type *p){Apo *a=OWNER(p,field);return a->outer?IUnknown_Release(a->outer):release(a);}
UNKNOWN(ap,IAudioProcessingObject,apo)
UNKNOWN(cf,IAudioProcessingObjectConfiguration,config)
UNKNOWN(rt,IAudioProcessingObjectRT,rt)
UNKNOWN(fx,IAudioSystemEffects,fx)
UNKNOWN(ct,DspiApoControl,control)

static HRESULT STDMETHODCALLTYPE reset(IAudioProcessingObject *p){
    Apo *a=OWNER(p,apo);if(!a->initialized)return APOERR_NOT_INITIALIZED;
    atomic_store(&a->reset,1);return S_OK;
}
static HRESULT STDMETHODCALLTYPE latency(IAudioProcessingObject *p,HNSTIME *time){
    probe("GetLatency",OWNER(p,apo)->locked,0);
    if(!time)return E_POINTER;Apo *a=OWNER(p,apo);if(!a->locked)return APOERR_ALREADY_UNLOCKED;
    *time=a->latency;return S_OK;
}
static HRESULT STDMETHODCALLTYPE properties(IAudioProcessingObject *p,APO_REG_PROPERTIES **out){
    (void)p;if(!out)return E_POINTER;*out=NULL;
    size_t bytes=sizeof(APO_REG_PROPERTIES)+3*sizeof(IID);
    APO_REG_PROPERTIES *v=CoTaskMemAlloc(bytes);if(!v)return E_OUTOFMEMORY;memset(v,0,bytes);
    v->clsid=CLSID_DspiApo;v->Flags=APO_FLAG_DEFAULT;
    wcscpy(v->szFriendlyName,L"DSPi Standalone APO (development)");wcscpy(v->szCopyrightInfo,L"DSPi contributors, GPL-3.0");
    v->u32MajorVersion=0;v->u32MinorVersion=1;v->u32MinInputConnections=v->u32MaxInputConnections=1;
    v->u32MinOutputConnections=v->u32MaxOutputConnections=1;v->u32MaxInstances=UINT32_MAX;v->u32NumAPOInterfaces=4;
    v->iidAPOInterfaceList[0]=DSPI_IID_APO;v->iidAPOInterfaceList[1]=DSPI_IID_CONFIG;
    v->iidAPOInterfaceList[2]=DSPI_IID_RT;v->iidAPOInterfaceList[3]=DSPI_IID_FX;*out=v;return S_OK;
}
static BOOL endpoint_profile_key(IMMDeviceCollection *devices,wchar_t key[65]){
    UINT count=0;
    IMMDevice *device=NULL;
    if(!devices||FAILED(IMMDeviceCollection_GetCount(devices,&count))||!count||
       FAILED(IMMDeviceCollection_Item(devices,count-1,&device)))return FALSE;
    LPWSTR endpoint=NULL;
    HRESULT result=IMMDevice_GetId(device,&endpoint);
    IMMDevice_Release(device);
    if(FAILED(result)||!endpoint)return FALSE;
    BOOL valid=dspi_apo_endpoint_key(endpoint,key);
    CoTaskMemFree(endpoint);
    return valid;
}
static HRESULT STDMETHODCALLTYPE initialize(IAudioProcessingObject *p,UINT32 size,BYTE *data){
    probe("Initialize",size,data&&size>=sizeof(APOInitBaseStruct)?((APOInitBaseStruct*)data)->cbSize:0);
    Apo *a=OWNER(p,apo);if(a->initialized)return APOERR_ALREADY_INITIALIZED;
    if(size){
        if(!data)return E_POINTER;
        if(size!=sizeof(APOInitSystemEffects)&&size!=sizeof(APOInitSystemEffects2))return E_INVALIDARG;
        APOInitBaseStruct base;memcpy(&base,data,sizeof base);
        if(base.cbSize!=size)return E_INVALIDARG;if(!IsEqualCLSID(&base.clsid,&CLSID_DspiApo)){probe("InitClsidMismatch",base.clsid.Data1,0);return APOERR_INVALID_APO_CLSID;}
    }else if(data)return E_INVALIDARG;
    if(size){
        APOInitSystemEffects *init=(APOInitSystemEffects*)data;
        wchar_t profile[65]={0};
        if(init->pAPOSystemEffectsProperties){
            const PROPERTYKEY key={{0x67fe7ad1,0x1232,0x4c16,{0x94,0xce,0x83,0xa4,0xf6,0x3b,0xe9,0x81}},1};
            PROPVARIANT v;memset(&v,0,sizeof v);
            if(SUCCEEDED(IPropertyStore_GetValue(init->pAPOSystemEffectsProperties,&key,&v))&&v.vt==VT_LPWSTR&&dspi_apo_key_valid(v.pwszVal)){
                wcscpy(profile,v.pwszVal);
            }
            PropVariantClear(&v);
        }
        if(profile[0]||endpoint_profile_key(init->pDeviceCollection,profile)){
            wchar_t root[1800];DWORD n=GetEnvironmentVariableW(L"ProgramData",root,1800);
            if(n&&n<1800)swprintf(a->directory,2048,L"%ls\\DSPi\\Profiles\\%ls",root,profile);
        }
    }
    probe("ProfileBound",a->directory[0]!=0,0);
    a->initialized=TRUE;return S_OK;
}
static BOOL format(IAudioMediaType *m,UNCOMPRESSEDAUDIOFORMAT *v){
    if(!m||FAILED(IAudioMediaType_GetUncompressedAudioFormat(m,v)))return FALSE;
    if(!IsEqualGUID(&v->guidFormatType,&DSPI_FLOAT)||v->dwBytesPerSampleContainer!=4||v->dwValidBitsPerSample!=32||
       !isfinite(v->fFramesPerSecond)||v->fFramesPerSecond<8000||v->fFramesPerSecond>192000||
       floorf(v->fFramesPerSecond)!=v->fFramesPerSecond||!v->dwSamplesPerFrame||v->dwSamplesPerFrame>8)return FALSE;
    if(v->dwChannelMask){unsigned n=0;DWORD mask=v->dwChannelMask;while(mask){n+=mask&1;mask>>=1;}if(n!=v->dwSamplesPerFrame)return FALSE;}
    return TRUE;
}
static BOOL same(const UNCOMPRESSEDAUDIOFORMAT *a,const UNCOMPRESSEDAUDIOFORMAT *b){
    return a->dwSamplesPerFrame==b->dwSamplesPerFrame&&a->fFramesPerSecond==b->fFramesPerSecond&&a->dwChannelMask==b->dwChannelMask;
}
static HRESULT STDMETHODCALLTYPE supported(IAudioProcessingObject *p,IAudioMediaType *opposite,IAudioMediaType *requested,IAudioMediaType **out){
    Apo *instance=OWNER(p,apo);if(!requested)return E_POINTER;UNCOMPRESSEDAUDIOFORMAT a={0},b={0};
    if(!format(requested,&a)||(opposite&&(!format(opposite,&b)||!same(&a,&b)))){probe("FormatRejected",a.dwBytesPerSampleContainer,a.dwValidBitsPerSample);return APOERR_FORMAT_NOT_SUPPORTED;}
    probe("FormatAccepted",a.dwSamplesPerFrame,(unsigned)a.fFramesPerSecond);
    /* Recipe/effect restrictions belong in negotiation, not a late lock failure.
       These calls are control-thread only; no graph preparation in APOProcess. */
    void *probe=dspi_host_prepare(a.fFramesPerSecond,a.dwSamplesPerFrame,a.dwSamplesPerFrame,instance->recipe?instance->recipe:"");
    if(!probe)return APOERR_FORMAT_NOT_SUPPORTED;dspi_host_graph_destroy(probe);
    if(out){IAudioMediaType_AddRef(requested);*out=requested;}return S_OK;
}
static HRESULT STDMETHODCALLTYPE channel_count(IAudioProcessingObject *p,UINT32 *n){
    if(!n)return E_POINTER;Apo *a=OWNER(p,apo);if(!a->locked)return APOERR_ALREADY_UNLOCKED;*n=a->channels;return S_OK;
}
static HRESULT STDMETHODCALLTYPE set_recipe(DspiApoControl *p,const char *recipe){
    Apo *a=OWNER(p,control);if(a->locked)return APOERR_APO_LOCKED;if(!recipe)return E_POINTER;
    size_t n=0;while(n<=262144&&recipe[n])n++;if(n>262144)return E_INVALIDARG;
    char *copy=malloc(n+1);if(!copy)return E_OUTOFMEMORY;memcpy(copy,recipe,n+1);free(a->recipe);a->recipe=copy;return S_OK;
}
static HRESULT STDMETHODCALLTYPE bind_profile(DspiApoControl *p,const wchar_t *root,const wchar_t *key){
    Apo *a=OWNER(p,control);if(a->locked)return APOERR_APO_LOCKED;
    if(!root||!dspi_apo_key_valid(key)||!root[0]||wcslen(root)>1900)return E_INVALIDARG;
    swprintf(a->directory,2048,L"%ls\\%ls",root,key);return S_OK;
}
static HRESULT STDMETHODCALLTYPE lock_process(IAudioProcessingObjectConfiguration *p,UINT32 ni,APO_CONNECTION_DESCRIPTOR **in,UINT32 no,APO_CONNECTION_DESCRIPTOR **out){
    probe("LockForProcess",ni,no);
    Apo *a=OWNER(p,config);if(a->locked)return APOERR_APO_LOCKED;if(!a->initialized)return APOERR_NOT_INITIALIZED;
    if(ni!=1||no!=1)return APOERR_NUM_CONNECTIONS_INVALID;
    if(!in||!out||!in[0]||!out[0])return E_POINTER;
    APO_CONNECTION_DESCRIPTOR *i=in[0],*o=out[0];UNCOMPRESSEDAUDIOFORMAT fi,fo;
    if(i->u32Signature!=APO_CONNECTION_DESCRIPTOR_SIGNATURE||o->u32Signature!=APO_CONNECTION_DESCRIPTOR_SIGNATURE)return E_INVALIDARG;
    if(!format(i->pFormat,&fi)||!format(o->pFormat,&fo)||!same(&fi,&fo))return APOERR_INVALID_CONNECTION_FORMAT;
    if(!i->u32MaxFrameCount||o->u32MaxFrameCount<i->u32MaxFrameCount)return APOERR_INVALID_OUTPUT_MAXFRAMECOUNT;
    /* Bound hostile descriptors while allowing every practical Windows period. */
    if(i->u32MaxFrameCount>(UINT32)fi.fFramesPerSecond*2)return E_INVALIDARG;
    uint64_t revision=0;unsigned profile_error=0;
    char *profile=a->directory[0]?dspi_apo_profile(a->directory,(unsigned)fi.fFramesPerSecond,fi.dwSamplesPerFrame,&revision,&profile_error):NULL;
    DspiGraph *g=dspi_host_prepare_fixed_latency(fi.fFramesPerSecond,fi.dwSamplesPerFrame,fi.dwSamplesPerFrame,profile?profile:(a->recipe?a->recipe:""));
    if(profile&&!g){revision=0;g=dspi_host_prepare_fixed_latency(fi.fFramesPerSecond,fi.dwSamplesPerFrame,fi.dwSamplesPerFrame,a->recipe?a->recipe:"");}
    if(!profile)revision=0;free(profile);dspi_host_graph_revision(g,revision);
    if(!g)return E_INVALIDARG;
    unsigned frames=dspi_host_graph_latency(g);
    void *runtime=dspi_host_create(g,(unsigned)fi.fFramesPerSecond/100);if(!runtime){dspi_host_graph_destroy(g);return E_OUTOFMEMORY;}
    a->runtime=runtime;a->rate=fi.fFramesPerSecond;a->channels=fi.dwSamplesPerFrame;a->maxframes=i->u32MaxFrameCount;
    a->latency=(HNSTIME)ceil((double)frames*10000000.0/a->rate);atomic_store(&a->reset,0);a->locked=TRUE;
    if(a->directory[0]){a->live=dspi_apo_live_start(a->directory,runtime,(unsigned)a->rate,a->channels,frames,revision);if(!a->live){a->locked=FALSE;dspi_host_destroy(runtime);a->runtime=NULL;return E_OUTOFMEMORY;}}
    probe("LockSucceeded",a->live!=NULL,0);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE unlock_process(IAudioProcessingObjectConfiguration *p){
    Apo *a=OWNER(p,config);if(!a->locked)return APOERR_ALREADY_UNLOCKED;
    a->locked=FALSE;dspi_apo_live_stop(a->live);a->live=NULL;dspi_host_destroy(a->runtime);a->runtime=NULL;a->channels=0;a->maxframes=0;a->latency=0;return S_OK;
}
static void STDMETHODCALLTYPE process(IAudioProcessingObjectRT *p,UINT32 ni,APO_CONNECTION_PROPERTY **in,UINT32 no,APO_CONNECTION_PROPERTY **out){
    Apo *a=OWNER(p,rt);
    if(no!=1||!out||!out[0])return;
    APO_CONNECTION_PROPERTY *o=out[0];o->u32ValidFrameCount=0;o->u32BufferFlags=BUFFER_INVALID;
    if(!a->locked||ni!=1||!in||!in[0]||o->u32Signature!=APO_CONNECTION_PROPERTY_SIGNATURE)return;
    APO_CONNECTION_PROPERTY *i=in[0];unsigned n=i->u32ValidFrameCount,ch=a->channels;
    if(i->u32Signature!=APO_CONNECTION_PROPERTY_SIGNATURE||n>a->maxframes||!o->pBuffer)return;
    float *dest=(float*)o->pBuffer;const float *src=(const float*)i->pBuffer;
    if(i->u32BufferFlags!=BUFFER_VALID&&i->u32BufferFlags!=BUFFER_SILENT){o->u32ValidFrameCount=n;return;}
    if(i->u32BufferFlags==BUFFER_VALID&&n&&!src)return;
    size_t bytes=(size_t)n*ch*sizeof(float);uintptr_t ip=(uintptr_t)src,op=(uintptr_t)dest;
    if(bytes>UINTPTR_MAX-op||(src&&bytes>UINTPTR_MAX-ip))return;
    if(i->u32BufferFlags==BUFFER_VALID&&src!=dest&&ip<op+bytes&&op<ip+bytes)return;
    if(atomic_exchange(&a->reset,0))dspi_host_reset(a->runtime);
    BOOL nonzero=FALSE;
    for(unsigned pos=0;pos<n;){
        unsigned count=n-pos;if(count>DSPI_BLOCK_FRAMES)count=DSPI_BLOCK_FRAMES;
        for(unsigned x=0;x<count*ch;x++){
            float value=i->u32BufferFlags==BUFFER_SILENT?0:src[(size_t)pos*ch+x];a->input[x]=isfinite(value)?value:0;
        }
        if(!dspi_host_process(a->runtime,a->input,a->output,count))memcpy(a->output,a->input,count*ch*sizeof(float));
        dspi_apo_live_spectrum(a->live,a->input,a->output,count);
        for(unsigned x=0;x<count*ch;x++){float v=a->output[x];if(!isfinite(v))v=0;dest[(size_t)pos*ch+x]=v;nonzero|=(v!=0);}
        pos+=count;
    }
    dspi_apo_live_processed(a->live,n);
    o->u32ValidFrameCount=n;o->u32BufferFlags=nonzero?BUFFER_VALID:BUFFER_SILENT;
}
static UINT32 STDMETHODCALLTYPE input_frames(IAudioProcessingObjectRT *p,UINT32 n){(void)p;return n;}
static UINT32 STDMETHODCALLTYPE output_frames(IAudioProcessingObjectRT *p,UINT32 n){(void)p;return n;}
static IAudioProcessingObjectVtbl apo_vt={ap_q,ap_a,ap_r,reset,latency,properties,initialize,supported,supported,channel_count};
static IAudioProcessingObjectConfigurationVtbl config_vt={cf_q,cf_a,cf_r,lock_process,unlock_process};
static IAudioProcessingObjectRTVtbl rt_vt={rt_q,rt_a,rt_r,process,input_frames,output_frames};
static IAudioSystemEffectsVtbl fx_vt={fx_q,fx_a,fx_r};
static DspiApoControlVtbl ctl_vt={ct_q,ct_a,ct_r,set_recipe,bind_profile};
static HRESULT STDMETHODCALLTYPE factory_q(IClassFactory *p,REFIID iid,void **out){
    if(!out)return E_POINTER;*out=NULL;if(!iid)return E_POINTER;
    if(!IsEqualIID(iid,&IID_IUnknown)&&!IsEqualIID(iid,&IID_IClassFactory))return E_NOINTERFACE;
    *out=p;InterlockedIncrement(&((Factory*)p)->refs);return S_OK;
}
static ULONG STDMETHODCALLTYPE factory_a(IClassFactory *p){return InterlockedIncrement(&((Factory*)p)->refs);}
static ULONG STDMETHODCALLTYPE factory_r(IClassFactory *p){Factory *f=(Factory*)p;LONG n=InterlockedDecrement(&f->refs);if(!n){free(f);InterlockedDecrement(&objects);}return n;}
static HRESULT STDMETHODCALLTYPE factory_create(IClassFactory *p,IUnknown *outer,REFIID iid,void **out){
    probe("CreateInstance",iid?iid->Data1:0,outer!=NULL);
    (void)p;if(!out)return E_POINTER;*out=NULL;if(!iid)return E_POINTER;
    if(outer&&!IsEqualIID(iid,&IID_IUnknown))return CLASS_E_NOAGGREGATION;
    Apo *a=calloc(1,sizeof *a);if(!a)return E_OUTOFMEMORY;
    a->inner.lpVtbl=&inner_vt;a->outer=outer;
    a->apo.lpVtbl=&apo_vt;a->config.lpVtbl=&config_vt;a->rt.lpVtbl=&rt_vt;a->fx.lpVtbl=&fx_vt;a->control.lpVtbl=&ctl_vt;
    a->refs=1;atomic_init(&a->reset,0);InterlockedIncrement(&objects);HRESULT hr=query(a,iid,out);release(a);return hr;
}
static HRESULT STDMETHODCALLTYPE factory_lock(IClassFactory *p,BOOL lock){
    (void)p;if(lock){InterlockedIncrement(&server_locks);return S_OK;}
    LONG old=InterlockedCompareExchange(&server_locks,0,0);
    while(old>0){LONG seen=InterlockedCompareExchange(&server_locks,old-1,old);if(seen==old)return S_OK;old=seen;}return E_UNEXPECTED;
}
static IClassFactoryVtbl factory_vt={factory_q,factory_a,factory_r,factory_create,factory_lock};
HRESULT WINAPI DllGetClassObject(REFCLSID clsid,REFIID iid,void **out){
    probe("DllGetClassObject",clsid?clsid->Data1:0,iid?iid->Data1:0);
    if(!out)return E_POINTER;*out=NULL;if(!clsid)return E_POINTER;
    if(!IsEqualCLSID(clsid,&CLSID_DspiApo))return CLASS_E_CLASSNOTAVAILABLE;
    Factory *f=calloc(1,sizeof *f);if(!f)return E_OUTOFMEMORY;f->iface.lpVtbl=&factory_vt;f->refs=1;InterlockedIncrement(&objects);
    HRESULT hr=factory_q(&f->iface,iid,out);factory_r(&f->iface);return hr;
}
HRESULT WINAPI DllCanUnloadNow(void){return InterlockedCompareExchange(&objects,0,0)||InterlockedCompareExchange(&server_locks,0,0)?S_FALSE:S_OK;}
