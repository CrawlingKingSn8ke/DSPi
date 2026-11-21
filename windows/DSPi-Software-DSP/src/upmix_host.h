/* GPL-3.0. Per-instance wrapper for the firmware stereo upmixer. */
#ifndef DSPI_UPMIX_HOST_H
#define DSPI_UPMIX_HOST_H
#include "../vendor/dspi/upmix.h"
typedef struct DspiUpmixer DspiUpmixer;
DspiUpmixer *dspi_upmix_create(void);
void dspi_upmix_destroy(DspiUpmixer *u);
void dspi_upmix_configure(DspiUpmixer *u,const UpmixConfig *c,float rate);
void dspi_upmix_process(DspiUpmixer *u,float bus[8][48]);
UpmixConfig dspi_upmix_defaults(void);
#endif
