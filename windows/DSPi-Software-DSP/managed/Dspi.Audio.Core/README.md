# Live audio core

One capture producer and one render consumer use a bounded interleaved frame
FIFO. The producer copies complete frames and publishes its write cursor only
after copying. It never advances the consumer cursor or blocks on the DSP/UI.
Overflow drops the incoming packet and signals the consumer to fade/rebuffer;
it never allocates a larger queue. Non-finite input samples become zero and
increment a counter. Underruns fade the last output sample to silence, clear
resampler histories and re-prime with fresh capture audio.

Capture is resampled to the 48 kHz engine, then the engine's eight outputs are
mapped explicitly to the playback channels and resampled to the playback mix
rate. Each converter uses an interpolated 1024-phase Blackman-windowed sinc:
64 taps minimum, scaled by the decimation ratio to preserve alias rejection at
large rate differences. Coefficients and buffers are allocated at construction.
Rendering and capture enqueueing take no locks and allocate no managed memory
in the core's steady path.

Smoothed FIFO occupancy drives a bounded PI clock correction (default +/-1500
ppm), slowly adjusting input consumption to follow independent capture/render
clocks. Nominal sample-rate conversion and this small drift correction are
separate. Default FIFO target is 60 ms and capacity is 500 ms. Neither number is
a total latency promise: capture/render queues, converter lookahead, cable/app
buffers and configured DSP delays are additional.

Start and underrun recovery fade in over 10 ms. Normal stop requests a 10 ms fade
out; the Windows transport then allows the render queue to drain before stopping
callbacks. Silence continues until the transport is stopped. A stopped pipeline
is not restarted; create a fresh one to avoid replaying history.

The tests cover DC/channel mapping, priming, underrun/overrun recovery, invalid
samples, 96k -> 48k -> 44.1k pitch/amplitude, 2:1 and 6:1 alias rejection,
accelerated 150-second streams at both +300 and -300 ppm, real producer/consumer
overlap, allocation-free callbacks, and a complete 44.1k -> real native 8-output
DSP -> mapped 96k path with live parameter edits and real meters. Physical audio
devices are not opened by these tests.
