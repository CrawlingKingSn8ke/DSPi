$ErrorActionPreference='Stop'
$program=[Environment]::GetFolderPath('ProgramFiles')
$stage=Join-Path $program ('DSPi-SetupRuntime-'+$OperationId)
$sha=[Security.Cryptography.SHA256]::Create()
function Get-Hash([byte[]]$bytes) {
 [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')
}
function Quote([string]$value) { "'" + $value.Replace("'","''") + "'" }
if($OperationId -cnotmatch '^[a-f0-9]{32}$' -or $SessionId -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid setup identifier.'}
if(Test-Path -LiteralPath $stage){throw 'The temporary runtime location already exists.'}
$runtimeStarted=$false
try{
 $adminFile=Join-Path $Payload 'Admin.ps1'
 $admin=[IO.File]::ReadAllBytes($adminFile)
 if((Get-Hash $admin) -cne $AdminHash){throw 'The setup helper changed before launch.'}
 $acl=New-Object Security.AccessControl.DirectorySecurity
 $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
 [IO.Directory]::CreateDirectory($stage,$acl)|Out-Null
 $archive=Join-Path $stage 'PowerShell.zip'
 [IO.File]::Copy($ArchivePath,$archive,$false)
 $file=[IO.File]::OpenRead($archive)
 try{$verified=[BitConverter]::ToString($sha.ComputeHash($file)).Replace('-','')}finally{$file.Dispose()}
 if($verified -cne 'CE7484804C0F0AD4DDA10C958E71ACDAF7EEBFB22505C1B480F89E0E9F1DA94D'){throw 'The bundled Microsoft runtime failed its integrity check.'}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $runtime=Join-Path $stage 'runtime'
 [IO.Compression.ZipFile]::ExtractToDirectory($archive,$runtime)
 $hostExe=Join-Path $runtime 'pwsh.exe'
 if((Get-AuthenticodeSignature -LiteralPath $hostExe).Status -ne 'Valid'){throw 'The bundled Microsoft runtime signature could not be verified.'}
 $lines=@(foreach($name in @('Operation','OperationId','SessionId','EndpointGuid','Payload','ExpectedUser','ModuleHash','WorkerHash','SharedHash','ApoHash')){
  '$'+$name+'='+(Quote (Get-Variable -Name $name -ValueOnly))
 })
 $lines+='$BootstrapHost='+(Quote $hostExe)
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($lines -join [Environment]::NewLine)+[Environment]::NewLine+[Text.Encoding]::UTF8.GetString($admin).TrimStart([char]0xfeff)))
 $runner=Start-Process -FilePath $hostExe -ArgumentList ('-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded) -WindowStyle Hidden -PassThru
 $runtimeStarted=$true
 if(!$runner.WaitForExit(110000)){throw 'The bundled setup helper is still running.'}
 $runtimeStarted=$false
 if($runner.ExitCode){exit $runner.ExitCode}
}finally{
 $sha.Dispose()
 if(!$runtimeStarted -and (Test-Path -LiteralPath $stage)){
  $actual=(Get-Item -LiteralPath $stage)
  if($actual.FullName -ine $stage -or $actual.Parent.FullName -ine $program -or ($actual.Attributes -band [IO.FileAttributes]::ReparsePoint)){
   throw 'The temporary runtime path changed.'
  }
  $task=Get-ScheduledTask -TaskName ('DSPi-EndpointSetup-'+$OperationId) -ErrorAction SilentlyContinue
  if(!$task){Remove-Item -LiteralPath $actual.FullName -Recurse -Force}
 }
}

