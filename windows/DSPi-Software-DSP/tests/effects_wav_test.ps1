param([string]$Exe=(Join-Path $PSScriptRoot '..\build\dspi-wav.exe'))
$ErrorActionPreference='Stop'
$dir=Join-Path $PSScriptRoot ('..\build\effects-'+[guid]::NewGuid());New-Item -ItemType Directory -Path $dir | Out-Null
$source=Join-Path $dir 'input.wav';$w=[IO.BinaryWriter]::new([IO.File]::Create($source))
try{
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$w.Write([uint32]192036);$w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$w.Write([uint32]16)
    $w.Write([uint16]1);$w.Write([uint16]2);$w.Write([uint32]48000);$w.Write([uint32]192000);$w.Write([uint16]4);$w.Write([uint16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data'));$w.Write([uint32]192000)
    for($i=0;$i -lt 48000;$i++){
        $v=[int16](2000*[Math]::Sin(2*[Math]::PI*60*$i/48000)+1000*[Math]::Sin(2*[Math]::PI*1000*$i/48000))
        $w.Write($v);if($i -lt 24000){$w.Write($v)}else{$w.Write([int16](-$v))}
    }
}finally{$w.Dispose()}
# Capture native stdout separately from the returned byte buffer.
function Audio($name,[string[]]$settings){
    $path=Join-Path $dir "$name.wav";$log=& $Exe $source $path @settings
    if($LASTEXITCODE){throw "Effect command failed: $name"}
    Write-Host ($log -join "`n");return ,([IO.File]::ReadAllBytes($path))
}
$original=[IO.File]::ReadAllBytes($source)
$p=Audio 'psy' @('--channel','left','--psybass','80','0','6','0','0')
$changed=$false
for($i=0;$i -lt 48000;$i++){
    if([BitConverter]::ToInt16($p,46+$i*4) -ne [BitConverter]::ToInt16($original,46+$i*4)){throw 'Psybass changed unselected output'}
    if([BitConverter]::ToInt16($p,44+$i*4) -ne [BitConverter]::ToInt16($original,44+$i*4)){$changed=$true}
}
if(!$changed){throw 'Psybass did not generate content'}
$s=Audio 'sub' @('--subharm','0','0','-30','0','--subharm-solo','on')
$subEnergy=0;for($i=44;$i -lt $s.Length;$i+=2){$subEnergy+=[Math]::Abs([BitConverter]::ToInt16($s,$i))}
if($subEnergy -lt 10000){throw 'Subharm output empty'}
$l=Audio 'level' @('--leveller','50','fast','12','--leveller-apply','1')
for($i=0;$i -lt 48000;$i++){
    $v=[BitConverter]::ToInt16($l,46+$i*4)
    if($i -lt 288){if($v -ne 0){throw 'Missing leveller delay'}}
    elseif($v -ne [BitConverter]::ToInt16($original,46+($i-288)*4)){throw 'Non-applied input lost alignment'}
}
$routing=@('--outputs','5','--upmix','passive','--clear-routes','--route','1','1','0','--route','2','2','0','--route','3','3','0','--route','4','4','0','--route','5','5','0')
$u=Audio 'upmix' $routing
if($u.Length -ne 480068 -or [BitConverter]::ToUInt16($u,22) -ne 5){throw 'Wrong five-channel WAV format/frame count'}
$center=0;$surround=0
for($i=2400;$i -lt 20000;$i++){$center+=[Math]::Abs([BitConverter]::ToInt16($u,68+$i*10+4));$surround+=[Math]::Abs([BitConverter]::ToInt16($u,68+$i*10+6))}
if($center -lt 10000 -or $surround -gt 100){throw 'Mono extraction did not go to centre'}
$surround=0;for($i=30000;$i -lt 48000;$i++){$surround+=[Math]::Abs([BitConverter]::ToInt16($u,68+$i*10+6))}
if($surround -lt 10000){throw 'Difference signal did not reach surround'}
$all=Audio 'combined' ($routing+@('--leveller','50','fast','12','--psybass','80','-6','6','50','0','--subharm','-12','-12','-30','0','--limiter','-6','100','--limiter-link','1'))
if($all.Length -ne $u.Length){throw 'Combined effects changed length'}
for($i=68;$i -lt $all.Length;$i+=2){if([Math]::Abs([BitConverter]::ToInt16($all,$i)) -gt 16424){throw 'Combined output exceeded limiter ceiling'}}
$off=Audio 'off' @('--psybass','80','0','6','50','0','--psybass-off','--subharm','0','0','-30','0','--subharm-off','--leveller','50','fast','12','--leveller-off','--upmix','adaptive','--upmix-off')
if((Get-FileHash (Join-Path $dir 'off.wav')).Hash -ne (Get-FileHash $source).Hash){throw 'Disabled block changed audio or delay'}
foreach($settings in @(
    @('--psybass','29','0','6','50','0'),@('--psybass','80','13','6','50','0'),@('--psybass','80','0','NaN','50','0'),
    @('--subharm','13','0','-30','0'),@('--subharm-select','invalid','100','150'),@('--subharm-ceiling','-41'),@('--subharm-link','maybe'),
    @('--leveller','101','fast','12'),@('--leveller','50','invalid','12'),@('--leveller','50','slow','36'),@('--leveller-apply','4'),@('--leveller-detectors','1.5'),
    @('--upmix','invalid'),@('--upmix-width','101'),@('--upmix-delay','21'),@('--upmix-presence','NaN'),@('--route','3','1','0'))){
    $bad=Join-Path $dir 'invalid.wav';$null=& $Exe $source $bad @settings 2>&1
    if($LASTEXITCODE -eq 0 -or (Test-Path $bad)){throw "Invalid effect settings accepted: $settings"}
}
Write-Output 'PASS: four-effect WAV controls, selection, leveller alignment, five-channel routing, combined ceiling, bypass and invalid settings.'
