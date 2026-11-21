namespace Dspi.Audio.Core;

/// <summary>One capture producer, one audio consumer. Whole frames are published
/// only after their samples have been copied. Producer never moves read cursor.</summary>
internal sealed class FrameRing
{
    readonly float[] samples;readonly int channels,capacity;
    long read,write;
    public FrameRing(int frames,int channels){capacity=frames;this.channels=channels;samples=new float[checked(frames*channels)];}
    // A third-party meter reader can observe cursor snapshots from different
    // instants. Bound that approximate diagnostic count to the actual capacity.
    public int Available => (int)Math.Clamp(Volatile.Read(ref write)-Volatile.Read(ref read),0,capacity);
    public bool Write(float[] source,int offset,int frames,out long invalid)
    {
        invalid=0;long w=write;
        if(frames>capacity-(w-Volatile.Read(ref read)))return false;
        for(int f=0;f<frames;f++){
            int p=(int)((w+f)%capacity)*channels;
            for(int c=0;c<channels;c++){float v=source[offset+f*channels+c];if(!float.IsFinite(v)){v=0;invalid++;}samples[p+c]=v;}
        }
        Volatile.Write(ref write,w+frames);return true;
    }
    public bool ReadFrame(float[] destination,int offset)
    {
        long r=read;if(r>=Volatile.Read(ref write))return false;
        int p=(int)(r%capacity)*channels;
        for(int c=0;c<channels;c++)destination[offset+c]=samples[p+c];
        Volatile.Write(ref read,r+1);return true;
    }
    public int DiscardAll(){long w=Volatile.Read(ref write),r=read;Volatile.Write(ref read,w);return (int)(w-r);}
}
