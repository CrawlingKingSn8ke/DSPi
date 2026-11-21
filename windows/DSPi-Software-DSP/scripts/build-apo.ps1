param([string]$Compiler=$env:DSPI_ZIG,[string]$SampleFile,[switch]$LocalProbe)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(!$Compiler){$Compiler=Join-Path $root '.tools\zig\zig.exe'}
if(!(Test-Path -LiteralPath $Compiler)){throw 'Pass -Compiler with zig.exe path.'}
Push-Location $root
try {
    New-Item -ItemType Directory -Path build -Force | Out-Null
    $env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root 'build\zig-cache'
    & (Join-Path $PSScriptRoot 'get-apo-headers.ps1')
    foreach($file in @('firmware_coefficients.c','firmware_loudness.c','firmware_tube.c','firmware_crossfeed.c','firmware_psybass.c','firmware_subharm.c','limiter_kernel.inc','upmix_kernel.inc')){
        if(!(Test-Path -LiteralPath (Join-Path $root "build\$file"))){throw 'Run build.ps1 first to generate pinned firmware sources.'}
    }
    $sources=@('src/engine.c','src/graph.c','src/limiter_host.c','src/input_host.c','src/effects_host.c','src/upmix_host.c','src/recipe.c','src/host_api.c','src/graph_reset.c','build/firmware_coefficients.c','build/firmware_loudness.c','build/firmware_tube.c','build/firmware_crossfeed.c','build/firmware_psybass.c','build/firmware_subharm.c','vendor/dspi/crossover.c','vendor/dspi/leveller.c')
    $flags=@('-std=c11','-O2','-ffp-contract=off','-Ivendor/dspi','-Ibuild/windows-sdk','-DCONST_VTABLE')
    if($LocalProbe){$flags+='-DDSPI_LOCAL_PROBE'}
    & $Compiler cc @flags -shared -DRTA_HOST -DRTA_SAMPLE_FLOAT=1 apo/dspi_apo.c apo/live.c apo/spectrum.c vendor/dspi/rta_fft.c vendor/dspi/rta_bass.c apo/dspi-apo.def @sources -lole32 -luuid -lbcrypt -o build/dspi-apo.dll
    if($LASTEXITCODE){throw 'APO DLL build failed'}
    & $Compiler cc @flags tests/apo_test.c @sources -lole32 -luuid -o build/apo_test.exe
    if($LASTEXITCODE){throw 'APO harness build failed'}
    $testArgs=@((Join-Path $root 'build\dspi-apo.dll'))
    if($SampleFile){$testArgs+=$SampleFile}
    & '.\build\apo_test.exe' @testArgs
    if($LASTEXITCODE){throw 'APO harness failed'}
}finally{Pop-Location}
