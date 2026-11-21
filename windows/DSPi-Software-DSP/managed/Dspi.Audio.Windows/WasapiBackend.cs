using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Dspi.Audio.Windows;

internal sealed class WasapiBackend : IAudioBackend
{
    public IReadOnlyList<AudioEndpointInfo> Enumerate(bool capture)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Live WASAPI audio requires Windows.");
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<AudioEndpointInfo>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(capture ? DataFlow.Capture : DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                var format = device.AudioClient.MixFormat;
                result.Add(new(device.ID, device.FriendlyName, capture, format.SampleRate, format.Channels,
                    device.FriendlyName.Contains("CABLE", StringComparison.OrdinalIgnoreCase) || device.FriendlyName.Contains("VB-Audio", StringComparison.OrdinalIgnoreCase)));
            }
        }
        return result;
    }
    public IAudioSession Open(LiveAudioStartOptions options) => new WasapiSession(options);
}

internal sealed class WasapiSession : IAudioSession, IMMNotificationClient
{
    private readonly MMDeviceEnumerator enumerator = new();
    private MMDevice? captureDevice, renderDevice;
    private WasapiCapture? capture;
    private WasapiOut? render;
    private readonly LiveAudioStartOptions options;
    private Action<Exception?>? stopped;
    private bool registered;
    public WaveFormat CaptureFormat { get; private set; } = null!;
    public WaveFormat RenderFormat { get; private set; } = null!;
    public WasapiSession(LiveAudioStartOptions options)
    {
        this.options = options;
        try
        {
            captureDevice = enumerator.GetDevice(options.CaptureDeviceId);
            renderDevice = enumerator.GetDevice(options.RenderDeviceId);
            if (captureDevice.State != DeviceState.Active || captureDevice.DataFlow != DataFlow.Capture)
                throw new InvalidOperationException("The selected capture endpoint is unavailable. Install/select a virtual cable recording endpoint and restart.");
            if (renderDevice.State != DeviceState.Active || renderDevice.DataFlow != DataFlow.Render)
                throw new InvalidOperationException("The selected playback endpoint is unavailable. Select an active playback endpoint and restart.");
            CaptureFormat = captureDevice.AudioClient.MixFormat;
            RenderFormat = renderDevice.AudioClient.MixFormat;
        }
        catch (Exception ex)
        {
            Dispose();
            throw new InvalidOperationException("Cannot open the selected audio endpoints. Ensure both are connected and enabled; then select them again. " + ex.Message, ex);
        }
    }
    public void Start(IWaveProvider provider, Action<byte[], int> onCapture, Action<Exception?> onStopped)
    {
        stopped = onStopped;
        enumerator.RegisterEndpointNotificationCallback(this); registered = true;
        capture = new WasapiCapture(captureDevice!, true, options.DeviceBufferMilliseconds) { ShareMode = AudioClientShareMode.Shared, WaveFormat = CaptureFormat };
        render = new WasapiOut(renderDevice!, AudioClientShareMode.Shared, true, options.DeviceBufferMilliseconds);
        capture.DataAvailable += (_, e) => onCapture(e.Buffer, e.BytesRecorded);
        capture.RecordingStopped += (_, e) => onStopped(e.Exception);
        render.PlaybackStopped += (_, e) => onStopped(e.Exception);
        render.Init(provider);
        capture.StartRecording();
        render.Play();
    }
    public void Stop()
    {
        // Called only by lifecycle worker, never on an audio callback thread.
        capture?.StopRecording();
        render?.Stop();
    }
    public void Dispose()
    {
        if (registered) { enumerator.UnregisterEndpointNotificationCallback(this); registered = false; }
        try { capture?.Dispose(); } finally
        {
            capture = null;
            try { render?.Dispose(); } finally
            {
                render = null; captureDevice?.Dispose(); captureDevice = null;
                renderDevice?.Dispose(); renderDevice = null; enumerator.Dispose();
            }
        }
    }
    private bool Selected(string id) => id == options.CaptureDeviceId || id == options.RenderDeviceId;
    private void Lost(string id) { if (Selected(id)) stopped?.Invoke(new IOException("The selected audio endpoint was disconnected or disabled. Reconnect it and restart live audio.")); }
    public void OnDeviceStateChanged(string id, DeviceState state) { if (state != DeviceState.Active) Lost(id); }
    public void OnDeviceRemoved(string id) => Lost(id);
    public void OnDeviceAdded(string id) { }
    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string id) { }
    public void OnPropertyValueChanged(string id, PropertyKey key)
    {
        if (Selected(id)) stopped?.Invoke(new IOException("The selected audio endpoint configuration changed. Restart live audio to use its current format."));
    }
}
