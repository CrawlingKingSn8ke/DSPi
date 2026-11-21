using Dspi.Audio.Core;
using NAudio.Wave;

namespace Dspi.Audio.Windows;

public sealed record AudioEndpointInfo(string Id, string Name, bool IsCapture, int SampleRate, int Channels, bool IsVirtualCable);
public sealed class LiveAudioStartOptions
{
    public string CaptureDeviceId { get; init; } = "";
    public string RenderDeviceId { get; init; } = "";
    public int EngineSampleRate { get; init; } = 48000;
    public int ExpectedCaptureChannels { get; init; }
    public int DspOutputChannels { get; init; } = 8;
    public int[] OutputMap { get; init; } = [];
    public int TargetBufferMilliseconds { get; init; } = 60;
    public int DeviceBufferMilliseconds { get; init; } = 20;
}
public sealed class LiveAudioErrorEventArgs(string message, Exception exception) : EventArgs
{
    public string Message { get; } = message;
    public Exception Exception { get; } = exception;
}
internal interface IAudioBackend
{
    IReadOnlyList<AudioEndpointInfo> Enumerate(bool capture);
    IAudioSession Open(LiveAudioStartOptions options);
}
internal interface IAudioSession : IDisposable
{
    WaveFormat CaptureFormat { get; }
    WaveFormat RenderFormat { get; }
    void Start(IWaveProvider render, Action<byte[], int> capture, Action<Exception?> stopped);
    void Stop();
}

/// <summary>Explicit endpoint routing. No audio is opened until StartAsync is called.</summary>
public sealed class LiveAudioService : IDisposable
{
    private readonly IAudioBackend backend;
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private IAudioSession? session;
    private AdaptiveAudioPipeline? pipeline;
    private long generation;
    private int deviceBufferMilliseconds;
    private bool disposed;
    public event EventHandler<LiveAudioErrorEventArgs>? Error;
    public event EventHandler? Stopped;
    public bool IsRunning => Volatile.Read(ref session) != null;
    public LivePipelineStatistics? Statistics => Volatile.Read(ref pipeline)?.Statistics;
    public LiveAudioService() : this(new WasapiBackend()) { }
    internal LiveAudioService(IAudioBackend backend) => this.backend = backend;
    public IReadOnlyList<AudioEndpointInfo> EnumerateCaptureDevices() => backend.Enumerate(true);
    public IReadOnlyList<AudioEndpointInfo> EnumerateRenderDevices() => backend.Enumerate(false);

