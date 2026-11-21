using Dspi.Software;

namespace DSPiConsole.Usb;

public partial class DspDevice
{
    private SoftwareLiveLease? _softwareLive;
    public bool IsSoftwareLive => Volatile.Read(ref _softwareLive) != null;

    private void RequireSoftwareStopped()
    {
        if (_softwareLive != null) throw new InvalidOperationException("Stop Live Audio before changing the backend, sample rate or channel layout.");
    }

    /// <summary>The caller must stop and join audio callbacks before disposing this lease.</summary>
    public SoftwareLiveLease BeginSoftwareLive(EngineConfiguration configuration)
    {
        lock (_lock) RequireWindowsApoUnbound();
        configuration = configuration.Clone();
        configuration.Validate();
        if (configuration.SampleRate != 48000 || configuration.OutputCount != 8)
            throw new ArgumentException("Live Audio requires the 48 kHz engine and eight DSP outputs.");
        SoftwareLiveLease lease;
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            RequireWindowsApoUnbound();
            RequireSoftwareStopped();
            if (_softwareFileProcessing) throw new InvalidOperationException("Wait for WAV processing to finish before starting Live Audio.");
            // A new physical stream starts with empty rings/envelopes, including
            // when its format matches a previous offline file or live session.
            var previous = RequireSoftware();
            var replacement = new NativeSession(configuration);
            previous.Dispose();
            _software = replacement;
            NumInputChannels = configuration.InputCount;
            NumOutputChannels = configuration.OutputCount;
            NumChannels = NumInputChannels + NumOutputChannels;
            lease = new SoftwareLiveLease(this, _software!);
            Volatile.Write(ref _softwareLive, lease);
        }
        BulkInvalidated?.Invoke(this, ParamSource.HostSet);
        return lease;
    }

    public sealed class SoftwareLiveLease : IDisposable
    {
        private readonly DspDevice _owner;
        private readonly NativeSession _session;
        private int _ended, _processing;
        internal SoftwareLiveLease(DspDevice owner, NativeSession session) { _owner = owner; _session = session; }
        public void Process(float[] input, float[] output, int frames)
        {
            if (Volatile.Read(ref _ended) != 0) throw new ObjectDisposedException(nameof(SoftwareLiveLease));
            Interlocked.Increment(ref _processing);
            try
            {
                if (Volatile.Read(ref _ended) != 0) throw new ObjectDisposedException(nameof(SoftwareLiveLease));
                // Never take the device control lock: graph preparation may be expensive.
                _session.Process(input, output, frames);
            }
            finally { Interlocked.Decrement(ref _processing); }
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _ended, 1) != 0) return;
            var spin = new SpinWait();
            while (Volatile.Read(ref _processing) != 0) spin.SpinOnce();
            lock (_owner._lock)
                if (ReferenceEquals(_owner._softwareLive, this)) Volatile.Write(ref _owner._softwareLive, null);
        }
    }
}
