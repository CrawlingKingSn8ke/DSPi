# DSPi Software DSP

Experimental local Windows host for DSPi processing, created 3 November 2026.
This repository contains the native engine and a managed software backend for
the sibling Windows Console, including opt-in live shared-WASAPI capture and
playback through an installed virtual cable and selected soundcard.

## Current processing

The Windows host now uses the v1.1.6 firmware coefficient designer, original
SVF/biquad kernels and original crossover designer/processor. Each channel has
10 independent PEQ bands and 4 independent crossover bands. Crossover processing
runs before PEQ, matching the firmware output-stage order.

The host also provides an 8-by-8 routing matrix with per-crosspoint gain and
polarity, per-output gain/mute and 0..170 ms delay. The processing order is
input preamp -> input PEQ -> input delay -> leveller -> stereo upmixer -> matrix -> crossfeed -> subharmonic synthesizer -> psychoacoustic bass -> tube modeller -> crossover -> output PEQ -> output/listening gain -> loudness -> limiter -> output delay -> output mute. These
routing/gain/delay stages are host implementations of the corresponding
operations, not an extraction of the complete Pico audio pipeline.

Supported PEQ types: peaking, shelves, low/high pass, notch, all pass, first-order
variants and Linkwitz Transform. Supported crossovers: Linkwitz-Riley orders
2/4/6/8, Butterworth orders 1 through 8, and Bessel orders 2/4/6/8, each LP or HP.
The firmware selects SVF below Fs/7.5, otherwise biquad, and applies its original
frequency/Q clamps. Designed filter state belongs to each channel/band.

## Build and check

Requires a portable Zig C compiler (tested with 0.15.2). No global install is
required. From PowerShell in this folder:

```powershell
.\build.ps1 -Compiler 'C:\path\to\zig.exe'
```

The script verifies the pinned coefficient source, extracts the two required
functions into the build directory, builds the native checks and WAV tool,
and runs native and WAV integration tests. No Pico SDK is needed.

```powershell
.\build\dspi-wav.exe input.wav processed.wav 1000 0.707 -6
```

Arguments are input, new output filename, frequency in Hz, Q and gain in dB.
The original single-band command remains supported. For multiple bands:

```powershell
.\build\dspi-wav.exe input.wav processed.wav --peak 250 0.707 -8 --peak 3000 0.707 -8 --crossover lr4-hp 80
```

Settings default to all outputs. `--channel left`, `right`, a one-based output
number, or `all` changes the target of subsequent options. `both` is a legacy
alias for `all`, including when more than two outputs are selected. For a stereo crossover test:

```powershell
.\build\dspi-wav.exe input.wav split.wav --channel left --crossover lr4-lp 1000 --channel right --crossover lr4-hp 1000
```

This example filters the existing left/right content independently. Use the
matrix controls below to sum or duplicate inputs.

## Independent input processing

Every physical input has its own preamp, ten-band EQ and alignment delay, before
the leveller, upmixer and routing matrix. Correcting one input affects every
output fed from that input. Output EQ, gain and delay stay independent.

```powershell
.\build\dspi-wav.exe input.wav corrected.wav --input-channel left --preamp -3 --input-peak 1000 0.707 -6 --input-delay 2 --input-channel right --preamp -6 --input-filter low-shelf 120 0.707 3 --input-delay 5 --limiter -1 100
```

- `--input-channel left|right|all|N` selects physical inputs for subsequent input
  controls. Default is all; N is one-based and restricted to the file's inputs.
- `--preamp dB` (alias `--input-preamp`) sets -60..+12 dB on selected inputs.
  Zero is unity; -60 is attenuation, not mute. No automatic level normalization.
- `--input-peak Hz Q dB` adds an independent PEQ band to the selected inputs.
- `--input-filter NAME Hz Q GAIN_OR_FP` accepts the same 14 PEQ filter names as
  `--filter`, including shelves, first-order filters and Linkwitz Transform.
  Crossover types remain output-only. Peak/shelf gain accepts -30..+30 dB.
- `--input-eq-clear` removes all ten EQ bands and their filter history from
  selected inputs, letting subsequent input EQ options begin at band one again.
- `--input-delay ms` sets 0..170 ms per selected input. It uses whole samples,
  rounding down. A changed delay clears that input's delay history.

