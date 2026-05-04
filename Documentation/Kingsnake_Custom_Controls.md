# Kingsnake Custom Controls Build for DSPi RP2350

This document describes the Kingsnake custom control build based on WeebLabs DSPi `v1.1.4-beta1`.

This build is intended for testing a more finished-device style DSPi setup using local hardware controls rather than relying on Windows volume control.

## Current custom branch

Branch:

```text
lloyd-custom-v1.1.4-beta1-gcc15-controls
```

Base firmware:

```text
WeebLabs DSPi v1.1.4-beta1
RP2350 / Pico 2
Pico SDK 2.2.0
```

Compiler used for the working build:

```text
Arm GNU Toolchain 15.2.1
```

Important build note:

```text
Older GCC 10.3.1 builds were found to produce a different UF2 size and caused USB/S/PDIF switching problems. GCC 15.2.1 is required for the current working build.
```

Current known usable UF2:

```text
DSPi-RP2350-v1.1.4-beta1-gcc15-encoder-rf-source-led-gpio22-ignore-windows-mute-volume-safe-start.uf2
```

## Purpose of this build

This build adds local physical controls to DSPi:

```text
Rotary encoder for listening volume and source switching
433 MHz 4-channel RF receiver control
External GPIO22 status LED
Safe low startup volume
Windows host volume and mute writes ignored
```

The aim is to use DSPi like a standalone audio processor:

```text
Encoder/RF controls = real listening volume
Master Volume = safety ceiling only
Windows volume slider = not used
```

## Pin layout

### Added local controls

| Function | Pico GPIO | Direction | Electrical behaviour | Notes |
|---|---:|---|---|---|
| Rotary encoder CLK | GPIO 2 | Input | Internal pull-up | Quadrature input |
| Rotary encoder DT | GPIO 3 | Input | Internal pull-up | Quadrature input |
| Rotary encoder switch | GPIO 4 | Input | Internal pull-up, active low | Short press source toggle, long press save preset |
| RF A | GPIO 16 | Input | Internal pull-down, active high | Volume up |
| RF B | GPIO 17 | Input | Internal pull-down, active high | Volume down |
| RF C | GPIO 18 | Input | Internal pull-down, active high | Long press loudness toggle, short press LED acknowledgement only |
| RF D | GPIO 19 | Input | Internal pull-down, active high | Source toggle |
| External status LED | GPIO 22 | Output | Active high | Use series resistor to LED then GND |

### Existing audio-related pins used in this project

These are not introduced by the control patch, but are relevant to the tested hardware arrangement.

| Function | Pico GPIO | Notes |
|---|---:|---|
| I2S DAC DIN | GPIO 7 | PCM5102A/DAC data input |
| S/PDIF / TOSLINK RX | GPIO 11 | Proven working S/PDIF input pin |
| I2S BCK | GPIO 14 | I2S bit clock |
| I2S LRCLK | GPIO 15 | I2S left/right clock |
| S/PDIF / TOSLINK TX | GPIO 20 | Optical output transmitter |
| External LED | GPIO 22 | Used by this custom build |
| GPIO 25 | Do not use | Onboard Pico LED only, not suitable for external status LED |

## External LED wiring

Use a normal small LED with a series resistor.

Recommended simple wiring:

```text
Pico GPIO22  ->  330 ohm resistor  ->  LED anode
LED cathode  ->  Pico GND
```

GPIO22 is active high.

A 330 ohm resistor is a normal choice for a small indicator LED.

## Rotary encoder functions

| Action | Function |
|---|---|
| Rotate clockwise | Volume up, 1 dB steps |
| Rotate anticlockwise | Volume down, 1 dB steps |
| Short press | Toggle input source between USB and S/PDIF |
| Long press | Save active preset |

Encoder direction can be inverted in `control_inputs.c` by changing:

```c
#define ENCODER_DIRECTION        1
```

to:

```c
#define ENCODER_DIRECTION        -1
```

## RF remote functions

This build assumes a 433 MHz 4-channel RF receiver with outputs A, B, C and D.

| RF button | GPIO | Function |
|---|---:|---|
| A | GPIO 16 | Volume up |
| B | GPIO 17 | Volume down |
| C short press | GPIO 18 | LED acknowledgement only |
| C long press | GPIO 18 | Toggle loudness |
| D short press | GPIO 19 | Toggle source between USB and S/PDIF |

