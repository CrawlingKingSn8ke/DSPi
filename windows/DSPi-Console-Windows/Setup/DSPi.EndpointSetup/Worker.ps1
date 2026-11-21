param(
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$OperationId,
 [Parameter(Mandatory)][ValidateSet('Install','Remove')][string]$Operation
)
$ErrorActionPreference='Stop'
function Read-Session {
 $backup=Join-Path $PSScriptRoot 'endpoint-before.json'
 $record=Get-Content -Raw -LiteralPath $backup | ConvertFrom-Json
 if($record.EndpointGuid -cnotmatch '^\{[0-9a-f-]{36}\}$' -or
    $record.SessionId -cnotmatch '^[a-f0-9]{32}$' -or
    ('install-'+$record.SessionId) -cne (Split-Path $PSScriptRoot -Leaf) -or
    $record.UserSid -cnotmatch '^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$'){throw 'Invalid protected endpoint record.'}
 if($record.FxPropertiesExisted -ne $false -or $record.ProfileExisted -ne $false){throw 'The original endpoint state is not supported.'}
 $record
}
$record=Read-Session
$endpointGuid=([guid]$record.EndpointGuid).ToString('B')
$endpointId='{0.0.0.00000000}.'+$endpointGuid
$endpointBase='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$endpointGuid
$clsid='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
$binding='{67fe7ad1-1232-4c16-94ce-83a4f63be981},1'
$effect='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$mode='{d3993a3f-99c2-4402-b5ec-a92a0367664b},7'
$defaultMode='{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}'
$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($endpointId.ToLowerInvariant()))).ToLowerInvariant()
$program=[Environment]::GetFolderPath('ProgramFiles')
$data=[Environment]::GetFolderPath('CommonApplicationData')
$profile=Join-Path $data ('DSPi\Profiles\'+$hash)
$telemetry=Join-Path $profile 'telemetry'
$hostPath=Join-Path $program 'PowerShell\7\pwsh.exe'
$root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.Identity.User.Value -ne 'S-1-5-18'){throw 'System token required for the exact endpoint test.'}


