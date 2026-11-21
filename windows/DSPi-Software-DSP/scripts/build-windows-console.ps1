param([string]$Compiler=$env:DSPI_ZIG,[string]$ConsoleRoot=(Join-Path $PSScriptRoot '..\..\DSPi-Console-Windows'))
$ErrorActionPreference='Stop'
$engineRoot=Split-Path -Parent $PSScriptRoot
& (Join-Path $engineRoot 'build.ps1') -Compiler $Compiler
if($LASTEXITCODE){throw 'Native engine checks failed'}
if(!(Test-Path -LiteralPath (Join-Path $engineRoot 'build\dspi-host.dll'))){throw 'Native host DLL was not produced'}
$fixture=Join-Path $ConsoleRoot 'DSPiConsole.Core.Tests\Fixtures\mac-shared-schema.dspipreset'
& dotnet run --project (Join-Path $engineRoot 'managed\Dspi.Software.Tests\Dspi.Software.Tests.csproj') -c Release -- $fixture
if($LASTEXITCODE){throw 'Managed preset/runtime checks failed'}
& dotnet run --project (Join-Path $engineRoot 'managed\Dspi.Audio.Core.Tests\Dspi.Audio.Core.Tests.csproj') -c Release
if($LASTEXITCODE){throw 'Live audio core checks failed'}
& dotnet run --project (Join-Path $engineRoot 'managed\Dspi.Audio.Windows.Tests\Dspi.Audio.Windows.Tests.csproj') -c Release
if($LASTEXITCODE){throw 'WASAPI transport/decoder checks failed'}
foreach($project in @('DSPiConsole.sln','DSPiConsole.Core.Tests\DSPiConsole.Core.Tests.csproj','DSPiConsole.Software.Tests\DSPiConsole.Software.Tests.csproj')){
    & dotnet restore (Join-Path $ConsoleRoot $project) -p:Platform=x64 --ignore-failed-sources --verbosity minimal
    if($LASTEXITCODE){throw "Console dependency restore failed: $project"}
}
& dotnet test (Join-Path $ConsoleRoot 'DSPiConsole.Core.Tests\DSPiConsole.Core.Tests.csproj') -p:Platform=x64 -c Debug --no-restore --verbosity minimal
if($LASTEXITCODE){throw 'Console core/device checks failed'}
& dotnet build (Join-Path $ConsoleRoot 'DSPiConsole.Software.Tests\DSPiConsole.Software.Tests.csproj') -p:Platform=x64 -c Debug --no-restore --verbosity minimal
if($LASTEXITCODE){throw 'Software Console integration test build failed'}
& dotnet (Join-Path $ConsoleRoot 'DSPiConsole.Software.Tests\bin\x64\Debug\net8.0-windows10.0.19041.0\DSPiConsole.Software.Tests.dll')
if($LASTEXITCODE){throw 'Software Console integration checks failed'}
& dotnet build (Join-Path $ConsoleRoot 'DSPiConsole.sln') -p:Platform=x64 -c Debug --no-restore --verbosity minimal
if($LASTEXITCODE){throw 'Console x64 build failed'}
$global:LASTEXITCODE=0
