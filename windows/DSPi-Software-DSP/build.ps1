param([string]$Compiler = $env:DSPI_ZIG)
$ErrorActionPreference='Stop'
if (!$Compiler) { $Compiler=Join-Path $PSScriptRoot '.tools\zig\zig.exe' }
if (!(Test-Path -LiteralPath $Compiler)) { throw 'Set DSPI_ZIG or pass -Compiler with the path to zig.exe.' }
$out=Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $out 'zig-cache'
Push-Location $PSScriptRoot
try {
    & (Join-Path $PSScriptRoot 'scripts\extract-coefficients.ps1') -Destination (Join-Path $out 'firmware_coefficients.c')
    & (Join-Path $PSScriptRoot 'scripts\extract-loudness.ps1') -Destination (Join-Path $out 'firmware_loudness.c')
    & (Join-Path $PSScriptRoot 'scripts\extract-tube.ps1') -Destination (Join-Path $out 'firmware_tube.c')
    & (Join-Path $PSScriptRoot 'scripts\extract-crossfeed.ps1') -Destination (Join-Path $out 'firmware_crossfeed.c')
    & (Join-Path $PSScriptRoot 'scripts\extract-limiter.ps1') -Destination (Join-Path $out 'limiter_kernel.inc')
    & (Join-Path $PSScriptRoot 'scripts\extract-effects.ps1') -Destination $out
    $native=@('src/engine.c','src/graph.c','src/limiter_host.c','build/firmware_coefficients.c','build/firmware_loudness.c','build/firmware_tube.c','build/firmware_crossfeed.c','vendor/dspi/crossover.c')
    $flags=@('-std=c11','-O2','-ffp-contract=off','-Ivendor/dspi')
    $native+=@('src/input_host.c','src/effects_host.c','src/upmix_host.c','build/firmware_psybass.c','build/firmware_subharm.c','vendor/dspi/leveller.c')
    $native+=@('src/recipe.c','src/host_api.c','src/graph_reset.c')
    & $Compiler cc @flags tests/runtime_test.c @native -o build/runtime_test.exe
    if($LASTEXITCODE) { throw 'Runtime test build failed' }
    & (Join-Path $out 'runtime_test.exe')
    if($LASTEXITCODE) { throw 'Runtime checks failed' }
    & $Compiler cc @flags tests/runtime_stress_test.c @native -o build/runtime_stress_test.exe
    if($LASTEXITCODE) { throw 'Runtime stress test build failed' }
    & (Join-Path $out 'runtime_stress_test.exe')
    if($LASTEXITCODE) { throw 'Runtime stress checks failed' }
    & $Compiler cc @flags -shared @native -o build/dspi-host.dll
    if($LASTEXITCODE) { throw 'Native host DLL build failed' }
    & $Compiler cc @flags tests/input_test.c @native -o build/input_test.exe
    if($LASTEXITCODE) { throw 'Input test build failed' }
    & (Join-Path $out 'input_test.exe')
    if($LASTEXITCODE) { throw 'Input checks failed' }
    & $Compiler cc @flags tests/effects_test.c @native -o build/effects_test.exe
    if($LASTEXITCODE) { throw 'Effects test build failed' }
    & (Join-Path $out 'effects_test.exe')
    if($LASTEXITCODE) { throw 'Effects checks failed' }
    & $Compiler cc @flags tests/engine_test.c @native -o build/engine_test.exe
    if($LASTEXITCODE) { throw 'Native test build failed' }
    & (Join-Path $out 'engine_test.exe')
    if($LASTEXITCODE) { throw 'DSP checks failed' }
    & $Compiler cc @flags tests/chain_test.c @native -o build/chain_test.exe
    if($LASTEXITCODE) { throw 'Chain test build failed' }
    & (Join-Path $out 'chain_test.exe')
    if($LASTEXITCODE) { throw 'Chain checks failed' }
    & $Compiler cc @flags tests/graph_test.c @native -o build/graph_test.exe
    if($LASTEXITCODE) { throw 'Graph test build failed' }
    & (Join-Path $out 'graph_test.exe')
    if($LASTEXITCODE) { throw 'Matrix/gain/delay checks failed' }
    & $Compiler cc @flags tests/loudness_test.c @native -o build/loudness_test.exe
    if($LASTEXITCODE) { throw 'Loudness test build failed' }
    & (Join-Path $out 'loudness_test.exe')
    if($LASTEXITCODE) { throw 'Loudness checks failed' }
    & $Compiler cc @flags tests/tube_test.c @native -o build/tube_test.exe
    if($LASTEXITCODE) { throw 'Tube test build failed' }
    & (Join-Path $out 'tube_test.exe')
    if($LASTEXITCODE) { throw 'Tube checks failed' }
    & $Compiler cc @flags tests/crossfeed_test.c @native -o build/crossfeed_test.exe
    if($LASTEXITCODE) { throw 'Crossfeed test build failed' }
    & (Join-Path $out 'crossfeed_test.exe')
    if($LASTEXITCODE) { throw 'Crossfeed checks failed' }
    & $Compiler cc @flags tests/limiter_test.c @native -o build/limiter_test.exe
    if($LASTEXITCODE) { throw 'Limiter test build failed' }
    & (Join-Path $out 'limiter_test.exe')
    if($LASTEXITCODE) { throw 'Limiter checks failed' }
    if(Test-Path src/wav_main.c) {
        & $Compiler cc @flags src/wav_main.c @native -o build/dspi-wav.exe
        if($LASTEXITCODE) { throw 'WAV processor build failed' }
        & (Join-Path $PSScriptRoot 'tests\wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\routing_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\loudness_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\tube_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\crossfeed_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\limiter_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\effects_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
        & (Join-Path $PSScriptRoot 'tests\input_wav_test.ps1') -Exe (Join-Path $out 'dspi-wav.exe')
    }
} finally { Pop-Location }
# Rejection tests deliberately run the tool with invalid input. They throw on
# an unexpected outcome; their expected nonzero exit must not escape the suite.
$global:LASTEXITCODE=0
