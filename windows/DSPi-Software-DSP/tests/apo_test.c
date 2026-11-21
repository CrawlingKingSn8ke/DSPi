/* GPL-3.0. Loads the unregistered DLL and uses the actual Windows COM ABI. */
#include "../apo/dspi_apo.h"
#include "../src/host_api.h"
#include "../src/graph.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { checks++; if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);} } while(0)
static unsigned checks;
typedef struct {IAudioMediaType iface; LONG refs; UNCOMPRESSEDAUDIOFORMAT f;} Media;
static HRESULT STDMETHODCALLTYPE mq(IAudioMediaType *m,REFIID iid,void **out){(void)iid;if(!out)return E_POINTER;*out=m; m->lpVtbl->AddRef(m);return S_OK;}
static ULONG STDMETHODCALLTYPE ma(IAudioMediaType *m){return ++((Media*)m)->refs;}
static ULONG STDMETHODCALLTYPE mr(IAudioMediaType *m){return --((Media*)m)->refs;}
static HRESULT STDMETHODCALLTYPE mc(IAudioMediaType *m,BOOL *b){(void)m;if(!b)return E_POINTER;*b=FALSE;return S_OK;}
static HRESULT STDMETHODCALLTYPE me(IAudioMediaType *m,IAudioMediaType *n,DWORD *f){(void)m;(void)n;if(f)*f=0;return E_NOTIMPL;}
static const WAVEFORMATEX *STDMETHODCALLTYPE mw(IAudioMediaType *m){(void)m;return NULL;}
static HRESULT STDMETHODCALLTYPE mf(IAudioMediaType *m,UNCOMPRESSEDAUDIOFORMAT *f){if(!f)return E_POINTER;*f=((Media*)m)->f;return S_OK;}
static const IAudioMediaTypeVtbl media_vt={mq,ma,mr,mc,me,mw,mf};
static Media media(unsigned rate,unsigned ch){Media m={{&media_vt},1,{DSPI_FLOAT,ch,4,32,(float)rate,0}};return m;}
typedef struct {IAudioProcessingObject *apo; IAudioProcessingObjectConfiguration *cfg; IAudioProcessingObjectRT *rt;DspiApoControl *ctl;} Instance;
static Instance instance(IClassFactory *f){
    Instance a={0};CHECK(IClassFactory_CreateInstance(f,NULL,&DSPI_IID_APO,(void**)&a.apo)==S_OK);
    CHECK(IAudioProcessingObject_QueryInterface(a.apo,&DSPI_IID_CONFIG,(void**)&a.cfg)==S_OK);
    CHECK(IAudioProcessingObject_QueryInterface(a.apo,&DSPI_IID_RT,(void**)&a.rt)==S_OK);
    CHECK(IAudioProcessingObject_QueryInterface(a.apo,&DSPI_IID_CONTROL,(void**)&a.ctl)==S_OK);
    return a;
}
static void destroy(Instance a){a.ctl->lpVtbl->Release(a.ctl);IAudioProcessingObjectRT_Release(a.rt);IAudioProcessingObjectConfiguration_Release(a.cfg);CHECK(IAudioProcessingObject_Release(a.apo)==0);}
static HRESULT lock(Instance a,Media *m,unsigned max){
    APO_CONNECTION_DESCRIPTOR i={APO_CONNECTION_BUFFER_TYPE_EXTERNAL,0,max,&m->iface,APO_CONNECTION_DESCRIPTOR_SIGNATURE},o=i;
    APO_CONNECTION_DESCRIPTOR *ip=&i,*op=&o;return IAudioProcessingObjectConfiguration_LockForProcess(a.cfg,1,&ip,1,&op);
}
static void process(Instance a,float *in,float *out,unsigned n,APO_BUFFER_FLAGS flag,APO_BUFFER_FLAGS *result){
    APO_CONNECTION_PROPERTY i={(UINT_PTR)in,n,flag,APO_CONNECTION_PROPERTY_SIGNATURE};
    APO_CONNECTION_PROPERTY o={(UINT_PTR)out,0,BUFFER_INVALID,APO_CONNECTION_PROPERTY_SIGNATURE};
    APO_CONNECTION_PROPERTY *ip=&i,*op=&o;IAudioProcessingObjectRT_APOProcess(a.rt,1,&ip,1,&op);
    CHECK(o.u32ValidFrameCount==n);if(result)*result=o.u32BufferFlags;
}
static uint32_t profile_crc(const unsigned char *b,size_t n){uint32_t x=~0u;for(size_t i=0;i<n;i++){x^=b[i];for(unsigned j=0;j<8;j++)x=(x>>1)^(0xedb88320u&-(x&1));}return ~x;}
static void put32(unsigned char*b,uint32_t x){memcpy(b,&x,4);}
static void put64(unsigned char*b,uint64_t x){memcpy(b,&x,8);}
static uint64_t read64(const unsigned char*b){uint64_t x;memcpy(&x,b,8);return x;}
static uint32_t read32(const unsigned char*b){uint32_t x;memcpy(&x,b,4);return x;}
static void profile(const wchar_t *dir,uint64_t rev,const char *recipe,unsigned rate,int corrupt){
    size_t n=strlen(recipe);unsigned char b[2048]={0};CHECK(n+66<sizeof b);memcpy(b,"DSPIAPO1",8);put32(b+8,1);put32(b+12,64);put64(b+16,rev);put32(b+24,rate);put32(b+28,2);put32(b+32,(uint32_t)n);put32(b+36,2);memcpy(b+64,recipe,n);memcpy(b+64+n,"{}",2);put32(b+40,profile_crc(b+64,n+2)+(corrupt==1));
    if(corrupt==2)put32(b+32,262145);if(corrupt==3)b[44]=1;
    if(corrupt==4){b[64]=0;put32(b+40,profile_crc(b+64,n+2));}
    if(corrupt==5){b[64+n+2]=1;n++;}
    wchar_t path[1024],temp[1024];swprintf(path,1024,L"%ls\\profile.bin",dir);swprintf(temp,1024,L"%ls\\profile.tmp",dir);
    FILE *f=_wfopen(temp,L"wb");CHECK(f);CHECK(fwrite(b,1,64+n+2,f)==64+n+2);fclose(f);CHECK(MoveFileExW(temp,path,MOVEFILE_REPLACE_EXISTING));
}
typedef struct {Instance a;volatile LONG stop;volatile LONG blocks;volatile LONG last;} Pump;
static DWORD WINAPI pump(void *v){Pump *p=v;float in[512],out[512];for(unsigned i=0;i<512;i++)in[i]=.5f;
    while(!InterlockedCompareExchange(&p->stop,0,0)){APO_CONNECTION_PROPERTY i={(UINT_PTR)in,256,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE},o={(UINT_PTR)out,0,BUFFER_INVALID,APO_CONNECTION_PROPERTY_SIGNATURE};APO_CONNECTION_PROPERTY *ip=&i,*op=&o;IAudioProcessingObjectRT_APOProcess(p->a.rt,1,&ip,1,&op);LONG bits;memcpy(&bits,&out[510],4);InterlockedExchange(&p->last,bits);InterlockedIncrement(&p->blocks);Sleep(1);}return 0;}
