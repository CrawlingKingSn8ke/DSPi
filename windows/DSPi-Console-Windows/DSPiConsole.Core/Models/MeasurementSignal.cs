namespace DSPiConsole.Core.Models;

/// <summary>Frame-accurate shared-mode measurement signals. The render thread owns synthesis state.</summary>
public sealed class MeasurementSignal
{
    private const double Turn = Math.PI * 2;
    private readonly SiggenConfig _config;
    private readonly int _rate, _channels, _fade;
    private readonly int[] _selected;
    private readonly bool _walk, _continuous, _sweep;
    private readonly long _period, _gap, _total;
    private readonly float _gain;
    private readonly double _f1, _f2;
    private readonly uint[] _random;
    private readonly double[,] _pink = new double[8, 7];
    private readonly double[] _tones;
    private long _frame, _stopFrame = long.MaxValue;
    private double _phase, _phase2;
    private float _frequency;
    private int _active = 255;
    private int _stopRequested;
    private long _lastCycle = -1;

    public MeasurementSignal(int rate, int channels, SiggenConfig configuration)
    {
        if (rate is < 8000 or > 192000 || channels is < 1 or > 8)
            throw new ArgumentOutOfRangeException(nameof(rate));
        _config = configuration.Clone();
        if (!Enum.IsDefined(_config.SignalType) || !float.IsFinite(_config.LevelDb) ||
            _config.LevelDb is < -80 or > -20 || Enumerable.Range(0, 4).Any(i => !float.IsFinite(_config.GetParam(i))))
            throw new ArgumentException("Use a valid test signal at a level between −80 and −20 dBFS.", nameof(configuration));
        _selected = Enumerable.Range(0, channels).Where(i => (_config.ChannelMask & (1 << i)) != 0).ToArray();
        if (_selected.Length == 0) throw new ArgumentException("Select at least one output.", nameof(configuration));
        _rate = rate;
        _channels = channels;
        _fade = rate / 50;
        _gain = (float)Math.Pow(10, _config.LevelDb / 20);
        _random = Enumerable.Range(0, channels).Select(i => 0x633d4f15u + (uint)i * 112361u).ToArray();
        _f1 = Frequency(_config.P1);
        _f2 = Frequency(_config.P2);
        _walk = _config.SignalType == SiggenType.ChannelId || (_config.Flags & SiggenFlags.Walk) != 0;
        _sweep = _config.SignalType is SiggenType.SweepLog or SiggenType.SweepLin or SiggenType.SweepStep;
        _continuous = !_sweep && _config.SignalType is not
            (SiggenType.Impulse or SiggenType.ClicksAlt or SiggenType.Polarity or SiggenType.ToneBurst or SiggenType.ChannelId);
        _period = _config.SignalType switch
        {
            SiggenType.SweepLog or SiggenType.SweepLin or SiggenType.SweepStep => Frames(Math.Max(10, _config.DurationMs)),
            SiggenType.Impulse or SiggenType.ClicksAlt => Frames(Math.Clamp(_config.P1, 10, 60000)),
            SiggenType.Polarity => Frames(Math.Clamp(Math.Max(_config.P2, _config.P1), 10, 60000)),
            SiggenType.ToneBurst => Math.Max(1, (long)(rate * (Math.Clamp(_config.P2, 1, 1000) + Math.Clamp(_config.P3, 0, 1000)) / _f1)),
            SiggenType.ChannelId => Frames(Math.Clamp(_config.P1, 30, 1000) * 2 * (_selected.Max() + 1)),
            _ => _config.DurationMs > 0 ? Frames(_config.DurationMs) : _walk ? Frames(2000) : long.MaxValue,
        };
        _gap = _continuous ? 0 : (long)_config.GapMs * rate / 1000;
        _total = _continuous && !_walk ? _period :
            _config.Repeat == 0 ? long.MaxValue : (_period + _gap) * _config.Repeat * (_walk ? _selected.Length : 1) - _gap;
        _tones = _config.SignalType == SiggenType.Multitone
            ? Enumerable.Range(0, (int)Math.Clamp(_config.P1, 2, 16))
                .Select(i => Frequency(_config.P2) * Math.Pow(Frequency(_config.P3) / Frequency(_config.P2),
                    i / (Math.Clamp(_config.P1, 2, 16) - 1))).ToArray()
            : [];
    }

