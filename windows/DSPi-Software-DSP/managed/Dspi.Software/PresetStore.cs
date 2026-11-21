using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dspi.Software;

public sealed record PresetImportResult(EngineConfiguration Configuration,IReadOnlyList<string> Warnings);
public static class PresetStore
{
    public static JsonSerializerOptions JsonOptions { get; }=new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase,PropertyNameCaseInsensitive=true,WriteIndented=true,UnmappedMemberHandling=JsonUnmappedMemberHandling.Disallow };
    private static readonly JsonSerializerOptions ImportOptions=new() {PropertyNamingPolicy=JsonNamingPolicy.CamelCase,PropertyNameCaseInsensitive=true};
    public static string Serialize(EngineConfiguration c){c.Validate();return JsonSerializer.Serialize(c,JsonOptions);}
    public static EngineConfiguration Deserialize(string json){var c=JsonSerializer.Deserialize<EngineConfiguration>(json,JsonOptions)??throw new JsonException("Empty configuration.");c.Validate();return c;}
    public static EngineConfiguration Load(string path)=>Deserialize(File.ReadAllText(path));
    public static void Save(string path,EngineConfiguration configuration)
    {
        var json=Serialize(configuration);string full=Path.GetFullPath(path),temp=full+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {using(var stream=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough))using(var writer=new StreamWriter(stream)){writer.Write(json);writer.Flush();stream.Flush(true);}File.Move(temp,full,true);}
        finally {if(File.Exists(temp))File.Delete(temp);}
    }
    public static PresetImportResult ImportDspi(string path)=>ImportDspiJson(File.ReadAllText(path));
    public static PresetImportResult ImportDspiJson(string json)
    {
        using var doc=JsonDocument.Parse(json);var root=doc.RootElement;var warnings=new List<string>();
        JsonElement Get(JsonElement e,string name){foreach(var p in e.EnumerateObject())if(p.Name.Equals(name,StringComparison.OrdinalIgnoreCase))return p.Value;return default;}
        int I(JsonElement e,string n,int d=0){var x=Get(e,n);return x.ValueKind==JsonValueKind.Undefined||x.ValueKind==JsonValueKind.Null?d:x.GetInt32();}
        float F(JsonElement e,string n,float d=0){var x=Get(e,n);return x.ValueKind==JsonValueKind.Undefined||x.ValueKind==JsonValueKind.Null?d:x.GetSingle();}
        bool B(JsonElement e,string n,bool d=false){var x=Get(e,n);return x.ValueKind==JsonValueKind.Undefined?d:x.GetBoolean();}
        string S(JsonElement e,string n,string d=""){var x=Get(e,n);return x.ValueKind==JsonValueKind.String?x.GetString()!:d;}
        int version=I(root,"schemaVersion");if(version!=1)throw new JsonException("Unsupported DSPi preset schema version.");
        void Unknown(JsonElement e,IEnumerable<string> allowed,string label){var names=new HashSet<string>(allowed,StringComparer.OrdinalIgnoreCase);foreach(var prop in e.EnumerateObject())if(!names.Contains(prop.Name))warnings.Add($"Unsupported {label} field '{prop.Name}' was not imported.");}
        Unknown(root,new[]{"schemaVersion","meta","global","loudness","crossfeed","leveller","psybass","subharm","tube","upmix","channels","matrix","io"},"preset");
        var c=new EngineConfiguration();var meta=Get(root,"meta");
        int originalOutputs=8;
        if(meta.ValueKind==JsonValueKind.Object){c.Name=S(meta,"name","Imported DSPi preset");c.InputCount=I(meta,"inputChannelCount",2);originalOutputs=I(meta,"outputChannelCount",8);c.OutputCount=Math.Min(originalOutputs,8);}
        if(originalOutputs>8)warnings.Add($"DSPi hardware outputs 9–{originalOutputs} are unsupported and were not imported.");
        var global=Get(root,"global");if(global.ValueKind==JsonValueKind.Object){c.Bypass=B(global,"bypass");c.VolumeDb=F(global,"userVolumeDb");c.MasterVolumeDb=F(global,"masterVolumeDb");var gains=Get(global,"inputPreampsDb");if(gains.ValueKind==JsonValueKind.Array){int i=0;foreach(var g in gains.EnumerateArray()){if(i>=8)throw new JsonException("More than 8 input gains.");c.Inputs[i++].GainDb=g.GetSingle();}}var linked=Get(global,"inputPairLinked");if(linked.ValueKind==JsonValueKind.Array)c.InputPairLinked=linked.Deserialize<bool[]>()!;
            warnings.Add("Hardware input source, LG Sound Sync and persistence modes are unsupported; master and user volume levels were imported separately.");}
        void Block<T>(string name,Action<T> set){var b=Get(root,name);if(b.ValueKind==JsonValueKind.Object){Unknown(b,typeof(T).GetProperties().Select(p=>p.Name),name);set(b.Deserialize<T>(ImportOptions)!);}}
        Block<LoudnessConfiguration>("loudness",v=>c.Loudness=v);Block<CrossfeedConfiguration>("crossfeed",v=>c.Crossfeed=v);Block<LevellerConfiguration>("leveller",v=>c.Leveller=v);Block<PsybassConfiguration>("psybass",v=>c.Psybass=v);Block<SubharmConfiguration>("subharm",v=>c.Subharm=v);Block<TubeConfiguration>("tube",v=>c.Tube=v);Block<UpmixConfiguration>("upmix",v=>c.Upmix=v);
        int Mask(int value,int allowed,string label){if((value&~allowed)!=0)warnings.Add($"{label}: unsupported or inactive hardware channels were removed from the mask.");return value&allowed;}
        int om=(1<<c.OutputCount)-1,im=(1<<c.InputCount)-1;
        c.Loudness.OutputMask=Mask(c.Loudness.OutputMask,om,"Loudness");c.Psybass.OutputMask=Mask(c.Psybass.OutputMask,om,"Psybass");c.Subharm.OutputMask=Mask(c.Subharm.OutputMask,om,"Subharm");c.Tube.OutputMask=Mask(c.Tube.OutputMask,om,"Tube");c.Crossfeed.OutputPairMask=Mask(c.Crossfeed.OutputPairMask,(1<<(c.OutputCount/2))-1,"Crossfeed");c.Leveller.DetectorMask=Mask(c.Leveller.DetectorMask,im,"Leveller detector");c.Leveller.ApplyMask=Mask(c.Leveller.ApplyMask,im,"Leveller apply");
        var channels=Get(root,"channels");var seen=new HashSet<(bool,int)>();
        if(channels.ValueKind==JsonValueKind.Array)foreach(var ch in channels.EnumerateArray()){
            bool output=B(ch,"isOutput");int id=I(ch,"channelId");int index=I(ch,output?"outputIndex":"inputIndex",-1);
            if(index<0){int eq=I(ch,"eqChannel",-1);index=eq>=0?(output?eq-c.InputCount:eq):output?id-2:id<2?id:id-9;}
            if(index<0||index>7||(output?index>=c.OutputCount:index>=c.InputCount)){warnings.Add($"Channel '{S(ch,"name")}' (index {index+1}) is unsupported and was not imported.");continue;}
            if(!seen.Add((output,index)))throw new JsonException("Duplicate channel index.");
            var channel=output?c.Outputs[index]:c.Inputs[index];channel.Name=S(ch,"name");channel.DelayMs=F(ch,output?"outputDelayMs":"delayMs",F(ch,"delayMs"));
            Unknown(ch,new[]{"channelId","name","isOutput","eqChannel","inputIndex","outputIndex","delayMs","gainDb","muted","enabled","outputDelayMs","limiter","eq","crossover"},"channel");
            if(!output&&(B(ch,"muted")||!B(ch,"enabled",true)))warnings.Add($"Input {index+1}: hardware mute/enable state is unsupported and was not imported.");
            if(output){channel.GainDb=F(ch,"gainDb");channel.Muted=B(ch,"muted");channel.Enabled=B(ch,"enabled",true);var limiter=Get(ch,"limiter");if(limiter.ValueKind==JsonValueKind.Object)channel.Limiter=limiter.Deserialize<LimiterConfiguration>(ImportOptions)!;}
            void Bands(string key,FilterConfiguration[] dest){
                var bands=Get(ch,key);if(bands.ValueKind!=JsonValueKind.Array)return;int n=0;
                foreach(var b in bands.EnumerateArray()){
                    if(n>=dest.Length){
                        if(key=="eq"&&(I(b,"type")==0||B(b,"bypass"))){warnings.Add($"Channel {index+1}: inactive EQ band {n+1} exceeds the ten-band software limit and was not imported.");n++;continue;}
                        throw new JsonException($"Channel {index+1}: active or unsupported {key} band {n+1} exceeds the software limit of {dest.Length} bands.");
                    }
                    dest[n++]=new(){Type=I(b,"type"),FrequencyHz=F(b,"freqHz",1000),Q=F(b,"q",.707f),Gain=F(b,"gain"),TargetQ=F(b,"qp",.707f),Bypass=B(b,"bypass")};
                }
            }
            Bands("eq",channel.Eq);if(output)Bands("crossover",channel.Crossover);
        }
        var matrix=Get(root,"matrix");if(matrix.ValueKind==JsonValueKind.Array){foreach(var r in c.Routes)r.Enabled=false;var points=new HashSet<(int,int)>();foreach(var cp in matrix.EnumerateArray()){int i=I(cp,"input"),o=I(cp,"output");if(i<0||o<0)throw new JsonException("Negative crosspoint index.");if(i>=8||o>=c.OutputCount){warnings.Add($"Matrix input {i+1} to output {o+1} is unsupported and was not imported.");continue;}if(!points.Add((i,o)))throw new JsonException("Duplicate crosspoint.");var r=c.Routes[i*8+o];r.Enabled=B(cp,"enabled");r.Invert=B(cp,"invert");r.GainDb=F(cp,"gainDb");}}
        if(Get(root,"io").ValueKind==JsonValueKind.Object)warnings.Add("Physical IO pins, hardware clocks, ADAT and DAC hardware mute are unsupported and were not imported.");
        c.Validate();return new(c,warnings);
    }
}