Input selection is separate from `--channel` output selection. Each input can
have up to ten bands independently of the ten output bands. Upmix-derived
C/Ls/Rs are virtual matrix sources; input controls apply to the two physical
channels before extraction, not to those derived rows.

No input delay is added by default. A signal routed from input i to output o
carries that input's delay plus the common adapter/leveller lookahead, active
limiter lookahead and output o's alignment delay. Upmix surrounds also carry
their algorithm's conditioning/delay. EQ has its normal frequency-dependent
phase response. The WAV tool reports per-input alignment delay separately,
keeps the original frame count and trims delayed tails.

Preamp and delay are host stages; EQ reuses the original firmware coefficient
designer and float kernels. Settings are static/offline: configure before
processing. Input edits do not flush already queued downstream audio or provide
smooth live transitions. See `docs/input-processing-results.md` for checks.

## Routing, gain, mute and delay

`--outputs N` selects 1..8 output channels (default: same as the input).
Input and output numbers are one-based. Default routes are identity: input 1
to output 1, input 2 to output 2, etc. Additional outputs start silent.

- `--clear-routes` removes all routes.
- `--route INPUT OUTPUT dB` enables/replaces one crosspoint with a gain.
- `--route-invert INPUT OUTPUT dB` also reverses its polarity.
- `--route-off INPUT OUTPUT` disables one crosspoint.
- `--gain dB` sets gain on the currently selected outputs (-120..+12 dB).
- `--delay ms` sets delay on the selected outputs (0..170 ms).
- `--mute` / `--unmute` controls the selected outputs.

Route gains also accept -120..+12 dB. Inputs are summed without automatic
normalization: two identical sources at 0 dB each can clip. To average two
inputs, set each crosspoint to -6.0206 dB. Repeating a crosspoint replaces its
setting rather than adding a duplicate route.

For a three-output stereo-plus-subwoofer test:

```powershell
.\build\dspi-wav.exe input.wav system-2point1.wav --outputs 3 --clear-routes --route 1 1 0 --route 2 2 0 --route 1 3 -6.0206 --route 2 3 -6.0206 --channel 1 --crossover lr4-hp 80 --channel 2 --crossover lr4-hp 80 --channel 3 --crossover lr4-lp 80 --gain -6 --delay 2
```

Output 1 is high-passed left, output 2 high-passed right, and output 3 is the
averaged mono low-pass feed, with -6 dB output trim and 2 ms delay. These are
logical file channels, not assignments to physical soundcard sockets.

Delay uses whole samples, truncating fractional samples as the firmware does.
At 48 kHz, 1 ms is exactly 48 samples; at 44.1 kHz it is 44 samples. Delay changes
clear that output's ring buffer. Muting is immediate and clears buffered audio
so it is not replayed on unmute. The WAV tool keeps the original frame count,
so delayed audio/filter tails extending past the input end are trimmed.

`--peak Hz Q dB` adds a peaking band. `--filter NAME Hz Q GAIN` adds another
PEQ type. Names: `flat`, `peak`, `low-shelf`, `high-shelf`, `low-pass`,
`high-pass`, `notch`, `all-pass`, `all-pass1`, `low-shelf1`, `high-shelf1`,
`lt`, `low-pass1`, `high-pass1`. For `lt`, Hz/Q describe the original speaker
alignment, GAIN is the target frequency (not dB), and target Q defaults to
0.707. The C API also supports a custom target Q.

`--crossover NAME Hz` adds a crossover. Names are `lr2`/`lr4`/`lr6`/`lr8`,
`bw1` through `bw8`, or `bes2`/`bes4`/`bes6`/`bes8`, followed by `-lp` or `-hp`.
More than 10 PEQ or 4 crossover bands on any targeted channel is rejected.

Frequency must be positive and below Nyquist; firmware clamps the design
frequency to 10 Hz..0.45*Fs and Q to 0.1..20. Non-LT gain is limited by this
host to -30..+30 dB. LT corners additionally follow the firmware's 0.15*Fs cap.

Input supports uncompressed PCM16 RIFF WAV with 1..8 channels, including
WAVEFORMATEXTENSIBLE PCM with 16 valid bits. Output keeps the sample rate and
frame count and writes PCM16. More than two outputs use WAVEFORMATEXTENSIBLE
with an unspecified speaker mask: logical channel ordering is preserved, but
speaker positions are not inferred from the input or automatically assigned.
Existing output files are refused. Positive boosts may clip PCM16 output;
the tool reports the number of clipped samples. Start with a cut for listening.
This is an offline tool: it never opens a soundcard or changes Windows routing.

