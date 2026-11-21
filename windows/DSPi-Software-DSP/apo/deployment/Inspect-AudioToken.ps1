param([Parameter(Mandatory)][string]$OutputPath,[switch]$IncludeCurrentProcess)
$ErrorActionPreference='Stop'
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
if(!$output.StartsWith($build+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Report must remain in the development build directory.'}
for($cursor=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($output));$null -ne $cursor -and $cursor.FullName.Length -ge $build.Length;$cursor=$cursor.Parent){
    if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Report ancestors must not be links.'}
}
if(Test-Path -LiteralPath $output){throw 'Choose a new report filename.'}
if(-not ('Dspi.Deployment.TokenReader' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace Dspi.Deployment {
    public class SidEntry { public string Sid; public uint Attributes; }
    public class TokenReport {
        public int ProcessId; public bool TokenReadable; public int Error;
        public string UserSid; public string IntegritySid; public bool IsAppContainer;
        public SidEntry[] Groups; public SidEntry[] RestrictedSids; public SidEntry[] Capabilities;
    }
    public static class TokenReader {
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr data,int size,out int needed);
        [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
        static IntPtr Info(IntPtr token,int kind,out int bytes) {
            bytes=0;GetTokenInformation(token,kind,IntPtr.Zero,0,out bytes);
            if(bytes<=0 || bytes>1048576)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            IntPtr p=Marshal.AllocHGlobal(bytes);
            if(!GetTokenInformation(token,kind,p,bytes,out bytes)){int error=Marshal.GetLastWin32Error();Marshal.FreeHGlobal(p);throw new System.ComponentModel.Win32Exception(error);}
            return p;
        }
        static string Sid(IntPtr token,int kind) {
            int bytes;IntPtr p=Info(token,kind,out bytes);
            try { return new SecurityIdentifier(Marshal.ReadIntPtr(p)).Value; }
            finally { Marshal.FreeHGlobal(p); }
        }
        static SidEntry[] Sids(IntPtr token,int kind) {
            int bytes;IntPtr p=Info(token,kind,out bytes);
            try {
                int n=Marshal.ReadInt32(p),offset=IntPtr.Size==8?8:4,stride=Marshal.SizeOf(typeof(SidAndAttributes));
                if(n<0 || n>4096 || (long)offset+(long)n*stride>bytes)throw new InvalidOperationException("Invalid group buffer");
                var list=new List<SidEntry>();
                for(int i=0;i<n;i++){
                    var item=(SidAndAttributes)Marshal.PtrToStructure(IntPtr.Add(p,offset+i*stride),typeof(SidAndAttributes));
                    list.Add(new SidEntry {Sid=new SecurityIdentifier(item.Sid).Value,Attributes=item.Attributes});
                }
                return list.ToArray();
            }finally{Marshal.FreeHGlobal(p);}
        }
        public static TokenReport Read(int pid) {
            var r=new TokenReport {ProcessId=pid};IntPtr process=OpenProcess(0x1000,false,pid),token=IntPtr.Zero;
            if(process==IntPtr.Zero){r.Error=Marshal.GetLastWin32Error();return r;}
            try {
                if(!OpenProcessToken(process,8,out token)){r.Error=Marshal.GetLastWin32Error();return r;}
                r.UserSid=Sid(token,1);r.IntegritySid=Sid(token,25);r.Groups=Sids(token,2);r.RestrictedSids=Sids(token,11);r.Capabilities=Sids(token,30);
                int bytes;IntPtr info=Info(token,29,out bytes);
                try{r.IsAppContainer=Marshal.ReadInt32(info)!=0;}finally{Marshal.FreeHGlobal(info);}
                r.TokenReadable=true;return r;
            }catch(System.ComponentModel.Win32Exception e){r.Error=e.NativeErrorCode;return r;}
            finally{if(token!=IntPtr.Zero)CloseHandle(token);CloseHandle(process);}
        }
    }
}
'@
}
$audio=@(Get-Process -Name audiodg -ErrorAction SilentlyContinue | ForEach-Object { [Dspi.Deployment.TokenReader]::Read($_.Id) })
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$report=[ordered]@{
    SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o')
    IsAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Purpose='Read-only token query. No privileges enabled, ACLs or audio settings changed.'
    Audiodg=$audio
}
if($IncludeCurrentProcess){$report.CurrentProcess=[Dspi.Deployment.TokenReader]::Read($PID)}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 8))
$stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
Write-Output $output
