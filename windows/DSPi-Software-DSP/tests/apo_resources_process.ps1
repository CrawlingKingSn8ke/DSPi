# Isolated Windows test helper only; no live system backend.
param([string]$Descriptor,[ValidateSet('Apply','Undo')][string]$Mode)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/Resources.psm1') -Force
$data=Get-Content -LiteralPath $Descriptor -Raw | ConvertFrom-Json
if($Mode -eq 'Apply'){Invoke-DspiResourceTransaction -Lab $data.Lab -Operations $data.Operations -JournalPath $data.Journal}
else{Undo-DspiResourceTransaction -Lab $data.Lab -JournalPath $data.Journal;Write-Output 'PASS independent-process hard-crash recovery'}
