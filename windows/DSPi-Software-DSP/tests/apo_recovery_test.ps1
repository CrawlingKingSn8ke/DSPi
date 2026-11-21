$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/Recovery.psm1') -Force
$root=Split-Path $PSScriptRoot -Parent
$target=Get-Content (Join-Path $root 'build/dspi-usb-target-20261117.json') -Raw | ConvertFrom-Json
$mapping=Get-Content (Join-Path $root 'build/dspi-endpoint-mapping-20261118.json') -Raw | ConvertFrom-Json
$plan=New-DspiRecoveryPlan -Target $target -Mapping $mapping
$script:assertions=0
function Check($condition,$message){$script:assertions++;if(!$condition){throw $message}}
function Reject([scriptblock]$action,$message){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};Check $failed $message}
Check ($plan.Scope.EndpointId -eq $target.EndpointId) 'Exact endpoint retained'
Check ($plan.Changes.Count -eq 3) 'Only three DSPi endpoint additions'
Check (!$plan.LiveInstallable) 'Recovery plan does not authorize Windows writes'
$wrong=$mapping | ConvertTo-Json -Depth 40 | ConvertFrom-Json
$wrong.FunctionInstanceId+='-other'
Reject {New-DspiRecoveryPlan -Target $target -Mapping $wrong} 'Other USB function rejected'
$occupied=$target | ConvertTo-Json -Depth 40 | ConvertFrom-Json
$occupied.BeforeState.FxProperties+= $plan.Changes[0].After
Reject {New-DspiRecoveryPlan -Target $occupied -Mapping $mapping} 'Occupied slot rejected'
$journal=Join-Path $root ('build/recovery-test-'+[guid]::NewGuid().ToString('N')+'.json')
$script:store=@{}
foreach($value in $target.BeforeState.FxProperties){$script:store[$value.Name]=$value}
$script:writes=0
$read={param($name) if($script:store.ContainsKey($name)){$script:store[$name]}else{$null}}
$write={param($name,$value) $script:store[$name]=$value;$script:writes++;if($script:writes -eq 2){throw 'Injected interruption after second write'}}
$remove={param($name) $script:store.Remove($name)}
Reject {Start-DspiRecoveryTransaction -Plan $plan -JournalPath $journal -Read $read -Write $write} 'Interrupted installation reported'
Check (Test-Path -LiteralPath $journal) 'Journal survived interruption'
Check ($script:store.ContainsKey($plan.Changes[1].Name)) 'Interrupted write actually occurred'
$disk=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
Check ($disk.Entries[1].State -eq 'Intent') 'Intent persisted before interrupted write'
$savedCount=$script:store.Count
$script:store[$plan.Changes[0].Name]=[pscustomobject]@{Name=$plan.Changes[0].Name;Kind='String';Value='changed by another application'}
Reject {Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $journal -Read $read -Write $write -Remove $remove} 'Recovery stops on subsequent edit'
Check ($script:store.Count -eq $savedCount) 'Conflict preflight performs no partial rollback'
$script:store[$plan.Changes[0].Name]=$plan.Changes[0].After
Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $journal -Read $read -Write $write -Remove $remove | Out-Null
Check ($script:store.Count -eq @($target.BeforeState.FxProperties).Count) 'Original seven Windows values retained'
foreach($value in $target.BeforeState.FxProperties){Check (Test-DspiTypedValue $value $script:store[$value.Name]) 'OEM value restored exactly'}
Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $journal -Read $read -Write $write -Remove $remove | Out-Null
Check ((Get-Content $journal -Raw | ConvertFrom-Json).State -eq 'RolledBack') 'Repeated rollback is harmless'
$other=$plan.Scope | ConvertTo-Json | ConvertFrom-Json;$other.EndpointId+='-other'
Reject {Undo-DspiRecoveryTransaction -Scope $other -JournalPath $journal -Read $read -Write $write -Remove $remove} 'Cross-device recovery rejected'
Check (!(Test-DspiTypedValue ([pscustomobject]@{Name='x';Kind='MultiString';Value=@('a')}) ([pscustomobject]@{Name='x';Kind='MultiString';Value='a'}))) 'Scalar and multi-string array are distinct'
Check (!(Test-DspiTypedValue ([pscustomobject]@{Name='x';Kind='String';Value='a'}) ([pscustomobject]@{Name='x';Kind='String';Value='A'}))) 'Recovery compares data ordinally'
$success=$journal.Replace('.json','-success.json')
$writeOkay={param($name,$value) $script:store[$name]=$value}
$original=$target.BeforeState.FxProperties[0]
$script:store[$original.Name]=[pscustomobject]@{Name=$original.Name;Kind=$original.Kind;Value='changed OEM value'}
$changedJournal=$journal.Replace('.json','-changed.json')
Reject {Start-DspiRecoveryTransaction -Plan $plan -JournalPath $changedJournal -Read $read -Write $writeOkay} 'Changed OEM effects reject installation'
Check (!(Test-Path -LiteralPath $changedJournal)) 'No journal created for stale baseline'
$script:store[$original.Name]=$original
Start-DspiRecoveryTransaction -Plan $plan -JournalPath $success -Read $read -Write $writeOkay | Out-Null
Check ($script:store.Count -eq 10) 'All three additions applied successfully'
Reject {Start-DspiRecoveryTransaction -Plan $plan -JournalPath $success -Read $read -Write $writeOkay} 'Existing journal is never overwritten'
$removeInterrupted={param($name) $script:store.Remove($name);throw 'Injected rollback interruption after removal'}
Reject {Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $success -Read $read -Write $writeOkay -Remove $removeInterrupted} 'Rollback interruption recorded'
Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $success -Read $read -Write $writeOkay -Remove $remove | Out-Null
Check ($script:store.Count -eq 7) 'Rollback resumes after removal before acknowledgement'
$badJournal=$journal.Replace('.json','-bad.json')
$bad=Get-Content $success -Raw | ConvertFrom-Json
$bad.Entries[0].After.Value='tampered'
$bad | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $badJournal
Reject {Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $badJournal -Read $read -Write $writeOkay -Remove $remove} 'Tampered after-value rejected'
# A new host process must recover solely from persisted state and journal.
$planFile=$journal.Replace('.json','-plan.json');$storeFile=$journal.Replace('.json','-store.json');$processJournal=$journal.Replace('.json','-process.json')
$plan | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath $planFile
@($target.BeforeState.FxProperties) | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $storeFile
$hostExe=(Get-Process -Id $PID).Path
$helper=Join-Path $PSScriptRoot 'apo_recovery_process.ps1'
& $hostExe -NoProfile -File $helper -Mode Apply -PlanPath $planFile -StorePath $storeFile -JournalPath $processJournal 2>&1 | Out-Null
Check ($LASTEXITCODE -eq 23) 'Separate installer process interrupted at expected point'
& $hostExe -NoProfile -File $helper -Mode Undo -PlanPath $planFile -StorePath $storeFile -JournalPath $processJournal
Check ($LASTEXITCODE -eq 0) 'Fresh process successfully recovers from durable journal'
$recovered=@(Get-Content $storeFile -Raw | ConvertFrom-Json)
Check ($recovered.Count -eq 7) 'New-process recovery preserves seven original effects'
foreach($value in $target.BeforeState.FxProperties){Check (Test-DspiTypedValue $value @($recovered | Where-Object Name -eq $value.Name)[0]) 'New-process original value unchanged'}
foreach($ownershipState in @('Pending','Restored')){
$raceJournal=$journal.Replace('.json',('-race-'+$ownershipState+'.json'))
$disk.Entries[2].State=$ownershipState
$disk | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $raceJournal
$script:store=@{};foreach($value in $target.BeforeState.FxProperties){$script:store[$value.Name]=$value}
$script:store[$plan.Changes[0].Name]=$plan.Changes[0].After;$script:store[$plan.Changes[1].Name]=$plan.Changes[1].After
$script:raceReads=0
$raceRead={param($name)
 if($name -eq $plan.Changes[2].Name){$script:raceReads++;if($script:raceReads -eq 2){$script:store[$name]=$plan.Changes[2].After}}
 if($script:store.ContainsKey($name)){$script:store[$name]}else{$null}
}
Reject {Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $raceJournal -Read $raceRead -Write $writeOkay -Remove $remove} "$ownershipState entry concurrently created after preflight is not ours to remove"
Check ($script:store.ContainsKey($plan.Changes[2].Name)) 'Concurrent identical external value preserved'
}
Write-Output "PASS device-scoped recovery ($script:assertions assertions)"
