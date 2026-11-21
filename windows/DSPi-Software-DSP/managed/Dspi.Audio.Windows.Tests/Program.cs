using System.Buffers.Binary;
using System.Runtime.InteropServices;
using Dspi.Audio.Windows;
using NAudio.Wave;

if (args.Contains("--list-devices"))
{
    using var inventory = new LiveAudioService();
    foreach (bool capture in new[] { true, false })
    {
        var devices = capture ? inventory.EnumerateCaptureDevices() : inventory.EnumerateRenderDevices();
        Console.WriteLine($"{(capture ? "Capture" : "Render")}: {devices.Count}");
        foreach (var d in devices) Console.WriteLine($"{d.Name} | {d.SampleRate} Hz | {d.Channels} channels | {d.Id}");
    }
    return;
}
int passed = 0;
void Check(bool ok, string name) { if (!ok) throw new Exception(name); passed++; Console.WriteLine("PASS " + name); }
void Decode(WaveFormat format, byte[] bytes, float expected, string name)
{
    float[] output = new float[1]; new PcmDecoder(format).Decode(bytes, output);
    Check(Math.Abs(output[0] - expected) < 0.000001, name);
}
Decode(new WaveFormat(48000, 16, 1), [0, 128], -1, "PCM16 negative full scale");
Decode(new WaveFormat(48000, 24, 1), [0, 0, 128], -1, "PCM24 sign extension");
Decode(new WaveFormat(48000, 32, 1), [0, 0, 0, 128], -1, "PCM32 negative full scale");
Decode(WaveFormat.CreateIeeeFloatWaveFormat(48000, 1), BitConverter.GetBytes(.25f), .25f, "float32");
Decode(new WaveFormatExtensible(48000, 24, 1), [0, 0, 64], .5f, "extensible PCM24");
// Build actual WAVEFORMATEXTENSIBLE PCM32 with 24 valid bits, left-aligned.
byte[] raw = new byte[40];
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(0), 0xfffe);
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(2), 1);
BinaryPrimitives.WriteInt32LittleEndian(raw.AsSpan(4), 48000);
BinaryPrimitives.WriteInt32LittleEndian(raw.AsSpan(8), 192000);
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(12), 4);
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(14), 32);
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(16), 22);
BinaryPrimitives.WriteUInt16LittleEndian(raw.AsSpan(18), 24);
new Guid("00000001-0000-0010-8000-00aa00389b71").ToByteArray().CopyTo(raw, 24);
IntPtr pointer = Marshal.AllocHGlobal(40);
try { Marshal.Copy(raw, 0, pointer, 40); Decode(WaveFormat.MarshalFromPtr(pointer), [255, 255, 255, 63], 8388607f / 16777216f, "extensible valid bits discard padding"); }
finally { Marshal.FreeHGlobal(pointer); }
try { _ = new PcmDecoder(new WaveFormat(48000, 8, 1)); Check(false, "reject PCM8"); }
catch (NotSupportedException) { Check(true, "reject PCM8"); }
try { new PcmDecoder(new WaveFormat(48000, 16, 2)).Decode(new byte[2], new float[2]); Check(false, "reject incomplete frame"); }
catch (ArgumentException) { Check(true, "reject incomplete frame"); }
_ = new PcmDecoder(new WaveFormat(192000, 24, 8));
Check(true, "accept supported boundary 192kHz and 8 channels");
foreach (var format in new[] { new WaveFormat(48000, 16, 9), new WaveFormat(384000, 16, 2) })
{
    try { _ = new PcmDecoder(format); Check(false, "reject unsupported live layout"); }
    catch (NotSupportedException e) { Check(e.Message.Contains("8–192 kHz, 1–8 channels"), $"reject {format.SampleRate} Hz / {format.Channels} channels with live limits"); }
}

