Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DspiEndpointAssessment {
    param([Parameter(Mandatory)]$Endpoint)
    if ($Endpoint.EndpointId -notmatch '^\{0\.0\.0\.00000000\}\.\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { throw 'Expected a full render endpoint ID, not a friendly name.' }
    $decision = 'CandidateRequiresReview'
    if ($Endpoint.DeviceState -ne 1) { $decision = 'BlockedInactive' }
    elseif ($Endpoint.FxReadStatus -ne 'Read') { $decision = 'BlockedIncompleteInspection' }
    elseif (@($Endpoint.FxProperties).Count -gt 0) { $decision = 'BlockedExistingEffects' }
    elseif ($Endpoint.EnhancementsDisabled -eq 1) { $decision = 'BlockedEnhancementsDisabled' }
    [pscustomobject]@{ AttachmentDecision=$decision; CanInstall=$false; ProposedInsertion='EFX candidate only; requires target-driver/package validation'; ExistingValuesToPreserve=@($Endpoint.FxProperties) }
}

function New-DspiInspectionReport {
    param([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)]$DllFacts)
    if ($Inventory.SchemaVersion -ne 1) { throw 'Unsupported inventory schema.' }
    $endpoints = @($Inventory.Endpoints | ForEach-Object {
        [pscustomobject]@{ Facts=$_; Assessment=(Get-DspiEndpointAssessment $_) }
    })
    [pscustomobject]@{
        SchemaVersion=1; GeneratedUtc=[DateTime]::UtcNow.ToString('o'); Installed=$false; Installable=$false
        Purpose='Read-only deployment evidence. No target selected and no install performed.'
        Inventory=$Inventory; Dll=$DllFacts; Endpoints=$endpoints
        Gates=@('ExplicitEndpointSelectionRequired','ExactDriverExtensionAndSoftwareComponentINFUnproven','SignedPackageAndProtectedAudioTrustUnproven','EFXCompatibilityAndCoexistenceUnproven','ProfileAndTelemetryACLsRequireVerifiedProcessToken','BackupAndConflictAwareRecoveryRequired','RealAudiodgLoadAndProcessingNotProven')
        Security='Observed DisableProtectedAudioDG is evidence only, never install permission or a security solution. Do not change it, test signing, or other security policy.'
    }
}

function Read-DspiRegistrySnapshot {
    param([Parameter(Mandatory)][string]$SubKey)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return [pscustomobject]@{Path="HKLM\$SubKey"; Status='Absent'; Values=@(); Sddl=$null} }
        $values = @($key.GetValueNames() | ForEach-Object {
            [pscustomobject]@{Name=$_; Kind=$key.GetValueKind($_).ToString(); Value=$key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
        })
        $sddl=$null
        try { $sddl=(Get-Acl -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$SubKey").Sddl } catch { $sddl="Unavailable: $($_.Exception.Message)" }
        [pscustomobject]@{Path="HKLM\$SubKey"; Status='Read'; Values=$values; Sddl=$sddl}
    } catch { [pscustomobject]@{Path="HKLM\$SubKey"; Status='ReadFailed'; Values=@(); Sddl=$null; Error=$_.Exception.Message} }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-DspiDllFacts {
    param([Parameter(Mandatory)][string]$Path)
    $item=Get-Item -LiteralPath $Path
    $stream=[IO.File]::OpenRead($item.FullName)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Not a PE image' }
        $stream.Position=0x3c; $offset=$reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length-6)) { throw 'Invalid PE offset' }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE signature' }
        $machine=$reader.ReadUInt16(); $arch=if ($machine -eq 0x8664) {'x64'} elseif ($machine -eq 0x14c) {'x86'} else {'Other'}
    } finally { $reader.Dispose(); $stream.Dispose() }
    $sig=Get-AuthenticodeSignature -LiteralPath $item.FullName
    [pscustomobject]@{Path=$item.FullName; Bytes=$item.Length; SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash; Architecture=$arch; Machine=$machine; SignatureStatus=$sig.Status.ToString(); SignatureMessage=$sig.StatusMessage; Signer=if($sig.SignerCertificate){$sig.SignerCertificate.Subject}else{$null}; Installed=$false}
}

