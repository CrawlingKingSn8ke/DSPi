using System.Globalization;
using System.Text.Json;

namespace Dspi.Software;

public sealed class FilterConfiguration
{
    public int Type { get; set; }
    public float FrequencyHz { get; set; } = 1000;
    public float Q { get; set; } = .707f;
    public float Gain { get; set; }
    public float TargetQ { get; set; } = .707f;
    public bool Bypass { get; set; }
}
public sealed class LimiterConfiguration { public bool Enabled { get; set; } public float ThresholdDb { get; set; } = -1; public float ReleaseMs { get; set; } = 100; public int LinkGroup { get; set; } }
public sealed class ChannelConfiguration
{
    public string Name { get; set; } = "";
    public float GainDb { get; set; }
    public float DelayMs { get; set; }
    public bool Muted { get; set; }
    public bool Enabled { get; set; } = true;
    public bool Bypass { get; set; }
    public FilterConfiguration[] Eq { get; set; } = Enumerable.Range(0,10).Select(_=>new FilterConfiguration()).ToArray();
    public FilterConfiguration[] Crossover { get; set; } = Enumerable.Range(0,4).Select(_=>new FilterConfiguration { Type=32, Bypass=true }).ToArray();
    public LimiterConfiguration Limiter { get; set; } = new();
}
public sealed class RouteConfiguration { public int Input { get; set; } public int Output { get; set; } public bool Enabled { get; set; } public bool Invert { get; set; } public float GainDb { get; set; } }
public sealed class LoudnessConfiguration { public bool Enabled { get; set; } public float RefSpl { get; set; } = 83; public float IntensityPct { get; set; } = 100; public int OutputMask { get; set; } = 3; }
public sealed class CrossfeedConfiguration { public bool Enabled { get; set; } public int Preset { get; set; } public float FreqHz { get; set; } = 700; public float FeedDb { get; set; } = 4.5f; public bool Itd { get; set; } = true; public int OutputPairMask { get; set; } = 1; }
public sealed class LevellerConfiguration { public bool Enabled { get; set; } public int Speed { get; set; } public bool Lookahead { get; set; } = true; public float AmountPct { get; set; } = 50; public float MaxGainDb { get; set; } = 15; public float GateDb { get; set; } = -96; public int DetectorMask { get; set; } = 3; public int ApplyMask { get; set; } = 3; }
public sealed class PsybassConfiguration { public bool Enabled { get; set; } public float CutoffHz { get; set; } = 80; public float HarmonicsDb { get; set; } public float DriveDb { get; set; } = 6; public float CharacterPct { get; set; } = 50; public float OriginalDb { get; set; } public int OutputMask { get; set; } = 3; }
public sealed class SubharmConfiguration { public bool Enabled { get; set; } public float LowDb { get; set; } public float HighDb { get; set; } public float TopDb { get; set; } = -30; public float BoostDb { get; set; } public int OutputMask { get; set; } = 3; public int SelectMode { get; set; } public float SelectDepthPct { get; set; } = 100; public float SelectHoldMs { get; set; } = 150; public float CeilingDb { get; set; } public bool LinkPairs { get; set; } = true; public bool Solo { get; set; } }
public sealed class TubeConfiguration { public bool Enabled { get; set; } public int OutputMask { get; set; } = 3; public int TubeType { get; set; } = 1; public float DriveDb { get; set; } = -12; public float BiasPct { get; set; } = 10; public float AsymDb { get; set; } = 3; public float HardnessPct { get; set; } = 40; public float SagPct { get; set; } = 15; public int Rectifier { get; set; } = 1; public bool XfmrEnabled { get; set; } = true; public float XfmrDamping { get; set; } = 2; public float XfmrResHz { get; set; } = 95; public float MixPct { get; set; } = 100; public float TrimDb { get; set; } }
public sealed class UpmixConfiguration { public bool Enabled { get; set; } public int CenterMode { get; set; } = 1; public int SurroundMode { get; set; } = 2; public float StrengthPct { get; set; } = 100; public float CenterWidthPct { get; set; } = 25; public float ThresholdPct { get; set; } = 30; public float AttackMs { get; set; } = 10; public float ReleaseMs { get; set; } = 100; public float DetectorHpfHz { get; set; } = 200; public float SurroundDelayMs { get; set; } = 12; public float SurroundHpfHz { get; set; } = 300; public float SurroundLpfHz { get; set; } = 7000; public float DecorrPct { get; set; } = 90; public float PresenceDb { get; set; } }
public sealed partial class EngineConfiguration
{
    public const int CurrentSchemaVersion = 1;
    public int SchemaVersion { get; set; } = CurrentSchemaVersion;
    public string Name { get; set; } = "Untitled";
    public float SampleRate { get; set; } = 48000;
    public int InputCount { get; set; } = 2;
    public int OutputCount { get; set; } = 2;
    public bool Bypass { get; set; }
    public float VolumeDb { get; set; }
    public float MasterVolumeDb { get; set; }
    public bool[] InputPairLinked { get; set; } = new bool[4];
    public ChannelConfiguration[] Inputs { get; set; } = Enumerable.Range(0,8).Select(_=>new ChannelConfiguration()).ToArray();
    public ChannelConfiguration[] Outputs { get; set; } = Enumerable.Range(0,8).Select(_=>new ChannelConfiguration()).ToArray();
    public RouteConfiguration[] Routes { get; set; } = Enumerable.Range(0,64).Select(n=>new RouteConfiguration {Input=n/8,Output=n%8,Enabled=n/8==n%8&&n/8<2}).ToArray();
    public LoudnessConfiguration Loudness { get; set; } = new();
    public CrossfeedConfiguration Crossfeed { get; set; } = new();
    public LevellerConfiguration Leveller { get; set; } = new();
    public PsybassConfiguration Psybass { get; set; } = new();
    public SubharmConfiguration Subharm { get; set; } = new();
    public TubeConfiguration Tube { get; set; } = new();
    public UpmixConfiguration Upmix { get; set; } = new();
    public EngineConfiguration Clone() => JsonSerializer.Deserialize<EngineConfiguration>(JsonSerializer.Serialize(this,PresetStore.JsonOptions),PresetStore.JsonOptions)!;
    public string ToRecipe()
    {
        Validate(); var t=new List<string>();
        void A(params object[] a) { foreach(var v in a)t.Add(v is float f?f.ToString("R",CultureInfo.InvariantCulture):Convert.ToString(v,CultureInfo.InvariantCulture)!); }
        string On(bool v)=>v?"on":"off";
        void Band(FilterConfiguration b,bool input,bool cross=false) {
            if(b.Bypass||b.Type==0)return;
            if(cross) A("--crossover",XoverNames[b.Type-32],b.FrequencyHz);
            else if(b.Type==11) A(input?"--input-lt":"--lt",b.FrequencyHz,b.Q,b.Gain,b.TargetQ);
            else A(input?"--input-filter":"--filter",PeqNames[b.Type],b.FrequencyHz,b.Q,b.Gain);
        }
        A("--volume",VolumeDb,"--master-gain",MasterVolumeDb);
        for(int i=0;i<InputCount;i++) {var c=Inputs[i];A("--input-channel",i+1,"--preamp",c.GainDb,"--input-delay",c.DelayMs); if(!Bypass&&!c.Bypass)foreach(var b in c.Eq)Band(b,true);}
        // Configure source generation before routes that reference virtual sources.
        if(!Bypass&&Upmix.Enabled) {
            var u=Upmix; A("--upmix",u.CenterMode==0?"passive":"adaptive","--upmix-center",new[]{"passive","adaptive","off"}[u.CenterMode],"--upmix-surround",new[]{"off","passive","adaptive"}[u.SurroundMode]);
            A("--upmix-strength",u.StrengthPct,"--upmix-width",u.CenterWidthPct,"--upmix-threshold",u.ThresholdPct,"--upmix-attack",u.AttackMs,"--upmix-release",u.ReleaseMs,"--upmix-detector-hpf",u.DetectorHpfHz,"--upmix-delay",u.SurroundDelayMs,"--upmix-hpf",u.SurroundHpfHz,"--upmix-lpf",u.SurroundLpfHz,"--upmix-decorr",u.DecorrPct,"--upmix-presence",u.PresenceDb);
        }
        A("--clear-routes"); int sources=!Bypass&&Upmix.Enabled?5:InputCount;
        foreach(var r in Routes)if(r.Enabled&&r.Input<sources&&r.Output<OutputCount)A(r.Invert?"--route-invert":"--route",r.Input+1,r.Output+1,r.GainDb);
        for(int o=0;o<OutputCount;o++) {
            var c=Outputs[o]; A("--channel",o+1,"--gain",c.GainDb,"--delay",c.DelayMs,c.Muted||!c.Enabled?"--mute":"--unmute");
            if(!Bypass) {if(!c.Bypass)foreach(var b in c.Eq)Band(b,false);foreach(var b in c.Crossover)Band(b,false,true);}
            if(c.Limiter.Enabled)A("--limiter",c.Limiter.ThresholdDb,c.Limiter.ReleaseMs,"--limiter-link",c.Limiter.LinkGroup);
            else A("--limiter-threshold",c.Limiter.ThresholdDb,"--limiter-release",c.Limiter.ReleaseMs,"--limiter-off","--limiter-link",c.Limiter.LinkGroup);
            if(Bypass)continue;
            if(Loudness.Enabled&&(Loudness.OutputMask&(1<<o))!=0)A("--loudness",Loudness.RefSpl,Loudness.IntensityPct);
            if(Psybass.Enabled&&(Psybass.OutputMask&(1<<o))!=0) {var p=Psybass;A("--psybass",p.CutoffHz,p.HarmonicsDb,p.DriveDb,p.CharacterPct,p.OriginalDb);}
            if(Subharm.Enabled&&(Subharm.OutputMask&(1<<o))!=0) {var s=Subharm;A("--subharm",s.LowDb,s.HighDb,s.TopDb,s.BoostDb,"--subharm-select",new[]{"all","percussive","sustained"}[s.SelectMode],s.SelectDepthPct,s.SelectHoldMs,"--subharm-link",On(s.LinkPairs),"--subharm-solo",On(s.Solo),"--subharm-ceiling",s.CeilingDb);}
            if(Tube.Enabled&&(Tube.OutputMask&(1<<o))!=0) {var x=Tube; A("--tube",x.TubeType,x.DriveDb,x.MixPct,"--tube-bias",x.BiasPct,"--tube-asym",x.AsymDb,"--tube-hardness",x.HardnessPct,"--tube-sag",x.SagPct,"--tube-rectifier",new[]{"solid-state","gz34","5u4","5y3"}[x.Rectifier],"--tube-trim",x.TrimDb); if(x.XfmrEnabled)A("--tube-output-stage",x.XfmrDamping,x.XfmrResHz);else A("--tube-no-output-stage");}
        }
        if(!Bypass&&Crossfeed.Enabled)for(int p=0;p<OutputCount/2;p++)if((Crossfeed.OutputPairMask&(1<<p))!=0) {var x=Crossfeed;A("--pair",p+1);if(x.Preset==3)A("--crossfeed-custom",x.FreqHz,x.FeedDb);else A("--crossfeed",new[]{"default","chumoy","meier"}[x.Preset]);A("--crossfeed-itd",On(x.Itd));}
        if(!Bypass&&Leveller.Enabled) {var l=Leveller;A("--leveller",l.AmountPct,new[]{"slow","medium","fast"}[l.Speed],l.MaxGainDb,"--leveller-lookahead",On(l.Lookahead),"--leveller-gate",l.GateDb,"--leveller-detectors",l.DetectorMask,"--leveller-apply",l.ApplyMask);}
        return string.Join('\n',t);
    }
    internal static readonly string[] PeqNames={"flat","peak","low-shelf","high-shelf","low-pass","high-pass","notch","all-pass","all-pass1","low-shelf1","high-shelf1","lt","low-pass1","high-pass1"};
    internal static readonly string[] XoverNames={"lr2-lp","lr2-hp","lr4-lp","lr4-hp","lr6-lp","lr6-hp","lr8-lp","lr8-hp","bw1-lp","bw1-hp","bw2-lp","bw2-hp","bw3-lp","bw3-hp","bw4-lp","bw4-hp","bw5-lp","bw5-hp","bw6-lp","bw6-hp","bw7-lp","bw7-hp","bw8-lp","bw8-hp","bes2-lp","bes2-hp","bes4-lp","bes4-hp","bes6-lp","bes6-hp","bes8-lp","bes8-hp"};
}
