param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
if(!(Test-Path -LiteralPath $Exe)) { throw 'WAV processor is not implemented/built yet' }
$testDir=Join-Path $PSScriptRoot '..\build\wav-check'
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
$inputFile=Join-Path $testDir 'input.wav'
$outputFile=Join-Path $testDir ([guid]::NewGuid().ToString()+'.wav')
$stream=[IO.File]::Create($inputFile)
$writer=[IO.BinaryWriter]::new($stream)
try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([uint32](36+48000*4))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([uint32]16)
    $writer.Write([uint16]1); $writer.Write([uint16]2); $writer.Write([uint32]48000)
    $writer.Write([uint32]192000); $writer.Write([uint16]4); $writer.Write([uint16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([uint32](48000*4))
    for($i=0;$i -lt 48000;$i++) {
        $writer.Write([int16](6000*[Math]::Sin(2*[Math]::PI*1000*$i/48000)))
        $writer.Write([int16]0)
    }
} finally { $writer.Dispose() }
& $Exe $inputFile $outputFile 1000 0.707 -6
if($LASTEXITCODE) { throw 'WAV processing failed' }
$original=[IO.File]::ReadAllBytes($inputFile); $processed=[IO.File]::ReadAllBytes($outputFile)
if($original.Length -ne $processed.Length) { throw 'Output duration/channel count changed' }
$inPower=0.0; $outPower=0.0
for($i=44+24000*4;$i -lt $processed.Length;$i+=4) {
    $a=[BitConverter]::ToInt16($original,$i); $b=[BitConverter]::ToInt16($processed,$i)
    $inPower+=$a*$a; $outPower+=$b*$b
    if([BitConverter]::ToInt16($processed,$i+2) -ne 0) { throw 'Cross-channel leakage' }
}
$gain=10*[Math]::Log10($outPower/$inPower)
if([Math]::Abs($gain+6) -gt 0.01) { throw "Wrong WAV gain: $gain dB" }
$hash=(Get-FileHash $outputFile).Hash
& $Exe $inputFile $outputFile 1000 0.707 -6
if($LASTEXITCODE -eq 0 -or (Get-FileHash $outputFile).Hash -ne $hash) { throw 'Existing output was overwritten' }
$invalidOut=Join-Path $testDir ([guid]::NewGuid().ToString()+'.wav')
& $Exe $inputFile $invalidOut 24000 0.707 6
if($LASTEXITCODE -eq 0 -or (Test-Path $invalidOut)) { throw 'Invalid recipe accepted or output created' }
$badInput=Join-Path $testDir 'truncated.wav'
[IO.File]::WriteAllBytes($badInput,[byte[]](82,73,70,70,0,0,0,0,87,65,86,69))
& $Exe $badInput $invalidOut 1000 0.707 6
if($LASTEXITCODE -eq 0 -or (Test-Path $invalidOut)) { throw 'Truncated WAV accepted or output created' }
Write-Output "PASS: WAV response $gain dB; independent channels; overwrite protection; invalid recipe and malformed WAV rejection."
# Both channels contain the known tone for independent crossover/PEQ checks.
$dual=[byte[]]$original.Clone()
for($i=44;$i -lt $dual.Length;$i+=4) { $dual[$i+2]=$dual[$i]; $dual[$i+3]=$dual[$i+1] }
$dualInput=Join-Path $testDir 'dual.wav'; [IO.File]::WriteAllBytes($dualInput,$dual)
$chainOut=Join-Path $testDir ([guid]::NewGuid().ToString()+'.wav')
& $Exe $dualInput $chainOut --channel left --crossover lr4-lp 1000 --peak 1000 0.707 -3 --peak 1000 0.707 -3 --channel right --crossover lr4-hp 1000
if($LASTEXITCODE) { throw 'Multiband crossover command failed' }
$chain=[IO.File]::ReadAllBytes($chainOut)
for($channel=0;$channel -lt 2;$channel++) {
    $power=0.0
    for($i=44+24000*4+2*$channel;$i -lt $chain.Length;$i+=4) {
        $v=[BitConverter]::ToInt16($chain,$i); $power+=$v*$v
    }
    $db=10*[Math]::Log10($power/$inPower)
    $want=if($channel -eq 0){-12.0206}else{-6.0206}
    if([Math]::Abs($db-$want) -gt 0.02) { throw "Wrong channel $channel chain gain: $db, expected $want" }
    Write-Output "PASS: channel $channel crossover/EQ response $db dB."
}
$tooMany=@(); for($i=0;$i -lt 11;$i++) { $tooMany+=@('--peak','1000','1','-1') }
& $Exe $dualInput $invalidOut @tooMany
if($LASTEXITCODE -eq 0 -or (Test-Path $invalidOut)) { throw 'PEQ capacity overflow accepted' }
$tooMany=@(); for($i=0;$i -lt 5;$i++) { $tooMany+=@('--crossover','lr4-lp','1000') }
& $Exe $dualInput $invalidOut @tooMany
if($LASTEXITCODE -eq 0 -or (Test-Path $invalidOut)) { throw 'Crossover capacity overflow accepted' }
& $Exe $dualInput $invalidOut --filter invalid 1000 1 0
if($LASTEXITCODE -eq 0 -or (Test-Path $invalidOut)) { throw 'Unknown filter accepted' }