function Get-DspiLiveInventory {
    # All RegistryKey handles are explicitly read-only. CIM GetOwner only queries ownership.
    $base='SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $render=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($base,$false)
    if ($null -eq $render) { throw 'Render endpoint registry is unavailable.' }
    $endpoints=@()
    try {
        foreach ($id in $render.GetSubKeyNames()) {
            $endpoint=Read-DspiRegistrySnapshot "$base\$id"
            $state=@($endpoint.Values | Where-Object Name -eq 'DeviceState')
            if ($state.Count -ne 1 -or $state[0].Value -ne 1) { continue }
            $props=Read-DspiRegistrySnapshot "$base\$id\Properties"
            $fx=Read-DspiRegistrySnapshot "$base\$id\FxProperties"
            $friendly=@($props.Values | Where-Object Name -eq '{a45c254e-df1c-4efd-8020-67d146a850e0},14')
            $description=@($props.Values | Where-Object Name -eq '{a45c254e-df1c-4efd-8020-67d146a850e0},2')
            $interface=@($props.Values | Where-Object Name -eq '{b3f8fa53-0004-438e-9003-51a46e139bfc},6')
            $displayName=if($friendly.Count){$friendly[0].Value}elseif($description.Count -and $interface.Count){"$($description[0].Value) ($($interface[0].Value))"}elseif($description.Count){$description[0].Value}else{$null}
            $relationship=@($props.Values | Where-Object Name -eq '{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
            $hardwareRegistry=$null; $driverRegistry=$null
            if ($relationship.Count -and $relationship[0].Value -match '^\{\d+\}\.(.+)$') {
                $hardwareRegistry=Read-DspiRegistrySnapshot "SYSTEM\CurrentControlSet\Enum\$($Matches[1])"
                $driver=@($hardwareRegistry.Values | Where-Object Name -eq 'Driver')
                if ($driver.Count) { $driverRegistry=Read-DspiRegistrySnapshot "SYSTEM\CurrentControlSet\Control\Class\$($driver[0].Value)" }
            }
            $disabled=@($fx.Values | Where-Object Name -eq '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5')
            $endpointId="{0.0.0.00000000}.$id"
            $pnp=@(); $instance="SWD\MMDEVAPI\$endpointId"
            $seen=@{}
            for ($depth=0; $depth -lt 8 -and $instance; $depth++) {
                if ($seen.ContainsKey($instance)) { break }; $seen[$instance]=$true
                try {
                    $device=Get-PnpDevice -InstanceId $instance -ErrorAction Stop
                    $deviceProps=@(Get-PnpDeviceProperty -InstanceId $instance -ErrorAction Stop | Select-Object KeyName,Type,Data)
                    $pnp+= [pscustomobject]@{InstanceId=$instance; FriendlyName=$device.FriendlyName; Class=$device.Class; Status=$device.Status; Properties=$deviceProps}
                    $parent=@($deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_Parent')
                    $instance=if($parent.Count){[string]$parent[0].Data}else{$null}
                } catch { $pnp+= [pscustomobject]@{InstanceId=$instance; Error=$_.Exception.Message}; break }
            }
            $endpoints+=[pscustomobject]@{EndpointId=$endpointId; FriendlyName=$displayName; FriendlyNameSource=if($friendly.Count){'PKEY_Device_FriendlyName'}else{'Device description plus interface name from registry'}; DeviceState=1; EndpointRegistry=$endpoint; Properties=$props.Values; PropertiesSnapshot=$props; FxProperties=$fx.Values; FxSnapshot=$fx; FxReadStatus=if($fx.Status -in @('Read','Absent')){'Read'}else{$fx.Status}; EnhancementsDisabled=if($disabled.Count){$disabled[0].Value}else{$null}; Pnp=$pnp; HardwareRegistry=$hardwareRegistry; DriverRegistry=$driverRegistry}
        }
    } finally { $render.Dispose() }
    $processes=@()
    try {
        foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='audiodg.exe'")) {
            try { $owner=Invoke-CimMethod -InputObject $proc -MethodName GetOwner; $ownerSid=Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid
                $processes+=[pscustomobject]@{ProcessId=$proc.ProcessId; ExecutablePath=$proc.ExecutablePath; OwnerReturn=$owner.ReturnValue; OwnerDomain=$owner.Domain; OwnerUser=$owner.User; SidReturn=$ownerSid.ReturnValue; OwnerSid=$ownerSid.Sid; TokenGroupsAndRestrictions='Not inspected; owner alone is insufficient for ACL provisioning'}
            } catch { $processes+=[pscustomobject]@{ProcessId=$proc.ProcessId; Error=$_.Exception.Message} }
        }
    } catch {
        $processes+= [pscustomobject]@{Error=$_.Exception.Message; Source='CIM'}
        $audioProcesses=@(Get-Process -Name audiodg -ErrorAction SilentlyContinue)
        if ($audioProcesses.Count -eq 0) { $processes+= [pscustomobject]@{Source='Get-Process'; Observation='No audiodg instance visible in this session; identity remains unverified'} }
        foreach ($audioProcess in $audioProcesses) {
            $identity=$null; $identityError=$null
            try { $identity=(Get-Process -Id $audioProcess.Id -IncludeUserName -ErrorAction Stop).UserName } catch { $identityError=$_.Exception.Message }
            $processes+= [pscustomobject]@{ProcessId=$audioProcess.Id; OwnerUser=$identity; IdentityError=$identityError; Source='Get-Process'; TokenGroupsAndRestrictions='Not inspected; no ACL provisioning permitted from this evidence alone'}
        }
    }
    try { $os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture }
    catch { $os=[pscustomobject]@{CimError=$_.Exception.Message; Registry=(Read-DspiRegistrySnapshot 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'); ProcessArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()} }
    [pscustomobject]@{SchemaVersion=1; OS=$os; Endpoints=$endpoints; Audiodg=$processes; AudioPolicy=(Read-DspiRegistrySnapshot 'SOFTWARE\Microsoft\Windows\CurrentVersion\Audio'); ExistingEqualizerAPO=(Read-DspiRegistrySnapshot 'SOFTWARE\EqualizerAPO'); PackageModel='Windows 10: SoftwareComponent APO plus target-specific extension/component relationship; Windows 11 AudioProcessingObject class is separate.'}
}

Export-ModuleMember -Function Get-DspiEndpointAssessment,New-DspiInspectionReport,Get-DspiDllFacts,Get-DspiLiveInventory
