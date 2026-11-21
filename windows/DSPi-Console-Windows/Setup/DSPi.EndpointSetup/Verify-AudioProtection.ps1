$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AudioProtection.psm1') -Force
$name='Software\DSPi-AudioProtectionTest-'+[guid]::NewGuid().ToString('N')
$fixture=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($name)
try {
 $render=$fixture.CreateSubKey('Render')
 $audio=$fixture.CreateSubKey('Audio')
 try {
  $value='DisableProtectedAudioDG'
  $audio.SetValue($value,1,[Microsoft.Win32.RegistryValueKind]::DWord)
  $disabled=$render.CreateSubKey('{00000000-0000-0000-0000-000000000001}')
  try {
   $disabled.SetValue('DeviceState',4)
   $fx=$disabled.CreateSubKey('FxProperties')
   try{
    $fx.SetValue('test-multi-string',[string[]]@('{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}'),[Microsoft.Win32.RegistryValueKind]::MultiString)
    if((Restore-DspiAudioTestValue -Render $render -Audio $audio) -ne 'OtherOutputs' -or $audio.GetValue($value) -ne 1){throw 'A disconnected output must keep the setting.'}
    $fx.DeleteValue('test-multi-string')
    $fx.SetValue('unrelated-effect','{00000000-0000-0000-0000-000000000002}')
    if((Restore-DspiAudioTestValue -Render $render -Audio $audio) -ne 'Restored' -or $value -in $audio.GetValueNames()){throw 'The final detach must remove the test override.'}
    if((Restore-DspiAudioTestValue -Render $render -Audio $audio) -ne 'Unchanged'){throw 'Absent value should be left alone.'}
    $audio.SetValue($value,0,[Microsoft.Win32.RegistryValueKind]::DWord)
    if((Restore-DspiAudioTestValue -Render $render -Audio $audio) -ne 'Unchanged' -or $audio.GetValue($value) -ne 0){throw 'Existing protected value changed.'}
    $audio.SetValue($value,'1',[Microsoft.Win32.RegistryValueKind]::String)
    if((Restore-DspiAudioTestValue -Render $render -Audio $audio) -ne 'Unrecognized' -or $audio.GetValueKind($value) -ne [Microsoft.Win32.RegistryValueKind]::String){throw 'Changed type was overwritten.'}
   }finally{$fx.Dispose()}
  }finally{$disabled.Dispose()}
 }finally{$render.Dispose();$audio.Dispose()}
}finally{
 $fixture.Dispose()
 [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($name,$false)
}
'PASS audio protection restore preserves other DSPi outputs and restores only the test DWORD.'
