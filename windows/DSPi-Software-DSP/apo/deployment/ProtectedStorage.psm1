# GPL-3.0. Administrator/SYSTEM-only recovery storage. No audio mutations.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not ('DspiSecure.Native' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DspiSecure {
public static class Native {
 [StructLayout(LayoutKind.Sequential)] struct SA {public int Length;public IntPtr Descriptor;public int Inherit;}
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint revision,out IntPtr p,out uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectory(string path,ref SA security);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,ref SA security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
 static SA Security(string text){IntPtr p;uint size;if(!ConvertStringSecurityDescriptorToSecurityDescriptor(text,1,out p,out size))throw new Win32Exception();return new SA{Length=Marshal.SizeOf(typeof(SA)),Descriptor=p};}
 public static bool Directory(string path){var s=Security("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)");try{if(CreateDirectory(path,ref s))return true;int e=Marshal.GetLastWin32Error();if(e==183)return false;throw new Win32Exception(e);}finally{LocalFree(s.Descriptor);}}
 public static void Record(string path,byte[] bytes){var s=Security("O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)");try{using(var h=CreateFile(path,0x40000000,0,ref s,1,0x80000000,IntPtr.Zero)){if(h.IsInvalid)throw new Win32Exception();using(var f=new FileStream(h,FileAccess.Write)){f.Write(bytes,0,bytes.Length);f.Flush(true);}}}finally{LocalFree(s.Descriptor);}}
 public static FileStream Lock(string path){var s=Security("O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)");try{var h=CreateFile(path,0xc0000000,0,ref s,4,0x80000000,IntPtr.Zero);if(h.IsInvalid){h.Dispose();throw new Win32Exception();}return new FileStream(h,FileAccess.ReadWrite);}finally{LocalFree(s.Descriptor);}}
}
}
'@
}
function Assert-DspiAdministrator {
 $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
 if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An elevated administrator is required.'}
}
function Assert-NoStorageLink([string]$path){
 for($walk=[IO.Path]::GetFullPath($path);$walk;$walk=Split-Path -Parent $walk){
  if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Recovery storage link rejected.'}
  if((Split-Path -Parent $walk) -eq $walk){break}
 }
}
function Get-RecoveryRoot([bool]$test){
 $programData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
 return Join-Path $programData $(if($test){'DSPi-Recovery-Tests'}else{'DSPi-Recovery'})
}
function Assert-DspiProtectedAcl {
 param([Parameter(Mandatory)][string]$Path,[switch]$File)
 Assert-NoStorageLink $Path
 $acl=Get-Acl -LiteralPath $Path
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or !$acl.AreAccessRulesProtected){throw 'Recovery ownership or inheritance is not protected.'}
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 if($rules.Count -ne 2){throw 'Unexpected recovery access rule.'}
 $seen=@{}
 foreach($rule in $rules){
  $sid=$rule.IdentityReference.Value
  $inherit=if($File){[Security.AccessControl.InheritanceFlags]::None}else{[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}
  if($sid -notin @('S-1-5-18','S-1-5-32-544') -or $seen.ContainsKey($sid) -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $rule.InheritanceFlags -ne $inherit -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None){throw 'Unexpected recovery access rule.'}
  $seen[$sid]=$true
 }
}
function Assert-DspiRecoveryDirectory([string]$directory){
 $directory=[IO.Path]::GetFullPath($directory)
 $base=Split-Path $directory -Parent
 if((Split-Path $directory -Leaf) -cnotmatch '^install-[a-f0-9]{32}$' -or $base -notin @((Get-RecoveryRoot $true),(Get-RecoveryRoot $false))){throw 'Unexpected recovery directory.'}
 Assert-DspiProtectedAcl $base;Assert-DspiProtectedAcl $directory
 return $directory
}
function New-DspiProtectedRecovery {
 param([Parameter(Mandatory)][string]$SessionId,[switch]$TestOnly)
 if($SessionId -cnotmatch '^[a-f0-9]{32}$'){throw 'SessionId must be a new GUID in lowercase N format.'}
 Assert-DspiAdministrator
 $base=Get-RecoveryRoot ([bool]$TestOnly);Assert-NoStorageLink $base
 $baseCreated=[DspiSecure.Native]::Directory($base);Assert-DspiProtectedAcl $base
 $path=Join-Path $base ('install-'+$SessionId)
 if(![DspiSecure.Native]::Directory($path)){throw 'Recovery session already exists.'}
 Assert-DspiProtectedAcl $path
 [pscustomobject]@{Directory=$path;BaseCreated=$baseCreated;TestOnly=[bool]$TestOnly;SessionId=$SessionId}
}
function Record-Path([string]$directory,[string]$name){
 if($name -cnotmatch '^[a-z][a-z0-9-]{0,70}\.json$'){throw 'Record name must be a simple JSON filename.'}
 $directory=Assert-DspiRecoveryDirectory $directory
 $path=Join-Path $directory $name;Assert-NoStorageLink $path;return $path
}
function Write-DspiProtectedRecord {
 param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Value,[string]$ExpectedSHA256)
 Assert-DspiAdministrator
 $path=Record-Path $Directory $Name
 # Reject incomplete/oversized serialization before creating even a lock file.
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 40 -Compress -WarningAction Stop))
 if($bytes.Length -gt 1048576){throw 'Recovery record exceeds one MiB.'}
 $lockPath=$path+'.lock';Assert-NoStorageLink $lockPath
 $lock=[DspiSecure.Native]::Lock($lockPath)
 try{
 Assert-DspiProtectedAcl $lockPath -File
 $exists=Test-Path -LiteralPath $path
 if($exists){Assert-DspiProtectedAcl $path -File;if(!$ExpectedSHA256 -or (Get-FileHash -LiteralPath $path).Hash -cne $ExpectedSHA256){throw 'Recovery record changed or overwrite was not expected.'}}
 elseif($ExpectedSHA256){throw 'Expected recovery record is absent.'}
 $temp=Join-Path $Directory ('record-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  [DspiSecure.Native]::Record($temp,$bytes);Assert-DspiProtectedAcl $temp -File
  if($exists){[IO.File]::Replace($temp,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$path)}
  Assert-DspiProtectedAcl $path -File
 }finally{if(Test-Path -LiteralPath $temp){Assert-DspiProtectedAcl $temp -File;[IO.File]::Delete($temp)}}
 (Get-FileHash -LiteralPath $path).Hash
 }finally{$lock.Dispose()}
}
function Read-DspiProtectedRecord {
 param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Name)
 $path=Record-Path $Directory $Name;Assert-DspiProtectedAcl $path -File
 if((Get-Item -LiteralPath $path).Length -gt 1048576){throw 'Oversized recovery record.'}
 Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
