param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$TargetPlan)
$ErrorActionPreference='Stop'
$installer=Join-Path $PSScriptRoot '../apo/deployment/Install-DspiApo.ps1'
$class='Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
$before=Test-Path -LiteralPath $class
$base=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'DSPi-Recovery'
$storageBefore=Test-Path -LiteralPath $base
$rejected=$false
try{& $installer -PackageRoot $PackageRoot -TargetPlan $TargetPlan -Install | Out-Null}catch{$rejected=$_.Exception.Message -like '*unsigned*'}
if(!$rejected){throw 'Unsigned real package must be rejected explicitly before elevation or writes'}
if((Test-Path -LiteralPath $class) -ne $before -or (Test-Path -LiteralPath $base) -ne $storageBefore){throw 'Blocked installer changed machine registration or created recovery storage'}
$status=& $installer -PackageRoot $PackageRoot -TargetPlan $TargetPlan
if($status.CanInstall -or $status.Installed -or !$status.ReadOnly -or !$status.PackageHashesValid){throw 'Check-only mode must report actual blocked state'}
Write-Output 'PASS live installer unsigned rejection before machine writes and read-only readiness'
