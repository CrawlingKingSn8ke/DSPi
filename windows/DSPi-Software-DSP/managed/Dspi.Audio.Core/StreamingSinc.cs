namespace Dspi.Audio.Core;

/// <summary>Blackman-windowed sinc with interpolated 1024-phase table. At least
/// 64 taps, scaled by decimation ratio to preserve the transition band.
/// All storage/tables allocated at construction, never on the audio callback.</summary>
internal sealed class StreamingSinc
{
    const int Phases=1024;
    readonly int taps,left;
    readonly FrameRing source;readonly int channels;readonly double step;
    readonly float[] history,coefficients;
    int head;double phase;bool ready;
    public StreamingSinc(FrameRing source,int channels,int sourceRate,int destinationRate)
    {
        this.source=source;this.channels=channels;step=(double)sourceRate/destinationRate;
        taps=64*(int)Math.Ceiling(Math.Max(1,step));left=taps/2-1;
        history=new float[taps*channels];coefficients=new float[(Phases+1)*taps];
        // Slight transition guard also covers the small adaptive-rate excursion.
        double cutoff=.94*Math.Min(1,(double)destinationRate/sourceRate);
        for(int p=0;p<=Phases;p++){
            double sum=0;
            for(int t=0;t<taps;t++){
                double x=t-left-(double)p/Phases;
                double window=.42+.5*Math.Cos(Math.PI*x/(taps/2))+.08*Math.Cos(2*Math.PI*x/(taps/2));
                double v=Math.Abs(x)<1e-12?cutoff:Math.Sin(Math.PI*cutoff*x)/(Math.PI*x);
                coefficients[p*taps+t]=(float)(v*window);sum+=v*window;
            }
            for(int t=0;t<taps;t++)coefficients[p*taps+t]/=(float)sum;
        }
    }
    public int PrimingFrames => taps-left;
    public void Reset(){Array.Clear(history);head=0;phase=0;ready=false;}
    public bool ReadOne(float[] destination,int offset,double rateFactor=1)
    {
        if(!ready){
            if(source.Available<taps-left)return false;
            for(int t=left;t<taps;t++)source.ReadFrame(history,t*channels);
            ready=true;
        }
        double next=phase+step*rateFactor;int advance=(int)next;
        if(source.Available<advance)return false;
        double index=phase*Phases;int p=(int)index;float blend=(float)(index-p);
        for(int c=0;c<channels;c++){
            float sum=0;
            for(int t=0;t<taps;t++){
                float a=coefficients[p*taps+t],b=coefficients[(p+1)*taps+t];
                sum+=history[((head+t)%taps)*channels+c]*(a+(b-a)*blend);
            }
            destination[offset+c]=sum;
        }
        for(int t=0;t<advance;t++){source.ReadFrame(history,head*channels);head=(head+1)%taps;}
        phase=next-advance;return true;
    }
}
