using DSPiConsole.Core.Models;
using Microsoft.UI.Dispatching;
using NAudio.CoreAudioApi;

namespace DSPiConsole;

internal sealed class WindowsTestSignalPlayback(string endpointId, int channels, DispatcherQueue dispatcher) : IDisposable
{
    private WasapiMeasurementPlayer? _player;
    private MeasurementSignal? _signal;
    private SiggenConfig? _queued;
    private SiggenStatus? _finished;
    private bool _userStopped;

    public event Action? Changed;
    public string? Error { get; private set; }
    public SiggenStatus? Status => _signal?.GetStatus() ?? _finished;
    public int Channels => channels;

    public void Start(SiggenConfig config)
    {
        Error = null;
        if (_signal != null)
        {
            _queued = config.Clone();
            _signal.FadeOut();
            return;
        }
        _userStopped = false;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDevice(endpointId);
            if (device.State != DeviceState.Active)
                throw new InvalidOperationException("This Windows output is unavailable.");
            using var client = device.AudioClient;
            var format = client.MixFormat;
            if (format.Channels != channels)
                throw new InvalidOperationException("The Windows channel layout changed. Reconnect the output.");
            _signal = new MeasurementSignal(format.SampleRate, format.Channels, config);
            var player = new WasapiMeasurementPlayer(endpointId, format.SampleRate, format.Channels, _signal);
            _player = player;
            player.Stopped += error => dispatcher.TryEnqueue(() => OnStopped(player, error));
            player.Play();
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            Release();
        }
        Changed?.Invoke();
    }

    public void Stop(bool immediate)
    {
        _queued = null;
        _userStopped = true;
        if (immediate && _player != null)
        {
            _finished = _signal?.GetStatus();
            if (_finished != null) { _finished.State = SiggenState.Idle; _finished.StopReason = 1; }
            Release();
            Changed?.Invoke();
        }
        else _signal?.FadeOut();
    }

    private void OnStopped(WasapiMeasurementPlayer player, Exception? error)
    {
        if (!ReferenceEquals(_player, player)) return;
        _finished = _signal?.GetStatus();
        if (_finished != null)
        {
            _finished.State = SiggenState.Idle;
            _finished.StopReason = (byte)(_userStopped ? 1 : 2);
        }
        var next = _queued;
        _queued = null;
        Release();
        Error = error?.Message;
        if (error == null && next != null) Start(next);
        else Changed?.Invoke();
    }

    private void Release()
    {
        var player = _player;
        _player = null;
        _signal = null;
        player?.Dispose();
    }

    public void Dispose()
    {
        _queued = null;
        Release();
    }

}
