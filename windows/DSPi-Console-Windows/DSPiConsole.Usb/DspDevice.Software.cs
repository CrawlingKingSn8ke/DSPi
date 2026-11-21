using Dspi.Software;
using DSPiConsole.Core.Models;

namespace DSPiConsole.Usb;

/// <summary>Local processing transport. Unsupported hardware requests fail closed.</summary>
public partial class DspDevice
{
    private NativeSession? _software;
    private bool _softwareFileProcessing;
    public bool IsSoftwareMode => _software != null;

    public void UseSoftwareDsp(int inputCount = 2)
    {
        lock (_lock)
        {
            if (_softwareFileProcessing) throw new InvalidOperationException("Wait for WAV processing to finish before switching backends.");
            RequireSoftwareStopped();
            _backendMode.SelectSoftware();
            _pollTimer.Stop();
            HandleDisconnect();
            try
            {
                var configuration = new EngineConfiguration { InputCount = inputCount, OutputCount = 8 };
                for (int i = 0; i < 8; i++)
                {
                    configuration.Inputs[i].Name = $"Input {i + 1}";
                    configuration.Outputs[i].Name = $"Output {i + 1}";
                }
                _software = new NativeSession(configuration);
                NumInputChannels = inputCount; NumOutputChannels = 8;
                NumChannels = inputCount + 8;
                WireFormatVersion = 32;
                SelectedDeviceInfo = new DSPiDeviceInfo("SOFTWARE", "local://dspi-host");
                _availableDevices = new() { SelectedDeviceInfo };
                AvailableDevicesChanged?.Invoke(this, EventArgs.Empty);
                ErrorMessage = null;
                IsConnected = true;
                // MainViewModel owns the meter poll. The native peak read consumes
                // accumulated peaks, so a second timer would steal its samples.
                DeviceConnected?.Invoke(this, EventArgs.Empty);
            }
            catch (Exception ex)
            {
                _software?.Dispose();
                _software = null;
                ErrorMessage = "Software DSP could not start: " + ex.Message;
            }
        }
    }

    public EngineConfiguration SoftwareConfiguration
    {
        get { lock (_lock) return RequireSoftware().CurrentConfiguration; }
    }
    private NativeSession RequireSoftware() => _software ?? throw new InvalidOperationException("Select Software DSP first.");
    public void ApplySoftwareConfiguration(EngineConfiguration configuration, ParamSource source = ParamSource.HostSet)
    {
        configuration = configuration.Clone();
        configuration.Validate();
        lock (_lock)
        {
            if (_softwareFileProcessing) throw new InvalidOperationException("Wait for WAV processing to finish before loading a preset.");
            var current = RequireSoftware().CurrentConfiguration;
            if (_windowsApo != null)
            {
                ApplySoftwareUpdate(configuration);
                foreach (var pair in _windowsOutputEqPartners.Where(p => p.Key < p.Value &&
                    !OutputEqMatches(configuration, p.Key, p.Value)).ToArray())
                    UnlinkWindowsOutputEq(pair.Key, pair.Value);
            }
            else if (current.InputCount != configuration.InputCount || current.OutputCount != configuration.OutputCount || current.SampleRate != configuration.SampleRate)
            {
                RequireSoftwareStopped();
                var replacement = new NativeSession(configuration);
                _software!.Dispose();
                _software = replacement;
            }
            else ApplySoftwareUpdate(configuration);
            NumInputChannels = configuration.InputCount;
            NumOutputChannels = configuration.OutputCount;
            NumChannels = NumInputChannels + NumOutputChannels;
        }
        BulkInvalidated?.Invoke(this, source);
    }

    internal void BeginSoftwareFile(EngineConfiguration configuration)
    {
        lock (_lock)
        {
            RequireWindowsApoUnbound();
            RequireSoftwareStopped();
            if (_softwareFileProcessing) throw new InvalidOperationException("A WAV file is already being processed.");
            var replacement = new NativeSession(configuration);
            RequireSoftware().Dispose();
            _software = replacement;
            NumInputChannels = configuration.InputCount;
            NumOutputChannels = configuration.OutputCount;
            NumChannels = NumInputChannels + NumOutputChannels;
            _softwareFileProcessing = true;
        }
        BulkInvalidated?.Invoke(this, ParamSource.HostSet);
    }
    internal void EndSoftwareFile() { lock (_lock) _softwareFileProcessing = false; }

