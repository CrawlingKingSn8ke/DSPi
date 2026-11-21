#ifndef DSP_SVF_H
#define DSP_SVF_H

#include "config.h"

#if PICO_RP2350
static inline void dsp_svf_first_order(Filter * __restrict f, float * __restrict samples, uint32_t count) {
    // Load SVF coefficients
    float a1 = f->sva1, a2 = f->sva2;
    float m0 = f->svm0, m1 = f->svm1, m2 = f->svm2;
    float ic1eq = f->svic1eq, ic2eq = f->svic2eq;
    float *sp = samples;
    float v0, v1;
    uint32_t blk_count = count >> 2; // unroll loops by 4
    // Per-type specialization: eliminates zero-multiplies in inner loop
    switch (f->filter_type)
    {
        // One-pole TPT SVF: a1 = 1/(1+g), a2 = g/(1+g) (multiply-only).
        case FILTER_LOWPASS1:
            while(blk_count > 0) {
                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v1;

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v1;

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v1;

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v1;

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v1;
                blk_count--;
            }
        break;

        case FILTER_HIGHPASS1:
            while(blk_count > 0) {
                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v0 - v1;

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v0 - v1;

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v0 - v1;

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v0 - v1;

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v0 - v1;
                blk_count--;
            }
        break;

        case FILTER_ALLPASS1:
            while(blk_count > 0) {

                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v1 + v1 - v0;

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v1 + v1 - v0;

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v1 + v1 - v0;

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v1 + v1 - v0;

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                float v0, v1;
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v1 + v1 - v0;
                blk_count--;
            }
        break;

        case FILTER_HIGHSHELF1:
            while(blk_count > 0) {
                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v0 + m2 * (v0 - v1);

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v0 + m2 * (v0 - v1);

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v0 + m2 * (v0 - v1);

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v0 + m2 * (v0 - v1);

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                float v0, v1;
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v0 + m2 * (v0 - v1);
                blk_count--;
            }
        break;

        case FILTER_LOWSHELF1:
            while(blk_count > 0) {
                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v0 + m1 * v1;

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v0 + m1 * v1;

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v0 + m1 * v1;

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v0 + m1 * v1;

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v0 + m1 * v1;
                blk_count--;
            }
        break;

        default:
            while(blk_count > 0) {
                v0 = sp[0];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[0] = v0 * m0 + m1 * v1 + m2 * (v0 - v1);

                v0 = sp[1];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[1] = v0 * m0 + m1 * v1 + m2 * (v0 - v1);

                v0 = sp[2];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[2] = v0 * m0 + m1 * v1 + m2 * (v0 - v1);

                v0 = sp[3];
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                sp[3] = v0 * m0 + m1 * v1 + m2 * (v0 - v1);

                sp += 4;
                blk_count--;
            }
            blk_count = count & 0x3;
            while(blk_count > 0) {
                float v0, v1;
                v0 = *sp;
                v1 = a2 * v0 + a1 * ic1eq;
                ic1eq = v1 + v1 - ic1eq;
                *sp++ = v0 * m0 + m1 * v1 + m2 * (v0 - v1);
                blk_count--;
            }
    }

    f->svic1eq = ic1eq;
}

