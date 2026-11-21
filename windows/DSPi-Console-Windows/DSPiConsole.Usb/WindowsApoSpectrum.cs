using System.Buffers.Binary;
using Dspi.Apo;
using DSPiConsole.Core.Rta;

namespace DSPiConsole.Usb;

/// <summary>Adapts the endpoint's Windows spectrum telemetry to the existing analyser.</summary>
internal sealed class WindowsApoSpectrum(ApoProfileClient profile, int rate, int channels)
{
    private const int ConfigBytes = 24;
    private const int FramesOffset = ConfigBytes + RtaWire.StatusSize;
    private static readonly ushort[] Centres =
    [
        10, 13, 16, 20, 25, 32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
        12500, 16000, 20000, 25000, 31500, 40000
    ];

    private RtaConfig _config = new();
    private uint _reset;
    private long _lastControl = -1000;
    private long _lastRead = -1000;
    private long _lastCapabilityCheck = -1000;
    private bool _canRequest;
    private byte[]? _snapshot;
    private byte[]? _binSnapshot;

    public bool Configure(RtaConfig config)
    {
        if (config.Tap > RtaWire.TapOutput || config.ChannelMask == 0 || config.ChannelMask >> channels != 0 ||
            config.FftOrder < RtaWire.OrderMin || config.FftOrder > RtaWire.OrderMax)
            return false;
        if (_config != config)
        {
            _config = config;
            _lastControl = -1000;
            _snapshot = null;
            _binSnapshot = null;
        }
        return Renew();
    }

    public byte[]? Read(byte request, ushort value, int length)
    {
        if (length <= 0) return null;
        switch (request)
        {
            case RtaWire.GetCaps:
                if (value == 0) return Slice([3, (byte)channels, (byte)channels, 8, 10, 10, 14, 37, 243, 120, 208, 7, 17, 2, 120, 0], 0, length);
                int start = (value - 1) * RtaWire.CentresPerChunk;
                if (start >= Centres.Length) return null;
                var centres = new byte[Math.Min(Centres.Length - start, RtaWire.CentresPerChunk) * 2];
                for (int index = 0; index < centres.Length / 2; index++)
                    BinaryPrimitives.WriteUInt16LittleEndian(centres.AsSpan(index * 2), Centres[start + index]);
                return Slice(centres, 0, length);
            case RtaWire.GetConfig:
                return Slice(_config.ToBytes(), 0, length);
            case RtaWire.Control:
                if (value == RtaWire.CtlStop) { Stop(); return [0]; }
                if (value == RtaWire.CtlResetAvg)
                {
                    _reset++;
                    _snapshot = null;
                    _lastControl = -1000;
                }
                return Renew() ? [0] : null;
            case RtaWire.GetStatus:
                byte[]? latest = GetSnapshot();
                if (latest != null) return Slice(latest, ConfigBytes, Math.Min(length, RtaWire.StatusSize));
                byte[] status = new byte[RtaWire.StatusSize];
                status[0] = RtaWire.Version;
                status[2] = _config.Tap;
                status[3] = RtaWire.ChannelNone;
                status[20] = IsRateSupported ? (byte)0 : (byte)255;
                BinaryPrimitives.WriteUInt32LittleEndian(status.AsSpan(16), (uint)rate);
                return Slice(status, 0, length);
            case RtaWire.GetBands:
            case RtaWire.GetBandsAll:
            case RtaWire.GetBins:
                if (!Renew()) return null;
                return ReadFrames(request, value, length);
            default:
                return null;
        }
    }

    public bool IsRateSupported => rate is 44100 or 48000 or 96000;

    public void Stop()
    {
        _snapshot = null;
        _binSnapshot = null;
        _lastControl = -1000;
        // The short lease ends by itself, including after a crash. A different
        // controller may already be using the endpoint, so leave its file alone.
    }

    private byte[]? ReadFrames(byte request, ushort value, int length)
    {
        if (request == RtaWire.GetBins)
        {
            if (value == 0) _binSnapshot = GetSnapshot();
            return _binSnapshot == null ? null : Slice(_binSnapshot, EndOfBandFrames(_binSnapshot) + value, length);
        }
        byte[]? snapshot = GetSnapshot();
        if (snapshot == null) return null;
        int end = EndOfBandFrames(snapshot);
        if (request == RtaWire.GetBandsAll) return Slice(snapshot, FramesOffset, Math.Min(length, end - FramesOffset));
        for (int offset = FramesOffset; offset < end; offset += RtaWire.BandFrameSize)
            if (snapshot[offset + 1] == value) return Slice(snapshot, offset, Math.Min(length, RtaWire.BandFrameSize));
        return null;
    }

    private static int EndOfBandFrames(byte[] data) => FramesOffset + data[ConfigBytes + 5] * RtaWire.BandFrameSize;
    private static byte[]? Slice(byte[] bytes, int offset, int length) =>
        offset >= bytes.Length || length <= 0 ? null : bytes.AsSpan(offset, Math.Min(length, bytes.Length - offset)).ToArray();

    private byte[] BuildControl()
    {
        var bytes = new byte[ConfigBytes];
        "DSPIRTA1"u8.CopyTo(bytes);
        _config.ToBytes().CopyTo(bytes, 8);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(20), _reset);
        return bytes;
    }

    private bool Renew()
    {
        if (Environment.TickCount64 - _lastControl < 500) return true;
        if (Environment.TickCount64 - _lastCapabilityCheck >= 500)
        {
            _lastCapabilityCheck = Environment.TickCount64;
            try
            {
                _canRequest = IsRateSupported && profile.ReadStatuses().Any(status =>
                    status.IsFresh && status.Status != 5 && status.ActualRate == rate && status.PhysicalChannels == channels &&
                    File.Exists(Path.Combine(profile.TelemetryDirectoryPath, $"spectrum-{status.InstanceId >> 32}-{(uint)status.InstanceId}.bin")));
            }
            catch (UnauthorizedAccessException) { _canRequest = false; }
        }
        if (!_canRequest) return false;
        string path = Path.Combine(profile.DirectoryPath, "rta-control.bin");
        string temporary = Path.Combine(profile.DirectoryPath, $"rta-control.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, BuildControl());
            File.Move(temporary, path, overwrite: true);
            _lastControl = Environment.TickCount64;
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private byte[]? GetSnapshot()
    {
        long now = Environment.TickCount64;
        if (now - _lastRead < 25) return _snapshot;
        _lastRead = now;
        _snapshot = null;
        var control = BuildControl();
        try
        {
            foreach (var file in new DirectoryInfo(profile.TelemetryDirectoryPath).EnumerateFiles("spectrum-*-*.bin")
                .Where(f => f.Length >= FramesOffset && f.Length <= FramesOffset + 8 * RtaWire.BandFrameSize + RtaWire.BinFrameMax &&
                    (DateTime.UtcNow - f.LastWriteTimeUtc).TotalMilliseconds is >= 0 and < 500)
                .OrderByDescending(f => f.LastWriteTimeUtc))
            {
                using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (stream.Length < FramesOffset || stream.Length > FramesOffset + 8 * RtaWire.BandFrameSize + RtaWire.BinFrameMax) continue;
                var data = new byte[(int)stream.Length];
                stream.ReadExactly(data);
                if (!control.AsSpan().SequenceEqual(data.AsSpan(0, ConfigBytes)) ||
                    data[ConfigBytes] != RtaWire.Version || data[ConfigBytes + 5] > channels ||
                    EndOfBandFrames(data) >= data.Length || RtaBinFrame.Parse(data[EndOfBandFrames(data)..]) == null) continue;
                return _snapshot = data;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return null;
    }
}

