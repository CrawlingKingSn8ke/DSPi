param(
    [string]$Sample=(Join-Path $PSScriptRoot '..\sample-12s.wav'),
    [string]$Suffix='v8'
)
$ErrorActionPreference='Stop'
$exe=Join-Path $PSScriptRoot '..\build\dspi-wav.exe'
$samplePath=(Resolve-Path -LiteralPath $Sample).Path
$folder=Split-Path -Parent $samplePath
$stem=[IO.Path]::GetFileNameWithoutExtension($samplePath)
if($Suffix -notmatch '^[a-zA-Z0-9-]+$'){throw 'Suffix must contain letters, digits or hyphens only'}
$before=(Get-FileHash -LiteralPath $samplePath).Hash
$route=@('--outputs','5','--upmix','adaptive','--clear-routes','--route','1','1','0','--route','2','2','0','--route','3','3','0','--route','4','4','0','--route','5','5','0')
$recipes=@(
    @{Name='effects-bypass';Flags=@('--gain','-6','--limiter','-1','100')},
    @{Name='psybass';Flags=@('--gain','-6','--psybass','80','-6','6','50','0','--limiter','-1','100')},
    @{Name='subharm';Flags=@('--gain','-6','--subharm','-12','-12','-30','0','--limiter','-1','100')},
    @{Name='leveller';Flags=@('--gain','-6','--leveller','50','medium','12','--limiter','-1','100')},
    @{Name='upmix-5ch';Flags=($route+@('--gain','-6','--limiter','-1','100'))},
    @{Name='all-effects-5ch';Flags=($route+@('--gain','-6','--leveller','50','medium','12','--psybass','80','-6','6','50','0','--subharm','-12','-12','-30','0','--limiter','-1','100'))}
)
foreach($recipe in $recipes){
    $output=Join-Path $folder "$stem-$($recipe.Name)-$Suffix.wav"
    $settings=$recipe.Flags
    & $exe $samplePath $output @settings
    if($LASTEXITCODE){throw "Listening sample failed: $output"}
    Write-Output $output
}
if((Get-FileHash -LiteralPath $samplePath).Hash -ne $before){throw 'Original sample changed'}