RF A and RF B repeat while held:

```text
Initial repeat delay: 350 ms
Repeat rate: 120 ms
```

## LED behaviour

| LED behaviour | Meaning |
|---|---|
| Solid while RF button is held | RF input is active |
| Short acknowledgement blink | RF button press detected |
| Two short blinks | Loudness enabled |
| One long blink | Loudness disabled |

## Volume behaviour

This build changes how volume is controlled.

### Local volume

The real listening volume is controlled by:

```text
Rotary encoder
RF A / RF B
```

Both adjust the same DSPi internal listening volume path used for loudness tracking.

### Windows host volume

Windows USB host volume writes are intentionally ignored.

In `usb_audio.c`, USB Audio Class volume SET requests are accepted but not applied to the live audio path.

This means:

```text
Moving the Windows WeebLabs volume slider should not change DSPi listening volume.
Moving the Windows WeebLabs volume slider should not mute DSPi.
Encoder/RF remains the intended volume control.
```

### Windows host mute

Windows USB host mute writes are also ignored.

This avoids Windows muting the DSPi device when the Windows slider is moved all the way down.

### Safe startup volume

The default DSPi listening volume is set to:

```text
-45 dB
```

This is intentionally low for safe startup.

After boot, raise the listening volume using:

```text
Rotary encoder clockwise
RF A held down
```

Relevant code in `usb_audio.c`:

```c
#define DEFAULT_VOLUME       ENCODE_DB(-45)
```

## Master Volume

Master Volume remains separate from the listening volume path.

Intended use:

```text
Listening volume = encoder/RF host-volume path
Master Volume = hard ceiling / safety limit only
```

This keeps loudness compensation tied to the actual listening volume while still allowing a fixed maximum output ceiling.

## Source switching

The build supports local source switching between:

```text
USB
S/PDIF
```

Local controls:

```text
Encoder short press = source toggle
RF D short press = source toggle
```

A simple inhibit guard is included to prevent repeated immediate toggles during source changes.

## Known issue

There is a remaining upstream beta issue:

```text
Touching the Windows WeebLabs volume slider can still freeze/reset DSPi on some systems, even though this build ignores the actual host volume and mute values.
```

Testing showed that the freeze is not caused by the volume value being applied. It appears to be related to the USB control transaction path itself.

The current practical rule is:

```text
Do not use the Windows WeebLabs volume slider.
Use encoder/RF volume only.
For S/PDIF use, close DSPi Console after setup if possible.
```

The developer has been informed of this issue.

## Rejected experiment

A test build was made that removed the USB Audio Feature Unit from the descriptor.

That build is rejected.

Reason:

```text
It did not stop the Windows slider issue.
It caused dropouts when using the rotary encoder.
```

Do not use any build named:

```text
no-feature-unit
```

## Files changed by this custom build

New files:

```text
firmware/DSPi/control_inputs.c
firmware/DSPi/control_inputs.h
```

Modified files:

```text
firmware/DSPi/CMakeLists.txt
firmware/DSPi/main.c
firmware/DSPi/usb_audio.c
```

The USB descriptor file was restored to the original `v1.1.4-beta1` state after the failed no-feature-unit experiment.

## Build notes

The working build was produced with:

```text
Pico SDK 2.2.0
Pico 2 target
Arm GNU Toolchain 15.2.1
Ninja
CMake
```

The old Raspberry Pi Pico SDK v1.5.1 bundled GCC 10.3.1 compiler should not be used for this branch.

Use the newer Arm toolchain first in PATH:

```text
C:\Program Files\Arm\GNU Toolchain mingw-w64-x86_64-arm-none-eabi\bin
```

## Test checklist

After flashing the UF2:

```text
1. USB audio device appears in Windows.
2. USB audio plays.
3. Encoder raises and lowers volume.
4. RF A raises volume.
5. RF B lowers volume.
6. Encoder short press toggles USB/S/PDIF.
7. RF D toggles USB/S/PDIF.
8. RF C long press toggles loudness.
9. GPIO22 LED gives acknowledgement/status feedback.
10. Windows volume slider is not used.
11. S/PDIF input remains stable with Console closed.
```