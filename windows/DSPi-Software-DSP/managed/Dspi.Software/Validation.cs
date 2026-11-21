namespace Dspi.Software;

public sealed partial class EngineConfiguration
{
    public void Validate()
    {
        static void R(float n,float lo,float hi,string field) {if(!float.IsFinite(n)||n<lo||n>hi)throw new ArgumentException($"{field} must be finite and between {lo} and {hi}.");}
        static void Need(bool condition,string message) {if(!condition)throw new ArgumentException(message);}
        static void Finite(object? v) {if(v is null)throw new ArgumentException("Configuration blocks cannot be null.");if(v is float f){if(!float.IsFinite(f))throw new ArgumentException("Non-finite parameter.");return;}if(v is string||v.GetType().IsPrimitive)return;if(v is System.Collections.IEnumerable a){foreach(var x in a)Finite(x);return;}foreach(var p in v.GetType().GetProperties().Where(p=>p.CanRead))Finite(p.GetValue(v));}
        Finite(this);
        Need(SchemaVersion==CurrentSchemaVersion,"Unsupported schema version.");R(SampleRate,8000,192000,nameof(SampleRate));Need(InputCount is >=1 and <=8 && OutputCount is >=1 and <=8,"Topology must have 1–8 inputs and outputs.");R(VolumeDb,-60,0,nameof(VolumeDb));
        R(MasterVolumeDb,-128,12,nameof(MasterVolumeDb));
        Need(Inputs.Length==8&&Outputs.Length==8&&Routes.Length==64&&InputPairLinked.Length==4,"Configuration requires 8 input and output channel slots, 64 routes and 4 link slots.");
        for(int i=0;i<64;i++){var r=Routes[i];Need(r.Input==i/8&&r.Output==i%8,"Routes must contain exactly one crosspoint per input/output in row order.");R(r.GainDb,-120,12,"Route gain");Need(!r.Enabled||(r.Input<(Upmix.Enabled?5:InputCount)&&r.Output<OutputCount),"Enabled route references an unavailable channel.");}
        for(int i=0;i<8;i++) foreach(var input in new[]{true,false}) {
            var c=input?Inputs[i]:Outputs[i];R(c.GainDb,input?-60:-120,12,"Channel gain");R(c.DelayMs,0,170,"Delay");Need(c.Eq.Length==10&&c.Crossover.Length==4,"Each channel needs 10 EQ and 4 crossover slots.");
            if(input)Need(!c.Muted&&c.Enabled&&!c.Limiter.Enabled&&c.Crossover.All(b=>b.Bypass||b.Type==0),"Physical inputs support gain, delay and PEQ; input mute, disable, crossover and limiter are unsupported.");
            foreach(var b in c.Eq) {Need(b.Type is >=0 and <=13,"Unsupported EQ type.");R(b.FrequencyHz,float.Epsilon,SampleRate/2-.001f,"EQ frequency");R(b.Q,float.Epsilon,100,"EQ Q");R(b.TargetQ,0,20,"Target Q");if(b.Type==11){R(b.Gain,float.Epsilon,SampleRate/2-.001f,"LT target frequency");Need(b.TargetQ==0||b.TargetQ>=.1f,"LT target Q must be zero or at least 0.1.");}else R(b.Gain,-30,30,"EQ gain");}
            foreach(var b in c.Crossover){Need(b.Type==0||b.Type is >=32 and <=63,"Unsupported crossover type.");R(b.FrequencyHz,float.Epsilon,SampleRate/2-.001f,"Crossover frequency");}
            R(c.Limiter.ThresholdDb,-30,0,"Limiter threshold");R(c.Limiter.ReleaseMs,10,1000,"Limiter release");Need(c.Limiter.LinkGroup is >=0 and <=4,"Limiter link group must be 0–4.");
        }
        foreach(var group in Outputs.Take(OutputCount).Where(o=>o.Limiter.LinkGroup!=0).GroupBy(o=>o.Limiter.LinkGroup)) {
            var first=group.First().Limiter;
            Need(group.All(o=>o.Limiter.Enabled==first.Enabled&&o.Limiter.ThresholdDb==first.ThresholdDb&&o.Limiter.ReleaseMs==first.ReleaseMs),"Linked output limiters must have identical enabled, threshold and release settings.");
        }
        void Mask(int m,int max,string field)=>Need(m>=0&&(m&~max)==0,$"{field} references unavailable channels.");
        int om=(1<<OutputCount)-1,im=(1<<InputCount)-1;
        Mask(Loudness.OutputMask,om,"Loudness mask");R(Loudness.RefSpl,40,100,"Loudness reference");R(Loudness.IntensityPct,0,200,"Loudness intensity");Need(!Loudness.Enabled||SampleRate>12000,"Loudness requires sample rate above 12 kHz.");
        var x=Crossfeed;Mask(x.OutputPairMask,(1<<(OutputCount/2))-1,"Crossfeed mask");Need(x.Preset is >=0 and <=3,"Crossfeed preset invalid.");R(x.FreqHz,500,2000,"Crossfeed frequency");R(x.FeedDb,0,15,"Crossfeed feed");
        Need(!x.Enabled||x.OutputPairMask!=0,"Enabled crossfeed requires at least one complete output pair.");
        var p=Psybass;Mask(p.OutputMask,om,"Psybass mask");R(p.CutoffHz,30,300,"Psybass cutoff");R(p.HarmonicsDb,-24,12,"Psybass harmonics");R(p.DriveDb,0,18,"Psybass drive");R(p.CharacterPct,0,100,"Psybass character");R(p.OriginalDb,-60,0,"Psybass original");
        var s=Subharm;Mask(s.OutputMask,om,"Subharm mask");R(s.LowDb,-30,12,"Subharm low");R(s.HighDb,-30,12,"Subharm high");R(s.TopDb,-30,12,"Subharm top");R(s.BoostDb,0,6,"Subharm boost");Need(s.SelectMode is >=0 and <=2,"Subharm mode invalid.");R(s.SelectDepthPct,0,100,"Subharm depth");R(s.SelectHoldMs,50,400,"Subharm hold");R(s.CeilingDb,-40,0,"Subharm ceiling");
        var l=Leveller;Mask(l.DetectorMask,im,"Leveller detectors");Mask(l.ApplyMask,im,"Leveller apply");Need(l.Speed is >=0 and <=2,"Leveller speed invalid.");R(l.AmountPct,0,100,"Leveller amount");R(l.MaxGainDb,0,35,"Leveller gain");R(l.GateDb,-96,0,"Leveller gate");
        var t=Tube;Mask(t.OutputMask,om,"Tube mask");Need(t.TubeType is >=0 and <=16&&t.Rectifier is >=0 and <=3,"Tube style invalid.");R(t.DriveDb,-30,24,"Tube drive");R(t.BiasPct,-100,100,"Tube bias");R(t.AsymDb,-12,12,"Tube asymmetry");R(t.HardnessPct,0,100,"Tube hardness");R(t.SagPct,0,100,"Tube sag");R(t.XfmrDamping,1,20,"Tube damping");R(t.XfmrResHz,30,150,"Tube resonance");R(t.MixPct,0,100,"Tube mix");R(t.TrimDb,-12,12,"Tube trim");
        var u=Upmix;Need(u.CenterMode is >=0 and <=2&&u.SurroundMode is >=0 and <=2,"Upmix mode invalid.");Need(!u.Enabled||(InputCount==2&&SampleRate<=48000),"Upmix requires stereo at 48 kHz or below.");R(u.StrengthPct,0,100,"Upmix strength");R(u.CenterWidthPct,0,100,"Upmix width");R(u.ThresholdPct,0,95,"Upmix threshold");R(u.AttackMs,1,500,"Upmix attack");R(u.ReleaseMs,5,2000,"Upmix release");R(u.DetectorHpfHz,20,1000,"Upmix detector");R(u.SurroundDelayMs,0,20,"Upmix delay");R(u.SurroundHpfHz,20,2000,"Upmix HPF");R(u.SurroundLpfHz,1000,20000,"Upmix LPF");R(u.DecorrPct,0,100,"Upmix decorrelation");R(u.PresenceDb,-12,12,"Upmix presence");
    }
}
