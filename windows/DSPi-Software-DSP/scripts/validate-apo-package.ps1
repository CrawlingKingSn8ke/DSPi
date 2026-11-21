# GPL-3.0. Microsoft file validation/catalog generation in a fresh build folder.
# No driver installation, signing, registry, service or security-policy operations.
param([Parameter(Mandatory)][string]$ToolsRoot,[Parameter(Mandatory)][string]$PackageRoot,[string]$OutputName=('apo-wdk-'+[guid]::NewGuid().ToString('N')))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$ToolsRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ToolsRoot)
$PackageRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageRoot)
if($OutputName -cnotmatch '^[a-z0-9][a-z0-9-]{0,100}$'){throw 'OutputName must be a simple build folder name.'}
function Assert-PlainPath([string]$path){
    for($walk=[IO.Path]::GetFullPath($path);$walk;$walk=Split-Path -Parent $walk){
        if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse path rejected: $walk"}
        if((Split-Path -Parent $walk) -eq $walk){break}
    }
}
Assert-PlainPath $PackageRoot;Assert-PlainPath $ToolsRoot
$toolEvidence=& (Join-Path $PSScriptRoot 'get-wdk-validation-tools.ps1') -Destination $ToolsRoot -VerifyOnly
$verifier=Join-Path $ToolsRoot 'x64/infverif.exe';$catalog=Join-Path $ToolsRoot 'x86/Inf2Cat.exe'
foreach($tool in @($verifier,$catalog)){if(!(Test-Path -LiteralPath $tool -PathType Leaf)){throw "Validation tool missing: $tool"}}
$sourceManifest=Join-Path $PackageRoot 'manifest.json'
$source=Get-Content -LiteralPath $sourceManifest -Raw | ConvertFrom-Json
if($source.SchemaVersion -ne 1 -or $source.Installed -or $source.Installable -or $source.Signed -or $source.CatalogsGenerated){throw 'Expected an original unsigned, uninstalled review package.'}
$known=@('manifest.json')
foreach($file in $source.Files){
    if([IO.Path]::IsPathRooted($file.Path) -or $file.Path -match '(^|[\\/])\.\.([\\/]|$)'){throw 'Unsafe source manifest path.'}
    $path=Join-Path $PackageRoot $file.Path;Assert-PlainPath $path
    if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ne $file.SHA256){throw "Input hash mismatch: $($file.Path)"}
    $known+=$file.Path.Replace('\','/')
}
foreach($entry in Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force){
    Assert-PlainPath $entry.FullName
    if(!$entry.PSIsContainer -and $entry.FullName.Substring($PackageRoot.Length+1).Replace('\','/') -notin $known){throw 'Source contains a file absent from its manifest.'}
}
$out=Join-Path (Join-Path $root 'build') $OutputName;Assert-PlainPath $out
if($out.StartsWith($PackageRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $PackageRoot.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source and output folders must not contain one another.'}
if(Test-Path -LiteralPath $out){throw 'Validation output exists; refusing overwrite.'}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($entry in Get-ChildItem -LiteralPath $PackageRoot -Force){Copy-Item -LiteralPath $entry.FullName -Destination $out -Recurse}
Move-Item -LiteralPath (Join-Path $out 'manifest.json') -Destination (Join-Path $out 'source-manifest.json')
$report=[ordered]@{SchemaVersion=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');WdkPassed=$false;CatalogsGenerated=$false;Windows10Models=$false;Windows11Excluded=$false;Installed=$false;Installable=$false;Signed=$false;SourceManifestSHA256=(Get-FileHash -LiteralPath $sourceManifest).Hash;ToolsVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($verifier).FileVersion;Checks=@();Error=$null}
$report.ToolEvidence=$toolEvidence
function Run-Check([string]$name,[string]$exe,[string[]]$arguments){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$out
    if($start.PSObject.Properties['ArgumentList']){foreach($argument in $arguments){$start.ArgumentList.Add($argument)}}
    else{$start.Arguments=($arguments | ForEach-Object {'"'+$_.Replace('"','\"')+'"'}) -join ' '}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(!$process.Start()){throw 'Could not start validation tool.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(30000)){$process.Kill();throw 'Validation tool timed out.'}
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $out ($name+'.log')),$text)
        $exit=$process.ExitCode
        $report.Checks+= [ordered]@{Name=$name;Executable=$exe;Arguments=$arguments;ExitCode=$exit;Log=$name+'.log'}
        if($exit -ne 0){throw "WDK check failed: $name (exit $exit). See its log."}
        return $text
    }finally{$process.Dispose()}
}
try{
    $paths=@((Join-Path $out 'component/dspi-apo-component.inf'),(Join-Path $out 'extension/dspi-usb-extension.inf'))
    $null=Run-Check 'infverif-windows-driver' $verifier (@('/w','/rulever','10.0.19041')+$paths)
    $win10=Run-Check 'infverif-windows10-scope' $verifier (@('/w','/rulever','10.0.19041','/osver','NTAMD64.10.0.1..19045','/info')+$paths)
    if(@($win10 -split '\r?\n' | Where-Object {$_ -match '^Hardware ID:'}).Count -ne 3){throw 'Expected component and two USB hardware models for Windows10 x64.'}
    $report.Windows10Models=$true
    $win11=Run-Check 'infverif-windows11-exclusion' $verifier (@('/w','/rulever','10.0.19041','/osver','NTAMD64.10.0.1..22000','/info')+$paths)
    if($win11 -match 'Hardware ID:' -or @($win11 -split '\r?\n' | Where-Object {$_ -match 'No applicable hardware'}).Count -ne 2){throw 'Windows11 exclusion was not proven by the parser.'}
    $report.Windows11Excluded=$true
    foreach($part in @('component','extension')){
        $null=Run-Check ('inf2cat-'+$part) $catalog @(('/driver:'+(Join-Path $out $part)),'/os:10_VB_X64','/verbose')
    }
    foreach($path in @('component/dspi-apo-component.cat','extension/dspi-usb-extension.cat')){if(!(Test-Path -LiteralPath (Join-Path $out $path))){throw 'Catalog generator returned success without its expected output.'}}
    $report.CatalogsGenerated=$true;$report.WdkPassed=$true
}catch{$report.Error=$_.Exception.Message;throw}
finally{$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $out 'validation.json') -Encoding utf8}
$source.GeneratedUtc=$report.GeneratedUtc;$source.Purpose='WDK-checked unsigned engineering review; not installed or trusted for installation'
$source.CatalogsGenerated=$true;$source.Installable=$false;$source.Installed=$false;$source.Signed=$false
$source.Validation=[pscustomobject]$report
$source.Gates=@($source.Gates | Where-Object {$_ -ne 'WDKInfVerifAndInf2CatNotPassed'})
$source.Files=@(Get-ChildItem -LiteralPath $out -Recurse -File | Sort-Object FullName | ForEach-Object {[ordered]@{Path=$_.FullName.Substring($out.Length+1).Replace('\','/');Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$source | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding utf8
Write-Output $out