function Remove-DspiProtectedTestRecovery {
 param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][hashtable]$ExpectedRecords)
 Assert-DspiAdministrator
 if(!$Session.TestOnly){throw 'Only explicitly marked test sessions may be removed by this helper.'}
 $path=Assert-DspiRecoveryDirectory $Session.Directory
 if((Split-Path $path -Parent) -cne (Get-RecoveryRoot $true)){throw 'Not a test recovery directory.'}
 $children=@(Get-ChildItem -LiteralPath $path -Force)
 if($children.Count -ne $ExpectedRecords.Count*2){throw 'Unexpected child in recovery test session.'}
 foreach($child in $children){
  if($child.PSIsContainer){throw 'Unexpected child in recovery test session.'};Assert-DspiProtectedAcl $child.FullName -File
  if($ExpectedRecords.ContainsKey($child.Name)){if((Get-FileHash -LiteralPath $child.FullName).Hash -cne $ExpectedRecords[$child.Name]){throw 'Recovery test record changed.'}}
  elseif($child.Name.EndsWith('.lock') -and $ExpectedRecords.ContainsKey($child.Name.Substring(0,$child.Name.Length-5)) -and $child.Length -eq 0){}
  else{throw 'Unexpected child in recovery test session.'}
 }
 foreach($child in $children){[IO.File]::Delete($child.FullName)}
 [IO.Directory]::Delete($path,$false)
 $base=Split-Path $path -Parent
 if($Session.BaseCreated -and @(Get-ChildItem -LiteralPath $base -Force).Count -eq 0){Assert-DspiProtectedAcl $base;[IO.Directory]::Delete($base,$false)}
}
Export-ModuleMember -Function Assert-DspiAdministrator,Assert-DspiProtectedAcl,New-DspiProtectedRecovery,Write-DspiProtectedRecord,Read-DspiProtectedRecord,Remove-DspiProtectedTestRecovery