## Volume-dependent loudness

The original firmware loudness equations, shelf designer and sample processing
now run on Windows. Compensation follows the listening volume control, as it
does on the Pico; it does not follow the instantaneous signal level or the
per-output calibration trim.

```powershell
.\build\dspi-wav.exe input.wav quiet-flat.wav --volume -20
.\build\dspi-wav.exe input.wav quiet-loudness.wav --volume -20 --loudness 83 100
```

Compare these files at the same player volume. Both include the same -20 dB
listening attenuation, while the second restores some bass and treble according
to the firmware's equal-loudness model. `83` is the reference SPL parameter and
`100` is correction strength in percent; this does not measure or calibrate your
actual speaker SPL.

- `--volume dB` is global, from -60 to 0 dB. It defaults to 0 dB. The firmware's
  1 dB downward steps are used: -20.2 dB selects -21 dB; -60 dB is silence.
- `--loudness REFERENCE_SPL INTENSITY` enables correction on the selected outputs.
  Reference SPL is 40..100 and intensity is 0..200 percent.
- `--loudness-off` disables correction on the selected outputs.
- Reference/intensity are shared by all enabled outputs, while filter state is
  independent per output. With `--channel 3 --loudness-off`, for example, the
  subwoofer feed can be excluded from correction.
- At 0 dB listening volume or 0 percent intensity, correction is transparent.
- `--gain` remains a separate per-output trim and does not re-key loudness.
- Loudness requires a sample rate above 12 kHz because the firmware uses a
  fixed 6 kHz high shelf. The rest of the engine still supports 8 kHz files.

The host converts volume steps directly to floating-point gain; the Pico's Q15
volume lookup approximates those gains. Exact device-output bit parity is not
claimed. Coefficient calculations run during configuration, not in the audio
callback. Parameter changes are not smoothed yet. Loudness can add gain; the
WAV tool continues to report clipped output samples.

## Tube modeller

The firmware's original tube shaper, sag envelope, DC blocker and output-stage
model now run before crossovers/EQ, matching their place in the Pico pipeline.
The designer, kernel, 16 style rows and rectifier rows are copied from the pinned
firmware. Per-output state belongs to the graph, with no shared audio state.

```powershell
.\build\dspi-wav.exe input.wav tube.wav --tube 12ax7 6 100 --gain -3
```

`--tube STYLE DRIVE MIX` enables the selected outputs. Drive is -30..+24 dB;
mix is 0..100 percent. The shaper keeps small-signal gain approximately unity:
drive changes saturation, not a simple volume boost. A 0 percent mix is dry.
`--tube-off` disables the selected outputs.

Styles (case insensitive): `12ax7`, `5751`, `12at7`, `12ay7`, `12au7`, `6sn7`,
`6sl7`, `6dj8`, `ef86`, `6sj7`, `el84`, `el34`, `6l6`, `6v6`, `kt88`, `300b`.
Numeric IDs 1..16 match this order; `custom`/0 retains existing character values.
Selecting a named style loads the firmware's bias/asymmetry/hardness/sag row,
while preserving the other controls, like the original firmware setter.

Advanced controls:

| Option | Range / meaning |
| --- | --- |
| `--tube-drive dB` | -30..24 |
| `--tube-mix percent` | 0..100 |
| `--tube-trim dB` | -12..12, wet-path trim |
| `--tube-bias percent` | -100..100 |
| `--tube-asym dB` | -12..12 |
| `--tube-hardness percent` | 0..100 |
| `--tube-sag percent` | 0..100 |
| `--tube-rectifier NAME` | `solid-state`, `gz34`, `5u4`, `5y3` |
| `--tube-output-stage DAMPING RESONANCE_HZ` | Enable; damping 1..20, resonance 30..150 Hz |
| `--tube-no-output-stage` | Disable the output-stage model |

The defaults are the firmware's 12AX7 character, GZ34 rectifier, output stage on,
damping 2, resonance 95 Hz, mix 100 percent and wet trim 0 dB. `--tube` supplies
the drive/mix for that command. Changing bias/asymmetry/hardness/sag marks the
character custom. Advanced settings are shared by all enabled outputs and do
not enable the effect by themselves; put them after `--tube` when overriding
a named style. The output selection controls where the effect runs, while
each output maintains an independent envelope/filter state.