function Assert-Endpoint {
 $p=$root.OpenSubKey($endpointBase+'\Properties')
 if(!$p){throw 'The selected playback device is unavailable.'}
 try{
  if($p.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},2') -ine $record.HardwareInstance -or
     $p.GetValue('{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},8') -ine '{DFF21CE1-F70F-11D0-B917-00A0C9223196}'){
    throw 'The playback device identity or speaker layout changed.'
  }
 }finally{$p.Dispose()}
}
function Restart-Audio {
 $running=@(Get-Service Audiosrv -DependentServices | Where-Object Status -eq Running)
 if(@($running | Where-Object Name -ne 'LightingService').Count){throw 'An unexpected running service depends on Windows Audio.'}
 try {
  foreach($service in $running) {Stop-Service -Name $service.Name}
  Restart-Service -Name Audiosrv
 }finally{
  if((Get-Service Audiosrv).Status -ne 'Running'){Start-Service Audiosrv}
  foreach($service in $running){if((Get-Service $service.Name).Status -ne 'Running'){Start-Service -Name $service.Name}}
 }
}
function Undo-Values($key) {
 $expected=@{$effect=$clsid;$mode=$defaultMode;$binding=$hash}
 foreach($name in $expected.Keys) {
  if($name -notin $key.GetValueNames()){continue}
  $value=$key.GetValue($name)
  if(@($value).Count -ne 1 -or [string]@($value)[0] -ine $expected[$name]){
   throw 'An effects value changed during the test. Recovery preserved it.'
  }
 }
 foreach($name in $expected.Keys){$key.DeleteValue($name,$false)}
 $key.Flush()
}
function Remove-TestProfile {
 if(!(Test-Path -LiteralPath $profile)){return}
 $acl=Get-Acl -LiteralPath $profile
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){throw 'The test profile permissions changed.'}
 if((Get-Item -LiteralPath $profile).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile directory link.'}
 foreach($child in Get-ChildItem -LiteralPath $profile -Force){
  if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected profile link.'}
  if($child.PSIsContainer){
   if($child.Name -cne 'telemetry'){throw 'Unexpected test-profile directory.'}
   foreach($item in Get-ChildItem -LiteralPath $child.FullName -Force){
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Name -notmatch '^(status|spectrum)-[0-9]+-[0-9]+\.bin(\.tmp)?$'){throw 'Unexpected telemetry file; retained.'}
    [IO.File]::Delete($item.FullName)
   }
   [IO.Directory]::Delete($child.FullName,$false)
  }else{
   if($child.Name -notin @('profile.bin','profile.writer.lock','rta-control.bin')){throw 'Unexpected test-profile file; retained.'}
   [IO.File]::Delete($child.FullName)
  }
 }
 [IO.Directory]::Delete($profile,$false)
}

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public static class EndpointRegistryNative
{
    [StructLayout(LayoutKind.Sequential)]
    struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)]
    struct Entry { public Luid Id; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    struct Privileges { public uint Count; public Entry First, Second; }
    [StructLayout(LayoutKind.Sequential)]
    struct Security { public int Length; public IntPtr Descriptor; public int Inherit; }
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LookupPrivilegeValue(string machine, string privilege, out Luid id);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(SafeFileHandle token, bool disableAll, ref Privileges next,
        int previousSize, out Privileges previous, out int needed);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint bytes);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, EntryPoint="RegCreateKeyExW")]
    static extern int RegCreateKeyEx(SafeRegistryHandle parent, string child, uint reserved, string cls,
        uint options, uint rights, IntPtr security, out SafeRegistryHandle key, out uint disposition);

    public static RegistryKey OpenForRestore(RegistryKey existing, string child, string sddl)
    {
        if (child != "" && child != "FxProperties")
            throw new ArgumentException("Unexpected endpoint subkey.");
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out var token))
            throw new Win32Exception();
        using (token)
        {
            var privileges = new Privileges { Count=2 };
            if (!LookupPrivilegeValue(null, "SeBackupPrivilege", out privileges.First.Id) ||
                !LookupPrivilegeValue(null, "SeRestorePrivilege", out privileges.Second.Id))
                throw new Win32Exception();
            privileges.First.Attributes=2;
            privileges.Second.Attributes=2;
            bool adjusted=AdjustTokenPrivileges(token, false, ref privileges, Marshal.SizeOf<Privileges>(), out var previous, out _);
            int result=Marshal.GetLastWin32Error();
            if (!adjusted || result == 1300)
                throw new Win32Exception(result);
            try
            {
                IntPtr descriptor=IntPtr.Zero, attributes=IntPtr.Zero;
                try
                {
                    if (sddl != null)
                    {
                        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out descriptor, out _))
                            throw new Win32Exception();
                        int size=Marshal.SizeOf<Security>();
                        attributes=Marshal.AllocHGlobal(size);
                        Marshal.StructureToPtr(new Security { Length=size, Descriptor=descriptor }, attributes, false);
                    }
                    int status=RegCreateKeyEx(existing.Handle, child, 0, null, 4, 0, attributes, out var key, out var disposition);
                    if (status != 0) { key?.Dispose(); throw new Win32Exception(status); }
                    if (disposition != (child == "" ? 2u : 1u))
                    {
                        key.Dispose();
                        throw new InvalidOperationException("The endpoint effects key changed before acquisition.");
                    }
                    return RegistryKey.FromHandle(key, RegistryView.Registry64);
                }
                finally
                {
                    if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                    if (descriptor != IntPtr.Zero) LocalFree(descriptor);
                }
            }
            finally
            {
                AdjustTokenPrivileges(token, false, ref previous, 0, out _, out _);
            }
        }
    }
}
"@

function Open-TestEndpointParent {
 $original=$root.OpenSubKey($endpointBase,$false)
 if(!$original){throw 'The exact endpoint is missing.'}
 try { return [EndpointRegistryNative]::OpenForRestore($original,'',[System.Management.Automation.Language.NullString]::Value) }
 finally {$original.Dispose()}
}
$association='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0'
$speaker='{DFF21CE1-F70F-11D0-B917-00A0C9223196}'
function Restore-Test([bool]$refresh) {
 $parent=(Open-TestEndpointParent)
 if(!$parent){throw 'The selected endpoint is missing during removal.'}
 try{
  $k=$parent.OpenSubKey('FxProperties',$true)
  if($k){
   try{
    if($association -in $k.GetValueNames() -and $k.GetValue($association) -ine $speaker){throw 'The association changed during testing.'}
    Undo-Values $k
    $k.DeleteValue($association,$false)
    $empty=$k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0
   }finally{$k.Dispose()}
   if($empty){$parent.DeleteSubKey('FxProperties',$false);$parent.Flush()}
  }
 }finally{$parent.Dispose()}
 if($refresh){Restart-Audio}
 Remove-TestProfile
 if(!$empty -and $null -ne $k){throw 'Windows added other endpoint values; those were preserved.'}
}

