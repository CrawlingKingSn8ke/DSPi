using System.Diagnostics;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NAudio.CoreAudioApi;

namespace DSPiConsole;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _windowsVolumeTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private MMDeviceEnumerator? _windowsVolumeEnumerator;
    private MMDevice? _windowsVolumeDevice;
    private string? _windowsVolumeEndpoint;
    private readonly DispatcherTimer _windowsStatusTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _readingWindowsStatus;
    private bool _closedWindowsControls;
    private TestSignalsWindow? _windowsSignals;


    private void InitializeWindowsConsole()
    {
        Activated += RestoreWindowsApoConnectionOnStartup;
        InitializeNamedPresets();
        // Named elements still used by the shared controller are detached from
        // the menu so their commands and keyboard shortcuts cannot be invoked.
        foreach (var item in new MenuFlyoutItemBase[] { SettingsMenuItem, SaveMasterVolumeMenuItem, SaveOutputConfigMenuItem })
            MainMenu.Items.Remove(item);
        foreach (var item in MainMenu.Items.OfType<MenuFlyoutItem>().Where(item => item.Text == "Save Preset").ToArray())
            MainMenu.Items.Remove(item);
        var import = MainMenu.Items.OfType<MenuFlyoutSubItem>().Single(item => item.Text == "Import");
        var export = MainMenu.Items.OfType<MenuFlyoutSubItem>().Single(item => item.Text == "Export");
        import.Items.Remove(ImportPresetMenuItem);
        export.Items.Remove(ExportPresetMenuItem);
        SoftwareMenu.Items.Remove(CaptureAudioMenuItem);
        SoftwareMenu.Items.Remove(ProcessSoftwareWavMenuItem);
        SidebarSettingsBtn.Visibility = Visibility.Collapsed;
        SidebarStatsBtn.Visibility = Visibility.Collapsed;
        Cpu0Meter.Visibility = Visibility.Collapsed;
        SidebarVolumeModeLabel.IsHitTestVisible = false;
        SidebarVolumeModeLabel.Text = "Windows volume";
        SetSidebarSliderTint((Windows.UI.Color)Application.Current.Resources["SystemAccentColor"]);
        _updatingMasterVolumeSlider = true;
        try
        {
            MasterVolumeSlider.Maximum = 100;
            MasterVolumeSlider.SmallChange = 1;
            MasterVolumeSlider.LargeChange = 10;
        }
        finally { _updatingMasterVolumeSlider = false; }
        RefreshWindowsVolume();
        _windowsVolumeTimer.Tick += (_, _) => RefreshWindowsVolume();
        _windowsVolumeTimer.Start();
        _windowsStatusTimer.Tick += async (_, _) => await UpdateWindowsProcessingNotice();
        _windowsStatusTimer.Start();
        Closed += (_, _) =>
        {
            _closedWindowsControls = true;
            CloseWindowsTestSignals();
            _windowsStatusTimer.Stop();
            _windowsVolumeTimer.Stop();
            CloseWindowsVolumeDevice();
            _windowsVolumeEnumerator?.Dispose();
        };
    }

    private async Task UpdateWindowsProcessingNotice()
    {
        if (_readingWindowsStatus || _closedWindowsControls) return;
        if (ViewModel.Device.WindowsApoEndpointId is not { } endpoint)
        {
            SetWindowsProcessingNotice(null);
            return;
        }
        ulong revision = ViewModel.Device.WindowsApoDesiredRevision;
        _readingWindowsStatus = true;
        try
        {
            var statuses = await Task.Run(ViewModel.Device.GetWindowsApoStatuses);
            if (_closedWindowsControls || ViewModel.Device.WindowsApoEndpointId != endpoint ||
                ViewModel.Device.WindowsApoDesiredRevision != revision) return;
            bool pending = statuses.Any(s => s.IsFresh && s.Status != 5 && s.PendingRestartRevision == revision);
            SetWindowsProcessingNotice(pending ? "DSP settings saved. Restart playback to apply the lookahead change." : null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            if (!_closedWindowsControls) SetWindowsProcessingNotice(null);
        }
        finally { _readingWindowsStatus = false; }
    }

    private void SetWindowsProcessingNotice(string? text)
    {
        WindowsProcessingNotice.Text = text ?? "";
        WindowsProcessingNotice.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnWindowsTestSignalsClick(object sender, RoutedEventArgs e)
    {
        if (_softwareFileBusy || !ViewModel.Device.IsWindowsApo ||
            ViewModel.WindowsSpeakerNames.Count == 0) return;
        if (_windowsSignals == null)
        {
            _windowsSignals = new TestSignalsWindow(ViewModel);
            _windowsSignals.Closed += (_, _) => _windowsSignals = null;
        }
        _windowsSignals.Activate();
    }

    private void CloseWindowsTestSignals() => _windowsSignals?.Close();

    private void CloseWindowsVolumeDevice()
    {
        _windowsVolumeDevice?.Dispose();
        _windowsVolumeDevice = null;
        _windowsVolumeEndpoint = null;
    }

    private void RefreshWindowsVolume()
    {
        _updatingMasterVolumeSlider = true;
        try
        {
            string? endpoint = ViewModel.Device.WindowsApoEndpointId;
            if (endpoint != _windowsVolumeEndpoint)
            {
                CloseWindowsVolumeDevice();
                if (endpoint != null)
                {
                    _windowsVolumeEnumerator ??= new MMDeviceEnumerator();
                    _windowsVolumeDevice = _windowsVolumeEnumerator.GetDevice(endpoint);
                    _windowsVolumeEndpoint = endpoint;
                }
            }
            if (_windowsVolumeDevice?.State == DeviceState.Active)
            {
                var volume = _windowsVolumeDevice.AudioEndpointVolume;
                var percent = volume.Mute ? 0 : Math.Round(volume.MasterVolumeLevelScalar * 100);
                MasterVolumeSlider.Value = percent;
                MasterVolumeValueText.Text = $"{percent}%";
                MasterVolumeSlider.IsEnabled = true;
                return;
            }
        }
        catch (System.Runtime.InteropServices.COMException) { CloseWindowsVolumeDevice(); }
        finally { _updatingMasterVolumeSlider = false; }

        MasterVolumeSlider.IsEnabled = false;
        MasterVolumeValueText.Text = "—";
    }

    private void SetWindowsVolume(double percent)
    {
        if (_windowsVolumeDevice == null || _windowsVolumeEndpoint != ViewModel.Device.WindowsApoEndpointId) return;
        try
        {
            var volume = _windowsVolumeDevice.AudioEndpointVolume;
            volume.MasterVolumeLevelScalar = (float)Math.Clamp(percent / 100, 0, 1);
            if (percent > 0 && volume.Mute)
                volume.Mute = false;
            MasterVolumeValueText.Text = $"{percent:F0}%";
        }
        catch (System.Runtime.InteropServices.COMException) { RefreshWindowsVolume(); }
    }

    private async void OnSpectrumSettingsClick(object sender, RoutedEventArgs e)
    {
        var settings = new Settings.Pages.SpectrumSettingsPanel(ViewModel);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Spectrum Settings",
            Content = new ScrollViewer { Content = settings, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 535 },
            CloseButtonText = "Close"
        };
        await dialog.ShowAsync();
    }

    private async void OnDetachWindowsApoClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Device.WindowsApoEndpointId is not { } id)
        {
            OnWindowsApoClick(sender, e);
            return;
        }
        try { await DetachWindowsApoAsync(id); }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
    }

    private async Task DetachWindowsApoAsync(string endpointId, XamlRoot? owner = null)
    {
        if (_softwareFileBusy) return;
        var confirmation = new ContentDialog
        {
            XamlRoot = owner ?? Content.XamlRoot,
            Title = "Detach DSPi from this output?",
            Content = "Windows asks for administrator approval and briefly interrupts playback. Your saved DSPi profile remains available.",
            PrimaryButtonText = "Detach DSPi",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;

        await ViewModel.FlushSoftwareWritesAsync();
        _softwareFileBusy = true;
        ApplySoftwareMenuState();
        try
        {
            int exitCode = await DetachWindowsEffectAsync(endpointId);
            if (exitCode == 2) throw new InvalidOperationException("No active DSPi installation with protected recovery was found for this output.");
            if (exitCode == 3) throw new InvalidOperationException("Windows detached DSPi but cleanup still needs attention. Run protected recovery to finish.");
            if (exitCode != 0) throw new InvalidOperationException("DSPi removal could not be verified. Check the protected recovery status.");
        }
        finally
        {
            _softwareFileBusy = false;
            ApplySoftwareMenuState();
        }
        if (ViewModel.Device.WindowsApoEndpointId == endpointId)
            await DisconnectWindowsApoAsync();
    }

    private static async Task<int> DetachWindowsEffectAsync(string endpointId)
    {
        string host = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (!File.Exists(host))
            throw new InvalidOperationException("PowerShell 7 is required for DSPi recovery.");
        using var resource = typeof(MainWindow).Assembly.GetManifestResourceStream("DSPiConsole.DetachWindowsApo.ps1")
            ?? throw new InvalidOperationException("The DSPi recovery command is missing.");
        using var reader = new StreamReader(resource);
        string selection = Convert.ToBase64String(Encoding.UTF8.GetBytes(endpointId));
        string script = "$endpoint=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + selection + "'))\n" + await reader.ReadToEndAsync();
        var start = new ProcessStartInfo(host)
        {
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = Path.GetDirectoryName(host)!,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (string argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not open protected DSPi recovery.");
        await process.WaitForExitAsync();
        return process.ExitCode;
    }
}

