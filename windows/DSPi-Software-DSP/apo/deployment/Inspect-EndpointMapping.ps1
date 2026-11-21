[CmdletBinding()]
param(
 [string]$EndpointId='{0.0.0.00000000}.{7903955c-abce-4f0a-8cd8-249a73bc348f}',
 [string]$FunctionInstanceId='USB\VID_2E8B&PID_FEAA&MI_00\7&3758099e&1&0000',
 [string]$OutputPath,
 [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
function Get-DspiMappingClassification {
 param([string]$EndpointId,[string]$CandidateInterface,[object[]]$Endpoints,[bool]$InterfaceInstanceMatches,[bool]$Fx0AssociationMatches,[bool]$EnumerationComplete)
 $matches=@($Endpoints | Where-Object { ($_.AdapterInterface -eq $CandidateInterface -or $_.AdapterInterface -eq ('{2}.'+$CandidateInterface)) })
 $selected=@($matches | Where-Object { $_.EndpointId -eq $EndpointId -and $_.Flow -eq 'Render' })
 $mapping=if(-not $EnumerationComplete -or -not $InterfaceInstanceMatches -or -not $Fx0AssociationMatches){'IncompleteEvidence'} elseif($selected.Count -ne 1){'CandidateDoesNotReachSelectedEndpoint'} elseif($matches.Count -ne 1){'SharedInterface'} else {'UniqueSelectedRenderEndpoint'}
 [pscustomobject]@{Mapping=$mapping; CurrentMatchingEndpointCount=$matches.Count; Installable=$false; ModelWideHardwareIdScopeProvenSafe=$false; Meaning='Current-machine mapping evidence only; does not narrow a model-wide INF to this physical unit.'}
}
if($LibraryOnly){return}
if(-not $OutputPath){throw 'Explicit OutputPath is required.'}
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
if(-not $output.StartsWith($build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'OutputPath must be inside staging build.'}
$cursor=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($output))
while($cursor -and $cursor.FullName.Length -ge $build.Length){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Report ancestors must not be links.'}; $cursor=$cursor.Parent}
if(Test-Path -LiteralPath $output){throw 'Report exists; choose a new path.'}
# All native calls below are enumeration/query operations. Never activate IAudioClient or open a KS stream.
if(-not ('DspiMapping.Reader' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace DspiMapping {
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class EnumeratorClass {}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Enumerator {
 void EnumAudioEndpoints(int flow,uint states,out Devices devices);
 void GetDefaultAudioEndpoint(int flow,int role,out Device device);
 void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,out Device device);
}
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Devices {void GetCount(out uint count); void Item(uint index,out Device device);}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Device {
 void Activate(ref Guid iid,uint context,IntPtr parameters,[MarshalAs(UnmanagedType.IUnknown)] out object result);
 void OpenPropertyStore(uint access,out IntPtr store);
 void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
 void GetState(out uint state);
}
[ComImport, Guid("1BE09788-6894-4089-8586-9A2A6C265AC5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Endpoint {void GetDataFlow(out int flow);}
[ComImport, Guid("2A07407E-6497-4A18-9787-32F79BD0D98F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Topology {void GetConnectorCount(out uint count); void GetConnector(uint index,out Connector connector);}
[ComImport, Guid("AE2DE0E4-5BCA-4F2D-AA46-5D13F8FDB3A9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Part { void GetName([MarshalAs(UnmanagedType.LPWStr)] out string name);void GetLocalId(out uint id);void GetGlobalId([MarshalAs(UnmanagedType.LPWStr)] out string id);void GetPartType(out int type);void GetSubType(out Guid type); }
[ComImport, Guid("9c2c4058-23f5-41de-877a-df3af236a09e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface Connector {
 void GetType(out int type); void GetDataFlow(out int flow); void ConnectTo(Connector other); void Disconnect(); void IsConnected([MarshalAs(UnmanagedType.Bool)] out bool connected); void GetConnectedTo(out Connector other);
 void GetConnectorIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
 void GetDeviceIdConnectedTo([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
public class EndpointRow {public string EndpointId,Flow,TopologyStatus,AdapterInterface,ConnectorId,HardwareConnectorSubtype,HardwareSubtypeStatus; public uint State; public uint ConnectorCount;}
public class ValueRow {public string Name,Kind; public object Value;}
public class KeyRow {public string RelativePath,Status; public List<ValueRow> Values=new List<ValueRow>();}
public class InterfaceRow {public string Path,InstanceId,RegistryStatus; public int Flags; public List<KeyRow> Keys=new List<KeyRow>();}
[StructLayout(LayoutKind.Sequential)] struct InterfaceData {public uint Size; public Guid ClassGuid; public uint Flags; public UIntPtr Reserved;}
[StructLayout(LayoutKind.Sequential)] struct DeviceData {public uint Size; public Guid ClassGuid; public uint DevInst; public UIntPtr Reserved;}
public static class Reader {
[DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid cls,string enumerator,IntPtr hwnd,uint flags);
[DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set,IntPtr dev,ref Guid cls,uint index,ref InterfaceData data);
[DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set,ref InterfaceData data,IntPtr detail,uint size,out uint required,ref DeviceData dev);
[DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInstanceId(IntPtr set,ref DeviceData dev,StringBuilder id,uint size,out uint needed);
[DllImport("setupapi.dll",SetLastError=true)] static extern IntPtr SetupDiOpenDeviceInterfaceRegKey(IntPtr set,ref InterfaceData data,uint reserved,uint access);
[DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
[DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
public static EndpointRow[] Endpoints() {
 var result=new List<EndpointRow>(); var e=(Enumerator)new EnumeratorClass(); Devices devices=null;
 try { e.EnumAudioEndpoints(2,15,out devices); uint count; devices.GetCount(out count);
 for(uint i=0;i<count;i++){Device d=null; object topObject=null; Connector connector=null; var row=new EndpointRow();
 try {devices.Item(i,out d); d.GetId(out row.EndpointId); d.GetState(out row.State); int flow; ((Endpoint)d).GetDataFlow(out flow); row.Flow=flow==0?"Render":"Capture";
 Guid iid=new Guid("2A07407E-6497-4A18-9787-32F79BD0D98F"); d.Activate(ref iid,23,IntPtr.Zero,out topObject); var top=(Topology)topObject; top.GetConnectorCount(out row.ConnectorCount); if(row.ConnectorCount!=1)throw new Exception("Expected single endpoint connector");
 top.GetConnector(0,out connector); connector.GetDeviceIdConnectedTo(out row.AdapterInterface); connector.GetConnectorIdConnectedTo(out row.ConnectorId); Connector hardware=null; try { connector.GetConnectedTo(out hardware); Guid subtype; ((Part)hardware).GetSubType(out subtype); row.HardwareConnectorSubtype=subtype.ToString("B"); row.HardwareSubtypeStatus="Read"; } catch(Exception ex) { row.HardwareSubtypeStatus="Error: "+ex.Message; } finally { if(hardware!=null)Marshal.ReleaseComObject(hardware); } row.TopologyStatus="Read";
 } catch(Exception ex){row.TopologyStatus="Error: "+ex.Message+" (0x"+ex.HResult.ToString("X8")+")";}
 finally {if(connector!=null)Marshal.ReleaseComObject(connector);if(topObject!=null)Marshal.ReleaseComObject(topObject);if(d!=null)Marshal.ReleaseComObject(d);} result.Add(row); }
 }finally {if(devices!=null)Marshal.ReleaseComObject(devices);Marshal.ReleaseComObject(e);}return result.ToArray();
}
static void ReadKey(RegistryKey root,string relative,List<KeyRow> rows,int depth){
 var row=new KeyRow();row.RelativePath=relative; rows.Add(row);
 try { using(var key=relative==""?null:root.OpenSubKey(relative,false)){var current=relative==""?root:key;if(current==null){row.Status="Missing";return;} foreach(var name in current.GetValueNames()) row.Values.Add(new ValueRow{Name=name,Kind=current.GetValueKind(name).ToString(),Value=current.GetValue(name,null,RegistryValueOptions.DoNotExpandEnvironmentNames)});row.Status="Read";
 if(depth>0)foreach(var sub in current.GetSubKeyNames())ReadKey(root,relative==""?sub:relative+"\\"+sub,rows,depth-1);
 }}catch(Exception ex){row.Status="Error: "+ex.Message;}
}
public static InterfaceRow[] Interfaces(string target){
 var rows=new List<InterfaceRow>();Guid cls=new Guid("6994ad04-93ef-11d0-a3cc-00a0c9223196");IntPtr set=SetupDiGetClassDevs(ref cls,null,IntPtr.Zero,16); // includes inactive registered interfaces
 if(set==new IntPtr(-1))throw new System.ComponentModel.Win32Exception();
 try {for(uint i=0;;i++){var data=new InterfaceData();data.Size=(uint)Marshal.SizeOf(data);if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref cls,i,ref data)){int error=Marshal.GetLastWin32Error();if(error==259)break;throw new System.ComponentModel.Win32Exception(error);}
 var dev=new DeviceData();dev.Size=(uint)Marshal.SizeOf(dev);uint required;
 bool sized=SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out required,ref dev);
 int sizeError=Marshal.GetLastWin32Error();
 if(sized || sizeError!=122 || required<8 || required>65536)throw new System.ComponentModel.Win32Exception(sizeError,"Unexpected device-interface detail size");
 IntPtr detail=Marshal.AllocHGlobal((int)required);
 try {Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);if(!SetupDiGetDeviceInterfaceDetail(set,ref data,detail,required,out required,ref dev))throw new System.ComponentModel.Win32Exception();var id=new StringBuilder(1024);uint needed;if(!SetupDiGetDeviceInstanceId(set,ref dev,id,1024,out needed))throw new System.ComponentModel.Win32Exception();if(!String.Equals(id.ToString(),target,StringComparison.OrdinalIgnoreCase))continue;
 var row=new InterfaceRow{Path=Marshal.PtrToStringUni(IntPtr.Add(detail,4)),InstanceId=id.ToString(),Flags=(int)data.Flags};rows.Add(row);
 IntPtr h=SetupDiOpenDeviceInterfaceRegKey(set,ref data,0,0x20019); // KEY_READ only
 if(h==new IntPtr(-1)){row.RegistryStatus="Win32Error: "+Marshal.GetLastWin32Error();continue;}
 try {using(var safe=new SafeRegistryHandle(h,false))using(var key=RegistryKey.FromHandle(safe)){ReadKey(key,"",row.Keys,4);row.RegistryStatus="Read";}}finally{RegCloseKey(h);}
 }finally{Marshal.FreeHGlobal(detail);}}
 }finally{SetupDiDestroyDeviceInfoList(set);}return rows.ToArray();
}
}
}
"@
}
$endpoints=@([DspiMapping.Reader]::Endpoints())
$interfaces=@([DspiMapping.Reader]::Interfaces($FunctionInstanceId))
# Retain cached association identity for disconnected endpoints when live topology is unavailable.
$registryEndpoints=@()
foreach($flow in @('Render','Capture')) {
 $root=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow",$false)
 if(-not $root){throw "Cannot enumerate $flow MMDevice registry"}
 try {foreach($name in $root.GetSubKeyNames()) {
  $key=$root.OpenSubKey($name,$false)
  try {$props=$key.OpenSubKey('Properties',$false); $fx=$key.OpenSubKey('FxProperties',$false)
   try {
    $instance=$props.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
    $association=$props.GetValue('{233164c8-1b2c-4c7d-bc68-b671687a2567},1')
    if($instance -and $instance.EndsWith($FunctionInstanceId,[StringComparison]::OrdinalIgnoreCase)) {
     $values=@();if($fx){foreach($n in $fx.GetValueNames()){$values += [pscustomobject]@{Name=$n;Kind=$fx.GetValueKind($n).ToString();Value=$fx.GetValue($n)}}}
     $registryEndpoints += [pscustomobject]@{Flow=$flow;Key=$name;DeviceState=$key.GetValue('DeviceState');FunctionAssociation=$instance;CachedTopologyAssociation=$association;FxProperties=$values;FxReadStatus=$(if($fx){'Read'}else{'Missing'})}
    }
   } finally {if($props){$props.Dispose()};if($fx){$fx.Dispose()}}
  }finally{$key.Dispose()}
 }}finally{$root.Dispose()}
}
$candidate=@($interfaces|Where-Object {$_.Path -match '\\global$'})
$associationMatches=$false
if($candidate.Count -eq 1){
 $fx0=@($candidate[0].Keys|Where-Object RelativePath -eq 'FX\0')
 # Match documented topology association KS node type and endpoint association, not just APO CLSIDs.
 $selectedRegistry=@($registryEndpoints|Where-Object { $EndpointId.EndsWith($_.Key,[StringComparison]::OrdinalIgnoreCase) })
 if($fx0.Count -eq 1 -and $selectedRegistry.Count -eq 1){
  $interfaceAssociation=@($fx0[0].Values|Where-Object Name -eq '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},0')
  $endpointAssociation=@($selectedRegistry[0].FxProperties|Where-Object Name -eq '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},0')
  $associationMatches=$interfaceAssociation.Count -eq 1 -and $endpointAssociation.Count -eq 1 -and $interfaceAssociation[0].Value -eq $endpointAssociation[0].Value
 }
}
$complete=@($endpoints|Where-Object {$_.TopologyStatus -ne 'Read'}).Count -eq 0
$classification=Get-DspiMappingClassification -EndpointId $EndpointId -CandidateInterface $(if($candidate.Count -eq 1){$candidate[0].Path}else{''}) -Endpoints $endpoints -InterfaceInstanceMatches ($candidate.Count -eq 1) -Fx0AssociationMatches $associationMatches -EnumerationComplete $complete
$report=[pscustomobject]@{SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');ReadOnly=$true;Installed=$false;Installable=$false;EndpointId=$EndpointId;FunctionInstanceId=$FunctionInstanceId;CandidateReferenceString='GLOBAL';CandidateFxKey='FX\0';Classification=$classification;AllEndpointTopologies=$endpoints;FunctionInterfaces=$interfaces;FunctionRegistryEndpoints=$registryEndpoints;Fx0AssociationMatches=$associationMatches;AllLiveTopologiesReadable=$complete;Limitations=@('Cached MMDevice registry associations are evidence, not a supported contract for installation.','Topology failures on any enumerated endpoint keep uniqueness unproven.','GLOBAL is an interface reference string; an INF model hardware ID still targets every matching unit.','The observed adapter MMDevice ID is compared with the literal {2}. prefix plus SetupAPI path; this observed representation is not an installation API contract.','FX zero does not currently exist and has no PKEY_FX_Association; intended endpoint eligibility therefore remains unproven.','Inbox MSFX SFX/MFX must remain active: a higher priority FX store can displace the whole MSFX store even if its registry values are untouched.','No APO, DLL, audio client or physical stream activated; IDeviceTopology activated for metadata only.')}
$json=$report|ConvertTo-Json -Depth 30
$file=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
$output



