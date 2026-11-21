# GPL-3.0. Pure install policy. Unknown prerequisites fail closed.
Set-StrictMode -Version Latest
function Get-DspiLiveInstallBlockers($Report){
 if($Report.SchemaVersion -ne 1 -or @($Report.Signatures).Count -ne 3){throw 'Complete current installer readiness required.'}
 # These have moved to the implemented backend or to post-attachment tests.
 # They never exempt a signature, trust, driver, ACL or unknown blocker.
 $moved=@('DeviceInstanceAttachmentNotValidated','PackageComFileAndAclRecoveryNotImplemented','AudioTokenAccessProvisionNotValidated','ActualAudiodgProcessingNotVerified','LiveHostRecoveryNotVerified')
 $gates=@($Report.Blockers | Where-Object {$_ -notin $moved})
 if(@($Report.Signatures | Where-Object Status -ne 'Valid').Count){$gates+='PackageOrDllNotTrusted'}
 @($gates | Sort-Object -Unique)
}
Export-ModuleMember -Function Get-DspiLiveInstallBlockers
