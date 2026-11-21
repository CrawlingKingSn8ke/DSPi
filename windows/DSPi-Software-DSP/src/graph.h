/* GPL-3.0. Host routing/gain/delay around the firmware filter stages. */
#ifndef DSPI_HOST_GRAPH_H
#define DSPI_HOST_GRAPH_H
#include "engine.h"
#include "loudness_host.h"
#include "tube_host.h"
#include "../vendor/dspi/crossfeed.h"
#include "limiter_host.h"
#include "../vendor/dspi/psybass.h"
#include "../vendor/dspi/subharm.h"
#include "../vendor/dspi/leveller.h"
#include "upmix_host.h"
#define DSPI_MAX_CHANNELS 8
#define DSPI_MAX_DELAY_MS 170
#define DSPI_BLOCK_FRAMES 256
typedef struct {
    uint64_t revision; /* immutable once submitted to runtime */
    unsigned inputs,outputs;
    float rate;
    DspiChannel channel[DSPI_MAX_CHANNELS];
    DspiChannel input_channel[DSPI_MAX_CHANNELS];
    float input_gain[DSPI_MAX_CHANNELS];
    uint32_t input_delay_samples[DSPI_MAX_CHANNELS],input_position[DSPI_MAX_CHANNELS];
    float *input_delay_line[DSPI_MAX_CHANNELS];
    float route[DSPI_MAX_CHANNELS][DSPI_MAX_CHANNELS]; /* [input][output] */
    float gain[DSPI_MAX_CHANNELS];
    bool mute[DSPI_MAX_CHANNELS];
    unsigned volume_step;
    float volume_gain,reference_spl,intensity,master_gain;
    uint8_t loudness_mask;
    LoudnessCoeffs loudness[LOUDNESS_BIQUAD_COUNT];
    LoudnessOutputState loudness_state[DSPI_MAX_CHANNELS];
    TubeConfig tube;
    TubeCoeffs tube_coeffs;
    TubeOutputState tube_state[DSPI_MAX_CHANNELS];
    CrossfeedConfig crossfeed;
    CrossfeedCoeffs crossfeed_coeffs;
    CrossfeedPairState crossfeed_state[DSPI_MAX_CHANNELS/2];
    DspiLimiter *limiter;
    PsybassConfig psybass;
    PsybassCoeffs psybass_coeffs;
    PsybassOutputState psybass_state[DSPI_MAX_CHANNELS];
    SubharmConfig subharm;
    SubharmCoeffs subharm_coeffs;
    SubharmOutputState subharm_state[DSPI_MAX_CHANNELS];
    uint8_t subharm_phase;
    LevellerConfig leveller;
    LevellerCoeffs leveller_coeffs;
    LevellerState leveller_state;
    UpmixConfig upmix;
    DspiUpmixer *upmixer;
    /* Fixed 48-frame input adapter; one quantum of latency when in use. */
    unsigned control_pos;
    float control_in[DSPI_MAX_CHANNELS][48],control_out[DSPI_MAX_CHANNELS][48];
    float sources[DSPI_MAX_CHANNELS][DSPI_BLOCK_FRAMES];
    uint32_t delay_samples[DSPI_MAX_CHANNELS],position[DSPI_MAX_CHANNELS],capacity;
    float *delay[DSPI_MAX_CHANNELS];
    float work[DSPI_MAX_CHANNELS][DSPI_BLOCK_FRAMES];
    unsigned padding_frames,padding_position;
    float *padding_delay;
} DspiGraph;
/* Create/destroy and settings run outside processing. Default routing is identity. */
DspiGraph *dspi_graph_create(float rate,unsigned inputs,unsigned outputs);
void dspi_graph_destroy(DspiGraph *graph);
void dspi_graph_clear_routes(DspiGraph *graph);
bool dspi_graph_route(DspiGraph *graph,unsigned input,unsigned output,float db,bool invert,bool enabled);
bool dspi_graph_gain(DspiGraph *graph,unsigned output,float db);
bool dspi_graph_delay(DspiGraph *graph,unsigned output,float ms);
bool dspi_graph_mute(DspiGraph *graph,unsigned output,bool mute);
/* Physical input controls, before leveller/upmix/matrix. Static settings only. */
bool dspi_graph_input_preamp(DspiGraph *graph,unsigned input,float db);
bool dspi_graph_input_delay(DspiGraph *graph,unsigned input,float ms);
bool dspi_graph_input_eq(DspiGraph *graph,unsigned input,unsigned band,uint8_t type,
                         float hz,float q,float gain_or_fp,float target_q,bool bypass);
bool dspi_graph_input_eq_clear(DspiGraph *graph,unsigned input);
void dspi_graph_process_inputs(DspiGraph *graph,const float *const *in,uint32_t offset,uint32_t count);
/* Listening volume: -60 (silence) to 0 dB in firmware-style 1 dB steps.
 * Loudness follows this global control, not per-output gain or signal level. */
bool dspi_graph_volume(DspiGraph *graph,float db);
bool dspi_graph_master_gain(DspiGraph *graph,float db);
bool dspi_graph_loudness(DspiGraph *graph,float reference_spl,float intensity,uint8_t output_mask);
void dspi_graph_loudness_endpoint_volume(DspiGraph *graph,int db);
bool dspi_graph_tube(DspiGraph *graph,const TubeConfig *config);
bool dspi_graph_crossfeed(DspiGraph *graph,const CrossfeedConfig *config);
bool dspi_graph_limiter(DspiGraph *graph,unsigned output,const LimiterOutputConfig *config);
bool dspi_graph_psybass(DspiGraph *graph,const PsybassConfig *config);
bool dspi_graph_subharm(DspiGraph *graph,const SubharmConfig *config);
bool dspi_graph_leveller(DspiGraph *graph,const LevellerConfig *config);
bool dspi_graph_upmix(DspiGraph *graph,const UpmixConfig *config);
unsigned dspi_graph_sources(const DspiGraph *graph);
/* Common adapter + leveller lookahead only; excludes per-input/output delays. */
unsigned dspi_graph_input_latency(const DspiGraph *graph);
/* Internal stages, preallocated and allocation-free. */
void dspi_graph_prepare_inputs(DspiGraph *graph,const float *const *in,uint32_t offset,uint32_t count);
void dspi_graph_subharm_process(DspiGraph *graph,uint32_t count);
/* Planar float buffers; no allocations/locks in processing. Caller owns buffers.
 * Buffers must not overlap. Count may exceed the internal chunk size. */
bool dspi_graph_process(DspiGraph *graph,const float *const *inputs,float *const *outputs,uint32_t count);
void dspi_graph_reset(DspiGraph *g);
#endif
