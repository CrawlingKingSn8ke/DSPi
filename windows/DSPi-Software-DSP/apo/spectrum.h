/* GPL-3.0. Off-callback analysis of the APO's two signal taps. */
#ifndef DSPI_APO_SPECTRUM_H
#define DSPI_APO_SPECTRUM_H
#include <stdint.h>
#include <wchar.h>
typedef struct DspiSpectrum DspiSpectrum;
DspiSpectrum *dspi_spectrum_create(const wchar_t *directory, unsigned rate, unsigned channels, uint64_t id);
void dspi_spectrum_capture(DspiSpectrum *, const float *input, const float *output, unsigned frames);
void dspi_spectrum_tick(DspiSpectrum *);
void dspi_spectrum_destroy(DspiSpectrum *);
#endif

