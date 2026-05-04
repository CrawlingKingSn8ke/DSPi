#include "control_inputs.h"

#include <stdint.h>
#include <stdbool.h>

#include "pico/stdlib.h"

#include "audio_input.h"
#include "flash_storage.h"
#include "loudness.h"
#include "usb_audio.h"

// -----------------------------------------------------------------------------
// GPIO map
// -----------------------------------------------------------------------------

#define ENC_CLK_PIN              2
#define ENC_DT_PIN               3
#define ENC_SW_PIN               4

#define RF_A_PIN                16
#define RF_B_PIN                17
#define RF_C_PIN                18
#define RF_D_PIN                19

// External status LED. Do not use GPIO 25, that is only the onboard Pico LED.
#define STATUS_LED_PIN          22

// Change to -1 if encoder direction is reversed.
#define ENCODER_DIRECTION        1

// -----------------------------------------------------------------------------
// Timing
// -----------------------------------------------------------------------------

#define POLL_INTERVAL_US       1000u
#define LONG_PRESS_US        700000u

#define RF_REPEAT_DELAY_US   350000u
#define RF_REPEAT_RATE_US    120000u

#define LED_ACK_ON_US         70000u
#define LED_SHORT_ON_US       90000u
#define LED_SHORT_GAP_US     110000u
#define LED_LONG_ON_US       300000u
#define LED_FINAL_GAP_US     120000u

#define CONTROL_VOLUME_STEP_Q8 256

// -----------------------------------------------------------------------------
// Button / LED state
// -----------------------------------------------------------------------------

typedef struct {
    bool pressed;
    bool long_handled;
    uint64_t press_us;
    uint64_t next_repeat_us;
} ButtonState;

typedef enum {
    LED_MODE_IDLE = 0,
    LED_MODE_ACK,
    LED_MODE_LOUD_ON,
    LED_MODE_LOUD_OFF
} LedMode;

static uint64_t next_poll_us = 0;
static uint8_t enc_prev_state = 0;
static int8_t enc_accum = 0;

static ButtonState enc_sw = {0};
static ButtonState rf_a = {0};
static ButtonState rf_b = {0};
static ButtonState rf_c = {0};
static ButtonState rf_d = {0};

static LedMode led_mode = LED_MODE_IDLE;
static uint8_t led_phase = 0;
static uint64_t led_deadline_us = 0;
static bool led_output = false;

static uint8_t last_seen_input_source = INPUT_SOURCE_USB;
static uint64_t source_toggle_inhibit_until_us = 0;

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------

static inline uint64_t now_us(void) {
    return to_us_since_boot(get_absolute_time());
}

static inline void led_write(bool on) {
    led_output = on;
    gpio_put(STATUS_LED_PIN, on ? 1 : 0);
}

static void led_start_ack(uint64_t now) {
    // Do not interrupt a loudness status report.
    if (led_mode == LED_MODE_LOUD_ON || led_mode == LED_MODE_LOUD_OFF) {
        return;
    }

    led_mode = LED_MODE_ACK;
    led_phase = 0;
    led_deadline_us = now + LED_ACK_ON_US;
    led_write(true);
}

static void led_begin_loudness_report(bool loud_on, uint64_t now) {
    led_mode = loud_on ? LED_MODE_LOUD_ON : LED_MODE_LOUD_OFF;
    led_phase = 0;
    led_deadline_us = now + (loud_on ? LED_SHORT_ON_US : LED_LONG_ON_US);
    led_write(true);
}

static void led_service(uint64_t now, bool any_rf_held) {
    if (led_mode == LED_MODE_IDLE) {
        // Solid LED while any RF button is physically held.
        led_write(any_rf_held);
        return;
    }

    if (now < led_deadline_us) {
        return;
    }

    if (led_mode == LED_MODE_ACK) {
        led_mode = LED_MODE_IDLE;
        led_phase = 0;
        led_write(any_rf_held);
        return;
    }

    if (led_mode == LED_MODE_LOUD_ON) {
        // 2 short blinks = loudness on.
        switch (led_phase) {
            case 0:
                led_phase = 1;
                led_deadline_us = now + LED_SHORT_GAP_US;
                led_write(false);
                return;

            case 1:
                led_phase = 2;
                led_deadline_us = now + LED_SHORT_ON_US;
                led_write(true);
                return;

            case 2:
                led_phase = 3;
                led_deadline_us = now + LED_FINAL_GAP_US;
                led_write(false);
                return;

            default:
                led_mode = LED_MODE_IDLE;
                led_phase = 0;
                led_write(any_rf_held);
                return;
        }
    }

    if (led_mode == LED_MODE_LOUD_OFF) {
        // 1 long blink = loudness off.
        switch (led_phase) {
            case 0:
                led_phase = 1;
                led_deadline_us = now + LED_FINAL_GAP_US;
                led_write(false);
                return;

            default:
                led_mode = LED_MODE_IDLE;
                led_phase = 0;
                led_write(any_rf_held);
                return;
        }
    }

    led_mode = LED_MODE_IDLE;
    led_phase = 0;
    led_write(any_rf_held);
}

