#ifndef DSP_BIQUAD_H
#define DSP_BIQUAD_H

#include "config.h"

#if PICO_RP2350
static inline void dsp_biquad_first_order(Filter * __restrict f, float * __restrict samples, uint32_t count) {
    // Load biquad coefficients
    // Assumption is that b2 and a2 are 0.0f
    float b0 = f->b0, b1 = f->b1;
    float a1 = f->a1;
    float s1 = f->s1, s2 = f->s2;
    float *sp = samples;
    float x, y, t;
    uint32_t blk_count = count >> 2; // unroll loops by 4

    switch(f->filter_type) {
        case FILTER_ALLPASS1:
            //optimise b1=1.0f, (b0=a1)
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = x - a1 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = x - a1 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = x - a1 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = x - a1 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = x - a1 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        case FILTER_LOWPASS1:
            //optimise b0=b1
            while(blk_count > 0) {
                x = sp[0];
                t = b0 * x;
                y = t + s1;
                s1 = t - a1 * y;
                sp[0] = y;

                x = sp[1];
                t = b0 * x;
                y = t + s1;
                s1 = t - a1 * y;
                sp[1] = y;

                x = sp[2];
                t = b0 * x;
                y = t + s1;
                s1 = t - a1 * y;
                sp[2] = y;

                x = sp[3];
                t = b0 * x;
                y = t + s1;
                s1 = t - a1 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                t = b0 * x;
                y = t + s1;
                s1 = t - a1 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        default:
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y;
                *sp++ = y;
                blk_count--;
            }
            break;
    }

    f->s1 = s1;
    f->s2 = 0.0f;
}

static inline void dsp_biquad_second_order(Filter * __restrict f, float * __restrict samples, uint32_t count) {
    // Load biquad coefficients
    float b0 = f->b0, b1 = f->b1, b2 = f->b2;
    float a1 = f->a1, a2 = f->a2;
    float s1 = f->s1, s2 = f->s2;
    float *sp = samples;
    float x, y;
    uint32_t blk_count = count >> 2; // unroll loops by 4

    switch(f->filter_type) {
        case FILTER_LOWPASS:
        case FILTER_HIGHPASS:
            //optimise b0 = b2
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b0 * x - a2 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b0 * x - a2 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b0 * x - a2 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b0 * x - a2 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b0 * x - a2 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        case FILTER_PEAKING:
            // optimise b1 = a1
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b2 * x - a2 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b2 * x - a2 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b2 * x - a2 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b2 * x - a2 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b2 * x - a2 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        case FILTER_ALLPASS:
            // optimise b1 = a1
            // optimise a0 = b2, a0 is normalised to 1.0f so b2 is implicitly 1.0f
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = x - a2 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = x - a2 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = x - a2 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = x - a2 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = x - a2 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        case FILTER_NOTCH:
            // optimise b0=b2, b1=a1
           while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b0 * x - a2 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b0 * x - a2 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b0 * x - a2 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b0 * x - a2 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * (x - y) + s2;
                s2 = b0 * x - a2 * y;
                *sp++ = y;
                blk_count--;
            }
            break;

        default:
            while(blk_count > 0) {
                x = sp[0];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b2 * x - a2 * y;
                sp[0] = y;

                x = sp[1];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b2 * x - a2 * y;
                sp[1] = y;

                x = sp[2];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b2 * x - a2 * y;
                sp[2] = y;

                x = sp[3];
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b2 * x - a2 * y;
                sp[3] = y;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                y = b0 * x + s1;
                s1 = b1 * x - a1 * y + s2;
                s2 = b2 * x - a2 * y;
                *sp++ = y;
                blk_count--;
            }
            break;
    }

    f->s1 = s1;
    f->s2 = s2;
}

// Fused two-section cascade: each sample is loaded once, pushed through both
// sections in registers, and stored once.  Generic TDF2 for both sections; the
// per-type cases above only exploit coefficient equalities, so output differs
// from two single sweeps by rounding at most.
static inline void dsp_biquad_second_order_x2(Filter * __restrict f0, Filter * __restrict f1,
                                              float * __restrict samples, uint32_t count) {
    float b0_0 = f0->b0, b1_0 = f0->b1, b2_0 = f0->b2;
    float a1_0 = f0->a1, a2_0 = f0->a2;
    float s1_0 = f0->s1, s2_0 = f0->s2;
    float b0_1 = f1->b0, b1_1 = f1->b1, b2_1 = f1->b2;
    float a1_1 = f1->a1, a2_1 = f1->a2;
    float s1_1 = f1->s1, s2_1 = f1->s2;
    float *sp = samples;
    float x, y, z;
    uint32_t blk_count = count >> 2; // unroll loops by 4

    while(blk_count > 0) {
        x = sp[0];
        y = b0_0 * x + s1_0;
        s1_0 = b1_0 * x - a1_0 * y + s2_0;
        s2_0 = b2_0 * x - a2_0 * y;
        z = b0_1 * y + s1_1;
        s1_1 = b1_1 * y - a1_1 * z + s2_1;
        s2_1 = b2_1 * y - a2_1 * z;
        sp[0] = z;

        x = sp[1];
        y = b0_0 * x + s1_0;
        s1_0 = b1_0 * x - a1_0 * y + s2_0;
        s2_0 = b2_0 * x - a2_0 * y;
        z = b0_1 * y + s1_1;
        s1_1 = b1_1 * y - a1_1 * z + s2_1;
        s2_1 = b2_1 * y - a2_1 * z;
        sp[1] = z;

        x = sp[2];
        y = b0_0 * x + s1_0;
        s1_0 = b1_0 * x - a1_0 * y + s2_0;
        s2_0 = b2_0 * x - a2_0 * y;
        z = b0_1 * y + s1_1;
        s1_1 = b1_1 * y - a1_1 * z + s2_1;
        s2_1 = b2_1 * y - a2_1 * z;
        sp[2] = z;

        x = sp[3];
        y = b0_0 * x + s1_0;
        s1_0 = b1_0 * x - a1_0 * y + s2_0;
        s2_0 = b2_0 * x - a2_0 * y;
        z = b0_1 * y + s1_1;
        s1_1 = b1_1 * y - a1_1 * z + s2_1;
        s2_1 = b2_1 * y - a2_1 * z;
        sp[3] = z;

        sp += 4;
        blk_count--;
    }

    blk_count = count & 0x3;
    while(blk_count > 0) {
        x = *sp;
        y = b0_0 * x + s1_0;
        s1_0 = b1_0 * x - a1_0 * y + s2_0;
        s2_0 = b2_0 * x - a2_0 * y;
        z = b0_1 * y + s1_1;
        s1_1 = b1_1 * y - a1_1 * z + s2_1;
        s2_1 = b2_1 * y - a2_1 * z;
        *sp++ = z;
        blk_count--;
    }

    f0->s1 = s1_0;
    f0->s2 = s2_0;
    f1->s1 = s1_1;
    f1->s2 = s2_1;
}

#endif // PICO_RP2350

#endif // DSP_BIQUAD_H
