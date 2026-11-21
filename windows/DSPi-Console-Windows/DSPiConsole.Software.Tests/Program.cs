using DSPiConsole.Usb;
using DSPiConsole.Core.Models;
using Dspi.Software;

int assertions = 0;
void Check(bool condition, string label) { assertions++; if (!condition) throw new Exception(label); }
void Near(float actual, float expected, string label) => Check(Math.Abs(actual - expected) < .00005f, $"{label}: {actual} != {expected}");
var selection = new BackendModeState();
Check(!selection.TryCaptureHardwareScan(out _), "Startup does not authorize a hardware scan");
selection.SelectHardware();
Check(selection.TryCaptureHardwareScan(out var scan) && selection.IsCurrentHardwareScan(scan), "Explicit hardware selection authorizes its scan");
selection.SelectSoftware();
Check(!selection.IsCurrentHardwareScan(scan), "In-flight hardware scan cannot publish or reconnect after software selection");
selection.SelectHardware();
Check(!selection.IsCurrentHardwareScan(scan), "Re-selecting hardware cannot revive a stale scan generation");
using var d = new DspDevice();
d.StartMonitoring();
Check(!d.IsConnected && d.AvailableDevicesList.Count == 0, "Startup remains disconnected without discovering USB");
d.UseSoftwareDsp();
Check(d.IsConnected && d.IsSoftwareMode && d.SelectedDeviceInfo?.DisplayName == "Software DSP", "Explicit software identity");
Check(d.NumInputChannels == 2 && d.NumOutputChannels == 8 && d.NumChannels == 10, "Real software topology");
Check(d.GetPlatformInfo()?.Platform == "Software DSP", "Software platform is not a hardware impersonation");
Check(d.SetOutputPin(0, 14) == 255, "GPIO unavailable");
Check(d.SaveParams() != 0 && d.FactoryReset() != 0, "Flash operations unavailable");
Check(d.SetFilter(0, 0, new FilterParams(FilterType.Peaking, 900, .8f, 3)), "Input EQ accepted");
Check(d.SoftwareConfiguration.Inputs[0].Eq[0].Type == 1, "Input EQ reaches managed processor config");
Check(!d.SetFilter(0, 10, new FilterParams(FilterType.Peaking, 1000, 1, 3)), "Unsupported eleventh EQ rejected");
Check(d.SetTubeParam(TubeParam.DriveDb, -8), "Tube command");
Near(d.SoftwareConfiguration.Tube.DriveDb, -8, "Tube config");
Check(d.SetLoudnessEnabled(true) && d.SetLoudnessRefSPL(80), "Loudness command");
Check(d.SetCrossfeedEnabled(true) && d.SetCrossfeedPreset(1), "Crossfeed command");
Check(d.SetLevellerEnabled(true) && d.SetLevellerAmount(30), "Leveller command");
Check(d.SetPsybassEnabled(true), "Psybass command");
Check(d.SetSubharmEnabled(true), "Subharm command");
Check(d.SetUpmixParam(UpmixParam.Enabled, 1), "Upmix enabled");
Check(d.SetMatrixRoute(4, 7, true, true, -3), "Upmix derived route accepted");
Check(d.SoftwareConfiguration.Routes[4 * 8 + 7].Enabled, "Upmix route reaches engine");
Check(d.SetUpmixParam(UpmixParam.Presence, 2), "Upmix presence command");
Near(d.GetUpmixConfig()!.PresenceDb, 2, "Upmix packed config presence");
Check(d.SetLimiterParam(0, LimiterParam.LinkGroup, 1), "Limiter leader link");
Check(d.SetLimiterParam(0, LimiterParam.ThresholdDb, -8), "Limiter leader threshold");
Check(d.SetLimiterParam(1, LimiterParam.LinkGroup, 1), "Limiter member joins group");
Near(d.SoftwareConfiguration.Outputs[1].Limiter.ThresholdDb, -8, "Joining limiter adopts leader");
Check(d.SetLimiterParam(1, LimiterParam.Enabled, 1) && d.SetLimiterParam(1, LimiterParam.ReleaseMs, 200), "Limiter member edits gang");
Near(d.SoftwareConfiguration.Outputs[0].Limiter.ReleaseMs, 200, "Limiter release gang");
Check(d.SoftwareConfiguration.Outputs[0].Limiter.Enabled, "Limiter enable gang");
Check(d.GetLimiterStatus()?.Outputs == 8, "Limiter capability probe reports actual output count");
var bulk = d.GetSoftwareParams()!;
Check(bulk.HasTube && bulk.HasPsybass && bulk.HasSubharm && bulk.HasUpmix && bulk.HasLimiter && bulk.HasLevellerConfig, "All effect capabilities seeded");
Check(bulk.NumOutputChannels == 8 && bulk.MaxBands == 10, "Bulk describes actual engine limits");
Check(bulk.Crosspoints[4, 7].enabled && bulk.Crosspoints[4, 7].invert && bulk.Crosspoints[4, 7].gain == -3, "Bulk refresh preserves upmix derived routing");

