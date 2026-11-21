# GPL-3.0. Prepares an unsigned engineering-review artifact; never installs or signs.
[CmdletBinding()]
param(
    [string]$OutputName=('apo-review-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)),
    [string]$TargetPlan,
    [string]$Inspection,
    [string]$MappingEvidence,
    [string]$Dll
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$build=Join-Path $root 'build'
if(!$TargetPlan){$TargetPlan=Join-Path $build 'dspi-usb-target-20261117.json'}
if(!$Inspection){$Inspection=Join-Path $build 'deployment-inspection-20261117.json'}
if(!$MappingEvidence){$MappingEvidence=Join-Path $build 'dspi-endpoint-mapping-20261117-final.json'}
if(!$Dll){$Dll=Join-Path $build 'dspi-apo.dll'}
$TargetPlan=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetPlan)
$Inspection=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Inspection)
$MappingEvidence=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MappingEvidence)
$Dll=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dll)
if($OutputName -cnotmatch '^[a-z0-9][a-z0-9-]{0,100}$'){throw 'OutputName must be a simple lowercase folder name, without path separators.'}
function Assert-NoReparse([string]$Path) {
    $walk=[IO.Path]::GetFullPath($Path)
    while($walk){
        if(Test-Path -LiteralPath $walk){
            if((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse path is forbidden: $walk"}
        }
        $parent=[IO.Directory]::GetParent($walk)
        if($null -eq $parent){break};$walk=$parent.FullName
    }
}
Assert-NoReparse $build
if(!(Test-Path -LiteralPath $build -PathType Container)){throw 'Existing project build folder is required.'}
$out=[IO.Path]::GetFullPath((Join-Path $build $OutputName))
if([IO.Directory]::GetParent($out).FullName -cne $build){throw 'Output path must be a direct child of build.'}
if(Test-Path -LiteralPath $out){throw 'Output folder already exists; refusing overwrite.'}
$templates=Join-Path $root 'apo/deployment/inf'
foreach($inputPath in @($TargetPlan,$Inspection,$MappingEvidence,$Dll,(Join-Path $root 'LICENSE'))){
    Assert-NoReparse $inputPath
    if(!(Test-Path -LiteralPath $inputPath -PathType Leaf)){throw "Required input missing: $inputPath"}
}
Assert-NoReparse $templates
foreach($inputItem in Get-ChildItem -LiteralPath $templates -Recurse -Force){Assert-NoReparse $inputItem.FullName}
$p=Get-Content -LiteralPath $TargetPlan -Raw|ConvertFrom-Json
$r=Get-Content -LiteralPath $Inspection -Raw|ConvertFrom-Json
$endpoint='{0.0.0.00000000}.{7903955c-abce-4f0a-8cd8-249a73bc348f}'
if($p.SchemaVersion -ne 1 -or $p.EndpointId -cne $endpoint -or $p.BeforeState.EndpointId -cne $endpoint){throw 'Target plan is not the explicitly selected DSPi endpoint.'}
if($p.Installed -or $p.Installable){throw 'Preparation requires an uninstalled, non-installable target plan.'}
$sha=[Security.Cryptography.SHA256]::Create()
try{$profileKey=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($endpoint.ToLowerInvariant()))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
if($p.ProfileKey -cne $profileKey){throw 'ProfileKey does not match SHA256 of the full lowercase endpoint ID.'}
$expectedIds=@('USB\VID_2E8B&PID_FEAA&REV_0204&MI_00','USB\VID_2E8B&PID_FEAA&MI_00')
$hardware=@($p.BeforeState.HardwareRegistry.Values|Where-Object Name -eq HardwareID)
if($hardware.Count -ne 1 -or $hardware[0].Kind -ne 'MultiString' -or @($hardware[0].Value).Count -ne 2 -or @(Compare-Object $expectedIds @($hardware[0].Value)).Count){throw 'Target hardware IDs differ from the two inspected DSPi USB function IDs.'}
$driver=$p.BeforeState.DriverRegistry.Values
if(@($driver|Where-Object {$_.Name -eq 'InfPath' -and $_.Value -eq 'wdma_usb.inf'}).Count -ne 1 -or @($driver|Where-Object {$_.Name -eq 'InfSection' -and $_.Value -eq 'USBAudio'}).Count -ne 1 -or @($driver|Where-Object {$_.Name -eq 'DriverVersion' -and $_.Value -eq '10.0.19041.5794'}).Count -ne 1){throw 'The inspected USB audio function driver has changed.'}
$inspectedEndpoint=@($r.Inventory.Endpoints|Where-Object EndpointId -eq $endpoint)
if($inspectedEndpoint.Count -ne 1){throw 'Inspection must identify exactly the selected endpoint.'}
if($p.BeforeState.DeviceState -ne 1 -or $p.BeforeState.FxReadStatus -ne 'Read' -or $p.BeforeState.EnhancementsDisabled -eq 1){throw 'Active endpoint with readable, enabled effects is required.'}
$writeNames=@('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7','{d3993a3f-99c2-4402-b5ec-a92a0367664b},7','{67fe7ad1-1232-4c16-94ce-83a4f63be981},1')
$conflictNames=$writeNames+@('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15','{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2')
foreach($facts in @($p.BeforeState,$inspectedEndpoint[0])){
    if(@($facts.FxProperties|Where-Object {$_.Name -in $conflictNames}).Count){throw 'EFX, composite EFX, legacy effect or profile slot is occupied.'}
}
$mapping=Get-Content -LiteralPath $MappingEvidence -Raw | ConvertFrom-Json
if(!$mapping.ReadOnly -or $mapping.Installed -or $mapping.EndpointId -ne $endpoint -or $mapping.FunctionInstanceId -ne 'USB\VID_2E8B&PID_FEAA&MI_00\7&3758099e&1&0000'){throw 'Mapping evidence does not identify the selected function.'}
$interfaces=@($mapping.FunctionInterfaces | Where-Object {$_.Path -like '*\global' -and $_.RegistryStatus -eq 'Read'})
$topology=@($mapping.AllEndpointTopologies | Where-Object {$_.EndpointId -eq $endpoint -and $_.TopologyStatus -eq 'Read' -and $_.HardwareSubtypeStatus -eq 'Read'})
if($interfaces.Count -ne 1 -or $topology.Count -ne 1 -or $topology[0].HardwareConnectorSubtype -ne '{dff21ce1-f70f-11d0-b917-00a0c9223196}' -or $topology[0].AdapterInterface -ne ('{2}.'+$interfaces[0].Path)){throw 'Connected speaker interface mapping was not observed.'}
$existingFx=@($interfaces[0].Keys | Where-Object {($_.RelativePath.Replace('\\','\')) -eq 'FX\0'})
$windowsStore=@($interfaces[0].Keys | Where-Object {($_.RelativePath.Replace('\\','\')) -eq 'MSFX\0' -and $_.Status -eq 'Read'})
if($existingFx.Count -ne 0 -or $windowsStore.Count -ne 1){throw 'Expected absent FX zero and readable Windows MSFX zero.'}
$fxSet='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'
$modeSet='{d3993a3f-99c2-4402-b5ec-a92a0367664b}'
$requiredWindows=[ordered]@{
    ($fxSet+',0')=@('String','{dff21ce1-f70f-11d0-b917-00a0c9223196}')
    ($fxSet+',5')=@('String','{62dc1a93-ae24-464c-a43e-452f824c4250}')
    ($fxSet+',6')=@('String','{637c490d-eee3-4c0a-973f-371958802da2}')
    ($fxSet+',3')=@('String','{5860e1c5-f95c-4a7a-8ec8-8aef24f379a1}')
    ($modeSet+',5')=@('MultiString','{c18e2f7e-933d-4965-b7d1-1eef228d2af3}')
    ($modeSet+',6')=@('MultiString','{c18e2f7e-933d-4965-b7d1-1eef228d2af3}')
    '{b725f130-47ef-101a-a5f1-02608c9eebac},10'=@('String','Microsoft Audio Home Theater Effects')
}
if(@($windowsStore[0].Values).Count -ne $requiredWindows.Count -or @($windowsStore[0].Values | Where-Object {$_.Name -notin $requiredWindows.Keys}).Count){throw 'Windows effect source has unexpected properties; refresh the preservation design.'}
foreach($key in $requiredWindows.Keys){
    foreach($store in @($windowsStore[0].Values,$p.BeforeState.FxProperties)){
        $observed=@($store | Where-Object Name -eq $key)
        if($observed.Count -ne 1 -or $observed[0].Kind -ne $requiredWindows[$key][0] -or @($observed[0].Value).Count -ne 1 -or @($observed[0].Value)[0] -ne $requiredWindows[$key][1]){throw "Windows effect source changed or is incomplete: $key"}
    }
}
$bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Dll))
if($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a){throw 'DLL must be a PE image.'}
$pe=[BitConverter]::ToInt32($bytes,0x3c)
if($pe -lt 64 -or $pe -gt $bytes.Length-24 -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664 -or !([BitConverter]::ToUInt16($bytes,$pe+22) -band 0x2000)){throw 'DLL must be an x64 PE DLL.'}
$dllHash=(Get-FileHash -LiteralPath $Dll -Algorithm SHA256).Hash
if($p.Dll.SHA256 -ne $dllHash){throw 'DLL SHA256 differs from the selected target plan; refresh evidence after testing the binary.'}
$signature=Get-AuthenticodeSignature -LiteralPath $Dll
if($signature.Status -ne 'NotSigned'){throw 'This unsigned review workflow requires the unsigned DLL; review a signed release separately.'}
$component=Get-Content (Join-Path $templates 'dspi-apo-component.inf') -Raw
$extension=(Get-Content (Join-Path $templates 'dspi-usb-extension.inf.in') -Raw).Replace('@@PROFILE_KEY@@',$profileKey)
if($extension.Contains('@@')){throw 'Unresolved template token.'}
$discovered=[ordered]@{}
foreach($tool in @('InfVerif.exe','Inf2Cat.exe')){
    $cmd=Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    $discovered[$tool]=if($cmd){$cmd.Source}else{$null}
}
# All checks above are read-only. Only a fresh direct child of build is created below.
New-Item -ItemType Directory -Path $out -ErrorAction Stop|Out-Null
foreach($dir in @('component','extension','provenance')){New-Item -ItemType Directory -Path (Join-Path $out $dir)|Out-Null}
Copy-Item -LiteralPath $Dll -Destination (Join-Path $out 'component/dspi-apo.dll')
Set-Content -LiteralPath (Join-Path $out 'component/dspi-apo-component.inf') -Value $component -Encoding utf8
Set-Content -LiteralPath (Join-Path $out 'extension/dspi-usb-extension.inf') -Value $extension -Encoding utf8
Copy-Item -LiteralPath (Join-Path $templates 'README.md') -Destination (Join-Path $out 'README.md')
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $out 'DSPi-LICENSE.txt')
Get-ChildItem -LiteralPath (Join-Path $templates 'provenance') -File|ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $out 'provenance')}
$evidence=[ordered]@{
    EndpointId=$endpoint;ProfileKey=$profileKey;HardwareIDs=$expectedIds
    ParentRegistryPath=$p.BeforeState.HardwareRegistry.Path
    ParentInstanceChain=@($p.BeforeState.Pnp|ForEach-Object {$_.InstanceId})
    DriverValues=@($driver|Where-Object {$_.Name -in @('InfPath','InfSection','DriverVersion','MediaInterfaces')})
    ProposedWrites=$p.ProposedFxAdditions;PreserveUnchangedValues=$p.PreserveUnchangedValues
    InterfaceCandidate=[ordered]@{Category='{6994ad04-93ef-11d0-a3cc-00a0c9223196}';Reference='GLOBAL';EffectsSubkey='FX\0';AssociationProven=$false;EndpointScopeProven=$false}
    WindowsStorePreservation=[ordered]@{Source='MSFX\0';ObservedValues=$windowsStore[0].Values;Destination='new FX\0';RuntimeCoexistenceProven=$false;Strategy='Represent inspected Windows association/SFX/MFX/modes/UI in the higher-priority store; never modify MSFX.'}
}
$evidence|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $out 'target-evidence.json') -Encoding utf8
$files=@(Get-ChildItem -LiteralPath $out -File -Recurse|Sort-Object FullName|ForEach-Object {[ordered]@{Path=$_.FullName.Substring($out.Length+1).Replace('\','/');Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$manifest=[ordered]@{
    SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');Purpose='Unsigned, unvalidated engineering review only'
    Installed=$false;Installable=$false;Signed=$false;CatalogsGenerated=$false
    EndpointId=$endpoint;ProfileKey=$profileKey;Architecture='x64';MinWorkstationBuild=19041;ExcludedWorkstationBuildFrom=22000
    HardwareIDs=$expectedIds;DllSignatureStatus=[string]$signature.Status
    Inputs=@(@{Path=[IO.Path]::GetFullPath($TargetPlan);SHA256=(Get-FileHash $TargetPlan -Algorithm SHA256).Hash},@{Path=[IO.Path]::GetFullPath($Inspection);SHA256=(Get-FileHash $Inspection -Algorithm SHA256).Hash},@{Path=$MappingEvidence;SHA256=(Get-FileHash $MappingEvidence).Hash},@{Path=[IO.Path]::GetFullPath($Dll);SHA256=(Get-FileHash $Dll -Algorithm SHA256).Hash})
    Validation=[ordered]@{Structural='Preparation checks only; run tests/apo_package_test.ps1';InfVerif='NotRun';Inf2Cat='NotRun';ToolDiscovery='PATH only; no WDK installed or downloaded by this script';DiscoveredTools=$discovered;AudiodgLoad='NotProven'}
    Gates=@('InterfaceAssociationAndEndpointScopeUnproven','HardwareIdModelWideScopeRequiresReview','WDKInfVerifAndInf2CatNotPassed','SignedCatalogAndProtectedAudioTrustUnproven','ProfileAndTelemetryACLProvisioningMissing','EFXCompatibilityAndCoexistenceUnproven','ConflictAwareRecoveryMissing','ActualAudiodgProcessingUnproven')
    Files=$files
}
$manifest|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding utf8
Write-Output $out
