using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Dspi.Software;

namespace Dspi.Apo;

public sealed class ApoProfileSnapshot
{
    private readonly EngineConfiguration configuration;
    public ulong Revision { get; }
    public EngineConfiguration Configuration => configuration.Clone();
    internal ApoProfileSnapshot(ulong revision, EngineConfiguration configuration)
    { Revision = revision; this.configuration = configuration.Clone(); }
}

/// <summary>One native processing instance; saved settings alone never imply processing.</summary>
public sealed class ApoInstanceStatus
{
    private readonly float[] inputs, outputs;
    public ulong InstanceId { get; }
    public ulong HeartbeatFileTime { get; }
    public ulong AcceptedRevision { get; }
    public ulong AppliedRevision { get; }
    public ulong RejectedRevision { get; }
    public ulong PendingRestartRevision { get; }
    public ulong ProcessedFrames { get; }
    public uint ActualRate { get; }
    public uint PhysicalChannels { get; }
    public uint Status { get; }
    public uint Error { get; }
    public uint Clips { get; }
    public uint AlgorithmicLatencyFrames { get; }
    public ulong LastProcessedFileTime { get; }
    public float[] InputPeaks => (float[])inputs.Clone();
    public float[] OutputPeaks => (float[])outputs.Clone();
    public MeterSnapshot Meters => new(InputPeaks, OutputPeaks, Clips);
    public DateTimeOffset Heartbeat => DateTimeOffset.FromFileTime((long)HeartbeatFileTime);
    public DateTimeOffset LastProcessed => DateTimeOffset.FromFileTime((long)LastProcessedFileTime);
    public bool IsFresh => Recent(HeartbeatFileTime, TimeSpan.FromSeconds(3));
    public bool IsProcessing => IsFresh && Status is 1 or 2 or 3 && ProcessedFrames > 0 && Recent(LastProcessedFileTime, TimeSpan.FromMilliseconds(500));

    private static bool Recent(ulong timestamp, TimeSpan limit)
    {
        ulong now = (ulong)DateTime.UtcNow.ToFileTimeUtc();
        return timestamp != 0 && timestamp <= now && now - timestamp <= (ulong)limit.Ticks;
    }

    internal ApoInstanceStatus(byte[] b)
    {
        InstanceId = Protocol.U64(b,16); HeartbeatFileTime = Protocol.U64(b,24);
        AcceptedRevision = Protocol.U64(b,32); AppliedRevision = Protocol.U64(b,40);
        RejectedRevision = Protocol.U64(b,48); PendingRestartRevision = Protocol.U64(b,56);
        ProcessedFrames = Protocol.U64(b,64); ActualRate = Protocol.U32(b,72);
        PhysicalChannels = Protocol.U32(b,76); Status = Protocol.U32(b,80); Error = Protocol.U32(b,84);
        inputs = new float[8]; outputs = new float[8];
        for (int i=0;i<8;i++)
        {
            inputs[i] = BitConverter.UInt32BitsToSingle(Protocol.U32(b,88+4*i));
            outputs[i] = BitConverter.UInt32BitsToSingle(Protocol.U32(b,120+4*i));
            if (!float.IsFinite(inputs[i]) || !float.IsFinite(outputs[i]) || inputs[i]<0 || outputs[i]<0)
                throw new InvalidDataException("Non-finite or negative native meter.");
        }
        Clips = Protocol.U32(b,152); AlgorithmicLatencyFrames = Protocol.U32(b,156); LastProcessedFileTime = Protocol.U64(b,160);
        if (InstanceId==0 || ActualRate is <8000 or >192000 || PhysicalChannels is <1 or >8 || Status>5 || Error>5)
            throw new InvalidDataException("Invalid native instance format or state.");
        const ulong maxFileTime = 2650467743999999999;
        if (HeartbeatFileTime>maxFileTime || LastProcessedFileTime>maxFileTime)
            throw new InvalidDataException("Invalid native timestamp.");
    }
}

/// <summary>Endpoint profile data access. Installation must provision the directory and ACLs.</summary>
public sealed class ApoProfileClient
{
    private const int MaxRecipe=262144, MaxJson=1048576;
    private static readonly UTF8Encoding Utf8 = new(false, true);
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DSPi", "Profiles");
    public string ProfileKey { get; }
    public string DirectoryPath { get; }
    public string TelemetryDirectoryPath => Path.Combine(DirectoryPath, "telemetry");
    private string ProfilePath => Path.Combine(DirectoryPath,"profile.bin");

