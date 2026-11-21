param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\tube-'+[guid]::NewGuid().ToString());New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir 'tone.wav';$stream=[IO.File]::Create($source);$w=[IO.BinaryWriter]::new($stream)
try{
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$w.Write([uint32]192036);$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$w.Write([uint32]16)
    $w.Write([uint16]1);$w.Write([uint16]2);$w.Write([uint32]48000);$w.Write([uint32]192000);$w.Write([uint16]4);$w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data'));$w.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++){$v=[int16](16000*[Math]::Sin(2*[Math]::PI*1000*$i/48000));$w.Write($v);$w.Write($v)}
}finally{$w.Dispose()}
$wet=Join-Path $dir 'wet.wav';$dry=Join-Path $dir 'dry.wav';$off=Join-Path $dir 'off.wav';$zero=Join-Path $dir 'zero.wav'
& $Exe $source $wet --channel left --tube 12AX7 6 100 --tube-sag 40 --tube-rectifier 5y3 --tube-output-stage 2 95 --tube-trim -3
if($LASTEXITCODE){throw 'Tube and advanced options failed'}
& $Exe $source $dry --tube 12ax7 6 0
if($LASTEXITCODE){throw 'Zero-mix tube command failed'}
& $Exe $source $off --tube 12ax7 6 100 --tube-off
if($LASTEXITCODE){throw 'Tube-off command failed'}
$inputBytes=[IO.File]::ReadAllBytes($source);$wetBytes=[IO.File]::ReadAllBytes($wet)
if((Get-FileHash $source).Hash -ne (Get-FileHash $dry).Hash -or (Get-FileHash $source).Hash -ne (Get-FileHash $off).Hash){throw 'Dry mix or bypass changed WAV data'}
$changed=$false
for($i=44;$i -lt $inputBytes.Length;$i+=4){
    if($wetBytes[$i+2] -ne $inputBytes[$i+2] -or $wetBytes[$i+3] -ne $inputBytes[$i+3]){throw 'Tube changed an unselected output'}
    if($wetBytes[$i] -ne $inputBytes[$i] -or $wetBytes[$i+1] -ne $inputBytes[$i+1]){$changed=$true}
}
if(!$changed){throw 'Enabled tube did not change selected output'}
# Symmetric cubic reference, with sag/transformer disabled, checked through WAV I/O.
& $Exe $source $zero --tube custom 0 100 --tube-bias 0 --tube-asym 0 --tube-hardness 0 --tube-sag 0 --tube-rectifier solid-state --tube-no-output-stage
if($LASTEXITCODE){throw 'Custom tube parameter command failed'}
$cubic=[IO.File]::ReadAllBytes($zero);$re1=0.0;$im1=0.0;$re3=0.0;$im3=0.0
for($i=24000;$i -lt 48000;$i++){
    $v=[BitConverter]::ToInt16($cubic,44+$i*4);$p=2*[Math]::PI*1000*$i/48000
    $re1+=$v*[Math]::Cos($p);$im1+=$v*[Math]::Sin($p);$re3+=$v*[Math]::Cos(3*$p);$im3+=$v*[Math]::Sin(3*$p)
}
$h3=10*[Math]::Log10(($re3*$re3+$im3*$im3)/($re1*$re1+$im1*$im1))
# A=16000/32768: H3/H1=(A^2/12)/(1-A^2/4), approximately -33.5 dBc.
$amp=16000/32768.0;$expected=20*[Math]::Log10(($amp*$amp/12)/(1-$amp*$amp/4))
if([Math]::Abs($h3-$expected) -gt 0.08){throw "Wrong WAV cubic harmonic: $h3 expected $expected"}
foreach($settings in @(@('--tube','unknown','0','100'),@('--tube','12ax7','25','100'),@('--tube','12ax7','0','101'),@('--tube-bias','NaN'),@('--tube-output-stage','0','95'),@('--tube-rectifier','unknown'))){
    $bad=Join-Path $dir 'invalid.wav';& $Exe $source $bad @settings
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid tube settings accepted: $settings"}
}
Write-Output "PASS: tube WAV controls, selection, bypass, dry mix, custom cubic H3=$h3 dBc and invalid parameters."
