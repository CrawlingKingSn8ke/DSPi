/* Host scalar section dispatcher, GPL-3.0. No ARM fused assembly. */
#ifndef DSPI_HOST_CASCADE_H
#define DSPI_HOST_CASCADE_H
#include "config.h"
void dsp_cascade_block(Filter *sections,uint32_t num_sections,float *samples,uint32_t count);
#endif
