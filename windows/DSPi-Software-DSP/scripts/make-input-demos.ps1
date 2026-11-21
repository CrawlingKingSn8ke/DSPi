param([string]$Sample=(Join-Path $PSScriptRoot '..\sample-12s.wav'),[string]$Suffix='v9')
$ErrorActionPreference='Stop'
$exe=Join-Path $PSScriptRoot '..\build\dspi-wav.exe'
$source=(Resolve-Path -LiteralPath $Sample).Path;$folder=Split-Path -Parent $source;$stem=[IO.Path]::GetFileNameWithoutExtension($source)
if($Suffix -notmatch '^[a-zA-Z0-9-]+$'){throw 'Suffix must contain letters, digits or hyphens only'}
$before=(Get-FileHash -LiteralPath $source).Hash
$correction=@('--input-channel','all','--preamp','-3','--input-peak','120','.707','3','--input-peak','3000','.707','-3')
$upmix=@('--outputs','5','--upmix','adaptive','--route','3','3','0','--route','4','4','0','--route','5','5','0')
$recipes=@(
    @{Name='input-bypass';Flags=@('--preamp','0','--gain','-6','--limiter','-1','100')},
    @{Name='input-eq-preamp';Flags=($correction+@('--gain','-6','--limiter','-1','100'))},
    @{Name='input-delay';Flags=@('--input-channel','left','--input-delay','2','--input-channel','right','--input-delay','5','--gain','-6','--limiter','-1','100')},
    @{Name='input-fullchain-5ch';Flags=($correction+$upmix+@('--leveller','50','medium','12','--subharm','-12','-12','-30','0','--psybass','80','-6','6','50','0','--gain','-6','--limiter','-1','100'))}
)
foreach($recipe in $recipes){$output=Join-Path $folder "$stem-$($recipe.Name)-$Suffix.wav";$settings=$recipe.Flags;& $exe $source $output @settings;if($LASTEXITCODE){throw "Input demo failed: $output"};Write-Output $output}
if((Get-FileHash -LiteralPath $source).Hash -ne $before){throw 'Original sample changed'}
