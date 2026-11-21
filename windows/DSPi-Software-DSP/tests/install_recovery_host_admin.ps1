param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/MachineBackend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/ProtectedStorage.psm1')
Assert-DspiAdministrator
$session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
$sddl='O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
$partial=Join-Path $session.Directory partial.bin
$failed=$false;try{[DspiMachine.Native]::TestFileWriteFailure($partial,[byte[]]@(1,2,3),$sddl)}catch{$failed=$true}
if(!$failed -or (Test-Path -LiteralPath $partial)){throw 'Native partial-write cleanup failed.'}
$existing=Join-Path $session.Directory existing.bin
[DspiMachine.Native]::File($existing,[byte[]]@(7),$sddl)
$failed=$false;try{[DspiMachine.Native]::TestFileWriteFailure($existing,[byte[]]@(9),$sddl)}catch{$failed=$true}
if(!$failed -or [IO.File]::ReadAllBytes($existing)[0] -ne 7){throw 'Native failed creation modified an existing file.'}
[IO.File]::Delete($existing)
Remove-DspiProtectedTestRecovery -Session $session -ExpectedRecords @{}
$result=& (Join-Path $PSScriptRoot '../apo/deployment/Install-DspiRecoveryHost.ps1') -ArchivePath $ArchivePath
if(!$result.Installed){throw 'Recovery host was not installed.'}
$target=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'PowerShell\7'
[DspiMachine.Native]::File((Join-Path $target dspi-host-tests.json),[Text.Encoding]::UTF8.GetBytes((@{PartialWriteCleaned=$true;ExistingFilePreserved=$true;VersionVerified=$true;SignatureVerified=$true} | ConvertTo-Json)),'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)')
