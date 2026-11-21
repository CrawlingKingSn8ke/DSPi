#ifndef DSPI_HOST_LOUDNESS_H
#define DSPI_HOST_LOUDNESS_H
#include "../vendor/dspi/loudness.h"
/* Extracted firmware designer, called only during configuration. Step 0..60. */
void dspi_loudness_design(int step,float reference_spl,float intensity,float rate,LoudnessCoeffs out[2]);
#endif
