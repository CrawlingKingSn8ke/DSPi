$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../apo/deployment/Inspection.psm1'
Import-Module $module -Force
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Endpoint($fx) { [pscustomobject]@{ EndpointId='{0.0.0.00000000}.{2483e5f7-5bf3-4646-8ab6-c57b2c3ca909}'; FriendlyName='Fixture DAC'; DeviceState=1; FxProperties=$fx; FxReadStatus='Read'; Properties=@(); Pnp=@(); EnhancementsDisabled=$null } }
$empty = Get-DspiEndpointAssessment (Endpoint @())
Assert ($empty.AttachmentDecision -eq 'CandidateRequiresReview') 'An empty slot must be a candidate, never permission to install'
Assert (-not $empty.CanInstall) 'Inspection must never authorize install'
$occupied = Get-DspiEndpointAssessment (Endpoint @([pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'; Value='{fixture-clsid}'; Kind='String'}))
Assert ($occupied.AttachmentDecision -eq 'BlockedExistingEffects') 'Occupied effects must not be replaced'
$disabledEndpoint = Endpoint @(); $disabledEndpoint.EnhancementsDisabled = 1
Assert ((Get-DspiEndpointAssessment $disabledEndpoint).AttachmentDecision -eq 'BlockedEnhancementsDisabled') 'Disabled enhancements must remain blocked'
$unknownEndpoint = Endpoint @(); $unknownEndpoint.FxReadStatus='AccessDenied'
Assert ((Get-DspiEndpointAssessment $unknownEndpoint).AttachmentDecision -eq 'BlockedIncompleteInspection') 'An unreadable store must never count as empty'
$inactiveEndpoint = Endpoint @(); $inactiveEndpoint.DeviceState=2
Assert ((Get-DspiEndpointAssessment $inactiveEndpoint).AttachmentDecision -eq 'BlockedInactive') 'Inactive endpoints must be blocked'
$bad = Endpoint @(); $bad.EndpointId='Fixture DAC'
$rejected=$false; try { Get-DspiEndpointAssessment $bad | Out-Null } catch { $rejected=$true }
Assert $rejected 'Friendly names must not be accepted as endpoint identity'
$fixture = [pscustomobject]@{SchemaVersion=1; Endpoints=@((Endpoint @()),(Endpoint @([pscustomobject]@{Name='OEM'; Value='preserve'; Kind='String'})))}
$report = New-DspiInspectionReport -Inventory $fixture -DllFacts ([pscustomobject]@{Path='fixture.dll'; Architecture='x64'; SignatureStatus='NotSigned'})
Assert ($report.Endpoints.Count -eq 2) 'Report must preserve every endpoint'
Assert (-not $report.Installed -and -not $report.Installable) 'An unsigned inspection must never imply installation'
Assert ($report.Gates -contains 'SignedPackageAndProtectedAudioTrustUnproven') 'Trust gate must be explicit'
$fixture.SchemaVersion=2
$rejected=$false; try { New-DspiInspectionReport -Inventory $fixture -DllFacts @{} | Out-Null } catch { $rejected=$true }
Assert $rejected 'Unknown fixture schema must be rejected'
$scriptPath=Join-Path $PSScriptRoot '../apo/deployment/Inspect-DspiDeployment.ps1'
$rejected=$false; try { & $scriptPath -OutputPath $PSCommandPath -DllPath 'unused.dll' | Out-Null } catch { $rejected=$true }
Assert $rejected 'Output outside staging build must be rejected before collection'
$existing=Join-Path $PSScriptRoot '../build/dspi-apo.dll'
if (Test-Path -LiteralPath $existing) {
    $hash=(Get-FileHash -LiteralPath $existing).Hash
    $rejected=$false; try { & $scriptPath -OutputPath $existing -DllPath 'unused.dll' | Out-Null } catch { $rejected=$true }
    Assert ($rejected -and (Get-FileHash -LiteralPath $existing).Hash -eq $hash) 'Existing output must never be overwritten'
}
'PASS: deployment judgement, schema and report destination guards; no system writes'
