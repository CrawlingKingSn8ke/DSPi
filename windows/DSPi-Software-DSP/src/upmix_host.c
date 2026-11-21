#include "upmix_host.h"
#include <stdlib.h>
#include "../build/upmix_kernel.inc"
struct DspiUpmixer { UpmixState state; UpmixCoeffs coeffs; };
DspiUpmixer *dspi_upmix_create(void){return calloc(1,sizeof(DspiUpmixer));}
void dspi_upmix_destroy(DspiUpmixer *u){free(u);}
void dspi_upmix_reset_state(DspiUpmixer *u){if(u)memset(&u->state,0,sizeof u->state);}
void dspi_upmix_configure(DspiUpmixer *u,const UpmixConfig *c,float rate){
    memset(&u->state,0,sizeof u->state);upmix_compute_coefficients(&u->coeffs,c,rate);
}
void dspi_upmix_process(DspiUpmixer *u,float bus[8][48]){
    host_upmix_process_block(&u->state,&u->coeffs,bus[0],bus[1],bus[2],bus[3],bus[4],48);
}
UpmixConfig dspi_upmix_defaults(void){return (UpmixConfig){false,UPMIX_DEFAULT_CENTER_MODE,UPMIX_DEFAULT_SURROUND_MODE,
    UPMIX_DEFAULT_STRENGTH,UPMIX_DEFAULT_WIDTH,UPMIX_DEFAULT_THRESH,UPMIX_DEFAULT_ATTACK,UPMIX_DEFAULT_RELEASE,
    UPMIX_DEFAULT_DET_HPF,UPMIX_DEFAULT_SUR_DELAY,UPMIX_DEFAULT_SUR_HPF,UPMIX_DEFAULT_SUR_LPF,UPMIX_DEFAULT_DECORR,UPMIX_DEFAULT_PRESENCE};}