static void control_host_volume_step_db(int8_t step_db) {
    int32_t v = (int32_t)audio_state.volume + ((int32_t)step_db * CONTROL_VOLUME_STEP_Q8);

    const int32_t min_v = -((int32_t)CENTER_VOLUME_INDEX * CONTROL_VOLUME_STEP_Q8);
    const int32_t max_v = 0;

    if (v < min_v) v = min_v;
    if (v > max_v) v = max_v;

    audio_set_volume((int16_t)v);
}

static void source_control_observe(uint64_t now) {
    if (active_input_source != last_seen_input_source) {
        last_seen_input_source = active_input_source;
        source_toggle_inhibit_until_us = now + 1000000u;
    }
}

static void control_toggle_source(uint64_t now) {
    if (now < source_toggle_inhibit_until_us) {
        return;
    }

    if (input_source_change_pending) {
        return;
    }

    uint8_t current = active_input_source;

    uint8_t next = (current == INPUT_SOURCE_SPDIF)
        ? INPUT_SOURCE_USB
        : INPUT_SOURCE_SPDIF;

    if (!input_source_valid(next)) {
        return;
    }

    pending_input_source = next;
    input_source_change_pending = true;
    source_toggle_inhibit_until_us = now + 1000000u;
}

static void control_request_save_active_preset(void) {
    pending_preset_save_slot = preset_get_active();
    preset_save_pending = true;
}

static void control_toggle_loudness(void) {
    loudness_enabled = !loudness_enabled;

    if (loudness_enabled && loudness_active_table) {
        audio_set_volume(audio_state.volume);
    } else {
        current_loudness_coeffs = NULL;
    }
}

static bool control_get_loudness(void) {
    return loudness_enabled;
}

// -----------------------------------------------------------------------------
// Encoder handling
// -----------------------------------------------------------------------------

static void handle_encoder_rotation(void) {
    static const int8_t quad_table[16] = {
         0, -1,  1,  0,
         1,  0,  0, -1,
        -1,  0,  0,  1,
         0,  1, -1,  0
    };

    uint8_t enc_state =
        (gpio_get(ENC_CLK_PIN) ? 2u : 0u) |
        (gpio_get(ENC_DT_PIN)  ? 1u : 0u);

    if (enc_state == enc_prev_state) {
        return;
    }

    int8_t delta = quad_table[(enc_prev_state << 2) | enc_state];
    enc_prev_state = enc_state;

    if (!delta) {
        return;
    }

    enc_accum += delta;

    if (enc_accum >= 4) {
        control_host_volume_step_db(ENCODER_DIRECTION * 1);
        enc_accum = 0;
    } else if (enc_accum <= -4) {
        control_host_volume_step_db(ENCODER_DIRECTION * -1);
        enc_accum = 0;
    }
}

static void handle_encoder_switch(uint64_t now) {
    bool pressed = !gpio_get(ENC_SW_PIN);   // Active low

    if (pressed) {
        if (!enc_sw.pressed) {
            enc_sw.pressed = true;
            enc_sw.long_handled = false;
            enc_sw.press_us = now;
        } else if (!enc_sw.long_handled && (now - enc_sw.press_us) >= LONG_PRESS_US) {
            control_request_save_active_preset();
            enc_sw.long_handled = true;
        }
    } else if (enc_sw.pressed) {
        if (!enc_sw.long_handled) {
            control_toggle_source(now);
        }

        enc_sw.pressed = false;
        enc_sw.long_handled = false;
    }
}

// -----------------------------------------------------------------------------
// RF handling
// -----------------------------------------------------------------------------

static void handle_rf_volume(ButtonState *btn, bool pressed, int8_t step_db, uint64_t now) {
    if (pressed) {
        if (!btn->pressed) {
            btn->pressed = true;
            btn->long_handled = false;
            btn->press_us = now;
            btn->next_repeat_us = now + RF_REPEAT_DELAY_US;

            led_start_ack(now);
            control_host_volume_step_db(step_db);
        } else if (now >= btn->next_repeat_us) {
            control_host_volume_step_db(step_db);
            btn->next_repeat_us = now + RF_REPEAT_RATE_US;
        }
    } else {
        btn->pressed = false;
        btn->long_handled = false;
    }
}