$receiptRoot=Join-Path $program 'DSPi\APO'
$done=Join-Path $receiptRoot ('setup-'+$OperationId+'.json')
$result=[ordered]@{Endpoint=$endpointId;SessionId=$record.SessionId;Operation=$Operation;Installed=$false;RolledBack=$false;Error=$null;RecoveryError=$null}
$mutation=$false
$createdKey=$false
$refresh=$false
try{
 Assert-Endpoint
 if($Operation -eq 'Remove'){
  $ep=$root.OpenSubKey($endpointBase+'\FxProperties')
  if($ep){
   try{
    $present=$ep.GetValue($effect)
    if($present -ine $clsid){throw 'The endpoint effect has changed.'}
    if($ep.GetValue($binding) -ine $hash){throw 'The endpoint binding has changed.'}
   }finally{$ep.Dispose()}
  }
  Restore-Test $true
  $result.RolledBack=$true
  return
 }
 $ep=$root.OpenSubKey($endpointBase+'\FxProperties')
 if($ep){$ep.Dispose();throw 'This output has an effects store. Setup left it intact.'}
 if(Test-Path -LiteralPath $profile){throw 'This output already has a DSPi profile.'}
 $safety=$root.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Audio')
 try{if($safety.GetValue('DisableProtectedAudioDG') -ne 1){throw 'The local development audio configuration is unavailable.'}}finally{$safety.Dispose()}
 $com=$root.OpenSubKey('SOFTWARE\Classes\CLSID\'+$clsid+'\InprocServer32')
 $verified=$false
 $trustedHashes=@('1714F4A54ED5EB80C16FD7ABA67150F2356F0F33A56067BAEFC253B3A8A30AF2','C207F2809D90002A576A662A5A7BB85F3C8B27F73D5C4EF0E4A6EDCB21CF89AE','AC58FB436A9C6BA9C5C88A8E8C7CE02E927CA1048860492E03E53FB8059CA4AD')
 try{
  if(!$com){throw 'The local DSPi APO is not registered.'}
  $registered=[string]$com.GetValue('')
  foreach($dllHash in $trustedHashes){
   $candidate=Join-Path $program ('DSPi\APO\'+$dllHash.ToLowerInvariant()+'\dspi-apo.dll')
   if($registered -ieq $candidate -and (Get-FileHash -LiteralPath $candidate).Hash -ceq $dllHash){$verified=$true;break}
  }
  if(!$verified){throw 'The installed DSPi APO does not match a verified local build.'}
 }finally{if($com){$com.Dispose()}}
 if(@(Get-Service Audiosrv -DependentServices | Where-Object {$_.Status -eq 'Running' -and $_.Name -ne 'LightingService'}).Count){throw 'An unexpected running service depends on Windows Audio.'}

 $parent=(Open-TestEndpointParent)
 if(!$parent -or $parent.GetValue('DeviceState') -ne 1){throw 'The selected output is no longer active.'}
 try{
  $sid=$record.UserSid
  $audio='S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775'
  $profiles=Get-Item -LiteralPath (Split-Path $profile -Parent)
  if($profiles.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Profile root is a link.'}
  $profileAcl=[Security.AccessControl.DirectorySecurity]::new()
  $profileAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1301bf;;;'+$sid+')(A;OICI;0x1200a9;;;'+$audio+')')
  [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($profile),$profileAcl)
  $mutation=$true
  $telemetryAcl=[Security.AccessControl.DirectorySecurity]::new()
  $telemetryAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;'+$sid+')(A;OICI;0x1301bf;;;'+$audio+')')
  [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($telemetry),$telemetryAcl)

  if('FxProperties' -in $parent.GetSubKeyNames()){throw 'The endpoint effects key appeared during setup.'}
  $k=[EndpointRegistryNative]::OpenForRestore($parent,'FxProperties','O:SYG:SYD:P(A;;KA;;;SY)(A;;KA;;;BA)(A;;KR;;;BU)(A;;KR;;;S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775)(A;;KR;;;S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464)(A;;KR;;;S-1-5-80-1580948945-3239616721-2529237571-3761093093-1214243633)')
  $createdKey=$true
  try{
   $k.SetValue($association,$speaker,[Microsoft.Win32.RegistryValueKind]::String)
   $k.SetValue($binding,$hash,[Microsoft.Win32.RegistryValueKind]::String)
   $k.SetValue($mode,[string[]]@($defaultMode),[Microsoft.Win32.RegistryValueKind]::MultiString)
   $k.SetValue($effect,$clsid,[Microsoft.Win32.RegistryValueKind]::String)
   $k.Flush()
   if($k.GetValue($effect) -ine $clsid){throw 'The endpoint attachment could not be confirmed.'}
  }finally{$k.Dispose()}
 }finally{$parent.Dispose()}
 $refresh=$true
 Restart-Audio

 $result.Installed=$true
}catch{$result.Error=$_.Exception.Message}
finally{
 if($mutation -and !$result.Installed){
  try{if($createdKey){Restore-Test $refresh}else{Remove-TestProfile};$result.RolledBack=$true}
  catch{$result.RecoveryError=$_.Exception.Message}
 }
 $temp=$done+'.tmp'
 $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp
 [IO.File]::Move($temp,$done)
}
