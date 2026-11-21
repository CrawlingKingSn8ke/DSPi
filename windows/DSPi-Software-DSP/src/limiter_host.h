/* GPL-3.0. Host lifetime/linking around original firmware limiter kernels. */
#ifndef DSPI_HOST_LIMITER_H
#define DSPI_HOST_LIMITER_H
#include "../vendor/dspi/limiter.h"
typedef struct DspiLimiter DspiLimiter;
DspiLimiter *dspi_limiter_create(float rate,unsigned outputs);
void dspi_limiter_destroy(DspiLimiter *limiter);
bool dspi_limiter_get(const DspiLimiter *limiter,unsigned output,LimiterOutputConfig *config);
bool dspi_limiter_set(DspiLimiter *limiter,unsigned output,const LimiterOutputConfig *config);
unsigned dspi_limiter_latency(const DspiLimiter *limiter);
float dspi_limiter_reduction_db(const DspiLimiter *limiter,unsigned output);
/* At most AUDIO_BUFFER_SAMPLES frames. All output buffers must be available. */
bool dspi_limiter_process(DspiLimiter *limiter,float (*buffers)[AUDIO_BUFFER_SAMPLES],uint32_t count);
#endif