static void handle_rf_loudness_button(bool pressed, uint64_t now) {
    if (pressed) {
        if (!rf_c.pressed) {
            rf_c.pressed = true;
            rf_c.long_handled = false;
            rf_c.press_us = now;

            // Short press has no action, but every RF press gets an acknowledgement blink.
            led_start_ack(now);
        } else if (!rf_c.long_handled && (now - rf_c.press_us) >= LONG_PRESS_US) {
            control_toggle_loudness();
            led_begin_loudness_report(control_get_loudness(), now);
            rf_c.long_handled = true;
        }
    } else if (rf_c.pressed) {
        // RF C short press intentionally has no function other than the LED acknowledgement.
        rf_c.pressed = false;
        rf_c.long_handled = false;
    }
}

static void handle_rf_source_button(bool pressed, uint64_t now) {
    if (pressed) {
        if (!rf_d.pressed) {
            rf_d.pressed = true;
            rf_d.long_handled = false;
            rf_d.press_us = now;

            led_start_ack(now);
        }
    } else if (rf_d.pressed) {
        if (!rf_d.long_handled) {
            control_toggle_source(now);
        }

        rf_d.pressed = false;
        rf_d.long_handled = false;
    }
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

void control_inputs_init(void) {
    gpio_init(ENC_CLK_PIN);
    gpio_set_dir(ENC_CLK_PIN, GPIO_IN);
    gpio_pull_up(ENC_CLK_PIN);

    gpio_init(ENC_DT_PIN);
    gpio_set_dir(ENC_DT_PIN, GPIO_IN);
    gpio_pull_up(ENC_DT_PIN);

    gpio_init(ENC_SW_PIN);
    gpio_set_dir(ENC_SW_PIN, GPIO_IN);
    gpio_pull_up(ENC_SW_PIN);

    gpio_init(RF_A_PIN);
    gpio_set_dir(RF_A_PIN, GPIO_IN);
    gpio_pull_down(RF_A_PIN);

    gpio_init(RF_B_PIN);
    gpio_set_dir(RF_B_PIN, GPIO_IN);
    gpio_pull_down(RF_B_PIN);

    gpio_init(RF_C_PIN);
    gpio_set_dir(RF_C_PIN, GPIO_IN);
    gpio_pull_down(RF_C_PIN);

    gpio_init(RF_D_PIN);
    gpio_set_dir(RF_D_PIN, GPIO_IN);
    gpio_pull_down(RF_D_PIN);

    gpio_init(STATUS_LED_PIN);
    gpio_set_dir(STATUS_LED_PIN, GPIO_OUT);
    gpio_put(STATUS_LED_PIN, 0);

    enc_prev_state =
        (gpio_get(ENC_CLK_PIN) ? 2u : 0u) |
        (gpio_get(ENC_DT_PIN)  ? 1u : 0u);

    uint64_t now = now_us();

    rf_a.pressed = gpio_get(RF_A_PIN);
    rf_b.pressed = gpio_get(RF_B_PIN);
    rf_c.pressed = gpio_get(RF_C_PIN);
    rf_d.pressed = gpio_get(RF_D_PIN);
    enc_sw.pressed = !gpio_get(ENC_SW_PIN);

    last_seen_input_source = active_input_source;
    source_toggle_inhibit_until_us = now + 500000u;

    next_poll_us = now;
}

void control_inputs_poll(void) {
    uint64_t now = now_us();

    source_control_observe(now);

    bool rf_a_pressed = gpio_get(RF_A_PIN);
    bool rf_b_pressed = gpio_get(RF_B_PIN);
    bool rf_c_pressed = gpio_get(RF_C_PIN);
    bool rf_d_pressed = gpio_get(RF_D_PIN);

    bool any_rf_held = rf_a_pressed || rf_b_pressed || rf_c_pressed || rf_d_pressed;

    led_service(now, any_rf_held);

    if (now < next_poll_us) {
        return;
    }

    next_poll_us = now + POLL_INTERVAL_US;

    handle_encoder_rotation();
    handle_encoder_switch(now);

    handle_rf_volume(&rf_a, rf_a_pressed, +1, now);
    handle_rf_volume(&rf_b, rf_b_pressed, -1, now);
    handle_rf_loudness_button(rf_c_pressed, now);
    handle_rf_source_button(rf_d_pressed, now);
}