This is the existing DSPi sonic model, not a circuit-level simulator or a
measurement of a particular physical valve amplifier. It retains the firmware's
nonlinearity without additional oversampling, so aliasing at strong drive is
not eliminated. Parameter changes are not yet smoothed for live audio.

## Headphone crossfeed

The firmware's BS2B-derived coefficient designer, preset table and processing
kernel now run after the matrix and before tube/crossover/EQ processing.
The engine mixes a low-pass-filtered portion of each channel into the opposite
channel, with optional added all-pass delay. Pair state is independent, while
the preset/custom parameters are shared by the selected pairs.

```powershell
.\build\dspi-wav.exe input.wav headphones.wav --pair 1 --crossfeed default --gain -3
```

| Preset | Cutoff | Direct-to-crossfeed difference at DC |
| --- | ---: | ---: |
| `default` | 700 Hz | 4.5 dB |
| `chumoy` | 700 Hz | 6 dB |
| `meier` | 650 Hz | 9.5 dB |

`chu-moy` and `jan-meier` aliases are accepted. `--crossfeed-custom HZ FEED_DB`
sets 500..2000 Hz and 0..15 dB. FEED_DB is the difference between the direct
and crossfed levels at DC, so increasing it reduces the opposite-channel blend.
`--crossfeed-itd on|off` controls the added delay stage (on by default). Turning
it off retains the low-pass filter's own phase/delay.

`--pair N` selects consecutive logical outputs 1/2, 3/4, 5/6 or 7/8 for subsequent
options. It can also be used with gain, tube and other per-output controls.
`--crossfeed-off` disables the selected pairs. Default `--channel all` applies
crossfeed to every complete pair, leaving a final unpaired mono output untouched.
A half-pair selection such as `--channel left --crossfeed default` is rejected;
use `--pair 1` to select both headphone channels. Mono-only output cannot enable
crossfeed. These are logical channels, with no automatic physical speaker mapping.

Equal mono signals preserve unity at DC, and with added delay off the
complementary mix preserves equal mono signals across the spectrum. With delay
on, the response away from DC is intentionally different. Output mute remains
after the crossfeed stage. Coefficient changes clear pair history rather than
providing smooth live transitions; disabled pairs also start clean on re-enable.

## Output peak limiter

The original firmware peak detector, 16-sample gain decisions, gain ramps and
32-sample lookahead rings now run after gain/loudness and before output delay.
The host owns independent limiter state for every output and supports the
firmware's four link groups.

```powershell
.\build\dspi-wav.exe input.wav limited.wav --pair 1 --limiter -1 100 --limiter-link 1
```

- `--limiter THRESHOLD_DBFS RELEASE_MS` enables the selected outputs with a
  ceiling from -30..0 dBFS and release from 10..1000 ms.
- `--limiter-threshold dBFS` / `--limiter-release ms` changes that parameter
  without enabling an output that is currently off.
- `--limiter-link GROUP` selects 0 (independent) or group 1..4.
- `--limiter-off` disables the selected outputs.

Outputs in a nonzero group share enable/threshold/release and apply the deepest
reduction needed by any group member. Editing one member updates the group;
joining adopts the lowest-numbered existing member's settings. Leaving a group
keeps its current settings. Use `--pair 1` with a nonzero group for linked
headphone/stereo operation, or select output numbers for independent protection.

While any limiter is enabled, every output carries the same 32-sample lookahead,
including outputs whose own limiter is off. At 48 kHz this adds 0.667 ms. When
all limiters are off, that delay is removed and the limiter is transparent.
User alignment delays are additional. The WAV tool keeps the input duration,
so the last 32 samples, plus any alignment/filter tails, are trimmed rather
than extending the file. It reports lookahead and deepest measured gain reduction.

The ceiling applies to finite digital sample peaks for a fixed configuration,
not reconstructed inter-sample/analogue peaks. PCM16 rounding can differ from
the float ceiling by a quantization step. The original firmware's live silent
engage, fade, joining/draining and dual-core rendezvous are not part of this
offline port. Limiter setting changes reset its rings and envelopes; configure
it before processing, with no concurrent audio callback. Smooth live changes
remain future work.

## Bass enhancement, volume leveller and stereo upmixer

