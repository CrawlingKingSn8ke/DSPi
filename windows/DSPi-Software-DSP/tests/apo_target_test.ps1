$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/TargetPlan.psm1') -Force
function Check($value,$message){if(!$value){throw $message}}
$endpoint=[pscustomobject]@{
    EndpointId='test-endpoint';FriendlyName='DSPi USB';DeviceState=1;FxReadStatus='Read';EnhancementsDisabled=$null
    FxProperties=@([pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5';Kind='String';Value='existing-sfx'})
}
$inspection=[pscustomobject]@{Inventory=[pscustomobject]@{Endpoints=@($endpoint)}}
$dll=[pscustomobject]@{SignatureStatus='NotSigned';Architecture='x64'}
$plan=New-DspiTargetPlan $inspection 'test-endpoint' $dll
Check (!$plan.Installed -and !$plan.Installable -and !$plan.CoexistenceValidated) 'Preparation must never claim installation or coexistence'
Check ($plan.ProposedFxAdditions.Count -eq 3) 'Free EFX slot has explicit additions'
Check ($plan.PreserveUnchangedValues[0].Value -eq 'existing-sfx') 'Existing SFX is retained unchanged'
Check ($plan.ProfileKey -cmatch '^[0-9a-f]{64}$') 'Endpoint-bound profile key'
Check ($plan.FileLayout.Telemetry -like '*\telemetry\status-*') 'Telemetry separated from profile permissions'
$token=[pscustomobject]@{IsAdministrator=$true;GeneratedUtc='2026-11-17T20:00:00Z';Audiodg=@([pscustomobject]@{ProcessId=1;TokenReadable=$true;UserSid='S-1-5-19';IsAppContainer=$false;RestrictedSids=@();Groups=@([pscustomobject]@{Sid='S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775';Attributes=14})})}
$known=New-DspiTargetPlan $inspection 'test-endpoint' $dll $token
Check ($null -ne $known.ObservedAudioIdentity -and $known.Gates -notcontains 'AudioProcessTokenAndRestrictedSidsNotVerified') 'Verified token observation carried into preparation'
Check ($known.Gates -contains 'ProfileAclProvisionAndAccessTestPending' -and !$known.Installable) 'Observed identity does not imply installed permissions or package readiness'
$token.Audiodg[0].Groups[0].Attributes=16
$denied=New-DspiTargetPlan $inspection 'test-endpoint' $dll $token
Check ($null -eq $denied.ObservedAudioIdentity) 'Deny-only service SID is not treated as a usable access grant'
$endpoint.FxProperties += [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15';Kind='MultiString';Value=@('occupied-efx')}
$plan=New-DspiTargetPlan $inspection 'test-endpoint' $dll
Check ($plan.ProposedFxAdditions.Count -eq 0 -and $plan.Gates -contains 'EffectSlotOrProposedPropertyOccupied') 'An occupied multi-EFX slot is not replaced'
$endpoint.FxProperties=@();$endpoint.EnhancementsDisabled=1
$plan=New-DspiTargetPlan $inspection 'test-endpoint' $dll
Check ($plan.ProposedFxAdditions.Count -eq 0 -and $plan.Gates -contains 'EnhancementsDisabled') 'Enhancement setting is preserved'
$failed=$false;try{New-DspiTargetPlan $inspection 'missing' $dll | Out-Null}catch{$failed=$true}
Check $failed 'Unknown endpoint must fail'
Write-Output 'PASS selected APO target planning, preserved effects, occupied slots and explicit deployment gates'
