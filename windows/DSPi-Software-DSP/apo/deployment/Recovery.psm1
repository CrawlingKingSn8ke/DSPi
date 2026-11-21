# GPL-3.0. Lab transaction engine only: no Windows registry/device write backend.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Copy-Data($value){$value | ConvertTo-Json -Depth 35 -Compress | ConvertFrom-Json}
function Get-DataHash([string]$text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','')}finally{$sha.Dispose()}
}
function Test-DspiTypedValue($Left,$Right){
 if($null -eq $Left -or $null -eq $Right){return ($null -eq $Left -and $null -eq $Right)}
 if($Left.Name -ine $Right.Name -or $Left.Kind -cne $Right.Kind){return $false}
 # Preserve array boundaries and ordinal data, including case and order.
 return ((ConvertTo-Json -InputObject $Left.Value -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $Right.Value -Depth 8 -Compress))
}
function Get-ScopedChanges($scope){
 if($scope.EndpointId -cnotmatch '^\{0\.0\.0\.00000000\}\.\{[a-f0-9-]{36}\}$' -or $scope.ProfileKey -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid endpoint/profile scope.'}
 $expected=(Get-DataHash $scope.EndpointId.ToLowerInvariant()).ToLowerInvariant()
 if($scope.ProfileKey -cne $expected){throw 'Profile key does not identify this endpoint.'}
 if($scope.FunctionInstanceId -notlike 'USB\VID_2E8B&PID_FEAA&MI_00\*' -or !$scope.InterfacePath.EndsWith('\global',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsupported device scope.'}
 @(
  [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7';Before=$null;After=[pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7';Kind='String';Value='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'}}
  [pscustomobject]@{Name='{d3993a3f-99c2-4402-b5ec-a92a0367664b},7';Before=$null;After=[pscustomobject]@{Name='{d3993a3f-99c2-4402-b5ec-a92a0367664b},7';Kind='MultiString';Value=@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}')}}
  [pscustomobject]@{Name='{67fe7ad1-1232-4c16-94ce-83a4f63be981},1';Before=$null;After=[pscustomobject]@{Name='{67fe7ad1-1232-4c16-94ce-83a4f63be981},1';Kind='String';Value=$scope.ProfileKey}}
 )
}
function New-DspiRecoveryPlan {
 param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Mapping)
 if($Target.SchemaVersion -ne 1 -or $Mapping.SchemaVersion -ne 1 -or $Mapping.EndpointId -ine $Target.EndpointId){throw 'Selected endpoint evidence mismatch.'}
 if($Target.BeforeState.DeviceState -ne 1 -or $Target.BeforeState.FxReadStatus -ne 'Read' -or $Target.BeforeState.EnhancementsDisabled -eq 1){throw 'Selected endpoint is unavailable or effects are disabled.'}
 $endpointPnp=@($Target.BeforeState.Pnp | Where-Object InstanceId -eq ('SWD\MMDEVAPI\'+$Target.EndpointId))
 if($endpointPnp.Count -ne 1){throw 'Exact endpoint PnP evidence missing.'}
 $parent=@($endpointPnp[0].Properties | Where-Object KeyName -eq 'DEVPKEY_Device_Parent')
 if($parent.Count -ne 1 -or $parent[0].Data -ine $Mapping.FunctionInstanceId){throw 'Selected USB function differs from endpoint parent.'}
 $interfaces=@($Mapping.FunctionInterfaces | Where-Object {$_.InstanceId -ieq $Mapping.FunctionInstanceId -and $_.Path.EndsWith('\global',[StringComparison]::OrdinalIgnoreCase) -and $_.RegistryStatus -eq 'Read'})
 if($interfaces.Count -ne 1){throw 'Exact GLOBAL interface evidence missing.'}
 $topology=@($Mapping.AllEndpointTopologies | Where-Object EndpointId -eq $Target.EndpointId)
 if($topology.Count -ne 1 -or $topology[0].State -ne 1 -or $topology[0].TopologyStatus -ne 'Read' -or $topology[0].AdapterInterface -ine ('{2}.'+$interfaces[0].Path)){throw 'Live endpoint topology differs from selected interface.'}
 $scope=[pscustomobject]@{EndpointId=$Target.EndpointId.ToLowerInvariant();FunctionInstanceId=$Mapping.FunctionInstanceId.ToLowerInvariant();InterfacePath=$interfaces[0].Path.ToLowerInvariant();ProfileKey=$Target.ProfileKey}
 $changes=@(Get-ScopedChanges $scope)
 $values=@($Target.BeforeState.FxProperties)
 if(@($values.Name | Sort-Object -Unique).Count -ne $values.Count){throw 'Duplicate original property names.'}
 $cached=@($Mapping.FunctionRegistryEndpoints | Where-Object {$_.Flow -eq 'Render' -and $Target.EndpointId.EndsWith($_.Key,[StringComparison]::OrdinalIgnoreCase)})
 if($cached.Count -ne 1 -or @($cached[0].FxProperties).Count -ne $values.Count){throw 'Fresh endpoint effects differ from target evidence.'}
 foreach($value in $values){$observed=@($cached[0].FxProperties | Where-Object Name -eq $value.Name);if($observed.Count -ne 1 -or !(Test-DspiTypedValue $value $observed[0])){throw 'Fresh endpoint effects differ from target evidence.'}}
 $forbidden=@($changes.Name)+@('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15','{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2')
 if(@($values | Where-Object Name -in $forbidden).Count){throw 'Endpoint effect slot is already occupied.'}
 [pscustomobject]@{SchemaVersion=1;Mode='LabOnly';LiveInstallable=$false;Scope=$scope;Changes=$changes;OriginalValues=(Copy-Data $values);Limitations=@('No Windows device writer is exposed.','Model-wide INF attachment and signed-package trust remain unresolved.','Recovery covers these three endpoint values only; package, file, COM and ACL recovery require their own journal entries.')}
}
function Assert-JournalPath([string]$path){
 $build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\')+'\'
 $full=[IO.Path]::GetFullPath($path)
 if(!$full.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Parent)+'\' -ine $build){throw 'Lab journals must be direct children of repository build.'}
 foreach($candidate in @($full,$full+'.lock')){
  for($walk=$candidate;$walk;$walk=Split-Path -Parent $walk){
   if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Journal reparse path rejected.'}
   if((Split-Path -Parent $walk) -eq $walk){break}
  }
 }
 return $full
}
function Save-Journal($journal,[string]$path,[switch]$Create){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($journal | ConvertTo-Json -Depth 35 -Compress))
 # Atomic replacement plus Flush(true): after a failed acknowledgement, recovery
 # can see Intent and compare the store against both the before and after value.
 $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
 if($Create){[IO.File]::Move($temporary,$path)}else{[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}
}
function Assert-Entries($scope,$entries){
 $expected=@(Get-ScopedChanges $scope)
 if(@($entries).Count -ne 3){throw 'Journal must contain exactly three allowed changes.'}
 for($i=0;$i -lt 3;$i++){
  if($entries[$i].Name -cne $expected[$i].Name -or $null -ne $entries[$i].Before -or !(Test-DspiTypedValue $entries[$i].After $expected[$i].After)){throw 'Journal change is outside its device scope.'}
 }
}
function Start-DspiRecoveryTransaction {
 param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][scriptblock]$Read,[Parameter(Mandatory)][scriptblock]$Write)
 if($Plan.SchemaVersion -ne 1 -or $Plan.Mode -cne 'LabOnly' -or $Plan.LiveInstallable){throw 'Only lab plans are supported.'}
 Assert-Entries $Plan.Scope $Plan.Changes
 $path=Assert-JournalPath $JournalPath
 $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  if(Test-Path -LiteralPath $path){throw 'Existing journal cannot be overwritten.'}
  foreach($value in $Plan.OriginalValues){if(!(Test-DspiTypedValue $value (& $Read $value.Name))){throw 'Original Windows effects changed; no writes performed.'}}
  foreach($change in $Plan.Changes){if($null -ne (& $Read $change.Name)){throw 'Occupied effect slot; no writes performed.'}}
  $journal=[pscustomobject]@{SchemaVersion=1;Mode='LabOnly';Scope=(Copy-Data $Plan.Scope);State='Applying';Entries=@(foreach($change in $Plan.Changes){[pscustomobject]@{Name=$change.Name;Before=$null;After=(Copy-Data $change.After);State='Pending'}})}
  Save-Journal $journal $path -Create
  foreach($entry in $journal.Entries){
   if($null -ne (& $Read $entry.Name)){throw 'Effect slot changed during transaction.'}
   $entry.State='Intent';Save-Journal $journal $path
   $null=& $Write $entry.Name (Copy-Data $entry.After)
   if(!(Test-DspiTypedValue $entry.After (& $Read $entry.Name))){throw 'Write verification failed.'}
   $entry.State='Applied';Save-Journal $journal $path
  }
  $journal.State='Applied';Save-Journal $journal $path
  return $journal
 }finally{$lock.Dispose()}
}
function Undo-DspiRecoveryTransaction {
 param([Parameter(Mandatory)]$Scope,[Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][scriptblock]$Read,[Parameter(Mandatory)][scriptblock]$Write,[Parameter(Mandatory)][scriptblock]$Remove)
 $path=Assert-JournalPath $JournalPath
 $lock=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $info=Get-Item -LiteralPath $path
  if($info.Length -gt 1048576){throw 'Oversized recovery journal.'}
  $journal=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if($journal.SchemaVersion -ne 1 -or $journal.Mode -cne 'LabOnly' -or $journal.State -cnotin @('Applying','Applied','RollingBack','RolledBack')){throw 'Invalid recovery journal.'}
  foreach($field in @('EndpointId','FunctionInstanceId','InterfacePath','ProfileKey')){if($journal.Scope.$field -cne $Scope.$field){throw 'Recovery scope differs from selected device.'}}
  Assert-Entries $Scope $journal.Entries
  foreach($entry in $journal.Entries){
   if($entry.State -cnotin @('Pending','Intent','Applied','UndoIntent','Restored')){throw 'Invalid recovery entry state.'}
   $current=& $Read $entry.Name
   if($null -ne $current -and (!(Test-DspiTypedValue $current $entry.After) -or $entry.State -in @('Pending','Restored'))){throw 'Recovery conflict; no values restored.'}
  }
  if($journal.State -eq 'RolledBack'){return $journal}
  $journal.State='RollingBack';Save-Journal $journal $path
  for($i=2;$i -ge 0;$i--){
   $entry=$journal.Entries[$i];$current=& $Read $entry.Name
   if($null -ne $current){
    if($entry.State -in @('Pending','Restored') -or !(Test-DspiTypedValue $current $entry.After)){throw 'Recovery conflict during rollback.'}
    $entry.State='UndoIntent';Save-Journal $journal $path
    $null=& $Remove $entry.Name
    if($null -ne (& $Read $entry.Name)){throw 'Removal verification failed.'}
   }
   $entry.State='Restored';Save-Journal $journal $path
  }
  $journal.State='RolledBack';Save-Journal $journal $path
  return $journal
 }finally{$lock.Dispose()}
}
Export-ModuleMember -Function New-DspiRecoveryPlan,Test-DspiTypedValue,Start-DspiRecoveryTransaction,Undo-DspiRecoveryTransaction
