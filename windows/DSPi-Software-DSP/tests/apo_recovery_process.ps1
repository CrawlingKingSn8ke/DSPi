# Test helper: JSON lab store only. Never opens the Windows registry.
param([ValidateSet('Apply','Undo')][string]$Mode,[string]$PlanPath,[string]$StorePath,[string]$JournalPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/Recovery.psm1') -Force
$plan=Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$script:store=@{}
foreach($value in (Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json)){$script:store[$value.Name]=$value}
$script:writes=0
function Save-Store { @($script:store.Values) | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $StorePath }
$read={param($name) if($script:store.ContainsKey($name)){$script:store[$name]}else{$null}}
$write={param($name,$value) $script:store[$name]=$value;Save-Store;$script:writes++;if($script:writes -eq 2){throw 'Expected test interruption'}}
$remove={param($name) $script:store.Remove($name);Save-Store}
if($Mode -eq 'Apply'){
 try {Start-DspiRecoveryTransaction -Plan $plan -JournalPath $JournalPath -Read $read -Write $write | Out-Null}
 catch {if($_.Exception.Message -eq 'Expected test interruption'){exit 23};throw}
 throw 'Expected interruption did not occur'
}
Undo-DspiRecoveryTransaction -Scope $plan.Scope -JournalPath $JournalPath -Read $read -Write $write -Remove $remove | Out-Null
Write-Output 'PASS independent-process recovery'