var backend = new FakeBackend();
using var service = new LiveAudioService(backend);
Check(!service.IsRunning && backend.OpenCount == 0, "construction opens no audio");
var options = new LiveAudioStartOptions { CaptureDeviceId = "capture", RenderDeviceId = "render", DspOutputChannels = 2, OutputMap = [0, 1], DeviceBufferMilliseconds = 10 };
await service.StartAsync(options, (input, output, frames) => Array.Copy(input, output, frames * 2));
Check(service.IsRunning, "explicit start");
var old = backend.Last!;
old.Capture!(new byte[480 * 4], 480 * 4);
byte[] renderBytes = Enumerable.Repeat((byte)255, 480 * 8 + 3).ToArray();
Check(old.Provider!.Read(renderBytes, 0, renderBytes.Length) == renderBytes.Length, "render fills requested length including trailing bytes");
Check(renderBytes[^1] == 0 && renderBytes[^2] == 0, "trailing unaligned bytes silent");
await service.StopAsync();
Check(!service.IsRunning && old.Disposed && old.Stopped, "stop joins/disposes backend before returning");
await service.StartAsync(options, (input, output, frames) => Array.Clear(output));
old.Fault!(new IOException("stale"));
old.Capture!(new byte[4], 4);
Check(service.IsRunning, "old callbacks cannot stop new generation");
var faulted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
service.Error += (_, e) => { if (!service.IsRunning && backend.Last!.Disposed) faulted.TrySetResult(); };
backend.Last!.Fault!(new IOException("selected endpoint lost"));
await faulted.Task.WaitAsync(TimeSpan.FromSeconds(5));
Check(!service.IsRunning, "device loss closes exact session and reports fault after disposal");
backend.FailStart = true;
try { await service.StartAsync(options, (_, _, _) => { }); Check(false, "failed start"); }
catch (IOException) { Check(!service.IsRunning && backend.Last!.Disposed, "failed start cleans up"); }
backend.FailStart = false;
foreach (var format in new[] { new WaveFormat(48000, 16, 9), new WaveFormat(384000, 16, 2) })
{
    backend.CaptureFormat = format;
    try { await service.StartAsync(options, (_, _, _) => { }); Check(false, "reject unsupported endpoint before stream starts"); }
    catch (NotSupportedException) { Check(!service.IsRunning && backend.Last!.Disposed && !backend.Last.Started, "unsupported endpoint rejected before stream starts"); }
}
backend.CaptureFormat = new WaveFormat(44100, 16, 2);
foreach (var format in new[] { new WaveFormat(48000, 16, 9), new WaveFormat(384000, 16, 2) })
{
    backend.RenderFormat = format;
    try { await service.StartAsync(options, (_, _, _) => { }); Check(false, "reject unsupported render endpoint before stream starts"); }
    catch (NotSupportedException) { Check(!service.IsRunning && backend.Last!.Disposed && !backend.Last.Started, "unsupported render endpoint rejected before stream starts"); }
}
backend.RenderFormat = WaveFormat.CreateIeeeFloatWaveFormat(96000, 2);
foreach (var failure in new[] { "stop", "dispose", "both" })
{
    await service.StartAsync(options, (_, _, _) => { });
    var failed = backend.Last!;
    failed.FailStop = failure != "dispose"; failed.FailDispose = failure != "stop";
    try { await service.StopAsync().WaitAsync(TimeSpan.FromSeconds(5)); Check(false, "stop failure reported"); }
    catch (Exception e) when (e is IOException || e is AggregateException)
    {
        Check(!service.IsRunning && failed.Stopped && failed.Disposed, $"{failure} failure still attempts complete cleanup");
        if (failure == "both") Check(e is AggregateException { InnerExceptions.Count: 2 }, "both cleanup errors preserved");
    }
    await service.StartAsync(options, (_, _, _) => { }).WaitAsync(TimeSpan.FromSeconds(5));
    Check(service.IsRunning, $"restart after {failure} failure does not deadlock");
    await service.StopAsync().WaitAsync(TimeSpan.FromSeconds(5));
}
Console.WriteLine($"{passed} Windows audio checks passed. No physical capture or playback was started.");

sealed class FakeBackend : IAudioBackend
{
    public FakeSession? Last; public int OpenCount; public bool FailStart;
    public WaveFormat CaptureFormat = new(44100, 16, 2);
    public WaveFormat RenderFormat = WaveFormat.CreateIeeeFloatWaveFormat(96000, 2);
    public IReadOnlyList<AudioEndpointInfo> Enumerate(bool capture) => [];
    public IAudioSession Open(LiveAudioStartOptions options) { OpenCount++; return Last = new FakeSession { FailStart = FailStart, CaptureFormat = CaptureFormat, RenderFormat = RenderFormat }; }
}
sealed class FakeSession : IAudioSession
{
    public bool Disposed, Stopped, Started, FailStart, FailStop, FailDispose;
    public IWaveProvider? Provider; public Action<byte[], int>? Capture; public Action<Exception?>? Fault;
    public WaveFormat CaptureFormat { get; init; } = new(44100, 16, 2);
    public WaveFormat RenderFormat { get; init; } = WaveFormat.CreateIeeeFloatWaveFormat(96000, 2);
    public void Start(IWaveProvider provider, Action<byte[], int> capture, Action<Exception?> stopped)
    { Started = true; Provider = provider; Capture = capture; Fault = stopped; if (FailStart) throw new IOException("fake start failure"); }
    public void Stop() { Stopped = true; Fault?.Invoke(null); if (FailStop) throw new IOException("fake stop failure"); }
    public void Dispose() { Disposed = true; if (FailDispose) throw new IOException("fake dispose failure"); }
}
