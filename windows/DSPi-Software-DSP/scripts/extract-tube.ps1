param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\vendor\dspi\tube.c'
if((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'dad48bc7f8d08d8774eaa132da88ec9d0eea93cfc6658cf93c5f04006b1a39c0'){
    throw 'Pinned tube source changed; review extraction before building.'
}
$text=[IO.File]::ReadAllText($source)
$rowsStart=$text.IndexOf('// Tube style rows',[StringComparison]::Ordinal)
$rowsEnd=$text.IndexOf('// Indexed parameter access',[StringComparison]::Ordinal)
$coeffStart=$text.IndexOf('// One-pole coefficient a',[StringComparison]::Ordinal)
$coeffEnd=$text.IndexOf('void tube_apply_config(',[StringComparison]::Ordinal)
$body=$text.IndexOf('// Branch-free float body.',[StringComparison]::Ordinal)
$kernelStart=if($body -ge 0){$text.LastIndexOf('#if PICO_RP2350',$body,[StringComparison]::Ordinal)}else{-1}
if($rowsStart -lt 0 -or $rowsEnd -le $rowsStart -or $coeffStart -lt 0 -or $coeffEnd -le $coeffStart -or $kernelStart -lt 0){throw 'Tube extraction markers missing'}
# Original style/rectifier tables, designer and full kernel kept unchanged.
# Skip USB notification setters and MCU globals/double-buffer publication.
$prefix="#include <math.h>`n#include <string.h>`n#include `"tube.h`"`n"
$wrappers=@'

TubeConfig dspi_tube_defaults(void) {
    return (TubeConfig){
        .enabled=false,.tube_type=TUBE_DEFAULT_TUBE_TYPE,.rectifier=TUBE_DEFAULT_RECTIFIER,
        .xfmr_enabled=TUBE_DEFAULT_XFMR_ENABLED,.output_mask=0,
        .drive_db=TUBE_DEFAULT_DRIVE,.bias_pct=TUBE_DEFAULT_BIAS,.asym_db=TUBE_DEFAULT_ASYM,
        .hardness_pct=TUBE_DEFAULT_HARDNESS,.sag_pct=TUBE_DEFAULT_SAG,
        .xfmr_damping=TUBE_DEFAULT_XFMR_DAMPING,.xfmr_res_hz=TUBE_DEFAULT_XFMR_RES,
        .mix_pct=TUBE_DEFAULT_MIX,.trim_db=TUBE_DEFAULT_TRIM
    };
}
bool dspi_tube_style(TubeConfig *c,unsigned style) {
    if(!c||style>TUBE_TYPE_MAX)return false;
    if(style){const TubeRow *r=&tube_rows[style-1];
        c->bias_pct=r->bias;c->asym_db=r->asym;c->hardness_pct=r->hardness;c->sag_pct=r->sag;
    }
    c->tube_type=(uint8_t)style;return true;
}
'@
$generated=$prefix+$text.Substring($rowsStart,$rowsEnd-$rowsStart)+$text.Substring($coeffStart,$coeffEnd-$coeffStart)+$text.Substring($kernelStart)+$wrappers
[IO.File]::WriteAllText($Destination,$generated,[Text.UTF8Encoding]::new($false))
