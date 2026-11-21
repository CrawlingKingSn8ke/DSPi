param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\vendor\dspi\crossfeed.c'
if((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'e484227896222f3efc3f698360531b67349061b0c0cad44cdcee56e826ed75d6'){
    throw 'Pinned crossfeed source changed; review extraction before building.'
}
$text=[IO.File]::ReadAllText($source)
$presets=$text.IndexOf('// Preset definitions:',[StringComparison]::Ordinal)
$presetsEnd=$text.IndexOf('// Per-output-pair filter state,',[StringComparison]::Ordinal)
$coeff=$text.IndexOf('void crossfeed_compute_coefficients(',[StringComparison]::Ordinal)
$coeffEnd=$text.IndexOf('void crossfeed_apply_config(',[StringComparison]::Ordinal)
$body=$text.IndexOf('// RP2350 Float processing',[StringComparison]::Ordinal)
$kernel=if($body -ge 0){$text.LastIndexOf('#if PICO_RP2350',$body,[StringComparison]::Ordinal)}else{-1}
$kernelEnd=$text.IndexOf('// Per-pair dispatch:',[StringComparison]::Ordinal)
if($presets -lt 0 -or $presetsEnd -le $presets -or $coeff -lt 0 -or $coeffEnd -le $coeff -or $kernel -lt 0 -or $kernelEnd -le $kernel){throw 'Crossfeed extraction markers missing'}
# Preset table, coefficient designer and both conditional kernel paths copied
# verbatim. Exclude USB/matrix globals, publication and MCU pair dispatcher.
$prefix="#include <math.h>`n#include <string.h>`n#include `"crossfeed.h`"`n"
[IO.File]::WriteAllText($Destination,$prefix+$text.Substring($presets,$presetsEnd-$presets)+$text.Substring($coeff,$coeffEnd-$coeff)+$text.Substring($kernel,$kernelEnd-$kernel),[Text.UTF8Encoding]::new($false))
