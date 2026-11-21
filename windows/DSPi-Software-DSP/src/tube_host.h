#ifndef DSPI_HOST_TUBE_H
#define DSPI_HOST_TUBE_H
#include "../vendor/dspi/tube.h"
TubeConfig dspi_tube_defaults(void);
/* Apply the original four character values for style 1..16; 0 keeps custom. */
bool dspi_tube_style(TubeConfig *config,unsigned style);
#endif
