# Start normally; only the confined storage helper elevates via UAC.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/ProtectedStorage.psm1') -Force
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Start this test from normal PowerShell so denial checks use an unelevated token.'}
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))
$tag=[guid]::NewGuid().ToString('N')
$report=Join-Path $build ('storage-admin-'+$tag+'.json');$ack=Join-Path $build ('storage-probe-'+$tag+'.json')
$helper=Join-Path $PSScriptRoot 'apo_storage_admin.ps1'
$arguments='-NoProfile -File "'+$helper+'" -ReportPath "'+$report+'" -AckPath "'+$ack+'"'
$process=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
function Wait-Report([string[]]$phases){
 $deadline=[DateTime]::UtcNow.AddSeconds(55)
 while([DateTime]::UtcNow -lt $deadline){
  if(Test-Path -LiteralPath $report){
   try{$r=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json}catch{Start-Sleep -Milliseconds 100;continue}
   if($r.Phase -eq 'Failed'){throw $r.Error}
   if($r.Phase -in $phases){return $r}
  }
  Start-Sleep -Milliseconds 100
 }
 throw 'Protected storage helper did not report the expected phase.'
}
$ready=Wait-Report @('Ready')
$probe=[ordered]@{ReadDenied=$false;WriteDenied=$false;DeleteDenied=$false}
try{[IO.File]::ReadAllText($ready.Record) | Out-Null}catch [UnauthorizedAccessException]{$probe.ReadDenied=$true}
try{$f=[IO.File]::Open($ready.Record,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);$f.Dispose()}catch [UnauthorizedAccessException]{$probe.WriteDenied=$true}
try{[IO.File]::Delete($ready.Record)}catch [UnauthorizedAccessException]{$probe.DeleteDenied=$true}
$probe | ConvertTo-Json | Set-Content -LiteralPath $ack
$result=Wait-Report @('Passed')
foreach($name in @('CleanedUp','AtomicCreate','ConditionalReplace','UnconditionalOverwriteRejected','StaleHashRejected','ConcurrentWriterRejected','DeepAndOversizeRejected','RecordPreserved')){if(!$result.$name){throw "Protected storage check failed: $name"}}
if(!$probe.ReadDenied -or !$probe.WriteDenied -or !$probe.DeleteDenied){throw 'Normal-user access was not denied.'}
Write-Output 'PASS elevated protected recovery storage, lock/stale-write limits, normal-user read/write/delete denial and cleanup'
Write-Output $report
