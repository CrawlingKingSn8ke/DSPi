using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Dspi.Apo;
using Dspi.Software;

static class Program
{
    static int Main(string[] args)
    {
        if(args.Length==2 && args[0]=="--writer")
        { var writer=new ApoProfileClient(args[1],"crossprocess"); for(int i=0;i<8;i++)writer.Save(new());return 0; }
        string root = Path.Combine(Path.GetTempPath(), "dspi-apo-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Roundtrip(root); Multiwriter(root); Crossprocess(root); MalformedProfiles(root); Statuses(root); RepairProfile(root);
            Console.WriteLine("PASS managed APO profile, concurrency, binary and telemetry tests"); return 0;
        }
        catch(Exception e) { Console.Error.WriteLine(e); return 1; }
        finally { Directory.Delete(root, true); }
    }
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Throws<T>(Action action) where T:Exception { try { action(); } catch(T) { return; } throw new Exception("Expected " + typeof(T).Name); }
    static ApoProfileClient Client(string root, string endpoint)
    {
        var c = new ApoProfileClient(root, endpoint); Directory.CreateDirectory(c.DirectoryPath); return c;
    }
    static void RepairProfile(string root)
    {
        var client=Client(root,"repair");client.Save(new());client.Save(new());
        string path=Path.Combine(client.DirectoryPath,"profile.bin");
        byte[] bad=File.ReadAllBytes(path);bad[40]^=1;File.WriteAllBytes(path,bad);
        var desired=new EngineConfiguration {VolumeDb=-12};
        ulong repaired=client.Save(desired);
        Check(repaired>2&&client.Load()!.Configuration.VolumeDb==-12,"valid settings repair corrupted profile without resetting revisions");
    }
    static void Roundtrip(string root)
    {
        Check(Crc("123456789"u8)==0xcbf43926,"IEEE CRC32 standard vector");
        var missing = new ApoProfileClient(root, "Missing");
        Check(missing.Load() is null && missing.ReadStatuses().Count == 0, "missing profile");
        Throws<DirectoryNotFoundException>(() => missing.Save(new()));
        Check(!Directory.Exists(missing.DirectoryPath), "must not install profile directory");
        var c = Client(root, "{Mixed-ENDPOINT}/../endpoint");
        string expected = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("{mixed-endpoint}/../endpoint"))).ToLowerInvariant();
        Check(c.ProfileKey == expected && new ApoProfileClient(root,"{MIXED-ENDPOINT}/../ENDPOINT").ProfileKey == expected, "endpoint hash");
        var config = new EngineConfiguration {Name="APO test \u03bb", VolumeDb=-7};
        Check(c.Save(config) == 1, "first revision"); config.VolumeDb = -20;
        var s=c.Load()!; Check(s.Revision == 1 && s.Configuration.VolumeDb == -7 && s.Configuration.Name == "APO test \u03bb", "roundtrip/copy");
        s.Configuration.VolumeDb=-30; Check(s.Configuration.VolumeDb == -7, "snapshot defensive configuration");
        byte[] b=File.ReadAllBytes(Path.Combine(c.DirectoryPath,"profile.bin"));
        Check(Encoding.ASCII.GetString(b,0,8)=="DSPIAPO1" && U32(b,8)==1 && U32(b,12)==64 && U64(b,16)==1, "C profile header");
        Check(U32(b,24)==48000 && U32(b,28)==2 && b.AsSpan(44,20).IndexOfAnyExcept((byte)0)<0, "C profile format/reserved");
        Check(b.Length==64+U32(b,32)+U32(b,36) && U32(b,40)==Crc(b.AsSpan(64)), "C CRC and exact size");
        string recipe=Encoding.UTF8.GetString(b,64,(int)U32(b,32));
        Check(recipe == s.Configuration.ToRecipe() && !recipe.EndsWith('\n'), "native recipe exact");
        var invalid=new EngineConfiguration {OutputCount=3}; Throws<ArgumentException>(()=>c.Save(invalid));
        Throws<ArgumentException>(()=>c.Save(new(){SampleRate=48000.5f}));
        Throws<ArgumentException>(()=>c.Save(new(){Name=new string('x',1048577)}));
        Check(c.Load()!.Revision==1,"rejection retains profile");
        Check(c.Save(s.Configuration)==2 && Directory.GetFiles(c.DirectoryPath,"*.tmp").Length==0,"atomic replacement");
    }
    static void Multiwriter(string root)
    {
        var c=Client(root,"concurrency"); var revisions=new System.Collections.Concurrent.ConcurrentBag<ulong>();
        Parallel.For(0,24,_=>revisions.Add(new ApoProfileClient(root,"concurrency").Save(new())));
        Check(revisions.Order().SequenceEqual(Enumerable.Range(1,24).Select(v=>(ulong)v)),"monotonic multiwriter revisions");
        Check(c.Load()!.Revision==24,"latest complete snapshot");
    }
    static void Crossprocess(string root)
    {
        var c=Client(root,"crossprocess");c.Save(new());
        var children=new List<System.Diagnostics.Process>();
        try
        {
            for(int i=0;i<4;i++)
            {
                var start=new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true};
                if(Path.GetFileNameWithoutExtension(Environment.ProcessPath)=="dotnet")start.ArgumentList.Add(typeof(Program).Assembly.Location);
                start.ArgumentList.Add("--writer");start.ArgumentList.Add(root);
                children.Add(System.Diagnostics.Process.Start(start)!);
            }
            ulong observed=0;int reads=0;
            while(children.Any(p=>!p.HasExited))
            { var snapshot=c.Load()!;Check(snapshot.Revision>=observed,"atomic monotonic reader");observed=snapshot.Revision;reads++; }
            foreach(var child in children)Check(child.ExitCode==0,"crossprocess writer exit");
            Check(c.Load()!.Revision==33 && reads>0,"crossprocess serialized revisions");
        }
        finally { foreach(var child in children){if(!child.HasExited){child.Kill();child.WaitForExit();}child.Dispose();} }
    }
    static void MalformedProfiles(string root)
    {
        var c=Client(root,"malformed"); c.Save(new()); string path=Path.Combine(c.DirectoryPath,"profile.bin"); var good=File.ReadAllBytes(path);
        void Reject(Action<byte[]> change, bool crc=false) { var b=(byte[])good.Clone(); change(b); if(crc) W32(b,40,Crc(b.AsSpan(64))); File.WriteAllBytes(path,b); Throws<InvalidDataException>(()=>c.Load()); }
        Reject(b=>b[0]=0); Reject(b=>W32(b,8,2)); Reject(b=>W32(b,12,63)); Reject(b=>W64(b,16,0)); Reject(b=>b[44]=1);
        Reject(b=>W32(b,32,262145)); Reject(b=>W32(b,36,1048577)); Reject(b=>b[64]^=1);
        Reject(b=>b[64]=0,true); Reject(b=>b[64]=0xff,true); Reject(b=>b[64+(int)U32(b,32)-1]=(byte)'\n',true);
        Reject(b=>b[64+(int)U32(b,32)]=0xff,true);
        Reject(b=>b[64+(int)U32(b,32)]=(byte)'[',true);
        Reject(b=>W32(b,28,3)); Reject(b=>W32(b,24,44100));
        File.WriteAllBytes(path,good.Concat(new byte[]{0}).ToArray()); Throws<InvalidDataException>(()=>c.Load());
        using(var f=new FileStream(path,FileMode.Create))f.SetLength(64+262144+1048576+1);
        Throws<InvalidDataException>(()=>c.Load());
        File.WriteAllBytes(path,good); Check(c.Load()!.Revision==1,"recover valid profile");
        var overflow=(byte[])good.Clone();W64(overflow,16,ulong.MaxValue);File.WriteAllBytes(path,overflow);
        Throws<OverflowException>(()=>c.Save(new()));Check(c.Load()!.Revision==ulong.MaxValue,"revision overflow retains original");
    }
    static void Statuses(string root)
    {
        var c=Client(root,"status"); long now=DateTime.UtcNow.ToFileTimeUtc();
        byte[] Status(ulong id,long heartbeat,long processed,uint status=1)
        {
            byte[] b=new byte[192]; Encoding.ASCII.GetBytes("DSPIMTR1").CopyTo(b,0);W32(b,8,1);W32(b,12,192);W64(b,16,id);W64(b,24,(ulong)heartbeat);
            for(int i=0;i<4;i++)W64(b,32+i*8,(ulong)(10+i));W64(b,64,1024);W32(b,72,48000);W32(b,76,2);W32(b,80,status);W32(b,84,0);
            W32(b,88,BitConverter.SingleToUInt32Bits(.25f));W32(b,120,BitConverter.SingleToUInt32Bits(.5f));W32(b,152,7);W32(b,156,128);W64(b,160,(ulong)processed);return b;
        }
        Directory.CreateDirectory(c.TelemetryDirectoryPath);
        void Put(uint pid,uint serial,byte[] b)=>File.WriteAllBytes(Path.Combine(c.TelemetryDirectoryPath,$"status-{pid}-{serial}.bin"),b);
        Put(10,1,Status((10UL<<32)|1,now,now));Put(10,2,Status((10UL<<32)|2,now-TimeSpan.FromSeconds(5).Ticks,now-TimeSpan.FromSeconds(5).Ticks));
        Put(11,1,Status((11UL<<32)|1,now,now-TimeSpan.FromSeconds(1).Ticks));
        Put(12,1,Status((12UL<<32)|1,now,now,5));
        var all=c.ReadStatuses();Check(all.Count==4,"per-instance status records");
        var live=all.Single(s=>s.InstanceId==((10UL<<32)|1));Check(live.IsFresh&&live.IsProcessing,"live status");
        Check(live.AcceptedRevision==10 && live.AppliedRevision==11 && live.RejectedRevision==12 && live.PendingRestartRevision==13 && live.ProcessedFrames==1024 && live.ActualRate==48000 && live.PhysicalChannels==2 && live.AlgorithmicLatencyFrames==128,"C status offsets");
        Check(live.Meters.Inputs[0]==.25f&&live.Meters.Outputs[0]==.5f&&live.Meters.Clips==7,"real meters");
        live.Meters.Inputs[0]=99;live.InputPeaks[0]=99;Check(live.Meters.Inputs[0]==.25f,"defensive meters");
        Check(!all.Single(s=>s.InstanceId==((10UL<<32)|2)).IsFresh,"stale status");
        Check(!all.Single(s=>s.InstanceId==((11UL<<32)|1)).IsProcessing,"heartbeat is not processing");
        Check(!all.Single(s=>s.InstanceId==((12UL<<32)|1)).IsProcessing,"stopped is not processing");
        var bad=Status((13UL<<32)|1,now,now);W32(bad,88,BitConverter.SingleToUInt32Bits(float.NaN));Put(13,1,bad);
        var reserved=Status((14UL<<32)|1,now,now);reserved[191]=1;Put(14,1,reserved);
        Put(15,1,Status((99UL<<32)|1,now,now));Put(16,1,new byte[193]);
        var infinite=Status((18UL<<32)|1,now,now);W32(infinite,148,BitConverter.SingleToUInt32Bits(float.PositiveInfinity));Put(18,1,infinite);
        var invalidTime=Status((19UL<<32)|1,now,now);W64(invalidTime,24,ulong.MaxValue);Put(19,1,invalidTime);
        var future=Status((17UL<<32)|1,now+TimeSpan.FromSeconds(10).Ticks,now);Put(17,1,future);
        all=c.ReadStatuses();Check(all.Count==5 && !all.Single(s=>s.InstanceId==((17UL<<32)|1)).IsFresh,"malformed skipped, future not fresh");
    }
    static uint U32(byte[] b,int n)=>BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(n));
    static ulong U64(byte[] b,int n)=>BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(n));
    static void W32(byte[] b,int n,uint v)=>BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(n),v);
    static void W64(byte[] b,int n,ulong v)=>BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(n),v);
    static uint Crc(ReadOnlySpan<byte> bytes) { uint c=0xffffffff;foreach(byte b in bytes){c^=b;for(int i=0;i<8;i++)c=(c>>1)^((c&1)==0?0:0xedb88320);}return ~c; }
}
