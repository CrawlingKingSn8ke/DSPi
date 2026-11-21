namespace Dspi.Audio.Core;

/// <summary>Capture producer -> bounded FIFO -> adaptive SRC -> DSP -> explicit
/// channel map -> output SRC. One render consumer. No locks or callback allocations.</summary>
public sealed class AdaptiveAudioPipeline
{
    const int Block=256;
    readonly FrameRing capture,mapped;
    readonly StreamingSinc inputConverter,outputConverter;
    readonly int inputChannels,dspOutputs,renderChannels,captureRate,engineRate,targetFrames,fadeFrames;
    readonly int[] map;readonly AudioProcessCallback process;
    readonly float[] engineInput,engineOutput,mappedBlock,last;
    readonly double maxCorrection;
    long capturedFrames,renderedFrames,underruns,overruns,dropped,invalid,overflowVersion,seenOverflow;
    double correction,filteredFill,integral;
    bool primed;int fadeIn,fadeOut,stopRequested,stopComplete;
    public AdaptiveAudioPipeline(int captureRate,int inputChannels,int engineRate,int dspOutputs,int renderRate,int renderChannels,int[] outputMap,AudioProcessCallback process,LivePipelineOptions? options=null)
    {
        static void Rate(int value){if(value is <8000 or >192000)throw new ArgumentOutOfRangeException(nameof(value));}
        Rate(captureRate);Rate(engineRate);Rate(renderRate);
        if(inputChannels is <1 or >8||dspOutputs is <1 or >8||renderChannels is <1 or >8)throw new ArgumentOutOfRangeException(nameof(inputChannels));
        ArgumentNullException.ThrowIfNull(process);ArgumentNullException.ThrowIfNull(outputMap);
        if(outputMap.Length!=renderChannels||outputMap.Any(c=>c< -1||c>=dspOutputs))throw new ArgumentException("Every soundcard channel must map to an available DSP output or silence.");
        options??=new();
        if(options.TargetBufferMilliseconds is <20 or >200||options.CapacityMilliseconds is <60 or >2000||options.CapacityMilliseconds<options.TargetBufferMilliseconds*2||!double.IsFinite(options.MaxDriftPpm)||options.MaxDriftPpm<0||options.MaxDriftPpm>3000)throw new ArgumentException("Invalid bounded-buffer/drift options.");
        this.captureRate=captureRate;this.inputChannels=inputChannels;this.engineRate=engineRate;this.dspOutputs=dspOutputs;this.renderChannels=renderChannels;this.process=process;
        map=(int[])outputMap.Clone();maxCorrection=options.MaxDriftPpm/1e6;targetFrames=(int)Math.Ceiling(captureRate*options.TargetBufferMilliseconds/1000.0);fadeFrames=Math.Max(1,renderRate/100);
        capture=new FrameRing((int)Math.Ceiling(captureRate*options.CapacityMilliseconds/1000.0),inputChannels);
        mapped=new FrameRing(4096,renderChannels);
        inputConverter=new(capture,inputChannels,captureRate,engineRate);outputConverter=new(mapped,renderChannels,engineRate,renderRate);
        engineInput=new float[Block*inputChannels];engineOutput=new float[Block*dspOutputs];mappedBlock=new float[Block*renderChannels];last=new float[renderChannels];
        filteredFill=targetFrames;
    }
    public LivePipelineStatistics Statistics => new(Interlocked.Read(ref capturedFrames),Interlocked.Read(ref renderedFrames),Interlocked.Read(ref underruns),Interlocked.Read(ref overruns),Interlocked.Read(ref dropped),Interlocked.Read(ref invalid),capture.Available*1000.0/captureRate,Volatile.Read(ref correction)*1e6,Volatile.Read(ref primed));
    public bool StopFadeCompleted => Volatile.Read(ref stopComplete)!=0;
    public void RequestStop()=>Interlocked.Exchange(ref stopRequested,1);
    public void PushCapture(float[] samples,int offset,int frames)
    {
        ArgumentNullException.ThrowIfNull(samples);if(offset<0||frames<0||(long)offset+(long)frames*inputChannels>samples.Length)throw new ArgumentOutOfRangeException(nameof(frames));
        if(Volatile.Read(ref stopRequested)!=0)return;
        Interlocked.Add(ref capturedFrames,frames);
        if(!capture.Write(samples,offset,frames,out long bad)){Interlocked.Add(ref dropped,frames);Interlocked.Increment(ref overruns);Interlocked.Increment(ref overflowVersion);}
        else if(bad!=0)Interlocked.Add(ref invalid,bad);
    }
    void ResetConsumer(bool fade)
    {
        Volatile.Write(ref primed,false);fadeIn=0;fadeOut=fade?fadeFrames:0;
        Interlocked.Add(ref dropped,capture.DiscardAll());mapped.DiscardAll();inputConverter.Reset();outputConverter.Reset();correction=0;integral=0;filteredFill=targetFrames;
    }
    bool Produce()
    {
        // Low-pass occupancy removes callback packet-size jitter. The integral
        // corrects independent device clocks; slew keeps pitch changes gradual.
        filteredFill+=.015*(capture.Available-filteredFill);
        double error=(filteredFill-targetFrames)/Math.Max(1,targetFrames);
        double dt=(double)Block/engineRate;
        integral=Math.Clamp(integral+error*dt*.0002,-maxCorrection,maxCorrection);
        double wanted=Math.Clamp(error*.001+integral,-maxCorrection,maxCorrection);
        correction+=Math.Clamp(wanted-correction,-.000002,.000002);
        int frames=0;while(frames<Block&&inputConverter.ReadOne(engineInput,frames*inputChannels,1+correction))frames++;
        if(frames==0)return false;
        process(engineInput,engineOutput,frames);
        for(int f=0;f<frames;f++)for(int c=0;c<renderChannels;c++){
            float v=map[c]<0?0:engineOutput[f*dspOutputs+map[c]];
            if(!float.IsFinite(v))throw new InvalidOperationException("DSP returned non-finite live audio.");
            mappedBlock[f*renderChannels+c]=v;
        }
        if(!mapped.Write(mappedBlock,0,frames,out _))throw new InvalidOperationException("Internal output SRC buffer overflow.");
        return true;
    }
    public void Render(float[] destination,int offset,int frames)
    {
        ArgumentNullException.ThrowIfNull(destination);if(offset<0||frames<0||(long)offset+(long)frames*renderChannels>destination.Length)throw new ArgumentOutOfRangeException(nameof(frames));
        long version=Interlocked.Read(ref overflowVersion);
        if(version!=seenOverflow){seenOverflow=version;ResetConsumer(primed);}
        if(Volatile.Read(ref stopRequested)!=0&&Volatile.Read(ref stopComplete)==0&&primed)ResetConsumer(true);
        for(int f=0;f<frames;f++){
            int p=offset+f*renderChannels;
            if(!primed&&fadeOut==0&&Volatile.Read(ref stopRequested)==0&&capture.Available>=targetFrames+inputConverter.PrimingFrames){Volatile.Write(ref primed,true);fadeIn=fadeFrames;}
            bool valid=false;
            if(primed){
                while(!(valid=outputConverter.ReadOne(destination,p))){if(!Produce())break;}
                if(!valid){Interlocked.Increment(ref underruns);ResetConsumer(true);}
            }
            if(valid){
                float gain=fadeIn>0?(float)(fadeFrames-fadeIn--)/fadeFrames:1;
                for(int c=0;c<renderChannels;c++)last[c]=destination[p+c]*=gain;
            }else{
                float gain=fadeOut>0?(float)fadeOut--/fadeFrames:0;
                for(int c=0;c<renderChannels;c++)destination[p+c]=last[c]*gain;
            }
            if(Volatile.Read(ref stopRequested)!=0&&!primed&&fadeOut==0)Volatile.Write(ref stopComplete,1);
        }
        Interlocked.Add(ref renderedFrames,frames);
    }
}
