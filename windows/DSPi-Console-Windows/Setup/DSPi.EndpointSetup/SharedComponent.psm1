# GPL-3.0. Shared APO registration used by the local development installer.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$clsid='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
$comPath='CLSID\'+$clsid
$registrationPath='AudioEngine\AudioProcessingObjects\'+$clsid
$friendly='DSPi Standalone APO (development)'
$strings=@{
 FriendlyName=$friendly
 Copyright='DSPi contributors, GPL-3.0'
 APOInterface0='{fd7f2b29-24d0-4b5c-b177-592c39f9ca10}'
 APOInterface1='{0e5ed805-aba6-49c3-8f9a-2b8c889c4fa8}'
 APOInterface2='{9e1d6a6d-ddbc-4e95-a4c7-ad64ba37846c}'
 APOInterface3='{5fa00f27-add6-499a-8a9d-6b98521fa75b}'
}
$numbers=@{MajorVersion=0;MinorVersion=1;Flags=14;MinInputConnections=1;MaxInputConnections=1;MinOutputConnections=1;MaxOutputConnections=1;MaxInstances=-1;NumAPOInterfaces=4}

function Get-DspiComponentState {
 param([Parameter(Mandatory)]$Classes,[Parameter(Mandatory)][string]$DllPath)
 $com=$Classes.OpenSubKey($comPath)
 $registration=$Classes.OpenSubKey($registrationPath)
 $server=$null
 try{
  if(!$com -and !$registration){return 'Absent'}
  if(!$com -or !$registration){return 'Conflict'}
  $server=$com.OpenSubKey('InprocServer32')
  if(!$server -or $server.GetValue('') -ine $DllPath -or $server.GetValueKind('') -ne 'ExpandString' -or
       $server.GetValue('ThreadingModel') -ne 'Both' -or $com.GetValue('') -ne $friendly -or
       $server.ValueCount -ne 2 -or $server.SubKeyCount -ne 0 -or $com.ValueCount -ne 1 -or $com.SubKeyCount -ne 1 -or
       $registration.ValueCount -ne ($strings.Count+$numbers.Count) -or $registration.SubKeyCount -ne 0){return 'Conflict'}
  foreach($name in $strings.Keys){if($registration.GetValue($name) -ine $strings[$name] -or $registration.GetValueKind($name) -ne 'String'){return 'Conflict'}}
  foreach($name in $numbers.Keys){if($registration.GetValue($name) -ne $numbers[$name] -or $registration.GetValueKind($name) -ne 'DWord'){return 'Conflict'}}
  return 'Ready'
 }finally{
  if($server){$server.Dispose()}
  if($com){$com.Dispose()}
  if($registration){$registration.Dispose()}
 }
}

function Register-DspiComponent {
 param([Parameter(Mandatory)]$Classes,[Parameter(Mandatory)][string]$DllPath)
 if((Get-DspiComponentState -Classes $Classes -DllPath $DllPath) -ne 'Absent'){throw 'DSPi already has a COM or audio engine registration.'}
 $comCreated=$false
 $apoCreated=$false
 try{
  $com=$Classes.CreateSubKey($comPath)
  $comCreated=$true
  try{
   $com.SetValue('',$friendly,[Microsoft.Win32.RegistryValueKind]::String)
   $server=$com.CreateSubKey('InprocServer32')
   try{
    $server.SetValue('',$DllPath,[Microsoft.Win32.RegistryValueKind]::ExpandString)
    $server.SetValue('ThreadingModel','Both',[Microsoft.Win32.RegistryValueKind]::String)
    $server.Flush()
   }finally{$server.Dispose()}
  }finally{$com.Dispose()}
  $apo=$Classes.CreateSubKey($registrationPath)
  $apoCreated=$true
  try{
   foreach($name in $strings.Keys){$apo.SetValue($name,$strings[$name],[Microsoft.Win32.RegistryValueKind]::String)}
   foreach($name in $numbers.Keys){$apo.SetValue($name,$numbers[$name],[Microsoft.Win32.RegistryValueKind]::DWord)}
   $apo.Flush()
  }finally{$apo.Dispose()}
  if((Get-DspiComponentState -Classes $Classes -DllPath $DllPath) -ne 'Ready'){throw 'DSPi registration could not be verified.'}
 }catch{
  if($apoCreated){$Classes.DeleteSubKeyTree($registrationPath,$false)}
  if($comCreated){$Classes.DeleteSubKeyTree($comPath,$false)}
  throw
 }
}

function Unregister-DspiNewComponent {
 param([Parameter(Mandatory)]$Classes,[Parameter(Mandatory)][string]$DllPath)
 if((Get-DspiComponentState -Classes $Classes -DllPath $DllPath) -ne 'Ready'){throw 'The DSPi registration changed and was retained for recovery.'}
 $Classes.DeleteSubKeyTree($registrationPath,$false)
 $Classes.DeleteSubKeyTree($comPath,$false)
 $Classes.Flush()
}

Export-ModuleMember -Function Get-DspiComponentState,Register-DspiComponent,Unregister-DspiNewComponent

