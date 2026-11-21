using Dspi.Software;
using DSPiConsole.Core.Models;

namespace DSPiConsole.Usb;

public partial class DspDevice
{
    // Each pair is the existing Console SET/GET command and the managed parameter.
    // Value widths remain those expected by the USB-facing view model.
    private static (object Owner, string Property, int Width)? EffectParameter(EngineConfiguration c, byte request)
    {
        return request switch
        {
            0x58 or 0x59 => (c.Loudness, "Enabled", 1),
            0x5A or 0x5B => (c.Loudness, "RefSpl", 4),
            0x5C or 0x5D => (c.Loudness, "IntensityPct", 4),
            VendorCommands.SetLoudnessMask or VendorCommands.GetLoudnessMask => (c.Loudness, "OutputMask", 2),
            0x5E or 0x5F => (c.Crossfeed, "Enabled", 1),
            0x60 or 0x61 => (c.Crossfeed, "Preset", 1),
            0x62 or 0x63 => (c.Crossfeed, "FreqHz", 4),
            0x64 or 0x65 => (c.Crossfeed, "FeedDb", 4),
            0x66 or 0x67 => (c.Crossfeed, "Itd", 1),
            VendorCommands.SetCrossfeedOutputs or VendorCommands.GetCrossfeedOutputs => (c.Crossfeed, "OutputPairMask", 1),
            VendorCommands.SetLevellerEnabled or VendorCommands.GetLevellerEnabled => (c.Leveller, "Enabled", 1),
            VendorCommands.SetLevellerAmount or VendorCommands.GetLevellerAmount => (c.Leveller, "AmountPct", 4),
            VendorCommands.SetLevellerSpeed or VendorCommands.GetLevellerSpeed => (c.Leveller, "Speed", 1),
            VendorCommands.SetLevellerMaxGain or VendorCommands.GetLevellerMaxGain => (c.Leveller, "MaxGainDb", 4),
            VendorCommands.SetLevellerLookahead or VendorCommands.GetLevellerLookahead => (c.Leveller, "Lookahead", 1),
            VendorCommands.SetLevellerGate or VendorCommands.GetLevellerGate => (c.Leveller, "GateDb", 4),
            0x30 or 0x31 => (c.Psybass, "Enabled", 1),
            0x32 or 0x33 => (c.Psybass, "CutoffHz", 4),
            0x34 or 0x35 => (c.Psybass, "HarmonicsDb", 4),
            0x36 or 0x37 => (c.Psybass, "DriveDb", 4),
            0x38 or 0x39 => (c.Psybass, "CharacterPct", 4),
            0x3A or 0x3B => (c.Psybass, "OriginalDb", 4),
            0x3C or 0x3D => (c.Psybass, "OutputMask", 2),
            0x10 or 0x11 => (c.Subharm, "Enabled", 1),
            0x12 or 0x13 => (c.Subharm, "LowDb", 4),
            0x14 or 0x15 => (c.Subharm, "HighDb", 4),
            0x16 or 0x17 => (c.Subharm, "BoostDb", 4),
            0x18 or 0x19 => (c.Subharm, "OutputMask", 2),
            0x1B or 0x1C => (c.Subharm, "TopDb", 4),
            0x1D or 0x1E => (c.Subharm, "SelectMode", 1),
            0x2C or 0x2D => (c.Subharm, "Solo", 1),
            0x2E or 0x2F => (c.Subharm, "LinkPairs", 1),
            0xA9 or 0xAA => (c.Subharm, "SelectDepthPct", 4),
            0xAB or 0xAC => (c.Subharm, "SelectHoldMs", 4),
            0xAD or 0xAE => (c.Subharm, "CeilingDb", 4),
            _ => null
        };
    }
    private static readonly string[] TubeProperties = { "Enabled", "OutputMask", "TubeType", "DriveDb", "BiasPct", "AsymDb", "HardnessPct", "SagPct", "Rectifier", "XfmrEnabled", "XfmrDamping", "XfmrResHz", "MixPct", "TrimDb" };
    private static readonly string[] UpmixProperties = { "Enabled", "CenterMode", "SurroundMode", "StrengthPct", "CenterWidthPct", "ThresholdPct", "AttackMs", "ReleaseMs", "DetectorHpfHz", "SurroundDelayMs", "SurroundHpfHz", "SurroundLpfHz", "DecorrPct", "PresenceDb" };

    private static void Assign(object owner, string name, float value)
    {
        var property = owner.GetType().GetProperty(name) ?? throw new ArgumentException(name);
        property.SetValue(owner, property.PropertyType == typeof(bool) ? value != 0 : Convert.ChangeType(value, property.PropertyType));
    }
    private static float Read(object owner, string name) => Convert.ToSingle(owner.GetType().GetProperty(name)!.GetValue(owner));

