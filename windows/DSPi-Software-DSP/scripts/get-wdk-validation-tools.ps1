# GPL-3.0. Local tool cache only; no SDK/driver/system installation.
param([string]$Destination=(Join-Path $PSScriptRoot '../.tools/wdk-10.0.26100.1'),[string]$PackagePath,[switch]$VerifyOnly)
$ErrorActionPreference='Stop'
$version='10.0.26100.1'
$expected='247B2919AE451F65BA5F1CD51C7C39730FB0FC383D607F3E8AB317FDDC8A8239'
$pins=[ordered]@{
 'x86/Microsoft.UniversalStore.HardwareWorkflow.Cabinets.dll'='6C17808AABD7BD41341492C090499FC8C5D0346E873F35A1B9E69794C048A007'
 'x86/Microsoft.UniversalStore.HardwareWorkflow.Catalogs.dll'='8E5F207D29AAAB57798DED38C5CDE24B5C8AEF0186E5D69BDAEEC0FE825D9452'
 'x86/Microsoft.UniversalStore.HardwareWorkflow.InfReader.dll'='190485C1564D7D35FDCC76D853022261E5249B77F39CF4CCCF0EDD0BA1569461'
 'x86/Microsoft.UniversalStore.HardwareWorkflow.SubmissionBuilder.dll'='3A2003AA14776C374B817568E31A344F88004148B1753F662C25B4AB24B51EA1'
 'x86/WindowsProtectedFiles.xml'='B6DCF5D577C4EB96A63DBA8E8F952CC9A1B6E7C21C6C5784AEC82B261ABEC640'
 'x86/Inf2Cat.exe'='48FEF0566F71B5F59D44DC3011C973C255B82C8B8E0435D85AB3DE4A2C9949ED'
 'x64/infverif.dll'='7768E087AC21090E070159A5FBBFD1D4F60AF3325C029403457028EC0E17D0F0'
 'x64/infverifhlk.dll'='3260C4CFFB2E45C89692CAEC7AE2A8883C1C98B72F6F398B6BEA3D329DB1778D'
 'x64/infverif.exe'='13C697C3197BD2E0FBD208A66A8D24AE93F7A673A65AA24D35320ADAF7EB6992'
}
function Assert-PlainPath([string]$path){
 for($walk=[IO.Path]::GetFullPath($path);$walk;$walk=Split-Path -Parent $walk){
  if((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Tool cache paths must not be reparse points.'}
  if((Split-Path -Parent $walk) -eq $walk){break}
 }
}
$Destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
Assert-PlainPath $Destination
foreach($relative in @($pins.Keys)+@('provenance.json',"microsoft.windows.wdk.x64.$version.nupkg","microsoft.windows.wdk.x64.$version.nupkg.download")){Assert-PlainPath (Join-Path $Destination $relative)}
if($VerifyOnly){
 $verified=@(foreach($relative in $pins.Keys){
  $target=Join-Path $Destination $relative
  if(!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash -ne $pins[$relative]){throw "Validation tool hash mismatch: $relative"}
  [ordered]@{Path=$relative;SHA256=$pins[$relative]}
 })
 return [pscustomobject]@{Version=$version;PackageSHA256=$expected;Files=$verified}
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
if(!$PackagePath){
    $PackagePath=Join-Path $Destination "microsoft.windows.wdk.x64.$version.nupkg"
    if(!(Test-Path -LiteralPath $PackagePath)){
        $temporary=$PackagePath+'.download'
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$version/microsoft.windows.wdk.x64.$version.nupkg" -OutFile $temporary
        if((Get-FileHash -LiteralPath $temporary).Hash -ne $expected){throw 'Downloaded WDK package hash mismatch.'}
        Move-Item -LiteralPath $temporary -Destination $PackagePath
    }
}
$PackagePath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
Assert-PlainPath $PackagePath
if((Get-FileHash -LiteralPath $PackagePath).Hash -ne $expected){throw 'Pinned WDK package hash mismatch.'}
& dotnet nuget verify $PackagePath --all --verbosity quiet
if($LASTEXITCODE){throw 'WDK NuGet signature verification failed.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($PackagePath)
$files=@()
try{
    foreach($entry in $zip.Entries){
        $relative=$null
        if($entry.FullName -eq 'c/tools//10.0.26100.0/x64/infverif.exe' -or $entry.FullName -like 'c/build/10.0.26100.0/bin/x64/infverif*.dll'){$relative='x64/'+[IO.Path]::GetFileName($entry.FullName)}
        if($entry.FullName -like 'c/bin/10.0.26100.0/x86/*' -and ($entry.FullName -like '*.dll' -or $entry.FullName -like '*.xml' -or $entry.FullName -like '*/Inf2Cat.exe')){$relative='x86/'+[IO.Path]::GetFileName($entry.FullName)}
        if(!$relative){continue}
        $target=Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
        if(!$pins.Contains($relative) -or $hash -ne $pins[$relative]){throw "Pinned tool hash mismatch: $relative"}
        if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw "Existing tool hash mismatch: $relative"}}
        else{[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)}
        $files+=[ordered]@{Path=$relative;SHA256=$hash}
    }
}finally{$zip.Dispose()}
if($files.Count -ne 9){throw 'Unexpected WDK validation-tool contents.'}
[ordered]@{Version=$version;PackagePath=$PackagePath;PackageSHA256=$expected;NuGetSignatureVerified=$true;Files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'provenance.json') -Encoding utf8
Write-Output $Destination
