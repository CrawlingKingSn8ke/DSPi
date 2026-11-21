param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\routing-'+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $dir | Out-Null
$inputFile=Join-Path $dir 'impulses.wav';$outputFile=Join-Path $dir 'routed.wav'
$bytes=[byte[]]::new(44+1000*4)
[Text.Encoding]::ASCII.GetBytes('RIFF').CopyTo($bytes,0)
[BitConverter]::GetBytes([uint32]($bytes.Length-8)).CopyTo($bytes,4)
[Text.Encoding]::ASCII.GetBytes('WAVEfmt ').CopyTo($bytes,8)
[BitConverter]::GetBytes([uint32]16).CopyTo($bytes,16)
[BitConverter]::GetBytes([uint16]1).CopyTo($bytes,20)
[BitConverter]::GetBytes([uint16]2).CopyTo($bytes,22)
[BitConverter]::GetBytes([uint32]48000).CopyTo($bytes,24)
[BitConverter]::GetBytes([uint32]192000).CopyTo($bytes,28)
[BitConverter]::GetBytes([uint16]4).CopyTo($bytes,32)
[BitConverter]::GetBytes([uint16]16).CopyTo($bytes,34)
[Text.Encoding]::ASCII.GetBytes('data').CopyTo($bytes,36)
[BitConverter]::GetBytes([uint32]4000).CopyTo($bytes,40)
[BitConverter]::GetBytes([int16]8000).CopyTo($bytes,44)
[BitConverter]::GetBytes([int16]4000).CopyTo($bytes,50)
[IO.File]::WriteAllBytes($inputFile,$bytes)
& $Exe $inputFile $outputFile --outputs 3 --clear-routes --route 1 1 0 --route 2 2 0 --route 1 3 -6.0205999 --route 2 3 -6.0205999 --channel 1 --gain -6.0205999 --delay 1 --channel 2 --mute --channel 3 --delay 2
if($LASTEXITCODE) { throw 'Routing/gain/delay WAV processing failed' }
$result=[IO.File]::ReadAllBytes($outputFile)
if($result.Length -ne 6068 -or [BitConverter]::ToUInt16($result,20) -ne 65534 -or [BitConverter]::ToUInt16($result,22) -ne 3) { throw 'Wrong multichannel extensible WAV header/length' }
for($frame=0;$frame -lt 1000;$frame++){for($ch=0;$ch -lt 3;$ch++) {
    $expected=0
    if($frame -eq 48 -and $ch -eq 0){$expected=4000}
    if($frame -eq 96 -and $ch -eq 2){$expected=4000}
    if($frame -eq 97 -and $ch -eq 2){$expected=2000}
    $got=[BitConverter]::ToInt16($result,68+($frame*3+$ch)*2)
    if([Math]::Abs($got-$expected) -gt 1){throw "Wrong impulse: frame=$frame channel=$ch expected=$expected got=$got"}
}}
# Read back our extensible 3-channel output without losing channel independence.
$roundtrip=Join-Path $dir 'roundtrip.wav'
& $Exe $outputFile $roundtrip --gain 0
if($LASTEXITCODE){throw 'Extensible multichannel input failed'}
if((Get-FileHash $roundtrip).Hash -ne (Get-FileHash $outputFile).Hash){throw 'Unity multichannel round trip changed samples/header'}
# Exercise the last physical buffer slot and different interleaving stride.
$eightOut=Join-Path $dir 'eight.wav'
& $Exe $inputFile $eightOut --outputs 8 --clear-routes --route 1 8 0 --route 2 1 0
if($LASTEXITCODE){throw 'Eight-channel output failed'}
$eight=[IO.File]::ReadAllBytes($eightOut)
if($eight.Length -ne 16068 -or [BitConverter]::ToUInt16($eight,22) -ne 8){throw 'Wrong eight-channel WAV size/count'}
for($frame=0;$frame -lt 1000;$frame++){for($ch=0;$ch -lt 8;$ch++){
    $expected=0
    if($frame -eq 0 -and $ch -eq 7){$expected=8000}
    if($frame -eq 1 -and $ch -eq 0){$expected=4000}
    if([BitConverter]::ToInt16($eight,68+($frame*8+$ch)*2) -ne $expected){throw 'Wrong eight-channel routing/interleaving'}
}}
$monoOut=Join-Path $dir 'mono.wav'
& $Exe $inputFile $monoOut --outputs 1 --clear-routes --route 1 1 -6.0205999 --route 2 1 -6.0205999
if($LASTEXITCODE){throw 'Mono sum output failed'}
$mono=[IO.File]::ReadAllBytes($monoOut)
if($mono.Length -ne 2044 -or [BitConverter]::ToInt16($mono,44) -ne 4000 -or [BitConverter]::ToInt16($mono,46) -ne 2000){throw 'Wrong mono averaging/format'}
$inverted=Join-Path $dir 'invert.wav'
& $Exe $inputFile $inverted --clear-routes --route-invert 1 1 0 --route 2 2 0 --route-off 2 2
if($LASTEXITCODE){throw 'Polarity/route-off command failed'}
$inverse=[IO.File]::ReadAllBytes($inverted)
if([BitConverter]::ToInt16($inverse,44) -ne -8000 -or [BitConverter]::ToInt16($inverse,50) -ne 0){throw 'Polarity/route-off behavior incorrect'}
$bad=Join-Path $dir 'invalid.wav'
foreach($settings in @(
    @('--outputs','9'),@('--outputs','2.5'),@('--delay','171'),@('--gain','NaN'),
    @('--route','3','1','0'),@('--channel','0','--mute')
)) {
    & $Exe $inputFile $bad @settings
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid routing setting accepted: $settings"}
}
Write-Output 'PASS: stereo-to-three-channel mixing, output gain/mute, exact delay, extensible WAV roundtrip and invalid routing checks.'
