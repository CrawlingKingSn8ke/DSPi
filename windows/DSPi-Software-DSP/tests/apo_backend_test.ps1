$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/MachineBackend.psm1') -Force
$repo=Split-Path $PSScriptRoot -Parent
$target=Get-Content (Join-Path $repo 'build/dspi-usb-target-20261117.json') -Raw | ConvertFrom-Json
$mapping=Get-Content (Join-Path $repo 'build/dspi-endpoint-mapping-20261118.json') -Raw | ConvertFrom-Json
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
 $rejected=$false;try{New-DspiBackendFixture -Target $target -Mapping $mapping -DllPath (Join-Path $repo 'build/dspi-apo.dll')}catch{$rejected=$true}
 if(!$rejected){throw 'Backend creation requires elevation.'}
 Write-Output 'PASS machine backend elevation refusal'
 return
}
throw 'Run the elevated fixture helper for mutation tests.'
