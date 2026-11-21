$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/InstallerPolicy.psm1') -Force
$r=[pscustomobject]@{SchemaVersion=1;Signatures=@([pscustomobject]@{Status='Valid'},[pscustomobject]@{Status='Valid'},[pscustomobject]@{Status='Valid'});Blockers=@('ProtectedAudioAndDriverPackageTrustNotValidated','ActualAudiodgProcessingNotVerified')}
$gates=@(Get-DspiLiveInstallBlockers $r)
if('ProtectedAudioAndDriverPackageTrustNotValidated' -notin $gates){throw 'Signed DLL must not bypass protected-audio trust gate'}
$r.Blockers+= 'UnknownFutureSafetyGate'
if('UnknownFutureSafetyGate' -notin @(Get-DspiLiveInstallBlockers $r)){throw 'Unknown gates must fail closed'}
$r.Signatures[0].Status='NotSigned'
if('PackageOrDllNotTrusted' -notin @(Get-DspiLiveInstallBlockers $r)){throw 'Invalid signature must block'}
Write-Output 'PASS installer policy preserves protected-audio, unsigned and unknown gates'
