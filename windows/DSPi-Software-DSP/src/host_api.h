/* GPL-3.0. Control-thread graph ownership and one processing-thread runtime. */
#ifndef DSPI_HOST_API_H
#define DSPI_HOST_API_H
#include <stdint.h>
#ifdef _WIN32
#define DSPI_API __declspec(dllexport)
#else
#define DSPI_API
#endif
/* Newline-delimited recipe tokens. No paths, <=262144 bytes/4096 tokens.
 * Prepare is control-thread only and returns a fully validated graph or NULL. */
DSPI_API void *dspi_host_prepare(float rate,unsigned inputs,unsigned outputs,const char *tokens);
/* Windows audio graphs add compensation to keep their reported latency stable. */
void *dspi_host_prepare_fixed_latency(float rate,unsigned inputs,unsigned outputs,const char *tokens);
unsigned dspi_host_graph_latency(const void *graph);
DSPI_API void dspi_host_graph_destroy(void *graph);
/* create/submit take ownership only on success. Same rate/topology for edits.
 * New graphs warm before taking over. Equal processing latencies crossfade
 * directly. Other host transitions fade through zero. Replaced graphs are
 * reclaimed by submit/collect on the control thread */
DSPI_API void *dspi_host_create(void *graph,unsigned ramp_samples);
DSPI_API int dspi_host_submit(void *runtime,void *graph);
DSPI_API void dspi_host_graph_revision(void *graph,uint64_t revision);
DSPI_API uint64_t dspi_host_active_revision(void *runtime);
/* Request reset; only the processing caller dereferences owned live graphs. */
DSPI_API void dspi_host_reset(void *runtime);
DSPI_API void dspi_host_collect(void *runtime);
/* Single processing caller; interleaved, finite audio, non-overlapping arrays.
 * No allocation/free/locks. Destruction requires processing has stopped. */
DSPI_API int dspi_host_process(void *runtime,const float *input,float *output,uint32_t frames);
/* Peak maxima since last read, input clips bits0..7, output clips bits8..15.
 * One meter reader; read resets peaks and clip flags. Buffers each hold8 floats. */
DSPI_API void dspi_host_meters(void *runtime,float *input_peaks,float *output_peaks,uint32_t *clips);
DSPI_API void dspi_host_destroy(void *runtime);
#endif
