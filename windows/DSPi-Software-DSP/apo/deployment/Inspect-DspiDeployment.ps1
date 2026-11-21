[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$DllPath,
    [string]$FixturePath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Inspection.psm1') -Force
# Reports are the only writes. Require an existing staging build directory, no overwrite.
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
if (-not $output.StartsWith($build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPath must be inside this staging repository build directory.' }
$parent=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($output))
if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Report parent must not be a link.' }
$cursor=$parent
while ($cursor.FullName.Length -ge $build.Length) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Report ancestors must not be links.' }
    $cursor=$cursor.Parent
    if ($null -eq $cursor) { break }
}
if (Test-Path -LiteralPath $output) { throw 'Report already exists; choose a new explicit output path.' }
$inventory=if ($FixturePath) { Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json } else { Get-DspiLiveInventory }
$report=New-DspiInspectionReport -Inventory $inventory -DllFacts (Get-DspiDllFacts $DllPath)
$json=$report | ConvertTo-Json -Depth 40
$file=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json); $file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
Write-Output $output
