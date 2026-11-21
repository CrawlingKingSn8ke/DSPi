param([Parameter(Mandatory)][string]$ToolsRoot,[Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$runner=Join-Path $root 'scripts/validate-apo-package.ps1'
function Check($value,$message){if(!$value){throw $message}}
$tag='wdk-test-'+[guid]::NewGuid().ToString('N')
$result=& $runner -ToolsRoot $ToolsRoot -PackageRoot $PackageRoot -OutputName $tag
$manifest=Get-Content -LiteralPath (Join-Path $result 'manifest.json') -Raw | ConvertFrom-Json
Check ($manifest.Validation.WdkPassed -and $manifest.CatalogsGenerated) 'Real WDK verification and catalog creation must succeed'
Check (!$manifest.Installed -and !$manifest.Installable -and !$manifest.Signed) 'Passing WDK must not imply trusted installation'
Check ($manifest.Validation.Windows10Models -and $manifest.Validation.Windows11Excluded) 'Actual Microsoft parser confirms target OS boundaries'
foreach($part in @('component','extension')){Check (Test-Path -LiteralPath (Join-Path $result "$part\$(if($part -eq 'component'){'dspi-apo-component'}else{'dspi-usb-extension'}).cat")) 'Unsigned catalog is present'}
foreach($file in $manifest.Files){Check ((Get-FileHash -LiteralPath (Join-Path $result $file.Path)).Hash -eq $file.SHA256) 'Output manifest file integrity'}
$tampered=Join-Path $root ('build/'+$tag+'-input')
Copy-Item -LiteralPath $PackageRoot -Destination $tampered -Recurse
Add-Content -LiteralPath (Join-Path $tampered 'component/dspi-apo-component.inf') -Value '; changed after review'
$rejected=$false
try{& $runner -ToolsRoot $ToolsRoot -PackageRoot $tampered -OutputName ($tag+'-tampered') | Out-Null}catch{$rejected=$_.Exception.Message -like '*hash mismatch*'}
Check $rejected 'Changed input must be rejected before invoking tools'
Check (!(Test-Path -LiteralPath (Join-Path $root ('build/'+$tag+'-tampered')))) 'Rejected input must not create output'
$changedTools=Join-Path $root ('build/'+$tag+'-tools')
Copy-Item -LiteralPath $ToolsRoot -Destination $changedTools -Recurse
$changedExe=Join-Path $changedTools 'x64/infverif.exe'
$append=[IO.File]::Open($changedExe,[IO.FileMode]::Append);try{$append.WriteByte(0)}finally{$append.Dispose()}
$rejected=$false
try{& $runner -ToolsRoot $changedTools -PackageRoot $PackageRoot -OutputName ($tag+'-tool-tamper') | Out-Null}catch{$rejected=$_.Exception.Message -like '*tool hash mismatch*'}
Check $rejected 'Modified cached validation tool must be rejected before execution'
Check (!(Test-Path -LiteralPath (Join-Path $root ('build/'+$tag+'-tool-tamper')))) 'Tool mismatch must not create output'
# A producer can supply a self-consistent package with an invalid INF. It must
# still fail the real Microsoft parser rather than just our hash checks.
$inf=Join-Path $tampered 'component/dspi-apo-component.inf'
(Get-Content -LiteralPath $inf -Raw).Replace('Signature="$WINDOWS NT$"','Signature="INVALID"') | Set-Content -LiteralPath $inf
$inputManifest=Get-Content -LiteralPath (Join-Path $tampered 'manifest.json') -Raw | ConvertFrom-Json
foreach($entry in $inputManifest.Files){$item=Get-Item -LiteralPath (Join-Path $tampered $entry.Path);$entry.Bytes=$item.Length;$entry.SHA256=(Get-FileHash -LiteralPath $item.FullName).Hash}
$inputManifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $tampered 'manifest.json')
$failed=$false
try{& $runner -ToolsRoot $ToolsRoot -PackageRoot $tampered -OutputName ($tag+'-invalid') | Out-Null}catch{$failed=$true}
Check $failed 'Invalid INF must fail actual WDK verification'
$failure=Get-Content -LiteralPath (Join-Path $root ('build/'+$tag+'-invalid/validation.json')) -Raw | ConvertFrom-Json
Check (!$failure.WdkPassed -and !$failure.CatalogsGenerated) 'Failed verification must not generate catalogs or claim success'
Write-Output 'PASS actual WDK checks, OS scope, unsigned catalogs, file integrity and invalid-package rejection'
