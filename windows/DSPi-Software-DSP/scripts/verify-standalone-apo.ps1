param([string]$Compiler=$env:DSPI_ZIG,[string]$ConsoleRoot=(Join-Path $PSScriptRoot '..\..\DSPi-Console-Windows'),[string]$SampleFile)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$ConsoleRoot=[IO.Path]::GetFullPath($ConsoleRoot)
& (Join-Path $PSScriptRoot 'build-windows-console.ps1') -Compiler $Compiler -ConsoleRoot $ConsoleRoot
if($LASTEXITCODE){throw 'Existing engine/Console regressions failed'}
$apoArgs=@{Compiler=$Compiler}
if($SampleFile){$apoArgs.SampleFile=$SampleFile}
& (Join-Path $PSScriptRoot 'build-apo.ps1') @apoArgs
if($LASTEXITCODE){throw 'Native APO verification failed'}
& dotnet run --project (Join-Path $root 'managed\Dspi.Apo.Tests\Dspi.Apo.Tests.csproj') -c Release
if($LASTEXITCODE){throw 'Managed APO profile tests failed'}
$project=Join-Path $ConsoleRoot 'DSPiConsole.Apo.Tests\DSPiConsole.Apo.Tests.csproj'
& dotnet build $project -p:Platform=x64 -c Debug --verbosity minimal
if($LASTEXITCODE){throw 'APO Console integration test build failed'}
& dotnet (Join-Path $ConsoleRoot 'DSPiConsole.Apo.Tests\bin\x64\Debug\net8.0-windows10.0.19041.0\DSPiConsole.Apo.Tests.dll') (Join-Path $root 'build\apo_test.exe') (Join-Path $root 'build\dspi-apo.dll')
if($LASTEXITCODE){throw 'Real native/Console integration failed'}
& (Join-Path $root 'tests\apo_deployment_test.ps1')
& (Join-Path $root 'tests\apo_target_test.ps1')
Write-Output 'PASS standalone APO verification; no device installation or physical audio stream was started.'
