using Dspi.Software;
using System.Globalization;
using System.Text.Json;

int passed=0;
void Check(bool yes,string message){if(!yes)throw new Exception(message);passed++;}
void Reject(Action action,string message){try{action();}catch(ArgumentException){passed++;return;}catch(JsonException){passed++;return;}throw new Exception(message);}
var c=new EngineConfiguration {Name="Full preset",InputCount=8,OutputCount=8,VolumeDb=-12,MasterVolumeDb=-3};
for(int i=0;i<8;i++){
    c.Inputs[i].Name=$"Input {i}";c.Inputs[i].GainDb=-i;c.Inputs[i].DelayMs=i;
    var o=c.Outputs[i];o.Name=$"Output {i}";o.GainDb=-i;o.DelayMs=i*2;o.Muted=i==7;o.Enabled=i!=6;o.Bypass=i==5;
    o.Limiter=new(){Enabled=true,ThresholdDb=-3,ReleaseMs=90,LinkGroup=i%5};
    for(int b=0;b<10;b++)foreach(var ch in new[]{c.Inputs[i],o})ch.Eq[b]=new(){Type=b+1,FrequencyHz=200+b*150,Q=.8f+b*.1f,Gain=b-5,TargetQ=.9f,Bypass=b==3};
    for(int b=0;b<4;b++)o.Crossover[b]=new(){Type=32+i*4+b,FrequencyHz=1000+b*100,Bypass=b==3};
}
for(int i=0;i<64;i++){c.Routes[i].Enabled=true;c.Routes[i].GainDb=-i;c.Routes[i].Invert=i%2==0;}
c.InputPairLinked=[true,false,true,true];c.Loudness=new(){Enabled=true,RefSpl=45,IntensityPct=150,OutputMask=255};
c.Crossfeed=new(){Enabled=true,Preset=3,FreqHz=900,FeedDb=6,Itd=false,OutputPairMask=15};
c.Leveller=new(){Enabled=true,Speed=2,Lookahead=false,AmountPct=35,MaxGainDb=10,GateDb=-70,DetectorMask=255,ApplyMask=127};
c.Psybass=new(){Enabled=true,CutoffHz=90,HarmonicsDb=-3,DriveDb=5,CharacterPct=66,OriginalDb=-6,OutputMask=255};
c.Subharm=new(){Enabled=true,LowDb=-5,HighDb=-6,TopDb=-12,BoostDb=2,OutputMask=255,SelectMode=2,SelectDepthPct=50,SelectHoldMs=160,CeilingDb=-6,LinkPairs=false,Solo=true};
c.Tube=new(){Enabled=true,OutputMask=255,TubeType=0,DriveDb=-10,BiasPct=-20,AsymDb=-2,HardnessPct=30,SagPct=20,Rectifier=2,XfmrEnabled=true,XfmrDamping=4,XfmrResHz=80,MixPct=75,TrimDb=-2};
var json=PresetStore.Serialize(c);Check(json==PresetStore.Serialize(PresetStore.Deserialize(json)),"Full fields did not roundtrip.");
var path=Path.Combine(Path.GetTempPath(),Guid.NewGuid()+".json");
try {PresetStore.Save(path,c);var before=File.ReadAllText(path);var bad=c.Clone();bad.VolumeDb=float.NaN;Reject(()=>PresetStore.Save(path,bad),"Nonfinite save accepted");Check(File.ReadAllText(path)==before,"Failed save changed previous preset");Check(PresetStore.Serialize(PresetStore.Load(path))==json,"Save/load mismatch");}finally{File.Delete(path);}
Reject(()=>PresetStore.Deserialize(json.Replace("\"schemaVersion\": 1","\"schemaVersion\": 99")),"Future version accepted");
var badTopology=c.Clone();badTopology.InputCount=9;Reject(()=>badTopology.Validate(),"Bad topology accepted");
badTopology=c.Clone();badTopology.Routes[0].Input=1;Reject(()=>badTopology.Validate(),"Duplicate route accepted");
var badFilter=c.Clone();badFilter.Inputs[7].Eq[9].FrequencyHz=float.PositiveInfinity;Reject(()=>badFilter.Validate(),"Nonfinite dormant field accepted");
var inconsistent=c.Clone();inconsistent.Outputs[1].Limiter.ReleaseMs=200;Reject(()=>inconsistent.Validate(),"Inconsistent linked limiter accepted");
var mutedInput=c.Clone();mutedInput.Inputs[0].Muted=true;Reject(()=>mutedInput.Validate(),"Unsupported input mute silently accepted");
CultureInfo.CurrentCulture=CultureInfo.GetCultureInfo("de-DE");var recipe=c.ToRecipe();Check(recipe.Contains("0.8")&&!recipe.Contains("0,8"),"Recipe not invariant");CultureInfo.CurrentCulture=CultureInfo.InvariantCulture;
var bypass=c.Clone();bypass.Bypass=true;var rb=bypass.ToRecipe();Check(!rb.Contains("--filter")&&!rb.Contains("--tube")&&!rb.Contains("--crossover")&&rb.Contains("--limiter")&&rb.Contains("--route-invert")&&rb.Contains("--delay"),"Bypass stage policy failed");
var perChannel=new EngineConfiguration();perChannel.Outputs[0].Bypass=true;perChannel.Outputs[0].Eq[0].Type=1;perChannel.Outputs[0].Crossover[0].Bypass=false;Check(perChannel.ToRecipe().Contains("--crossover")&&!perChannel.ToRecipe().Contains("--filter"),"Channel bypass must retain crossover");
const string shared="""
{"schemaVersion":1,"meta":{"name":"Imported","inputChannelCount":8,"outputChannelCount":9},"global":{"inputPreampsDb":[-3,-2,0,0,0,0,0,0],"userVolumeDb":-8},"channels":[{"channelId":11,"name":"Input 3","isOutput":false,"delayMs":2,"eq":[{"type":11,"freqHz":40,"q":0.7,"gain":80,"qp":0.9}]},{"channelId":2,"name":"Output 1","isOutput":true,"outputIndex":0,"delayMs":2,"outputDelayMs":5,"gainDb":-3,"limiter":{"enabled":true,"thresholdDb":-2,"releaseMs":120,"linkGroup":2},"crossover":[{"type":34,"freqHz":80}]},{"channelId":10,"name":"PDM","isOutput":true}],"matrix":[{"input":2,"output":0,"enabled":true,"gainDb":-2},{"input":0,"output":8,"enabled":true}],"io":{"outputPins":"BgcICQo="}}
""";
var imported=PresetStore.ImportDspiJson(shared);Check(imported.Configuration.Inputs[2].Eq[0].TargetQ==.9f&&imported.Configuration.Outputs[0].DelayMs==5&&imported.Configuration.Outputs[0].Limiter.LinkGroup==2,"Import field mapping failed");Check(imported.Warnings.Any(w=>w.Contains("9"))&&imported.Warnings.Any(w=>w.Contains("Physical IO")),"Unsupported import not reported");
var master=PresetStore.ImportDspiJson(shared.Replace("\"userVolumeDb\":-8","\"masterVolumeDb\":-30,\"userVolumeDb\":-8"));Check(master.Configuration.VolumeDb==-8&&master.Configuration.MasterVolumeDb==-30&&master.Warnings.Any(w=>w.Contains("persistence modes")),"Independent hardware master and user volume were not preserved separately");
var flatCross=PresetStore.ImportDspiJson(shared.Replace("\"type\":34","\"type\":0"));Check(!flatCross.Configuration.ToRecipe().Contains("--crossover"),"Flat hardware crossover was not imported as off");
string TwelveBands(bool activeTail)=>JsonSerializer.Serialize(new{schemaVersion=1,channels=new[]{new{channelId=0,isOutput=false,eq=Enumerable.Range(0,12).Select(i=>new{type=i<10||activeTail?1:0,freqHz=1000,q=1,gain=1,bypass=false})}}});
var twelve=PresetStore.ImportDspiJson(TwelveBands(false));Check(twelve.Configuration.Inputs[0].Eq.All(b=>b.Type==1)&&twelve.Warnings.Count(w=>w.Contains("inactive EQ band"))==2,"Inactive trailing Console EQ slots were not reported and skipped");
Reject(()=>PresetStore.ImportDspiJson(TwelveBands(true)),"Active EQ beyond ten silently discarded");
Reject(()=>PresetStore.ImportDspiJson(shared.Replace("\"schemaVersion\":1","\"schemaVersion\":2")),"Future DSPi import accepted");
var upmix=new EngineConfiguration();upmix.Upmix=new(){Enabled=true,CenterMode=2,SurroundMode=1,StrengthPct=70,CenterWidthPct=80,ThresholdPct=40,AttackMs=20,ReleaseMs=200,DetectorHpfHz=300,SurroundDelayMs=8,SurroundHpfHz=200,SurroundLpfHz=6000,DecorrPct=50,PresenceDb=3};upmix.Routes[2*8].Enabled=true;
Check(PresetStore.Serialize(PresetStore.Deserialize(PresetStore.Serialize(upmix)))==PresetStore.Serialize(upmix),"Upmix roundtrip failed");
if(File.Exists(Path.Combine(AppContext.BaseDirectory,"dspi-host.dll"))){
    using(var s=new NativeSession(c)){var input=Enumerable.Repeat(.01f,8*1024).ToArray();var output=new float[input.Length];s.Process(input,output,1024);Check(output.All(float.IsFinite),"Full configuration produced nonfinite output");}
    using(var s=new NativeSession(upmix)){s.Process(new float[1600],new float[1600],800);Check(s.CurrentConfiguration.Upmix.CenterMode==2,"Surround-only upmix failed");}
    var defaults=new EngineConfiguration();using var session=new NativeSession(defaults);var samples=Enumerable.Repeat(.25f,2600).ToArray();var result=new float[2600];session.Process(samples,result,1300);Check(result.All(x=>Math.Abs(x-.25f)<1e-6),"Default native identity failed");
    var meters=session.ReadMeters();Check(meters.Inputs[0]==.25f&&meters.Outputs[1]==.25f,"Native meters failed");Check(session.ReadMeters().Inputs[0]==0,"Meters did not reset");
    var renamed=defaults.Clone();renamed.Name="Renamed";renamed.Inputs[0].Name="Left source";renamed.Psybass.DriveDb=8;session.Apply(renamed);session.Process(samples,result,1300);Check(result.All(x=>x==.25f)&&session.CurrentConfiguration.Name=="Renamed","Metadata/disabled effect edits disturbed native audio");
    var edit=defaults.Clone();edit.VolumeDb=-6;session.Apply(edit);session.Process(samples,result,1300);Check(Math.Abs(result[^1]-.25f*MathF.Pow(10,-6/20f))<1e-5,"Live transition did not reach target");Check(result.Take(1920).Min()<.005f,"Live transition did not fade");
    var dual=edit.Clone();dual.MasterVolumeDb=-6;session.Apply(dual);session.Process(samples,result,1300);Check(Math.Abs(result[^1]-.25f*MathF.Pow(10,-12/20f))<1e-5,"Independent master and user gains did not combine correctly");Check(session.CurrentConfiguration.VolumeDb==-6&&session.CurrentConfiguration.MasterVolumeDb==-6,"Dual volume state lost independence");
    var loud=defaults.Clone();loud.VolumeDb=-20;loud.Loudness.Enabled=true;var trimmed=loud.Clone();trimmed.MasterVolumeDb=-6;
    using(var a=new NativeSession(loud))using(var b=new NativeSession(trimmed)){var untrimmedOutput=new float[2600];var trimmedOutput=new float[2600];a.Process(samples,untrimmedOutput,1300);b.Process(samples,trimmedOutput,1300);Check(untrimmedOutput.Zip(trimmedOutput,(x,y)=>Math.Abs(y-x*MathF.Pow(10,-6/20f))).Max()<1e-5,"Master trim incorrectly changed loudness calibration");}
    var masterMute=defaults.Clone();masterMute.MasterVolumeDb=-128;using(var muted=new NativeSession(masterMute)){muted.Process(samples,result,1300);Check(result.All(x=>x==0),"Master mute sentinel did not produce silence");}
    var invalid=edit.Clone();invalid.OutputCount=9;Reject(()=>session.Apply(invalid),"Invalid apply accepted");Check(session.CurrentConfiguration.VolumeDb==-6,"Rejected apply modified current configuration");
    var external=session.CurrentConfiguration;external.VolumeDb=-40;Check(session.CurrentConfiguration.VolumeDb==-6,"Current configuration is externally mutable");
    var lt=defaults.Clone();lt.Inputs[0].Eq[0]=new(){Type=11,FrequencyHz=40,Q=.7f,Gain=80,TargetQ=.9f};lt.Outputs[0].Eq[0]=new(){Type=11,FrequencyHz=40,Q=.7f,Gain=80,TargetQ=1.2f};using var linkwitz=new NativeSession(lt);Check(true,"LT preparation failed");
}else Console.WriteLine("Native tests skipped: build/dspi-host.dll is absent.");
foreach(var fixture in args){var result=PresetStore.ImportDspi(fixture);result.Configuration.Validate();Check(result.Warnings.Count>0,"Expected hardware compatibility warnings for shared fixture");Console.WriteLine($"Imported shared fixture: {Path.GetFileName(fixture)} ({result.Warnings.Count} warnings).");}
Console.WriteLine($"PASS: {passed} managed checks.");
