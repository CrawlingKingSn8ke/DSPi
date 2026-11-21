using System.Buffers.Binary;
using System.Text;
using System.Diagnostics;
using System.Globalization;
using Dspi.Apo;
using Dspi.Audio.Windows;
using NAudio.Wave;
using Dspi.Software;
using DSPiConsole.Usb;
using DSPiConsole.Core.Models;
using DSPiConsole.Core.Rta;

int count = 0;
void Check(bool value, string label) { count++; if (!value) throw new Exception(label); }
void Reject(Action action, string label) { bool rejected = false; try { action(); } catch (InvalidOperationException) { rejected = true; } Check(rejected, label); }
string root = Path.Combine(Path.GetTempPath(), "dspi-apo-console-" + Guid.NewGuid().ToString("N"));
string endpoint = "{0.0.0.00000000}.{11111111-2222-3333-4444-555555555555}";
var client = new ApoProfileClient(root, endpoint);
using var device = new DspDevice();
device.StartMonitoring();
try
{
    Reject(() => device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root), "Unprovisioned output cannot be connected or silently installed");
    Check(!device.IsSoftwareMode && !device.IsConnected, "Failed connection preserves backend");
    Directory.CreateDirectory(client.DirectoryPath);
    var surroundClient = new ApoProfileClient(root, endpoint + "-surround"); Directory.CreateDirectory(surroundClient.DirectoryPath);
    device.UseWindowsApo(endpoint + "-surround", "Test Surround", 48000, 8, root);
    Check(Enumerable.Range(0, 8).All(ch => surroundClient.Load()!.Configuration.Routes[ch * 8 + ch].Enabled), "New multichannel profile preserves every physical channel");
    device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root);
    Check(device.IsWindowsApo && device.IsSoftwareMode && device.IsConnected, "APO control binding");
    Check(device.NumInputChannels == 2 && device.NumOutputChannels == 2, "Actual physical channel topology");
    Check(device.SelectedDeviceInfo?.DisplayName == "Test DAC", "Friendly endpoint identity");
    Check(device.SoftwareConfiguration.SampleRate == 44100, "Actual endpoint rate without forced resampling");

    var blank = DspDevice.CreateFlatWindowsApoConfiguration(96000, 6);
    Check(blank.SampleRate == 96000 && blank.InputCount == 6 && blank.OutputCount == 6 &&
        blank.Routes.All(r => r.Enabled == (r.Input == r.Output && r.Input < 6) && !r.Invert && r.GainDb == 0),
        "New preset has unity routing on all physical channels");
    Check(blank.Inputs.Concat(blank.Outputs).All(c => c.GainDb == 0 && c.DelayMs == 0 && c.Enabled &&
        !c.Muted && !c.Bypass && !c.Limiter.Enabled && c.Eq.All(b => b.Type == 0) && c.Crossover.All(b => b.Bypass)),
        "New preset has flat EQ, bypassed crossovers and neutral channel settings");
    Check(!blank.Bypass && blank.VolumeDb == 0 && blank.MasterVolumeDb == 0 &&
        !blank.Loudness.Enabled && !blank.Crossfeed.Enabled && !blank.Leveller.Enabled && !blank.Psybass.Enabled &&
        !blank.Subharm.Enabled && !blank.Tube.Enabled && !blank.Upmix.Enabled, "New preset starts with effects off");

    string originalName = device.SoftwareConfiguration.Name;
    string originalRecipe = device.SoftwareConfiguration.ToRecipe();
    device.SetWindowsApoPresetName(endpoint, "Renamed");
    Check(client.Load()!.Configuration.Name == "Renamed" && device.SoftwareConfiguration.ToRecipe() == originalRecipe,
        "Renaming the active preset persists its name without changing DSP");
    Reject(() => device.SetWindowsApoPresetName(endpoint + "-other", ""), "An inactive endpoint cannot rename the active profile");
    device.SetWindowsApoPresetName(endpoint, "");
    Check(client.Load()!.Configuration.Name == "" && device.SoftwareConfiguration.ToRecipe() == originalRecipe,
        "Clearing the active preset name retains live DSP");
    device.SetWindowsApoPresetName(endpoint, originalName);

    var speakers = WindowsSpeakerLayout.GetLabels(6, 0x60f);
    Check(ChannelMap.WindowsOutputPairIndex(speakers, 0) == 1 &&
        ChannelMap.WindowsOutputPairIndex(speakers, 4) == 5 &&
        ChannelMap.WindowsOutputPairIndex(speakers, 2) == -1 && ChannelMap.WindowsOutputPairIndex(speakers, 3) == -1,
        "Only matching left and right speakers can be paired");
    var beforeLink = device.SoftwareConfiguration;
    var independent = beforeLink.Clone();
    independent.Outputs[1].GainDb = -5;
    independent.Outputs[1].DelayMs = 3;
    device.ApplySoftwareConfiguration(independent);
    Check(device.SetFilter(2, 0, new FilterParams(FilterType.Peaking, 1000, 1, -3)), "Set left EQ");
    Check(device.SetWindowsOutputEqLink(endpoint, 2, 3, true), "Enable output EQ link");
    var paired = client.Load()!.Configuration;
    Check(paired.Outputs[1].Eq[0].Gain == -3 && paired.Outputs[1].GainDb == -5 && paired.Outputs[1].DelayMs == 3,
        "Link copies EQ and keeps independent gain and delay");
    ulong linkRevision = device.WindowsApoDesiredRevision;
    Check(device.SetFilter(3, 0, new FilterParams(FilterType.Peaking, 1200, 1, -6)) &&
        device.WindowsApoDesiredRevision == linkRevision + 1 && client.Load()!.Configuration.Outputs[0].Eq[0].Gain == -6,
        "Right-side edit updates both outputs in one profile write");
    Check(device.SetBandBypass(2, 0, true) && client.Load()!.Configuration.Outputs[1].Eq[0].Bypass,
        "Band bypass mirrors");
    Check(device.SetFilter(2, 20, new FilterParams((FilterType)32, 100, 1, 0)) &&
        client.Load()!.Configuration.Outputs[1].Crossover[0].Bypass, "Output crossover does not mirror");
    device.ApplySoftwareConfiguration(independent, ParamSource.Preset);
    Check(device.GetWindowsOutputEqPartner(2) == 3, "Matching recalled EQ keeps the link");
    independent.Outputs[1].Eq[0].Gain = -9;
    device.ApplySoftwareConfiguration(independent, ParamSource.Preset);
    Check(device.GetWindowsOutputEqPartner(2) == -1 && client.Load()!.Configuration.Outputs[1].Eq[0].Gain == -9,
        "Recall with different EQ banks drops the link and preserves both banks");
    device.ApplySoftwareConfiguration(beforeLink);

    var rememberedPreset = device.SoftwareConfiguration;
    rememberedPreset.Name = "Night playback";
    rememberedPreset.Outputs[0].GainDb = -4;
    device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root, rememberedPreset);
    Check(client.Load()!.Configuration.Name == "Night playback" &&
        client.Load()!.Configuration.Outputs[0].GainDb == -4, "Chosen startup preset reaches the endpoint profile");
    ulong startupRevision = device.WindowsApoDesiredRevision;
    device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root, rememberedPreset);
    Check(device.WindowsApoDesiredRevision == startupRevision, "Reopening with the already active preset does not create a DSP change");
    var badStartup = rememberedPreset.Clone(); badStartup.SampleRate = 48000;
    Reject(() => device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root, badStartup), "Mismatched startup layout cannot overwrite endpoint settings");
    Check(client.Load()!.Revision == startupRevision, "Rejected startup preset preserves live profile");

    Check(WindowsSpeakerLayout.GetLabels(6, 0x60f).SequenceEqual(new[] { "Front Left", "Front Right", "Centre", "LFE", "Surround Left", "Surround Right" }), "Speaker mask defines the centre and side surround order");
    Check(WindowsSpeakerLayout.GetLabels(2, 0).SequenceEqual(new[] { "Left", "Right" }), "Two-channel format has stereo labels");
    var waveFormat = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
    var check = new WindowsTestSignal(waveFormat, WindowsSignal.ChannelCheck, -1, -40);
    var frames = new float[96000];
    Check(check.Read(frames, 0, frames.Length) == frames.Length && frames[0] == 0 && frames[^2] == 0 &&
        Enumerable.Range(0, 48000).All(i => frames[i * 2 + 1] == 0) && frames.Max() > .009f, "Channel check plays and fades the left speaker alone");
    Check(check.Read(frames, 0, frames.Length) == frames.Length &&
        Enumerable.Range(0, 48000).All(i => frames[i * 2] == 0) && frames.Max() > .009f &&
        check.Read(frames, 0, frames.Length) == 0, "Channel check advances to right and then stops");
    foreach (var signal in new[] { WindowsSignal.Sine, WindowsSignal.PinkNoise, WindowsSignal.Sweep })
    {
        var source = new WindowsTestSignal(waveFormat, signal, 1, -30);
        Check(source.Read(frames, 0, frames.Length) == frames.Length && frames.All(float.IsFinite) &&
            Enumerable.Range(0, 48000).All(i => frames[i * 2] == 0) && frames.Max() > 0.001 &&
            frames.Max(x => Math.Abs(x)) < .032, $"{signal} produces bounded audio on the selected output channel");
    }


    var measurementConfig = new DSPiConsole.Core.Models.SiggenConfig
    {
        SignalType = DSPiConsole.Core.Models.SiggenType.Sine, ChannelMask = 3, InvertMask = 2,
        LevelDb = -40, P1 = 1000, DurationMs = 0
    };
    var measurement = new DSPiConsole.Core.Models.MeasurementSignal(48000, 2, measurementConfig);
    var measureBuffer = new float[96000];
    for (int second = 0; second < 9; second++)
        Check(measurement.Read(measureBuffer, 0, measureBuffer.Length) == measureBuffer.Length,
            "Duration zero keeps a Windows signal running beyond the old five-second limit");
    Check(measureBuffer.Max() > .009f && Enumerable.Range(0, 48000).All(i => measureBuffer[2*i] == -measureBuffer[2*i+1]), "Selected output polarity is applied");
    measurement.FadeOut();
    int finalCount = measurement.Read(measureBuffer, 0, measureBuffer.Length);
    Check(finalCount > 0 && finalCount <= 2000 && measureBuffer[finalCount-2] == 0 &&
        measurement.Read(measureBuffer, 0, measureBuffer.Length) == 0, "Stop fades continuous audio and closes the stream");
    measurementConfig.DurationMs = 250;
    measurement = new DSPiConsole.Core.Models.MeasurementSignal(48000, 2, measurementConfig);
    Check(measurement.Read(measureBuffer, 0, measureBuffer.Length) == 24000 &&
        measurement.Read(measureBuffer, 0, measureBuffer.Length) == 0, "Finite duration ends at the requested frame");


    foreach (var kind in Enum.GetValues<SiggenType>())
    {
        var cfg = new SiggenConfig
        {
            SignalType = kind, ChannelMask = 1, LevelDb = -40, DurationMs = 1000,
            P1 = kind switch { SiggenType.Multitone => 10, SiggenType.ChannelId => 120, SiggenType.Isp => 0, _ => 80 },
            P2 = 1000, P3 = 4, P4 = 250, Repeat = 1
        };
        var pattern = new MeasurementSignal(48000, 2, cfg);
        int samples = pattern.Read(measureBuffer, 0, measureBuffer.Length);
        Check(samples > 0 && measureBuffer.AsSpan(0, samples).ToArray().Any(v => Math.Abs(v) > .0003f),
            $"{kind} produces a playback signal");
        Check(Enumerable.Range(0, samples / 2).All(i => measureBuffer[2*i + 1] == 0 &&
            float.IsFinite(measureBuffer[2*i]) && Math.Abs(measureBuffer[2*i]) <= .01001f),
            $"{kind} stays within its channel and level limits");
    }


    var indicatorBaseline = device.SoftwareConfiguration;
    var labelOnly = indicatorBaseline.Clone();
    labelOnly.Name = "Another label";
    Check(!device.HasWindowsApoPresetChanges(labelOnly), "Preset names do not affect dirty state");
    int revisionNotifications = 0;
    device.PropertyChanged += (_, e) =>
    {
        if (e.PropertyName == nameof(DspDevice.WindowsApoDesiredRevision)) revisionNotifications++;
    };
    Check(device.SetLevellerAmount(indicatorBaseline.Leveller.AmountPct + 1), "Effect edit applied to endpoint");
    Check(device.HasWindowsApoPresetChanges(indicatorBaseline) && revisionNotifications > 0,
        "Effect edit marks the named preset modified and notifies the UI");
    device.ApplySoftwareConfiguration(indicatorBaseline);
    Check(!device.HasWindowsApoPresetChanges(indicatorBaseline), "Restoring the saved effect settings clears the dirty state");
    var changedEq = indicatorBaseline.Clone();
    changedEq.Outputs[0].Eq[0].Type = 1;
    changedEq.Outputs[0].Eq[0].Gain = 2;
    device.ApplySoftwareConfiguration(changedEq);
    Check(device.HasWindowsApoPresetChanges(indicatorBaseline), "EQ edits mark the preset modified");
    device.ApplySoftwareConfiguration(indicatorBaseline);
    Check(!device.HasWindowsApoPresetChanges(indicatorBaseline), "Recalling the saved EQ clears the dirty state");

    var saved = client.Load()!;
    Check(saved.Revision == device.WindowsApoDesiredRevision, "Persisted revision matches desired revision");
    Check(device.SetWindowsApoInputPairLinks(endpoint, new[] { true, false, true, false }), "Input-pair link metadata saved to this endpoint");
    Check(client.Load()!.Configuration.InputPairLinked.SequenceEqual(new[] { true, false, true, false }), "Endpoint profile retains link choices");
    Check(!device.SetWindowsApoInputPairLinks(endpoint + "-old", new bool[4]), "Queued link edit cannot target a later endpoint");
    device.UseWindowsApo(endpoint, "Test DAC", 44100, 2, root);
    Check(device.SoftwareConfiguration.InputPairLinked[0] && device.SoftwareConfiguration.InputPairLinked[2], "Reconnection exposes saved link metadata for UI hydration");
    Check(device.SetOutputGain(0, -6), "Gain command reaches profile");
    Check(client.Load()!.Configuration.Outputs[0].GainDb == -6, "Saved gain used by remote native worker");
    Check(device.SetBypass(true), "Bypass publishes");
    Check(client.Load()!.Configuration.Bypass, "Bypass saved");
    var preset = device.SoftwareConfiguration; preset.Inputs[0].GainDb = -3; device.ApplySoftwareConfiguration(preset);
    Check(client.Load()!.Configuration.Inputs[0].GainDb == -3, "Full profile apply forwards input controls");
    var topology = preset.Clone(); topology.OutputCount = 8;
    Reject(() => device.ApplySoftwareConfiguration(topology), "Physical layout cannot change while APO controls bound");
    Reject(() => device.BeginSoftwareLive(new EngineConfiguration()), "Capture/render path cannot replace native APO controls");
    Reject(() => device.ProcessSoftwareAudio(new float[2], new float[2], 1), "Local rendering blocked while controlling APO");
    var status = device.GetStatus()!;
    Check(status.Peaks.All(p => p == 0), "No local mirror or fake meter when APO is absent");

    var telemetry = new byte[192];
    Encoding.ASCII.GetBytes("DSPIMTR1").CopyTo(telemetry, 0);
    void U32(int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(telemetry.AsSpan(offset), value);
    void U64(int offset, ulong value) => BinaryPrimitives.WriteUInt64LittleEndian(telemetry.AsSpan(offset), value);
    U32(8, 1); U32(12, 192); U64(16, 1UL << 32 | 7); U64(24, (ulong)DateTime.UtcNow.ToFileTimeUtc());
    U64(32, device.WindowsApoDesiredRevision); U64(40, device.WindowsApoDesiredRevision);
    U64(64, 4096); U32(72, 44100); U32(76, 2); U32(80, 1); U64(160, (ulong)DateTime.UtcNow.ToFileTimeUtc());
    U32(88, (uint)BitConverter.SingleToInt32Bits(.25f)); U32(120, (uint)BitConverter.SingleToInt32Bits(.5f)); U32(152, 257);
    string telemetryPath = Path.Combine(client.DirectoryPath, "telemetry"); Directory.CreateDirectory(telemetryPath);
    string statusFile = Path.Combine(telemetryPath, "status-1-7.bin"); File.WriteAllBytes(statusFile, telemetry);
    Check(device.GetWindowsApoStatuses().Count == 1, "Remote worker instance visible");
    status = device.GetStatus()!;
    Check(Math.Abs(status.Peaks[0] - .25f) < .001 && Math.Abs(status.Peaks[2] - .5f) < .001, "Meters come from remote native APO");
    Check(status.ClipFlags != 0, "Remote clip flags translated");
    device.ClearClips(); Check(device.GetStatus()!.ClipFlags == 0, "Clear ignores cached clip snapshot");
    U64(24, (ulong)DateTime.UtcNow.AddSeconds(-10).ToFileTimeUtc()); U64(160, (ulong)DateTime.UtcNow.AddSeconds(-10).ToFileTimeUtc());
    File.WriteAllBytes(statusFile, telemetry); Check(device.GetStatus()!.Peaks.All(p => p == 0), "Stale telemetry is not audio activity");

    if (args.Length == 2)
    {
        File.Delete(statusFile);
        device.ApplySoftwareConfiguration(new EngineConfiguration { SampleRate = 44100, InputCount = 2, OutputCount = 2 });
        var start = new ProcessStartInfo(args[0]) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in new[] { "--bridge", args[1], root, client.ProfileKey }) start.ArgumentList.Add(argument);
        using var bridge = Process.Start(start)!;
        try
        {
            string? ready = await bridge.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Check(ready == "READY", "Real native COM bridge starts without an audio device");
            void WaitFor(Func<bool> predicate, string label)
            {
                var timer = Stopwatch.StartNew();
                while (!predicate() && timer.Elapsed < TimeSpan.FromSeconds(5)) Thread.Sleep(10);
                Check(predicate(), label);
            }
            WaitFor(() => client.ReadStatuses().Any(s => s.IsProcessing && s.AppliedRevision == device.WindowsApoDesiredRevision), "Actual native worker reads managed profile and publishes processing");
            var rta = new RtaEngine(device);
            rta.FetchCaps();
            Check(rta.Supported && rta.Caps.InputChannels == 2 && rta.BandCentresHz[20] == 1000, "Console uses DSPi spectrum capability and centre table on Windows");
            var spectrum = rta.Subscribe(new RtaRequest(RtaWire.TapInput, 1, WantsBins: true));
            WaitFor(() => { rta.Tick(); return rta.Snapshot.Bins is { Channel: 0, SampleRateHz: 44100 } bins && bins.Bins.Any(level => level > 0); }, "Windows APO feeds real samples to the Console spectrum");
            rta.Update(spectrum, new RtaRequest(RtaWire.TapOutput, 1, WantsBins: true));
            WaitFor(() => { rta.Tick(); return rta.Snapshot.Frame(0, RtaWire.TapOutput)?.HasData == true; }, "Windows APO output tap publishes third-octave bands");
            rta.Release(spectrum);
            Check(device.SetOutputGain(0, -6.0206f), "Console gain command publishes to native worker");
            WaitFor(() => client.ReadStatuses().Any(s => s.IsProcessing && s.AppliedRevision == device.WindowsApoDesiredRevision), "Native audio callback acknowledges actual gain activation");
            await Task.Delay(30);
            await bridge.StandardInput.WriteLineAsync("sample");
            string? sample = await bridge.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(3));
            Check(sample?.StartsWith("SAMPLE ") == true && Math.Abs(float.Parse(sample[7..], CultureInfo.InvariantCulture) - .25f) < .0001f, "Console gain changes samples processed inside the native APO DLL");
            WaitFor(() => device.GetStatus()!.Peaks[0] > .49f, "Main Console meters receive real native instance input peaks");
            ulong applied = device.WindowsApoDesiredRevision;
            Check(device.SetLimiterParam(0, LimiterParam.Enabled, 1), "Latency-changing limiter setting saved");
            WaitFor(() => client.ReadStatuses().Any(s => s.PendingRestartRevision == device.WindowsApoDesiredRevision && s.AppliedRevision == applied), "Real worker defers latency change and preserves active revision");
            await bridge.StandardInput.WriteLineAsync("sample");
            sample = await bridge.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(3));
            Check(sample?.StartsWith("SAMPLE ") == true && Math.Abs(float.Parse(sample[7..], CultureInfo.InvariantCulture) - .25f) < .0001f, "Pending latency change preserves current output audio");
            Check(device.SetLimiterParam(0, LimiterParam.Enabled, 0), "Return to current latency");
            WaitFor(() => client.ReadStatuses().Any(s => s.AppliedRevision == device.WindowsApoDesiredRevision && s.PendingRestartRevision == 0), "Same-latency revision clears pending state");
            await bridge.StandardInput.WriteLineAsync("stop");
            await bridge.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Check(bridge.ExitCode == 0, "Native worker joins and COM DLL shuts down cleanly");
        }
        finally { if (!bridge.HasExited) { bridge.Kill(true); await bridge.WaitForExitAsync(); } }
    }

    ulong revision = client.Load()!.Revision;
    string persisted = PresetStore.Serialize(client.Load()!.Configuration);
    device.Disconnect(); Check(!device.IsWindowsApo, "Unbind control session");
    Check(client.Load()!.Revision == revision && PresetStore.Serialize(client.Load()!.Configuration) == persisted, "Disconnect leaves independent processing profile intact");
    device.UseSoftwareDsp(); Check(!device.IsWindowsApo && device.NumOutputChannels == 8, "Local software backend still works");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
Console.WriteLine($"PASS Windows APO Console controls: {count} checks");


