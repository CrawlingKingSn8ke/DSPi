/* Host compatibility declarations, GPL-3.0; not the Pico pipeline header. */
#ifndef DSPI_HOST_PIPELINE_H
#define DSPI_HOST_PIPELINE_H
#include "config.h"
/* Configuration uses a per-thread temporary LT-Q slot; processing never reads it. */
extern _Thread_local uint16_t peq_qp_x512[NUM_CHANNELS][MAX_BANDS];
void dsp_compute_coefficients(EqParamPacket *p, Filter *f, float sample_rate);
#endif
