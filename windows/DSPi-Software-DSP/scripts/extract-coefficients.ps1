param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$vendor=Join-Path $PSScriptRoot '..\vendor\dspi'
$source=Join-Path $vendor 'dsp_pipeline.c'
$expected='783b508e7737be705803a71bcd5447b67adb63ecf6c0c408803c71c4b714faa6'
if((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Pinned firmware pipeline hash changed; review the extraction before building.'
}
$text=[IO.File]::ReadAllText($source)
function Extract-Between([string]$start,[string]$end) {
    $a=$text.IndexOf($start,[StringComparison]::Ordinal)
    $b=$text.IndexOf($end,$a,[StringComparison]::Ordinal)
    if($a -lt 0 -or $b -le $a) { throw 'Firmware extraction markers missing' }
    return $text.Substring($a,$b-$a)
}
# Build output only: function bodies copied verbatim from pinned upstream C.
# Skip MCU globals, delay lines, assembly includes and peripheral scheduling.
$helper=Extract-Between 'static inline bool is_filter_flat(' 'Filter filters['
$designer=Extract-Between 'void dsp_compute_coefficients(' 'void dsp_init_default_filters('
$prefix="#include <math.h>`n#include <stdbool.h>`n#include `"dsp_pipeline.h`"`n"
[IO.File]::WriteAllText($Destination,$prefix+$helper+$designer,[Text.UTF8Encoding]::new($false))
