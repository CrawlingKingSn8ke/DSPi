# Real elevated fixture, never a live audio attachment. Start unelevated.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/MachineBackend.psm1') -Force
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Start unelevated so the executable-access probe uses a normal token.'}
$repo=Split-Path $PSScriptRoot -Parent;$build=Join-Path $repo build;$hostExe=(Get-Process -Id $PID).Path
function Launch([string]$extra=''){
 $report=Join-Path $build ('backend-admin-'+[guid]::NewGuid().ToString('N')+'.json')
 $helper=Join-Path $PSScriptRoot 'apo_backend_admin.ps1'
 $process=Start-Process -FilePath $hostExe -ArgumentList ('-NoProfile -File "'+$helper+'" -ReportPath "'+$report+'" '+$extra) -Verb RunAs -WindowStyle Hidden -PassThru
 [pscustomobject]@{Process=$process;Report=$report}
}
function Read-Report($run){if(Test-Path -LiteralPath $run.Report){try{return (Get-Content -LiteralPath $run.Report -Raw | ConvertFrom-Json)}catch{return $null}};return $null}
function Wait-Result($run,[string[]]$phases){
 $until=[DateTime]::UtcNow.AddSeconds(180)
 while([DateTime]::UtcNow -lt $until){$r=Read-Report $run;if($r){if($r.Phase -eq 'Failed'){throw ($r.Error+'; '+$r.Stack)};if($r.Phase -in $phases){return $r}};Start-Sleep -Milliseconds 100}
 throw 'Machine fixture helper timed out; use its report to locate protected recovery.'
}
$ack=Join-Path $build ('backend-probe-'+[guid]::NewGuid().ToString('N')+'.json')
$run=Launch ('-Sweep -ProbeAckPath "'+$ack+'"')
$probe=Wait-Result $run @('ExecutableProbe')
$base=[IO.Path]::GetFullPath($probe.Fixture)
if((Split-Path $base -Parent) -cne $build -or (Split-Path $base -Leaf) -cnotmatch '^machine-fixture-[a-f0-9]{32}$' -or !$probe.Binary.StartsWith($base+'\Program\APO\',[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $probe.Binary).Hash -cne $probe.SHA256){throw 'Unexpected fixture binary.'}
[DspiMachine.Native]::ExecutableMapping($probe.Binary)
@{ExecutableMapped=$true} | ConvertTo-Json | Set-Content -LiteralPath $ack
$result=Wait-Result $run @('Passed')
Write-Output ('PASS elevated machine fixture: '+$result.Checks+' checks; normal-user executable mapping; 14 apply boundaries and staged recovery')
Write-Output $run.Report
$crash=Launch '-CrashStage 14'
if(!$crash.Process.WaitForExit(55000)){throw 'Crash fixture did not terminate.'}
if($crash.Process.ExitCode -ne 29){$r=Read-Report $crash;if($r -and $r.Phase -eq 'Failed'){throw $r.Error};throw 'Unexpected crash fixture exit code.'}
$r=Read-Report $crash;$session=Split-Path $r.Session -Leaf
if($session -cnotmatch '^install-[a-f0-9]{32}$'){throw 'Crash session identity missing.'}
$resume=Launch ('-ResumeSession '+$session.Substring(8))
$recovered=Wait-Result $resume @('Passed')
if(!$recovered.RecoveredInterruptedFixture -or !$recovered.CleanedUp){throw 'Hard-crash fixture did not recover.'}
Write-Output 'PASS real process termination during staged FX publication and protected standalone recovery in a fresh process'
Write-Output $resume.Report