    public void FadeOut() => Interlocked.Exchange(ref _stopRequested, 1);

    public SiggenStatus GetStatus()
    {
        long position = Interlocked.Read(ref _frame);
        return new SiggenStatus
        {
            State = Volatile.Read(ref _stopRequested) != 0 ? SiggenState.FadeOut : SiggenState.Run,
            SignalType = _config.SignalType,
            ActiveChannel = (byte)Volatile.Read(ref _active),
            CurrentFreq = Volatile.Read(ref _frequency),
            ElapsedMs = (uint)Math.Min(uint.MaxValue, position * 1000.0 / _rate),
            CyclesDone = (ushort)Math.Min(ushort.MaxValue, Math.Max(0, Volatile.Read(ref _lastCycle))),
        };
    }

    public int Read(float[] destination, int offset, int count)
    {
        long frame = _frame;
        int written = 0;
        for (; written < count / _channels && frame < _total && frame < _stopFrame; written++, frame++)
        {
            if (Volatile.Read(ref _stopRequested) != 0 && _stopFrame == long.MaxValue)
                _stopFrame = frame + _fade;
            long cycle = frame / (_period + _gap);
            long position = frame % (_period + _gap);
            int active = _walk ? _selected[(int)(cycle % _selected.Length)] : 255;
            if (cycle != _lastCycle) { _phase = _phase2 = 0; Volatile.Write(ref _lastCycle, cycle); }
            Volatile.Write(ref _active, active);
            int start = offset + written * _channels;
            Array.Clear(destination, start, _channels);
            if (position >= _period) continue;

            float gain = _gain;
            gain *= Math.Min(1, Math.Min(_total - frame - 1, _stopFrame - frame - 1) / (float)_fade);
            // Preserve the leading sample of deliberate click and impulse tests.
            if (_config.SignalType is not (SiggenType.Impulse or SiggenType.ClicksAlt or SiggenType.Isp))
                gain *= Math.Min(1, position / (float)_fade);
            if (_walk || _sweep)
                gain *= Math.Min(1, (_period - position - 1) / (float)_fade);

            bool separateNoise = (_config.Flags & SiggenFlags.Decorrelate) != 0 &&
                _config.SignalType is SiggenType.White or SiggenType.Pink;
            float shared = separateNoise ? 0 : Sample(position, cycle, active, 0);
            foreach (int channel in _selected)
            {
                if (active != 255 && active != channel) continue;
                float value = separateNoise ? Sample(position, cycle, active, channel) : shared;
                destination[start + channel] = Math.Clamp(value, -1, 1) * gain *
                    ((_config.InvertMask & (1 << channel)) != 0 ? -1 : 1);
            }
        }
        Interlocked.Exchange(ref _frame, frame);
        return written * _channels;
    }

    private long Frames(double milliseconds) => Math.Max(1, (long)(milliseconds * _rate / 1000));
    private double Frequency(double value) => Math.Clamp(value, 1, _rate * .45);

    private float Noise(int channel, bool pink)
    {
        uint value = _random[channel];
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        _random[channel] = value;
        double white = value / (double)uint.MaxValue * 2 - 1;
        if (!pink) return (float)white;
        _pink[channel,0] = 0.99886 * _pink[channel,0] + white * 0.0555179;
        _pink[channel,1] = 0.99332 * _pink[channel,1] + white * 0.0750759;
        _pink[channel,2] = 0.96900 * _pink[channel,2] + white * 0.1538520;
        _pink[channel,3] = 0.86650 * _pink[channel,3] + white * 0.3104856;
        _pink[channel,4] = 0.55000 * _pink[channel,4] + white * 0.5329522;
        _pink[channel,5] = -0.7616 * _pink[channel,5] - white * 0.0168980;
        double outValue = white * 0.5362;
        for (int i = 0; i < 7; i++) outValue += _pink[channel,i];
        _pink[channel,6] = white * 0.115926;
        return (float)(0.18 * outValue);
    }

