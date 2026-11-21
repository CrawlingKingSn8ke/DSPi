$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../apo/deployment/Attachment.psm1') -Force
$repo=Split-Path $PSScriptRoot -Parent
$target=Get-Content (Join-Path $repo 'build/dspi-usb-target-20261117.json') -Raw | ConvertFrom-Json
$mapping=Get-Content (Join-Path $repo 'build/dspi-endpoint-mapping-20261118.json') -Raw | ConvertFrom-Json
$plan=New-DspiScopedAttachment -Target $target -Mapping $mapping
$script:checks=0
function Check($v,$m){$script:checks++;if(!$v){throw $m}}
function Reject([scriptblock]$f,$m){$failed=$false;try{& $f | Out-Null}catch{$failed=$true};Check $failed $m}
Check ($plan.PackageAction -eq 'None') 'No model-wide package installation'
Check ($plan.InterfaceBinding.OpenApi -eq 'SetupDiOpenDeviceInterfaceRegKey') 'Interface opened through supported API'
Check ($plan.InterfaceBinding.InstanceId -ieq $mapping.FunctionInstanceId) 'Exact function instance'
Check ($plan.InterfaceBinding.Path -ieq $plan.Scope.InterfacePath) 'Exact interface path'
Check ($plan.InterfaceValues.Count -eq 10) 'Complete Windows chain plus DSPi values'
Check (!$plan.Installable -and !$plan.WindowsBackendValidated) 'Candidate is not claimed live validated'
Check ($plan.Binary.SHA256 -eq $target.Dll.SHA256) 'Pinned native DLL identity'
Check (@($plan.ComValues).Count -gt 15) 'Full COM/APO registration recorded'
Check ($plan.ApplyOrder[-1] -eq 'InterfaceFx') 'Attach only after binary, COM and access provisioning'
Check ($plan.UndoOrder[0] -eq 'InterfaceFx') 'Detach before removing live resources'
foreach($name in $target.BeforeState.FxProperties.Name){Check (@($plan.InterfaceValues | Where-Object Name -eq $name).Count -eq 1) 'Existing effect metadata retained'}
$second=$mapping | ConvertTo-Json -Depth 40 | ConvertFrom-Json
$extra=$second.FunctionRegistryEndpoints[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$extra.Key='{00000000-0000-0000-0000-000000000002}'
$second.FunctionRegistryEndpoints+= $extra
Reject {New-DspiScopedAttachment -Target $target -Mapping $second} 'Second associated endpoint blocks attachment'
$changed=$mapping | ConvertTo-Json -Depth 40 | ConvertFrom-Json
$fx=@($changed.FunctionInterfaces[0].Keys | Where-Object RelativePath -eq 'MSFX\0')[0]
$fx.Values[0].Value='unexpected'
Reject {New-DspiScopedAttachment -Target $target -Mapping $changed} 'Changed Windows chain source blocked'
Write-Output "PASS exact-device attachment candidate ($script:checks assertions)"
