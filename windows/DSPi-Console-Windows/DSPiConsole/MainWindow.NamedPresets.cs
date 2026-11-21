using Dspi.Apo;
using Dspi.Audio.Windows;
using Dspi.Software;
using DSPiConsole.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace DSPiConsole;

public sealed partial class MainWindow
{
    private sealed record WindowsPresetChoice(string Endpoint, string Id, EngineConfiguration Preset);

    private readonly MenuFlyoutSubItem _quickPresets = new() { Text = "Recall Preset" };
    private readonly MenuFlyoutSubItem _startupPresets = new() { Text = "Startup Preset" };

    private static string NamedPresetFolder(string endpointId)
    {
        var profile = new ApoProfileClient(ApoProfileClient.DefaultRoot, endpointId);
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DSPiConsole", "Presets", profile.ProfileKey);
    }

    private static string WindowsPresetPath(string endpoint, string id) =>
        Path.Combine(NamedPresetFolder(endpoint), id + ".dspisw");

    private WindowsPresetChoice? SelectedWindowsPreset =>
        (PresetComboBox.SelectedItem as ComboBoxItem)?.Tag as WindowsPresetChoice;

    private static bool MatchesFormat(EngineConfiguration configuration, int channels, int rate) =>
        configuration.InputCount == channels && configuration.OutputCount == channels && configuration.SampleRate == rate;

    private static IEnumerable<(string Id, EngineConfiguration Config)> NamedPresets(string endpointId)
    {
        string folder = NamedPresetFolder(endpointId);
        if (!Directory.Exists(folder)) yield break;
        foreach (string path in Directory.EnumerateFiles(folder, "*.dspisw"))
        {
            string id = Path.GetFileNameWithoutExtension(path);
            if (!Guid.TryParseExact(id, "N", out _)) continue;
            EngineConfiguration config;
            try { config = PresetStore.Load(path); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or ArgumentException)
            { continue; }
            yield return (id, config);
        }
    }

    private void InitializeNamedPresets()
    {
        AddWindowsPresetAction(SoftwareMenu.Items, "New Preset…", NewWindowsPreset, 0);
        AddWindowsPresetAction(SoftwareMenu.Items, "Save Named Preset…", SaveNamedPreset, 1);
        AddWindowsPresetAction(SoftwareMenu.Items, "Import Preset…", ImportWindowsPreset, 2);
        SoftwareMenu.Items.Insert(3, _quickPresets);
        SoftwareMenu.Items.Insert(4, _startupPresets);
        SoftwareMenu.Items.Insert(5, new MenuFlyoutSeparator());
        ViewModel.Device.PropertyChanged += OnWindowsPresetRevisionChanged;
        Closed += (_, _) => ViewModel.Device.PropertyChanged -= OnWindowsPresetRevisionChanged;
    }

    private void OnWindowsPresetRevisionChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(Usb.DspDevice.WindowsApoDesiredRevision))
            DispatcherQueue.TryEnqueue(UpdateWindowsPresetDirtyIndicator);
    }

    private void UpdateWindowsPresetDirtyIndicator()
    {
        if (_closedWindowsControls || !ViewModel.Device.IsWindowsApo) return;
        PresetSaveButton.Visibility = Visibility.Visible;
        if (PresetComboBox.SelectedItem is ComboBoxItem { Tag: WindowsPresetChoice choice } &&
            ViewModel.Device.WindowsApoEndpointId == choice.Endpoint &&
            ViewModel.Device.HasWindowsApoPresetChanges(choice.Preset))
        {
            ShowPresetDirtyIndicator(choice.Preset.Name);
        }
        else PresetDirtyIndicator.Visibility = Visibility.Collapsed;
    }

    private void RefreshWindowsPresetComboBox(string? selectedPresetId = null)
    {
        bool wasUpdating = _isUpdatingPresetCombo;
        _isUpdatingPresetCombo = true;
        try
        {
            string? endpoint = ViewModel.Device.WindowsApoEndpointId;
            PresetSection.Visibility = endpoint == null ? Visibility.Collapsed : Visibility.Visible;
            PresetComboBox.PlaceholderText = "Current settings";
            PresetComboBox.Items.Clear();
            if (endpoint == null) return;

            var config = ViewModel.Device.SoftwareConfiguration;
            foreach (var (id, preset) in NamedPresets(endpoint)
                .Where(p => MatchesFormat(p.Config, config.OutputCount, (int)config.SampleRate))
                .OrderBy(p => p.Config.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                var choice = new WindowsPresetChoice(endpoint, id, preset);
                var item = new ComboBoxItem { Content = preset.Name, Tag = choice };
                item.RightTapped += (_, e) => ShowWindowsPresetContextMenu(item, e, choice);
                PresetComboBox.Items.Add(item);
                if (selectedPresetId == id || (selectedPresetId == null &&
                    string.Equals(config.Name, preset.Name, StringComparison.CurrentCultureIgnoreCase)))
                    PresetComboBox.SelectedItem = item;
            }
            if (PresetComboBox.Items.Count == 0)
                PresetComboBox.Items.Add(new ComboBoxItem { Content = "No saved presets", IsEnabled = false });
            PresetSaveButton.Visibility = Visibility.Visible;
        }
        finally
        {
            _isUpdatingPresetCombo = wasUpdating;
            UpdateWindowsPresetDirtyIndicator();
        }
    }

    private async Task SelectWindowsPresetChoice(WindowsPresetChoice choice)
    {
        try { await RecallNamedPreset(choice.Endpoint, choice.Preset); }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); RefreshWindowsPresetComboBox(); }
    }

    private void RefreshNamedPresets()
    {
        _quickPresets.Items.Clear();
        _startupPresets.Items.Clear();
        if (ViewModel.Device.WindowsApoEndpointId is not { } endpoint || _softwareFileBusy) return;
        var current = ViewModel.Device.SoftwareConfiguration;
        var settings = AppSettings.Instance;
        settings.WindowsApoStartupPresets.TryGetValue(endpoint, out string? startup);
        var none = new ToggleMenuFlyoutItem { Text = "Keep Last Settings", IsChecked = startup == null };
        none.Click += (_, _) => SetStartupPreset(endpoint, null);
        _startupPresets.Items.Add(none);
        foreach (var (id, config) in NamedPresets(endpoint)
            .Where(p => MatchesFormat(p.Config, current.OutputCount, (int)current.SampleRate))
            .OrderBy(p => p.Config.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            var recall = new MenuFlyoutItem { Text = config.Name };
            recall.Click += async (_, _) =>
            {
                try { await RecallNamedPreset(endpoint, config); }
                catch (Exception ex) { await ShowErrorDialog(ex.Message); }
            };
            _quickPresets.Items.Add(recall);

            var select = new ToggleMenuFlyoutItem { Text = config.Name, IsChecked = id == startup };
            select.Click += (_, _) => SetStartupPreset(endpoint, id);
            _startupPresets.Items.Add(select);
        }
        _quickPresets.IsEnabled = _quickPresets.Items.Count > 0;
    }

    private static void SetStartupPreset(string endpoint, string? preset)
    {
        var settings = AppSettings.Instance;
        if (preset == null) settings.WindowsApoStartupPresets.Remove(endpoint);
        else settings.WindowsApoStartupPresets[endpoint] = preset;
        settings.Save();
    }

    private static EngineConfiguration? GetStartupPreset(AudioEndpointInfo endpoint)
    {
        if (!AppSettings.Instance.WindowsApoStartupPresets.TryGetValue(endpoint.Id, out var preset)) return null;
        return NamedPresets(endpoint.Id)
            .Where(p => p.Id == preset && MatchesFormat(p.Config, endpoint.Channels, endpoint.SampleRate))
            .Select(p => p.Config).FirstOrDefault();
    }

    private Task QuickSaveWindowsPreset()
    {
        var choice = SelectedWindowsPreset;
        return choice != null && choice.Endpoint == ViewModel.Device.WindowsApoEndpointId
            ? SaveWindowsPreset(choice.Endpoint, choice.Preset.Name, choice)
            : SaveNamedPreset();
    }

    private void ShowWindowsPresetContextMenu(FrameworkElement anchor, RightTappedRoutedEventArgs e,
        WindowsPresetChoice? choice = null)
    {
        e.Handled = true;
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId is not { } endpoint) return;

        choice ??= SelectedWindowsPreset;
        var menu = new MenuFlyout();
        AddWindowsPresetAction(menu.Items, "New Preset…", NewWindowsPreset);
        AddWindowsPresetAction(menu.Items, "Save As…", SaveNamedPreset);
        AddWindowsPresetAction(menu.Items, "Import Preset…", ImportWindowsPreset);
        if (choice is { } slot && slot.Endpoint == endpoint)
        {
            bool isSelected = SelectedWindowsPreset?.Id == slot.Id;
            if (isSelected)
            {
                AddWindowsPresetAction(menu.Items, "Save", QuickSaveWindowsPreset, 0);
                bool dirty = ViewModel.Device.HasWindowsApoPresetChanges(slot.Preset);
                var destinations = new MenuFlyoutSubItem { Text = dirty ? "Save to…" : "Copy to…" };
                foreach (var (id, config) in NamedPresets(endpoint)
                    .Where(p => p.Id != slot.Id && MatchesFormat(p.Config, slot.Preset.OutputCount, (int)slot.Preset.SampleRate))
                    .OrderBy(p => p.Config.Name, StringComparer.CurrentCultureIgnoreCase))
                {
                    var target = new WindowsPresetChoice(endpoint, id, config);
                    AddWindowsPresetAction(destinations.Items, config.Name,
                        () => ConfirmSaveToWindowsPreset(slot, target, dirty));
                }
                if (destinations.Items.Count > 0) menu.Items.Add(destinations);
            }

            AddWindowsPresetAction(menu.Items, isSelected ? "Reload" : "Recall", () => SelectWindowsPresetChoice(slot));
            AddWindowsPresetAction(menu.Items, "Rename…", () => RenameWindowsPreset(slot));
            AddWindowsPresetAction(menu.Items, "Export This Preset…", () => ExportWindowsPreset(slot));
            var startup = new ToggleMenuFlyoutItem
            {
                Text = "Use at startup",
                IsChecked = AppSettings.Instance.WindowsApoStartupPresets.GetValueOrDefault(endpoint) == slot.Id,
            };
            startup.Click += (_, _) => SetStartupPreset(endpoint, startup.IsChecked ? slot.Id : null);
            menu.Items.Add(startup);
            menu.Items.Add(new MenuFlyoutSeparator());
            AddWindowsPresetAction(menu.Items, "Delete…", () => DeleteWindowsPreset(slot));
        }
        menu.ShowAt(anchor, new FlyoutShowOptions { Position = e.GetPosition(anchor) });
    }

    private static void AddWindowsPresetAction(IList<MenuFlyoutItemBase> items, string label, Func<Task> action,
        int? index = null)
    {
        var item = new MenuFlyoutItem { Text = label };
        item.Click += async (_, _) => await action();
        items.Insert(index ?? items.Count, item);
    }

    private async Task ConfirmSaveToWindowsPreset(WindowsPresetChoice source, WindowsPresetChoice target, bool saveLive)
    {
        var dialog = new ContentDialog
        {
            Title = "Replace preset?",
            Content = $"Replace the saved settings in “{target.Preset.Name}”?",
            XamlRoot = Content.XamlRoot,
            PrimaryButtonText = "Replace",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || SelectedWindowsPreset?.Id != source.Id) return;
        await SaveWindowsPreset(source.Endpoint, target.Preset.Name, target, saveLive ? null : source);
    }

    private async Task ImportWindowsPreset()
    {
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId is not { } endpoint) return;
        try
        {
            var file = await SoftwareOpenPicker(".dspisw").PickSingleFileAsync();
            if (file != null && ViewModel.Device.WindowsApoEndpointId == endpoint)
            {
                string name = ImportWindowsPresetFile(endpoint, file.Path);
                await ShowSuccessDialog($"“{name}” was added to the preset dropdown.");
            }
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
    }

    private string ImportWindowsPresetFile(string endpoint, string path)
    {
        var preset = PresetStore.Load(path);
        var current = ViewModel.Device.SoftwareConfiguration;
        if (!MatchesFormat(preset, current.OutputCount, (int)current.SampleRate))
            throw new InvalidOperationException(
                $"This output uses {current.OutputCount} channels at {current.SampleRate:0} Hz. Choose a preset with that format.");

        var names = NamedPresets(endpoint)
            .Where(p => MatchesFormat(p.Config, current.OutputCount, (int)current.SampleRate))
            .Select(p => p.Config.Name)
            .ToHashSet(StringComparer.CurrentCultureIgnoreCase);
        string baseName = string.IsNullOrWhiteSpace(preset.Name) ? Path.GetFileNameWithoutExtension(path) : preset.Name.Trim();
        preset.Name = baseName;
        for (int suffix = 2; names.Contains(preset.Name); suffix++)
            preset.Name = $"{baseName} ({suffix})";

        Directory.CreateDirectory(NamedPresetFolder(endpoint));
        PresetStore.Save(WindowsPresetPath(endpoint, Guid.NewGuid().ToString("N")), preset);
        RefreshWindowsPresetComboBox(SelectedWindowsPreset?.Id ?? "");
        return preset.Name;
    }

    private async Task ExportWindowsPreset(WindowsPresetChoice choice)
    {
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId != choice.Endpoint) return;
        try
        {
            var saved = PresetStore.Load(WindowsPresetPath(choice.Endpoint, choice.Id));
            var invalid = Path.GetInvalidFileNameChars();
            string name = string.Concat(saved.Name.Select(c => invalid.Contains(c) ? '_' : c)).TrimEnd(' ', '.');
            string fileName = name.Length == 0 ? "DSPi Preset" : $"DSPi - {name}";
            var file = await SoftwareSavePicker(fileName, "Full software preset", ".dspisw").PickSaveFileAsync();
            if (file != null) PresetStore.Save(file.Path, saved);
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
    }

    private async Task RenameWindowsPreset(WindowsPresetChoice choice)
    {
        var entry = new TextBox { Header = "Preset name", MaxLength = 80, Text = choice.Preset.Name };
        var dialog = new ContentDialog
        {
            Title = "Rename Preset",
            XamlRoot = Content.XamlRoot,
            Content = entry,
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        dialog.Opened += (_, _) => entry.SelectAll();
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        string name = entry.Text.Trim();
        if (name.Length > 0 && name != choice.Preset.Name)
            await UpdateWindowsPresetLibrary(choice, name);
    }

    private async Task DeleteWindowsPreset(WindowsPresetChoice choice)
    {
        var dialog = new ContentDialog
        {
            Title = "Delete Preset",
            XamlRoot = Content.XamlRoot,
            Content = $"Delete “{choice.Preset.Name}” from this output?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            await UpdateWindowsPresetLibrary(choice, newName: null);
    }

    private async Task UpdateWindowsPresetLibrary(WindowsPresetChoice choice, string? newName)
    {
        string endpoint = choice.Endpoint;
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId != endpoint) return;
        _softwareFileBusy = true;
        ApplySoftwareMenuState();
        try
        {
            await ViewModel.FlushSoftwareWritesAsync();
            if (ViewModel.Device.WindowsApoEndpointId != endpoint) return;

            string path = WindowsPresetPath(endpoint, choice.Id);
            var saved = PresetStore.Load(path);
            var current = ViewModel.Device.SoftwareConfiguration;
            if (!MatchesFormat(saved, current.OutputCount, (int)current.SampleRate))
                throw new InvalidOperationException("The preset no longer matches this output's audio format.");

            var selected = SelectedWindowsPreset;
            bool isActive = selected?.Id == choice.Id && selected.Endpoint == endpoint;
            if (newName == null)
            {
                if (isActive) ViewModel.Device.SetWindowsApoPresetName(endpoint, "");
                try { File.Delete(path); }
                catch
                {
                    if (isActive) ViewModel.Device.SetWindowsApoPresetName(endpoint, current.Name);
                    throw;
                }

                if (AppSettings.Instance.WindowsApoStartupPresets.GetValueOrDefault(endpoint) == choice.Id)
                    SetStartupPreset(endpoint, null);
            }
            else
            {
                bool nameInUse = NamedPresets(endpoint).Any(p => p.Id != choice.Id &&
                    MatchesFormat(p.Config, current.OutputCount, (int)current.SampleRate) &&
                    string.Equals(p.Config.Name, newName, StringComparison.CurrentCultureIgnoreCase));
                if (nameInUse)
                    throw new InvalidOperationException("A preset already uses this name. Choose a different name.");

                var renamed = saved.Clone();
                renamed.Name = newName;
                PresetStore.Save(path, renamed);
                try
                {
                    if (isActive) ViewModel.Device.SetWindowsApoPresetName(endpoint, newName);
                }
                catch
                {
                    PresetStore.Save(path, saved);
                    throw;
                }
            }
            RefreshWindowsPresetComboBox(selected?.Id);
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }

    private Task SaveNamedPreset() => CreateNamedPreset(startFlat: false);

    private Task NewWindowsPreset() => CreateNamedPreset(startFlat: true);

    private async Task CreateNamedPreset(bool startFlat)
    {
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId is not { } endpoint) return;
        var entry = new TextBox { Header = "Preset name", MaxLength = 80 };
        var dialog = new ContentDialog
        {
            Title = startFlat ? "New Preset" : "Save Named Preset",
            XamlRoot = Content.XamlRoot,
            Content = entry,
            PrimaryButtonText = startFlat ? "Create" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        if (startFlat)
        {
            bool dirty = SelectedWindowsPreset is { } choice && ViewModel.Device.HasWindowsApoPresetChanges(choice.Preset);
            var message = new TextBlock
            {
                Text = dirty
                    ? "Creating a flat preset replaces your current unsaved adjustments. To keep them, cancel and save first."
                    : "Starts with flat EQ, direct channel routing, and effects off.",
                TextWrapping = TextWrapping.Wrap
            };
            dialog.Content = new StackPanel { Spacing = 12, Children = { message, entry } };
        }
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        string name = entry.Text.Trim();
        if (name.Length > 0) await SaveWindowsPreset(endpoint, name, startFlat: startFlat);
    }

    private async Task SaveWindowsPreset(string endpoint, string name, WindowsPresetChoice? target = null,
        WindowsPresetChoice? copySource = null, bool startFlat = false)
    {
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId != endpoint) return;
        _softwareFileBusy = true;
        ApplySoftwareMenuState();
        try
        {
            await ViewModel.FlushSoftwareWritesAsync();
            if (ViewModel.Device.WindowsApoEndpointId != endpoint) return;

            var current = ViewModel.Device.SoftwareConfiguration;
            var config = startFlat
                ? Usb.DspDevice.CreateFlatWindowsApoConfiguration((int)current.SampleRate, current.OutputCount)
                : (copySource?.Preset ?? current).Clone();
            config.Name = name;
            var compatible = NamedPresets(endpoint)
                .Where(p => MatchesFormat(p.Config, config.OutputCount, (int)config.SampleRate))
                .ToArray();
            if (target != null && !compatible.Any(p => p.Id == target.Id))
                throw new InvalidOperationException("The destination preset is no longer available.");
            if (target == null && compatible.Any(p => string.Equals(p.Config.Name, name, StringComparison.CurrentCultureIgnoreCase)))
                throw new InvalidOperationException("A preset already uses this name. Choose a different name.");

            if (startFlat)
            {
                await ViewModel.PrepareForBackendSwitchAsync();
                if (ViewModel.Device.WindowsApoEndpointId != endpoint) return;
            }

            string id = target?.Id ?? Guid.NewGuid().ToString("N");
            Directory.CreateDirectory(NamedPresetFolder(endpoint));
            PresetStore.Save(WindowsPresetPath(endpoint, id), config);
            if (copySource == null)
            {
                if (startFlat)
                {
                    ViewModel.Device.ApplySoftwareConfiguration(config, Usb.ParamSource.Preset);
                    RestorePairLinksForDevice();
                }
                else if (!string.Equals(current.Name, name, StringComparison.Ordinal))
                    ViewModel.Device.ApplySoftwareConfiguration(config);
                ViewModel.MarkSoftwareSaved();
            }
            RefreshWindowsPresetComboBox(copySource?.Id ?? id);
        }
        catch (Exception ex) { await ShowErrorDialog(ex.Message); }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }

    private void SelectPresetName(string name)
    {
        bool wasUpdating = _isUpdatingPresetCombo;
        _isUpdatingPresetCombo = true;
        try
        {
            PresetComboBox.SelectedItem = PresetComboBox.Items.OfType<ComboBoxItem>()
                .FirstOrDefault(item => item.Tag is WindowsPresetChoice choice &&
                    string.Equals(choice.Preset.Name, name, StringComparison.CurrentCultureIgnoreCase));
        }
        finally
        {
            _isUpdatingPresetCombo = wasUpdating;
            UpdateWindowsPresetDirtyIndicator();
        }
    }

    private async Task RecallNamedPreset(string endpoint, EngineConfiguration preset)
    {
        if (_softwareFileBusy || ViewModel.Device.WindowsApoEndpointId != endpoint) return;
        _softwareFileBusy = true;
        ApplySoftwareMenuState();
        try
        {
            await ViewModel.PrepareForBackendSwitchAsync();
            if (ViewModel.Device.WindowsApoEndpointId != endpoint) return;
            ViewModel.Device.ApplySoftwareConfiguration(preset, Usb.ParamSource.Preset);
            RestorePairLinksForDevice();
            SelectPresetName(preset.Name);
        }
        finally { _softwareFileBusy = false; ApplySoftwareMenuState(); }
    }
}