static inline void dsp_svf_second_order(Filter * __restrict f, float * __restrict samples, uint32_t count) {
    // Load SVF coefficients
    float a1 = f->sva1, a2 = f->sva2, a3 = f->sva3;
    float m0 = f->svm0, m1 = f->svm1, m2 = f->svm2;
    float ic1eq = f->svic1eq, ic2eq = f->svic2eq;
    float g = f->g;
    float *sp = samples;
    float v0, v1, v2, v3;
    uint32_t blk_count = count >> 2; // unroll loops by 4

    // Per-type specialization: eliminates zero-multiplies in inner loop
    switch (f->filter_type) {
        case FILTER_LOWPASS:
            while(blk_count > 0) {
                v0 = sp[0];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[0] = v2;

                v0 = sp[1];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[1] = v2;

                v0 = sp[2];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[2] = v2;

                v0 = sp[3];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[3] = v2;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                *sp++ = v2;
                blk_count--;
            }
            break;
        case FILTER_HIGHPASS:
            while(blk_count > 0) {
                v0 = sp[0];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[0] = v0 + m1 * v1 - v2;

                v0 = sp[1];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[1] = v0 + m1 * v1 - v2;

                v0 = sp[2];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[2] = v0 + m1 * v1 - v2;

                v0 = sp[3];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[3] = v0 + m1 * v1 - v2;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                *sp++ = v0 + m1 * v1 - v2;
                blk_count--;
            }
            break;
        case FILTER_PEAKING:
        case FILTER_NOTCH:
        case FILTER_ALLPASS:
            while(blk_count > 0) {
                v0 = sp[0];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[0] = v0 + m1 * v1;

                v0 = sp[1];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[1] = v0 + m1 * v1;

                v0 = sp[2];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[2] = v0 + m1 * v1;

                v0 = sp[3];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[3] = v0 + m1 * v1;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                *sp++ = v0 + m1 * v1;
                blk_count--;
            }
            break;
        default: // FILTER_LOWSHELF, FILTER_HIGHSHELF, FILTER_LINKWITZ_TRANSFORM
            while(blk_count > 0) {
                v0 = sp[0];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[0] = v0 * m0 + m1 * v1 + m2 * v2;

                v0 = sp[1];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[1] = v0 * m0 + m1 * v1 + m2 * v2;

                v0 = sp[2];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[2] = v0 * m0 + m1 * v1 + m2 * v2;

                v0 = sp[3];
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                sp[3] = v0 * m0 + m1 * v1 + m2 * v2;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                v0 = *sp;
                v3 = v0 - ic2eq;
                v1 = a1 * ic1eq + a2 * v3;
                v2 = ic2eq + g * v1;
                ic1eq = v1 + v1 - ic1eq;
                ic2eq = v2 + v2 - ic2eq;
                *sp++ = v0 * m0 + m1 * v1 + m2 * v2;
                blk_count--;
            }
            break;
    }
    f->svic1eq = ic1eq;
    f->svic2eq = ic2eq;
}

// Arm classes for the second-order SVF kernel.  Sections fuse only with a
// partner of the same class, so every fused section keeps the op count of its
// specialized single-kernel arm.
typedef enum {
    DSP_SVF_ARM_LPHP = 0,   // FILTER_LOWPASS / FILTER_HIGHPASS
    DSP_SVF_ARM_PEAK,       // FILTER_PEAKING / FILTER_NOTCH / FILTER_ALLPASS
    DSP_SVF_ARM_GENERIC,    // shelves, Linkwitz Transform, and any other type
} DspSvfArm;

static inline DspSvfArm dsp_svf_arm_class(const Filter *f) {
    switch (f->filter_type) {
        case FILTER_LOWPASS:
        case FILTER_HIGHPASS:
            return DSP_SVF_ARM_LPHP;
        case FILTER_PEAKING:
        case FILTER_NOTCH:
        case FILTER_ALLPASS:
            return DSP_SVF_ARM_PEAK;
        default:
            return DSP_SVF_ARM_GENERIC;
    }
}

