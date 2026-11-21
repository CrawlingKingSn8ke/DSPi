/* GPL-3.0. Windows host for the DSPi float RTA kernels. */
#include "spectrum.h"
#include "rta_bass.h"
#include <windows.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

#define QUEUE_FRAMES 16384u
#define CHANNELS 8u
#define CONFIG_BYTES 24u
#define STATUS_BYTES 24u
#define BAND_BYTES (8u + 2u * RTA_MAX_BANDS)
#define BIN_BYTES (17u + RTA_MAX_POINTS / 2u)

typedef struct {
    RtaBassChannel bass;
    float time[RTA_MAX_POINTS], powers[RTA_MAX_BANDS], peak_fraction;
    unsigned used;
    uint8_t sequence, levels[RTA_MAX_BANDS], peaks[RTA_MAX_BANDS];
    ULONGLONG last_frame;
} SpectrumChannel;

struct DspiSpectrum {
    unsigned rate, channels, generation;
    wchar_t control[2200], output[2200], temporary[2220];
    _Atomic unsigned selection, written, consumed, dropped;
    unsigned tags[QUEUE_FRAMES];
    float samples[QUEUE_FRAMES][CHANNELS];
    unsigned char config[CONFIG_BYTES], bins[BIN_BYTES];
    const RtaBandTable *table;
    RtaBassCoeffs bass;
    SpectrumChannel channel[CHANNELS];
};

static void put16(unsigned char *p, uint16_t number) { memcpy(p, &number, sizeof number); }
static void put32(unsigned char *p, uint32_t number) { memcpy(p, &number, sizeof number); }