    public ApoProfileClient(string root, string endpointId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(root); ArgumentException.ThrowIfNullOrWhiteSpace(endpointId);
        ProfileKey = Hash(endpointId.ToLowerInvariant());
        DirectoryPath = Path.Combine(Path.GetFullPath(root), ProfileKey);
    }

    public ulong Save(EngineConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var copy = configuration.Clone(); copy.Validate();
        if (copy.InputCount!=copy.OutputCount || copy.InputCount is <1 or >8 || copy.SampleRate!=MathF.Truncate(copy.SampleRate))
            throw new ArgumentException("APO profiles require the physical matching input/output count and an integer sample rate.", nameof(configuration));
        byte[] recipe=Utf8.GetBytes(copy.ToRecipe()), json=Utf8.GetBytes(PresetStore.Serialize(copy));
        if (recipe.Length==0 || recipe.Length>MaxRecipe || json.Length==0 || json.Length>MaxJson)
            throw new ArgumentException("APO profile exceeds payload bounds.", nameof(configuration));
        if (!Directory.Exists(DirectoryPath)) throw new DirectoryNotFoundException("APO profile directory must be provisioned by installation: " + DirectoryPath);
        // A stable file lock serializes independent controllers across Windows sessions too.
        // Keep the lock file: deleting it could allow two callers to lock different objects.
        using var writerLock = RetrySharing(() => new FileStream(Path.Combine(DirectoryPath,"profile.writer.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None),TimeSpan.FromSeconds(10));
            ulong floor;
            try { floor=Load()?.Revision ?? 0; }
            catch(Exception e) when(e is InvalidDataException or EndOfStreamException)
            {
                // A valid complete setting write repairs a damaged snapshot.
                // Never trust the corrupt header's revision. A clock-based
                // recovery floor plus actual accepted instance revisions keeps
                // existing workers from ignoring the repaired configuration.
                floor=(ulong)DateTime.UtcNow.Ticks;
            }
            foreach(var instance in ReadStatuses())
                floor=Math.Max(floor,Math.Max(instance.AcceptedRevision,Math.Max(instance.AppliedRevision,instance.PendingRestartRevision)));
            ulong revision=checked(floor+1);
            byte[] b=new byte[64+recipe.Length+json.Length];
            "DSPIAPO1"u8.CopyTo(b); Protocol.W32(b,8,1); Protocol.W32(b,12,64); Protocol.W64(b,16,revision);
            Protocol.W32(b,24,(uint)copy.SampleRate); Protocol.W32(b,28,(uint)copy.InputCount);
            Protocol.W32(b,32,(uint)recipe.Length); Protocol.W32(b,36,(uint)json.Length);
            recipe.CopyTo(b,64); json.CopyTo(b,64+recipe.Length); Protocol.W32(b,40,Protocol.Crc32(b.AsSpan(64)));
            string temp=Path.Combine(DirectoryPath,"profile."+Guid.NewGuid().ToString("N")+".tmp");
            try
            {
                using(var stream=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None,4096,FileOptions.WriteThrough))
                { stream.Write(b); stream.Flush(true); }
                // Replace preserves the existing installed file's permissions on Windows.
                if (File.Exists(ProfilePath)) File.Replace(temp,ProfilePath,null);
                else File.Move(temp,ProfilePath);
            }
            finally { if(File.Exists(temp))File.Delete(temp); }
            return revision;
    }

    public ApoProfileSnapshot? Load()
    {
        byte[] b;
        try { b=ReadBounded(ProfilePath,64+MaxRecipe+MaxJson); }
        catch(FileNotFoundException) { return null; }
        catch(DirectoryNotFoundException) { return null; }
        try
        {
            if(b.Length<64 || !b.AsSpan(0,8).SequenceEqual("DSPIAPO1"u8) || Protocol.U32(b,8)!=1 || Protocol.U32(b,12)!=64 || Protocol.U64(b,16)==0 || b.AsSpan(44,20).IndexOfAnyExcept((byte)0)>=0)
                throw new InvalidDataException("Invalid APO profile header.");
            uint recipeBytes=Protocol.U32(b,32), jsonBytes=Protocol.U32(b,36);
            if(recipeBytes==0 || recipeBytes>MaxRecipe || jsonBytes==0 || jsonBytes>MaxJson || (ulong)b.Length!=64UL+recipeBytes+jsonBytes || Protocol.U32(b,40)!=Protocol.Crc32(b.AsSpan(64)))
                throw new InvalidDataException("Invalid APO profile payload size or CRC.");
            string recipe=Utf8.GetString(b,64,(int)recipeBytes);
            if(recipe.Contains('\0') || recipe.EndsWith('\n') || recipe.EndsWith('\r')) throw new InvalidDataException("Invalid native recipe encoding.");
            var configuration=PresetStore.Deserialize(Utf8.GetString(b,64+(int)recipeBytes,(int)jsonBytes));
            if(configuration.InputCount!=configuration.OutputCount || configuration.InputCount!=Protocol.U32(b,28) || configuration.SampleRate!=Protocol.U32(b,24) || !string.Equals(configuration.ToRecipe(),recipe,StringComparison.Ordinal))
                throw new InvalidDataException("APO profile recipe, format and managed settings do not match.");
            return new(Protocol.U64(b,16),configuration);
        }
        catch(Exception e) when(e is JsonException or ArgumentException or InvalidOperationException or NullReferenceException or IndexOutOfRangeException)
        { throw new InvalidDataException("Invalid APO managed profile.",e); }
    }

    public IReadOnlyList<ApoInstanceStatus> ReadStatuses()
    {
        var results=new List<ApoInstanceStatus>();
        try
        {
            foreach(string path in Directory.EnumerateFiles(TelemetryDirectoryPath,"status-*-*.bin",SearchOption.TopDirectoryOnly))
            {
                try
                {
                    string[] parts=Path.GetFileNameWithoutExtension(path).Split('-');
                    if(parts.Length!=3 || !uint.TryParse(parts[1],System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out uint pid) || !uint.TryParse(parts[2],System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out uint serial)) continue;
                    byte[] b=ReadBounded(path,192);
                    if(b.Length!=192 || !b.AsSpan(0,8).SequenceEqual("DSPIMTR1"u8) || Protocol.U32(b,8)!=1 || Protocol.U32(b,12)!=192 || b.AsSpan(168,24).IndexOfAnyExcept((byte)0)>=0 || Protocol.U64(b,16)!=((ulong)pid<<32|serial)) continue;
                    results.Add(new(b));
                }
                catch(Exception e) when(e is IOException or InvalidDataException or UnauthorizedAccessException) { /* An instance may exit, replace or corrupt its file during a read. */ }
            }
        }
        catch(DirectoryNotFoundException) { }
        return results.OrderBy(s=>s.InstanceId).ToArray();
    }

    private static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Utf8.GetBytes(text))).ToLowerInvariant();
    private static byte[] ReadBounded(string path,int maximum) => RetrySharing(() => ReadBoundedOnce(path,maximum),TimeSpan.FromMilliseconds(250));
    private static T RetrySharing<T>(Func<T> operation,TimeSpan timeout)
    {
        var timer=System.Diagnostics.Stopwatch.StartNew();
        while(true)
        {
            try { return operation(); }
            catch(FileNotFoundException) when(timer.Elapsed<timeout) { Thread.Sleep(5); }
            catch(IOException e) when((e.HResult & 0xffff) is 32 or 33 && timer.Elapsed<timeout) { Thread.Sleep(5); }
        }
    }
    private static byte[] ReadBoundedOnce(string path,int maximum)
    {
        using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        long length=stream.Length;
        if(length<0 || length>maximum)throw new InvalidDataException("APO data exceeds the protocol size limit.");
        byte[] bytes=new byte[(int)length]; stream.ReadExactly(bytes);
        if(stream.ReadByte()!=-1)throw new InvalidDataException("APO data changed length while reading.");
        return bytes;
    }
}

internal static class Protocol
{
    internal static uint U32(byte[] b,int n)=>BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(n));
    internal static ulong U64(byte[] b,int n)=>BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(n));
    internal static void W32(byte[] b,int n,uint v)=>BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(n),v);
    internal static void W64(byte[] b,int n,ulong v)=>BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(n),v);
    internal static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        uint crc=uint.MaxValue;
        foreach(byte b in bytes) { crc^=b; for(int bit=0;bit<8;bit++)crc=(crc>>1)^((crc&1)==0?0:0xedb88320); }
        return ~crc;
    }
}
