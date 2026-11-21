param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\loudness-'+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir '50Hz.wav'
$stream=[IO.File]::Create($source);$writer=[IO.BinaryWriter]::new($stream)
try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32]192036)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16)
    $writer.Write([uint16]1);$writer.Write([uint16]2);$writer.Write([uint32]48000)
    $writer.Write([uint32]192000);$writer.Write([uint16]4);$writer.Write([uint16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++) {
        $v=[int16](12000*[Math]::Sin(2*[Math]::PI*50*$i/48000));$writer.Write($v);$writer.Write($v)
    }
}finally{$writer.Dispose()}
$on=Join-Path $dir 'on.wav';$off=Join-Path $dir 'off.wav';$reordered=Join-Path $dir 'reordered.wav'
& $Exe $source $on --volume -20 --channel left --loudness 83 100
if($LASTEXITCODE){throw 'Loudness command failed'}
& $Exe $source $off --volume -20 --loudness 83 100 --loudness-off
if($LASTEXITCODE){throw 'Loudness-off command failed'}
& $Exe $source $reordered --channel left --loudness 83 100 --volume -20
if($LASTEXITCODE){throw 'Reordered loudness command failed'}
if((Get-FileHash $on).Hash -ne (Get-FileHash $reordered).Hash){throw 'Loudness curve depends on CLI option order'}
$original=[IO.File]::ReadAllBytes($source);$enabled=[IO.File]::ReadAllBytes($on);$disabled=[IO.File]::ReadAllBytes($off)
$power=0.0;$leftPower=0.0;$rightPower=0.0
for($i=44+24000*4;$i -lt $original.Length;$i+=4){
    $x=[BitConverter]::ToInt16($original,$i);$l=[BitConverter]::ToInt16($enabled,$i);$r=[BitConverter]::ToInt16($enabled,$i+2)
    $power+=$x*$x;$leftPower+=$l*$l;$rightPower+=$r*$r
    if($r -ne [BitConverter]::ToInt16($disabled,$i+2)){throw 'Loudness altered an unselected output'}
}
$leftDb=10*[Math]::Log10($leftPower/$power);$rightDb=10*[Math]::Log10($rightPower/$power)
if([Math]::Abs($leftDb+11.7656798323) -gt 0.02 -or [Math]::Abs($rightDb+20) -gt 0.02){throw "Unexpected loudness response: $leftDb / $rightDb"}
$silent=Join-Path $dir 'silent.wav'
& $Exe $source $silent --volume -60 --loudness 83 100
if($LASTEXITCODE){throw 'Minimum volume command failed'}
$silence=[IO.File]::ReadAllBytes($silent)
for($i=44;$i -lt $silence.Length;$i++){if($silence[$i] -ne 0){throw 'Minimum volume is not silent'}}
foreach($settings in @(@('--volume','1'),@('--volume','NaN'),@('--loudness','39','100'),@('--loudness','83','201'))){
    $bad=Join-Path $dir 'invalid.wav'
    & $Exe $source $bad @settings
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid loudness settings accepted: $settings"}
}
Write-Output "PASS: WAV loudness left=$leftDb dB, unselected right=$rightDb dB; order, disable, minimum-volume and invalid-setting checks."