static void write_snapshot(DspiSpectrum *s, const unsigned char *data, DWORD length) {
    HANDLE file = CreateFileW(s->temporary, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD wrote;
    BOOL ok = WriteFile(file, data, length, &wrote, NULL) && wrote == length;
    CloseHandle(file);
    if (!ok || !MoveFileExW(s->temporary, s->output, MOVEFILE_REPLACE_EXISTING))
        DeleteFileW(s->temporary);
}

static void publish_idle(DspiSpectrum *s) {
    static const unsigned char idle[CONFIG_BYTES + STATUS_BYTES] = "DSPIRTA1";
    write_snapshot(s, idle, sizeof idle);
}

DspiSpectrum *dspi_spectrum_create(const wchar_t *directory, unsigned rate, unsigned channels, uint64_t id) {
    if (!rta_band_table(rate, RTA_ORDER_MAX)) return NULL;
    DspiSpectrum *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->rate = rate;
    s->channels = channels;
    atomic_init(&s->selection, 0);
    atomic_init(&s->written, 0);
    atomic_init(&s->consumed, 0);
    atomic_init(&s->dropped, 0);
    swprintf(s->control, 2200, L"%ls\\rta-control.bin", directory);
    swprintf(s->output, 2200, L"%ls\\telemetry\\spectrum-%lu-%lu.bin", directory, (unsigned long)(id >> 32), (unsigned long)(uint32_t)id);
    swprintf(s->temporary, 2220, L"%ls.tmp", s->output);
    publish_idle(s);
    return s;
}

void dspi_spectrum_capture(DspiSpectrum *s, const float *input, const float *output, unsigned frames) {
    if (!s) return;
    unsigned selection = atomic_load_explicit(&s->selection, memory_order_acquire);
    unsigned mask = selection & 255u;
    if (!mask) return;
    unsigned written = atomic_load_explicit(&s->written, memory_order_relaxed);
    unsigned consumed = atomic_load_explicit(&s->consumed, memory_order_acquire);
    if (frames > QUEUE_FRAMES - (written - consumed)) {
        atomic_store_explicit(&s->dropped, 1, memory_order_relaxed);
        return;
    }

    const float *source = selection & 256u ? output : input;
    for (unsigned f = 0; f < frames; f++) {
        unsigned index = (written + f) & (QUEUE_FRAMES - 1u);
        s->tags[index] = selection;
        for (unsigned channel = 0; channel < s->channels; channel++) {
            if (mask & (1u << channel))
                s->samples[index][channel] = source[f * s->channels + channel];
        }
    }
    atomic_store_explicit(&s->written, written + frames, memory_order_release);
}

static unsigned read_config(DspiSpectrum *s, unsigned char *config) {
    HANDLE file = CreateFileW(s->control, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD got = 0;
    FILETIME timestamp, now;
    LARGE_INTEGER size;
    GetSystemTimeAsFileTime(&now);
    BOOL valid = GetFileSizeEx(file, &size) && size.QuadPart == CONFIG_BYTES
        && GetFileTime(file, NULL, NULL, &timestamp)
        && ReadFile(file, config, CONFIG_BYTES, &got, NULL) && got == CONFIG_BYTES;
    CloseHandle(file);
    if (!valid || memcmp(config, "DSPIRTA1", 8) || config[8] != 3 || config[9] > 1 || config[11] ||
        config[12] < RTA_ORDER_MIN || config[12] > RTA_ORDER_MAX || config[16] > 100) return 0;
    uint64_t time = ((uint64_t)timestamp.dwHighDateTime << 32) | timestamp.dwLowDateTime;
    uint64_t current = ((uint64_t)now.dwHighDateTime << 32) | now.dwLowDateTime;
    if (time > current || current - time > 20000000u) return 0;
    return config[10] & ((1u << s->channels) - 1u);
}

static void transform(DspiSpectrum *s, unsigned index, unsigned points) {
    SpectrumChannel *channel = &s->channel[index];
    uint8_t stage = 0;
    uint8_t order = s->config[12];
    while (!rta_fft_step(channel->time, order, &stage)) {}
    float power[RTA_MAX_BANDS] = {0};
    rta_fft_finish(channel->time, order, s->table, power, s->bins + 16);
    unsigned average = s->config[14] | (unsigned)s->config[15] << 8;
    float duration = 1000.f * points / s->rate;
    float alpha = duration / (average + duration);
    float drop = channel->peak_fraction + duration * s->config[16] * .002f;
    unsigned drop_steps = (unsigned)drop;
    channel->peak_fraction = drop - drop_steps;
    for (unsigned b = 0; b < s->table->n_bands; b++) {
        if (b < RTA_BASS_BANDS) power[b] = rta_bass_power(&s->bass, &channel->bass, (uint8_t)b);
        if (!channel->last_frame || b < RTA_BASS_BANDS) channel->powers[b] = power[b];
        else channel->powers[b] += alpha * (power[b] - channel->powers[b]);
        channel->levels[b] = rta_level_from_power(channel->powers[b]);
        unsigned instantaneous = rta_level_from_power(power[b]);
        unsigned decayed = drop_steps < channel->peaks[b] ? channel->peaks[b] - drop_steps : 0;
        channel->peaks[b] = s->config[16] && decayed > instantaneous ? decayed : instantaneous;
    }
    if (++channel->sequence == 255) channel->sequence = 0;
    channel->last_frame = GetTickCount64();
    channel->used = 0;
    s->bins[0] = 3;
    s->bins[1] = (uint8_t)index;
    s->bins[2] = channel->sequence;
    s->bins[3] = order;
    put32(s->bins + 4, s->rate);
    put16(s->bins + 8, (uint16_t)(points / 2));
    s->bins[16 + points / 2] = channel->sequence;
}

static void publish(DspiSpectrum *s, unsigned mask, unsigned points) {
    unsigned char data[CONFIG_BYTES + STATUS_BYTES + BAND_BYTES * CHANNELS + BIN_BYTES] = {0};
    memcpy(data, s->config, CONFIG_BYTES);
    unsigned char *status = data + CONFIG_BYTES;
    status[0] = 3;
    status[1] = 1;
    status[2] = s->config[9];
    status[3] = s->bins[1];
    put16(status + 6, (uint16_t)mask);
    put32(status + 16, s->rate);
    unsigned length = CONFIG_BYTES + STATUS_BYTES;
    ULONGLONG now = GetTickCount64();
    for (unsigned index = 0; index < s->channels; index++) {
        if (!(mask & (1u << index))) continue;
        SpectrumChannel *channel = &s->channel[index];
        if (!channel->last_frame) return;
        unsigned char *band = data + length;
        band[0] = 3;
        band[1] = (uint8_t)index;
        band[2] = channel->sequence;
        band[3] = s->table->n_bands;
        ULONGLONG age = now - channel->last_frame;
        put16(band + 4, age < 65534 ? (uint16_t)age : 65534);
        memcpy(band + 8, channel->levels, RTA_MAX_BANDS);
        memcpy(band + 8 + RTA_MAX_BANDS, channel->peaks, RTA_MAX_BANDS);
        length += BAND_BYTES;
        status[5]++;
    }
    put16(status + 8, (uint16_t)(s->rate / points * status[5]));
    memcpy(data + length, s->bins, 17 + points / 2);
    length += 17 + points / 2;

    write_snapshot(s, data, length);
}

void dspi_spectrum_tick(DspiSpectrum *s) {
    if (!s) return;
    unsigned char config[CONFIG_BYTES];
    unsigned mask = read_config(s, config);
    unsigned written = atomic_load_explicit(&s->written, memory_order_acquire);
    if (!mask || !rta_band_table(s->rate, config[12])) {
        if (atomic_exchange(&s->selection, 0)) publish_idle(s);
        atomic_store_explicit(&s->consumed, written, memory_order_release);
        s->config[0] = 0;
        return;
    }

    if (memcmp(s->config, config, sizeof config) || atomic_exchange(&s->dropped, 0)) {
        memcpy(s->config, config, sizeof config);
        s->table = rta_band_table(s->rate, config[12]);
        rta_bass_configure(&s->bass, s->rate, config[14] | (uint16_t)config[15] << 8);
        memset(s->channel, 0, sizeof s->channel);
        memset(s->bins, 0, sizeof s->bins);
        unsigned selection = (++s->generation << 9) | ((unsigned)config[9] << 8) | mask;
        atomic_store_explicit(&s->selection, selection, memory_order_release);
        atomic_store_explicit(&s->consumed, written, memory_order_release);
        return;
    }

    unsigned selection = atomic_load_explicit(&s->selection, memory_order_relaxed);
    unsigned cursor = atomic_load_explicit(&s->consumed, memory_order_relaxed);
    unsigned points = 1u << config[12];
    bool changed = false;
    for (; cursor != written; cursor++) {
        unsigned ring_index = cursor & (QUEUE_FRAMES - 1u);
        if (s->tags[ring_index] != selection) continue;
        for (unsigned index = 0; index < s->channels; index++) {
            if (!(mask & (1u << index))) continue;
            SpectrumChannel *channel = &s->channel[index];
            float value = s->samples[ring_index][index];
            rta_bass_push(&s->bass, &channel->bass, &value, 1);
            channel->time[channel->used++] = value;
            if (channel->used == points) {
                transform(s, index, points);
                changed = true;
            }
        }
    }
    atomic_store_explicit(&s->consumed, cursor, memory_order_release);
    if (changed) publish(s, mask, points);
}

void dspi_spectrum_destroy(DspiSpectrum *s) {
    if (!s) return;
    DeleteFileW(s->output);
    free(s);
}

