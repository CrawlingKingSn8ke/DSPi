#ifndef DSPI_HOST_ENGINE_H
#define DSPI_HOST_ENGINE_H
#include "../vendor/dspi/config.h"
#include "../vendor/dspi/crossover.h"
typedef struct {
    float sample_rate;
    Filter peq[MAX_BANDS];
    XoverFilter crossover[MAX_XOVER_BANDS];
} DspiChannel;
bool dspi_channel_init(DspiChannel *channel,float rate);
bool dspi_set_peq(DspiChannel *channel,unsigned band,uint8_t type,float hz,
                  float q,float gain_or_fp,float target_q,bool bypass);
bool dspi_set_crossover(DspiChannel *channel,unsigned band,uint8_t type,float hz,bool bypass);
void dspi_channel_process(DspiChannel *channel,float *samples,uint32_t count);
/* Configure one independent channel. Invalid parameters leave it untouched. */
bool dspi_peak(Filter *filter, double rate, double hz, double q, double gain_db);
void dspi_process(Filter *filter, float *samples, uint32_t count);
#endif