    public void ProcessSoftwareAudio(float[] input, float[] output, int frames)
    {
        lock (_lock) { RequireWindowsApoUnbound(); RequireSoftwareStopped(); RequireSoftware().Process(input, output, frames); }
    }

    private static ChannelConfiguration ChannelAt(EngineConfiguration c, int index) =>
        index < c.InputCount ? c.Inputs[index] : c.Outputs[index - c.InputCount];

    private static FilterConfiguration BandAt(EngineConfiguration c, int channel, int band)
    {
        var ch = ChannelAt(c, channel);
        return band >= 20 ? ch.Crossover[band - 20] : ch.Eq[band];
    }

    private bool SoftwareOut(byte request, ushort value, byte[] data)
    {
        try
        {
            var c = RequireSoftware().CurrentConfiguration;
            float F() => BitConverter.ToSingle(data, 0);
            bool B() => data[0] != 0;
            switch (request)
            {
                case VendorCommands.SetEqParam:
                    var f = BandAt(c, data[0], data[1]);
                    f.Type = data[2]; f.Bypass = data[3] != 0;
                    f.FrequencyHz = BitConverter.ToSingle(data, 4);
                    f.Q = BitConverter.ToSingle(data, 8); f.Gain = BitConverter.ToSingle(data, 12);
                    if (data.Length >= 18) f.TargetQ = BitConverter.ToUInt16(data, 16) / 512f;
                    MirrorWindowsOutputEqBand(c, data[0], data[1]);
                    break;
                case VendorCommands.SetBandBypass:
                    BandAt(c, value >> 8, value & 255).Bypass = B();
                    MirrorWindowsOutputEqBand(c, value >> 8, value & 255);
                    break;
                case VendorCommands.SetPreamp: foreach (var ch in c.Inputs) ch.GainDb = F(); break;
                case VendorCommands.SetPreampCh: c.Inputs[value].GainDb = F(); break;
                case VendorCommands.SetMasterVolume: c.MasterVolumeDb = F(); break;
                case VendorCommands.SetUserVolume: c.VolumeDb = F(); break;
                case VendorCommands.SetBypass: c.Bypass = B(); break;
                case VendorCommands.SetDelay: ChannelAt(c, value).DelayMs = F(); break;
                case VendorCommands.SetChannelGain: c.Outputs[value].GainDb = F(); break;
                case VendorCommands.SetChannelMute: c.Outputs[value].Muted = B(); break;
                case VendorCommands.SetOutputGain: c.Outputs[value].GainDb = F(); break;
                case VendorCommands.SetOutputMute: c.Outputs[value].Muted = B(); break;
                case VendorCommands.SetOutputDelay: c.Outputs[value].DelayMs = F(); break;
                case VendorCommands.SetOutputEnable: c.Outputs[value].Enabled = B(); break;
                case VendorCommands.SetChannelName:
                    ChannelAt(c, value).Name = System.Text.Encoding.UTF8.GetString(data).TrimEnd('\0'); break;
                case VendorCommands.SetMatrixRoute:
                    if (data[0] >= (c.Upmix.Enabled ? 5 : c.InputCount) || data[1] >= c.OutputCount) return false;
                    var route = c.Routes[data[0] * 8 + data[1]];
                    route.Enabled = data[2] != 0; route.Invert = data[3] != 0;
                    route.GainDb = BitConverter.ToSingle(data, 4); break;
                case VendorCommands.Limiter:
                    int o = value >> 8;
                    if ((value & 255) == 3 && o < c.OutputCount && (int)F() != 0)
                    {
                        var peer = c.Outputs.Take(c.OutputCount).Where((_, index) => index != o).FirstOrDefault(ch => ch.Limiter.LinkGroup == (int)F());
                        if (peer != null)
                        {
                            c.Outputs[o].Limiter.Enabled = peer.Limiter.Enabled;
                            c.Outputs[o].Limiter.ThresholdDb = peer.Limiter.ThresholdDb;
                            c.Outputs[o].Limiter.ReleaseMs = peer.Limiter.ReleaseMs;
                        }
                    }
                    int group = o < c.OutputCount ? c.Outputs[o].Limiter.LinkGroup : 0;
                    var targets = o == 255 ? c.Outputs.Take(c.OutputCount) :
                        (value & 255) != 3 && group != 0 ? c.Outputs.Take(c.OutputCount).Where(ch => ch.Limiter.LinkGroup == group) : new[] { c.Outputs[o] };
                    foreach (var ch in targets)
                    {
                        switch (value & 255)
                        {
                            case 0: ch.Limiter.Enabled = F() != 0; break;
                            case 1: ch.Limiter.ThresholdDb = F(); break;
                            case 2: ch.Limiter.ReleaseMs = F(); break;
                            case 3: ch.Limiter.LinkGroup = (int)F(); break;
                            default: return false;
                        }
                    }
                    break;
                default:
                    if (!SoftwareEffectOut(c, request, value, data)) return false;
                    break;
            }
            ApplySoftwareUpdate(c);
            return true;
        }
        catch (Exception ex)
        {
            ErrorMessage = "Software DSP rejected the setting: " + ex.Message;
            return false;
        }
    }

