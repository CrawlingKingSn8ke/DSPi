using Dspi.Apo;
using Dspi.Software;
using DSPiConsole.Core.Models;

namespace DSPiConsole.Usb;

public partial class DspDevice
{
    private ApoProfileClient? _windowsApo;
    private readonly Dictionary<int, int> _windowsOutputEqPartners = new();
    private WindowsApoSpectrum? _windowsApoSpectrum;
    private ulong _windowsApoRevision;
    private long _windowsApoClipClearTime;
    public bool IsWindowsApo => _windowsApo != null;
    public string? WindowsApoEndpointId { get; private set; }
    public string? WindowsApoEndpointName { get; private set; }
    public ulong WindowsApoDesiredRevision { get { lock (_lock) return _windowsApoRevision; } }

    public static EngineConfiguration CreateFlatWindowsApoConfiguration(int sampleRate, int channels)
    {
        var configuration = new EngineConfiguration { SampleRate = sampleRate, InputCount = channels, OutputCount = channels };
        foreach (var route in configuration.Routes)
            route.Enabled = route.Input == route.Output && route.Input < channels;
        return configuration;
    }

    /// <summary>Connects controls to an already provisioned endpoint profile.
    /// Does not attach an APO, move playback sessions or change the default device.</summary>
    public void UseWindowsApo(string endpointId, string endpointName, int sampleRate, int channels, string? profileRoot = null, EngineConfiguration? startupPreset = null)
    {
        var client = new ApoProfileClient(profileRoot ?? ApoProfileClient.DefaultRoot, endpointId);
        if (!Directory.Exists(client.DirectoryPath))
            throw new InvalidOperationException("DSPi has not been provisioned for this output. Install the standalone APO on this device before connecting its controls.");
        if (channels is < 1 or > 8 || sampleRate is < 8000 or > 192000)
            throw new InvalidOperationException("This output's audio format is not supported by the standalone APO.");
        var saved = client.Load();
        var configuration = startupPreset ?? saved?.Configuration ?? CreateFlatWindowsApoConfiguration(sampleRate, channels);
        if (configuration.SampleRate != sampleRate || configuration.InputCount != channels || configuration.OutputCount != channels)
            throw new InvalidOperationException("The saved APO profile has a different sample rate or channel layout. A compatible profile is required before connecting controls.");
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            RequireSoftwareStopped();
            if (_softwareFileProcessing) throw new InvalidOperationException("Wait for WAV processing to finish before switching backends.");
            // Validate through the real engine before publishing or disconnecting
            // a working backend. This session is a control mirror, not the meter source.
            var mirror = new NativeSession(configuration);
            try
            {
                bool needsSave = saved == null || startupPreset != null &&
                    !string.Equals(PresetStore.Serialize(saved.Configuration), PresetStore.Serialize(configuration), StringComparison.Ordinal);
                ulong revision = needsSave ? client.Save(configuration) : saved!.Revision;
                _backendMode.SelectSoftware();
                _pollTimer.Stop();
                HandleDisconnect();
                _software = mirror;
                _windowsApo = client;
                _windowsApoSpectrum = new WindowsApoSpectrum(client, sampleRate, channels);
                _windowsApoRevision = revision;
                _windowsApoClipClearTime = 0;
                WindowsApoEndpointId = endpointId;
                WindowsApoEndpointName = endpointName;
                NumInputChannels = channels; NumOutputChannels = channels; NumChannels = channels * 2;
                WireFormatVersion = 32;
                SelectedDeviceInfo = new DSPiDeviceInfo("WINDOWS_APO", endpointId, endpointName);
                _availableDevices = new() { SelectedDeviceInfo };
                AvailableDevicesChanged?.Invoke(this, EventArgs.Empty);
                ErrorMessage = null;
                IsConnected = true;
                DeviceConnected?.Invoke(this, EventArgs.Empty);
            }
            catch { if (!ReferenceEquals(_software, mirror)) mirror.Dispose(); throw; }
        }
    }

    public bool HasWindowsApoPresetChanges(EngineConfiguration savedPreset)
    {
        EngineConfiguration current;
        lock (_lock)
        {
            if (_windowsApo == null) return false;
            current = RequireSoftware().CurrentConfiguration;
        }

        // Renaming the library entry does not change the settings it contains.
        current.Name = savedPreset.Name;
        return !string.Equals(PresetStore.Serialize(current), PresetStore.Serialize(savedPreset), StringComparison.Ordinal);
    }

    public void SetWindowsApoPresetName(string endpointId, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        lock (_lock)
        {
            if (_windowsApo == null || WindowsApoEndpointId != endpointId)
                throw new InvalidOperationException("The Windows audio output is no longer selected.");

            var configuration = RequireSoftware().CurrentConfiguration;
            if (configuration.Name == name) return;
            configuration.Name = name;
            ApplySoftwareUpdate(configuration);
        }
    }

    public int GetWindowsOutputEqPartner(int channel)
    {
        lock (_lock) return _windowsOutputEqPartners.GetValueOrDefault(channel, -1);
    }

    public bool SetWindowsOutputEqLink(string endpoint, int source, int partner, bool enabled)
    {
        lock (_lock)
        {
            int first = source - ChannelMap.AppInputCount, second = partner - ChannelMap.AppInputCount;
            if (_windowsApo == null || WindowsApoEndpointId != endpoint || first == second ||
                first < 0 || second < 0 || first >= NumOutputChannels || second >= NumOutputChannels)
                return false;

            int linked = _windowsOutputEqPartners.GetValueOrDefault(source, -1);
            if (linked == partner)
            {
                if (!enabled) UnlinkWindowsOutputEq(source, partner);
                return true;
            }
            if (!enabled || linked >= 0 || _windowsOutputEqPartners.ContainsKey(partner))
                return false;

            var configuration = RequireSoftware().CurrentConfiguration;
            if (!OutputEqMatches(configuration, source, partner))
            {
                configuration.Outputs[second].Eq = configuration.Outputs[first].Eq.ToArray();
                ApplySoftwareUpdate(configuration);
            }
            _windowsOutputEqPartners[source] = partner;
            _windowsOutputEqPartners[partner] = source;
            return true;
        }
    }

    private void UnlinkWindowsOutputEq(int first, int second)
    {
        _windowsOutputEqPartners.Remove(first);
        _windowsOutputEqPartners.Remove(second);
    }

    private static bool OutputEqMatches(EngineConfiguration configuration, int first, int second)
    {
        var a = configuration.Outputs[first - ChannelMap.AppInputCount].Eq;
        var b = configuration.Outputs[second - ChannelMap.AppInputCount].Eq;
        return a.Zip(b).All(pair => pair.First.Type == pair.Second.Type &&
            pair.First.FrequencyHz == pair.Second.FrequencyHz && pair.First.Q == pair.Second.Q &&
            pair.First.Gain == pair.Second.Gain && pair.First.TargetQ == pair.Second.TargetQ &&
            pair.First.Bypass == pair.Second.Bypass);
    }

    private void MirrorWindowsOutputEqBand(EngineConfiguration configuration, int wireChannel, int band)
    {
        if (wireChannel < configuration.InputCount || band >= 10 || _windowsOutputEqPartners.Count == 0) return;

        int source = ChannelMap.WireToApp(wireChannel, configuration.InputCount);
        if (_windowsOutputEqPartners.TryGetValue(source, out int partner))
        {
            var from = configuration.Outputs[source - ChannelMap.AppInputCount];
            var to = configuration.Outputs[partner - ChannelMap.AppInputCount];
            to.Eq[band] = from.Eq[band];
        }
    }

    public IReadOnlyList<ApoInstanceStatus> GetWindowsApoStatuses()
    {
        lock (_lock) return _windowsApo?.ReadStatuses() ?? Array.Empty<ApoInstanceStatus>();
    }

    public bool SetWindowsApoInputPairLinks(string endpointId, bool[] links)
    {
        ArgumentNullException.ThrowIfNull(links);
        if (links.Length != 4) throw new ArgumentException("Four input-pair link flags are required.", nameof(links));
        lock (_lock)
        {
            if (_windowsApo == null || WindowsApoEndpointId != endpointId) return false;
            var configuration = RequireSoftware().CurrentConfiguration;
            if (configuration.InputPairLinked.SequenceEqual(links)) return true;
            configuration.InputPairLinked = links.ToArray();
            try { ApplySoftwareUpdate(configuration); return true; }
            catch (Exception ex) { ErrorMessage = "Could not save Windows APO input links: " + ex.Message; return false; }
        }
    }

    private void ApplySoftwareUpdate(EngineConfiguration configuration)
    {
        var session = RequireSoftware();
        var previous = session.CurrentConfiguration;
        if (_windowsApo != null && (configuration.SampleRate != previous.SampleRate ||
            configuration.InputCount != previous.InputCount || configuration.OutputCount != previous.OutputCount))
            throw new InvalidOperationException("Windows owns this APO's sample rate and physical channel layout. Disconnect its controls before using another format.");
        session.Apply(configuration);
        try
        {
            if (_windowsApo != null)
                _windowsApoRevision = _windowsApo.Save(configuration);
        }
        catch
        {
            session.Apply(previous);
            throw;
        }
        if (_windowsApo != null)
            OnPropertyChanged(nameof(WindowsApoDesiredRevision));
    }

    private void RequireWindowsApoUnbound()
    {
        if (_windowsApo != null)
            throw new InvalidOperationException("Disconnect the Windows APO controls before processing a file or using capture/playback audio.");
    }

    private MeterSnapshot ReadSoftwareMeters()
    {
        if (_windowsApo == null) return RequireSoftware().ReadMeters();
        var inputs = new float[8]; var outputs = new float[8]; uint clips = 0;
        foreach (var instance in _windowsApo.ReadStatuses())
        {
            if (!instance.IsProcessing || instance.ActualRate != (uint)RequireSoftware().CurrentConfiguration.SampleRate ||
                instance.PhysicalChannels != NumInputChannels) continue;
            var meters = instance.Meters;
            for (int i = 0; i < 8; i++) { inputs[i] = Math.Max(inputs[i], meters.Inputs[i]); outputs[i] = Math.Max(outputs[i], meters.Outputs[i]); }
            if (instance.HeartbeatFileTime > (ulong)_windowsApoClipClearTime) clips |= meters.Clips;
        }
        return new(inputs, outputs, clips);
    }

    private void ClearWindowsApoBinding()
    {
        _windowsApoSpectrum?.Stop();
        _windowsApoSpectrum = null;
        _windowsApo = null;
        _windowsOutputEqPartners.Clear();
        _windowsApoRevision = 0;
        _windowsApoClipClearTime = 0;
        WindowsApoEndpointId = WindowsApoEndpointName = null;
    }
}
