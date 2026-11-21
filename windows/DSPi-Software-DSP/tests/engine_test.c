#include "../src/engine.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(expr) do { if (!(expr)) { printf("FAIL line %d: %s\n", __LINE__, #expr); failures++; } } while(0)
static void tone(float *a, unsigned n) {
    for(unsigned i=0;i<n;i++) a[i]=(float)(0.1*sin(6.283185307179586*1000*i/48000));
}
int main(void) {
    /* Catches wrong coefficient normalization, empty processing, or sign errors. */
    float input[48000], output[48000];
    tone(input,48000); memcpy(output,input,sizeof input);
    Filter f={0};
    CHECK(dspi_peak(&f,48000,1000,0.707,6));
    CHECK(f.use_svf); /* Firmware selects SVF below Fs/7.5. */
    dspi_process(&f,output,48000);
    double a=0,b=0;
    for(unsigned i=24000;i<48000;i++) { a+=input[i]*input[i]; b+=output[i]*output[i]; }
    double gain=10*log10(b/a);
    printf("Measured 1 kHz gain: %.6f dB (expected +6 dB)\n",gain);
    CHECK(fabs(gain-6)<0.005);
    /* Catches lost state at callback boundaries and unrolled-loop tails. */
    Filter split={0}; CHECK(dspi_peak(&split,48000,1000,0.707,6));
    float chunks[48000]; memcpy(chunks,input,sizeof input);
    for(unsigned i=0;i<48000;) { unsigned n=127; if(n>48000-i)n=48000-i;
        dspi_process(&split,chunks+i,n); i+=n; }
    CHECK(memcmp(chunks,output,sizeof output)==0);
    /* Catches zero-gain coloration, wrong bypass, and invalid recipe acceptance. */
    CHECK(dspi_peak(&f,48000,1000,0.707,0));
    memcpy(output,input,sizeof input); dspi_process(&f,output,48000);
    for(unsigned i=0;i<48000;i++) CHECK(fabs(output[i]-input[i])<0.000002);
    CHECK(dspi_peak(&f,48000,1000,0.707,6)); f.bypass=true;
    memcpy(output,input,sizeof input); dspi_process(&f,output,48000);
    CHECK(memcmp(output,input,sizeof input)==0);
    Filter before=f;
    CHECK(!dspi_peak(&f,48000,24000,0.707,6));
    CHECK(!dspi_peak(&f,48000,1000,0,6));
    CHECK(!dspi_peak(&f,NAN,1000,1,6));
    CHECK(!dspi_peak(&f,48000,1000,1,INFINITY));
    CHECK(memcmp(&f,&before,sizeof f)==0);
    printf("%s: %d failed checks\n",failures?"FAIL":"PASS",failures);
    return failures?1:0;
}
