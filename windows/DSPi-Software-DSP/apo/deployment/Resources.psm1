# GPL-3.0. Real Windows resources in a confined LAB ONLY namespace.
# No HKLM, audio interface, driver-store, service or production backend is exposed.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Plain-Path([string]$path){
 for($walk=[IO.Path]::GetFullPath($path);$walk;$walk=Split-Path -Parent $walk){
  if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse path rejected.'}
  if((Split-Path -Parent $walk) -eq $walk){break}
 }
}
function Assert-Lab($lab){
 $build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\')+'\'
 $full=[IO.Path]::GetFullPath($lab.Root)
 if($lab.Mode -cne 'WindowsLab' -or !$full.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Parent)+'\' -ine $build -or (Split-Path $full -Leaf) -cnotmatch '^full-recovery-[a-f0-9]{32}$'){throw 'Not a confined Windows lab.'}
 if($lab.RegistryRoot -cne ('Software\DSPi-Recovery-Tests\'+(Split-Path $full -Leaf))){throw 'Registry lab scope mismatch.'}
 Plain-Path $full
}
function New-DspiResourceLab {
 param([Parameter(Mandatory)][string]$Root)
 $Root=[IO.Path]::GetFullPath($Root)
 $secret=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($secret)
 $lab=[pscustomobject]@{Mode='WindowsLab';Root=$Root;RegistryRoot=('Software\DSPi-Recovery-Tests\'+(Split-Path $Root -Leaf));TestSddl=$null;JournalKey=[Convert]::ToBase64String($secret);Journals=@()}
 Assert-Lab $lab
 if(Test-Path -LiteralPath $Root){throw 'Lab directory already exists.'}
 $existing=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($lab.RegistryRoot,$false)
 if($existing){$existing.Dispose();throw 'Lab registry key already exists.'}
 New-Item -ItemType Directory -Path $Root | Out-Null
 $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($lab.RegistryRoot+'\Classes\CLSID');$key.Dispose()
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 # Use Windows' canonical allow ordering and auto-inheritance flag so that an
 # interruption before readback still has an exact, recognisable after-state.
 $lab.TestSddl="O:${sid}G:${sid}D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;${sid})"
 return $lab
}
function Stage-Path($lab,$op){
 if(!$op.PSObject.Properties['StagingName'] -or $op.StagingName -cnotmatch '^[a-f0-9]{32}$'){throw 'File staging identity must be journaled.'}
 $path=(Resource-Path $lab $op)+'.'+$op.StagingName+'.tmp';Plain-Path $path;return $path
}
function Resource-Path($lab,$op){
 Assert-Lab $lab
 if($op.Kind -cnotin @('Directory','File','FileAcl','RegistryKey','RegistryValue')){throw 'Unknown resource kind.'}
 if($op.Path -cnotmatch '^[a-zA-Z0-9_.{}-]+([/\\][a-zA-Z0-9_.{}-]+)*$' -or @($op.Path -split '[/\\]' | Where-Object {$_ -in @('.','..')}).Count){throw 'Resource path escape rejected.'}
 if($op.Kind -in @('RegistryKey','RegistryValue')){return $lab.RegistryRoot+'\'+$op.Path.Replace('/','\')}
 $path=[IO.Path]::GetFullPath((Join-Path $lab.Root $op.Path));Plain-Path $path
 if(!$path.StartsWith($lab.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Resource path escaped lab.'}
 return $path
}
function Read-DspiLabResource {
 param($Lab,$Operation)
 $path=Resource-Path $Lab $Operation
 if($Operation.Kind -in @('RegistryKey','RegistryValue')){
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$false)
  if(!$key){return [pscustomobject]@{Exists=$false}}
  try{
   if($Operation.Kind -eq 'RegistryKey'){return [pscustomobject]@{Exists=$true}}
   if($Operation.Name -notin $key.GetValueNames()){return [pscustomobject]@{Exists=$false}}
   $kind=$key.GetValueKind($Operation.Name).ToString();$data=$key.GetValue($Operation.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
   if($kind -eq 'DWord'){$data=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$data),0)}
   return [pscustomobject]@{Exists=$true;Kind=$kind;Value=$data}
  }finally{$key.Dispose()}
 }
 if(!(Test-Path -LiteralPath $path)){return [pscustomobject]@{Exists=$false}}
 switch($Operation.Kind){
  'Directory' {if(!(Test-Path -LiteralPath $path -PathType Container)){throw 'Expected directory.'};return [pscustomobject]@{Exists=$true}}
  'File' {if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Expected file.'};return [pscustomobject]@{Exists=$true;Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}}
  'FileAcl' {return [pscustomobject]@{Exists=$true;Sddl=(Get-Acl -LiteralPath $path).Sddl}}
 }
}
function Write-DspiLabResource {
 param($Lab,$Operation,$Value)
 $path=Resource-Path $Lab $Operation
 if($Operation.Kind -in @('RegistryKey','RegistryValue')){
  if($Operation.Kind -eq 'RegistryKey'){
   if($Value.Exists){
    $parentPath=$path.Substring(0,$path.LastIndexOf('\'));$parent=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath,$false)
    if(!$parent){throw 'Registry parent missing; ancestors must be individually journaled.'};$parent.Dispose()
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path);$key.Dispose()
   }
   else{
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$false)
    if(!$key){return}
    try{if($key.SubKeyCount -or $key.ValueCount){throw 'Refusing to delete nonempty registry key.'}}finally{$key.Dispose()}
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($path,$false)
   }
   return
  }
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$true)
  if(!$key){if(!$Value.Exists){return};throw 'Registry parent key missing.'}
  try{
   if(!$Value.Exists){$key.DeleteValue($Operation.Name,$false)}
   else{
    if($Value.Kind -cnotin @('String','ExpandString','MultiString','DWord','QWord','Binary')){throw 'Unsupported registry type.'}
    $data=switch($Value.Kind){'MultiString' {[string[]]@($Value.Value);break};'Binary' {[byte[]]@($Value.Value);break};'DWord' {[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value.Value),0);break};'QWord' {[long]$Value.Value;break};default{[string]$Value.Value}}
    if($Value.Kind -eq 'MultiString'){$data=[string[]]@($Value.Value)}
    if($Value.Kind -eq 'Binary'){$data=[byte[]]@($Value.Value)}
    $key.SetValue($Operation.Name,$data,[Microsoft.Win32.RegistryValueKind]$Value.Kind)
   }
   $key.Flush()
  }finally{$key.Dispose()}
  return
 }
 switch($Operation.Kind){
  'Directory' {
   if($Value.Exists){$parent=Split-Path $path -Parent;if(!(Test-Path -LiteralPath $parent -PathType Container)){throw 'Directory parent missing.'};[IO.Directory]::CreateDirectory($path) | Out-Null}
   elseif(Test-Path -LiteralPath $path){[IO.Directory]::Delete($path,$false)}
  }
  'File' {
   if($Value.Exists){
    $bytes=[Convert]::FromBase64String($Value.Bytes);$temporary=Stage-Path $Lab $Operation
    try{
     $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
     try{
      if($Operation.PSObject.Properties['TestPartialWrite'] -and $Operation.TestPartialWrite){$file.Write($bytes,0,[int]($bytes.Length/2));$file.Flush($true);throw 'Injected partial file write.'}
      if($Operation.PSObject.Properties['TestTerminateWrite'] -and $Operation.TestTerminateWrite){$file.Write($bytes,0,[int]($bytes.Length/2));$file.Flush($true);[Environment]::Exit(24)}
      $file.Write($bytes,0,$bytes.Length);$file.Flush($true)
     }finally{$file.Dispose()}
     [IO.File]::Move($temporary,$path)
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
   }
   elseif(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}
  }
  'FileAcl' {if(!$Value.Exists){throw 'An ACL cannot be removed separately from its object.'};$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetSecurityDescriptorSddlForm($Value.Sddl,[Security.AccessControl.AccessControlSections]'Owner,Group,Access');[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path),$acl)}
 }
}
function Equal-Resource($a,$b){return ((ConvertTo-Json -InputObject $a -Depth 12 -Compress) -ceq (ConvertTo-Json -InputObject $b -Depth 12 -Compress))}
function Assert-OwnedChildren($lab,$entry,$entries){
 $op=$entry.Operation
 if(!(Read-DspiLabResource $lab $op).Exists){return}
 if($op.Kind -eq 'Directory'){
  $path=Resource-Path $lab $op
  $known=@($entries | Where-Object {$_.Operation.Kind -in @('Directory','File')} | ForEach-Object {Resource-Path $lab $_.Operation})
  $known+=@($entries | Where-Object {$_.Operation.Kind -eq 'File' -and $_.State -in @('Intent','UndoIntent')} | ForEach-Object {Stage-Path $lab $_.Operation})
  foreach($child in Get-ChildItem -LiteralPath $path -Force){if($child.FullName -notin $known){throw 'Unowned directory child; no rollback performed.'};Plain-Path $child.FullName}
 }
 if($op.Kind -eq 'RegistryKey'){
  $path=Resource-Path $lab $op
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$false)
  try{
   $knownKeys=@($entries | Where-Object {$_.Operation.Kind -eq 'RegistryKey'} | ForEach-Object {Resource-Path $lab $_.Operation})
   $knownValues=@($entries | Where-Object {$_.Operation.Kind -eq 'RegistryValue' -and (Resource-Path $lab $_.Operation) -eq $path} | ForEach-Object {$_.Operation.Name})
   foreach($child in $key.GetSubKeyNames()){if(($path+'\'+$child) -notin $knownKeys){throw 'Unowned registry child; no rollback performed.'}}
   foreach($value in $key.GetValueNames()){if($value -notin $knownValues){throw 'Unowned registry value; no rollback performed.'}}
  }finally{$key.Dispose()}
 }
}
function Journal-Mac($lab,[string]$payload){
 $hmac=[Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($lab.JournalKey))
 try{[Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))}finally{$hmac.Dispose()}
}
function Save-ResourceJournal($journal,$path,$lab,[switch]$Create){
 $payload=$journal | ConvertTo-Json -Depth 35 -Compress
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(([ordered]@{Payload=$payload;Mac=(Journal-Mac $lab $payload)} | ConvertTo-Json -Compress))
 if($bytes.Length -gt 4194304){throw 'Resource journal exceeds admitted recovery size.'}
 $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 $f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
 if($Create){[IO.File]::Move($tmp,$path)}else{[IO.File]::Replace($tmp,$path,[System.Management.Automation.Language.NullString]::Value)}
}
function Journal-Path($lab,[string]$path){
 Assert-Lab $lab;$path=[IO.Path]::GetFullPath($path)
 if((Split-Path $path -Parent) -cne $lab.Root -or (Split-Path $path -Leaf) -cnotmatch '^[a-z0-9-]+\.json$'){throw 'Journal must be a named direct child of lab.'}
 Plain-Path $path;Plain-Path ($path+'.lock');return $path
}
function Invoke-DspiResourceTransaction {
 param($Lab,[object[]]$Operations,[string]$JournalPath,[int]$FailAfter=0)
 $path=Journal-Path $Lab $JournalPath
 if($path -notin $Lab.Journals){$Lab.Journals+= $path}
 if(!$Operations.Count -or $Operations.Count -gt 256){throw 'Invalid operation count.'}
 # Bound admission before creating or changing any resource. At most 64 entries,
 # 512 KiB operation JSON and 8 KiB captured ACL each fit the 4 MiB envelope.
 if($Operations.Count -gt 64 -or [Text.Encoding]::UTF8.GetByteCount(($Operations | ConvertTo-Json -Depth 20 -Compress)) -gt 524288){throw 'Operations exceed recoverable journal size.'}
 $ids=@{}
 foreach($op in $Operations){$null=Resource-Path $Lab $op;if($ids.ContainsKey($op.Id)){throw 'Duplicate resource id.'};$ids[$op.Id]=$true}
 $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  if(Test-Path -LiteralPath $path){throw 'Existing journal cannot be overwritten.'}
  $journal=[pscustomobject]@{SchemaVersion=2;Mode='WindowsLab';Root=$Lab.Root;RegistryRoot=$Lab.RegistryRoot;State='Applying';Entries=@()}
  Save-ResourceJournal $journal $path $Lab -Create
  foreach($sourceOp in $Operations){
   $op=$sourceOp | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
   if($op.Kind -eq 'File'){$op | Add-Member -NotePropertyName StagingName -NotePropertyValue ([guid]::NewGuid().ToString('N'));if(Test-Path -LiteralPath (Stage-Path $Lab $op)){throw 'Occupied staging path.'}}
   $before=Read-DspiLabResource $Lab $op
   if($op.Kind -ne 'FileAcl' -and $before.Exists){throw 'Resource is already occupied.'}
   if($op.Kind -eq 'FileAcl' -and !$before.Exists){throw 'ACL object missing.'}
   if($op.Kind -eq 'FileAcl' -and $before.Sddl.Length -gt 8192){throw 'ACL snapshot too large.'}
   $entry=[pscustomobject]@{Operation=$op;Before=$before;After=$op.After;State='Intent'}
   $journal.Entries+= $entry;Save-ResourceJournal $journal $path $Lab
   Write-DspiLabResource $Lab $op $op.After
   if($FailAfter -gt 0 -and $journal.Entries.Count -eq $FailAfter){throw 'Injected interruption after write.'}
   if(!(Equal-Resource (Read-DspiLabResource $Lab $op) $op.After)){throw 'Resource write verification failed.'}
   $entry.State='Applied';Save-ResourceJournal $journal $path $Lab
  }
  $journal.State='Applied';Save-ResourceJournal $journal $path $Lab
 }finally{$lock.Dispose()}
}
function Undo-DspiResourceTransaction {
 param($Lab,[string]$JournalPath,[int]$FailAfter=0)
 $path=Journal-Path $Lab $JournalPath
 $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  if((Get-Item -LiteralPath $path).Length -gt 4194304){throw 'Oversized journal.'}
  $envelope=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if($envelope.Mac -cne (Journal-Mac $Lab $envelope.Payload)){throw 'Modified resource journal authentication failed.'}
  $journal=$envelope.Payload | ConvertFrom-Json
  if($journal.SchemaVersion -ne 2 -or $journal.Mode -cne 'WindowsLab' -or $journal.Root -cne $Lab.Root -or $journal.RegistryRoot -cne $Lab.RegistryRoot -or $journal.State -cnotin @('Applying','Applied','RollingBack','RolledBack') -or @($journal.Entries).Count -gt 256){throw 'Invalid resource journal scope/state.'}
  # Check every resource before removing the attachment, COM entry or binary.
  foreach($entry in $journal.Entries){
   $null=Resource-Path $Lab $entry.Operation
   if($entry.State -cnotin @('Intent','Applied','UndoIntent','Restored') -or !(Equal-Resource $entry.After $entry.Operation.After)){throw 'Invalid resource journal entry.'}
   $current=Read-DspiLabResource $Lab $entry.Operation
   # A restored ACL may no longer exist after its owning directory was removed.
   if($entry.State -eq 'Restored' -and !$current.Exists){continue}
   if(!(Equal-Resource $current $entry.Before) -and (!(Equal-Resource $current $entry.After) -or $entry.State -eq 'Restored')){throw 'Resource recovery conflict; no rollback performed.'}
   Assert-OwnedChildren $Lab $entry $journal.Entries
  }
  if($journal.State -eq 'RolledBack'){return}
  $journal.State='RollingBack';Save-ResourceJournal $journal $path $Lab
  $count=0
  for($i=$journal.Entries.Count-1;$i -ge 0;$i--){
   $entry=$journal.Entries[$i];$current=Read-DspiLabResource $Lab $entry.Operation
   if($entry.Operation.Kind -eq 'File'){
    $stage=Stage-Path $Lab $entry.Operation
    if(Test-Path -LiteralPath $stage){
     if($entry.State -notin @('Intent','UndoIntent')){throw 'Unexpected staging file after acknowledged write.'}
     $entry.State='UndoIntent';Save-ResourceJournal $journal $path $Lab
     [IO.File]::Delete($stage)
    }
   }
   if($entry.State -eq 'Restored' -and !$current.Exists){continue}
   if(!(Equal-Resource $current $entry.Before)){
    if($entry.State -eq 'Restored' -or !(Equal-Resource $current $entry.After)){throw 'Resource conflict during rollback.'}
    $entry.State='UndoIntent';Save-ResourceJournal $journal $path $Lab
    Write-DspiLabResource $Lab $entry.Operation $entry.Before
    $count++;if($FailAfter -gt 0 -and $count -eq $FailAfter){throw 'Injected interruption after restore.'}
    if(!(Equal-Resource (Read-DspiLabResource $Lab $entry.Operation) $entry.Before)){throw 'Resource restore verification failed.'}
   }
   $entry.State='Restored';Save-ResourceJournal $journal $path $Lab
  }
  $journal.State='RolledBack';Save-ResourceJournal $journal $path $Lab
 }finally{$lock.Dispose()}
}
function Test-DspiResourceLabEmpty($Lab){
 Assert-Lab $Lab
 if(@(Get-ChildItem -LiteralPath $Lab.Root -Directory -Force).Count){return $false}
 $known=@($Lab.Journals)+@($Lab.Journals | ForEach-Object {$_+'.lock'})
 if(@(Get-ChildItem -LiteralPath $Lab.Root -File -Force | Where-Object {$_.FullName -notin $known}).Count){return $false}
 foreach($relative in @('','Classes','Classes\CLSID')){
  $path=$Lab.RegistryRoot+$(if($relative){'\'+$relative}else{''})
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$false)
  if(!$key){return $false}
  try{
   $expected=@(if($relative -eq ''){'Classes'}elseif($relative -eq 'Classes'){'CLSID'})
   if($key.ValueCount -ne 0 -or @($key.GetSubKeyNames()).Count -ne $expected.Count -or @($key.GetSubKeyNames() | Where-Object {$_ -notin $expected}).Count){return $false}
  }finally{$key.Dispose()}
 }
 return $true
}
Export-ModuleMember -Function New-DspiResourceLab,Read-DspiLabResource,Write-DspiLabResource,Invoke-DspiResourceTransaction,Undo-DspiResourceTransaction,Test-DspiResourceLabEmpty
