/* GPL-3.0. Offline PCM16 WAV harness; no Windows device or routing changes. */
#include "graph.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <ctype.h>
static unsigned u16(const unsigned char *p) { return p[0]|((unsigned)p[1]<<8); }
static uint32_t u32(const unsigned char *p) {
    return p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static void put16(unsigned char *p,unsigned v) { p[0]=(unsigned char)v; p[1]=(unsigned char)(v>>8); }
static void put32(unsigned char *p,uint32_t v) { put16(p,v&65535); put16(p+2,v>>16); }
#include "recipe.h"
int main(int argc,char **argv) {
    if(argc<4) {
        fprintf(stderr,"Usage: dspi-wav input.wav new-output.wav frequency-Hz Q gain-dB\n"
            "Or: input.wav new-output.wav [--channel left|right|both] --peak Hz Q dB ...\n"
            "    --filter name Hz Q gain-or-fp   --crossover lr4-lp|bw3-hp|bes4-lp|... Hz\n"
            "    --outputs 1..8 --clear-routes --route input output dB --route-invert input output dB\n"
            "    --channel 1..8|all --gain dB --delay ms --mute --unmute\n"
            "    --input-channel 1..8|left|right|all --preamp -60..12 --input-delay 0..170\n"
            "    --input-peak Hz Q dB --input-filter name Hz Q gain-or-fp --input-eq-clear\n"
            "    --volume -60..0 --loudness reference-SPL intensity-percent --loudness-off\n"
            "    --master-gain -128..12 (independent global trim; -128 mutes)\n"
            "    --tube style drive-dB mix-percent --tube-off (advanced controls in README)\n"
            "    --pair 1..4 --crossfeed default|chumoy|meier --crossfeed-custom Hz feed-dB\n"
            "    --crossfeed-itd on|off --crossfeed-off\n"
            "    --limiter threshold-dBFS release-ms --limiter-link 0..4 --limiter-off\n"
            "    --psybass cutoff-Hz harmonics-dB drive-dB character-percent original-dB\n"
            "    --subharm low-dB high-dB top-dB boost-dB --subharm-solo on|off\n"
            "    --leveller amount-percent slow|medium|fast max-boost-dB\n"
            "    --upmix passive|adaptive (stereo <=48k; route sources 3=C, 4=Ls, 5=Rs)\n"); return 2;
    }
    FILE *in=fopen(argv[1],"rb");
    if(!in) { perror("Input"); return 1; }
    unsigned char header[68]={0},chunk[8],fmt[40];
    static const unsigned char pcm_guid[16]={1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113};
    unsigned channels=0,rate=0; uint32_t data_bytes=0;
    long data_start=-1;
    if(fseek(in,0,SEEK_END)!=0) goto invalid;
    long file_size=ftell(in);
    if(file_size<44 || fseek(in,0,SEEK_SET)!=0 || fread(header,1,12,in)!=12 ||
       memcmp(header,"RIFF",4)||memcmp(header+8,"WAVE",4)) goto invalid;
    uint64_t riff_end=(uint64_t)u32(header+4)+8;
    if(riff_end>(uint64_t)file_size || riff_end<44) goto invalid;
    while((uint64_t)ftell(in)+8<=riff_end) {
        if(fread(chunk,1,8,in)!=8) goto invalid;
        uint32_t size=u32(chunk+4); long start=ftell(in);
        uint64_t next=(uint64_t)start+size+(size&1);
        if(next>riff_end || next>LONG_MAX) goto invalid;
        if(!memcmp(chunk,"fmt ",4)) {
            if(channels || size<16 || fread(fmt,1,16,in)!=16 || u16(fmt+14)!=16) goto invalid;
            if(u16(fmt)==65534){
                if(size<40||fread(fmt+16,1,24,in)!=24||u16(fmt+16)<22||
                   (uint32_t)u16(fmt+16)+18>size||u16(fmt+18)!=16||memcmp(fmt+24,pcm_guid,16))goto invalid;
            }else if(u16(fmt)!=1)goto invalid;
            channels=u16(fmt+2); rate=u32(fmt+4);
            if(!channels||channels>DSPI_MAX_CHANNELS||rate<8000||rate>192000 ||
               u16(fmt+12)!=channels*2 || u32(fmt+8)!=rate*channels*2) goto invalid;
        } else if(!memcmp(chunk,"data",4)) {
            if(data_start>=0) goto invalid;
            data_start=start; data_bytes=size;
        }
        if(fseek(in,(long)next,SEEK_SET)!=0) goto invalid;
    }
    if(!channels||data_start<0||data_bytes%(channels*2)||data_bytes>UINT32_MAX-36) goto invalid;
    unsigned outputs=dspi_recipe_output_count(argc,argv,channels);
    uint32_t frames_total=data_bytes/(channels*2);
    uint64_t output_bytes=(uint64_t)frames_total*outputs*2;
    unsigned header_bytes=outputs>2?68:44;
    if(!outputs||output_bytes>UINT32_MAX-(header_bytes-8)){
        fprintf(stderr,"Invalid output channel count or WAV exceeds RIFF size limit\n");fclose(in);return 2;
    }
    DspiGraph *graph=dspi_graph_create((float)rate,channels,outputs);
    if(!graph){fprintf(stderr,"Cannot allocate audio engine\n");fclose(in);return 1;}
    if(!dspi_recipe_configure(argc,argv,graph)) {
        fprintf(stderr,"Invalid recipe/routing settings; see README\n");
        dspi_graph_destroy(graph);
        fclose(in); return 2;
    }
    if(fseek(in,data_start,SEEK_SET)!=0){dspi_graph_destroy(graph);goto invalid;}
    /* Exclusive creation also protects against input==output and races. */
    FILE *out=fopen(argv[2],"wbx");
    if(!out) { perror("New output (existing files refused)");dspi_graph_destroy(graph); fclose(in); return 1; }
    memcpy(header,"RIFF",4); put32(header+4,header_bytes-8+(uint32_t)output_bytes); memcpy(header+8,"WAVEfmt ",8);
    put32(header+16,outputs>2?40:16);put16(header+20,outputs>2?65534:1);put16(header+22,outputs);
    put32(header+24,rate);put32(header+28,rate*outputs*2);put16(header+32,outputs*2);put16(header+34,16);
    if(outputs>2){
        put16(header+36,22);put16(header+38,16);put32(header+40,0);memcpy(header+44,pcm_guid,16);
    }
    memcpy(header+header_bytes-8,"data",4);put32(header+header_bytes-4,(uint32_t)output_bytes);
    bool ok=fwrite(header,1,header_bytes,out)==header_bytes;
    uint32_t remaining=data_bytes; uint64_t clipped=0;
    unsigned limiter_latency=dspi_limiter_latency(graph->limiter);float max_reduction=0;
    unsigned input_latency=dspi_graph_input_latency(graph);
    uint32_t input_delays[DSPI_MAX_CHANNELS];memcpy(input_delays,graph->input_delay_samples,sizeof input_delays);
    unsigned char raw[DSPI_BLOCK_FRAMES*DSPI_MAX_CHANNELS*2],encoded[sizeof raw];
    float planar[DSPI_MAX_CHANNELS][DSPI_BLOCK_FRAMES],processed[DSPI_MAX_CHANNELS][DSPI_BLOCK_FRAMES];
    const float *input_ptrs[DSPI_MAX_CHANNELS];float *output_ptrs[DSPI_MAX_CHANNELS];
    for(unsigned c=0;c<channels;c++)input_ptrs[c]=planar[c];
    for(unsigned c=0;c<outputs;c++)output_ptrs[c]=processed[c];
    while(ok && remaining) {
        unsigned block_bytes=DSPI_BLOCK_FRAMES*channels*2;
        unsigned bytes=remaining>block_bytes?block_bytes:remaining;
        unsigned frames=bytes/(channels*2);
        if(fread(raw,1,bytes,in)!=bytes) { ok=false; break; }
        for(unsigned c=0;c<channels;c++) {
            for(unsigned n=0;n<frames;n++) {
                unsigned v=u16(raw+(n*channels+c)*2);
                int sample=v>=32768?(int)v-65536:(int)v;
                planar[c][n]=sample/32768.0f;
            }
        }
        if(!dspi_graph_process(graph,input_ptrs,output_ptrs,frames)){ok=false;break;}
        for(unsigned c=0;c<outputs;c++)max_reduction=fmaxf(max_reduction,dspi_limiter_reduction_db(graph->limiter,c));
        for(unsigned n=0;n<frames;n++) for(unsigned c=0;c<outputs;c++) {
            double v=processed[c][n]*32768.0;
            if(!isfinite(v)) { ok=false; v=0; }
            if(v>32767) { v=32767; clipped++; }
            if(v< -32768) { v= -32768; clipped++; }
            int sample=(int)round(v);
            put16(encoded+(n*outputs+c)*2,(unsigned)sample&65535);
        }
        unsigned encoded_bytes=frames*outputs*2;
        if(fwrite(encoded,1,encoded_bytes,out)!=encoded_bytes) ok=false;
        remaining-=bytes;
    }
    if(fclose(out)!=0) ok=false;
    fclose(in);
    dspi_graph_destroy(graph);
    if(!ok) { fprintf(stderr,"I/O or non-finite DSP failure; output may be incomplete\n"); return 1; }
    printf("Processed %u frames, %u input / %u output channels, %u Hz; clipped samples: %llu\n",
           frames_total,channels,outputs,rate,(unsigned long long)clipped);
    if(limiter_latency)printf("Limiter lookahead: %u samples; deepest gain reduction: %.2f dB\n",limiter_latency,max_reduction);
    if(input_latency)printf("Input adapter/lookahead delay: %u samples (%.3f ms); output frame count preserved, tail trimmed\n",input_latency,1000.0*input_latency/rate);
    for(unsigned i=0;i<channels;i++)if(input_delays[i])printf("Input %u alignment delay: %u samples (%.3f ms); tail trimmed\n",i+1,input_delays[i],1000.0*input_delays[i]/rate);
    return 0;
invalid:
    fprintf(stderr,"Unsupported or malformed WAV; requires PCM16 RIFF WAV, 1..8 channels\n");
    fclose(in); return 2;
}
