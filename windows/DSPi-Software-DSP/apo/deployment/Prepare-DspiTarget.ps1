param([Parameter(Mandatory)][string]$InspectionPath,[Parameter(Mandatory)][string]$EndpointId,[Parameter(Mandatory)][string]$DllPath,[Parameter(Mandatory)][string]$OutputPath,[string]$AudioTokenReportPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Inspection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TargetPlan.psm1') -Force
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
if(!$output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Target report must remain in this repository build directory.'}
$parent=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($output))
for($cursor=$parent;$null -ne $cursor -and $cursor.FullName.Length -ge $root.Length;$cursor=$cursor.Parent){
    if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Target report ancestors must not be links.'}
}
$inspection=Get-Content -LiteralPath $InspectionPath -Raw | ConvertFrom-Json
$tokenReport=if($AudioTokenReportPath){Get-Content -LiteralPath $AudioTokenReportPath -Raw | ConvertFrom-Json}else{$null}
$result=New-DspiTargetPlan -Inspection $inspection -EndpointId $EndpointId -DllFacts (Get-DspiDllFacts $DllPath) -AudioTokenReport $tokenReport
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Depth 50))
$stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
Write-Output $output
