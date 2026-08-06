#ifndef DSP_CASCADE_H
#define DSP_CASCADE_H

#include "config.h"

#if PICO_RP2350
// Runs a filter cascade over a sample block, fusing each pair of adjacent
// active second-order sections on the same path into one buffer sweep.
// Out-of-line and shared by the PEQ and crossover kernels so the unrolled
// bodies are emitted into RAM once.  Defined in dsp_pipeline.c; see
// Documentation/current_architecture.md.
void dsp_cascade_block(Filter * __restrict sections, uint32_t num_sections,
                       float * __restrict samples, uint32_t count);
#endif // PICO_RP2350

#endif // DSP_CASCADE_H
