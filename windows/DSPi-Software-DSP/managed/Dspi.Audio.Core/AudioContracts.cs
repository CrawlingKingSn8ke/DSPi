namespace Dspi.Audio.Core;

public delegate void AudioProcessCallback(float[] input,float[] output,int frames);
public sealed class LivePipelineOptions
{
    public int TargetBufferMilliseconds {get;set;}=60;
    public int CapacityMilliseconds {get;set;}=500;
    public double MaxDriftPpm {get;set;}=1500;
}
public sealed record LivePipelineStatistics(long CapturedFrames,long RenderedFrames,long UnderrunCount,long OverrunCount,long DroppedCaptureFrames,long InvalidSamples,double BufferedMilliseconds,double CorrectionPpm,bool Primed);
