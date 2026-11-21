param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\crossfeed-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir 'left.wav';$stream=[IO.File]::Create($source);$w=[IO.BinaryWriter]::new($stream)
try{
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$w.Write([uint32]192036);$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$w.Write([uint32]16)
    $w.Write([uint16]1);$w.Write([uint16]2);$w.Write([uint32]48000);$w.Write([uint32]192000);$w.Write([uint16]4);$w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data'));$w.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++){$w.Write([int16]8000);$w.Write([int16]0)}
}finally{$w.Dispose()}
$on=Join-Path $dir 'on.wav';$off=Join-Path $dir 'off.wav';$custom=Join-Path $dir 'custom.wav'
& $Exe $source $on --crossfeed default
if($LASTEXITCODE){throw 'Crossfeed preset command failed'}
$bytes=[IO.File]::ReadAllBytes($on)
$left=[BitConverter]::ToInt16($bytes,$bytes.Length-4);$right=[BitConverter]::ToInt16($bytes,$bytes.Length-2)
if([Math]::Abs($left-5014) -gt 1 -or [Math]::Abs($right-2986) -gt 1){throw "Incorrect DC crossfeed: $left/$right"}
& $Exe $source $off --crossfeed default --crossfeed-off
if($LASTEXITCODE -or (Get-FileHash $off).Hash -ne (Get-FileHash $source).Hash){throw 'Crossfeed bypass changed data'}
& $Exe $source $custom --crossfeed-custom 2000 6 --crossfeed-itd off
if($LASTEXITCODE){throw 'Custom crossfeed/ITD command failed'}
$four=Join-Path $dir 'pair2.wav'
& $Exe $source $four --outputs 4 --route 1 3 0 --pair 2 --crossfeed meier
if($LASTEXITCODE){throw 'Crossfeed pair selection failed'}
$pair=[IO.File]::ReadAllBytes($four)
if([BitConverter]::ToInt16($pair,68) -ne 8000 -or [BitConverter]::ToInt16($pair,70) -ne 0){throw 'Crossfeed changed unselected pair'}
if([BitConverter]::ToInt16($pair,$pair.Length-2) -eq 0){throw 'Crossfeed did not reach selected second pair'}
foreach($settings in @(@('--crossfeed','unknown'),@('--crossfeed-custom','499','6'),@('--crossfeed-custom','700','16'),@('--crossfeed-itd','unknown'),@('--pair','2','--crossfeed','default'),@('--channel','left','--crossfeed','default'))){
    $bad=Join-Path $dir 'invalid.wav';& $Exe $source $bad @settings
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid crossfeed setting accepted: $settings"}
}
Write-Output 'PASS: crossfeed WAV presets/custom/ITD, selected pairs, bypass, DC balance and invalid arguments.'
