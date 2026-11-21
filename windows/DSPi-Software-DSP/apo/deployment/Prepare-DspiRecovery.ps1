# GPL-3.0. Read-only device preflight. Only new build reports are written.
param([Parameter(Mandatory)][string]$PackageRoot,[string]$TargetPlan,[string]$OutputName=('dspi-recovery-'+[guid]::NewGuid().ToString('N')))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Recovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Inspection.psm1') -Force
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(!$TargetPlan){$TargetPlan=Join-Path $repo 'build/dspi-usb-target-20261117.json'}
function Assert-Plain([string]$path){
 for($walk=[IO.Path]::GetFullPath($path);$walk;$walk=Split-Path -Parent $walk){
  if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse path rejected.'}
  if((Split-Path -Parent $walk) -eq $walk){break}
 }
}
$PackageRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageRoot)
$TargetPlan=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetPlan)
Assert-Plain $PackageRoot;Assert-Plain $TargetPlan
if($OutputName -cnotmatch '^[a-z0-9][a-z0-9-]{0,100}$'){throw 'OutputName must be a simple build folder name.'}
$out=Join-Path $repo ('build/'+$OutputName);Assert-Plain $out
if(Test-Path -LiteralPath $out){throw 'Output already exists.'}
$manifestPath=Join-Path $PackageRoot 'manifest.json';Assert-Plain $manifestPath
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$target=Get-Content -LiteralPath $TargetPlan -Raw | ConvertFrom-Json
if($manifest.SchemaVersion -ne 1 -or $manifest.EndpointId -ine $target.EndpointId -or $manifest.ProfileKey -cne $target.ProfileKey -or !$manifest.Validation.WdkPassed){throw 'Package is not the WDK-checked review for this selected endpoint.'}
$known=@('manifest.json')
foreach($entry in $manifest.Files){
 if([IO.Path]::IsPathRooted($entry.Path) -or $entry.Path -match '(^|[\\/])\.\.([\\/]|$)'){throw 'Unsafe package manifest path.'}
 $path=Join-Path $PackageRoot $entry.Path;Assert-Plain $path
 if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.SHA256){throw 'Package hash mismatch.'}
 $known+=$entry.Path.Replace('\','/')
}
if(@($known | Sort-Object -Unique).Count -ne $known.Count){throw 'Duplicate package manifest entries.'}
foreach($entry in Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force){Assert-Plain $entry.FullName;if(!$entry.PSIsContainer -and $entry.FullName.Substring($PackageRoot.Length+1).Replace('\','/') -notin $known){throw 'Unmanifested package file.'}}
$dll=Join-Path $PackageRoot 'component/dspi-apo.dll'
if((Get-FileHash -LiteralPath $dll).Hash -ne $target.Dll.SHA256){throw 'Package DLL differs from reviewed target.'}
# Three explicit signature checks; catalog generation is not signing.
$signatures=@(foreach($relative in @('component/dspi-apo.dll','component/dspi-apo-component.cat','extension/dspi-usb-extension.cat')){
 $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $PackageRoot $relative)
 [pscustomobject]@{Path=$relative;Status=$signature.Status.ToString();Signer=$(if($signature.SignerCertificate){$signature.SignerCertificate.Subject}else{$null})}
})
New-Item -ItemType Directory -Path $out | Out-Null
$mappingPath=Join-Path $out 'fresh-mapping.json'
$null=& (Join-Path $PSScriptRoot 'Inspect-EndpointMapping.ps1') -EndpointId $target.EndpointId -OutputPath $mappingPath
$mapping=Get-Content -LiteralPath $mappingPath -Raw | ConvertFrom-Json
$plan=New-DspiRecoveryPlan -Target $target -Mapping $mapping
$attachment=New-DspiScopedAttachment -Target $target -Mapping $mapping
$blockers=@('DeviceInstanceAttachmentNotValidated','AudioTokenAccessProvisionNotValidated','ActualAudiodgProcessingNotVerified','LiveHostRecoveryNotVerified')
if(@($signatures | Where-Object Status -ne 'Valid').Count){$blockers+='PackageOrDllNotTrusted'}
else{$blockers+='ProtectedAudioAndDriverPackageTrustNotValidated'}
# Exact function registry and its referenced class key are read-only corroboration.
# PnP queries are denied in this session; do not substitute absence for denial.
$hardwarePath='SYSTEM\CurrentControlSet\Enum\'+$plan.Scope.FunctionInstanceId
$hardware=& (Get-Module Inspection) {param($path) Read-DspiRegistrySnapshot $path} $hardwarePath
$driverPointer=@($hardware.Values | Where-Object Name -eq 'Driver')
$driverStatus='Unreadable';$driver=$null
if($hardware.Status -eq 'Read' -and $driverPointer.Count -eq 1 -and $driverPointer[0].Value -match '^\{[a-fA-F0-9-]{36}\}\\[0-9]{4}$'){
 $driver=& (Get-Module Inspection) {param($path) Read-DspiRegistrySnapshot $path} ('SYSTEM\CurrentControlSet\Control\Class\'+$driverPointer[0].Value)
 $driverStatus='Matches'
 foreach($pair in @(@($target.BeforeState.HardwareRegistry,$hardware,@('HardwareID','Driver')),@($target.BeforeState.DriverRegistry,$driver,@('InfPath','DriverVersion','MatchingDeviceId')))){
  if($pair[0].Status -ne 'Read' -or $pair[1].Status -ne 'Read' -or $pair[0].Path -ine $pair[1].Path){$driverStatus='Mismatch';continue}
  foreach($name in $pair[2]){
   $before=@($pair[0].Values | Where-Object Name -eq $name);$now=@($pair[1].Values | Where-Object Name -eq $name)
   if($before.Count -ne 1 -or $now.Count -ne 1 -or !(Test-DspiTypedValue $before[0] $now[0])){$driverStatus='Mismatch'}
  }
 }
}
if($driverStatus -ne 'Matches'){$blockers+='SelectedDriverChangedOrUnreadable'}
$fxPath='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+($target.EndpointId -replace '^\{0\.0\.0\.00000000\}\.','')+'\FxProperties'
$fx=& (Get-Module Inspection) {param($path) Read-DspiRegistrySnapshot $path} $fxPath
$aclStatus=if($fx.Status -eq 'Read' -and $fx.Sddl -and !$fx.Sddl.StartsWith('Unavailable:') -and $fx.Sddl -ceq $target.BeforeState.FxSnapshot.Sddl){'Matches'}else{'MismatchOrUnreadable'}
if($aclStatus -ne 'Matches'){$blockers+='SelectedEffectAclChangedOrUnreadable'}
$report=[ordered]@{SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');ReadOnly=$true;Installed=$false;Installable=$false;Scope=$plan.Scope;PackageHashesValid=$true;PackageManifestSHA256=(Get-FileHash -LiteralPath $manifestPath).Hash;TargetSHA256=(Get-FileHash -LiteralPath $TargetPlan).Hash;Signatures=$signatures;DriverComparison=[ordered]@{Status=$driverStatus;Method='Read-only exact function Enum and referenced class registry snapshot; PnP API access is not implied';Hardware=$hardware;Driver=$driver};EffectAclComparison=[ordered]@{Status=$aclStatus;Snapshot=$fx};Blockers=$blockers;RecoveryCoverage='14-resource machine backend and protected standalone recovery implemented; elevated fixture tested. Live-host processing/recovery remains unverified.'}
foreach($entry in @(@('recovery-plan.json',$plan),@('attachment-plan.json',$attachment),@('readiness.json',$report))){
 $path=Join-Path $out $entry[0];$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($entry[1] | ConvertTo-Json -Depth 40))
 $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
}
Write-Output $out
