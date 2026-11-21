$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/ProtectedStorage.psm1') -Force
function Reject([scriptblock]$action){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};if(!$failed){throw 'Expected refusal'}}
Reject {New-DspiProtectedRecovery -TestOnly -SessionId '../escape'}
Reject {Read-DspiProtectedRecord -Directory $env:TEMP -Name '../escape'}
$admin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Reject {New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))}}
Write-Output 'PASS protected storage path and elevation refusals'