The original v1.1.6 floating-point algorithms now run in the offline engine.
Both bass effects target the outputs selected by `--channel`; the leveller
targets physical inputs and the upmixer works on the stereo input pair.

```powershell
.\build\dspi-wav.exe input.wav bass.wav --psybass 80 -6 6 50 0 --subharm -12 -12 -30 0 --limiter -1 100
.\build\dspi-wav.exe input.wav levelled.wav --leveller 50 medium 12 --limiter -1 100
.\build\dspi-wav.exe input.wav surround.wav --outputs 5 --upmix adaptive --clear-routes --route 1 1 0 --route 2 2 0 --route 3 3 0 --route 4 4 0 --route 5 5 0 --gain -6 --limiter -1 100
```

- `--psybass CUTOFF HARMONICS DRIVE CHARACTER ORIGINAL`: cutoff 30..300 Hz,
  harmonics -24..12 dB, drive 0..18 dB, character 0..100% (even to odd),
  original low-band level -60..0 dB. `--psybass-off` disables selected outputs.
- `--subharm LOW HIGH TOP BOOST`: octave-down bands 24..36, 36..56 and
  56..80 Hz, levels -30..12 dB (-30 means off), bass boost 0..6 dB.
  `--subharm-off` disables selected outputs. `--subharm-select all|percussive|sustained DEPTH HOLD_MS`
  sets selectivity, depth 0..100%, hold 50..400 ms. `--subharm-ceiling -40..0`
  limits the generated sub (0 disables that ceiling). `--subharm-link on|off`
  controls pair linking; `--subharm-solo on|off` auditions generated sub only.
- `--leveller AMOUNT slow|medium|fast MAX_BOOST`: amount 0..100%, maximum
  boost 0..35 dB. `--leveller-lookahead on|off`, `--leveller-gate -96..0`,
  `--leveller-detectors MASK`, `--leveller-apply MASK`, `--leveller-off`.
  Masks are decimal bitfields restricted to actual inputs (stereo: 1=left,
  2=right, 3=both; 0 selects none). Defaults detect and apply to all inputs.
  Gain is linked to the loudest selected detector. Its safety limiter reduces
  boost; existing loud peaks need the separate output limiter.
- `--upmix passive|adaptive` enables both engines; `--upmix-off` disables them.
  `--upmix-center off|passive|adaptive` and `--upmix-surround off|passive|adaptive`
  set engines independently. Further controls: `--upmix-strength 0..100`,
  `--upmix-width 0..100`, `--upmix-threshold 0..95`, `--upmix-attack 1..500`,
  `--upmix-release 5..2000`, `--upmix-detector-hpf 20..1000`,
  `--upmix-delay 0..20`, `--upmix-hpf 20..2000`, `--upmix-lpf 1000..20000`,
  `--upmix-decorr 0..100`, `--upmix-presence -12..12`. Times are milliseconds,
  corners Hz, presence dB; other values are percentages. Parameter-only flags
  configure without enabling an effect.

Upmix requires exactly two physical input channels at 8..48 kHz; other formats
are rejected when enabling it. Matrix sources become 1=L, 2=R, 3=C, 4=Ls,
5=Rs. Enable upmix **before** configuring derived-source routes. Existing
identity routes are preserved; derived sources start unrouted. A centre-off
source remains reserved and silent. These are five logical channels, with no
LFE, and the multichannel WAV speaker mask remains unspecified. Playback
requires a player/output setup with the corresponding channel mapping.

The host runs input effects in fixed 48-frame quanta so external buffer sizes
do not alter the result. Enabling either input effect adds 48 samples on all
sources. Leveller lookahead adds the firmware's fixed 240 samples to **all**
physical inputs, including non-applied inputs. At 48 kHz these total 1 ms
without lookahead or 6 ms with it; at 44.1 kHz, 1.088 or 6.531 ms. Output
limiter/alignment delays are additional. Surround Haas delay and allpass
conditioning are part of the upmix algorithm, additional to input-stage delay.
With decorrelation at zero the allpass becomes a 10 ms delay, as in firmware.

The WAV tool reports input-stage delay, retains the input frame count and trims
the delayed tail. No effects enabled means no input-adapter delay. Configure
before processing: bass setters reset their effect states; input-effect setters
reset the input queue, leveller and upmixer together. Smooth live edits and
preserving tails when changing settings are future work. See
`docs/four-effects-port-results.md` for test coverage and source adaptations.

