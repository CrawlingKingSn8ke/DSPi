param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\vendor\dspi\limiter.c'
if((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne '80dbc805b7cb4b5f364eccacf5eb34b0a29f5020624e15cc26e7130859ce392f'){
    throw 'Pinned limiter source changed; review extraction before building.'
}
$text=[IO.File]::ReadAllText($source)
$stateEnd=$text.IndexOf('} LimiterOutputState;',[StringComparison]::Ordinal)
$stateStart=if($stateEnd -ge 0){$text.LastIndexOf('typedef struct {',$stateEnd,[StringComparison]::Ordinal)}else{-1}
$gainStart=$text.IndexOf('static inline __attribute__((always_inline)) void lm_reset_gain(',[StringComparison]::Ordinal)
$gainEnd=$text.IndexOf('DSP_TIME_CRITICAL'+"`r`n"+'void limiter_reset_all(',[StringComparison]::Ordinal)
$ringStart=$text.IndexOf('// Delay only:',[StringComparison]::Ordinal)
$ringEnd=$text.IndexOf('#if PICO_RP2350',$ringStart,[StringComparison]::Ordinal)
$detectStart=$text.IndexOf('// Peak per block,',[StringComparison]::Ordinal)
$detectEnd=$text.IndexOf('#else  // RP2040',$detectStart,[StringComparison]::Ordinal)
if($stateStart -lt 0 -or $gainStart -lt 0 -or $gainEnd -le $gainStart -or $ringStart -lt 0 -or $ringEnd -le $ringStart -or $detectStart -lt 0 -or $detectEnd -le $detectStart){throw 'Limiter extraction markers missing'}
# Copy exact original state, reset, delay-only, float detect and float apply.
# The caller supplies context-owned state and single-thread link orchestration.
$result=$text.Substring($stateStart,$stateEnd+('} LimiterOutputState;').Length-$stateStart)+"`n"+
    $text.Substring($gainStart,$gainEnd-$gainStart)+$text.Substring($ringStart,$ringEnd-$ringStart)+$text.Substring($detectStart,$detectEnd-$detectStart)
[IO.File]::WriteAllText($Destination,$result,[Text.UTF8Encoding]::new($false))