// A clean session provides a known numeric signal path and meter expectations.
d.ApplySoftwareConfiguration(new EngineConfiguration { InputCount = 2, OutputCount = 8 });
var source = new float[4096 * 2]; var destination = new float[4096 * 8];
for (int i = 0; i < 4096; i++) { source[i * 2] = .25f; source[i * 2 + 1] = -.5f; }
d.ProcessSoftwareAudio(source, destination, 4096);
Near(destination[^8], .25f, "Actual native output left"); Near(destination[^7], -.5f, "Actual native output right");
var status = d.GetStatus()!;
Near(status.Peaks[0], .25f, "Actual input meter"); Near(status.Peaks[2], .25f, "Actual output meter in app channel space");
Check(d.SetOutputGain(0, -6.0206f), "Gain edit");
d.ProcessSoftwareAudio(source, destination, 4096);
Near(destination[^8], .125f, "Gain edit changes rendered native audio");
Check(d.SetMasterVolume(-6.0206f) && d.SetUserVolume(-6), "Master and user volume controls accepted independently");
d.ProcessSoftwareAudio(source, destination, 4096);
Near(destination[^8], .25f * MathF.Pow(10, (-6.0206f - 6.0206f - 6) / 20), "Independent master and user gains both affect actual audio");
Near(d.GetMasterVolume()!.Value, -6.0206f, "Master gain readback");
Near(d.GetUserVolume()!.Value, -6, "User gain readback");
Check(d.SetMasterVolume(0) && d.SetUserVolume(0), "Reset independent volume controls");
source[0] = 2;
d.ProcessSoftwareAudio(source, destination, 4096);
status = d.GetStatus()!;
Check((status.ClipFlags & 1) != 0, "Input clip flags from actual audio");
d.ClearClips(); Check(d.GetStatus()!.ClipFlags == 0, "Clear clips consumes native flags");

