param([Parameter(Mandatory)][string]$ReportPath,[Parameter(Mandatory)][string]$AckPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/ProtectedStorage.psm1') -Force
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))
foreach($path in @($ReportPath,$AckPath)){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -cne $build -or (Test-Path -LiteralPath $path)){throw 'Fresh direct build report paths required.'}}
$session=$null;$hash=$null
try{
 $session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
 $hash=Write-DspiProtectedRecord -Directory $session.Directory -Name state.json -Value @{SchemaVersion=1;Phase='Prepared';Endpoint='test-only'}
 if((Read-DspiProtectedRecord -Directory $session.Directory -Name state.json).Phase -ne 'Prepared'){throw 'Protected record readback failed.'}
 $refused=$false;try{Write-DspiProtectedRecord -Directory $session.Directory -Name state.json -Value @{Phase='bad'} | Out-Null}catch{$refused=$true};if(!$refused){throw 'Unconditional overwrite was accepted.'}
 $hash=Write-DspiProtectedRecord -Directory $session.Directory -Name state.json -ExpectedSHA256 $hash -Value @{SchemaVersion=1;Phase='Verified';Endpoint='test-only'}
 $refused=$false;try{Write-DspiProtectedRecord -Directory $session.Directory -Name state.json -ExpectedSHA256 ('0'*64) -Value @{Phase='stale'} | Out-Null}catch{$refused=$true};if(!$refused){throw 'Stale hash was accepted.'}
 $lock=[DspiSecure.Native]::Lock((Join-Path $session.Directory 'state.json.lock'))
 try{$refused=$false;try{Write-DspiProtectedRecord -Directory $session.Directory -Name state.json -ExpectedSHA256 $hash -Value @{Phase='racing'} | Out-Null}catch{$refused=$true};if(!$refused){throw 'Concurrent writer lock was ignored.'}}finally{$lock.Dispose()}
 $deep=@{Leaf='must not disappear'};foreach($i in 1..45){$deep=@{Nested=$deep}}
 foreach($case in @(@('deep.json',$deep),@('large.json',@{Data=('x'*1048577)}))){$refused=$false;try{Write-DspiProtectedRecord -Directory $session.Directory -Name $case[0] -Value $case[1] | Out-Null}catch{$refused=$true};if(!$refused){throw 'Incomplete or oversized serialization was accepted.'}}
 if((Read-DspiProtectedRecord -Directory $session.Directory -Name state.json).Phase -ne 'Verified'){throw 'Rejected writer changed the original record.'}
 $ready=[ordered]@{Phase='Ready';Directory=$session.Directory;Record=(Join-Path $session.Directory state.json);SHA256=$hash;AtomicCreate=$true;ConditionalReplace=$true;UnconditionalOverwriteRejected=$true;StaleHashRejected=$true;ConcurrentWriterRejected=$true;DeepAndOversizeRejected=$true;RecordPreserved=$true}
 [IO.File]::WriteAllText($ReportPath,($ready | ConvertTo-Json))
 $deadline=[DateTime]::UtcNow.AddSeconds(60)
 while(!(Test-Path -LiteralPath $AckPath) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
 if(!(Test-Path -LiteralPath $AckPath)){throw 'Normal-user probe did not acknowledge within 60 seconds.'}
 $probe=Get-Content -LiteralPath $AckPath -Raw | ConvertFrom-Json
 if(!$probe.ReadDenied -or !$probe.WriteDenied -or !$probe.DeleteDenied){throw 'Normal-user access denial was not proven.'}
 Remove-DspiProtectedTestRecovery -Session $session -ExpectedRecords @{'state.json'=$hash}
 $session=$null
 $ready.Phase='Passed';$ready.CleanedUp=$true;$ready.Probe=$probe
 [IO.File]::WriteAllText($ReportPath,($ready | ConvertTo-Json -Depth 6))
}catch{
 $message=$_.Exception.Message
 if($session -and $hash){try{Remove-DspiProtectedTestRecovery -Session $session -ExpectedRecords @{'state.json'=$hash}}catch{$message+='; cleanup refused: '+$_.Exception.Message}}
 [IO.File]::WriteAllText($ReportPath,(@{Phase='Failed';Error=$message} | ConvertTo-Json))
 exit 1
}