    private bool SoftwareEffectOut(EngineConfiguration c, byte request, ushort value, byte[] data)
    {
        if (request == VendorCommands.SetTubeParam) { Assign(c.Tube, TubeProperties[value], BitConverter.ToSingle(data)); return true; }
        if (request == VendorCommands.UpmixSetParam) { Assign(c.Upmix, UpmixProperties[value], BitConverter.ToSingle(data)); return true; }
        if (request == VendorCommands.UpmixSetConfig)
        {
            c.Upmix.Enabled = data[0] != 0; c.Upmix.CenterMode = data[1]; c.Upmix.SurroundMode = data[2];
            c.Upmix.PresenceDb = (sbyte)data[3] / 2f;
            for (int i = 3; i < 13; i++) Assign(c.Upmix, UpmixProperties[i], BitConverter.ToSingle(data, 4 + (i - 3) * 4));
            return true;
        }
        if (request == VendorCommands.SetLevellerMasks) { c.Leveller.DetectorMask = data[0]; c.Leveller.ApplyMask = data[1]; return true; }
        if (EffectParameter(c, request) is not { } parameter) return false;
        float v = parameter.Width switch { 1 => data[0], 2 => BitConverter.ToUInt16(data), _ => BitConverter.ToSingle(data) };
        Assign(parameter.Owner, parameter.Property, v);
        return true;
    }
    private byte[]? SoftwareEffectIn(EngineConfiguration c, byte request, ushort value)
    {
        if (request == VendorCommands.GetTubeParam) return BitConverter.GetBytes(Read(c.Tube, TubeProperties[value]));
        if (request == VendorCommands.UpmixGetParam) return BitConverter.GetBytes(Read(c.Upmix, UpmixProperties[value]));
        if (request == VendorCommands.UpmixGetConfig)
        {
            return UpmixBytes(c.Upmix);
        }
        if (request == VendorCommands.GetLevellerMasks) return new[] { (byte)c.Leveller.DetectorMask, (byte)c.Leveller.ApplyMask };
        if (EffectParameter(c, request) is not { } parameter) return null;
        float v = Read(parameter.Owner, parameter.Property);
        return parameter.Width switch { 1 => new[] { (byte)v }, 2 => BitConverter.GetBytes((ushort)v), _ => BitConverter.GetBytes(v) };
    }

    private static void FillSoftwareEffects(BulkParams bp, EngineConfiguration c)
    {
        var l = c.Loudness; bp.LoudnessEnabled = l.Enabled; bp.LoudnessRefSpl = l.RefSpl; bp.LoudnessIntensityPct = l.IntensityPct; bp.LoudnessOutputMask = (ushort)l.OutputMask;
        var x = c.Crossfeed; bp.CrossfeedEnabled = x.Enabled; bp.CrossfeedPreset = (byte)x.Preset; bp.CrossfeedFreq = x.FreqHz; bp.CrossfeedFeedDb = x.FeedDb; bp.CrossfeedItd = x.Itd; bp.CrossfeedOutputPairMask = (byte)x.OutputPairMask;
        var v = c.Leveller; bp.HasLevellerConfig = true; bp.LevellerEnabled = v.Enabled; bp.LevellerAmount = v.AmountPct; bp.LevellerSpeed = (byte)v.Speed; bp.LevellerMaxGainDb = v.MaxGainDb; bp.LevellerGateDb = v.GateDb; bp.LevellerLookahead = v.Lookahead; bp.LevellerDetectorMask = (byte)v.DetectorMask; bp.LevellerApplyMask = (byte)v.ApplyMask;
        var p = c.Psybass; bp.HasPsybass = true; bp.PsybassEnabled = p.Enabled; bp.PsybassCutoffHz = p.CutoffHz; bp.PsybassHarmonicsDb = p.HarmonicsDb; bp.PsybassDriveDb = p.DriveDb; bp.PsybassCharacterPct = p.CharacterPct; bp.PsybassOriginalDb = p.OriginalDb; bp.PsybassOutputMask = (ushort)p.OutputMask;
        var s = c.Subharm; bp.HasSubharm = bp.HasSubharmExtended = true; bp.SubharmEnabled = s.Enabled; bp.SubharmLowDb = s.LowDb; bp.SubharmHighDb = s.HighDb; bp.SubharmTopDb = s.TopDb; bp.SubharmBoostDb = s.BoostDb; bp.SubharmOutputMask = (ushort)s.OutputMask; bp.SubharmSelectMode = (byte)s.SelectMode; bp.SubharmSelectDepthPct = s.SelectDepthPct; bp.SubharmSelectHoldMs = s.SelectHoldMs; bp.SubharmCeilingDb = s.CeilingDb; bp.SubharmLinkPairs = s.LinkPairs;
        var t = c.Tube; bp.HasTube = true; bp.TubeEnabled = t.Enabled; bp.TubeOutputMask = (ushort)t.OutputMask; bp.TubeType = (byte)t.TubeType; bp.TubeDriveDb = t.DriveDb; bp.TubeBiasPct = t.BiasPct; bp.TubeAsymDb = t.AsymDb; bp.TubeHardnessPct = t.HardnessPct; bp.TubeSagPct = t.SagPct; bp.TubeRectifier = (byte)t.Rectifier; bp.TubeXfmrEnabled = t.XfmrEnabled; bp.TubeXfmrDamping = t.XfmrDamping; bp.TubeXfmrResHz = t.XfmrResHz; bp.TubeMixPct = t.MixPct; bp.TubeTrimDb = t.TrimDb;
        var u = c.Upmix; bp.HasUpmix = true;
        bp.Upmix = UpmixConfig.FromBytes(UpmixBytes(u));
    }
    private static byte[] UpmixBytes(UpmixConfiguration u)
    {
        var bytes = new byte[44]; bytes[0] = (byte)(u.Enabled ? 1 : 0); bytes[1] = (byte)u.CenterMode; bytes[2] = (byte)u.SurroundMode;
        bytes[3] = unchecked((byte)(sbyte)Math.Clamp((int)MathF.Round(u.PresenceDb * 2), -24, 24));
        for (int i = 3; i < 13; i++) BitConverter.GetBytes(Read(u, UpmixProperties[i])).CopyTo(bytes, 4 + (i - 3) * 4);
        return bytes;
    }
}
