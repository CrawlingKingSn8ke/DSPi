$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/Resources.psm1') -Force
$repo=Split-Path $PSScriptRoot -Parent
$lab=New-DspiResourceLab -Root (Join-Path $repo ('build/full-recovery-'+[guid]::NewGuid().ToString('N')))
$script:checks=0
function Check($v,$m){$script:checks++;if(!$v){throw $m}}
function Reject([scriptblock]$f,$m){$failed=$false;try{& $f | Out-Null}catch{$failed=$true};Check $failed $m}
$ops=@(
 [pscustomobject]@{Id='binary-dir';Kind='Directory';Path='binary';After=[pscustomobject]@{Exists=$true}}
 [pscustomobject]@{Id='binary';Kind='File';Path='binary/dspi-apo.dll';After=[pscustomobject]@{Exists=$true;Bytes=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('lab binary'))}}
 [pscustomobject]@{Id='profile-dir';Kind='Directory';Path='profiles';After=[pscustomobject]@{Exists=$true}}
 [pscustomobject]@{Id='telemetry';Kind='Directory';Path='profiles/telemetry';After=[pscustomobject]@{Exists=$true}}
 [pscustomobject]@{Id='com';Kind='RegistryKey';Path='Classes/CLSID/DSPi';After=[pscustomobject]@{Exists=$true}}
 [pscustomobject]@{Id='com-dll';Kind='RegistryValue';Path='Classes/CLSID/DSPi';Name='';After=[pscustomobject]@{Exists=$true;Kind='String';Value='lab.dll'}}
 [pscustomobject]@{Id='modes';Kind='RegistryValue';Path='Classes/CLSID/DSPi';Name='Modes';After=[pscustomobject]@{Exists=$true;Kind='MultiString';Value=@('default','media')}}
 [pscustomobject]@{Id='acl';Kind='FileAcl';Path='profiles/telemetry';After=[pscustomobject]@{Exists=$true;Sddl=$lab.TestSddl}}
 [pscustomobject]@{Id='fx';Kind='RegistryValue';Path='Classes/CLSID/DSPi';Name='Endpoint';After=[pscustomobject]@{Exists=$true;Kind='String';Value='selected-endpoint'}}
)
# Fail after each real store write, then recover from the persisted journal.
for($boundary=1;$boundary -le $ops.Count;$boundary++){
 $journal=Join-Path $lab.Root ('journal-'+$boundary+'.json')
 Reject {Invoke-DspiResourceTransaction -Lab $lab -Operations $ops -JournalPath $journal -FailAfter $boundary} "Injected mutation $boundary must interrupt"
 Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal | Out-Null
 Check (Test-DspiResourceLabEmpty $lab) "All resources restored at boundary $boundary"
 Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal | Out-Null
}
$journal=Join-Path $lab.Root 'success.json'
Invoke-DspiResourceTransaction -Lab $lab -Operations $ops -JournalPath $journal | Out-Null
Check ((Read-DspiLabResource $lab $ops[1]).Bytes -eq $ops[1].After.Bytes) 'Real file bytes installed'
Check ((Read-DspiLabResource $lab $ops[6]).Value.Count -eq 2) 'Real multi-string registry type preserved'
# A subsequent attachment edit must stop recovery before deleting its binary.
$edited=$ops[8] | ConvertTo-Json -Depth 10 | ConvertFrom-Json;$edited.After.Value='external edit'
Write-DspiLabResource $lab $edited $edited.After
Reject {Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal} 'Conflicting attachment prevents recovery'
Check (Test-Path (Join-Path $lab.Root 'binary/dspi-apo.dll')) 'Conflict preserves required binary'
Write-DspiLabResource $lab $ops[8] $ops[8].After
$external=Join-Path $lab.Root 'binary/external.txt'
[IO.File]::WriteAllText($external,'external data')
Reject {Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal} 'External directory child stops rollback in preflight'
Check (Test-Path (Join-Path $lab.Root 'binary/dspi-apo.dll')) 'Directory conflict does not remove binary'
[IO.File]::Delete($external)
$extra=[pscustomobject]@{Kind='RegistryValue';Path='Classes/CLSID/DSPi';Name='External'}
Write-DspiLabResource $lab $extra ([pscustomobject]@{Exists=$true;Kind='DWord';Value=123})
Reject {Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal} 'External registry value stops rollback in preflight'
Check (Test-Path (Join-Path $lab.Root 'binary/dspi-apo.dll')) 'Registry child conflict does not remove binary'
Write-DspiLabResource $lab $extra ([pscustomobject]@{Exists=$false})
Undo-DspiResourceTransaction -Lab $lab -JournalPath $journal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'Successful transaction fully restored'
for($boundary=1;$boundary -le $ops.Count;$boundary++){
 $restoreJournal=Join-Path $lab.Root ('restore-'+$boundary+'.json')
 Invoke-DspiResourceTransaction -Lab $lab -Operations $ops -JournalPath $restoreJournal | Out-Null
 Reject {Undo-DspiResourceTransaction -Lab $lab -JournalPath $restoreJournal -FailAfter $boundary} "Injected restore $boundary must interrupt"
 Undo-DspiResourceTransaction -Lab $lab -JournalPath $restoreJournal | Out-Null
 Check (Test-DspiResourceLabEmpty $lab) "Full recovery resumes after restore boundary $boundary"
}
$escaped=$ops[0] | ConvertTo-Json | ConvertFrom-Json;$escaped.Path='../outside'
Reject {Invoke-DspiResourceTransaction -Lab $lab -Operations @($escaped) -JournalPath (Join-Path $lab.Root 'escape.json')} 'Path escape rejected'
$deep=[pscustomobject]@{Id='deep';Kind='RegistryKey';Path='missing/parent/leaf';After=[pscustomobject]@{Exists=$true}}
$deepJournal=Join-Path $lab.Root 'deep.json'
Reject {Invoke-DspiResourceTransaction -Lab $lab -Operations @($deep) -JournalPath $deepJournal} 'Unjournaled registry ancestors cannot be created'
Undo-DspiResourceTransaction -Lab $lab -JournalPath $deepJournal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'No implicit ancestors remain'
$large=$ops[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json;$large.After.Bytes=[Convert]::ToBase64String([byte[]]::new(1600000))
Reject {Invoke-DspiResourceTransaction -Lab $lab -Operations @($ops[0],$large) -JournalPath (Join-Path $lab.Root 'oversized.json')} 'Oversized recovery payload rejected before mutation'
Check (Test-DspiResourceLabEmpty $lab) 'Oversized operation leaves no binary directory'
$partial=$ops[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json;$partial | Add-Member -NotePropertyName TestPartialWrite -NotePropertyValue $true
$partialJournal=Join-Path $lab.Root 'partial.json'
Reject {Invoke-DspiResourceTransaction -Lab $lab -Operations @($ops[0],$partial) -JournalPath $partialJournal} 'Failure during file write is reported'
Check (!(Test-Path -LiteralPath (Join-Path $lab.Root 'binary/dspi-apo.dll'))) 'Partial bytes are never published as the DLL'
Undo-DspiResourceTransaction -Lab $lab -JournalPath $partialJournal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'Staged partial file removed and resources recovered'
$tamperJournal=Join-Path $lab.Root 'tamper.json'
Invoke-DspiResourceTransaction -Lab $lab -Operations $ops -JournalPath $tamperJournal | Out-Null
$saved=[IO.File]::ReadAllText($tamperJournal)
$envelope=$saved | ConvertFrom-Json;$payload=$envelope.Payload | ConvertFrom-Json
$payload.Entries[1].Before=[pscustomobject]@{Exists=$true;Bytes=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('forged before state'))}
$envelope.Payload=$payload | ConvertTo-Json -Depth 35 -Compress
$envelope | ConvertTo-Json -Compress | Set-Content -LiteralPath $tamperJournal
Reject {Undo-DspiResourceTransaction -Lab $lab -JournalPath $tamperJournal} 'Modified journal before-state fails independent authentication'
Check ((Read-DspiLabResource $lab $ops[1]).Bytes -eq $ops[1].After.Bytes) 'Tampered journal never rewrites DLL'
[IO.File]::WriteAllText($tamperJournal,$saved)
Undo-DspiResourceTransaction -Lab $lab -JournalPath $tamperJournal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'Authenticated original journal restores resources'
$rootJson=Join-Path $lab.Root 'external.json';[IO.File]::WriteAllText($rootJson,'external')
Check (!(Test-DspiResourceLabEmpty $lab)) 'Unknown root JSON is not mistaken for journal metadata'
[IO.File]::Delete($rootJson)
$crashFile=$ops[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json;$crashFile | Add-Member -NotePropertyName TestTerminateWrite -NotePropertyValue $true
$crashOps=@($ops[0],$crashFile)
$crashJournal=Join-Path $lab.Root 'hard-crash.json';$lab.Journals+= $crashJournal
# Recovery authority (including its random MAC key) is retained independently
# of the untrusted journal. Production would require protected storage.
$descriptor=Join-Path $repo ('build/crash-descriptor-'+[guid]::NewGuid().ToString('N')+'.json')
[pscustomobject]@{Lab=$lab;Operations=$crashOps;Journal=$crashJournal} | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $descriptor
$hostExe=(Get-Process -Id $PID).Path;$helper=Join-Path $PSScriptRoot 'apo_resources_process.ps1'
& $hostExe -NoProfile -File $helper -Descriptor $descriptor -Mode Apply
Check ($LASTEXITCODE -eq 24) 'Separate installer terminates during binary write'
Check (!(Test-Path -LiteralPath (Join-Path $lab.Root 'binary/dspi-apo.dll'))) 'Hard crash never publishes partial DLL'
Check (@(Get-ChildItem -LiteralPath (Join-Path $lab.Root 'binary') -Filter '*.tmp').Count -eq 1) 'Hard crash leaves journaled partial staging file'
& $hostExe -NoProfile -File $helper -Descriptor $descriptor -Mode Undo
Check ($LASTEXITCODE -eq 0) 'Fresh process authenticates journal and recovers hard crash'
Check (Test-DspiResourceLabEmpty $lab) 'Hard-crash recovery removes owned partial file and directory'
$native=$ops[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$native.After.Bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo 'build/dspi-apo.dll')))
$nativeJournal=Join-Path $lab.Root 'native-dll.json'
Invoke-DspiResourceTransaction -Lab $lab -Operations @($ops[0],$native) -JournalPath $nativeJournal | Out-Null
Check ((Get-FileHash -LiteralPath (Join-Path $lab.Root 'binary/dspi-apo.dll')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $repo 'build/dspi-apo.dll')).Hash) 'Actual native DLL copied byte for byte into lab'
Undo-DspiResourceTransaction -Lab $lab -JournalPath $nativeJournal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'Actual native DLL and directory fully removed by rollback'
$unsigned=[pscustomobject]@{Id='max-instances';Kind='RegistryValue';Path='Classes/CLSID/DSPi';Name='MaxInstances';After=[pscustomobject]@{Exists=$true;Kind='DWord';Value=4294967295}}
$unsignedJournal=Join-Path $lab.Root 'unsigned-dword.json'
Invoke-DspiResourceTransaction -Lab $lab -Operations @($ops[4],$unsigned) -JournalPath $unsignedJournal | Out-Null
Check ((Read-DspiLabResource $lab $unsigned).Value -eq 4294967295) 'Actual APO unsigned DWORD maximum preserved'
Undo-DspiResourceTransaction -Lab $lab -JournalPath $unsignedJournal | Out-Null
Check (Test-DspiResourceLabEmpty $lab) 'Unsigned APO registration removed cleanly'
Write-Output "PASS full Windows lab resource recovery ($script:checks assertions)"
