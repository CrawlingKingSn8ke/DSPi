# The caller encodes the selected MMDevice ID as data before starting this script.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($endpoint -notmatch '^\{0\.0\.0\.00000000\}\.\{[a-f0-9-]{36}\}$') { exit 1 }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'DSPi-Recovery'
if (!(Test-Path -LiteralPath $root -PathType Container)) { exit 2 }

function Assert-Protected([string]$path, [bool]$container) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery link rejected.' }
    $acl = Get-Acl -LiteralPath $path
    $sid = [Security.Principal.SecurityIdentifier]
    if ($acl.GetOwner($sid).Value -ne 'S-1-5-32-544' -or !$acl.AreAccessRulesProtected) { throw 'Recovery ownership rejected.' }
    $rules = @($acl.GetAccessRules($true, $true, $sid))
    $inherit = if ($container) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    if ($rules.Count -ne 2 -or @($rules.IdentityReference.Value | Sort-Object -Unique).Count -ne 2) { throw 'Recovery access rejected.' }
    foreach ($rule in $rules) {
        if ($rule.IdentityReference.Value -notin $allowed -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags.ToString() -ne $inherit -or $rule.PropagationFlags -ne 'None') { throw 'Recovery access rejected.' }
    }
}

try {
    Assert-Protected $root $true
    $matches = @(foreach ($session in Get-ChildItem -LiteralPath $root -Directory) {
        if ($session.Name -cnotmatch '^install-[a-f0-9]{32}$') { continue }
        Assert-Protected $session.FullName $true
        $journalPath = Join-Path $session.FullName 'backend.json'
        if (!(Test-Path -LiteralPath $journalPath -PathType Leaf)) { continue }
        Assert-Protected $journalPath $false
        $record = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        if ($record.Context.Mode -eq 'Machine' -and $record.Context.Plan.Scope.EndpointId -eq $endpoint -and
            $record.State -in @('Applying', 'Installed', 'RollingBack', 'WaitingForFileRelease')) { $session.FullName }
    })
    if (!$matches.Count) { exit 2 }
    if ($matches.Count -ne 1) { exit 1 }
    $tools = Join-Path $matches[0] 'tools'
    $recovery = Join-Path $tools 'Recover-DspiApo.ps1'
    Assert-Protected $tools $true
    Assert-Protected $recovery $false
    $running = @(Get-Service Audiosrv -DependentServices | Where-Object Status -eq Running)
    if (@($running | Where-Object Name -ne 'LightingService').Count) { exit 1 }
    $result = & $recovery
    if (!$result.RolledBack -and !$result.Detached) { exit 1 }
    try {
        foreach ($service in $running) { Stop-Service -Name $service.Name }
        Restart-Service Audiosrv
    } finally {
        if ((Get-Service Audiosrv).Status -ne 'Running') { Start-Service Audiosrv }
        foreach ($service in $running) { Start-Service -Name $service.Name }
    }
    if (!$result.RolledBack) { $result = & $recovery }
    if (!$result.RolledBack) { exit 3 }
    if ($restoreProtection) { exit (Complete-DspiAudioProtection) }
    exit 0
} catch { exit 1 }

