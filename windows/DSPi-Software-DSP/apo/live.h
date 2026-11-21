/* GPL-3.0. Bounded profile files and off-callback per-instance telemetry. */
#ifndef DSPI_APO_LIVE_H
#define DSPI_APO_LIVE_H
#include <windows.h>
#include <stdint.h>
typedef struct DspiApoLive DspiApoLive;
int dspi_apo_key_valid(const wchar_t *key);
BOOL dspi_apo_endpoint_key(const wchar_t *endpoint,wchar_t key[65]);
/* All filesystem/graph work occurs on setup/worker threads. */
char *dspi_apo_profile(const wchar_t *directory,unsigned rate,unsigned channels,uint64_t *revision,unsigned *error);
DspiApoLive *dspi_apo_live_start(const wchar_t *directory,void *runtime,unsigned rate,unsigned channels,unsigned latency,uint64_t initial);
void dspi_apo_live_processed(DspiApoLive *live,unsigned frames);
void dspi_apo_live_spectrum(DspiApoLive *live,const float *input,const float *output,unsigned frames);
void dspi_apo_live_stop(DspiApoLive *live);
#endif