string folder = Path.Combine(Path.GetTempPath(), "dspi-console-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(folder);
try
{
    string input = Path.Combine(folder, "input.wav"), output = Path.Combine(folder, "output.wav"), preset = Path.Combine(folder, "preset.dspisw");
    using (var w = new BinaryWriter(File.Create(input)))
    {
        void Tag(string s) => w.Write(System.Text.Encoding.ASCII.GetBytes(s));
        Tag("RIFF"); w.Write(36 + 4096 * 4); Tag("WAVE"); Tag("fmt "); w.Write(16); w.Write((ushort)1); w.Write((ushort)2); w.Write(44100); w.Write(176400); w.Write((ushort)4); w.Write((ushort)16); Tag("data"); w.Write(4096 * 4);
        for (int i = 0; i < 4096; i++) { w.Write((short)8192); w.Write((short)-16384); }
    }
    SoftwareWaveProcessor.Process(d, input, output);
    Near(d.SoftwareConfiguration.SampleRate, 44100, "WAV source sample rate configures engine without resampling");
    using (var r = new BinaryReader(File.OpenRead(output)))
    {
        r.BaseStream.Position = 44 + (4096 - 1) * 8 * 4;
        Near(r.ReadSingle(), .125f, "WAV processing uses live configured gain");
    }
    PresetStore.Save(preset, d.SoftwareConfiguration);
    var restored = PresetStore.Load(preset);
    Near(restored.Outputs[0].GainDb, -6.0206f, "Software full preset roundtrip");
    d.UseSoftwareDsp(8); Check(d.NumInputChannels == 8 && d.NumChannels == 16, "Explicit multichannel mode");
    Check(!d.SetUpmixParam(UpmixParam.Enabled, 1), "Upmix rejects non-stereo topology");
}
finally { foreach (string path in Directory.EnumerateFiles(folder)) File.Delete(path); Directory.Delete(folder); }
// A live lease owns the stable session until the transport has joined callbacks.
d.UseSoftwareDsp(2);
var liveConfiguration = d.SoftwareConfiguration;
using (var live = d.BeginSoftwareLive(liveConfiguration))
{
    Check(d.IsSoftwareLive, "Live state is visible");
    void Reject(Action action, string label)
    {
        bool rejected = false;
        try { action(); } catch (InvalidOperationException ex) { rejected = ex.Message.Contains("Stop Live Audio"); }
        Check(rejected, label);
    }
    Reject(() => d.BeginSoftwareLive(liveConfiguration), "Second live stream rejected");
    Reject(() => d.UseSoftwareDsp(8), "Software backend switch guarded");
    Reject(() => d.UseUsbHardware(), "Hardware backend switch guarded before discovery");
    Reject(() => d.Disconnect(), "Disconnect cannot free callback session");
    Reject(() => d.Dispose(), "Dispose cannot free callback session");
    Reject(() => d.BeginSoftwareFile(liveConfiguration), "WAV processing blocked while live");
    var topology = liveConfiguration.Clone(); topology.InputCount = 8;
    Reject(() => d.ApplySoftwareConfiguration(topology), "Live topology change blocked");
    var rate = liveConfiguration.Clone(); rate.SampleRate = 44100;
    Reject(() => d.ApplySoftwareConfiguration(rate), "Live sample rate change blocked");
    Check(d.SetOutputGain(0, -6.0206f), "Control edit accepted while live");
    var sameFormat = d.SoftwareConfiguration; sameFormat.Outputs[0].GainDb = 0;
    d.ApplySoftwareConfiguration(sameFormat, ParamSource.Preset);
    live.Process(source, destination, 4096);
    Near(destination[^8], .25f, "Same-format live preset reaches stable session");
    Check(d.GetStatus()!.Peaks[2] > 0, "Live processing feeds real meters");
    // Hold the UI/control lock on this thread: audio must still finish elsewhere.
    var controlLock = typeof(DspDevice).GetField("_lock", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(d)!;
    Task render;
    lock (controlLock)
    {
        render = Task.Run(() => live.Process(source, destination, 4096));
        Check(render.Wait(TimeSpan.FromSeconds(2)), "Audio callback bypasses UI/control lock");
    }
    render.GetAwaiter().GetResult();
}
Check(!d.IsSoftwareLive, "Joined transport can release live lease");
// Starting live audio must not replay delay history from a previous file/session.
var delayed = d.SoftwareConfiguration; delayed.Outputs[0].DelayMs = 30;
d.ApplySoftwareConfiguration(delayed); d.ProcessSoftwareAudio(source, destination, 4096);
using (var fresh = d.BeginSoftwareLive(delayed))
{
    fresh.Process(new float[256 * 2], destination, 256);
    Check(destination.Take(256 * 8).All(v => v == 0), "Live start must discard prior-session delay history");
}
d.UseSoftwareDsp(8);
Check(d.NumInputChannels == 8, "Topology can change after live stop");
using (var ended = d.BeginSoftwareLive(d.SoftwareConfiguration))
{
    ended.Dispose();
    bool rejected = false;
    try { ended.Process(new float[8], new float[8], 1); } catch (ObjectDisposedException) { rejected = true; }
    Check(rejected, "Ended lease cannot process");
}
d.Disconnect();
Check(!d.IsConnected && !d.IsSoftwareLive, "Backend closes safely after live stop");
Console.WriteLine($"PASS: {assertions} Console software backend checks (no UI or hardware).");

