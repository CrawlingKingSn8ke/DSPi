using System.Runtime.InteropServices;
using DSPiConsole.Core.Models;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace DSPiConsole;

/// <summary>Runs the measurement stream on a dedicated event-driven audio thread.</summary>
internal sealed class WasapiMeasurementPlayer(string endpointId, int rate, int channels, MeasurementSignal signal) : IDisposable
{
    private readonly ManualResetEvent _stop = new(false);
    private Thread? _thread;
    public event Action<Exception?>? Stopped;

    public void Play()
    {
        if (_thread != null) throw new InvalidOperationException("This measurement stream is already running.");
        _thread = new Thread(Render) { IsBackground = true, Name = "DSPi measurement audio", Priority = ThreadPriority.AboveNormal };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    private void Render()
    {
        Exception? error = null;
        IntPtr audioThread = IntPtr.Zero;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var endpoint = enumerator.GetDevice(endpointId);
            using var audio = endpoint.AudioClient;
            using var framesReady = new AutoResetEvent(false);
            var format = audio.MixFormat;
            if (format.SampleRate != rate || format.Channels != channels)
                throw new InvalidOperationException("The Windows playback format changed. Reconnect the output.");

            var flags = AudioClientStreamFlags.EventCallback;
            if (!IsFloat(format))
            {
                format = WaveFormat.CreateIeeeFloatWaveFormat(rate, channels);
                flags |= AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality;
            }
            const long requestedBuffer = 150 * 10000L;
            audio.Initialize(AudioClientShareMode.Shared, flags, requestedBuffer, 0, format, Guid.Empty);
            audio.SetEventHandle(framesReady.SafeWaitHandle.DangerousGetHandle());
            uint taskIndex = 0;
            audioThread = AvSetMmThreadCharacteristics("Audio", ref taskIndex);
            var render = audio.AudioRenderClient;
            int capacity = audio.BufferSize;
            var buffer = new float[capacity * channels];
            var handles = new WaitHandle[] { _stop, framesReady };

            bool ended = !Fill(render, buffer, capacity);
            if (ended || _stop.WaitOne(0)) return;
            audio.Start();
            try
            {
                while (WaitHandle.WaitAny(handles, 300) != 0)
                {
                    int padding = audio.CurrentPadding;
                    if (ended)
                    {
                        if (padding == 0) break;
                        continue;
                    }
                    if (padding < capacity) ended = !Fill(render, buffer, capacity - padding);
                }
            }
            finally { audio.Stop(); }
        }
        catch (Exception ex) { error = ex; }
        finally
        {
            if (audioThread != IntPtr.Zero) AvRevertMmThreadCharacteristics(audioThread);
            Stopped?.Invoke(error);
        }
    }

    private bool Fill(AudioRenderClient render, float[] buffer, int frames)
    {
        int count = signal.Read(buffer, 0, frames * channels);
        if (count == 0) return false;
        int written = count / channels;
        IntPtr destination = render.GetBuffer(written);
        try { Marshal.Copy(buffer, 0, destination, count); }
        finally { render.ReleaseBuffer(written, AudioClientBufferFlags.None); }
        return true;
    }

    private static bool IsFloat(WaveFormat format) => format.BitsPerSample == 32 &&
        (format.Encoding == WaveFormatEncoding.IeeeFloat || format is WaveFormatExtensible ext &&
         ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71"));

    public void Dispose()
    {
        _stop.Set();
        _thread?.Join();
        _stop.Dispose();
    }

    [DllImport("avrt.dll", CharSet = CharSet.Unicode, EntryPoint = "AvSetMmThreadCharacteristicsW")]
    private static extern IntPtr AvSetMmThreadCharacteristics(string taskName, ref uint taskIndex);

    [DllImport("avrt.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AvRevertMmThreadCharacteristics(IntPtr handle);
}

