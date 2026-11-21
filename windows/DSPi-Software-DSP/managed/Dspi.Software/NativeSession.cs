using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Dspi.Software;

public sealed record MeterSnapshot(float[] Inputs,float[] Outputs,uint Clips);
public sealed class NativeSession : IDisposable
{
    private readonly object updateGate=new();
    private readonly RuntimeHandle runtime;
    private EngineConfiguration current;
    public EngineConfiguration CurrentConfiguration {get {lock(updateGate)return current.Clone();}}
    public NativeSession(EngineConfiguration configuration)
    {
        current=configuration.Clone();current.Validate();
        using var graph=Prepare(current);
        runtime=Native.Create(graph,(uint)Math.Round(current.SampleRate*.01));
        if(runtime.IsInvalid){runtime.Dispose();throw new InvalidOperationException("Native runtime creation failed.");}
        graph.SetHandleAsInvalid();
    }
    private static GraphHandle Prepare(EngineConfiguration c)
    {
        var graph=Native.Prepare(c.SampleRate,(uint)c.InputCount,(uint)c.OutputCount,c.ToRecipe());
        if(graph.IsInvalid){graph.Dispose();throw new ArgumentException("Native DSP rejected the configuration.");}return graph;
    }
    public void Apply(EngineConfiguration configuration)
    {
        var next=configuration.Clone();next.Validate();
        lock(updateGate) {
            ObjectDisposedException.ThrowIf(runtime.IsClosed,this);
            if(next.SampleRate!=current.SampleRate||next.InputCount!=current.InputCount||next.OutputCount!=current.OutputCount)throw new ArgumentException("Live changes must retain the sample rate and channel topology.");
            if(next.ToRecipe()==current.ToRecipe()){current=next;return;}
            using var graph=Prepare(next);
            if(Native.Submit(runtime,graph)!=1)throw new InvalidOperationException("DSP transition is busy or rejected; the current configuration was retained.");
            graph.SetHandleAsInvalid();current=next;
        }
    }
    // One audio thread owns Process. Configuration construction never holds its lock.
    public void Process(float[] input,float[] output,int frames)
    {
        ArgumentNullException.ThrowIfNull(input);ArgumentNullException.ThrowIfNull(output);
        if(frames<0||input.Length<(long)frames*current.InputCount||output.Length<(long)frames*current.OutputCount||ReferenceEquals(input,output))throw new ArgumentException("Separate interleaved buffers must contain all requested frames.");
        if(Native.Process(runtime,input,output,(uint)frames)!=1)throw new InvalidOperationException("DSP processing failed.");
    }
    public MeterSnapshot ReadMeters(){lock(updateGate){var i=new float[8];var o=new float[8];Native.Collect(runtime);Native.Meters(runtime,i,o,out var clips);return new(i,o,clips);}}
    public void Dispose(){lock(updateGate)runtime.Dispose();}
}
internal sealed class GraphHandle:SafeHandleZeroOrMinusOneIsInvalid {public GraphHandle():base(true){} protected override bool ReleaseHandle(){Native.GraphDestroy(handle);return true;}}
internal sealed class RuntimeHandle:SafeHandleZeroOrMinusOneIsInvalid {public RuntimeHandle():base(true){} protected override bool ReleaseHandle(){Native.Destroy(handle);return true;}}
internal static class Native
{
    const string Library="dspi-host";
    [DllImport(Library,EntryPoint="dspi_host_prepare",CallingConvention=CallingConvention.Cdecl)] internal static extern GraphHandle Prepare(float rate,uint inputs,uint outputs,[MarshalAs(UnmanagedType.LPUTF8Str)]string tokens);
    [DllImport(Library,EntryPoint="dspi_host_graph_destroy",CallingConvention=CallingConvention.Cdecl)] internal static extern void GraphDestroy(IntPtr graph);
    [DllImport(Library,EntryPoint="dspi_host_create",CallingConvention=CallingConvention.Cdecl)] internal static extern RuntimeHandle Create(GraphHandle graph,uint rampSamples);
    [DllImport(Library,EntryPoint="dspi_host_submit",CallingConvention=CallingConvention.Cdecl)] internal static extern int Submit(RuntimeHandle runtime,GraphHandle graph);
    [DllImport(Library,EntryPoint="dspi_host_collect",CallingConvention=CallingConvention.Cdecl)] internal static extern void Collect(RuntimeHandle runtime);
    [DllImport(Library,EntryPoint="dspi_host_process",CallingConvention=CallingConvention.Cdecl)] internal static extern int Process(RuntimeHandle runtime,[In]float[] input,[Out]float[] output,uint frames);
    [DllImport(Library,EntryPoint="dspi_host_meters",CallingConvention=CallingConvention.Cdecl)] internal static extern void Meters(RuntimeHandle runtime,[Out]float[] inputs,[Out]float[] outputs,out uint clips);
    [DllImport(Library,EntryPoint="dspi_host_destroy",CallingConvention=CallingConvention.Cdecl)] internal static extern void Destroy(IntPtr runtime);
}
