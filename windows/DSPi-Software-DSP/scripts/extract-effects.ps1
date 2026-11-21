param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$vendor=Join-Path $PSScriptRoot '..\vendor\dspi'
function ReadPinned($name,$hash) {
    $path=Join-Path $vendor $name
    if((Get-FileHash $path -Algorithm SHA256).Hash -ne $hash){throw "Pinned $name changed"}
    return [IO.File]::ReadAllText($path)
}
function Between($s,$a,$b) {
    $i=$s.IndexOf($a,[StringComparison]::Ordinal); $j=$s.IndexOf($b,[StringComparison]::Ordinal)
    if($i -lt 0 -or $j -le $i){throw "Extraction markers missing: $a / $b"}
    return $s.Substring($i,$j-$i)
}
function WriteGenerated($name,$s){[IO.File]::WriteAllText((Join-Path $Destination $name),$s,[Text.UTF8Encoding]::new($false))}
$null=ReadPinned 'leveller.c' '81B3B3F92FA07257AA7A871D591B6A34B68B72376D6937FD0B116EEA0670424A'
$null=ReadPinned 'psybass.h' '03BAFE64D5840DCCAAA3EE94E37B99E96679C13BC50CBD61B9B4F58F60616E93'
$null=ReadPinned 'subharm.h' '3E1A3F49B22F7032D410A609328144A272B8F281B5EB422D081819055CB81B89'
$null=ReadPinned 'leveller.h' '86C94B35EBAD00ED3BAC060F857B5D0A00F2E25B6916598617E572C568332063'
$null=ReadPinned 'upmix.h' 'EB3E8E155391E5D13F27E1CDDAA1C5E8F9E01B24B0FA36009F580E22E6F886E1'
$p=ReadPinned 'psybass.c' '976808568A4EB38641665F3BA78D5A3B2C9EAA52D97727E3B34F024DD9214332'
WriteGenerated 'firmware_psybass.c' ("#include <math.h>`n#include <string.h>`n#include `"psybass.h`"`n"+(Between $p 'static inline float clampf' 'void psybass_apply_config('))
$s=ReadPinned 'subharm.c' '221C6E2DDAE7FB25B62FBF60800EA3F8B1AD0967C95524598A4A4ECCE1C813DA'
WriteGenerated 'firmware_subharm.c' ("#include <math.h>`n#include <string.h>`n#include `"subharm.h`"`n"+(Between $s 'static const float sh_pi' 'static inline bool sh_output_eligible'))
$u=ReadPinned 'upmix.c' 'C5926BCE00AFE1B0A52F6B46BD751A67840177DE28DFD1D2B15C67347FC8DFBF'
$state=Between $u 'typedef struct {' 'static UpmixState um;'
$design=Between $u 'static inline float clampf' '// Rate gate snapshot'
$kernel=Between $u 'void upmix_process_block(' '#endif // PICO_RP2350'
# Only adaptation: pass the formerly global state as a context. DSP math unchanged.
$kernel=$kernel.Replace('void upmix_process_block(','static void host_upmix_process_block(UpmixState *state,').Replace('um.','state->').Replace('upmix_state_dirty = true;','/* host owns activation state */')
WriteGenerated 'upmix_kernel.inc' ($state+$design+$kernel)
