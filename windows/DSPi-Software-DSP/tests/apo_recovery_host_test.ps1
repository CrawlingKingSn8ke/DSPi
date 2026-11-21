param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$installer=Join-Path $repo 'apo/deployment/Install-DspiRecoveryHost.ps1'
$status=& $installer -ArchivePath $ArchivePath -ValidateOnly
if(!$status.Validated -or $status.Installed -or $status.Version -ne '7.6.9'){throw 'Pinned recovery host validation failed'}
$bad=Join-Path $repo ('build/bad-host-'+[guid]::NewGuid().ToString('N')+'.zip')
[IO.File]::WriteAllBytes($bad,[byte[]]@(1,2,3,4))
$rejected=$false
try{& $installer -ArchivePath $bad -ValidateOnly | Out-Null}catch{$rejected=$_.Exception.Message -like '*hash mismatch*'}
if(!$rejected){throw 'Modified recovery host archive was accepted'}
Write-Output 'PASS official recovery-host hash, contents and modified-archive refusal'
