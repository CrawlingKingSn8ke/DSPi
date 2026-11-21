param([Parameter(Mandatory)][string]$PackagePath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$cache=Join-Path $root ('build/wdk-cache-'+[guid]::NewGuid().ToString('N'))
$outside=$cache+'-outside'
New-Item -ItemType Directory -Path $cache,$outside | Out-Null
New-Item -ItemType Junction -Path (Join-Path $cache 'x64') -Target $outside | Out-Null
$rejected=$false
try{& (Join-Path $root 'scripts/get-wdk-validation-tools.ps1') -Destination $cache -PackagePath $PackagePath | Out-Null}catch{$rejected=$_.Exception.Message -like '*reparse*'}
if(!$rejected){throw 'Tool extraction must reject a redirected x64 child directory'}
if(@(Get-ChildItem -LiteralPath $outside -Force).Count){throw 'Redirected directory must remain untouched'}
Write-Output 'PASS WDK child-path reparse rejection before extraction'
