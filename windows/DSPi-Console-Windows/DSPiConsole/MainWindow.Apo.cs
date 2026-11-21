using Dspi.Audio.Windows;
using Microsoft.UI.Xaml.Controls;
using Dspi.Software;
using DSPiConsole.Models;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using Microsoft.UI.Xaml;

namespace DSPiConsole;

public sealed partial class MainWindow
{
    private bool _openingWindowsOutput;
    private bool _restoringWindowsApoLinks;

    private async void OnWindowsApoClick(object sender, RoutedEventArgs e)
    {
        if (_softwareFileBusy || _openingWindowsOutput) return;
        _openingWindowsOutput = true;
        try
        {
            var outputs = await Task.Run(() =>
            {
                using var discovery = new LiveAudioService();
                return discovery.EnumerateRenderDevices()
                    .Where(device => !device.IsVirtualCable)
                    .Select(device => (Device: device, Attached: IsWindowsDspAttached(device.Id)))
                    .ToArray();
            });
            if (_closedWindowsControls) return;
            var picker = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedRight };
            string? current = ViewModel.Device.WindowsApoEndpointId;
            foreach (var (endpoint, attached) in outputs)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = attached ? endpoint.Name : $"{endpoint.Name} (DSPi not attached)",
                    IsChecked = string.Equals(current, endpoint.Id, StringComparison.OrdinalIgnoreCase),
                    IsEnabled = attached
                };
                item.Click += async (_, _) =>
                {
                    if (ViewModel.Device.WindowsApoEndpointId == endpoint.Id) return;
                    try { await ConnectWindowsApoAsync(endpoint); }
                    catch (Exception ex) { await ShowErrorDialog(ex.Message); }
                };
                picker.Items.Add(item);
            }
            if (outputs.Length == 0)
                picker.Items.Add(new MenuFlyoutItem { Text = "No Windows playback devices", IsEnabled = false });
            if (current != null)
            {
                picker.Items.Add(new MenuFlyoutSeparator());
                var disconnect = new MenuFlyoutItem { Text = "Disconnect controls" };
                disconnect.Click += async (_, _) =>
                {
                    try { await DisconnectWindowsApoAsync(); }
                    catch (Exception ex) { await ShowErrorDialog(ex.Message); }
                };
                picker.Items.Add(disconnect);
            }
            else
            {
                var detach = new MenuFlyoutSubItem { Text = "Detach DSPi from Output..." };
                foreach (var (endpoint, attached) in outputs)
                {
                    if (!attached) continue;
                    var item = new MenuFlyoutItem { Text = endpoint.Name };
                    item.Click += async (_, _) =>
                    {
                        try { await DetachWindowsApoAsync(endpoint.Id); }
                        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
                    };
                    detach.Items.Add(item);
                }
                if (detach.Items.Count > 0)
                {
                    picker.Items.Add(new MenuFlyoutSeparator());
                    picker.Items.Add(detach);
                }
            }
            picker.ShowAt(DeviceSelectorBtn);
        }
        catch (Exception ex)
        {
            if (!_closedWindowsControls) await ShowErrorDialog(ex.Message);
        }
        finally { _openingWindowsOutput = false; }
    }
    private async void RestoreWindowsApoConnectionOnStartup(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) return;
        Activated -= RestoreWindowsApoConnectionOnStartup;
        string? setupOutput = Environment.GetEnvironmentVariable("DSPI_SETUP_OUTPUT");
        string? remembered = setupOutput ?? AppSettings.Instance.WindowsApoControlEndpointId;
        if (remembered == string.Empty) return;

        try
        {
            var endpoint = await Task.Run(() => FindStartupOutput(remembered));
            if (endpoint != null && !ViewModel.Device.IsWindowsApo && !_softwareFileBusy)
                await ConnectWindowsApoAsync(endpoint, useStartupPreset: setupOutput == null, rememberOutput: setupOutput == null);
        }
        catch (Exception ex)
        {
            // An unplugged, changed or unavailable endpoint should leave the
            // playback chooser usable. Preserve the preference for next launch.
            System.Diagnostics.Debug.WriteLine($"DSPi could not restore playback controls: {ex.Message}");
        }
    }

    private static AudioEndpointInfo? FindStartupOutput(string? remembered)
    {
        if (remembered == null)
        {
            using var enumerator = new MMDeviceEnumerator();
            if (!enumerator.HasDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)) return null;
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            remembered = device.ID;
        }

        if (!IsWindowsDspAttached(remembered)) return null;
        using var discovery = new LiveAudioService();
        return discovery.EnumerateRenderDevices().FirstOrDefault(output =>
            !output.IsVirtualCable && string.Equals(output.Id, remembered, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsWindowsDspAttached(string endpointId)
    {
        const string endpointPrefix = "{0.0.0.00000000}.";
        if (!endpointId.StartsWith(endpointPrefix, StringComparison.OrdinalIgnoreCase) ||
            !Guid.TryParseExact(endpointId[endpointPrefix.Length..], "B", out var id)) return false;
        string effectsKey = $@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{id:B}\FxProperties";
        var effect = Registry.GetValue(effectsKey, "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7", null) as string;
        return string.Equals(effect, "{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}", StringComparison.OrdinalIgnoreCase);
    }

    private static void RememberWindowsApoOutput(string endpointId)
    {
        var settings = AppSettings.Instance;
        if (settings.WindowsApoControlEndpointId == endpointId) return;
        settings.WindowsApoControlEndpointId = endpointId;
        settings.Save();
    }

    private Task ConnectWindowsApoAsync(AudioEndpointInfo endpoint) => ConnectWindowsApoAsync(endpoint, useStartupPreset: false);

    private async Task ConnectWindowsApoAsync(AudioEndpointInfo endpoint, bool useStartupPreset, bool rememberOutput = true)
    {
        if (_softwareFileBusy) throw new InvalidOperationException("Wait for the current operation to finish.");
        _softwareFileBusy = true; ApplySoftwareMenuState();
        try
        {
            CloseWindowsTestSignals();
            await StopLiveAudioAsync();
            await ViewModel.PrepareForBackendSwitchAsync();
            EngineConfiguration? startup = useStartupPreset ? GetStartupPreset(endpoint) : null;
            var names = await Task.Run(() => ReadSpeakerNames(endpoint));
            ViewModel.SetWindowsSpeakerNames(names);
            await Task.Run(() => ViewModel.Device.UseWindowsApo(endpoint.Id, endpoint.Name, endpoint.SampleRate,
                endpoint.Channels, startupPreset: startup));
            if (rememberOutput) RememberWindowsApoOutput(endpoint.Id);
            RestorePairLinksForDevice();
            RefreshWindowsVolume();
            RefreshWindowsPresetComboBox();
        }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }
    private static string[] ReadSpeakerNames(AudioEndpointInfo endpoint)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var device = enumerator.GetDevice(endpoint.Id);
        using var audio = device.AudioClient;
        var format = audio.MixFormat;
        return format.Channels == endpoint.Channels
            ? WindowsSpeakerLayout.GetLabels(format)
            : WindowsSpeakerLayout.GetLabels(endpoint.Channels, 0);
    }

    private async Task DisconnectWindowsApoAsync()
    {
        if (!ViewModel.Device.IsWindowsApo || _softwareFileBusy) return;
        _softwareFileBusy = true; ApplySoftwareMenuState();
        try
        {
            CloseWindowsTestSignals();
            await ViewModel.PrepareForBackendSwitchAsync();
            ViewModel.Device.Disconnect();
            ViewModel.SetWindowsSpeakerNames([]);
            RememberWindowsApoOutput(string.Empty);
            RefreshWindowsPresetComboBox();
        }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }
}
