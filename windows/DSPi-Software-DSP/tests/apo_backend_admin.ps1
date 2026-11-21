param([Parameter(Mandatory)][string]$ReportPath,[string]$ResumeSession,[switch]$Sweep,[int]$CrashStage=0,[string]$ProbeAckPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/MachineBackend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/ProtectedStorage.psm1')
$repo=Split-Path $PSScriptRoot -Parent
if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath)) -cne (Join-Path $repo build) -or (Test-Path -LiteralPath $ReportPath)){throw 'Fresh direct build report required.'}
$checks=0;$session=$null;$context=$null
function Report($v){[IO.File]::WriteAllText($ReportPath,($v | ConvertTo-Json -Depth 8))}
function Clean-Session($s){
 $bundlePath=Join-Path $s.Directory bundle.json
 if(Test-Path -LiteralPath $bundlePath){
  $bundle=Read-DspiProtectedRecord -Directory $s.Directory -Name bundle.json
  $tools=Join-Path $s.Directory tools;Assert-DspiProtectedAcl $tools
  $files=@(Get-ChildItem -LiteralPath $tools -Force)
  if($files.Count -ne $bundle.Files.Count){throw 'Unknown protected recovery tool.'}
  foreach($f in $files){$expected=@($bundle.Files | Where-Object Name -ceq $f.Name);Assert-DspiProtectedAcl $f.FullName -File;if($f.PSIsContainer -or $expected.Count -ne 1 -or (Get-FileHash -LiteralPath $f.FullName).Hash -cne $expected[0].SHA256){throw 'Recovery tool changed.'}}
  foreach($f in $files){[IO.File]::Delete($f.FullName)};[IO.Directory]::Delete($tools,$false)
 }
 $hashes=@{};foreach($name in @('backend.json','lease.json','bundle.json')){$p=Join-Path $s.Directory $name;if(Test-Path -LiteralPath $p){$hashes[$name]=(Get-FileHash -LiteralPath $p).Hash}}
 Remove-DspiProtectedTestRecovery -Session $s -ExpectedRecords $hashes
}
try{
 if($ResumeSession){
  if($ResumeSession -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid test recovery session.'}
  $session=[pscustomobject]@{Directory=(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) ('DSPi-Recovery-Tests\install-'+$ResumeSession));SessionId=$ResumeSession;TestOnly=$true;BaseCreated=$false}
  $context=(Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json).Context
  $protectedRecovery=Join-Path $session.Directory 'tools/Recover-DspiApo.ps1'
  if(Test-Path -LiteralPath $protectedRecovery){& (Get-Process -Id $PID).Path -NoProfile -File $protectedRecovery | Out-Null;if($LASTEXITCODE){throw 'Protected standalone crash recovery failed.'}}else{Undo-DspiMachineTransaction -Session $session | Out-Null}
  Remove-DspiBackendFixture -Context $context
  Clean-Session $session
  Report @{Phase='Passed';RecoveredInterruptedFixture=$true;CleanedUp=$true;AudioChanged=$false};exit 0
 }
 $target=Get-Content (Join-Path $repo 'build/dspi-usb-target-20261117.json') -Raw | ConvertFrom-Json
 $mapping=Get-Content (Join-Path $repo 'build/dspi-endpoint-mapping-20261118.json') -Raw | ConvertFrom-Json
 $context=New-DspiBackendFixture -Target $target -Mapping $mapping -DllPath (Join-Path $repo 'build/dspi-apo.dll')
 # Open the exact real interface with requested rights, but never create/write
 # anything there. All following mutations remain in the fixture mapping.
 $interfaceProbe=[DspiMachine.Native]::Interface($context.Plan.Scope.InterfacePath,$context.Plan.Scope.FunctionInstanceId,$true)
 try{$null=$interfaceProbe.GetSubKeyNames();$checks++}finally{$interfaceProbe.Dispose()}
 $session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
 $recovery=Install-DspiRecoveryBundle -Session $session
 Report @{Phase='Running';Fixture=$context.Base;Session=$session.Directory;Step='apply'}
 $result=Start-DspiMachineTransaction -Context $context -Session $session -CrashStage $CrashStage
 if(!$result.Installed -or !$result.Fixture){throw 'Fixture installation status is wrong.'};$checks++
 $journal=Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json
 if($journal.State -ne 'Installed' -or $journal.Entries.Count -ne @(Get-DspiMachineOperations $context).Count){throw 'Complete protected mutation journal missing.'};$checks++
 $fx=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($context.RegistryPath+'\Interface\FX\0',$false)
 try{if($fx.ValueCount -ne 10){throw 'Published interface did not contain the complete Windows/DSPi chain.'};$checks++}finally{$fx.Dispose()}
 $ops=@(Get-DspiMachineOperations $context);$binary=@($ops | Where-Object Kind -eq File)[0].Path
 if($ProbeAckPath){
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ProbeAckPath)) -cne (Join-Path $repo build) -or (Test-Path -LiteralPath $ProbeAckPath)){throw 'Fresh direct build probe path required.'}
  Report @{Phase='ExecutableProbe';Fixture=$context.Base;Session=$session.Directory;Binary=$binary;SHA256=$context.Plan.Binary.SHA256}
  $until=[DateTime]::UtcNow.AddSeconds(55);while(!(Test-Path -LiteralPath $ProbeAckPath) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100}
  if(!(Test-Path -LiteralPath $ProbeAckPath) -or !(Get-Content -LiteralPath $ProbeAckPath -Raw | ConvertFrom-Json).ExecutableMapped){throw 'Normal-user executable mapping was not proven.'};$checks++
 }
 $acl=Get-Acl -LiteralPath $binary
 $audioRule=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq 'S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775'})
 if($audioRule.Count -ne 1 -or ([int]$audioRule[0].FileSystemRights -band 0x20) -eq 0){throw 'Audio identity lacks DLL execute access.'};$checks++
 $foreign=Join-Path $context.Data 'Profiles\external.txt';[IO.File]::WriteAllText($foreign,'external')
 $refused=$false;try{Undo-DspiMachineTransaction -Session $session}catch{$refused=$true};if(!$refused -or !(Test-Path -LiteralPath $binary)){throw 'Foreign file failed to stop recovery before binary removal.'};$checks++;[IO.File]::Delete($foreign)
 $fx=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($context.RegistryPath+'\Interface\FX\0',$true)
 try{$fx.SetValue('external',123,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$fx.Dispose()}
 $refused=$false;try{Undo-DspiMachineTransaction -Session $session}catch{$refused=$true};if(!$refused -or !(Test-Path -LiteralPath $binary)){throw 'Foreign FX value failed to stop recovery.'};$checks++
 $fx=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($context.RegistryPath+'\Interface\FX\0',$true);try{$fx.DeleteValue('external')}finally{$fx.Dispose()}
 # Use real native-harness profile/meter snapshots, preserving their exact bytes.
 $profileSource=$null;$statusSource=$null
 foreach($capture in Get-ChildItem -LiteralPath (Join-Path $repo build) -Directory -Filter 'apo-live-*'){
  foreach($keyDir in Get-ChildItem -LiteralPath $capture.FullName -Directory){
   $p=Join-Path $keyDir.FullName profile.bin;$t=Join-Path $keyDir.FullName telemetry
   if((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $t)){$s=Get-ChildItem -LiteralPath $t -Filter 'status-*.bin' | Select-Object -First 1;if($s){$profileSource=$p;$statusSource=$s.FullName;break}}
  }
  if($profileSource){break}
 }
 if(!$profileSource){throw 'Native harness profile/telemetry captures required; run build-apo.ps1 first.'}
 $profileRoot=Join-Path $context.Data ('Profiles\'+$context.Plan.Scope.ProfileKey)
 $runtimeHashes=@{}
 $profileFile=Join-Path $profileRoot profile.bin;[IO.File]::Copy($profileSource,$profileFile,$false);$runtimeHashes[$profileFile]=(Get-FileHash -LiteralPath $profileFile).Hash
 $statusFile=Join-Path $profileRoot ('telemetry\'+[IO.Path]::GetFileName($statusSource));[IO.File]::Copy($statusSource,$statusFile,$false);$runtimeHashes[$statusFile]=(Get-FileHash -LiteralPath $statusFile).Hash
 $writer=Join-Path $profileRoot profile.writer.lock;[IO.File]::WriteAllBytes($writer,[byte[]]@());$runtimeHashes[$writer]=(Get-FileHash -LiteralPath $writer).Hash
 Report @{Phase='Running';Fixture=$context.Base;Session=$session.Directory;Step='recover';Operations=$journal.Entries.Count}
 $pin=[IO.File]::Open($binary,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$pending=Undo-DspiMachineTransaction -Session $session;if($pending.RolledBack -or !$pending.Detached -or $pending.PendingFile -cne $binary){throw 'Locked binary was not retained as pending cleanup.'};$checks++}finally{$pin.Dispose()}
 $interrupted=$false;try{Undo-DspiMachineTransaction -Session $session -FailAfter 3}catch{$interrupted=$true};if(!$interrupted){throw 'Expected recovery interruption did not occur.'};$checks++
 & (Get-Process -Id $PID).Path -NoProfile -File $recovery | Out-Null
 if($LASTEXITCODE){throw 'Standalone protected recovery failed.'};$checks++
 & (Get-Process -Id $PID).Path -NoProfile -File $recovery | Out-Null
 if($LASTEXITCODE){throw 'Repeated standalone recovery failed.'};$checks++
 if((Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json).State -ne 'RolledBack'){throw 'Rollback did not finish.'};$checks++
 $after=Read-DspiProtectedRecord -Directory $session.Directory -Name backend.json
 $retained=@($after.Entries | Where-Object State -eq 'Retained' | ForEach-Object {$_.Operation.Path})
 if($retained.Count -lt 3 -or (Test-Path -LiteralPath $binary)){throw 'Used installation did not retain data while removing binary.'};$checks++
 foreach($path in $runtimeHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $runtimeHashes[$path]){throw 'Runtime profile or telemetry was changed by recovery.'};$checks++}
 # A fresh install must safely reuse the retained, correctly protected data.
 $second=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
 $reinstalled=Start-DspiMachineTransaction -Context $context -Session $second
 if(!$reinstalled.Installed){throw 'Reinstall with retained data failed.'};$checks++
 $removed=Undo-DspiMachineTransaction -Session $second
 if(!$removed.RolledBack){throw 'Reinstalled fixture did not recover.'};$checks++
 foreach($path in $runtimeHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $runtimeHashes[$path]){throw 'Reinstallation changed retained settings.'}}
 Clean-Session $second
 # Only test-created retained data is cleaned, with exact hashes/no recursion.
 foreach($directory in $retained){foreach($child in Get-ChildItem -LiteralPath $directory -Force){if($child.FullName -notin $runtimeHashes.Keys -and $child.FullName -notin $retained){throw 'Unknown retained fixture data.'}}}
 foreach($path in $runtimeHashes.Keys){[IO.File]::Delete($path)}
 foreach($directory in @($retained | Sort-Object Length -Descending)){[IO.Directory]::Delete($directory,$false)}
 Remove-DspiBackendFixture -Context $context
 Clean-Session $session
 if($Sweep){
  foreach($boundary in 1..14){
   $context=New-DspiBackendFixture -Target $target -Mapping $mapping -DllPath (Join-Path $repo 'build/dspi-apo.dll');$session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
   Report @{Phase='Running';Step='sweep';Boundary=$boundary;Fixture=$context.Base;Session=$session.Directory}
   $failed=$false;try{Start-DspiMachineTransaction -Context $context -Session $session -FailAfter $boundary | Out-Null}catch{$failed=$true};if(!$failed){throw 'Mutation interruption was not injected.'};$checks++
   Undo-DspiMachineTransaction -Session $session;Remove-DspiBackendFixture -Context $context;Clean-Session $session;$checks++
  }
  foreach($boundary in @(8,12,13,14)){
   $context=New-DspiBackendFixture -Target $target -Mapping $mapping -DllPath (Join-Path $repo 'build/dspi-apo.dll');$session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
   Report @{Phase='Running';Step='stage-sweep';Boundary=$boundary;Fixture=$context.Base;Session=$session.Directory}
   $failed=$false;try{Start-DspiMachineTransaction -Context $context -Session $session -FailStage $boundary | Out-Null}catch{$failed=$true};if(!$failed){throw 'Staged interruption was not injected.'};$checks++
   Undo-DspiMachineTransaction -Session $session;Remove-DspiBackendFixture -Context $context;Clean-Session $session;$checks++
  }
  foreach($scenario in @('changed-inbox','occupied-destination','changed-dll')){
   $context=New-DspiBackendFixture -Target $target -Mapping $mapping -DllPath (Join-Path $repo 'build/dspi-apo.dll');$session=New-DspiProtectedRecovery -TestOnly -SessionId ([guid]::NewGuid().ToString('N'))
   Report @{Phase='Running';Step=$scenario;Fixture=$context.Base;Session=$session.Directory}
   $ops=@(Get-DspiMachineOperations $context)
   if($scenario -eq 'changed-inbox'){$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($context.RegistryPath+'\Interface\MSFX\0',$true);$name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0';$old=$key.GetValue($name);$key.SetValue($name,'changed');$key.Dispose()}
   if($scenario -eq 'occupied-destination'){foreach($op in $ops[0..2]){[DspiMachine.Native]::Directory($op.Path,$op.Sddl)}}
   if($scenario -eq 'changed-dll'){$context.Dll=Join-Path $repo LICENSE}
   $failed=$false;try{Start-DspiMachineTransaction -Context $context -Session $session | Out-Null}catch{$failed=$true};if(!$failed){throw ('Missing refusal for '+$scenario)};$checks++
   if($scenario -eq 'changed-dll'){Undo-DspiMachineTransaction -Session $session | Out-Null}
   else{if(Test-Path -LiteralPath (Join-Path $session.Directory backend.json)){throw 'Preflight refusal unexpectedly began a machine journal.'};$checks++}
   if($scenario -eq 'changed-inbox'){$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($context.RegistryPath+'\Interface\MSFX\0',$true);$key.SetValue($name,$old);$key.Dispose()}
   if($scenario -eq 'occupied-destination'){foreach($op in @($ops[0..2] | Sort-Object {$_.Path.Length} -Descending)){[IO.Directory]::Delete($op.Path,$false)}}
   Remove-DspiBackendFixture -Context $context;Clean-Session $session;$checks++
  }
 }
 Report @{Phase='Passed';Checks=$checks;Operations=$journal.Entries.Count;CleanedUp=$true;AudioChanged=$false;ExactRealInterfaceWriteHandleOpened=$true}
}catch{Report @{Phase='Failed';Error=$_.Exception.Message;Stack=$_.ScriptStackTrace;Fixture=$(if($context){$context.Base}else{$null});Session=$(if($session){$session.Directory}else{$null})};exit 1}
