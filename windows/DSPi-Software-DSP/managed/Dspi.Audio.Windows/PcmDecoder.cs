using System.Buffers.Binary;
using NAudio.Wave;

namespace Dspi.Audio.Windows;

/// <summary>Interleaved little-endian PCM, including left-aligned extensible valid bits.</summary>
internal sealed class PcmDecoder
{
    private readonly int bytes, validBits;
    private readonly bool floating;
    public int Channels { get; }
    public int BlockAlign => bytes * Channels;
    public PcmDecoder(WaveFormat format)
    {
        Channels = format.Channels;
        bytes = format.BitsPerSample / 8;
        validBits = format.BitsPerSample;
        var encoding = format.Encoding;
        if (format is WaveFormatExtensible ext)
        {
            var sub = ext.SubFormat;
            encoding = sub == new Guid("00000001-0000-0010-8000-00aa00389b71") ? WaveFormatEncoding.Pcm :
                sub == new Guid("00000003-0000-0010-8000-00aa00389b71") ? WaveFormatEncoding.IeeeFloat : WaveFormatEncoding.Unknown;
            // NAudio 2.2.1 has no public valid-bits getter; Serialize preserves WAVEFORMATEXTENSIBLE.
            using var stream = new MemoryStream();
            using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, true)) ext.Serialize(writer);
            // NAudio serializes a four-byte size prefix before the 18-byte WAVEFORMATEX.
            validBits = BinaryPrimitives.ReadUInt16LittleEndian(stream.ToArray().AsSpan(22, 2));
        }
        floating = encoding == WaveFormatEncoding.IeeeFloat;
        if (format.SampleRate < 8000 || format.SampleRate > 192000 || Channels < 1 || Channels > 8 ||
            format.BitsPerSample != bytes * 8 || format.BlockAlign != bytes * Channels || validBits < 1 || validBits > format.BitsPerSample ||
            !(floating && bytes == 4 && validBits == 32 || encoding == WaveFormatEncoding.Pcm && (bytes == 2 || bytes == 3 || bytes == 4)))
            throw new NotSupportedException($"Unsupported live audio format: {format}. Use PCM 16/24/32-bit or float32, 8–192 kHz, 1–8 channels.");
    }
    public void Decode(ReadOnlySpan<byte> source, Span<float> destination)
    {
        if (source.Length % BlockAlign != 0 || destination.Length < source.Length / bytes) throw new ArgumentException("Audio data must contain complete frames.");
        int shift = bytes * 8 - validBits;
        double scale = Math.Pow(2, validBits - 1);
        for (int i = 0, p = 0; p < source.Length; i++, p += bytes)
        {
            if (floating) destination[i] = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(source.Slice(p, 4)));
            else
            {
                int value = bytes == 2 ? BinaryPrimitives.ReadInt16LittleEndian(source.Slice(p, 2)) : bytes == 4 ?
                    BinaryPrimitives.ReadInt32LittleEndian(source.Slice(p, 4)) : (source[p] | source[p + 1] << 8 | source[p + 2] << 16) << 8 >> 8;
                destination[i] = (float)((value >> shift) / scale);
            }
        }
    }
}
