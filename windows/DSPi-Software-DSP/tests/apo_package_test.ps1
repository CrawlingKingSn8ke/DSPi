# GPL-3.0. Non-installing package preparation regression checks.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$builder=Join-Path $root 'scripts/build-apo-package.ps1'
function Assert($Condition,[string]$Message) { if(!$Condition){throw "FAIL: $Message"} }
Assert (Test-Path -LiteralPath $builder) 'Review package builder exists'
$tag='apo-package-test-'+[guid]::NewGuid().ToString('N')
$package=& $builder -OutputName $tag
$m=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw|ConvertFrom-Json
Assert (!$m.Installed -and !$m.Installable -and !$m.Signed) 'Package never claims installation or signing'
Assert ($m.ProfileKey -ceq '73610d00ce7c1d84228fc7fe9d14039026d7916eaab219c71d36c4599d28cb09') 'Full lowercase endpoint SHA256 matches native contract'
Assert ($m.Gates -contains 'InterfaceAssociationAndEndpointScopeUnproven') 'Unproven GLOBAL mapping is a blocking gate'
Assert ($m.Gates -contains 'SignedCatalogAndProtectedAudioTrustUnproven') 'Trust remains a blocking gate'
Assert ($m.Validation.InfVerif -ne 'Passed') 'Structural assertions do not impersonate WDK validation'
$c=Get-Content (Join-Path $package 'component/dspi-apo-component.inf') -Raw
$e=Get-Content (Join-Path $package 'extension/dspi-usb-extension.inf') -Raw
Assert ($c -match '(?m)^Class\s*=\s*SoftwareComponent\s*$') 'Uses Windows10 component class'
Assert ($c -notmatch 'Class\s*=\s*AudioProcessingObject') 'Rejects Windows11 APO setup class'
Assert ($c -match 'SWC\\VEN_DSPI&CID_E53F75EF' -and $e -match 'ComponentIDs\s*=\s*VEN_DSPI&CID_E53F75EF') 'Extension creates component matched by component INF'
Assert ($c -match 'NumAPOInterfaces.*0x00010001,4') 'Registration advertises all four native APO interfaces'
Assert ($c -match 'PETrust\s*=\s*true') 'Protected audio trust requirement is retained, never bypassed'
Assert ($c -match '\[Components.NTamd64.10.0.1..22000\]' -and $e -match '\[Extensions.NTamd64.10.0.1..22000\]') 'Windows11 empty model ceilings are present'
foreach($guid in @('fd7f2b29-24d0-4b5c-b177-592c39f9ca10','0e5ed805-aba6-49c3-8f9a-2b8c889c4fa8','9e1d6a6d-ddbc-4e95-a4c7-ad64ba37846c','5fa00f27-add6-499a-8a9d-6b98521fa75b')){ Assert ($c.Contains($guid)) "Native APO interface $guid is registered" }
Assert ($c -match 'MajorVersion,0x00010001,0' -and $c -match 'MinorVersion,0x00010001,1' -and $c -match 'Flags,0x00010001,0x0000000e') 'Version and flags match native registration'
Assert ($m.HardwareIDs.Count -eq 2) 'Manifest contains exactly two hardware IDs'
Assert ((Get-Content (Join-Path $package 'provenance/Windows-driver-samples-LICENSE.txt') -Raw).Contains('Microsoft Public License')) 'Actual upstream license retained'
Assert (Test-Path (Join-Path $package 'DSPi-LICENSE.txt')) 'DSPi GPL license retained'
Assert (@(Get-ChildItem $package -Recurse -Filter '*.cat').Count -eq 0) 'No nonexistent signature or catalog is represented as shipped'
$lines=@($e -split '\r?\n'|Where-Object {$_ -match '^HKR,'})
Assert ($lines.Count -eq 10) 'New FX store includes the Windows chain and metadata alongside DSPi'
Assert ($e -notmatch '(?im)^HKR,MSFX|(?im)^HKR,.*FriendlyName') 'Existing inbox stores and endpoint names are not edited'
Assert ($e -match 'WINDOWS_SFX="\{62dc1a93-ae24-464c-a43e-452f824c4250\}"' -and $e -match 'WINDOWS_MFX="\{637c490d-eee3-4c0a-973f-371958802da2\}"') 'Current Windows SFX/MFX are represented in the higher-priority store'
Assert ($e -match 'SPEAKER_ASSOCIATION="\{dff21ce1-f70f-11d0-b917-00a0c9223196\}"') 'Specific observed speaker association is used'
Assert ($e -match 'AddInterface\s*=\s*%KSCATEGORY_AUDIO%,GLOBAL,') 'Targets recorded audio GLOBAL reference only'
Assert ($e -notmatch 'USB\\Class_|MMDEVAPI\\|ROOT\\|USB\\VID_2E8B&PID_FEAA\s*$') 'No broad device, endpoint or composite parent match'
foreach($h in $m.Files){ Assert ((Get-FileHash -LiteralPath (Join-Path $package $h.Path) -Algorithm SHA256).Hash -ceq $h.SHA256) "Hash verified: $($h.Path)" }
function ExpectReject([scriptblock]$Action,[string]$Expected) {
    $rejected=$false
    try { & $Action|Out-Null } catch { Assert ($_.Exception.Message -match $Expected) "Rejection explains $Expected (got $($_.Exception.Message))"; $rejected=$true }
    Assert $rejected "Must reject $Expected"
}
ExpectReject { & $builder -OutputName $tag } 'exists'
ExpectReject { & $builder -OutputName '../escape' } 'OutputName'
$plan=Get-Content (Join-Path $root 'build/dspi-usb-target-20261117.json') -Raw|ConvertFrom-Json
$fixture=Join-Path $root ('build/'+$tag+'-bad.json')
$plan.ProfileKey='a'*64
$plan|ConvertTo-Json -Depth 70|Set-Content -LiteralPath $fixture
ExpectReject { & $builder -OutputName ($tag+'-bad-key') -TargetPlan $fixture } 'ProfileKey'
$plan.ProfileKey=$m.ProfileKey
$dllHashBefore=$plan.Dll.SHA256
$plan.Dll.SHA256='0'*64
$plan|ConvertTo-Json -Depth 70|Set-Content -LiteralPath $fixture
ExpectReject { & $builder -OutputName ($tag+'-bad-binary') -TargetPlan $fixture } 'DLL SHA256'
$plan.Dll.SHA256=$dllHashBefore
($plan.BeforeState.HardwareRegistry.Values|Where-Object Name -eq HardwareID).Value=@('USB\VID_1234&PID_5678&MI_00')
$plan|ConvertTo-Json -Depth 70|Set-Content -LiteralPath $fixture
ExpectReject { & $builder -OutputName ($tag+'-bad-device') -TargetPlan $fixture } 'hardware IDs'
$plan=Get-Content (Join-Path $root 'build/dspi-usb-target-20261117.json') -Raw|ConvertFrom-Json
$plan.BeforeState.FxProperties+= [pscustomobject]@{Name='{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7';Kind='String';Value='{11111111-1111-1111-1111-111111111111}'}
$plan|ConvertTo-Json -Depth 70|Set-Content -LiteralPath $fixture
ExpectReject { & $builder -OutputName ($tag+'-occupied') -TargetPlan $fixture } 'occupied'
Assert (!(Test-Path (Join-Path $root ('build/'+$tag+'-occupied')))) 'Rejected plan never creates output'
$junction=Join-Path $root ('build/'+$tag+'-junction')
New-Item -ItemType Junction -Path $junction -Target $package|Out-Null
ExpectReject { & $builder -OutputName ($tag+'-reparse') -Dll (Join-Path $junction 'component/dspi-apo.dll') } 'Reparse'
Assert (!(Test-Path (Join-Path $root ('build/'+$tag+'-reparse')))) 'Reparse rejection never creates output'
$mapping=Get-Content (Join-Path $root 'build/dspi-endpoint-mapping-20261117-final.json') -Raw | ConvertFrom-Json
$store=@($mapping.FunctionInterfaces[0].Keys | Where-Object {$_.RelativePath.Replace('\\','\') -eq 'MSFX\0'})[0]
@($store.Values | Where-Object Name -eq '{D04E05A6-594B-4fb6-A80D-01AF5EED7D1D},5')[0].Value='{11111111-1111-1111-1111-111111111111}'
$mappingPath=Join-Path $root ('build/'+$tag+'-mapping.json')
$mapping | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $mappingPath
ExpectReject { & $builder -OutputName ($tag+'-changed-windows') -MappingEvidence $mappingPath } 'Windows effect source'
Assert (!(Test-Path (Join-Path $root ('build/'+$tag+'-changed-windows')))) 'Changed Windows chain rejected before output'
$mapping=Get-Content (Join-Path $root 'build/dspi-endpoint-mapping-20261117-final.json') -Raw | ConvertFrom-Json
$store=@($mapping.FunctionInterfaces[0].Keys | Where-Object {$_.RelativePath.Replace('\\','\') -eq 'MSFX\0'})[0]
$store.Values+= [pscustomobject]@{Name='{11111111-1111-1111-1111-111111111111},1';Kind='DWord';Value=1}
$extraPath=Join-Path $root ('build/'+$tag+'-extra-windows.json')
$mapping | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $extraPath
ExpectReject { & $builder -OutputName ($tag+'-extra-windows') -MappingEvidence $extraPath } 'Windows effect source'
Assert (!(Test-Path (Join-Path $root ('build/'+$tag+'-extra-windows')))) 'Unexpected Windows effect parameters must not be dropped'
'PASS: unsigned APO package preparation, preservation, target scope, manifest integrity and rejection checks'
