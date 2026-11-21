param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\vendor\dspi\loudness.c'
if((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne '71644cb5422fc80b3876669da5c6d0f5752c2f569606433881b956c4d3fed8a8') {
    throw 'Pinned loudness source changed; review extraction before building.'
}
$text=[IO.File]::ReadAllText($source)
$start=$text.IndexOf('// ISO 226:2003 Constants',[StringComparison]::Ordinal)
$end=$text.IndexOf('// Build in progress',[StringComparison]::Ordinal)
if($start -lt 0 -or $end -le $start){throw 'Loudness extraction markers missing'}
# Firmware maths and compute_vol_step are copied verbatim; omit Pico job scheduler.
$prefix="#include <math.h>`n#include `"loudness.h`"`n"
$wrapper="`nvoid dspi_loudness_design(int step,float ref,float intensity,float rate,LoudnessCoeffs out[2]) { compute_vol_step(step,ref,intensity,rate,out); }`n"
[IO.File]::WriteAllText($Destination,$prefix+$text.Substring($start,$end-$start)+$wrapper,[Text.UTF8Encoding]::new($false))