static int read_status(const wchar_t *dir,uint64_t revision,unsigned offset,unsigned char *b){
    wchar_t glob[1024];swprintf(glob,1024,L"%ls\\telemetry\\status-*.bin",dir);
    for(unsigned attempt=0;attempt<300;attempt++){
        WIN32_FIND_DATAW data;HANDLE h=FindFirstFileW(glob,&data);
        if(h!=INVALID_HANDLE_VALUE){do{wchar_t path[1024];swprintf(path,1024,L"%ls\\telemetry\\%ls",dir,data.cFileName);HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);if(f!=INVALID_HANDLE_VALUE){DWORD n;BOOL ok=ReadFile(f,b,192,&n,NULL);CloseHandle(f);if(ok&&n==192&&read64(b+offset)==revision){FindClose(h);return 1;}}}while(FindNextFileW(h,&data));FindClose(h);}Sleep(10);
    }return 0;
}
static unsigned spectrum_tone(Instance a,const wchar_t *dir,unsigned tap) {
    wchar_t control[1100],glob[1100];swprintf(control,1100,L"%ls\\rta-control.bin",dir);
    swprintf(glob,1100,L"%ls\\telemetry\\spectrum-*.bin",dir);
    unsigned char request[24]={0};memcpy(request,"DSPIRTA1",8);
    request[8]=3;request[9]=(unsigned char)tap;request[10]=1;request[12]=10;
    FILE *file=_wfopen(control,L"wb");CHECK(file);CHECK(fwrite(request,1,sizeof request,file)==sizeof request);fclose(file);
    float in[512],out[512];unsigned count=0;
    for(unsigned attempt=0;attempt<70;attempt++){
        for(unsigned f=0;f<256;f++,count++){
            in[f*2]=.5f*sinf(6.28318530718f*32*(count%1024)/1024.f);
            in[f*2+1]=0;
        }
        process(a,in,out,256,BUFFER_VALID,NULL);Sleep(5);
        WIN32_FIND_DATAW d;HANDLE h=FindFirstFileW(glob,&d);
        if(h==INVALID_HANDLE_VALUE)continue;
        FindClose(h);
        wchar_t path[1200];swprintf(path,1200,L"%ls\\telemetry\\%ls",dir,d.cFileName);
        HANDLE reader=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
        if(reader==INVALID_HANDLE_VALUE)continue;
        unsigned char snapshot[1500];DWORD n;
        BOOL ok=ReadFile(reader,snapshot,sizeof snapshot,&n,NULL);CloseHandle(reader);
        if(ok&&n>=48+82+16+512+1&&!memcmp(snapshot,request,24)){
            unsigned char *bins=snapshot+48+82+16;
            CHECK(bins[32]>bins[20]+10&&bins[32]>bins[55]+10);
            return bins[32];
        }
    }
    CHECK(0&&"No spectrum from the selected audio tap");return 0;
}
static int wait_error(const wchar_t *dir,uint64_t active,unsigned error){
    unsigned char b[192];uint64_t deadline=GetTickCount64()+3000;
    do {if(read_status(dir,active,40,b)&&read32(b+84)==error)return 1;Sleep(10);}while(GetTickCount64()<deadline);return 0;
}
static void live_test(IClassFactory *f) {
    const wchar_t *key=L"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    wchar_t root[512],dir[1024];swprintf(root,512,L"build\\apo-live-%lu-%llu",GetCurrentProcessId(),(unsigned long long)GetTickCount64());CHECK(CreateDirectoryW(root,NULL));swprintf(dir,1024,L"%ls\\%ls",root,key);CHECK(CreateDirectoryW(dir,NULL));
    wchar_t telemetry[1100];swprintf(telemetry,1100,L"%ls\\telemetry",dir);CHECK(CreateDirectoryW(telemetry,NULL));
    Instance a=instance(f);CHECK(a.ctl->lpVtbl->BindProfile(a.ctl,root,L"bad")==E_INVALIDARG);CHECK(a.ctl->lpVtbl->BindProfile(a.ctl,root,key)==S_OK);
    CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);Media m=media(48000,2);CHECK(lock(a,&m,1024)==S_OK);CHECK(a.ctl->lpVtbl->BindProfile(a.ctl,root,key)==APOERR_APO_LOCKED);
    unsigned char b[192];profile(dir,1,"--gain\n-6",48000,0);CHECK(read_status(dir,1,32,b));CHECK(read64(b+40)==0&&read64(b+64)==0&&read64(b+160)==0);
    Pump p={a,0,0,0};HANDLE thread=CreateThread(NULL,0,pump,&p,0,NULL);CHECK(thread);
    CHECK(read_status(dir,1,40,b));CHECK(read64(b+32)==1&&read64(b+64)>0&&read64(b+160)>0);CHECK(read32(b+72)==48000&&read32(b+76)==2);float peak;memcpy(&peak,b+88,4);CHECK(peak==.5f);
    Sleep(20);LONG last=InterlockedCompareExchange(&p.last,0,0);float value;memcpy(&value,&last,4);CHECK(fabsf(value-.5f*powf(10,-6/20.f))<1e-5f);
    wchar_t profilePath[1100];swprintf(profilePath,1100,L"%ls\\profile.bin",dir);
    HANDLE held=CreateFileW(profilePath,GENERIC_READ,0,NULL,OPEN_EXISTING,0,NULL);CHECK(held!=INVALID_HANDLE_VALUE);
    CHECK(wait_error(dir,1,5));CloseHandle(held);CHECK(wait_error(dir,1,0));
    /* Reset requests overlap graph submission/retirement on the real COM worker. */
    for(unsigned rev=2;rev<=10;rev++){profile(dir,rev,rev%2?"--gain\n-3":"--gain\n-9",48000,0);for(unsigned i=0;i<20;i++){CHECK(IAudioProcessingObject_Reset(a.apo)==S_OK);Sleep(1);}CHECK(read_status(dir,rev,40,b));}
    for(unsigned kind=1;kind<=3;kind++){profile(dir,10+kind,"--gain\n-20",48000,(int)kind);CHECK(read_status(dir,10+kind,48,b));CHECK(read64(b+40)==10&&read32(b+84)==1);}
    profile(dir,14,"--gain\n-20",44100,0);CHECK(read_status(dir,14,48,b));CHECK(read32(b+84)==2&&read64(b+40)==10);
    profile(dir,15,"--unknown",48000,0);CHECK(read_status(dir,15,48,b));CHECK(read32(b+84)==3);
    profile(dir,16,"--gain\n-3\n",48000,0);CHECK(read_status(dir,16,48,b));CHECK(read32(b+84)==1);
    profile(dir,17,"--gain\n" "\xc0\xaf",48000,0);CHECK(read_status(dir,17,48,b));CHECK(read32(b+84)==1);
    profile(dir,18,"--gain\n-20",48000,4);CHECK(read_status(dir,18,48,b));CHECK(read32(b+84)==1);
    profile(dir,19,"--gain\n-20",48000,5);CHECK(read_status(dir,19,48,b));CHECK(read32(b+84)==1);
    /* A corrupt revision is not a trusted counter: it must not poison the
       worker and prevent a later valid profile from being accepted. */
    profile(dir,UINT64_MAX,"--gain\n-20",48000,1);CHECK(read_status(dir,UINT64_MAX,48,b));
    profile(dir,20,"--limiter\n-6\n100",48000,0);CHECK(read_status(dir,20,40,b));CHECK(read64(b+56)==0&&read32(b+80)==1&&read32(b+156)==336);
    profile(dir,21,"--leveller\n50\nfast\n12\n--leveller-lookahead\non\n--limiter\n-6\n100",48000,0);
    CHECK(read_status(dir,21,40,b));CHECK(read64(b+56)==0&&read32(b+156)==336);
    profile(dir,22,"--upmix\npassive\n--leveller\n50\nfast\n12\n--leveller-lookahead\noff",48000,0);
    CHECK(read_status(dir,22,40,b));CHECK(read64(b+56)==0&&read32(b+156)==336);
    profile(dir,23,"--gain\n-9",48000,0);
    CHECK(read_status(dir,23,40,b));CHECK(read64(b+56)==0&&read32(b+156)==336);
    /* A second instance locks independently and reports the same latency. */
    const wchar_t *secondKey=L"1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    wchar_t secondDir[1024],secondTelemetry[1100];
    swprintf(secondDir,1024,L"%ls\\%ls",root,secondKey);CHECK(CreateDirectoryW(secondDir,NULL));
    swprintf(secondTelemetry,1100,L"%ls\\telemetry",secondDir);CHECK(CreateDirectoryW(secondTelemetry,NULL));
    profile(secondDir,24,"--limiter\n-6\n100",48000,0);
    Instance second=instance(f);CHECK(second.ctl->lpVtbl->BindProfile(second.ctl,root,secondKey)==S_OK);
    CHECK(IAudioProcessingObject_Initialize(second.apo,0,NULL)==S_OK);CHECK(lock(second,&m,1024)==S_OK);HNSTIME lat;
    CHECK(IAudioProcessingObject_GetLatency(second.apo,&lat)==S_OK&&lat==70000);
    CHECK(read_status(secondDir,24,40,b));uint64_t secondId=read64(b+16);
    CHECK(read64(b+64)==0&&read64(b+160)==0);CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(second.cfg)==S_OK);
    CHECK(read_status(secondDir,24,40,b));CHECK(read64(b+16)==secondId&&read32(b+80)==5);destroy(second);
    InterlockedExchange(&p.stop,1);CHECK(WaitForSingleObject(thread,3000)==WAIT_OBJECT_0);CloseHandle(thread);CHECK(p.blocks>0);
    unsigned input_bin=spectrum_tone(a,dir,0),output_bin=spectrum_tone(a,dir,1);
    CHECK(input_bin>=output_bin+16&&input_bin<=output_bin+20);
    puts("PASS DSPi RTA: tone bins at input and output with actual DSP gain");
    Sleep(100);CHECK(read_status(dir,23,40,b));uint64_t lastProcessed=read64(b+160),heartbeat=read64(b+24);
    Sleep(100);CHECK(read_status(dir,23,40,b));CHECK(read64(b+160)==lastProcessed&&read64(b+24)>heartbeat);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);
    puts("PASS APO live: effects switch at fixed latency, plus reset, malformed profile and shutdown checks");
}
static void compare(IClassFactory *f,unsigned rate,unsigned ch,const char *recipe,int alias){
    Instance a=instance(f);Media m=media(rate,ch);
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,recipe)==S_OK);
    CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);
    HRESULT locked=lock(a,&m,1024);if(FAILED(locked))fprintf(stderr,"Lock failed 0x%08lx rate=%u channels=%u recipe=%s\n",(unsigned long)locked,rate,ch,recipe);CHECK(locked==S_OK);
    void *g=dspi_host_prepare_fixed_latency((float)rate,ch,ch,recipe);CHECK(g);void *ref=dspi_host_create(g,rate/100);CHECK(ref);
    float in[1024*8],out[1024*8],expected[1024*8],copy[1024*8];
    const unsigned sizes[]={1,17,256,513,1024,48,7};
    for(unsigned b=0;b<21;b++){
        unsigned n=sizes[b%7];for(unsigned x=0;x<n*ch;x++)in[x]=.13f*sinf((float)(x+b*37)*.071f);
        CHECK(dspi_host_process(ref,in,expected,n));memcpy(copy,in,n*ch*sizeof(float));
        APO_BUFFER_FLAGS flags;process(a,alias?copy:in,alias?copy:out,n,BUFFER_VALID,&flags);
        CHECK(flags==BUFFER_VALID||flags==BUFFER_SILENT);
        float *actual=alias?copy:out;for(unsigned x=0;x<n*ch;x++)CHECK(isfinite(actual[x])&&fabsf(actual[x]-expected[x])<1e-6f);
    }
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"")==APOERR_APO_LOCKED);
    CHECK(IAudioProcessingObject_Reset(a.apo)==S_OK);
    dspi_host_destroy(ref);g=dspi_host_prepare_fixed_latency((float)rate,ch,ch,recipe);CHECK(g);ref=dspi_host_create(g,rate/100);CHECK(ref);
    for(unsigned x=0;x<1024*ch;x++)in[x]=x==0?.2f:0;
    CHECK(dspi_host_process(ref,in,expected,1024));process(a,in,out,1024,BUFFER_VALID,NULL);
    for(unsigned x=0;x<1024*ch;x++)CHECK(fabsf(out[x]-expected[x])<1e-6f);
    dspi_host_destroy(ref);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==APOERR_ALREADY_UNLOCKED);
    CHECK(lock(a,&m,1024)==S_OK);CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);
    CHECK(m.refs==1);destroy(a);
}
static void sample_wav(IClassFactory *f,const char *path){
    FILE *file=fopen(path,"rb");CHECK(file);CHECK(fseek(file,0,SEEK_END)==0);long size=ftell(file);CHECK(size>44&&size<40000000);rewind(file);
    unsigned char *bytes=malloc((size_t)size);CHECK(bytes);CHECK(fread(bytes,1,(size_t)size,file)==(size_t)size);fclose(file);
    CHECK(!memcmp(bytes,"RIFF",4)&&!memcmp(bytes+8,"WAVE",4));unsigned rate=0,ch=0,frames=0;unsigned char *data=NULL;
    for(size_t pos=12;pos+8<=(size_t)size;){uint32_t len;memcpy(&len,bytes+pos+4,4);CHECK(len<=(size_t)size-pos-8);
        if(!memcmp(bytes+pos,"fmt ",4)){CHECK(len>=16);uint16_t type,bits;memcpy(&type,bytes+pos+8,2);memcpy(&ch,bytes+pos+10,2);memcpy(&rate,bytes+pos+12,4);memcpy(&bits,bytes+pos+22,2);CHECK(type==1&&bits==16&&ch==2);}
        if(!memcmp(bytes+pos,"data",4)){CHECK(ch==2);data=bytes+pos+8;CHECK(len%4==0);frames=len/4;break;}pos+=8+len+(len&1);
    }
    CHECK(data&&frames&&rate);Instance a=instance(f);Media m=media(rate,ch);const char *recipe="--peak\n1000\n.7\n6\n--gain\n-6";
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,recipe)==S_OK);CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);CHECK(lock(a,&m,1024)==S_OK);
    void *g=dspi_host_prepare_fixed_latency((float)rate,ch,ch,recipe);CHECK(g);void *ref=dspi_host_create(g,rate/100);CHECK(ref);
    float input[2048],output[2048],expected[2048];
    for(unsigned pos=0;pos<frames;){unsigned n=frames-pos;if(n>1024)n=1024;for(unsigned x=0;x<n*ch;x++){int16_t s;memcpy(&s,data+((size_t)pos*ch+x)*2,2);input[x]=(float)s/32768;}
        CHECK(dspi_host_process(ref,input,expected,n));process(a,input,output,n,BUFFER_VALID,NULL);for(unsigned x=0;x<n*ch;x++)CHECK(isfinite(output[x])&&fabsf(output[x]-expected[x])<1e-6f);pos+=n;
    }
    dspi_host_destroy(ref);CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);free(bytes);
    printf("PASS sample WAV: %u frames, %u Hz, DSP reference match\n",frames,rate);
}
/* Separate process for the managed/Console test. Only the pump invokes
   APOProcess; stdin/stdout and file control stay on non-audio threads. */
