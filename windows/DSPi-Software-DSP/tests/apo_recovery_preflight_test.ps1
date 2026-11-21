param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tag='recovery-preflight-test-'+[guid]::NewGuid().ToString('N')
$runner=Join-Path $root 'apo/deployment/Prepare-DspiRecovery.ps1'
$result=& $runner -PackageRoot $PackageRoot -TargetPlan (Join-Path (Split-Path $PackageRoot -Parent) 'dspi-usb-target-20261117.json') -OutputName $tag
$report=Get-Content -LiteralPath (Join-Path $result 'readiness.json') -Raw | ConvertFrom-Json
if($report.Installable -or $report.Installed -or !$report.ReadOnly -or !$report.PackageHashesValid){throw 'Preflight must preserve uninstalled state and validate actual package'}
if($report.Signatures.Count -ne 3 -or @($report.Signatures | Where-Object Status -ne 'Valid').Count -ne 3){throw 'This unsigned review package must report three unsigned files'}
if('PackageOrDllNotTrusted' -notin $report.Blockers -or 'DeviceInstanceAttachmentNotValidated' -notin $report.Blockers){throw 'Real installation blockers must remain visible'}
$plan=Get-Content -LiteralPath (Join-Path $result 'recovery-plan.json') -Raw | ConvertFrom-Json
if($plan.Scope.EndpointId -ne '{0.0.0.00000000}.{7903955c-abce-4f0a-8cd8-249a73bc348f}'){throw 'Wrong real-device scope'}
if($report.DriverComparison.Status -ne 'Matches'){throw 'Device driver must match reviewed snapshot'}
if($report.EffectAclComparison.Status -ne 'Matches'){throw 'Endpoint ACL must match reviewed snapshot'}
$changed=Join-Path $root ('build/'+$tag+'-changed')
Copy-Item -LiteralPath $PackageRoot -Destination $changed -Recurse
Add-Content -LiteralPath (Join-Path $changed 'component/dspi-apo-component.inf') -Value '; tampered after validation'
$rejected=$false
try {& $runner -PackageRoot $changed -TargetPlan (Join-Path (Split-Path $PackageRoot -Parent) 'dspi-usb-target-20261117.json') -OutputName ($tag+'-rejected') | Out-Null}catch{$rejected=$_.Exception.Message -like '*hash mismatch*'}
if(!$rejected -or (Test-Path -LiteralPath (Join-Path $root ('build/'+$tag+'-rejected')))){throw 'Changed package must be rejected before writing reports'}
Write-Output 'PASS read-only real-device recovery preflight, signatures, driver and ACL checks'
