$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SharedComponent.psm1') -Force
$path='Software\DSPi-Bundle-Test-'+[guid]::NewGuid().ToString('N')
$registry=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
try{
 $dll='C:\Program Files\DSPi\APO\fixture\dspi-apo.dll'
 $state=Get-DspiComponentState -Classes $registry -DllPath $dll
 if($state -ne 'Absent'){throw 'Fresh fixture does not start absent.'}
 Register-DspiComponent -Classes $registry -DllPath $dll
 if((Get-DspiComponentState -Classes $registry -DllPath $dll) -ne 'Ready'){throw 'Fresh registration did not verify.'}
 if((Get-DspiComponentState -Classes $registry -DllPath ($dll+'.other')) -ne 'Conflict'){throw 'An existing registration must never be overwritten.'}
 Unregister-DspiNewComponent -Classes $registry -DllPath $dll
 if((Get-DspiComponentState -Classes $registry -DllPath $dll) -ne 'Absent'){throw 'Fresh registration rollback did not restore absence.'}
 'PASS fresh shared-component registration, verification, conflict check and rollback'
}finally{
 $registry.Dispose()
 [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($path,$false)
}