static int bridge_host(const char *dllpath,const char *rootarg,const char *keyarg){
    wchar_t root[1900],key[65];
    CHECK(MultiByteToWideChar(CP_ACP,0,rootarg,-1,root,1900)>0);
    CHECK(MultiByteToWideChar(CP_ACP,0,keyarg,-1,key,65)>0);
    HMODULE dll=LoadLibraryA(dllpath);CHECK(dll);
    HRESULT (WINAPI *get)(REFCLSID,REFIID,void**)=(void*)GetProcAddress(dll,"DllGetClassObject");CHECK(get);
    IClassFactory *factory=NULL;CHECK(get(&CLSID_DspiApo,&IID_IClassFactory,(void**)&factory)==S_OK);
    Instance a=instance(factory);CHECK(a.ctl->lpVtbl->BindProfile(a.ctl,root,key)==S_OK);
    CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);Media m=media(44100,2);CHECK(lock(a,&m,1024)==S_OK);
    Pump p={a,0,0,0};HANDLE thread=CreateThread(NULL,0,pump,&p,0,NULL);CHECK(thread);
    puts("READY");fflush(stdout);
    char command[64];while(fgets(command,sizeof command,stdin)){
        if(!strncmp(command,"stop",4))break;
        if(!strncmp(command,"sample",6)){LONG bits=InterlockedCompareExchange(&p.last,0,0);float value;memcpy(&value,&bits,4);printf("SAMPLE %.9g\n",value);fflush(stdout);}
    }
    InterlockedExchange(&p.stop,1);CHECK(WaitForSingleObject(thread,3000)==WAIT_OBJECT_0);CloseHandle(thread);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);IClassFactory_Release(factory);FreeLibrary(dll);return 0;
}
/* Endpoint gain is already applied by Windows. It should only affect the shelves. */
static void endpoint_loudness_test(void){
    DspiGraph *graph=dspi_graph_create(44100,2,2);
    CHECK(graph&&dspi_graph_loudness(graph,54.2f,100,3));
    LoudnessCoeffs flat[2],expected[2];
    memcpy(flat,graph->loudness,sizeof flat);
    dspi_graph_loudness_endpoint_volume(graph,-24);
    dspi_loudness_design(36,54.2f,100,44100,expected);
    CHECK(memcmp(flat,graph->loudness,sizeof flat)!=0);
    CHECK(memcmp(expected,graph->loudness,sizeof expected)==0);
    CHECK(graph->volume_step==60&&graph->volume_gain==1);
    CHECK(dspi_graph_volume(graph,-6));
    float gain=graph->volume_gain;
    dspi_graph_loudness_endpoint_volume(graph,-24);
    dspi_loudness_design(30,54.2f,100,44100,expected);
    CHECK(memcmp(expected,graph->loudness,sizeof expected)==0);
    CHECK(graph->volume_step==54&&graph->volume_gain==gain);
    dspi_graph_destroy(graph);
}
int main(int argc,char **argv){
    endpoint_loudness_test();
    if(argc==5&&!strcmp(argv[1],"--bridge"))return bridge_host(argv[2],argv[3],argv[4]);
    const char *path=argc>1?argv[1]:"build/dspi-apo.dll";
    HMODULE dll=LoadLibraryA(path);CHECK(dll);
    HRESULT (WINAPI *get)(REFCLSID,REFIID,void**)=(void*)GetProcAddress(dll,"DllGetClassObject");
    HRESULT (WINAPI *unload)(void)=(void*)GetProcAddress(dll,"DllCanUnloadNow");CHECK(get&&unload);CHECK(unload()==S_OK);
    IClassFactory *f=NULL;CHECK(get(&CLSID_DspiApo,&IID_IClassFactory,(void**)&f)==S_OK);CHECK(unload()==S_FALSE);
    CHECK(IClassFactory_CreateInstance(f,(IUnknown*)f,&DSPI_IID_APO,(void**)&(void*){0})==CLASS_E_NOAGGREGATION);
    IUnknown *inner=NULL,*identity=NULL;IAudioProcessingObject *aggregated=NULL;
    CHECK(IClassFactory_CreateInstance(f,(IUnknown*)f,&IID_IUnknown,(void**)&inner)==S_OK&&inner!=(IUnknown*)f);
    CHECK(IUnknown_QueryInterface(inner,&DSPI_IID_APO,(void**)&aggregated)==S_OK);
    CHECK(IAudioProcessingObject_QueryInterface(aggregated,&IID_IUnknown,(void**)&identity)==S_OK&&identity==(IUnknown*)f);
    IUnknown_Release(identity);IAudioProcessingObject_Release(aggregated);CHECK(IUnknown_Release(inner)==0);
    live_test(f);
    Instance a=instance(f);Media m=media(48000,2),bad=media(48000,9),other=media(44100,2);
    IUnknown *u,*v;CHECK(IAudioProcessingObject_QueryInterface(a.apo,&IID_IUnknown,(void**)&u)==S_OK);
    CHECK(IAudioProcessingObjectRT_QueryInterface(a.rt,&IID_IUnknown,(void**)&v)==S_OK);CHECK(u==v);IUnknown_Release(u);IUnknown_Release(v);
    IAudioSystemEffects *fx;CHECK(IAudioProcessingObject_QueryInterface(a.apo,&DSPI_IID_FX,(void**)&fx)==S_OK);IAudioSystemEffects_Release(fx);
    APO_REG_PROPERTIES *props=NULL;CHECK(IAudioProcessingObject_GetRegistrationProperties(a.apo,&props)==S_OK);CHECK(props&&props->u32MaxInputConnections==1&&!(props->Flags&APO_FLAG_INPLACE));CoTaskMemFree(props);
    CHECK(lock(a,&m,1024)==APOERR_NOT_INITIALIZED);
    CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);
    CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==APOERR_ALREADY_INITIALIZED);
    IAudioMediaType *supported=NULL;
    CHECK(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,&m.iface,&supported)==S_OK);CHECK(supported==&m.iface&&m.refs==2);IAudioMediaType_Release(supported);
    CHECK(FAILED(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,&bad.iface,&supported)));
    CHECK(FAILED(IAudioProcessingObject_IsInputFormatSupported(a.apo,&other.iface,&m.iface,&supported)));
    CHECK(FAILED(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,NULL,&supported)));
    CHECK(lock(a,&bad,1024)==APOERR_INVALID_CONNECTION_FORMAT);
    CHECK(lock(a,&m,1024)==S_OK);CHECK(lock(a,&m,1024)==APOERR_APO_LOCKED);
    HNSTIME latency=-1;CHECK(IAudioProcessingObject_GetLatency(a.apo,&latency)==S_OK&&latency==70000);
    float in[2048]={.5f},out[2048];APO_BUFFER_FLAGS flags;
    process(a,NULL,out,1024,BUFFER_SILENT,&flags);CHECK(flags==BUFFER_SILENT);for(unsigned x=0;x<2048;x++)CHECK(out[x]==0);
    in[0]=NAN;process(a,in,out,1024,BUFFER_VALID,&flags);CHECK(flags==BUFFER_SILENT);for(unsigned x=0;x<2048;x++)CHECK(isfinite(out[x]));
    process(a,NULL,out,1024,BUFFER_INVALID,&flags);CHECK(flags==BUFFER_INVALID);
    CHECK(IAudioProcessingObjectRT_CalcInputFrames(a.rt,123)==123);CHECK(IAudioProcessingObjectRT_CalcOutputFrames(a.rt,123)==123);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);
    /* Negotiation failures preserve the caller's supported-format pointer. */
    a=instance(f);Media invalid=m;
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"--upmix\npassive")==S_OK);
    Media high=media(96000,2),mono=media(48000,1);
    CHECK(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,&high.iface,NULL)==APOERR_FORMAT_NOT_SUPPORTED);
    CHECK(IAudioProcessingObject_IsOutputFormatSupported(a.apo,NULL,&mono.iface,NULL)==APOERR_FORMAT_NOT_SUPPORTED);
    CHECK(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,&m.iface,NULL)==S_OK);
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"")==S_OK);
    invalid.f.fFramesPerSecond=NAN;supported=(void*)(uintptr_t)1;
    CHECK(IAudioProcessingObject_IsInputFormatSupported(a.apo,NULL,&invalid.iface,&supported)==APOERR_FORMAT_NOT_SUPPORTED&&supported==(void*)(uintptr_t)1);
    invalid=m;invalid.f.dwBytesPerSampleContainer=2;CHECK(FAILED(IAudioProcessingObject_IsOutputFormatSupported(a.apo,NULL,&invalid.iface,NULL)));
    invalid=m;invalid.f.dwChannelMask=1;CHECK(FAILED(IAudioProcessingObject_IsOutputFormatSupported(a.apo,NULL,&invalid.iface,NULL)));
    CHECK(IAudioProcessingObject_Initialize(a.apo,1,NULL)==E_POINTER);CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"--unknown")==S_OK);CHECK(FAILED(lock(a,&m,1024)));
    CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"--limiter\n-6\n100")==S_OK);CHECK(lock(a,&m,1024)==S_OK);
    CHECK(IAudioProcessingObject_GetLatency(a.apo,&latency)==S_OK&&latency==70000);
    APO_CONNECTION_PROPERTY pi={(UINT_PTR)in,1025,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE},po={(UINT_PTR)out,99,BUFFER_VALID,APO_CONNECTION_PROPERTY_SIGNATURE};
    APO_CONNECTION_PROPERTY *pip=&pi,*pop=&po;out[0]=.75f;
    IAudioProcessingObjectRT_APOProcess(a.rt,1,&pip,1,&pop);CHECK(po.u32ValidFrameCount==0&&po.u32BufferFlags==BUFFER_INVALID&&out[0]==.75f);
    pi.u32ValidFrameCount=0;IAudioProcessingObjectRT_APOProcess(a.rt,1,&pip,1,&pop);CHECK(po.u32ValidFrameCount==0&&po.u32BufferFlags==BUFFER_SILENT);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);
    if(argc>2)sample_wav(f,argv[2]);
    const unsigned rates[]={44100,48000,96000},channels[]={1,2,8};
    for(unsigned r=0;r<3;r++)for(unsigned c=0;c<3;c++)for(int alias=0;alias<2;alias++)compare(f,rates[r],channels[c],"--gain\n-6",alias);
    compare(f,48000,2,"--input-delay\n3\n--delay\n7\n--limiter\n-6\n100",0);
    compare(f,44100,2,"--peak\n1000\n.7\n6",0);
    compare(f,48000,2,"--tube\n12ax7\n6\n50\n--crossfeed\ndefault\n--psybass\n80\n-6\n6\n50\n0\n--subharm\n-12\n-12\n-30\n0\n--leveller\n50\nfast\n12\n--upmix\npassive",1);
    /* A delayed impulse emerges even when subsequent input is flagged SILENT. */
    a=instance(f);CHECK(a.ctl->lpVtbl->SetRecipe(a.ctl,"--delay\n1")==S_OK);CHECK(IAudioProcessingObject_Initialize(a.apo,0,NULL)==S_OK);CHECK(lock(a,&m,1024)==S_OK);
    memset(in,0,sizeof in);in[0]=.5f;process(a,in,out,1,BUFFER_VALID,NULL);process(a,NULL,out,512,BUFFER_SILENT,&flags);CHECK(flags==BUFFER_VALID&&out[(336+47)*2]==.5f);
    for(unsigned f=0;f<512;f++)if(f!=336+47)CHECK(out[f*2]==0);
    CHECK(IAudioProcessingObjectConfiguration_UnlockForProcess(a.cfg)==S_OK);destroy(a);
    CHECK(IClassFactory_LockServer(f,TRUE)==S_OK);IClassFactory_Release(f);CHECK(unload()==S_FALSE);
    CHECK(get(&CLSID_DspiApo,&IID_IClassFactory,(void**)&f)==S_OK);CHECK(IClassFactory_LockServer(f,FALSE)==S_OK);IClassFactory_Release(f);CHECK(unload()==S_OK);
    FreeLibrary(dll);printf("PASS standalone APO: %u checks (COM, format, DSP reference, reset, tails, aliasing)\n",checks);return 0;
}
