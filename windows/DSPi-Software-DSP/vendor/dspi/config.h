/* Host-only compatibility subset of DSPi config.h (GPL-3.0).
 * This is NOT the firmware config.h or a Pico SDK replacement.
 * Only the float Filter and PEQ enum required by the unchanged kernels.
 */
#ifndef DSPI_HOST_CONFIG_H
#define DSPI_HOST_CONFIG_H
#include <stdint.h>
#include <stdbool.h>
#define PICO_RP2350 1
#define DSP_TIME_CRITICAL
#define NUM_CHANNELS 2
#define NUM_INPUT_CHANNELS 8
#define NUM_STEREO_INPUTS 2
#define FILTER_SHIFT 28
#define NUM_OUTPUT_CHANNELS 2
#define CH_OUT_1 0
#define MAX_BANDS 10
#define MAX_XOVER_BANDS 4
#define XOVER_BAND_BASE 20
/* Required by unused firmware dispatcher declarations; host owns actual state. */
#define AUDIO_BUFFER_SAMPLES 256
#define NUM_SPDIF_INSTANCES 4
typedef struct {
    float b0, b1, b2, a1, a2;
    float s1, s2;
    float sva1, sva2, sva3;
    float svm0, svm1, svm2;
    float svic1eq, svic2eq;
    float g;
    uint32_t filter_type;
    bool use_svf, first_order, bypass;
} Filter;
enum FilterType {
    FILTER_FLAT=0, FILTER_PEAKING=1, FILTER_LOWSHELF=2,
    FILTER_HIGHSHELF=3, FILTER_LOWPASS=4, FILTER_HIGHPASS=5,
    FILTER_NOTCH=6, FILTER_ALLPASS=7, FILTER_ALLPASS1=8,
    FILTER_LOWSHELF1=9, FILTER_HIGHSHELF1=10,
    FILTER_LINKWITZ_TRANSFORM=11, FILTER_LOWPASS1=12, FILTER_HIGHPASS1=13,
    FILTER_LR2_LP=32, FILTER_LR2_HP, FILTER_LR4_LP, FILTER_LR4_HP,
    FILTER_LR6_LP, FILTER_LR6_HP, FILTER_LR8_LP, FILTER_LR8_HP,
    FILTER_BW1_LP, FILTER_BW1_HP, FILTER_BW2_LP, FILTER_BW2_HP,
    FILTER_BW3_LP, FILTER_BW3_HP, FILTER_BW4_LP, FILTER_BW4_HP,
    FILTER_BW5_LP, FILTER_BW5_HP, FILTER_BW6_LP, FILTER_BW6_HP,
    FILTER_BW7_LP, FILTER_BW7_HP, FILTER_BW8_LP, FILTER_BW8_HP,
    FILTER_BES2_LP, FILTER_BES2_HP, FILTER_BES4_LP, FILTER_BES4_HP,
    FILTER_BES6_LP, FILTER_BES6_HP, FILTER_BES8_LP, FILTER_BES8_HP,
    FILTER_XOVER_FIRST=32, FILTER_XOVER_LAST=63
};
static inline bool filter_is_peq_type(uint8_t t) { return t<FILTER_XOVER_FIRST; }
typedef struct {
    uint8_t channel, band, type, bypass;
    float freq, Q, gain_db;
} EqParamPacket;
#endif
