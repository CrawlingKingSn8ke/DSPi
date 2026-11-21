$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../apo/deployment/Inspect-EndpointMapping.ps1') -LibraryOnly
function Assert($condition,$message) { if(-not $condition){throw $message} }
$endpoint='selected'; $path='\\?\usb#unit#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\global'
function Row($id,$flow,$p) { [pscustomobject]@{EndpointId=$id; Flow=$flow; AdapterInterface=$p; TopologyStatus='Read'} }
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' $path)) -InterfaceInstanceMatches $true -Fx0AssociationMatches $true -EnumerationComplete $true
Assert ($r.Mapping -eq 'UniqueSelectedRenderEndpoint') 'Exact unique interface, instance and association should prove current mapping'
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' $path),(Row 'capture' 'Capture' $path)) -InterfaceInstanceMatches $true -Fx0AssociationMatches $true -EnumerationComplete $true
Assert ($r.Mapping -eq 'SharedInterface') 'Render/capture sharing must block exact endpoint scope'
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' 'other')) -InterfaceInstanceMatches $true -Fx0AssociationMatches $true -EnumerationComplete $true
Assert ($r.Mapping -eq 'CandidateDoesNotReachSelectedEndpoint') 'Matching effects GUIDs cannot prove mapping'
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' $path)) -InterfaceInstanceMatches $true -Fx0AssociationMatches $true -EnumerationComplete $false
Assert ($r.Mapping -eq 'IncompleteEvidence') 'Unenumerated or unreadable endpoints must not silently disappear'
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' $path)) -InterfaceInstanceMatches $false -Fx0AssociationMatches $true -EnumerationComplete $true
Assert ($r.Mapping -eq 'IncompleteEvidence') 'The exact USB function must be proved by SetupAPI'
Assert (-not $r.Installable) 'Mapping is never install authorization'
'PASS: endpoint mapping classification (6 assertions)'
$r=Get-DspiMappingClassification -EndpointId $endpoint -CandidateInterface $path -Endpoints @((Row 'selected' 'Render' ('{2}.'+$path))) -InterfaceInstanceMatches $true -Fx0AssociationMatches $true -EnumerationComplete $true
Assert ($r.CurrentMatchingEndpointCount -eq 1) 'Observed adapter MMDevice prefix must be compared exactly with the SetupAPI interface'
$script=Join-Path $PSScriptRoot '../apo/deployment/Inspect-EndpointMapping.ps1'
$rejected=$false; try {& $script -OutputPath $PSCommandPath|Out-Null}catch{$rejected=$true}
Assert $rejected 'Report path outside staging build must be rejected before any collection'
$existing=Join-Path $PSScriptRoot ('../build/mapping-test-'+[guid]::NewGuid().ToString('N')+'.json')
try {
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($existing),'fixture')
 $rejected=$false; try {& $script -OutputPath $existing|Out-Null}catch{$rejected=$true}
 Assert ($rejected -and [IO.File]::ReadAllText([IO.Path]::GetFullPath($existing)) -eq 'fixture') 'Existing evidence must not be overwritten'
} finally {if(Test-Path -LiteralPath $existing){Remove-Item -LiteralPath $existing}}
'PASS: exact observed prefix and output guards (3 assertions)'

