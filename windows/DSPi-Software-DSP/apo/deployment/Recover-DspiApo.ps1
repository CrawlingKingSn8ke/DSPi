# GPL-3.0. Standalone elevated recovery from an installed protected tools folder.
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$directory=Split-Path $PSScriptRoot -Parent
$base=Split-Path $directory -Parent
$common=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if((Split-Path $PSScriptRoot -Leaf) -cne 'tools' -or (Split-Path $directory -Leaf) -cnotmatch '^install-[a-f0-9]{32}$' -or $base -notin @((Join-Path $common 'DSPi-Recovery'),(Join-Path $common 'DSPi-Recovery-Tests'))){throw 'Run the protected copy of this command from its recovery session.'}
for($path=$PSScriptRoot;$path;$path=Split-Path -Parent $path){if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Recovery path contains a link.'};if((Split-Path -Parent $path) -eq $path){break}}
Import-Module (Join-Path $PSScriptRoot 'ProtectedStorage.psm1') -Force
Assert-DspiAdministrator
Assert-DspiProtectedAcl $directory;Assert-DspiProtectedAcl $PSScriptRoot
$bundle=Read-DspiProtectedRecord -Directory $directory -Name bundle.json
if($bundle.SchemaVersion -ne 1 -or $bundle.State -ne 'Ready' -or $bundle.Files.Count -ne 6){throw 'Recovery code bundle is incomplete.'}
$expected=@('ProtectedStorage.psm1','Recovery.psm1','Attachment.psm1','MachineNative.cs','MachineBackend.psm1','Recover-DspiApo.ps1')
foreach($name in $expected){$entry=@($bundle.Files | Where-Object Name -ceq $name);$file=Join-Path $PSScriptRoot $name;Assert-DspiProtectedAcl $file -File;if($entry.Count -ne 1 -or (Get-FileHash -LiteralPath $file).Hash -cne $entry[0].SHA256){throw 'Recovery code hash mismatch.'}}
Import-Module (Join-Path $PSScriptRoot 'MachineBackend.psm1')
$session=[pscustomobject]@{Directory=$directory;SessionId=(Split-Path $directory -Leaf).Substring(8);TestOnly=($base -ceq (Join-Path $common 'DSPi-Recovery-Tests'));BaseCreated=$false}
if(!(Test-Path -LiteralPath (Join-Path $directory backend.json))){
 $failure=Read-DspiProtectedRecord -Directory $directory -Name failure.json
 if($failure.NoMachineChangesMade -eq $true){[pscustomobject]@{RolledBack=$true;NoMachineChangesMade=$true;RecoveryDirectory=$directory;AudioServiceRestarted=$false};return}
 throw 'Machine journal is missing; absence is not proof that no changes occurred.'
}
$result=Undo-DspiMachineTransaction -Session $session
$result | Add-Member -NotePropertyName RecoveryDirectory -NotePropertyValue $directory
$result | Add-Member -NotePropertyName AudioServiceRestarted -NotePropertyValue $false
$result
