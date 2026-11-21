# GPL-3.0. Temporary exact-device development test with automatic rollback.
param(
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
 [switch]$RefreshDevice,
 [switch]$KeepThroughReboot,
 [switch]$EndpointStore,
 [switch]$ProfileBindingTest,
 [switch]$DiagnosticBuild,
 [switch]$SpectrumBuild,
 [switch]$RefinementsBuild,
 [switch]$KeepActive
)
$ErrorActionPreference='Stop'
if($RefreshDevice -and $KeepThroughReboot){throw 'Choose a device refresh or a reboot test.'}
if($ProfileBindingTest -and ($RefreshDevice -or $KeepThroughReboot -or !$EndpointStore)){throw 'Profile binding test requires a temporary endpoint attachment.'}
if($DiagnosticBuild -and !$ProfileBindingTest){throw 'The diagnostic build requires a temporary profile binding test.'}
if($SpectrumBuild -and (!$ProfileBindingTest -or $DiagnosticBuild)){throw 'Spectrum build requires the endpoint profile test without a diagnostic build selection.'}
if($RefinementsBuild -and (!$ProfileBindingTest -or $DiagnosticBuild -or $SpectrumBuild)){throw 'Choose only the checked refinements build for this endpoint profile test.'}
if($KeepActive -and !$SpectrumBuild -and !$RefinementsBuild){throw 'KeepActive requires the checked spectrum build.'}
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$build=Join-Path $repo build
Import-Module (Join-Path $PSScriptRoot 'MachineBackend.psm1')
Import-Module (Join-Path $PSScriptRoot 'ProtectedStorage.psm1')
Assert-DspiAdministrator
$hostPath='C:\Program Files\PowerShell\7\pwsh.exe'
if((Get-Process -Id $PID).Path -ine $hostPath -or (Get-AuthenticodeSignature -LiteralPath $hostPath).Status -ne 'Valid'){throw 'Use the protected Microsoft PowerShell host.'}
$reportRoot=Split-Path $hostPath -Parent
function Write-Result($name,$value){
 $file=Join-Path $reportRoot ('dspi-live-'+$RunId+'-'+$name+'.json')
 $bytes=[Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 12))
 [DspiMachine.Native]::File($file,$bytes,'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)')
}
$result=[ordered]@{Installed=$false;RolledBack=$false;MachineMutationStarted=$false;Error=$null;RecoveryError=$null;RecoveryScript=$null}
$session=$null
$refreshAttempted=$false
$leaveAttached=$false
$audioRefreshAttempted=$false
function Restart-AudioForTest {
 $running=@(Get-Service Audiosrv -DependentServices | Where-Object Status -eq Running)
 if(@($running | Where-Object Name -ne 'LightingService').Count){throw 'An unexpected running service depends on Windows Audio.'}
 try{
  foreach($service in $running){Stop-Service -Name $service.Name}
  Restart-Service -Name Audiosrv
 }finally{
  if((Get-Service Audiosrv).Status -ne 'Running'){Start-Service Audiosrv}
  foreach($service in $running){Start-Service -Name $service.Name}
 }
}
function Refresh-SelectedDevice {
 $device='USB\VID_2E8B&PID_FEAA&MI_00\7&3758099E&1&0000'
 $messages=& (Join-Path ([Environment]::SystemDirectory) pnputil.exe) /restart-device $device
 if($LASTEXITCODE){throw ('DSPi USB device restart failed: '+($messages -join ' '))}
}
function Invoke-ProtectedRecovery {
 $json=& $hostPath -NoProfile -NonInteractive -CommandWithArgs '& $args[0] | ConvertTo-Json -Depth 8 -Compress' $result.RecoveryScript
 if($LASTEXITCODE){throw "Standalone recovery exited with code $LASTEXITCODE."}
 $json | ConvertFrom-Json
}
try {
 $package=Join-Path $build dspi-apo-wdk-checked-20261118
 $targetPath=Join-Path $build dspi-usb-target-20261117.json
 if($ProfileBindingTest){
  $package=Join-Path $build dspi-apo-wdk-profile-binding
  $targetPath=Join-Path $build dspi-usb-target-profile-binding.json
 }
 if($DiagnosticBuild){
  $package=Join-Path $build dspi-apo-wdk-local-effect-iid
  $targetPath=Join-Path $build dspi-usb-target-local-effect-iid.json
 }
 if($SpectrumBuild){
  $package=Join-Path $build dspi-apo-wdk-windows-rta
  $targetPath=Join-Path $build dspi-usb-target-windows-rta.json
 }
 if($RefinementsBuild){
  $package=Join-Path $build dspi-apo-wdk-windows-refinements
  $targetPath=Join-Path $build dspi-usb-target-windows-refinements.json
 }
 $prepared=& (Join-Path $PSScriptRoot 'Prepare-DspiRecovery.ps1') -PackageRoot $package -TargetPlan $targetPath -OutputName ('local-live-'+$RunId)
 $report=Get-Content -LiteralPath (Join-Path $prepared readiness.json) -Raw | ConvertFrom-Json
 $accepted=@('PackageOrDllNotTrusted','DeviceInstanceAttachmentNotValidated','AudioTokenAccessProvisionNotValidated','ActualAudiodgProcessingNotVerified','LiveHostRecoveryNotVerified')
 $remaining=@($report.Blockers | Where-Object {$_ -notin $accepted})
 if($remaining.Count -or !$report.PackageHashesValid -or $report.DriverComparison.Status -ne 'Matches' -or $report.EffectAclComparison.Status -ne 'Matches'){throw ('Local test preflight refused: '+($remaining -join ', '))}
 $target=Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json
 $mapping=Get-Content -LiteralPath (Join-Path $prepared fresh-mapping.json) -Raw | ConvertFrom-Json
 $context=New-DspiBackendContext -Target $target -Mapping $mapping -DllPath (Join-Path $package 'component/dspi-apo.dll') -UserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -LocalDevelopmentTest -EndpointStore:$EndpointStore
 $session=New-DspiProtectedRecovery -SessionId $RunId
 $result.RecoveryScript=Install-DspiRecoveryBundle -Session $session
 $null=Start-DspiMachineTransaction -Context $context -Session $session
 $result.Installed=$true
 if($KeepThroughReboot){
  $journal=Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json
  if($journal.State -ne 'Installed' -or !(Test-Path -LiteralPath $result.RecoveryScript -PathType Leaf)){
   throw 'Protected recovery was not verified.'
  }
  $osBoot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
  Write-Result 'reboot' @{
   RunId=$RunId
   EndpointId=$context.Plan.Scope.EndpointId
   BinarySHA256=$context.Plan.Binary.SHA256
   RecoveryScript=$result.RecoveryScript
   BootBeforeUtc=$osBoot
   State='AwaitingReboot'
  }
  $leaveAttached=$true
  return
 }
 if($RefreshDevice){$refreshAttempted=$true;Refresh-SelectedDevice;Start-Sleep -Seconds 2}
 if($ProfileBindingTest){$audioRefreshAttempted=$true;Restart-AudioForTest;Start-Sleep -Seconds 2}
 if($KeepActive){
  $journal=Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json
  if($journal.State -ne 'Installed' -or !(Test-Path -LiteralPath $result.RecoveryScript -PathType Leaf)){
   throw 'Protected recovery was not verified.'
  }
  $result.MachineMutationStarted=$true
  $result.KeptActive=$true
  Write-Result 'active' $result
  $leaveAttached=$true
  return
 }
 Write-Result 'ready' @{EndpointId=$context.Plan.Scope.EndpointId;RecoveryScript=$result.RecoveryScript;PlaybackWindowSeconds=24}
 Start-Sleep -Seconds $(if($DiagnosticBuild){13}else{24})
}catch {
 $result.Error=$_.Exception.Message
 $result.ErrorLocation=$_.ScriptStackTrace
}finally {
 if(!$leaveAttached -and $session -and (Test-Path -LiteralPath (Join-Path $session.Directory backend.json))){
  $result.MachineMutationStarted=$true
  try {
   $undo=Invoke-ProtectedRecovery
   if($audioRefreshAttempted -and ($undo.RolledBack -or $undo.Detached)){
    Restart-AudioForTest
    if(!$undo.RolledBack){$undo=Invoke-ProtectedRecovery}
   }
   if($refreshAttempted -and ($undo.RolledBack -or $undo.Detached)){
    Refresh-SelectedDevice
    Start-Sleep -Seconds 2
    if(!$undo.RolledBack){$undo=Invoke-ProtectedRecovery}
   }
   $result.RolledBack=$undo.RolledBack
   $result.PendingFile=$undo.PendingFile
  }catch{$result.RecoveryError=$_.Exception.Message}
 }
 if(!$leaveAttached){Write-Result 'done' $result}
}
if($result.Error -or $result.RecoveryError -or !$result.RolledBack){exit 1}