    private byte[]? SoftwareIn(byte request, ushort value, int length)
    {
        var c = RequireSoftware().CurrentConfiguration;
        byte[] F(float v) => BitConverter.GetBytes(v);
        byte[] B(bool v) => new[] { v ? (byte)1 : (byte)0 };
        try
        {
            switch (request)
            {
                case VendorCommands.GetStatus:
                    if (value == 15) return BitConverter.GetBytes((uint)c.SampleRate);
                    if (value != 9) return null;
                    var meters = ReadSoftwareMeters();
                    var packet = new byte[NumChannels * 2 + 6];
                    for (int i = 0; i < NumChannels; i++)
                    {
                        float peak = i < c.InputCount ? meters.Inputs[i] : meters.Outputs[i - c.InputCount];
                        BitConverter.GetBytes((ushort)Math.Clamp(peak * 32767, 0, 65535)).CopyTo(packet, i * 2);
                    }
                    uint clips = meters.Clips & ((1u << c.InputCount) - 1);
                    clips |= (meters.Clips >> 8) << c.InputCount;
                    BitConverter.GetBytes(clips).CopyTo(packet, NumChannels * 2 + 2);
                    return packet;
                case VendorCommands.ClearClips:
                    if (_windowsApo != null) _windowsApoClipClearTime = DateTime.UtcNow.ToFileTimeUtc();
                    else RequireSoftware().ReadMeters();
                    return new byte[2];
                case VendorCommands.GetEqParam:
                    var f = BandAt(c, value >> 8, (value >> 3) & 31);
                    return (value & 7) == 0 ? BitConverter.GetBytes(f.Type) :
                        (value & 7) == 5 ? BitConverter.GetBytes((uint)MathF.Round(f.TargetQ * 512)) :
                        F((value & 7) switch { 1 => f.FrequencyHz, 2 => f.Q, 3 => f.Gain, _ => 0 });
                case VendorCommands.GetBandBypass: return B(BandAt(c, value >> 8, value & 255).Bypass);
                case VendorCommands.GetPreamp: return F(c.Inputs[0].GainDb);
                case VendorCommands.GetPreampCh: return F(c.Inputs[value].GainDb);
                case VendorCommands.GetMasterVolume: return F(c.MasterVolumeDb);
                case VendorCommands.GetUserVolume: return F(c.VolumeDb);
                case VendorCommands.GetBypass: return B(c.Bypass);
                case VendorCommands.GetDelay: return F(ChannelAt(c, value).DelayMs);
                case VendorCommands.GetChannelGain:
                case VendorCommands.GetOutputGain: return F(c.Outputs[value].GainDb);
                case VendorCommands.GetChannelMute:
                case VendorCommands.GetOutputMute: return B(c.Outputs[value].Muted);
                case VendorCommands.GetOutputEnable: return B(c.Outputs[value].Enabled);
                case VendorCommands.GetOutputDelay: return F(c.Outputs[value].DelayMs);
                case VendorCommands.GetChannelName: return System.Text.Encoding.UTF8.GetBytes(ChannelAt(c, value).Name.PadRight(32, '\0'));
                case VendorCommands.GetSerial: return System.Text.Encoding.ASCII.GetBytes("SOFTWARE".PadRight(16, '\0'));
                case VendorCommands.GetMatrixRoute:
                    var r = c.Routes[(value >> 8) * 8 + (value & 255)];
                    var bytes = new byte[] { (byte)r.Input, (byte)r.Output, (byte)(r.Enabled ? 1 : 0), (byte)(r.Invert ? 1 : 0), 0, 0, 0, 0 };
                    F(r.GainDb).CopyTo(bytes, 4); return bytes;
                case VendorCommands.Limiter:
                    if ((value & 255) == LimiterParam.GetStatus)
                        return new[] { (byte)(c.Outputs.Take(c.OutputCount).Any(o => o.Limiter.Enabled) ? 1 : 0), (byte)LimiterLimits.LookaheadSamples, (byte)LimiterLimits.BlockSamples, (byte)c.OutputCount };
                    if ((value & 255) == LimiterParam.GetMeter) return null; // native gain reduction is not exposed
                    var l = c.Outputs[value >> 8].Limiter;
                    return F((value & 255) switch { 0 => l.Enabled ? 1 : 0, 1 => l.ThresholdDb, 2 => l.ReleaseMs, 3 => l.LinkGroup, _ => 0 });
                default: return SoftwareEffectIn(c, request, value);
            }
        }
        catch { return null; }
    }