    private float Sample(long p, long cycle, int active, int channel)
    {
        double hz = _f1;
        switch (_config.SignalType)
        {
            case SiggenType.White:
            case SiggenType.Pink:
                return Noise(channel, _config.SignalType == SiggenType.Pink);
            case SiggenType.Impulse:
                return p == 0 ? 1 : 0;
            case SiggenType.ClicksAlt:
                return p == 0 ? (cycle % 2 == 0 ? 1 : -1) : 0;
            case SiggenType.Polarity:
                long width = Frames(Math.Clamp(_config.P1, 1, 100));
                return p < width ? (float)Math.Sin(Math.PI * p / width) : 0;
            case SiggenType.ChannelId:
                long blip = Frames(Math.Clamp(_config.P1, 30, 1000));
                if (p / (blip * 2) > active || p % (blip * 2) >= blip) return 0;
                long local = p % (blip * 2);
                return (float)(Math.Sin(Turn * 440 * Math.Pow(2, active / 5.0) * local / _rate)
                    * Math.Sin(Math.PI * local / blip));
            case SiggenType.Isp:
                return (int)_config.P1 == 0 ? (p % 4 < 2 ? 1 : -1)
                    : (p % 6) switch { 0 or 1 => 1, 3 or 4 => -1, _ => 0 };
            case SiggenType.Multitone:
                double sum = 0;
                for (int i = 0; i < _tones.Length; i++)
                    sum += Math.Sin(Turn * _tones[i] * p / _rate + Math.PI * i * (i - 1) / _tones.Length);
                return (float)(sum / _tones.Length);
            case SiggenType.SweepLog:
                hz = _f1 * Math.Pow(_f2 / _f1, (double)p / _period);
                break;
            case SiggenType.SweepLin:
                hz = _f1 + (_f2 - _f1) * p / _period;
                break;
            case SiggenType.SweepStep:
                double step = p / Frames(Math.Clamp(_config.P4, 20, 10000)) / Math.Clamp(_config.P3, 1, 24);
                hz = _f1 <= _f2 ? Math.Min(_f2, _f1 * Math.Pow(2, step)) : Math.Max(_f2, _f1 * Math.Pow(2, -step));
                break;
        }

        Volatile.Write(ref _frequency, (float)hz);
        double sample = Math.Sin(Turn * _phase);
        if (_config.SignalType == SiggenType.Square)
        {
            double delta = hz / _rate;
            sample = (_phase < .5 ? 1 : -1) + PolyBlep(_phase, delta) - PolyBlep((_phase + .5) % 1, delta);
        }
        if (_config.SignalType == SiggenType.TonePair)
        {
            double ratio = Math.Clamp(_config.P3, .1, 10);
            sample = (ratio * sample + Math.Sin(Turn * _phase2)) / (1 + ratio);
            _phase2 = (_phase2 + _f2 / _rate) % 1;
        }
        if (_config.SignalType == SiggenType.ToneBurst)
        {
            double on = Math.Clamp(_config.P2, 1, 1000) * _rate / _f1;
            double edge = Math.Clamp(_config.P4, 0, 100) * _rate / _f1;
            if (p >= on) sample = 0;
            else if (edge > 0) sample *= .5 - .5 * Math.Cos(Math.PI * Math.Min(1, Math.Min(p, on - p) / edge));
        }
        _phase = (_phase + hz / _rate) % 1;
        return (float)sample;
    }

    private static double PolyBlep(double phase, double delta)
    {
        if (phase < delta) { double x = phase / delta; return 2 * x - x * x - 1; }
        if (phase > 1 - delta) { double x = (phase - 1) / delta; return x * x + 2 * x + 1; }
        return 0;
    }
}