    public async Task StartAsync(LiveAudioStartOptions options, AudioProcessCallback process)
    {
        ArgumentNullException.ThrowIfNull(options); ArgumentNullException.ThrowIfNull(process);
        await lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (session != null) throw new InvalidOperationException("Stop live audio before starting another session.");
            if (string.IsNullOrWhiteSpace(options.CaptureDeviceId) || string.IsNullOrWhiteSpace(options.RenderDeviceId))
                throw new ArgumentException("Select both a capture endpoint (for example VB-CABLE Output) and a physical playback endpoint.");
            if (options.EngineSampleRate != 48000) throw new ArgumentException("The DSP engine requires 48000 Hz.");
            if (options.DeviceBufferMilliseconds < 10 || options.DeviceBufferMilliseconds > 500) throw new ArgumentOutOfRangeException(nameof(options.DeviceBufferMilliseconds));
            var epoch = Interlocked.Increment(ref generation);
            // Construct on a worker thread so NAudio does not capture a UI synchronization context.
            await Task.Run(() =>
            {
                IAudioSession? opened = null;
                try
                {
                    opened = backend.Open(options);
                    var decoder = new PcmDecoder(opened.CaptureFormat);
                    if (options.ExpectedCaptureChannels != 0 && decoder.Channels != options.ExpectedCaptureChannels)
                        throw new InvalidOperationException("The capture endpoint channel count changed. Refresh devices, select the endpoint again, and restart.");
                    _ = new PcmDecoder(opened.RenderFormat);
                    var next = new AdaptiveAudioPipeline(opened.CaptureFormat.SampleRate, decoder.Channels, options.EngineSampleRate,
                        options.DspOutputChannels, opened.RenderFormat.SampleRate, opened.RenderFormat.Channels,
                        (int[])options.OutputMap.Clone(), process, new LivePipelineOptions { TargetBufferMilliseconds = options.TargetBufferMilliseconds });
                    var scratch = new float[4096 * decoder.Channels];
                    var provider = new PipelineWaveProvider(next, opened.RenderFormat.SampleRate, opened.RenderFormat.Channels,
                        () => Volatile.Read(ref generation) == epoch, ex => Fault(epoch, ex));
                    pipeline = next;
                    deviceBufferMilliseconds = options.DeviceBufferMilliseconds;
                    session = opened;
                    opened.Start(provider, (data, count) =>
                    {
                        if (Volatile.Read(ref generation) != epoch) return;
                        try
                        {
                            if (count < 0 || count > data.Length || count % decoder.BlockAlign != 0) throw new InvalidDataException("Capture supplied an incomplete audio frame.");
                            for (int offset = 0; offset < count;)
                            {
                                int length = Math.Min(count - offset, 4096 * decoder.BlockAlign);
                                decoder.Decode(data.AsSpan(offset, length), scratch);
                                next.PushCapture(scratch, 0, length / decoder.BlockAlign);
                                offset += length;
                            }
                        }
                        catch (Exception ex) { Fault(epoch, ex); }
                    }, ex => Fault(epoch, ex ?? new IOException("The selected audio endpoint stopped. Select devices and restart live audio.")));
                }
                catch
                {
                    Interlocked.Increment(ref generation);
                    session = null;
                    try { opened?.Dispose(); } catch { }
                    throw;
                }
            }).ConfigureAwait(false);
        }
        finally { lifecycle.Release(); }
    }
    private void Fault(long epoch, Exception exception)
    {
        // Never Stop/Dispose from NAudio's capture or render thread: those methods join it.
        _ = Task.Run(async () =>
        {
            await lifecycle.WaitAsync().ConfigureAwait(false);
            bool stopped = false;
            try
            {
                if (epoch != Volatile.Read(ref generation) || session == null) return;
                try { StopLocked(); } catch (Exception cleanup) { exception = new AggregateException(exception, cleanup); }
                stopped = true;
            }
            finally { lifecycle.Release(); }
            if (stopped)
            {
                try { Error?.Invoke(this, new(exception.Message, exception)); } catch { }
                try { Stopped?.Invoke(this, EventArgs.Empty); } catch { }
            }
        });
    }
    private void StopLocked()
    {
        Interlocked.Increment(ref generation);
        var previous = session; session = null;
        if (previous == null) return;
        Exception? stopError = null;
        try { previous.Stop(); } catch (Exception ex) { stopError = ex; }
        try { previous.Dispose(); }
        catch (Exception disposeError) when (stopError != null) { throw new AggregateException(stopError, disposeError); }
        if (stopError != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(stopError).Throw();
    }
    public async Task StopAsync()
    {
        await lifecycle.WaitAsync().ConfigureAwait(false);
        bool hadSession;
        try
        {
            hadSession = session != null;
            if (hadSession)
            {
                pipeline?.RequestStop();
                // Keep callbacks alive while Core emits its fade and the shared device drains.
                await Task.Delay(Math.Min(250, deviceBufferMilliseconds * 2 + 20)).ConfigureAwait(false);
            }
            await Task.Run(StopLocked).ConfigureAwait(false);
        }
        finally { lifecycle.Release(); }
        if (hadSession) Stopped?.Invoke(this, EventArgs.Empty);
    }
    public void Dispose()
    {
        lifecycle.Wait();
        try { if (disposed) return; disposed = true; StopLocked(); }
        finally { lifecycle.Release(); }
    }
}
internal sealed class PipelineWaveProvider(AdaptiveAudioPipeline pipeline, int rate, int channels, Func<bool> active, Action<Exception> fault) : IWaveProvider
{
    private readonly float[] scratch = new float[4096 * channels];
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(rate, channels);
    public int Read(byte[] buffer, int offset, int count)
    {
        int start = offset;
        Array.Clear(buffer, offset, count);
        if (!active()) return count;
        try
        {
            int frames = count / WaveFormat.BlockAlign;
            while (frames > 0)
            {
                int n = Math.Min(frames, 4096);
                pipeline.Render(scratch, 0, n);
                Buffer.BlockCopy(scratch, 0, buffer, offset, n * WaveFormat.BlockAlign);
                offset += n * WaveFormat.BlockAlign; frames -= n;
            }
        }
        catch (Exception ex) { Array.Clear(buffer, start, count); fault(ex); }
        return count;
    }
}
