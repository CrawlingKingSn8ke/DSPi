# GPL-3.0. Pure target preparation; contains no registry/file installation operations.
Set-StrictMode -Version Latest
function New-DspiTargetPlan {
    param([Parameter(Mandatory)]$Inspection,[Parameter(Mandatory)][string]$EndpointId,[Parameter(Mandatory)]$DllFacts,$AudioTokenReport=$null)
    $matches=@($Inspection.Inventory.Endpoints | Where-Object EndpointId -eq $EndpointId)
    if($matches.Count -ne 1){throw 'The selected endpoint must appear exactly once in the inspection.'}
    $endpoint=$matches[0]
    if($endpoint.DeviceState -ne 1 -or $endpoint.FxReadStatus -ne 'Read'){throw 'An active endpoint with a complete effect-property read is required.'}
    $profileKey=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($EndpointId.ToLowerInvariant()))).Replace('-','').ToLowerInvariant()
    $clsid='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
    $names=@('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7','{d3993a3f-99c2-4402-b5ec-a92a0367664b},7','{67fe7ad1-1232-4c16-94ce-83a4f63be981},1')
    $values=@($endpoint.FxProperties)
    $conflicts=@($values | Where-Object { $_.Name -in ($names+@('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15','{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2')) })
    $candidate=$conflicts.Count -eq 0 -and $endpoint.EnhancementsDisabled -ne 1
    $proposals=@()
    if($candidate){
        $proposals=@(
            [pscustomobject]@{Name=$names[0];Kind='String';Value=$clsid;ExpectedBefore='Absent'},
            [pscustomobject]@{Name=$names[1];Kind='MultiString';Value=@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}');ExpectedBefore='Absent'},
            [pscustomobject]@{Name=$names[2];Kind='String';Value=$profileKey;ExpectedBefore='Absent'}
        )
    }
    $audioSid='S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775'
    $observedIdentity=$null
    if($null -ne $AudioTokenReport -and $AudioTokenReport.IsAdministrator){
        $verified=@($AudioTokenReport.Audiodg | Where-Object {
            $_.TokenReadable -and $_.UserSid -eq 'S-1-5-19' -and !$_.IsAppContainer -and @($_.RestrictedSids).Count -eq 0 -and
            @($_.Groups | Where-Object {$_.Sid -eq $audioSid -and ($_.Attributes -band 4) -ne 0 -and ($_.Attributes -band 16) -eq 0}).Count -gt 0
        })
        if($verified.Count -gt 0){$observedIdentity=[pscustomobject]@{UserSid='S-1-5-19';ServiceSid=$audioSid;RestrictedSids=@();AppContainer=$false;ObservedUtc=$AudioTokenReport.GeneratedUtc;ProcessIds=@($verified | ForEach-Object ProcessId)}}
    }
    $gates=@('ComponentOrExtensionPackageNotValidated','DllAndPackageTrustNotValidated','ProfileAclProvisionAndAccessTestPending','InstallerAndConflictAwareRecoveryNotImplemented','ActualAudiodgProcessingNotVerified')
    if($null -eq $observedIdentity){$gates+='AudioProcessTokenAndRestrictedSidsNotVerified'}
    if(!$candidate){$gates+=if($conflicts.Count){'EffectSlotOrProposedPropertyOccupied'}else{'EnhancementsDisabled'}}
    [pscustomobject]@{
        SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');Installed=$false;Installable=$false
        Purpose='Explicitly selected endpoint preparation only. No installation or endpoint writes.'
        EndpointId=$EndpointId;FriendlyName=$endpoint.FriendlyName;ProfileKey=$profileKey
        InsertionCandidate=if($candidate){'EFX slot appears available; retain all current SFX/MFX values'}else{'No safe EFX proposal'}
        CoexistenceValidated=$false;ProposedFxAdditions=$proposals;ConflictingValues=$conflicts
        PreserveUnchangedValues=$values
        BeforeState=$endpoint
        Dll=$DllFacts
        ObservedAudioIdentity=$observedIdentity
        FileLayout=[pscustomobject]@{
            Binary='%DriverStore%\<signed component package>\dspi-apo.dll'
            Profile="%ProgramData%\DSPi\Profiles\$profileKey\profile.bin"
            Telemetry="%ProgramData%\DSPi\Profiles\$profileKey\telemetry\status-<pid>-<serial>.bin"
            Permissions='Administrator-owned binaries; selected user writes profile data; verified audio token reads profile and writes only telemetry. Do not grant broad write access.'
        }
        RecoveryRequirements=@('Recheck endpoint identity, driver, effect values and ACLs before any mutation','Save typed before/after values and original absence for every DSPi-owned mutation','Restore only values still matching the installer-written data; stop on conflicts','Never replace existing SFX/MFX or change protected-audio policy; no automatic audio-service restart')
        Gates=$gates
    }
}
Export-ModuleMember -Function New-DspiTargetPlan
