# GPL-3.0. Source-generated machine mutations and protected recovery authority.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProtectedStorage.psm1')
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1')
if(-not ('DspiMachine.Native' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'MachineNative.cs')}
$audioSid='S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775'
$script:Recovering=$false
function Clone($v){ConvertFrom-Json (ConvertTo-Json -InputObject $v -Depth 35 -Compress -WarningAction Stop)}
function Json($v){ConvertTo-Json -InputObject $v -Depth 35 -Compress -WarningAction Stop}
function No-Link([string]$p){
 for($w=[IO.Path]::GetFullPath($p);$w;$w=Split-Path -Parent $w){if((Test-Path -LiteralPath $w) -and ((Get-Item -LiteralPath $w -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Machine resource link rejected.'};if((Split-Path -Parent $w) -eq $w){break}}
}
function Security-Form([string]$sddl){
 $raw=[Security.AccessControl.RawSecurityDescriptor]::new($sddl)
 if(($raw.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -eq 0){throw 'Unprotected machine resource ACL.'}
 $aces=@(foreach($ace in $raw.DiscretionaryAcl){
  if($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed){throw 'Unexpected ACL entry.'}
  $mask=[long]$ace.AccessMask -band 4294967295L;$mapped=$mask -band 268435455L
  if($mask -band 2147483648L){$mapped=$mapped -bor 0x120089};if($mask -band 1073741824L){$mapped=$mapped -bor 0x120116};if($mask -band 536870912L){$mapped=$mapped -bor 0x1200a0};if($mask -band 268435456L){$mapped=$mapped -bor 0x1f01ff}
  $ace.SecurityIdentifier.Value+':'+$mapped+':'+[int]$ace.AceFlags
 }) | Sort-Object
 return $raw.Owner.Value+'|'+$raw.Group.Value+'|'+($aces -join '|')
}
function Check-Security($actual,$expected){if((Security-Form $actual) -cne (Security-Form $expected)){throw 'Machine resource permissions changed.'}}
function Check-SharedKey($key){
 $acl=[Microsoft.Win32.RegistryAclExtensions]::GetAccessControl($key)
 $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Shared registry owner is not trusted.'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($rule.AccessControlType -eq 'Allow' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and ([int]$rule.RegistryRights -band 0xd0006) -ne 0 -and $rule.IdentityReference.Value -notin $trusted){throw 'Shared registry location grants untrusted write access.'}
 }
}
function Directory-Sddl([string]$extra=''){return 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'+$extra}
function Registry-Sddl {return 'O:BAG:BAD:P(A;CI;KA;;;SY)(A;CI;KA;;;BA)(A;CI;KR;;;BU)(A;CI;KR;;;'+$audioSid+')'}
function File-Sddl {return 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)(A;;FRFX;;;'+$audioSid+')'}
function Inbox-Values($c){@($c.Plan.InterfaceValues | Where-Object Name -notin @('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7','{d3993a3f-99c2-4402-b5ec-a92a0367664b},7','{67fe7ad1-1232-4c16-94ce-83a4f63be981},1') | Sort-Object Name)}
function Check-Inbox($c,$root){
 $key=$root.OpenSubKey('MSFX\0',$false);if(!$key){throw 'Inspected Windows speaker effect store disappeared.'}
 try{Check-SharedKey $key;if(!(Equal @(Values $key) @(Inbox-Values $c))){throw 'Windows speaker effects changed since inspection.'}}finally{$key.Dispose()}
}
function Assert-Context($c){
 Assert-DspiAdministrator
 if($c.SchemaVersion -ne 1 -or $c.Id -cnotmatch '^[a-f0-9]{32}$' -or $c.Plan.Scope.ProfileKey -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid machine context.'}
 if($c.Mode -eq 'Fixture'){
  if((Split-Path ([IO.Path]::GetFullPath($c.Workspace)) -Leaf) -cne 'DSPi-Software-DSP'){throw 'Unexpected fixture workspace.'}
  $base=Join-Path (Join-Path $c.Workspace build) ('machine-fixture-'+$c.Id)
  if($c.Base -cne $base -or $c.Program -cne (Join-Path $base 'Program') -or $c.Data -cne (Join-Path $base 'Data') -or $c.RegistryPath -cne ('Software\DSPi-Machine-Tests\'+$c.Id)){throw 'Fixture context escaped its namespace.'}
 }elseif($c.Mode -eq 'Machine'){
  if($c.Program -cne (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'DSPi') -or $c.Data -cne (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'DSPi')){throw 'Machine roots differ from system roots.'}
 }else{throw 'Unknown backend mode.'}
 foreach($p in @($c.Program,$c.Data)){No-Link $p}
 if($c.UserSid -cnotmatch '^S-1-5-21-[0-9-]+$'){throw 'Installing user SID must be an explicit local/domain user.'}
}
function New-DspiBackendContext {
 param($Target,$Mapping,[string]$DllPath,[string]$UserSid,[switch]$LocalDevelopmentTest,[switch]$EndpointStore)
 Assert-DspiAdministrator
 $plan=New-DspiScopedAttachment -Target $Target -Mapping $Mapping
 $dll=[IO.Path]::GetFullPath($DllPath);No-Link $dll
 if((Get-FileHash -LiteralPath $dll).Hash -cne $plan.Binary.SHA256){throw 'Backend refuses a changed DLL.'}
 if($LocalDevelopmentTest){Assert-DevelopmentScope $plan}else{
  if((Get-AuthenticodeSignature -LiteralPath $dll).Status -ne 'Valid'){throw 'Backend refuses an unsigned/untrusted DLL.'}
 }
 $os=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
 if(![Environment]::Is64BitProcess -or $os.CurrentBuildNumber -ne '19045'){throw 'This backend is limited to Windows10 x64 build19045.'}
 $c=[pscustomobject]@{SchemaVersion=1;Mode='Machine';Id=[guid]::NewGuid().ToString('N');Base=$null;Program=(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'DSPi');Data=(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'DSPi');RegistryPath=$null;Dll=$dll;UserSid=$UserSid;Plan=$plan}
 Assert-Context $c
 $operations=@(Get-DspiMachineOperations $c)
 $profileOp=@($operations | Where-Object {$_.Kind -eq 'Directory' -and $_.Path -eq (Join-Path $c.Data ('Profiles\'+$c.Plan.Scope.ProfileKey))})[0]
 $telemetryOp=@($operations | Where-Object {$_.Kind -eq 'Directory' -and $_.Path.EndsWith('\telemetry')})[0]
 $probes=@(Get-Process -Name audiodg -ErrorAction SilentlyContinue | ForEach-Object {
  [pscustomobject]@{Id=$_.Id;Profile=[DspiMachine.Native]::AudioAccessResult($_.Id,$profileOp.Sddl,0x1200a9,[bool]$LocalDevelopmentTest);Telemetry=[DspiMachine.Native]::AudioAccessResult($_.Id,$telemetryOp.Sddl,0x120116);Dll=[DspiMachine.Native]::AudioAccessResult($_.Id,(File-Sddl),0x1200a9)}
 })
 $verified=@($probes | Where-Object {$_.Profile -eq 'Allowed' -and $_.Telemetry -eq 'Allowed' -and $_.Dll -eq 'Allowed'})
 if(!$verified.Count){throw ('No actual audiodg token passed profile-read, telemetry-write and DLL-read/execute access checks. Results: '+(Json $probes))}
 $c | Add-Member -NotePropertyName AccessVerifiedProcessIds -NotePropertyValue @($verified | ForEach-Object Id)
 $c | Add-Member -NotePropertyName LocalDevelopmentTest -NotePropertyValue ([bool]$LocalDevelopmentTest)
 if($EndpointStore){
  if(!$LocalDevelopmentTest){throw 'Endpoint-store attachment is restricted to the local development test.'}
  $c | Add-Member -NotePropertyName EndpointStore -NotePropertyValue $true
  $c | Add-Member -NotePropertyName EndpointStoreSddl -NotePropertyValue $Target.BeforeState.FxSnapshot.Sddl
  $key=Open-EndpointStore $c $true
  $key.Dispose()
 }
 foreach($which in @('Classes','Interface')){$key=Open-Root $c $which $true;$key.Dispose()}
 return $c
}
function Assert-DevelopmentScope($plan){
 if($plan.Scope.EndpointId -ine '{0.0.0.00000000}.{7903955c-abce-4f0a-8cd8-249a73bc348f}' -or
    $plan.Scope.FunctionInstanceId -ine 'USB\VID_2E8B&PID_FEAA&MI_00\7&3758099E&1&0000' -or
    $plan.Binary.SHA256 -notin @('49ADB1FE44B886E32588A11A33FFF37540256D4F7132311F0611EAD5C37C84FC','30F9FB4B0EAB750357D96B80F3B51F62524A681AA42FC4F012D9F39D9309B84C','7609B130E836391CA504CBCAD554937E9A17901E25205DDB38AAEEA4342D9536','1714F4A54ED5EB80C16FD7ABA67150F2356F0F33A56067BAEFC253B3A8A30AF2')){
  throw 'Development test is restricted to the approved DSPi USB output and tested DLL.'
 }
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Audio',$false)
 try {
  if(!$key -or $key.GetValue('DisableProtectedAudioDG') -ne 1 -or $key.GetValueKind('DisableProtectedAudioDG') -ne 'DWord'){
   throw 'The existing audio development setting is unavailable.'
  }
 }finally{if($key){$key.Dispose()}}
}
function New-DspiBackendFixture {
 param($Target,$Mapping,[string]$DllPath)
 Assert-DspiAdministrator
 $plan=New-DspiScopedAttachment -Target $Target -Mapping $Mapping
 $id=[guid]::NewGuid().ToString('N');$base=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build'))) ('machine-fixture-'+$id)
 $c=[pscustomobject]@{SchemaVersion=1;Mode='Fixture';Workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'));Id=$id;Base=$base;Program=(Join-Path $base 'Program');Data=(Join-Path $base 'Data');RegistryPath=('Software\DSPi-Machine-Tests\'+$id);Dll=[IO.Path]::GetFullPath($DllPath);UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Plan=$plan}
 Assert-Context $c
 if((Get-FileHash -LiteralPath $c.Dll).Hash -cne $plan.Binary.SHA256){throw 'Fixture DLL differs from target.'}
 [DspiMachine.Native]::Directory($base,(Directory-Sddl '(A;OICI;GRGX;;;BU)'))
 $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($c.RegistryPath)
 try{foreach($name in @('Classes','Interface')){$child=[DspiMachine.Native]::Key($key,$name,(Registry-Sddl));$child.Dispose()};$iface=$key.OpenSubKey('Interface',$true);try{$msfx=[DspiMachine.Native]::Key($iface,'MSFX',(Registry-Sddl));try{$speaker=[DspiMachine.Native]::Key($msfx,'0',(Registry-Sddl));try{Set-Values $speaker @(Inbox-Values $c)}finally{$speaker.Dispose()}}finally{$msfx.Dispose()}}finally{$iface.Dispose()}}finally{$key.Dispose()}
 return $c
}
function Open-Root($c,[string]$which,[bool]$write){
 Assert-Context $c
 if($c.Mode -eq 'Fixture'){return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($c.RegistryPath+'\'+$(if($which -eq 'Interface'){'Interface'}else{'Classes'}),$write)}
 if($which -eq 'Interface'){$key=[DspiMachine.Native]::Interface($c.Plan.Scope.InterfacePath,$c.Plan.Scope.FunctionInstanceId,$write,(!$script:Recovering));try{Check-SharedKey $key;return $key}catch{$key.Dispose();throw}}
 $hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
 try{$key=$hive.OpenSubKey('SOFTWARE\Classes',$false)}finally{$hive.Dispose()}
 try{Check-SharedKey $key;return $key}catch{$key.Dispose();throw}
}
function Get-DspiMachineOperations($c){
 Assert-Context $c
 $ops=[Collections.Generic.List[object]]::new()
 $read='(A;OICI;GRGX;;;BU)';$profile='(A;OICI;0x1301bf;;;'+$c.UserSid+')(A;OICI;0x1200a9;;;'+$audioSid+')';$telemetry='(A;OICI;GRGX;;;'+$c.UserSid+')(A;OICI;0x1301bf;;;'+$audioSid+')'
 foreach($d in @(@($c.Program,$read),@((Join-Path $c.Program 'APO'),$read),@((Join-Path $c.Program ('APO\'+$c.Plan.Binary.SHA256.ToLowerInvariant())),$read),@($c.Data,$read),@((Join-Path $c.Data 'Profiles'),$read),@((Join-Path $c.Data ('Profiles\'+$c.Plan.Scope.ProfileKey)),$profile),@((Join-Path $c.Data ('Profiles\'+$c.Plan.Scope.ProfileKey+'\telemetry')),$telemetry))){$ops.Add([pscustomobject]@{Kind='Directory';Path=$d[0];Sddl=(Directory-Sddl $d[1]);Shared=($d[0] -ieq $c.Program -or $d[0] -ieq (Join-Path $c.Program 'APO') -or $d[0] -ieq $c.Data -or $d[0].StartsWith($c.Data+'\',[StringComparison]::OrdinalIgnoreCase))})}
 $binary=Join-Path $c.Program ('APO\'+$c.Plan.Binary.SHA256.ToLowerInvariant()+'\dspi-apo.dll')
 $ops.Add([pscustomobject]@{Kind='File';Path=$binary;SHA256=$c.Plan.Binary.SHA256;Sddl=(File-Sddl)})
 # Shared registry ancestors are independently journaled; none are recursively created.
 foreach($p in @('CLSID','AudioEngine','AudioEngine\AudioProcessingObjects')){$ops.Add([pscustomobject]@{Kind='Key';Root='Classes';Path=$p;Sddl=(Registry-Sddl);Shared=$true})}
 $clsid='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
 foreach($tree in @(@('CLSID\'+$clsid),@('AudioEngine\AudioProcessingObjects\'+$clsid))){
  $prefix=[string]$tree;$nodes=@(foreach($key in @($c.Plan.ComValues.Key | Where-Object {$_ -eq $prefix -or $_.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)} | Sort-Object -Unique)){
   [pscustomobject]@{Path=$key.Substring($prefix.Length).TrimStart('\');Values=@(foreach($v in @($c.Plan.ComValues | Where-Object Key -eq $key | Sort-Object Name)){
    [pscustomobject]@{Name=$v.Name;Kind=$v.Kind;Value=$(if($v.Key.EndsWith('\InprocServer32') -and $v.Name -eq ''){$binary}else{$v.Value})}
   })}
  })
  $ops.Add([pscustomobject]@{Kind='Tree';Root='Classes';Path=$prefix;Nodes=$nodes;Sddl=(Registry-Sddl)})
 }
 if($c.PSObject.Properties['EndpointStore'] -and $c.EndpointStore){
  $names=@('{67fe7ad1-1232-4c16-94ce-83a4f63be981},1','{d3993a3f-99c2-4402-b5ec-a92a0367664b},7','{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7')
  foreach($name in $names){
   $value=@($c.Plan.InterfaceValues | Where-Object Name -eq $name)
   if($value.Count -ne 1){throw 'Incomplete DSPi endpoint values.'}
   $ops.Add([pscustomobject]@{Kind='EndpointValue';Name=$name;Data=$value[0]})
  }
 }else{
  $ops.Add([pscustomobject]@{Kind='Tree';Root='Interface';Path='FX';Nodes=@([pscustomobject]@{Path='';Values=@()},[pscustomobject]@{Path='0';Values=@($c.Plan.InterfaceValues | Sort-Object Name)});Sddl=(Registry-Sddl)})
 }
 for($i=0;$i -lt $ops.Count;$i++){$ops[$i] | Add-Member -NotePropertyName Id -NotePropertyValue ('resource-'+$i)}
 return $ops.ToArray()
}
function Key-Parent($root,[string]$path,[bool]$write){
 $index=$path.LastIndexOf('\');if($index -lt 0){return [pscustomobject]@{Key=$root;Leaf=$path;Owns=$false}}
 $parent=$root.OpenSubKey($path.Substring(0,$index),$write);if(!$parent){throw 'Registry parent is unavailable.'}
 [pscustomobject]@{Key=$parent;Leaf=$path.Substring($index+1);Owns=$true}
}
function Key-Sddl($key){([Microsoft.Win32.RegistryAclExtensions]::GetAccessControl($key)).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Owner,Group,Access')}
function Open-EndpointStore($c,[bool]$write){
 if($c.Mode -ne 'Machine' -or !$c.LocalDevelopmentTest -or $c.Plan.Scope.EndpointId -ine '{0.0.0.00000000}.{7903955c-abce-4f0a-8cd8-249a73bc348f}'){
  throw 'Endpoint store is outside the approved development scope.'
 }
 $path='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{7903955c-abce-4f0a-8cd8-249a73bc348f}\FxProperties'
 $rights=[Security.AccessControl.RegistryRights]::ReadKey
 $mode=[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree
 if($write){$rights=$rights -bor [Security.AccessControl.RegistryRights]::SetValue;$mode=[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree}
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path,$mode,$rights)
 if(!$key){throw 'Selected playback endpoint effects key is unavailable.'}
 try{
  if((Key-Sddl $key) -cne $c.EndpointStoreSddl){throw 'Selected endpoint permissions changed.'}
  return $key
 }catch{$key.Dispose();throw}
}
function Values($key){
 @(foreach($name in @($key.GetValueNames() | Sort-Object)){$kind=$key.GetValueKind($name).ToString();$value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($kind -eq 'DWord'){$value=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$value),0)};[pscustomobject]@{Name=$name;Kind=$kind;Value=$value}})
}
function Tree-Nodes($key,[string]$sddl,[string]$relative='',[int]$depth=0){
 if($depth -gt 3 -or $key.ValueCount -gt 40 -or $key.SubKeyCount -gt 8){throw 'Registry tree exceeds backend bounds.'}
 Check-Security (Key-Sddl $key) $sddl
 [pscustomobject]@{Path=$relative;Values=@(Values $key)}
 foreach($name in @($key.GetSubKeyNames() | Sort-Object)){$child=$key.OpenSubKey($name,$false);try{Tree-Nodes $child $sddl $(if($relative){$relative+'\'+$name}else{$name}) ($depth+1)}finally{$child.Dispose()}}
}
function Read-Resource($c,$op){
 if($op.Kind -eq 'EndpointValue'){
  $key=Open-EndpointStore $c $false
  try{
   if($op.Name -notin $key.GetValueNames()){return [pscustomobject]@{Exists=$false}}
   return [pscustomobject]@{Exists=$true;Data=[pscustomobject]@{Name=$op.Name;Kind=$key.GetValueKind($op.Name).ToString();Value=$key.GetValue($op.Name)}}
  }finally{$key.Dispose()}
 }
 if($op.Kind -in @('Directory','File')){
  No-Link $op.Path;if(!(Test-Path -LiteralPath $op.Path)){return [pscustomobject]@{Exists=$false}}
  Check-Security (Get-Acl -LiteralPath $op.Path).Sddl $op.Sddl
  if($op.Kind -eq 'Directory'){if(!(Test-Path -LiteralPath $op.Path -PathType Container)){throw 'Expected directory.'};return [pscustomobject]@{Exists=$true}}
  if(!(Test-Path -LiteralPath $op.Path -PathType Leaf)){throw 'Expected file.'};return [pscustomobject]@{Exists=$true;SHA256=(Get-FileHash -LiteralPath $op.Path).Hash}
 }
 $root=Open-Root $c $op.Root $false
 try{$key=$root.OpenSubKey($op.Path,$false);if(!$key){return [pscustomobject]@{Exists=$false}};try{
  if($op.Kind -eq 'Key'){if($op.Shared){Check-SharedKey $key}else{Check-Security (Key-Sddl $key) $op.Sddl};return [pscustomobject]@{Exists=$true}}
  [pscustomobject]@{Exists=$true;Nodes=@(Tree-Nodes $key $op.Sddl)}
 }finally{$key.Dispose()}}finally{$root.Dispose()}
}
function Expected($op){if($op.Kind -eq 'EndpointValue'){return [pscustomobject]@{Exists=$true;Data=$op.Data}};if($op.Kind -eq 'File'){return [pscustomobject]@{Exists=$true;SHA256=$op.SHA256}};if($op.Kind -eq 'Tree'){return [pscustomobject]@{Exists=$true;Nodes=$op.Nodes}};[pscustomobject]@{Exists=$true}}
function Equal($a,$b){(Json $a) -ceq (Json $b)}
function Set-Values($key,$values){
 foreach($v in $values){$data=switch($v.Kind){'DWord'{[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$v.Value),0);break};'MultiString'{[string[]]@($v.Value);break};'String'{[string]$v.Value;break};'ExpandString'{[string]$v.Value;break};default{throw 'Unsupported registration type.'}};if($v.Kind -eq 'MultiString'){$data=[string[]]@($v.Value)};$key.SetValue($v.Name,$data,[Microsoft.Win32.RegistryValueKind]$v.Kind)};$key.Flush()
}
function Stage-Name($entry){return 'dspi-stage-'+$entry.Token}
function Write-Resource($c,$entry,[bool]$failStage=$false,[bool]$crashStage=$false){
 $op=$entry.Operation
 if($op.Kind -eq 'EndpointValue'){
  $key=Open-EndpointStore $c $true
  try{if($op.Name -in $key.GetValueNames()){throw 'Endpoint value became occupied.'};Set-Values $key @($op.Data)}finally{$key.Dispose()}
  return
 }
 if($op.Kind -eq 'Directory'){[DspiMachine.Native]::Directory($op.Path,$op.Sddl);return}
 if($op.Kind -eq 'File'){
  $source=[IO.File]::Open($c.Dll,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{if($source.Length -gt 2097152 -or $source.Length -lt 128){throw 'Native DLL exceeds backend bounds.'};$bytes=[byte[]]::new([int]$source.Length);$source.ReadExactly($bytes,0,$bytes.Length)}finally{$source.Dispose()}
  $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
  if($hash -cne $op.SHA256){throw 'DLL changed before copying.'}
  $stage=$op.Path+'.'+$entry.Token+'.tmp';No-Link $stage
  [DspiMachine.Native]::File($stage,$bytes,$op.Sddl);if($crashStage){[Environment]::Exit(29)};if($failStage){throw 'Injected staged file interruption.'};[IO.File]::Move($stage,$op.Path);return
 }
 $root=Open-Root $c $op.Root $true
 try{$parent=Key-Parent $root $op.Path $true;try{
  if($op.Root -eq 'Interface'){Check-Inbox $c $root}
  if($op.Kind -eq 'Key'){$key=[DspiMachine.Native]::Key($parent.Key,$parent.Leaf,$op.Sddl);$key.Dispose();return}
  $stage=Stage-Name $entry;$key=[DspiMachine.Native]::Key($parent.Key,$stage,$op.Sddl)
  try{foreach($node in $op.Nodes){if(!$node.Path){Set-Values $key $node.Values}else{if($node.Path.Contains('\')){throw 'Only one-level staged nodes supported.'};$child=[DspiMachine.Native]::Key($key,$node.Path,$op.Sddl);try{Set-Values $child $node.Values}finally{$child.Dispose()}};if($crashStage){[Environment]::Exit(29)};if($failStage){throw 'Injected staged registry interruption.'}}}finally{$key.Dispose()}
  [DspiMachine.Native]::Rename($parent.Key,$stage,$parent.Leaf)
 }finally{if($parent.Owns){$parent.Key.Dispose()}}}finally{$root.Dispose()}
}
function Remove-Tree($parent,[string]$leaf,$op){
 $key=$parent.OpenSubKey($leaf,$true);if(!$key){return}
 try{
  $actual=@(Tree-Nodes $key $op.Sddl)
  # Partial staging may contain only an unchanged subset of intended values.
  foreach($node in $actual){$wanted=@($op.Nodes | Where-Object Path -eq $node.Path);if($wanted.Count -ne 1){throw 'Unknown staged registry child.'};foreach($v in $node.Values){$match=@($wanted[0].Values | Where-Object Name -eq $v.Name);if($match.Count -ne 1 -or !(Equal $v $match[0])){throw 'Staged registry value changed.'}}}
  foreach($node in @($actual | Sort-Object {$_.Path.Length} -Descending)){
   $child=if($node.Path){$key.OpenSubKey($node.Path,$true)}else{$key}
   try{foreach($name in @($child.GetValueNames())){$child.DeleteValue($name,$false)};if($child.SubKeyCount){throw 'Registry deletion order conflict.'}}finally{if($node.Path){$child.Dispose()}}
   if($node.Path){$key.DeleteSubKey($node.Path,$false)}
  }
 }finally{$key.Dispose()}
 $parent.DeleteSubKey($leaf,$false);$parent.Flush()
}
function Check-PartialTree($key,$op){
 $nodes=@(Tree-Nodes $key $op.Sddl)
 foreach($node in $nodes){$wanted=@($op.Nodes | Where-Object Path -eq $node.Path);if($wanted.Count -ne 1){throw 'Unknown staging node.'};foreach($v in $node.Values){$match=@($wanted[0].Values | Where-Object Name -eq $v.Name);if($match.Count -ne 1 -or !(Equal $v $match[0])){throw 'Staged value conflict; nothing removed.'}}}
}
function Runtime-File($c,$directory,$child){
 $profile=Join-Path $c.Data ('Profiles\'+$c.Plan.Scope.ProfileKey)
 if($child.PSIsContainer){return $false}
 if($directory -ieq $profile){return ($child.Name -in @('profile.bin','profile.writer.lock','rta-control.bin') -or $child.Name -cmatch '^(profile|rta-control)\.[a-f0-9]{32}\.tmp$')}
 if($directory -ieq (Join-Path $profile telemetry)){return $child.Name -cmatch '^(status|spectrum)-[0-9]{1,10}-[0-9]{1,10}\.bin(\.tmp)?$'}
 return $false
}
function Retained-Data($c){
 $result=@{};$profile=Join-Path $c.Data ('Profiles\'+$c.Plan.Scope.ProfileKey)
 foreach($directory in @($profile,(Join-Path $profile telemetry))){
  No-Link $directory
  if(!(Test-Path -LiteralPath $directory -PathType Container)){continue}
  $hasData=@(Get-ChildItem -LiteralPath $directory -Force | Where-Object {Runtime-File $c $directory $_}).Count -gt 0
  if($hasData){for($parent=$directory;$parent -and ($parent -ieq $c.Data -or $parent.StartsWith($c.Data+'\',[StringComparison]::OrdinalIgnoreCase));$parent=Split-Path $parent -Parent){$result[$parent]=$true}}
 }
 return $result
}
function Check-OwnedChildren($c,$e,$entries){
 $op=$e.Operation
 if($e.State -in @('Restored','Retained','Unchanged')){return}
 if($op.Kind -eq 'Directory' -and (Test-Path -LiteralPath $op.Path)){
  $known=@($entries | Where-Object {$_.Operation.Kind -in @('Directory','File')} | ForEach-Object {$_.Operation.Path})
  $known+=@($entries | Where-Object {$_.Operation.Kind -eq 'File' -and $_.State -in @('Intent','UndoIntent')} | ForEach-Object {$_.Operation.Path+'.'+$_.Token+'.tmp'})
  foreach($child in Get-ChildItem -LiteralPath $op.Path -Force){if(Runtime-File $c $op.Path $child){continue};No-Link $child.FullName;if($child.FullName -notin $known){throw 'Unowned directory content; nothing removed.'}}
 }
 if($op.Kind -eq 'File'){
  $stage=$op.Path+'.'+$e.Token+'.tmp';No-Link $stage
  if(Test-Path -LiteralPath $stage){if($e.State -notin @('Intent','UndoIntent')){throw 'Unowned file stage.'};Check-Security (Get-Acl -LiteralPath $stage).Sddl $op.Sddl}
 }
 if($op.Kind -in @('Key','Tree')){
  $root=Open-Root $c $op.Root $false
  try{
   if($op.Kind -eq 'Key'){
    $key=$root.OpenSubKey($op.Path,$false)
    if($key){try{
     if($key.ValueCount){throw 'Unowned container registry value; nothing removed.'}
     $known=@($entries | Where-Object {$_.Operation.Kind -in @('Key','Tree') -and $_.Operation.Root -eq $op.Root} | ForEach-Object {$_.Operation.Path})
     $stages=@($entries | Where-Object {$_.Operation.Kind -eq 'Tree' -and $_.Operation.Root -eq $op.Root -and $_.State -in @('Intent','UndoIntent')} | ForEach-Object {$(if($_.Operation.Path.Contains('\')){$_.Operation.Path.Substring(0,$_.Operation.Path.LastIndexOf('\'))+'\'}else{''})+(Stage-Name $_)})
     foreach($name in $key.GetSubKeyNames()){if(($op.Path+'\'+$name) -notin ($known+$stages)){throw 'Unowned container registry child; nothing removed.'}}
    }finally{$key.Dispose()}}
   }else{
    $parent=Key-Parent $root $op.Path $false
    try{$stage=$parent.Key.OpenSubKey((Stage-Name $e),$false);if($stage){try{if($e.State -notin @('Intent','UndoIntent')){throw 'Unowned registry stage.'};Check-PartialTree $stage $op}finally{$stage.Dispose()}}}finally{if($parent.Owns){$parent.Key.Dispose()}}
   }
  }finally{$root.Dispose()}
 }
}
function Remove-Resource($c,$entry){
 $op=$entry.Operation
 if($op.Kind -eq 'EndpointValue'){
  $key=Open-EndpointStore $c $true
  try{
   if(!(Equal (Read-Resource $c $op) $entry.After)){throw 'Endpoint value changed before removal.'}
   $key.DeleteValue($op.Name,$true)
   $key.Flush()
  }finally{$key.Dispose()}
  return
 }
 if($op.Kind -eq 'File'){$stage=$op.Path+'.'+$entry.Token+'.tmp';No-Link $stage;if(Test-Path -LiteralPath $stage){Check-Security (Get-Acl -LiteralPath $stage).Sddl $op.Sddl;[IO.File]::Delete($stage)};if(Test-Path -LiteralPath $op.Path){[IO.File]::Delete($op.Path)};return}
 if($op.Kind -eq 'Directory'){[IO.Directory]::Delete($op.Path,$false);return}
 $root=Open-Root $c $op.Root $true
 try{$parent=Key-Parent $root $op.Path $true;try{
  if($op.Kind -eq 'Key'){$key=$parent.Key.OpenSubKey($parent.Leaf,$false);if(!$key){return};try{if($key.ValueCount -or $key.SubKeyCount){throw 'Shared registry key contains new data.'}}finally{$key.Dispose()};$parent.Key.DeleteSubKey($parent.Leaf,$false);return}
  $stage=Stage-Name $entry
  $current=$parent.Key.OpenSubKey($parent.Leaf,$false)
  if($current){$current.Dispose();[DspiMachine.Native]::Rename($parent.Key,$parent.Leaf,$stage)}
  Remove-Tree $parent.Key $stage $op
 }finally{if($parent.Owns){$parent.Key.Dispose()}}}finally{$root.Dispose()}
}
function Save-Journal($session,$journal,[ref]$hash){$hash.Value=Write-DspiProtectedRecord -Directory $session.Directory -Name backend.json -Value $journal -ExpectedSHA256 $hash.Value}
function Lease($session){
 $path=Join-Path $session.Directory 'lease.json'
 if(!(Test-Path -LiteralPath $path)){$null=Write-DspiProtectedRecord -Directory $session.Directory -Name lease.json -Value @{SessionId=$session.SessionId}}
 if((Read-DspiProtectedRecord -Directory $session.Directory -Name lease.json).SessionId -cne $session.SessionId){throw 'Recovery session identity changed.'}
 $stream=[DspiSecure.Native]::Lock($path+'.lock');Assert-DspiProtectedAcl ($path+'.lock') -File;return $stream
}
function Check-Session($session){
 $directory=& (Get-Module ProtectedStorage) {param($p) Assert-DspiRecoveryDirectory $p} $session.Directory
 if($session.SessionId -cnotmatch '^[a-f0-9]{32}$' -or (Split-Path $directory -Leaf) -cne ('install-'+$session.SessionId)){throw 'Recovery session identity mismatch.'}
 $parent=Split-Path $directory -Parent
 $expected=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) $(if($session.TestOnly){'DSPi-Recovery-Tests'}else{'DSPi-Recovery'})
 if($parent -cne $expected){throw 'Recovery session mode mismatch.'}
}
function Global-Lease($session){
 Check-Session $session
 if($session.TestOnly){return $null}
 $base=Split-Path $session.Directory -Parent;Assert-DspiProtectedAcl $base
 $path=Join-Path $base machine.lock;No-Link $path
 $lock=[DspiSecure.Native]::Lock($path);try{Assert-DspiProtectedAcl $path -File;return $lock}catch{$lock.Dispose();throw}
}
function Check-OtherSessions($session){
 if($session.TestOnly){return}
 foreach($directory in Get-ChildItem -LiteralPath (Split-Path $session.Directory -Parent) -Directory -Force){
  if($directory.FullName -ieq $session.Directory){continue}
  if($directory.Name -cnotmatch '^install-[a-f0-9]{32}$'){throw 'Unknown production recovery directory requires inspection.'}
  Assert-DspiProtectedAcl $directory.FullName
  $path=Join-Path $directory.FullName backend.json
  if(Test-Path -LiteralPath $path){$other=Read-DspiProtectedRecord -Directory $directory.FullName -Name backend.json;if($other.State -ne 'RolledBack'){throw 'Another installation or pending recovery exists; finish its protected recovery before reinstalling.'}}
 }
}
function Install-DspiRecoveryBundle {
 param($Session)
 Assert-DspiAdministrator
 Check-Session $Session
 $tools=Join-Path $Session.Directory tools;No-Link $tools
 # Validate the session through the protected record API before creating tools.
 $null=Write-DspiProtectedRecord -Directory $Session.Directory -Name bundle.json -Value @{SchemaVersion=1;State='Preparing';Files=@()}
 [DspiMachine.Native]::Directory($tools,(Directory-Sddl))
 $files=@(foreach($name in @('ProtectedStorage.psm1','Recovery.psm1','Attachment.psm1','MachineNative.cs','MachineBackend.psm1','Recover-DspiApo.ps1')){
  $source=Join-Path $PSScriptRoot $name;No-Link $source
  $bytes=[IO.File]::ReadAllBytes($source);$target=Join-Path $tools $name
  [DspiSecure.Native]::Record($target,$bytes);Assert-DspiProtectedAcl $target -File
  [pscustomobject]@{Name=$name;SHA256=(Get-FileHash -LiteralPath $target).Hash}
 })
 $hash=(Get-FileHash -LiteralPath (Join-Path $Session.Directory bundle.json)).Hash
 $null=Write-DspiProtectedRecord -Directory $Session.Directory -Name bundle.json -ExpectedSHA256 $hash -Value @{SchemaVersion=1;State='Ready';Files=$files}
 return (Join-Path $tools 'Recover-DspiApo.ps1')
}
function Start-DspiMachineTransaction {
 param($Context,$Session,[int]$FailAfter=0,[int]$FailStage=0,[int]$CrashStage=0)
 Assert-Context $Context
 if($Context.Mode -eq 'Machine'){
  if($Context.PSObject.Properties['LocalDevelopmentTest'] -and $Context.LocalDevelopmentTest){
   Assert-DevelopmentScope $Context.Plan
   if(!@(Get-Process -Name audiodg -ErrorAction SilentlyContinue | Where-Object {[DspiMachine.Native]::AudioAccess($_.Id,(File-Sddl),0x1200a9,$true)}).Count){throw 'The running system audio process did not pass the development test gate.'}
  }elseif((Get-AuthenticodeSignature -LiteralPath $Context.Dll).Status -ne 'Valid'){throw 'Machine transaction refuses an unsigned/untrusted DLL.'}
 }
 if($Context.Mode -ne 'Fixture' -and ($FailAfter -or $FailStage -or $CrashStage)){throw 'Fault injection is confined to fixture mode.'}
 if(($Context.Mode -eq 'Fixture') -ne [bool]$Session.TestOnly){throw 'Fixture and protected storage mode differ.'}
 $global=Global-Lease $Session;$lease=$null
 try{
  $lease=Lease $Session
  Check-OtherSessions $Session
  $ops=@(Get-DspiMachineOperations $Context);$hash=$null
  # All destinations and write handles are checked before the first mutation.
  $initial=@{}
  foreach($op in $ops){$state=Read-Resource $Context $op;$shared=$op.PSObject.Properties['Shared'] -and $op.Shared;if($state.Exists -and !$shared){throw 'Machine destination is already occupied.'};$initial[$op.Id]=$state}
  foreach($name in @('Classes','Interface')){
   $probe=Open-Root $Context $name $true
   if(!$probe){throw 'Machine registry handle is unavailable.'}
   try{
    if($name -eq 'Interface'){Check-Inbox $Context $probe}
    elseif($Context.Mode -eq 'Machine'){
     foreach($path in @('CLSID','AudioEngine\AudioProcessingObjects')){
      $parent=$probe.OpenSubKey($path,$true)
      if(!$parent){throw 'Existing machine APO registration parent is required.'}
      try{Check-SharedKey $parent}finally{$parent.Dispose()}
     }
    }
   }finally{$probe.Dispose()}
  }
  $journal=[pscustomobject]@{SchemaVersion=1;SessionId=$Session.SessionId;Context=$Context;State='Applying';Entries=@()}
  Save-Journal $Session $journal ([ref]$hash)
  foreach($op in $ops){
   $before=Read-Resource $Context $op
   if(!(Equal $before $initial[$op.Id])){throw 'Machine resource changed after preflight.'}
   $shared=$op.PSObject.Properties['Shared'] -and $op.Shared
   if($before.Exists -and !$shared){throw 'Machine destination is already occupied.'}
   $entry=[pscustomobject]@{Operation=$op;Before=$before;After=(Expected $op);Token=[guid]::NewGuid().ToString('N');State=$(if($before.Exists){'Unchanged'}else{'Intent'})}
   $journal.Entries+= $entry;Save-Journal $Session $journal ([ref]$hash)
   if(!$before.Exists){Write-Resource $Context $entry ($FailStage -gt 0 -and $journal.Entries.Count -eq $FailStage) ($CrashStage -gt 0 -and $journal.Entries.Count -eq $CrashStage);if($FailAfter -gt 0 -and $journal.Entries.Count -eq $FailAfter){throw 'Injected machine interruption.'};if(!(Equal (Read-Resource $Context $op) $entry.After)){throw 'Machine resource verification failed.'};$entry.State='Applied';Save-Journal $Session $journal ([ref]$hash)}
  }
  $journal.State='Installed';Save-Journal $Session $journal ([ref]$hash)
  [pscustomobject]@{Installed=$true;Fixture=($Context.Mode -eq 'Fixture');RecoveryDirectory=$Session.Directory;SessionId=$Session.SessionId}
 }finally{if($lease){$lease.Dispose()};if($global){$global.Dispose()}}
}
function Undo-DspiMachineTransaction {
 param($Session,[int]$FailAfter=0)
 $global=Global-Lease $Session;$lease=$null;$oldRecovering=$script:Recovering;$script:Recovering=$true
 try{
  $lease=Lease $Session
  $journal=Read-DspiProtectedRecord -Directory $Session.Directory -Name backend.json
  $path=Join-Path $Session.Directory backend.json;$hash=(Get-FileHash -LiteralPath $path).Hash
  if($journal.SchemaVersion -ne 1 -or $journal.SessionId -cne $Session.SessionId -or $journal.State -cnotin @('Applying','Installed','RollingBack','WaitingForFileRelease','RolledBack')){throw 'Unexpected machine journal.'}
  $c=$journal.Context;Assert-Context $c
  if($c.Mode -ne 'Fixture' -and $FailAfter){throw 'Recovery fault injection is confined to fixture mode.'}
  if(($c.Mode -eq 'Fixture') -ne [bool]$Session.TestOnly){throw 'Recovery mode differs.'}
  $ops=@(Get-DspiMachineOperations $c)
  if($journal.Entries.Count -gt $ops.Count){throw 'Journal exceeds source-generated operation set.'}
  for($i=0;$i -lt $journal.Entries.Count;$i++){
   $e=$journal.Entries[$i]
   if(!(Equal $e.Operation $ops[$i]) -or $e.Token -cnotmatch '^[a-f0-9]{32}$' -or $e.State -cnotin @('Intent','Applied','Unchanged','UndoIntent','Restored','Retained') -or !(Equal $e.After (Expected $ops[$i]))){throw 'Journal differs from generated machine operations.'}
   $now=Read-Resource $c $e.Operation
   if($e.State -eq 'Retained'){
    if($e.Operation.Kind -ne 'Directory' -or ($e.Operation.Path -ine $c.Data -and !$e.Operation.Path.StartsWith($c.Data+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Only data directories may be retained.'}
    continue
   }
   if($e.State -eq 'Unchanged'){if(!$e.Before.Exists -or !(Equal $now $e.Before)){throw 'Shared resource changed.'};continue}
   if($e.Before.Exists){throw 'Backend only owns newly created resources.'}
   if(!(Equal $now $e.Before) -and (!(Equal $now $e.After) -or $e.State -eq 'Restored')){throw 'Machine recovery conflict; nothing removed.'}
   Check-OwnedChildren $c $e $journal.Entries
  }
  if($journal.State -eq 'RolledBack'){return [pscustomobject]@{RolledBack=$true;PendingFile=$null;RetainedDataDirectories=@($journal.Entries | Where-Object State -eq 'Retained' | ForEach-Object {$_.Operation.Path})}}
  $retained=Retained-Data $c
  $journal.State='RollingBack';Save-Journal $Session $journal ([ref]$hash);$count=0
  for($i=$journal.Entries.Count-1;$i -ge 0;$i--){
   $e=$journal.Entries[$i];if($e.State -in @('Unchanged','Restored','Retained')){continue}
   if($e.Operation.Kind -eq 'Directory' -and $retained.ContainsKey($e.Operation.Path)){$e.State='Retained';Save-Journal $Session $journal ([ref]$hash);continue}
   $now=Read-Resource $c $e.Operation
   if($now.Exists -and !(Equal $now $e.After)){throw 'Machine resource changed during recovery.'}
   # Also clean interrupted staging when final destination never appeared.
   $hasStage=$false
   if($e.Operation.Kind -eq 'File'){$hasStage=Test-Path -LiteralPath ($e.Operation.Path+'.'+$e.Token+'.tmp')}
   elseif($e.Operation.Kind -eq 'Tree'){$root=Open-Root $c $e.Operation.Root $false;try{$p=Key-Parent $root $e.Operation.Path $false;try{$k=$p.Key.OpenSubKey((Stage-Name $e),$false);$hasStage=$null -ne $k;if($k){$k.Dispose()}}finally{if($p.Owns){$p.Key.Dispose()}}}finally{$root.Dispose()}}
   if($now.Exists -or $hasStage){
    $e.State='UndoIntent';Save-Journal $Session $journal ([ref]$hash)
    try{Remove-Resource $c $e}catch{
     $errorDetail=$_.Exception;while($errorDetail.InnerException){$errorDetail=$errorDetail.InnerException};$code=$errorDetail.HResult -band 0xffff
     if($e.Operation.Kind -eq 'File' -and $code -in @(5,32,33) -and (Equal (Read-Resource $c $e.Operation) $e.After)){
      $journal.State='WaitingForFileRelease';Save-Journal $Session $journal ([ref]$hash)
      return [pscustomobject]@{RolledBack=$false;Detached=$true;PendingFile=$e.Operation.Path;Win32Error=$code;RetryAfterAudioCloses=$true}
     }
     throw
    }
    $count++;if($FailAfter -gt 0 -and $count -eq $FailAfter){throw 'Injected machine restore interruption.'}
   }
   $e.State='Restored';Save-Journal $Session $journal ([ref]$hash)
  }
  $journal.State='RolledBack';Save-Journal $Session $journal ([ref]$hash)
  [pscustomobject]@{RolledBack=$true;PendingFile=$null;RetainedDataDirectories=@($journal.Entries | Where-Object State -eq 'Retained' | ForEach-Object {$_.Operation.Path})}
 }finally{$script:Recovering=$oldRecovering;if($lease){$lease.Dispose()};if($global){$global.Dispose()}}
}
function Remove-DspiBackendFixture {
 param($Context)
 Assert-Context $Context;if($Context.Mode -ne 'Fixture'){throw 'Only fixture baselines can be cleaned.'}
 if(@(Get-ChildItem -LiteralPath $Context.Base -Force).Count){throw 'Fixture still has files.'}
 $root=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Context.RegistryPath,$true)
 try{
  $iface=$root.OpenSubKey('Interface',$true)
  try{
   Check-Inbox $Context $iface
   if(@($iface.GetSubKeyNames()).Count -ne 1 -or $iface.GetSubKeyNames()[0] -cne 'MSFX' -or $iface.ValueCount){throw 'Fixture has unknown interface changes.'}
   $msfx=$iface.OpenSubKey('MSFX',$true);try{if($msfx.ValueCount -or @($msfx.GetSubKeyNames()).Count -ne 1 -or $msfx.GetSubKeyNames()[0] -cne '0'){throw 'Fixture inbox baseline changed.'};$speaker=$msfx.OpenSubKey('0',$true);try{if($speaker.SubKeyCount){throw 'Unknown fixture speaker child.'};foreach($name in @($speaker.GetValueNames())){$speaker.DeleteValue($name)}}finally{$speaker.Dispose()};$msfx.DeleteSubKey('0',$false)}finally{$msfx.Dispose()};$iface.DeleteSubKey('MSFX',$false)
  }finally{$iface.Dispose()}
  foreach($name in @('Classes','Interface')){$key=$root.OpenSubKey($name,$false);try{if($key.ValueCount -or $key.SubKeyCount){throw 'Fixture still has registry changes.'}}finally{$key.Dispose()}};foreach($name in @('Classes','Interface')){$root.DeleteSubKey($name,$false)}
 }finally{$root.Dispose()}
 [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($Context.RegistryPath,$false);[IO.Directory]::Delete($Context.Base,$false)
}
Export-ModuleMember -Function New-DspiBackendContext,New-DspiBackendFixture,Get-DspiMachineOperations,Install-DspiRecoveryBundle,Start-DspiMachineTransaction,Undo-DspiMachineTransaction,Remove-DspiBackendFixture
