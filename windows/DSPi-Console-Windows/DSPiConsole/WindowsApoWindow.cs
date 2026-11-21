using Dspi.Apo;
using Dspi.Audio.Windows;
using DSPiConsole.Controls;
using DSPiConsole.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NAudio.CoreAudioApi;

namespace DSPiConsole;

/// <summary>Native endpoint controls and observed APO state. No device installation.</summary>
public sealed class WindowsApoWindow : Window
{
    private readonly MainViewModel _vm;
    private readonly Func<AudioEndpointInfo, Task> _connect;
    private readonly Func<Task> _disconnect;
    private readonly Func<string, XamlRoot?, Task> _detach;
    private readonly ComboBox _outputs = new() { Header = "Windows playback device", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button _refresh = new() { Content = "Refresh devices" };
    private readonly Button _connectButton = new() { Content = "Connect controls", IsEnabled = false };
    private readonly Button _disconnectButton = new() { Content = "Disconnect controls", IsEnabled = false };
    private readonly Button _detachButton = new() { Content = "Detach DSPi...", IsEnabled = false };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _details = new() { TextWrapping = TextWrapping.Wrap, Opacity = .75 };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _busy, _reading, _closed;
    private string? _operationError;

    public WindowsApoWindow(MainViewModel vm, Func<AudioEndpointInfo, Task> connect, Func<Task> disconnect, Func<string, XamlRoot?, Task> detach)
    {
        _vm = vm; _connect = connect; _disconnect = disconnect; _detach = detach;
        ToolWindowChrome.Apply(this, "Windows Audio — DSPi APO", 650, 470);
        var root = new StackPanel { Padding = new Thickness(20), Spacing = 14 };
        root.Children.Add(new TextBlock { Text = "Windows audio → DSPi → your playback device", FontSize = 20, TextWrapping = TextWrapping.Wrap });
        root.Children.Add(new TextBlock { Text = "Choose the device your apps already play through. The standalone DSPi APO must be installed on that output before its controls can connect. Selecting a device here does not change Windows' default output.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(_outputs); root.Children.Add(_refresh);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        buttons.Children.Add(_connectButton); buttons.Children.Add(_disconnectButton); buttons.Children.Add(_detachButton); root.Children.Add(buttons);
        root.Children.Add(_status); root.Children.Add(_details);
        root.Children.Add(new TextBlock { Text = "Closing the Console or disconnecting controls leaves endpoint processing running. Use Bypass in the main controls to save a bypass setting; a change in lookahead may require playback to restart.", TextWrapping = TextWrapping.Wrap, Opacity = .75 });
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _outputs.SelectionChanged += async (_, _) => { _operationError = null; await RefreshStatusAsync(); };
        _refresh.Click += async (_, _) => await RefreshDevicesAsync();
        _connectButton.Click += async (_, _) => await ConnectAsync();
        _disconnectButton.Click += async (_, _) => await DisconnectAsync();
        _detachButton.Click += async (_, _) => await DetachAsync();
        _timer.Tick += async (_, _) => await RefreshStatusAsync();
        AppWindow.Closing += (_, args) => { if (_busy) args.Cancel = true; };
        Closed += (_, _) => { _closed = true; _timer.Stop(); };
        _timer.Start();
        _ = RefreshDevicesAsync();
    }

    private AudioEndpointInfo? Selected => (_outputs.SelectedItem as ComboBoxItem)?.Tag as AudioEndpointInfo;
    private void SetBusy(bool busy)
    {
        if (_closed) return;
        _busy = busy; _outputs.IsEnabled = _refresh.IsEnabled = !busy;
        _connectButton.IsEnabled = !busy && Selected != null;
        _disconnectButton.IsEnabled = !busy && _vm.Device.IsWindowsApo;
        _detachButton.IsEnabled = !busy && Selected != null;
    }

    private async Task RefreshDevicesAsync()
    {
        if (_busy || _closed) return;
        SetBusy(true);
        string? selected = Selected?.Id ?? _vm.Device.WindowsApoEndpointId;
        try
        {
            var (devices, defaultId) = await Task.Run(() =>
            {
                using var discovery = new LiveAudioService();
                using var enumerator = new MMDeviceEnumerator();
                using var defaultDevice = enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                    ? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia) : null;
                return (discovery.EnumerateRenderDevices().Where(d => !d.IsVirtualCable).ToArray(), defaultDevice?.ID);
            });
            if (!devices.Any(device => device.Id == selected)) selected = defaultId;
            if (_closed) return;
            _outputs.Items.Clear();
            foreach (var device in devices)
            {
                var item = new ComboBoxItem { Content = $"{device.Name} ({device.Channels} ch, {device.SampleRate:N0} Hz)", Tag = device };
                _outputs.Items.Add(item);
                if (device.Id == selected) _outputs.SelectedItem = item;
            }
            _status.Text = devices.Length == 0 ? "No active Windows playback devices found." : "Select your playback device to inspect its DSPi status.";
        }
        catch (Exception ex) { if (!_closed) _status.Text = "Could not list playback devices: " + ex.Message; }
        finally { SetBusy(false); }
        await RefreshStatusAsync();
    }

    private async Task ConnectAsync()
    {
        if (_busy || Selected is not { } endpoint) return;
        _operationError = null;
        SetBusy(true);
        try { await _connect(endpoint); }
        catch (Exception ex) { _operationError = ex.Message; _status.Text = ex.Message; }
        finally { SetBusy(false); }
        await RefreshStatusAsync();
    }

    private async Task DisconnectAsync()
    {
        if (_busy) return;
        _operationError = null;
        SetBusy(true);
        try { await _disconnect(); }
        catch (Exception ex) { _operationError = ex.Message; _status.Text = ex.Message; }
        finally { SetBusy(false); }
        await RefreshStatusAsync();
    }

    private async Task DetachAsync()
    {
        if (_busy || Selected is not { } endpoint) return;
        _operationError = null;
        SetBusy(true);
        try { await _detach(endpoint.Id, Content.XamlRoot); }
        catch (Exception ex) { _operationError = ex.Message; }
        finally { SetBusy(false); }
        await RefreshStatusAsync();
    }

    private async Task RefreshStatusAsync()
    {
        if (_busy || _reading || _closed || Selected is not { } endpoint) return;
        _reading = true;
        try
        {
            var client = new ApoProfileClient(ApoProfileClient.DefaultRoot, endpoint.Id);
            var statuses = await Task.Run(client.ReadStatuses);
            if (_closed || Selected?.Id != endpoint.Id) return;
            bool provisioned = Directory.Exists(client.DirectoryPath);
            bool bound = _vm.Device.IsWindowsApo && _vm.Device.WindowsApoEndpointId == endpoint.Id;
            _connectButton.IsEnabled = provisioned && !_busy;
            _disconnectButton.IsEnabled = _vm.Device.IsWindowsApo && !_busy;
            var active = statuses.Where(s => s.IsFresh && s.Status != 5).ToArray();
            if (!provisioned) _status.Text = "DSPi APO is not set up on this output yet. Installation is required before you can connect its controls.";
            else if (active.Length == 0) _status.Text = "No running DSPi APO detected. Saved settings are available; play audio after DSPi has been installed and enabled on this output.";
            else
            {
                ulong desired = bound ? _vm.Device.WindowsApoDesiredRevision : 0;
                if (active.Any(s => s.ActualRate != endpoint.SampleRate || s.PhysicalChannels != endpoint.Channels))
                    _status.Text = "The device's audio format has changed. Refresh devices before reconnecting controls.";
                else if (active.Any(s => s.PendingRestartRevision != 0 && (!bound || s.PendingRestartRevision == desired)))
                    _status.Text = "Settings saved. A lookahead change needs playback to restart; earlier settings remain active.";
                else if (active.Any(s => s.Status is 2 or 4))
                    _status.Text = "DSPi could not apply the latest settings. Earlier audio settings are retained. Check the device format and preset.";
                else if (bound && active.Any(s => s.AppliedRevision != desired))
                    _status.Text = "Settings saved; waiting for DSPi to apply them.";
                else _status.Text = active.Any(s => s.IsProcessing) ? "Processing Windows audio through DSPi." : "DSPi is loaded and waiting for audio.";
            }
            _details.Text = bound
                ? $"Controls connected to {endpoint.Name}. Saved revision {_vm.Device.WindowsApoDesiredRevision}. {endpoint.SampleRate:N0} Hz · {endpoint.Channels} channels."
                : "Controls are not connected to this output. Device selection alone does not start processing.";
            if (active.Length > 0) _details.Text += $"\n{active.Length} active APO instance(s); applied revision(s): {string.Join(", ", active.Select(s => s.AppliedRevision).Distinct())}.";
            if (_operationError != null) _status.Text = _operationError + "\n\n" + _status.Text;
        }
        catch (Exception ex) { if (!_closed) _status.Text = "Could not read DSPi status: " + ex.Message; }
        finally { _reading = false; }
    }
}
