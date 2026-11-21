$ErrorActionPreference='Stop'
$programRoot=[Environment]::GetFolderPath('ProgramFiles')
$dataRoot=[Environment]::GetFolderPath('CommonApplicationData')
$reports=Join-Path $programRoot 'DSPi\APO'
$hostExe=Join-Path $programRoot ('DSPi-SetupRuntime-'+$OperationId+'\runtime\pwsh.exe')
$done=Join-Path $reports ('setup-'+$OperationId+'.json')
$taskName='DSPi-EndpointSetup-'+$OperationId
$registered=$false
$sharedCreated=$false
$classes=$null
$binary=$null
function Ensure-ProtectedFolder([string]$path) {
 $audio='S-1-5-80-2676549577-1911656217-2625096541-4178041876-1366760775'
 if(!(Test-Path -LiteralPath $path)){
  $acl=[Security.AccessControl.DirectorySecurity]::new()
  $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GRGX;;;BU)(A;OICI;GRGX;;;'+$audio+')')
  [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($path),$acl)
 }
 $item=Get-Item -LiteralPath $path
 $acl=Get-Acl -LiteralPath $path
 if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'DSPi machine storage is not protected.'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($rule.AccessControlType -eq 'Allow' -and ([int]$rule.FileSystemRights -band 0xd0156) -ne 0 -and
     $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'DSPi machine storage grants write access to an unexpected account.'}
 }
}
try{
 if($Operation -notin @('Install','Remove') -or $OperationId -cnotmatch '^[a-f0-9]{32}$' -or
    $SessionId -cnotmatch '^[a-f0-9]{32}$' -or $EndpointGuid -cnotmatch '^\{[0-9a-f-]{36}\}$'){throw 'Invalid setup request.'}
 if($BootstrapHost -ine $hostExe -or (Get-Process -Id $PID).Path -ine $hostExe -or
    (Get-AuthenticodeSignature -LiteralPath $hostExe).Status -ne 'Valid'){throw 'The protected setup runtime could not be verified.'}
 if($Operation -eq 'Install'){
  $security=Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' -Name DisableProtectedAudioDG
  if($security -ne 1){throw 'This unsigned development package requires the existing local audio test configuration.'}
 }
 $module=Join-Path $Payload 'ProtectedStorage.psm1'
 $workerSource=Join-Path $Payload 'Worker.ps1'
 $moduleBytes=[IO.File]::ReadAllBytes($module)
 $workerBytes=[IO.File]::ReadAllBytes($workerSource)
 $sharedBytes=[IO.File]::ReadAllBytes((Join-Path $Payload 'SharedComponent.psm1'))
 $apoBytes=[IO.File]::ReadAllBytes((Join-Path $Payload 'dspi-apo.dll'))
 $approvedApo='AC58FB436A9C6BA9C5C88A8E8C7CE02E927CA1048860492E03E53FB8059CA4AD'
 if($ApoHash -cne $approvedApo -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($apoBytes)) -cne $approvedApo -or
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sharedBytes)) -cne $SharedHash){throw 'The bundled APO or registration code failed verification.'}
 if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($moduleBytes)) -cne $ModuleHash -or
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($workerBytes)) -cne $WorkerHash){throw 'The embedded setup files changed before use.'}
 New-Module -Name DspiSetupRecovery -ScriptBlock ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($moduleBytes))) | Import-Module
 New-Module -Name DspiSharedComponent -ScriptBlock ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($sharedBytes))) | Import-Module
 Assert-DspiAdministrator
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($sid -ne $ExpectedUser){throw 'Use the same Windows account for administrator approval.'}
 Ensure-ProtectedFolder (Join-Path $programRoot 'DSPi')
 Ensure-ProtectedFolder $reports
 $lock=[DspiSecure.Native]::Lock((Join-Path $reports 'endpoint-setup.lock'))
 try{
  $sessionRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('DSPi-Recovery\install-'+$SessionId)
  if($Operation -eq 'Install'){
   $endpoint='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$EndpointGuid
   $key=Get-Item -LiteralPath $endpoint
   if($key.GetValue('DeviceState') -ne 1 -or 'FxProperties' -in $key.GetSubKeyNames()){throw 'This output is inactive or has existing effects.'}
   $properties=Get-Item -LiteralPath (Join-Path $endpoint 'Properties')
   $instance=$properties.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
   if(!$instance -or $properties.GetValue('{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},8') -ine '{DFF21CE1-F70F-11D0-B917-00A0C9223196}'){throw 'Setup supports active physical speaker outputs.'}
   $profileKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('{0.0.0.00000000}.'+$EndpointGuid))).ToLowerInvariant()
   if(Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('DSPi\Profiles\'+$profileKey))){throw 'This output already has a DSPi profile.'}
   $s=New-DspiProtectedRecovery -SessionId $SessionId
   $null=Write-DspiProtectedRecord -Directory $s.Directory -Name 'endpoint-before.json' -Value @{EndpointGuid=$EndpointGuid;HardwareInstance=$instance;UserSid=$sid;SessionId=$SessionId;FxPropertiesExisted=$false;ProfileExisted=$false}
   [DspiSecure.Native]::Record((Join-Path $sessionRoot 'Worker.ps1'),$workerBytes)
   Ensure-ProtectedFolder (Join-Path $dataRoot 'DSPi')
   Ensure-ProtectedFolder (Join-Path $dataRoot 'DSPi\Profiles')
   $version=Join-Path $reports $approvedApo.ToLowerInvariant()
   $binary=Join-Path $version 'dspi-apo.dll'
   $root=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
   try{$classes=$root.OpenSubKey('SOFTWARE\Classes',$true)}finally{$root.Dispose()}
   $state=Get-DspiComponentState -Classes $classes -DllPath $binary
   if($state -eq 'Conflict'){throw 'An existing DSPi registration uses a different build or has changed. Setup preserved it.'}
   Ensure-ProtectedFolder $version
   if(!(Test-Path -LiteralPath $binary)){
    if($state -eq 'Ready'){throw 'The registered DSPi binary is missing.'}
    $out=[IO.File]::Open($binary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$out.Write($apoBytes,0,$apoBytes.Length);$out.Flush($true)}finally{$out.Dispose()}
   }
   if((Get-Item -LiteralPath $binary).Attributes -band [IO.FileAttributes]::ReparsePoint -or
         (Get-FileHash -LiteralPath $binary).Hash -cne $approvedApo){throw 'The DSPi binary in Program Files did not match the bundle.'}
   if($state -eq 'Absent'){
    $null=Write-DspiProtectedRecord -Directory $s.Directory -Name 'component-before.json' -Value @{Before='Absent';Dll=$binary;SHA256=$approvedApo}
    Register-DspiComponent -Classes $classes -DllPath $binary
    $sharedCreated=$true
   }
  }else{
   $snapshot=Read-DspiProtectedRecord -Directory $sessionRoot -Name 'endpoint-before.json'
   if($snapshot.EndpointGuid -cne $EndpointGuid -or $snapshot.UserSid -cne $sid -or $snapshot.SessionId -cne $SessionId){throw 'The selected output does not match the protected recovery record.'}
  }
  $worker=Join-Path $sessionRoot 'Worker.ps1'
  Assert-DspiProtectedAcl -Path $worker -File
  $protectedHash=(Get-FileHash -LiteralPath $worker).Hash
  $previousWorkers=@('B167AE874F4F3D802C6435F60584962B829A43F71AC3FEAAB9E8EE7A1E763B10','C6A1005B9D12F80F638D4F5E1D9EC5B5246C8A2945913E32C1BD218E9C02265C')
  if($protectedHash -cne $WorkerHash -and ($Operation -ne 'Remove' -or $protectedHash -cnotin $previousWorkers)){
   throw 'The protected endpoint helper differs from this installer version.'
  }
  if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'The temporary task already exists.'}
  $action=New-ScheduledTaskAction -Execute $hostExe -Argument ('-NoLogo -NoProfile -NonInteractive -File "'+$worker+'" -OperationId '+$OperationId+' -Operation '+$Operation)
  $identity=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(3))
  $null=Register-ScheduledTask -TaskName $taskName -Action $action -Principal $identity -Settings $settings
  $registered=$true
  Start-ScheduledTask -TaskName $taskName
  $limit=[DateTime]::UtcNow.AddSeconds(95)
  while(!(Test-Path -LiteralPath $done) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 150}
  if(!(Test-Path -LiteralPath $done)){throw 'Windows did not report that setup completed. Use the protected recovery before retrying.'}
  $outcome=Get-Content -Raw -LiteralPath $done | ConvertFrom-Json
  if($Operation -eq 'Remove' -and $outcome.RolledBack -and $RestoreProtection -ceq '1'){
   $protectionResult=Complete-DspiAudioProtection
   if($protectionResult){exit $protectionResult}
  }
  if($sharedCreated -and !$outcome.Installed -and !$outcome.RecoveryError){
   Unregister-DspiNewComponent -Classes $classes -DllPath $binary
   $sharedCreated=$false
  }
 }catch{
  if($sharedCreated -and !$registered){Unregister-DspiNewComponent -Classes $classes -DllPath $binary}
  throw
 }finally{
  if($classes){$classes.Dispose()}
  $lock.Dispose()
 }
}catch{
 if(!(Test-Path -LiteralPath $done)){
  $problem=@{Endpoint='{0.0.0.00000000}.'+$EndpointGuid;Operation=$Operation;SessionId=$SessionId;Error=$_.Exception.Message;Installed=$false;RolledBack=$false}
  $receipt=[IO.File]::Open($done,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{
   $bytes=[Text.Encoding]::UTF8.GetBytes(($problem | ConvertTo-Json))
   $receipt.Write($bytes,0,$bytes.Length)
  }finally{$receipt.Dispose()}
 }
}finally{
 if($registered){
  for($i=0;$i -lt 25 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running';$i++){Start-Sleep -Milliseconds 200}
  if((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -ne 'Running'){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
 }
}
