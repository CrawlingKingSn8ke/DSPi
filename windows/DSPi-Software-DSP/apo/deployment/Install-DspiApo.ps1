# GPL-3.0. Fail-closed live-install entry point; check mode is the default.
# Unsigned or otherwise unvalidated builds never reach elevation or machine writes.
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$TargetPlan,[switch]$Install)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$prepared=& (Join-Path $PSScriptRoot 'Prepare-DspiRecovery.ps1') -PackageRoot $PackageRoot -TargetPlan $TargetPlan -OutputName ('installer-check-'+[guid]::NewGuid().ToString('N'))
$report=Get-Content -LiteralPath (Join-Path $prepared 'readiness.json') -Raw | ConvertFrom-Json
$plan=Get-Content -LiteralPath (Join-Path $prepared 'attachment-plan.json') -Raw | ConvertFrom-Json
$unsigned=@($report.Signatures | Where-Object Status -ne 'Valid').Count -gt 0
Import-Module (Join-Path $PSScriptRoot 'InstallerPolicy.psm1') -Force
$gates=@(Get-DspiLiveInstallBlockers $report)
$status=[pscustomobject]@{ReadOnly=$true;Installed=$false;CanInstall=$false;PackageHashesValid=$report.PackageHashesValid;Scope=$report.Scope;EvidenceDirectory=$prepared;Unsigned=$unsigned;Blockers=$gates;ProtectedRecoveryStorageImplemented=$true;MachineBackendImplemented=$true;LiveAudioVerified=$false;InstallChecksRequired=@('ElevatedAdministrator','TrustedPowerShell7Host','ActualAudiodgTokenAccess','RegistryWriteAccess');PostInstallChecksRequired=@('AudiodgLoad','WindowsEffectCoexistence','ActualProcessingAndRecovery')}
if(!$Install){return $status}
if($unsigned){throw 'Installation refused: the APO DLL or catalogs are unsigned/untrusted. No elevation, recovery folder, audio registration or settings change was attempted.'}
if($gates.Count){throw ('Installation refused before machine writes: '+($gates -join ', '))}
Import-Module (Join-Path $PSScriptRoot 'MachineBackend.psm1')
Import-Module (Join-Path $PSScriptRoot 'ProtectedStorage.psm1')
Assert-DspiAdministrator
$trustedHost=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'PowerShell\7\pwsh.exe'
if((Get-Process -Id $PID).Path -ine $trustedHost -or !(Test-Path -LiteralPath $trustedHost) -or (Get-AuthenticodeSignature -LiteralPath $trustedHost).Status -ne 'Valid'){throw 'Live installation requires a trusted, installed PowerShell7 host under Program Files; a user-writable runtime is not a recovery host.'}
$target=Get-Content -LiteralPath $TargetPlan -Raw | ConvertFrom-Json
$mapping=Get-Content -LiteralPath (Join-Path $prepared 'fresh-mapping.json') -Raw | ConvertFrom-Json
$context=New-DspiBackendContext -Target $target -Mapping $mapping -DllPath (Join-Path $PackageRoot 'component/dspi-apo.dll') -UserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
$session=New-DspiProtectedRecovery -SessionId ([guid]::NewGuid().ToString('N'))
$recovery=Install-DspiRecoveryBundle -Session $session
try{
 $result=Start-DspiMachineTransaction -Context $context -Session $session
 $result | Add-Member -NotePropertyName RecoveryScript -NotePropertyValue $recovery
 $result | Add-Member -NotePropertyName VerifiedProcessing -NotePropertyValue $false
 $result | Add-Member -NotePropertyName RequiresNewAudioStream -NotePropertyValue $true
 $result | Add-Member -NotePropertyName EndpointPropagationUnverified -NotePropertyValue $true
 $result
}catch{
 $failure=$_.Exception.Message;$restored=$false
 if(Test-Path -LiteralPath (Join-Path $session.Directory backend.json)){
  try{$undo=Undo-DspiMachineTransaction -Session $session;$restored=[bool]$undo.RolledBack;if(!$restored){$failure+='; binary cleanup is pending file release'}}catch{$failure+='; recovery requires attention: '+$_.Exception.Message}
 }
 $noChanges=!(Test-Path -LiteralPath (Join-Path $session.Directory backend.json))
 $null=Write-DspiProtectedRecord -Directory $session.Directory -Name failure.json -Value @{Error=$failure;RollbackCompleted=$restored;NoMachineChangesMade=$noChanges;RecoveryScript=$recovery}
 throw ('Installation failed. '+$failure+'. Protected recovery: '+$recovery)
}
