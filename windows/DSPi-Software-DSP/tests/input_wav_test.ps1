param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\input-'+[guid]::NewGuid());New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir 'tone.wav';$w=[IO.BinaryWriter]::new([IO.File]::Create($source))
try{
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$w.Write([uint32]192036);$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$w.Write([uint32]16)
    $w.Write([uint16]1);$w.Write([uint16]2);$w.Write([uint32]48000);$w.Write([uint32]192000);$w.Write([uint16]4);$w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data'));$w.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++){$v=[int16](2000*[Math]::Sin(2*[Math]::PI*1000*$i/48000));$w.Write($v);$w.Write($v)}
}finally{$w.Dispose()}
function Audio($name,[string[]]$settings){
    $path=Join-Path $dir "$name.wav";$log=& $Exe $source $path @settings
    if($LASTEXITCODE){throw "Input command failed: $name"}
    Write-Host ($log -join "`n");return ,([IO.File]::ReadAllBytes($path))
}
$original=[IO.File]::ReadAllBytes($source)
$a=Audio 'corrected' @('--outputs','3','--input-channel','left','--preamp','-6','--input-peak','1000','.707','12','--route','1','3','0')
$ei=0;$eo=0
for($i=12000;$i -lt 48000;$i++){
    $l=[BitConverter]::ToInt16($a,68+$i*6);$right=[BitConverter]::ToInt16($a,70+$i*6);$third=[BitConverter]::ToInt16($a,72+$i*6);$src=[BitConverter]::ToInt16($original,44+$i*4)
    if($right -ne $src -or $third -ne $l){throw 'Input isolation or pre-matrix routing failed'}
    $ei+=[double]$src*$src;$eo+=[double]$l*$l
}
$db=10*[Math]::Log10($eo/$ei);if([Math]::Abs($db-6) -gt .01){throw "Wrong input preamp/EQ response: $db"}
$d=Audio 'delay' @('--input-channel','right','--input-delay','3','--channel','left','--gain','-6','--channel','right','--delay','2')
for($i=0;$i -lt 48000;$i++){
    $v=[BitConverter]::ToInt16($d,46+$i*4)
    if($i -lt 240){if($v -ne 0){throw 'Delay startup not silent'}}
    elseif($v -ne [BitConverter]::ToInt16($original,46+($i-240)*4)){throw 'Input/output delays do not add exactly'}
}
$flat=Audio 'flat' @('--input-channel','all','--preamp','-6','--input-delay','3','--input-peak','1000','.707','12','--input-eq-clear','--preamp','0','--input-delay','0')
if((Get-FileHash (Join-Path $dir 'flat.wav')).Hash -ne (Get-FileHash $source).Hash){throw 'Restored input defaults changed audio or latency'}
$u=Audio 'combined' @('--outputs','5','--input-channel','left','--input-filter','low-shelf','120','.707','-3','--preamp','-3','--input-channel','right','--input-delay','2','--leveller','50','fast','12','--upmix','adaptive','--route','3','3','0','--route','4','4','0','--route','5','5','0','--limiter','-6','100')
if($u.Length -ne 480068){throw 'Combined input processing changed frame count'}
foreach($settings in @(
    @('--input-channel','3'),@('--input-channel','0'),@('--preamp','12.1'),@('--preamp','-60.1'),@('--preamp','NaN'),
    @('--input-delay','171'),@('--input-delay','-1'),@('--input-delay','Infinity'),@('--input-peak','24000','1','0'),
    @('--input-filter','lr4-hp','100','1','0'),@('--input-peak','1000','0','0'),@('--input-peak','1000','1','31'))){
    $bad=Join-Path $dir 'invalid.wav';$null=& $Exe $source $bad @settings 2>&1
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid input recipe accepted: $settings"}
}
$tooMany=@();for($i=0;$i -lt 11;$i++){$tooMany+=@('--input-peak','1000','.707','1')}
$bad=Join-Path $dir 'invalid.wav';$null=& $Exe $source $bad @tooMany 2>&1
if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw 'Accepted more than ten input EQ bands'}
Write-Output "PASS: input WAV response $db dB, independent selections, delay addition, reset, combined effects and invalid settings."
