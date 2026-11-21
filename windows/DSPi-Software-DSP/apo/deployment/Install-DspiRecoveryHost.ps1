# GPL-3.0. Pinned Microsoft PowerShell ZIP deployment, no PATH/policy/remoting changes.
param([Parameter(Mandatory)][string]$ArchivePath,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$expected='CE7484804C0F0AD4DDA10C958E71ACDAF7EEBFB22505C1B480F89E0E9F1DA94D'
$archive=[IO.Path]::GetFullPath($ArchivePath)
$file=[IO.File]::Open($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$zip=$null;$created=[Collections.Generic.List[string]]::new();$parentCreated=$false
$parent=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) PowerShell
$target=Join-Path $parent '7'
function No-Link([string]$p){for($walk=[IO.Path]::GetFullPath($p);$walk;$walk=Split-Path -Parent $walk){if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Recovery host link rejected.'};if((Split-Path -Parent $walk) -eq $walk){break}}}
function Validate-Parent([string]$p){
 No-Link $p;$acl=Get-Acl -LiteralPath $p
 $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Untrusted recovery-host parent owner.'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and ([int]$rule.FileSystemRights -band 0xd0156) -ne 0 -and $rule.IdentityReference.Value -notin $trusted){throw 'Recovery-host parent permits untrusted writes.'}}
}
try{
 No-Link $archive
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($file)).Replace('-','')}finally{$sha.Dispose()}
 if($hash -cne $expected){throw 'Microsoft PowerShell release ZIP hash mismatch.'}
 $file.Position=0;$zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Read,$true)
 $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$entries=@();$total=0L
 foreach($entry in $zip.Entries){
  $name=$entry.FullName.Replace('\','/')
  if($name -match '^[/\\]|:|(^|/)\.\.(/|$)' -or !$names.Add($name)){throw 'Unsafe or duplicated release ZIP entry.'}
  if($entry.Length -gt 67108864){throw 'Recovery host entry exceeds bounded size.'}
  $total+=$entry.Length;$entries+=$entry
 }
 if($entries.Count -gt 5000 -or $total -gt 1073741824 -or !$zip.GetEntry('pwsh.exe')){throw 'Unexpected PowerShell release contents.'}
 if($ValidateOnly){[pscustomobject]@{Validated=$true;Installed=$false;Version='7.6.9';SHA256=$hash;Entries=$entries.Count;Bytes=$total;Target=$target};return}
 Import-Module (Join-Path $PSScriptRoot 'MachineBackend.psm1')
 Import-Module (Join-Path $PSScriptRoot 'ProtectedStorage.psm1')
 Assert-DspiAdministrator
 No-Link $target
 if(Test-Path -LiteralPath $target){throw 'PowerShell7 target already exists; refusing to overwrite it.'}
 $directorySddl='O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)'
 $fileSddl='O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FRFX;;;BU)'
 if(!(Test-Path -LiteralPath $parent)){Validate-Parent (Split-Path $parent -Parent);[DspiMachine.Native]::Directory($parent,$directorySddl);$parentCreated=$true}else{Validate-Parent $parent}
 [DspiMachine.Native]::Directory($target,$directorySddl);$created.Add($target)
 $files=@();$dirs=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $entries){$relative=$entry.FullName.Replace('/','\').TrimEnd('\');if(!$relative){continue};$path=[IO.Path]::GetFullPath((Join-Path $target $relative));if(!$path.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'ZIP target escaped recovery host.'};$d=if($entry.FullName.EndsWith('/')){$path}else{Split-Path $path -Parent};for(;$d -and $d -ine $target;$d=Split-Path $d -Parent){$null=$dirs.Add($d)}}
 foreach($dir in @($dirs | Sort-Object Length)){No-Link $dir;[DspiMachine.Native]::Directory($dir,$directorySddl);$created.Add($dir)}
 foreach($entry in $entries){
  if($entry.FullName.EndsWith('/')){continue}
  $path=Join-Path $target $entry.FullName.Replace('/','\');No-Link $path
  $entryStream=$entry.Open();$memory=[IO.MemoryStream]::new();try{$entryStream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$entryStream.Dispose();$memory.Dispose()}
  [DspiMachine.Native]::File($path,$bytes,$fileSddl);$created.Add($path)
  $files+=[ordered]@{Path=$entry.FullName;SHA256=(Get-FileHash -LiteralPath $path).Hash}
 }
 $exe=Join-Path $target pwsh.exe;$signature=Get-AuthenticodeSignature -LiteralPath $exe
 if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){throw 'Installed recovery host Microsoft signature was not verified.'}
 $version=& $exe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
 if($LASTEXITCODE -ne 0 -or $version.Trim() -cne '7.6.9'){throw 'Installed PowerShell version verification failed.'}
 $result=[ordered]@{Installed=$true;Version=$version.Trim();ArchiveSHA256=$hash;Publisher=$signature.SignerCertificate.Subject;Target=$target;Files=$files;PathChanged=$false;SecurityPolicyChanged=$false;RemotingEnabled=$false}
 $metadata=Join-Path $target dspi-recovery-host.json
 [DspiMachine.Native]::File($metadata,[Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Depth 8)),$fileSddl);$created.Add($metadata)
 [pscustomobject]@{Installed=$true;Version=$version.Trim();Target=$target;Files=$files.Count;Signature='Valid';PolicyChanged=$false;PathChanged=$false}
}catch{
 $message=$_.Exception.Message
 $cause=$_.Exception
 while($cause){if($cause.Data.Contains('DspiOwnedFilePath')){$owned=[string]$cause.Data['DspiOwnedFilePath'];if(!$owned.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Native ownership report escaped host target.'};$created.Add($owned)};$cause=$cause.InnerException}
 foreach($path in @($created | Sort-Object Length -Descending)){
  $full=[IO.Path]::GetFullPath($path);if($full -ine $target -and !$full.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Host rollback escaped its target.'}
  try{No-Link $full;if(Test-Path -LiteralPath $full -PathType Container){[IO.Directory]::Delete($full,$false)}elseif(Test-Path -LiteralPath $full){[IO.File]::Delete($full)}}catch{$message+='; rollback refused: '+$_.Exception.Message}
 }
 if($parentCreated -and (Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0){[IO.Directory]::Delete($parent,$false)}
 throw $message
}finally{if($zip){$zip.Dispose()};$file.Dispose()}
