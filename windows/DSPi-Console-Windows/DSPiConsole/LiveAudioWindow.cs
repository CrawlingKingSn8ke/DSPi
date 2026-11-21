using Dspi.Audio.Windows;
using DSPiConsole.Controls;
using DSPiConsole.ViewModels;
using DSPiConsole.Usb;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DSPiConsole;

/// <summary>Explicit, opt-in shared-mode capture and playback. No defaults are modified.</summary>
public sealed class LiveAudioWindow : Window
{
    private readonly MainViewModel _vm;
    private readonly LiveAudioService _audio = new();
    private readonly ComboBox _capture = new() { Header = "Capture endpoint (VB-CABLE: CABLE Output)", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _render = new() { Header = "Playback endpoint (your DAC / soundcard)", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly NumberBox _buffer = new() { Header = "Target buffer (ms)", Minimum = 20, Maximum = 200, Value = 60, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    private readonly StackPanel _mapPanel = new() { Spacing = 6 };
    private readonly List<ComboBox> _maps = new();
    private readonly TextBlock _status = new() { Text = "Stopped. Select both endpoints explicitly, then Start.", TextWrapping = TextWrapping.Wrap };
    private readonly Button _start = new() { Content = "Start" }, _stop = new() { Content = "Stop", IsEnabled = false }, _refresh = new() { Content = "Refresh endpoints" };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private DspDevice.SoftwareLiveLease? _lease;
    private Task? _stopTask, _startTask;
    private bool _busy, _allowClose;
    private string? _lastStartError;
    public bool IsActive => _lease != null || _busy;
    public event EventHandler? StateChanged;

    public LiveAudioWindow(MainViewModel vm)
    {
        _vm = vm;
        ToolWindowChrome.Apply(this, "Live Windows Audio", 650, 740);
        var root = new StackPanel { Padding = new Thickness(20), Spacing = 12 };
        root.Children.Add(new TextBlock { Text = "Windows audio → virtual cable → DSPi → soundcard", FontSize = 19, TextWrapping = TextWrapping.Wrap });
        root.Children.Add(new TextBlock { Text = "In the source app choose CABLE Input for playback. Here capture CABLE Output, then choose your physical playback device. Start is always manual. Do not enable Windows ‘Listen to this device’ for the cable.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(new HyperlinkButton { Content = "VB-CABLE download and installation instructions", NavigateUri = new Uri("https://vb-audio.com/Cable/") });
        root.Children.Add(_capture); root.Children.Add(_render); root.Children.Add(_refresh); root.Children.Add(_buffer);
        root.Children.Add(new TextBlock { Text = "Physical playback channels ← DSP outputs", FontSize = 16 });
        root.Children.Add(new TextBlock { Text = "Every playback channel is explicit. Unmapped DSP outputs are not folded into stereo. For surround, set the matrix and these channel assignments to match your speakers.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(_mapPanel);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        buttons.Children.Add(_start); buttons.Children.Add(_stop); root.Children.Add(buttons); root.Children.Add(_status);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _render.SelectionChanged += (_, _) => BuildMap();
        _refresh.Click += (_, _) => RefreshEndpoints();
        _start.Click += async (_, _) => { try { await StartAsync(); } catch (Exception ex) { _status.Text = "Could not start or release audio: " + ex.Message; } };
        _stop.Click += async (_, _) => { try { await StopAsync(); } catch (Exception ex) { _status.Text = "Could not stop: " + ex.Message; } };
        _audio.Error += (_, e) => DispatcherQueue.TryEnqueue(async () => { try { await StopAsync(e.Message); } catch (Exception ex) { _status.Text = "Could not stop: " + ex.Message; } });
        _timer.Tick += (_, _) => UpdateStatistics();
        AppWindow.Closing += OnClosing;
        RefreshEndpoints();
    }
    private void RefreshEndpoints()
    {
        try
        {
            _capture.Items.Clear(); _render.Items.Clear();
            foreach (var d in _audio.EnumerateCaptureDevices()) _capture.Items.Add(new ComboBoxItem { Content = $"{d.Name} ({d.Channels} ch, {d.SampleRate} Hz)", Tag = d });
            // The requested destination is a soundcard. Feeding the cable's
            // playback side back into its capture side would create a loop.
            foreach (var d in _audio.EnumerateRenderDevices().Where(d => !d.IsVirtualCable)) _render.Items.Add(new ComboBoxItem { Content = $"{d.Name} ({d.Channels} ch, {d.SampleRate} Hz)", Tag = d });
            _capture.SelectedIndex = -1; _render.SelectedIndex = -1;
            if (_capture.Items.Count == 0) _status.Text = "No active capture endpoints. Install VB-CABLE manually using the link above, then Refresh endpoints. No audio has started.";
        }
        catch (Exception ex) { _status.Text = ex.Message; }
    }
    private void BuildMap()
    {
        _maps.Clear(); _mapPanel.Children.Clear();
        if ((_render.SelectedItem as ComboBoxItem)?.Tag is not AudioEndpointInfo render) return;
        for (int c = 0; c < render.Channels; c++)
        {
            var box = new ComboBox { Header = $"Playback channel {c + 1}", HorizontalAlignment = HorizontalAlignment.Stretch };
            box.Items.Add("Silence");
            for (int output = 1; output <= 8; output++) box.Items.Add($"DSP output {output}");
            box.SelectedIndex = c < 8 ? c + 1 : 0;
            _maps.Add(box); _mapPanel.Children.Add(box);
        }
    }
    private void SetBusy(bool running, bool busy)
    {
        _busy = busy;
        _capture.IsEnabled = _render.IsEnabled = _buffer.IsEnabled = _refresh.IsEnabled = !running && !busy;
        foreach (var map in _maps) map.IsEnabled = !running && !busy;
        _start.IsEnabled = !running && !busy; _stop.IsEnabled = running && !busy;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
    private Task StartAsync() => _startTask = StartCoreAsync();
    private async Task StartCoreAsync()
    {
        if (_busy || _lease != null) return;
        if ((_capture.SelectedItem as ComboBoxItem)?.Tag is not AudioEndpointInfo capture || (_render.SelectedItem as ComboBoxItem)?.Tag is not AudioEndpointInfo render)
        { _status.Text = "Choose capture and playback endpoints explicitly."; return; }
        _lastStartError = null;
        SetBusy(false, true);
        try
        {
            if (!double.IsFinite(_buffer.Value) || _buffer.Value < 20 || _buffer.Value > 200) throw new InvalidOperationException("Choose a buffer between 20 and 200 ms.");
            await _vm.PrepareForBackendSwitchAsync();
            var configuration = _vm.Device.SoftwareConfiguration;
            configuration.InputCount = capture.Channels; configuration.OutputCount = 8; configuration.SampleRate = 48000;
            if (configuration.InputCount != 2 && configuration.Upmix.Enabled) throw new InvalidOperationException("Disable stereo upmix before starting a capture endpoint with a different channel count.");
            _lease = _vm.Device.BeginSoftwareLive(configuration);
            await _audio.StartAsync(new LiveAudioStartOptions { CaptureDeviceId = capture.Id, RenderDeviceId = render.Id, ExpectedCaptureChannels = capture.Channels, EngineSampleRate = 48000, DspOutputChannels = 8, TargetBufferMilliseconds = (int)_buffer.Value, OutputMap = _maps.Select(m => m.SelectedIndex - 1).ToArray() }, _lease.Process);
            _status.Text = "Running"; _timer.Start();
        }
        catch (Exception ex)
        {
            _lastStartError = "Could not start: " + ex.Message;
            var cleanup = await StopTransportAsync();
            if (cleanup != null) _lastStartError += "\nCleanup: " + cleanup.Message;
            _status.Text = _lastStartError;
        }
        finally
        {
            SetBusy(_lease != null, false);
            _startTask = null;
        }
    }
    // The transport invalidates its generation and attempts Stop and Dispose
    // before completing, including exceptional completion. Release the native
    // lease only after the transport has detached that session.
    private async Task<Exception?> StopTransportAsync()
    {
        Exception? error = null;
        try { await _audio.StopAsync(); }
        catch (Exception ex) { error = ex; }
        if (!_audio.IsRunning)
        {
            _lease?.Dispose(); _lease = null; _timer.Stop();
        }
        return error;
    }
    public Task StopAsync() => StopAsync(null);
    private Task StopAsync(string? message)
    {
        if (_stopTask != null && !_stopTask.IsCompleted) return _stopTask;
        return _stopTask = StopCoreAsync(message);
    }
    private async Task StopCoreAsync(string? message)
    {
        try
        {
            // Failed startup must never prevent another cleanup attempt.
            if (_startTask != null)
            {
                try { await _startTask; }
                catch (Exception ex) { _lastStartError ??= "Could not start: " + ex.Message; }
            }
            SetBusy(_lease != null, true);
            var cleanup = await StopTransportAsync();
            var detail = message ?? _lastStartError;
            if (cleanup != null) detail = (detail == null ? "" : detail + "\n") + "Cleanup: " + cleanup.Message;
            _status.Text = detail == null ? "Stopped." : "Stopped: " + detail;
            if (_lease != null)
                throw new InvalidOperationException("Audio is still active. Try Stop again.", cleanup);
        }
        finally { SetBusy(_lease != null, false); _stopTask = null; }
    }
    private void UpdateStatistics()
    {
        if (_audio.Statistics is { } s) _status.Text = $"{(s.Primed ? "Running" : "Buffering")} • buffer {s.BufferedMilliseconds:F1} ms • underruns {s.UnderrunCount} • overruns {s.OverrunCount} • drift {s.CorrectionPpm:F0} ppm";
    }
    private async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose) return;
        args.Cancel = true;
        if (_busy) return;
        try { await StopAsync(); _audio.Dispose(); _allowClose = true; Close(); }
        catch (Exception ex) { _status.Text = "Could not stop: " + ex.Message; }
    }
}