    public BulkParams? GetSoftwareParams()
    {
        lock (_lock)
        {
            if (_software == null) return null;
            var c = _software.CurrentConfiguration;
            var bp = new BulkParams
            {
                FormatVersion = 32, NumChannels = (byte)(c.InputCount + c.OutputCount),
                NumInputChannels = (byte)c.InputCount, NumOutputChannels = (byte)c.OutputCount,
                MaxBands = (byte)c.Inputs[0].Eq.Length, Bypass = c.Bypass,
                HasCrossover = true, HasPerChannelPreamp = true, HasMasterVolume = true,
                MasterVolumeDb = c.MasterVolumeDb, HasUserVolume = true, UserVolumeDb = c.VolumeDb,
                Preamp = c.Inputs.Select(i => i.GainDb).ToArray(),
                PreampLDb = c.Inputs[0].GainDb, PreampRDb = c.Inputs[1].GainDb,
                Delays = new float[17], ChannelNames = new string[c.InputCount + c.OutputCount],
                HasLimiter = true, Limiter = new LimiterOutputSettings[9]
            };
            FilterParams Convert(FilterConfiguration f) => new((FilterType)f.Type, f.FrequencyHz, f.Q, f.Gain) { Bypass = f.Bypass, Qp = f.TargetQ };
            for (int i = 0; i < 17; i++)
            {
                var ch = i < c.InputCount + c.OutputCount ? ChannelAt(c, i) : null;
                if (i < bp.ChannelNames.Length && ch != null) bp.ChannelNames[i] = ch.Name;
                bp.Delays[i] = ch?.DelayMs ?? 0;
                for (int b = 0; b < 12; b++) bp.Eq[i, b] = ch != null && b < ch.Eq.Length ? Convert(ch.Eq[b]) : new FilterParams();
                for (int b = 0; b < 4; b++) bp.Xover[i, b] = ch != null ? Convert(ch.Crossover[b]) : new FilterParams();
            }
            for (int i = 0; i < 9; i++)
            {
                if (i >= c.OutputCount) { bp.Limiter[i] = new(); continue; }
                var ch = c.Outputs[i];
                bp.Outputs[i] = (ch.Enabled, ch.Muted, ch.GainDb, ch.DelayMs);
                bp.Limiter[i] = new() { Enabled = ch.Limiter.Enabled, ThresholdDb = ch.Limiter.ThresholdDb, ReleaseMs = ch.Limiter.ReleaseMs, LinkGroup = ch.Limiter.LinkGroup };
                for (int input = 0; input < (c.Upmix.Enabled ? 5 : c.InputCount); input++)
                {
                    var r = c.Routes[input * 8 + i];
                    bp.Crosspoints[input, i] = (r.Enabled, r.Invert, r.GainDb);
                }
            }
            FillSoftwareEffects(bp, c);
            return bp;
        }
    }
}

