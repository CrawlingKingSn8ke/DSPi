using System.Text;

namespace DSPiConsole.Usb;

/// <summary>Streams PCM/IEEE WAV audio through the same session used by Console controls.</summary>
public static class SoftwareWaveProcessor
{
    public static void Process(DspDevice device, string inputPath, string outputPath)
    {
        using var input = new BinaryReader(File.OpenRead(inputPath));
        string Tag() => Encoding.ASCII.GetString(input.ReadBytes(4));
        if (Tag() != "RIFF") throw new InvalidDataException("Expected a RIFF WAV file.");
        long riffEnd = input.ReadUInt32() + 8L;
        if (riffEnd > input.BaseStream.Length || riffEnd < 12) throw new InvalidDataException("Truncated RIFF file.");
        if (Tag() != "WAVE") throw new InvalidDataException("Expected a WAV file.");
        ushort format = 0, channels = 0, bits = 0, alignment = 0;
        uint rate = 0, dataSize = 0; long dataStart = 0;
        while (input.BaseStream.Position + 8 <= riffEnd)
        {
            var tag = Tag(); uint size = input.ReadUInt32(); long start = input.BaseStream.Position;
            if (start + size > riffEnd) throw new InvalidDataException("Truncated WAV chunk.");
            if (tag == "fmt ")
            {
                if (size < 16) throw new InvalidDataException("Invalid WAV format.");
                format = input.ReadUInt16(); channels = input.ReadUInt16(); rate = input.ReadUInt32();
                input.ReadUInt32(); alignment = input.ReadUInt16(); bits = input.ReadUInt16();
                if (format == 0xFFFE && size >= 40)
                {
                    if (input.ReadUInt16() < 22) throw new InvalidDataException("Invalid extensible WAV format.");
                    input.ReadUInt16(); input.ReadUInt32();
                    var subtype = new Guid(input.ReadBytes(16));
                    format = subtype == new Guid("00000001-0000-0010-8000-00aa00389b71") ? (ushort)1 :
                        subtype == new Guid("00000003-0000-0010-8000-00aa00389b71") ? (ushort)3 : (ushort)0;
                }
            }
            else if (tag == "data") { dataStart = start; dataSize = size; }
            input.BaseStream.Position = start + size + (size & 1);
        }
        if (dataStart == 0 || channels is < 1 or > 8 || rate is < 8000 or > 192000 ||
            !((format == 1 && bits is 16 or 24 or 32) || (format == 3 && bits == 32)) || alignment != channels * bits / 8)
            throw new InvalidDataException("Supported WAV audio: 1–8 channels, PCM 16/24/32-bit or IEEE 32-bit float, 8–192 kHz.");
        if (dataSize % alignment != 0) throw new InvalidDataException("Incomplete audio frame.");
        var configuration = device.SoftwareConfiguration;
        if (channels != configuration.InputCount)
            throw new InvalidDataException($"This WAV has {channels} input channels; select a software mode or load a preset with that input count first (current: {configuration.InputCount}).");
        configuration.SampleRate = rate; configuration.InputCount = channels;
        int inputMask = (1 << channels) - 1;
        configuration.Leveller.DetectorMask &= inputMask; configuration.Leveller.ApplyMask &= inputMask;
        if (channels != 2 && configuration.Upmix.Enabled) throw new InvalidDataException("Turn off the stereo upmixer before processing a non-stereo WAV.");
        long frames = dataSize / alignment, outputBytes = frames * configuration.OutputCount * 4;
        if (outputBytes > uint.MaxValue - 36) throw new InvalidDataException("The processed WAV exceeds the RIFF 4 GB size limit.");
        device.BeginSoftwareFile(configuration);
        try
        {
        using var output = new BinaryWriter(File.Create(outputPath));
        void WriteTag(string tag) => output.Write(Encoding.ASCII.GetBytes(tag));
        WriteTag("RIFF"); output.Write((uint)(36 + outputBytes)); WriteTag("WAVE"); WriteTag("fmt ");
        output.Write(16u); output.Write((ushort)3); output.Write((ushort)configuration.OutputCount);
        output.Write(rate); output.Write(rate * (uint)configuration.OutputCount * 4); output.Write((ushort)(configuration.OutputCount * 4)); output.Write((ushort)32);
        WriteTag("data"); output.Write((uint)outputBytes); input.BaseStream.Position = dataStart;
        var source = new float[1024 * channels]; var destination = new float[1024 * configuration.OutputCount];
        while (frames > 0)
        {
            int count = (int)Math.Min(frames, 1024);
            for (int n = 0; n < count * channels; n++)
            {
                if (format == 3) source[n] = input.ReadSingle();
                else if (bits == 16) source[n] = input.ReadInt16() / 32768f;
                else if (bits == 32) source[n] = input.ReadInt32() / 2147483648f;
                else { int value = input.ReadByte() | input.ReadByte() << 8 | input.ReadSByte() << 16; source[n] = value / 8388608f; }
                if (!float.IsFinite(source[n])) throw new InvalidDataException("WAV contains non-finite samples.");
            }
            device.ProcessSoftwareAudio(source, destination, count);
            for (int n = 0; n < count * configuration.OutputCount; n++) output.Write(destination[n]);
            frames -= count;
        }
        }
        finally { device.EndSoftwareFile(); }
    }
}