// Fused two-section SVF cascade: each sample is loaded once, pushed through
// both sections in registers, and stored once.  Callers must pair sections of
// equal dsp_svf_arm_class; the trailing arm assumes both are default-arm types.
static inline void dsp_svf_second_order_x2(Filter * __restrict f0, Filter * __restrict f1,
                                           float * __restrict samples, uint32_t count) {
    float a1_0 = f0->sva1, a2_0 = f0->sva2;
    float m0_0 = f0->svm0, m1_0 = f0->svm1, m2_0 = f0->svm2;
    float ic1_0 = f0->svic1eq, ic2_0 = f0->svic2eq;
    float g_0 = f0->g;
    float a1_1 = f1->sva1, a2_1 = f1->sva2;
    float m0_1 = f1->svm0, m1_1 = f1->svm1, m2_1 = f1->svm2;
    float ic1_1 = f1->svic1eq, ic2_1 = f1->svic2eq;
    float g_1 = f1->g;
    float *sp = samples;
    float x, y, z, v1_0, v2_0, v3_0, v1_1, v2_1, v3_1;
    uint32_t blk_count = count >> 2; // unroll loops by 4

    DspSvfArm arm0 = dsp_svf_arm_class(f0);

    if (arm0 == DSP_SVF_ARM_PEAK) {
        // Both sections drop the m0 and m2 products (2 ops/sample each).
        while(blk_count > 0) {
            x = sp[0];
            v3_0 = x - ic2_0;
            v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
            v2_0 = ic2_0 + g_0 * v1_0;
            ic1_0 = v1_0 + v1_0 - ic1_0;
            ic2_0 = v2_0 + v2_0 - ic2_0;
            y = x + m1_0 * v1_0;
            v3_1 = y - ic2_1;
            v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
            v2_1 = ic2_1 + g_1 * v1_1;
            ic1_1 = v1_1 + v1_1 - ic1_1;
            ic2_1 = v2_1 + v2_1 - ic2_1;
            z = y + m1_1 * v1_1;
            sp[0] = z;

            x = sp[1];
            v3_0 = x - ic2_0;
            v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
            v2_0 = ic2_0 + g_0 * v1_0;
            ic1_0 = v1_0 + v1_0 - ic1_0;
            ic2_0 = v2_0 + v2_0 - ic2_0;
            y = x + m1_0 * v1_0;
            v3_1 = y - ic2_1;
            v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
            v2_1 = ic2_1 + g_1 * v1_1;
            ic1_1 = v1_1 + v1_1 - ic1_1;
            ic2_1 = v2_1 + v2_1 - ic2_1;
            z = y + m1_1 * v1_1;
            sp[1] = z;

            x = sp[2];
            v3_0 = x - ic2_0;
            v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
            v2_0 = ic2_0 + g_0 * v1_0;
            ic1_0 = v1_0 + v1_0 - ic1_0;
            ic2_0 = v2_0 + v2_0 - ic2_0;
            y = x + m1_0 * v1_0;
            v3_1 = y - ic2_1;
            v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
            v2_1 = ic2_1 + g_1 * v1_1;
            ic1_1 = v1_1 + v1_1 - ic1_1;
            ic2_1 = v2_1 + v2_1 - ic2_1;
            z = y + m1_1 * v1_1;
            sp[2] = z;

            x = sp[3];
            v3_0 = x - ic2_0;
            v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
            v2_0 = ic2_0 + g_0 * v1_0;
            ic1_0 = v1_0 + v1_0 - ic1_0;
            ic2_0 = v2_0 + v2_0 - ic2_0;
            y = x + m1_0 * v1_0;
            v3_1 = y - ic2_1;
            v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
            v2_1 = ic2_1 + g_1 * v1_1;
            ic1_1 = v1_1 + v1_1 - ic1_1;
            ic2_1 = v2_1 + v2_1 - ic2_1;
            z = y + m1_1 * v1_1;
            sp[3] = z;

            sp += 4;
            blk_count--;
        }

        blk_count = count & 0x3;
        while(blk_count > 0) {
            x = *sp;
            v3_0 = x - ic2_0;
            v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
            v2_0 = ic2_0 + g_0 * v1_0;
            ic1_0 = v1_0 + v1_0 - ic1_0;
            ic2_0 = v2_0 + v2_0 - ic2_0;
            y = x + m1_0 * v1_0;
            v3_1 = y - ic2_1;
            v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
            v2_1 = ic2_1 + g_1 * v1_1;
            ic1_1 = v1_1 + v1_1 - ic1_1;
            ic2_1 = v2_1 + v2_1 - ic2_1;
            z = y + m1_1 * v1_1;
            *sp++ = z;
            blk_count--;
        }

        f0->svic1eq = ic1_0;
        f0->svic2eq = ic2_0;
        f1->svic1eq = ic1_1;
        f1->svic2eq = ic2_1;
        return;
    }

    if (arm0 == DSP_SVF_ARM_LPHP) {
        // Low-pass takes v2 straight out; high-pass needs the 3-term mix
        // with m0 = 1.0f and m2 = -1.0f folded in (v0 + m1*v1 - v2).
        // Split so neither section pays for the other's output expression.
        bool hp0 = (f0->filter_type == FILTER_HIGHPASS);
        bool hp1 = (f1->filter_type == FILTER_HIGHPASS);

        if (!hp0 && !hp1) {
            while(blk_count > 0) {
                x = sp[0];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[0] = z;

                x = sp[1];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[1] = z;

                x = sp[2];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[2] = z;

                x = sp[3];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[3] = z;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                *sp++ = z;
                blk_count--;
            }

            f0->svic1eq = ic1_0;
            f0->svic2eq = ic2_0;
            f1->svic1eq = ic1_1;
            f1->svic2eq = ic2_1;
            return;
        }

        if (!hp0 && hp1) {
            while(blk_count > 0) {
                x = sp[0];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[0] = z;

                x = sp[1];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[1] = z;

                x = sp[2];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[2] = z;

                x = sp[3];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[3] = z;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                *sp++ = z;
                blk_count--;
            }

            f0->svic1eq = ic1_0;
            f0->svic2eq = ic2_0;
            f1->svic1eq = ic1_1;
            f1->svic2eq = ic2_1;
            return;
        }

        if (hp0 && !hp1) {
            while(blk_count > 0) {
                x = sp[0];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[0] = z;

                x = sp[1];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[1] = z;

                x = sp[2];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[2] = z;

                x = sp[3];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                sp[3] = z;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = v2_1;
                *sp++ = z;
                blk_count--;
            }

            f0->svic1eq = ic1_0;
            f0->svic2eq = ic2_0;
            f1->svic1eq = ic1_1;
            f1->svic2eq = ic2_1;
            return;
        }

        if (hp0 && hp1) {
            while(blk_count > 0) {
                x = sp[0];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[0] = z;

                x = sp[1];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[1] = z;

                x = sp[2];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[2] = z;

                x = sp[3];
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                sp[3] = z;

                sp += 4;
                blk_count--;
            }

            blk_count = count & 0x3;
            while(blk_count > 0) {
                x = *sp;
                v3_0 = x - ic2_0;
                v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
                v2_0 = ic2_0 + g_0 * v1_0;
                ic1_0 = v1_0 + v1_0 - ic1_0;
                ic2_0 = v2_0 + v2_0 - ic2_0;
                y = x + m1_0 * v1_0 - v2_0;
                v3_1 = y - ic2_1;
                v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
                v2_1 = ic2_1 + g_1 * v1_1;
                ic1_1 = v1_1 + v1_1 - ic1_1;
                ic2_1 = v2_1 + v2_1 - ic2_1;
                z = y + m1_1 * v1_1 - v2_1;
                *sp++ = z;
                blk_count--;
            }

            f0->svic1eq = ic1_0;
            f0->svic2eq = ic2_0;
            f1->svic1eq = ic1_1;
            f1->svic2eq = ic2_1;
            return;
        }

    }

    // Shelves and the Linkwitz Transform: both sections need the full
    // three-term output mix, exactly as the single kernel's default arm.
    while(blk_count > 0) {
        x = sp[0];
        v3_0 = x - ic2_0;
        v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
        v2_0 = ic2_0 + g_0 * v1_0;
        ic1_0 = v1_0 + v1_0 - ic1_0;
        ic2_0 = v2_0 + v2_0 - ic2_0;
        y = x * m0_0 + m1_0 * v1_0 + m2_0 * v2_0;
        v3_1 = y - ic2_1;
        v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
        v2_1 = ic2_1 + g_1 * v1_1;
        ic1_1 = v1_1 + v1_1 - ic1_1;
        ic2_1 = v2_1 + v2_1 - ic2_1;
        z = y * m0_1 + m1_1 * v1_1 + m2_1 * v2_1;
        sp[0] = z;

        x = sp[1];
        v3_0 = x - ic2_0;
        v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
        v2_0 = ic2_0 + g_0 * v1_0;
        ic1_0 = v1_0 + v1_0 - ic1_0;
        ic2_0 = v2_0 + v2_0 - ic2_0;
        y = x * m0_0 + m1_0 * v1_0 + m2_0 * v2_0;
        v3_1 = y - ic2_1;
        v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
        v2_1 = ic2_1 + g_1 * v1_1;
        ic1_1 = v1_1 + v1_1 - ic1_1;
        ic2_1 = v2_1 + v2_1 - ic2_1;
        z = y * m0_1 + m1_1 * v1_1 + m2_1 * v2_1;
        sp[1] = z;

        x = sp[2];
        v3_0 = x - ic2_0;
        v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
        v2_0 = ic2_0 + g_0 * v1_0;
        ic1_0 = v1_0 + v1_0 - ic1_0;
        ic2_0 = v2_0 + v2_0 - ic2_0;
        y = x * m0_0 + m1_0 * v1_0 + m2_0 * v2_0;
        v3_1 = y - ic2_1;
        v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
        v2_1 = ic2_1 + g_1 * v1_1;
        ic1_1 = v1_1 + v1_1 - ic1_1;
        ic2_1 = v2_1 + v2_1 - ic2_1;
        z = y * m0_1 + m1_1 * v1_1 + m2_1 * v2_1;
        sp[2] = z;

        x = sp[3];
        v3_0 = x - ic2_0;
        v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
        v2_0 = ic2_0 + g_0 * v1_0;
        ic1_0 = v1_0 + v1_0 - ic1_0;
        ic2_0 = v2_0 + v2_0 - ic2_0;
        y = x * m0_0 + m1_0 * v1_0 + m2_0 * v2_0;
        v3_1 = y - ic2_1;
        v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
        v2_1 = ic2_1 + g_1 * v1_1;
        ic1_1 = v1_1 + v1_1 - ic1_1;
        ic2_1 = v2_1 + v2_1 - ic2_1;
        z = y * m0_1 + m1_1 * v1_1 + m2_1 * v2_1;
        sp[3] = z;

        sp += 4;
        blk_count--;
    }

    blk_count = count & 0x3;
    while(blk_count > 0) {
        x = *sp;
        v3_0 = x - ic2_0;
        v1_0 = a1_0 * ic1_0 + a2_0 * v3_0;
        v2_0 = ic2_0 + g_0 * v1_0;
        ic1_0 = v1_0 + v1_0 - ic1_0;
        ic2_0 = v2_0 + v2_0 - ic2_0;
        y = x * m0_0 + m1_0 * v1_0 + m2_0 * v2_0;
        v3_1 = y - ic2_1;
        v1_1 = a1_1 * ic1_1 + a2_1 * v3_1;
        v2_1 = ic2_1 + g_1 * v1_1;
        ic1_1 = v1_1 + v1_1 - ic1_1;
        ic2_1 = v2_1 + v2_1 - ic2_1;
        z = y * m0_1 + m1_1 * v1_1 + m2_1 * v2_1;
        *sp++ = z;
        blk_count--;
    }

    f0->svic1eq = ic1_0;
    f0->svic2eq = ic2_0;
    f1->svic1eq = ic1_1;
    f1->svic2eq = ic2_1;
}

#endif // PICO_RP2350

#endif // DSP_SVF_H