## Presets, live edits and the Windows Console

`managed/Dspi.Software` provides a complete versioned JSON configuration,
atomic save/load, compatible `.dspipreset` import and a safe native session.
It preserves filter parameters (including Linkwitz target Q), routing, gains,
delays, independent master/listening volumes, bypass/mutes, all effect settings,
masks and limiter groups. Files carry
settings, not running filter/ring history. Invalid loads leave the live settings
unchanged. Import reports unsupported physical hardware settings/outputs;
active EQ beyond the ten-band host capacity is rejected, while inactive extra
bands are reported and omitted. See the managed README for API details.

Use the sibling Console's **Software DSP** mode for existing controls, input and
output peak meters, local preset files and WAV processing. Software mode starts
without initializing USB; selecting USB hardware retains the hardware path.
Stereo and eight-channel input modes are separate; upmix requires stereo at
48 kHz or below. Unsupported board/firmware actions are unavailable in software
mode. Build the native DLL before building the Console:

```powershell
.\scripts\build-windows-console.ps1 -Compiler 'C:\path\to\zig.exe'
```

The build script runs all native/WAV checks, managed preset/runtime checks and
Console tests, then builds the x64 app. .NET 8 and the Console's restored NuGet
dependencies are required. The app is not launched by this script.

Live edits use complete prepared replacement graphs. Their delay paths are
filled while the old graph remains audible, then a 10 ms fade-down reaches
zero, the graph switches, and a 10 ms fade-up applies. This deliberately allows
a brief level dip instead of interpolating arbitrary nonlinear/filter states.
It also covers bypass, preset loads and limiter switching. Same-DSP metadata
edits do not restart audio. Rapid pending edits coalesce to the latest complete
configuration. Rate/channel-format changes require a stopped processing path.

Processing the native runtime allocates/frees no memory and takes no locks;
retired graphs are collected by the control thread. Meter values come from
processed buffers (input peaks before processing, output peaks after the live
envelope), not synthetic activity. Hard real-time deadline and listening tests
are still needed before a Windows audio-device backend is considered ready.
See `docs/presets-live-console-results.md` for scope and validation.

## Live Windows audio

Choose **Software DSP -> Live Windows Audio...** in the Console. Select the
recording endpoint of an installed virtual cable, a physical playback endpoint,
the output-channel mapping and a buffer target, then press Start. Start is always
manual; the app does not install drivers, change Windows defaults, capture from
an unselected input or switch playback devices automatically.

The live route uses a bounded FIFO, adaptive clock-drift correction and
windowed-sinc resampling into the 48 kHz native engine and out to the soundcard's
actual mix rate. The default buffer target is 60 ms; capture/render queues and
DSP delays add to that. Same-format settings and presets remain editable while
running. Stop Live Audio before changing rate/channel format or processing WAVs.
Device loss stops the selected stream with a message and requires explicit restart.

VB-CABLE setup: route the source application to **CABLE Input**; capture **CABLE
Output** in the Console; select the DAC/soundcard for playback. Full installation
and routing instructions are in the Console's `docs/LIVE_WINDOWS_AUDIO.md`.
VB-CABLE was not installed on the development machine, so the physical route
still needs a user-run listening test. See `docs/live-windows-audio-results.md`.

## Current limitations

No bundled virtual driver or complete Pico USB emulation. Live audio requires
an installed cable and explicit endpoint choices. Physical playback/latency and
driver-specific recovery still require testing; endpoint changes stop safely
rather than silently switching to another device.
The host dispatches individual native sections rather than the
Pico's fused/ARM-optimized pairs, so full bit-for-bit device equivalence has
not been established. Configuration must not run concurrently with processing
on the same raw graph. The graph allocates all buffers at creation; processing
does not allocate or lock. Use `NativeSession` / `host_api.h` for live handoff;
the low-level graph setters remain static configuration APIs.

## Repositories alongside this one

- `../DSPi-Console-Windows`: original UI and control application.
- `../DSPi-Firmware`: upstream firmware checkout.
- This repository: portable host adapters, experiments and checks.

See `docs/initial-scope.md` for the next stages and `vendor/dspi/UPSTREAM.md`
for the pinned firmware provenance. Upstream source trees are not modified.

## License

GPL-3.0; see LICENSE. Includes code from WeebLabs/DSPi. This is an unofficial
experimental derivative, not an upstream DSPi release.
