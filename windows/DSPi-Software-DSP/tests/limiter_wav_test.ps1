param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\limiter-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir 'peaks.wav';$stream=[IO.File]::Create($source);$w=[IO.BinaryWriter]::new($stream)
try{
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$w.Write([uint32]192036);$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$w.Write([uint32]16)
    $w.Write([uint16]1);$w.Write([uint16]2);$w.Write([uint32]48000);$w.Write([uint32]192000);$w.Write([uint16]4);$w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data'));$w.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++){
        $v=if($i -lt 64){[int16]1000}else{[int16](30000*[Math]::Sin(2*[Math]::PI*1000*$i/48000))}
        $w.Write($v);$w.Write([int16]($v/4))
    }
}finally{$w.Dispose()}
$limited=Join-Path $dir 'limited.wav';$off=Join-Path $dir 'off.wav';$leftOnly=Join-Path $dir 'left-only.wav'
& $Exe $source $limited --limiter -6 100 --limiter-link 1
if($LASTEXITCODE){throw 'Linked limiter command failed'}
$inputBytes=[IO.File]::ReadAllBytes($source);$bytes=[IO.File]::ReadAllBytes($limited)
$ceiling=32768*[Math]::Pow(10,-6/20.0);$peak=0
for($i=0;$i -lt 48000;$i++){
    $left=[BitConverter]::ToInt16($bytes,44+$i*4);$right=[BitConverter]::ToInt16($bytes,46+$i*4)
    if([Math]::Abs($left) -gt $peak){$peak=[Math]::Abs($left)}
    if([Math]::Abs($right-$left/4.0) -gt 1.5){throw 'Linked limiter shifted stereo ratio'}
    if($i -lt 32 -and ($left -ne 0 -or $right -ne 0)){throw 'Missing limiter lookahead'}
}
if($peak -gt [Math]::Ceiling($ceiling)){throw "Limiter overshoot: $peak > $ceiling"}
if([BitConverter]::ToInt16($bytes,44+32*4) -ne 1000){throw 'Wrong lookahead impulse/step alignment'}
& $Exe $source $off --limiter -6 100 --limiter-off
if($LASTEXITCODE -or (Get-FileHash $off).Hash -ne (Get-FileHash $source).Hash){throw 'Disabled limiter changed audio/delay'}
& $Exe $source $leftOnly --channel left --limiter -6 100 --limiter-threshold -12 --limiter-release 50
if($LASTEXITCODE){throw 'Per-output limiter controls failed'}
$single=[IO.File]::ReadAllBytes($leftOnly)
for($i=32;$i -lt 48000;$i++){
    if([BitConverter]::ToInt16($single,46+$i*4) -ne [BitConverter]::ToInt16($inputBytes,46+($i-32)*4)){throw 'Unprotected output was changed beyond alignment delay'}
}
foreach($settings in @(@('--limiter','1','100'),@('--limiter','-31','100'),@('--limiter','-6','9'),@('--limiter-link','5'),@('--limiter-link','1.5'),@('--limiter-threshold','NaN'))){
    $bad=Join-Path $dir 'invalid.wav';& $Exe $source $bad @settings
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid limiter settings accepted: $settings"}
}
Write-Output "PASS: WAV limiter ceiling peak=$peak, link balance, 32-frame alignment, disabled bypass and invalid arguments."
