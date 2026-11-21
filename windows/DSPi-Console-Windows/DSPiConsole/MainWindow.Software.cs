using Dspi.Software;
using DSPiConsole.Services;
using DSPiConsole.Usb;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DSPiConsole;

public sealed partial class MainWindow
{
    private bool _softwareFileBusy;

    private async void OnUseSoftwareClick(object sender, RoutedEventArgs e) => await SelectSoftwareAsync(2);
    private async void OnUseMultichannelSoftwareClick(object sender, RoutedEventArgs e) => await SelectSoftwareAsync(8);
    private async Task SelectSoftwareAsync(int inputs)
    {
        if (_softwareFileBusy) return;
        _softwareFileBusy = true;
        try
        {
            await StopLiveAudioAsync();
            await ViewModel.PrepareForBackendSwitchAsync();
            ViewModel.Device.UseSoftwareDsp(inputs);
            if (ViewModel.Device.IsSoftwareMode) Onboarding.Coordinator.FinishSetup();
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
        finally { _softwareFileBusy = false; }
    }
    private async void OnUseHardwareClick(object sender, RoutedEventArgs e)
    {
        if (_softwareFileBusy) return;
        _softwareFileBusy = true;
        try
        {
            await StopLiveAudioAsync();
            await ViewModel.PrepareForBackendSwitchAsync();
            ViewModel.Device.UseUsbHardware();
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
        finally { _softwareFileBusy = false; }
    }

    private void ApplySoftwareMenuState()
    {
        bool software = ViewModel.Device.IsSoftwareMode;
        SoftwareMenu.IsEnabled = software && !_softwareFileBusy;
        BackendMenu.IsEnabled = !_softwareFileBusy;
        ProcessSoftwareWavMenuItem.IsEnabled = !ViewModel.Device.IsWindowsApo && !ViewModel.Device.IsSoftwareLive && _liveAudioWindow?.IsActive != true && !_softwareFileBusy;
        CaptureAudioMenuItem.IsEnabled = !ViewModel.Device.IsWindowsApo && !_softwareFileBusy;
        // Flash, firmware, GPIO, physical signal generators and USB diagnostics
        // do not exist in this backend. Their transfer requests also fail closed.
        var hardware = new HashSet<string>
        {
            "Save Master Volume", "Save Output Config", "Revert Preset...",
            "Factory Reset...", "Update Firmware...", "Test Signal Generator...",
            "Interrupt Monitor...", "Stats for nerbs"
        };
        foreach (var item in MainMenu.Items.OfType<MenuFlyoutItem>())
        {
            if (hardware.Contains(item.Text)) item.IsEnabled = !software && !WizardShown;
            if (item.Text == "Spectrum Analyser...") item.IsEnabled = ViewModel.Device.IsWindowsApo;
            if (item.Text == "Save Preset") item.IsEnabled = ViewModel.IsDeviceConnected && !WizardShown && !_softwareFileBusy;
        }
        SettingsMenuItem.IsEnabled = !software;
        ImportPresetMenuItem.IsEnabled = ViewModel.IsDeviceConnected && !software;
        ExportPresetMenuItem.IsEnabled = ViewModel.IsDeviceConnected && !software;
        SaveMasterVolumeMenuItem.IsEnabled &= !software;
        SaveOutputConfigMenuItem.IsEnabled &= !software;
    }

    private FileOpenPicker SoftwareOpenPicker(params string[] extensions)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var extension in extensions) picker.FileTypeFilter.Add(extension);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return picker;
    }
    private FileSavePicker SoftwareSavePicker(string name, string label, string extension)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = name };
        picker.FileTypeChoices.Add(label, new List<string> { extension });
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return picker;
    }
    private async void OnSaveSoftwarePresetClick(object sender, RoutedEventArgs e)
    {
        await SaveSoftwarePresetAsync();
    }
    private async Task<bool> SaveSoftwarePresetAsync()
    {
        if (!ViewModel.Device.IsSoftwareMode || _softwareFileBusy) return false;
        var file = await SoftwareSavePicker("Software DSP Preset", "Full software preset", ".dspisw").PickSaveFileAsync();
        if (file == null) return false;
        try
        {
            await ViewModel.FlushSoftwareWritesAsync();
            var configuration = ViewModel.Device.SoftwareConfiguration;
            for (int pair = 0; pair < 4; pair++) configuration.InputPairLinked[pair] = ViewModel.GetInputPairLinked(pair);
            PresetStore.Save(file.Path, configuration);
            ViewModel.MarkSoftwareSaved();
            return true;
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); return false; }
    }
    private async void OnLoadSoftwarePresetClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.Device.IsSoftwareMode || _softwareFileBusy) return;
        var file = await SoftwareOpenPicker(".dspisw", ".json").PickSingleFileAsync();
        if (file == null) return;
        try
        {
            var configuration = PresetStore.Load(file.Path);
            await ViewModel.PrepareForBackendSwitchAsync();
            ViewModel.Device.ApplySoftwareConfiguration(configuration, ParamSource.Preset);
            for (int pair = 0; pair < 4; pair++) ViewModel.SetInputPairLinked(pair, configuration.InputPairLinked[pair]);
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
    }
    private async void OnImportSoftwarePresetClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.Device.IsSoftwareMode || _softwareFileBusy) return;
        var file = await SoftwareOpenPicker(PresetFileService.FileExtension, ".json").PickSingleFileAsync();
        if (file == null) return;
        try
        {
            var result = PresetStore.ImportDspi(file.Path);
            await ViewModel.PrepareForBackendSwitchAsync();
            ViewModel.Device.ApplySoftwareConfiguration(result.Configuration, ParamSource.Preset);
            for (int pair = 0; pair < 4; pair++) ViewModel.SetInputPairLinked(pair, result.Configuration.InputPairLinked[pair]);
            await ShowSuccessDialog(result.Warnings.Count == 0 ? "DSPi preset imported." : "DSPi preset imported.\n\n" + string.Join("\n", result.Warnings));
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
    }
    private async void OnProcessSoftwareWavClick(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.Device.IsSoftwareMode || _softwareFileBusy) return;
        var input = await SoftwareOpenPicker(".wav").PickSingleFileAsync();
        if (input == null) return;
        var output = await SoftwareSavePicker(System.IO.Path.GetFileNameWithoutExtension(input.Name) + "-processed", "Processed float WAV", ".wav").PickSaveFileAsync();
        if (output == null) return;
        if (string.Equals(input.Path, output.Path, StringComparison.OrdinalIgnoreCase)) { await ShowErrorDialog("Choose a different output file."); return; }
        await ViewModel.FlushSoftwareWritesAsync();
        _softwareFileBusy = true;
        ApplySoftwareMenuState();
        try
        {
            await Task.Run(() => SoftwareWaveProcessor.Process(ViewModel.Device, input.Path, output.Path));
            await ShowSuccessDialog("WAV processed through Software DSP. The output is a multichannel 32-bit float WAV.\n\nThis mode processes files; it does not capture or play Windows audio.");
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }
}


