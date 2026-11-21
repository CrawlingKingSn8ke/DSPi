# GPL-3.0. Remove the development override only after the last DSPi endpoint is detached.
function Restore-DspiAudioTestValue {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Render,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Audio
    )
    $value = 'DisableProtectedAudioDG'
    if ($value -notin $Audio.GetValueNames()) { return 'Unchanged' }
    if ($Audio.GetValueKind($value) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { return 'Unrecognized' }
    $setting = $Audio.GetValue($value)
    if ($setting -eq 0) { return 'Unchanged' }
    if ($setting -ne 1) { return 'Unrecognized' }

    $clsid = '{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
    foreach ($name in $Render.GetSubKeyNames()) {
        $effects = $Render.OpenSubKey("$name\FxProperties")
        if (!$effects) { continue }
        try {
            foreach ($property in $effects.GetValueNames()) {
                if ($clsid -in $effects.GetValue($property)) { return 'OtherOutputs' }
            }
        } finally { $effects.Dispose() }
    }
    if ($Audio.GetValue($value) -isnot [int] -or $Audio.GetValue($value) -ne 1) { return 'Unrecognized' }
    $Audio.DeleteValue($value)
    $Audio.Flush()
    return 'Restored'
}

function Complete-DspiAudioProtection {
    $root = $null
    $render = $null
    $audio = $null
    try {
        $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        $render = $root.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render')
        $audio = $root.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Audio',$true)
        if (!$render -or !$audio) { return 5 }
        $result = Restore-DspiAudioTestValue -Render $render -Audio $audio
    } catch { return 5 }
    finally {
        if ($audio) { $audio.Dispose() }
        if ($render) { $render.Dispose() }
        if ($root) { $root.Dispose() }
    }
    if ($result -eq 'OtherOutputs') { return 4 }
    if ($result -eq 'Unchanged') { return 0 }
    if ($result -ne 'Restored') { return 5 }

    try {
        $running = @(Get-Service Audiosrv -DependentServices | Where-Object Status -eq Running)
        if (@($running | Where-Object Name -ne 'LightingService').Count) { return 6 }
        try {
            foreach ($service in $running) { Stop-Service -Name $service.Name -ErrorAction Stop }
            Restart-Service Audiosrv -ErrorAction Stop
        } finally {
            if ((Get-Service Audiosrv).Status -ne 'Running') { Start-Service Audiosrv -ErrorAction Stop }
            foreach ($service in $running) { Start-Service -Name $service.Name -ErrorAction Stop }
        }
    } catch { return 6 }
    return 0
}

Export-ModuleMember -Function Restore-DspiAudioTestValue,Complete-DspiAudioProtection
