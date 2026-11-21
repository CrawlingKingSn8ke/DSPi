# GPL-3.0. Exact-interface attachment manifest candidate. No live writer.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Recovery.psm1')
function New-DspiScopedAttachment {
 param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Mapping)
 $recovery=New-DspiRecoveryPlan -Target $Target -Mapping $Mapping
 # A hardware ID is deliberately never used as an installation selector.
 if(@($Mapping.FunctionRegistryEndpoints).Count -ne 1){throw 'Selected function has another associated endpoint; attachment scope is ambiguous.'}
 $interfaces=@($Mapping.FunctionInterfaces | Where-Object Path -eq $recovery.Scope.InterfacePath)
 $interface=$interfaces[0]
 if(@($interface.Keys | Where-Object {$_.RelativePath -match '^FX($|\\)' -and $_.Status -eq 'Read'}).Count){throw 'Existing third-party interface effect store must not be overwritten.'}
 $source=@($interface.Keys | Where-Object {$_.RelativePath -eq 'MSFX\0' -and $_.Status -eq 'Read'})
 if($source.Count -ne 1 -or @($source[0].Values).Count -ne 7){throw 'Complete seven-value Windows speaker store required.'}
 $original=@($Target.BeforeState.FxProperties)
 if($original.Count -ne 7){throw 'Unexpected endpoint Windows effect chain.'}
 foreach($value in $source[0].Values){
  $observed=@($original | Where-Object Name -eq $value.Name)
  if($observed.Count -ne 1 -or $value.Kind -cne $observed[0].Kind -or @($value.Value).Count -ne @($observed[0].Value).Count){throw 'Windows effect source mismatch.'}
  for($i=0;$i -lt @($value.Value).Count;$i++){
   $a=@($value.Value)[$i];$b=@($observed[0].Value)[$i];$ga=[guid]::Empty;$gb=[guid]::Empty
   $equal=if([guid]::TryParse([string]$a,[ref]$ga) -and [guid]::TryParse([string]$b,[ref]$gb)){$ga -eq $gb}else{[string]$a -ceq [string]$b}
   if(!$equal){throw 'Windows effect source mismatch.'}
  }
 }
 $association=@($source[0].Values | Where-Object Name -eq '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0')
 $topology=@($Mapping.AllEndpointTopologies | Where-Object EndpointId -eq $Target.EndpointId)[0]
 if($association.Count -ne 1 -or $topology.HardwareSubtypeStatus -ne 'Read' -or $association[0].Value -ine $topology.HardwareConnectorSubtype -or $association[0].Value -ine '{dff21ce1-f70f-11d0-b917-00a0c9223196}'){throw 'Speaker pin association not proven.'}
 $active=@($Mapping.AllEndpointTopologies | Where-Object State -eq 1)
 if(@($active | Where-Object TopologyStatus -ne 'Read').Count){throw 'Unreadable active endpoint topology blocks scope.'}
 $same=@($active | Where-Object AdapterInterface -eq ('{2}.'+$recovery.Scope.InterfacePath))
 if($same.Count -ne 1 -or $same[0].EndpointId -ine $Target.EndpointId){throw 'Interface is shared by another active endpoint.'}
 $clsid='{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'
 if($Target.Dll.Architecture -cne 'x64' -or $Target.Dll.SHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'Pinned x64 DLL required.'}
 $binary='%ProgramFiles%\DSPi\APO\'+$Target.Dll.SHA256.ToLowerInvariant()+'\dspi-apo.dll'
 $com=@(
  [pscustomobject]@{Key=('CLSID\'+$clsid);Name='';Kind='String';Value='DSPi Standalone APO (development)'}
  [pscustomobject]@{Key=('CLSID\'+$clsid+'\InprocServer32');Name='';Kind='ExpandString';Value=$binary}
  [pscustomobject]@{Key=('CLSID\'+$clsid+'\InprocServer32');Name='ThreadingModel';Kind='String';Value='Both'}
 )
 $apoKey='AudioEngine\AudioProcessingObjects\'+$clsid
 foreach($pair in @(@('FriendlyName','DSPi Standalone APO (development)'),@('Copyright','DSPi contributors, GPL-3.0'))){$com+=[pscustomobject]@{Key=$apoKey;Name=$pair[0];Kind='String';Value=$pair[1]}}
 $numbers=[ordered]@{MajorVersion=0;MinorVersion=1;Flags=14;MinInputConnections=1;MaxInputConnections=1;MinOutputConnections=1;MaxOutputConnections=1;MaxInstances=4294967295;NumAPOInterfaces=4}
 foreach($name in $numbers.Keys){$com+=[pscustomobject]@{Key=$apoKey;Name=$name;Kind='DWord';Value=$numbers[$name]}}
 $i=0
 foreach($iid in @('{fd7f2b29-24d0-4b5c-b177-592c39f9ca10}','{0e5ed805-aba6-49c3-8f9a-2b8c889c4fa8}','{9e1d6a6d-ddbc-4e95-a4c7-ad64ba37846c}','{5fa00f27-add6-499a-8a9d-6b98521fa75b}')){$com+=[pscustomobject]@{Key=$apoKey;Name=('APOInterface'+$i);Kind='String';Value=$iid};$i++}
 $order=@('ProtectedDirectories','Binary','ProfileAndTelemetry','FileAccess','ComAndApoRegistration','InterfaceFx')
 [pscustomobject]@{
  SchemaVersion=1;Kind='ExactInterfaceEngineeringCandidate';Installable=$false;WindowsBackendImplemented=$true;WindowsBackendValidated=$false;Scope=$recovery.Scope
  PackageAction='None';UsesModelWideHardwareMatch=$false;PreservesBaseDriver=$true
  InterfaceBinding=[pscustomobject]@{OpenApi='SetupDiOpenDeviceInterfaceRegKey';InstanceId=$recovery.Scope.FunctionInstanceId;Path=$recovery.Scope.InterfacePath;Child='FX\0';RequireAbsent=$true;Association=$association[0].Value}
  InterfaceValues=@($source[0].Values)+@($recovery.Changes | ForEach-Object After)
  ComRoot='HKLM64\SOFTWARE\Classes';ComValues=$com
  Binary=[pscustomobject]@{Path=$binary;SHA256=$Target.Dll.SHA256;RequireTrustedSignature=$true;AllowExistingDifferentBinary=$false}
  Profile=[pscustomobject]@{Path=('%ProgramData%\DSPi\Profiles\'+$recovery.Scope.ProfileKey);TelemetryChild='telemetry';InstallingUserMayWriteProfile=$true;AudioIdentityMayWriteOnlyTelemetry=$true;RequireVerifiedAudioTokenAccessCheck=$true}
  ApplyOrder=$order;UndoOrder=@($order[5],$order[4],$order[3],$order[2],$order[1],$order[0])
  RollbackRules=@('Capture each resource before-state and ACL before mutation.','Refuse occupied COM class or APO registration.','Refuse nonempty unowned keys or directories.','Preflight all resources before any reverse mutation.','Restore only an unchanged installer after-state; preserve unrelated changes.','No service restart or default-output change.')
  Gates=@('SignedDllAndProtectedAudioTrust','ExactInterfacePropagationNotLiveValidated','ActualAudioTokenAccessProvision','AudiodgLoadAndWindowsChainCoexistence','LiveHostRecoveryNotVerified')
  Limitations=@('Windows 10 legacy registration candidate only; not modern driver package isolation.','MachineBackend implements this manifest; isolated success does not establish live audio compatibility.','An unknown historical endpoint is not assumed absent; only active and exact cached function associations are narrowed.','Device reenumeration may require fresh endpoint/profile binding; never reattach by friendly name or hardware ID.')
 }
}
Export-ModuleMember -Function New-DspiScopedAttachment
