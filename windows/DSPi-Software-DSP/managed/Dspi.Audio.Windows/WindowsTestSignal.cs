using System.Numerics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Dspi.Audio.Windows;

public static class WindowsSpeakerLayout
{
    private static readonly string[] Speakers =
    [
        "Front Left", "Front Right", "Centre", "LFE", "Rear Left", "Rear Right",
        "Front Left of Centre", "Front Right of Centre", "Rear Centre",
        "Surround Left", "Surround Right", "Top Centre", "Top Front Left",
        "Top Front Centre", "Top Front Right", "Top Rear Left", "Top Rear Centre", "Top Rear Right"
    ];

    public static string[] GetLabels(WaveFormat format)
    {
        uint mask = 0;
        if (format is WaveFormatExtensible)
        {
            IntPtr native = WaveFormat.MarshalToPtr(format);
            try { mask = unchecked((uint)Marshal.ReadInt32(native, 20)); }
            finally { Marshal.FreeHGlobal(native); }
        }
        return GetLabels(format.Channels, mask);
    }

    public static string[] GetLabels(int channels, uint mask)
    {
        if (channels < 1 || channels > 8) throw new ArgumentOutOfRangeException(nameof(channels));
        if (mask != 0 && BitOperations.PopCount(mask) == channels)
        {
            return Enumerable.Range(0, 32).Where(index => (mask & (1u << index)) != 0)
                .Select(index => index < Speakers.Length ? Speakers[index] : $"Speaker {index + 1}").ToArray();
        }
        return channels switch
        {
            1 => ["Mono"],
            2 => ["Left", "Right"],
            _ => Enumerable.Range(1, channels).Select(index => $"Channel {index}").ToArray()
        };
    }
}

public enum WindowsSignal { Sine, PinkNoise, Sweep, ChannelCheck }

/// <summary>Finite, faded PCM matched to a Windows render endpoint.</summary>
public sealed class WindowsTestSignal : ISampleProvider
{
    private readonly SignalGenerator _source;
    private readonly int _selectedChannel;
    private readonly int _frames;
    private readonly int _framesPerChannel;
    private readonly int _fadeFrames;
    private readonly double _gain;
    private int _position;

    public WaveFormat WaveFormat { get; }

    public WindowsTestSignal(WaveFormat format, WindowsSignal signal, int selectedChannel, double levelDb)
    {
        if (format.Channels is < 1 or > 8 || format.SampleRate is < 8000 or > 192000)
            throw new ArgumentException("A supported Windows playback format is required.", nameof(format));
        if (selectedChannel < -1 || selectedChannel >= format.Channels)
            throw new ArgumentOutOfRangeException(nameof(selectedChannel));
        if (!double.IsFinite(levelDb) || levelDb is < -60 or > -20)
            throw new ArgumentOutOfRangeException(nameof(levelDb));

        WaveFormat = format;
        _selectedChannel = signal == WindowsSignal.ChannelCheck ? -1 : selectedChannel;
        _framesPerChannel = signal == WindowsSignal.ChannelCheck ? format.SampleRate : 0;
        int seconds = signal switch
        {
            WindowsSignal.Sweep => 8,
            WindowsSignal.ChannelCheck => format.Channels,
            _ => 5
        };
        _frames = seconds * format.SampleRate;
        _fadeFrames = format.SampleRate / 50;
        _gain = Math.Pow(10, levelDb / 20);
        _source = new SignalGenerator(format.SampleRate, 1)
        {
            Type = signal switch
            {
                WindowsSignal.Sine or WindowsSignal.ChannelCheck => SignalGeneratorType.Sin,
                WindowsSignal.PinkNoise => SignalGeneratorType.Pink,
                WindowsSignal.Sweep => SignalGeneratorType.Sweep,
                _ => throw new ArgumentOutOfRangeException(nameof(signal))
            },
            Gain = 1,
            Frequency = signal == WindowsSignal.Sweep ? 20 : 1000,
            FrequencyEnd = Math.Min(20000, format.SampleRate * 0.45),
            SweepLengthSecs = seconds
        };
    }

    private readonly float[] _scratch = new float[512];

    public int Read(float[] buffer, int offset, int count)
    {
        int channels = WaveFormat.Channels;
        int frames = Math.Min(count / channels, _frames - _position);
        for (int start = 0; start < frames; start += _scratch.Length)
        {
            int chunk = Math.Min(_scratch.Length, frames - start);
            int generated = _source.Read(_scratch, 0, chunk);
            for (int index = 0; index < generated; index++)
            {
                int frame = _position + start + index;
                int channel = _framesPerChannel > 0 ? frame / _framesPerChannel : _selectedChannel;
                int left = _framesPerChannel > 0 ? frame % _framesPerChannel : frame;
                int right = (_framesPerChannel > 0 ? _framesPerChannel : _frames) - left - 1;
                double envelope = Math.Min(1, (double)Math.Min(left, right) / _fadeFrames);
                float sample = (float)(_gain * envelope * Math.Clamp(_scratch[index], -1, 1));
                for (int output = 0; output < channels; output++)
                    buffer[offset + (start + index) * channels + output] = channel < 0 || channel == output ? sample : 0;
            }
        }
        _position += frames;
        return frames * channels;
    }
}

