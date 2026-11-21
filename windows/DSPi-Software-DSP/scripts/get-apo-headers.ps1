param([string]$Destination=(Join-Path $PSScriptRoot '..\build\windows-sdk'))
$ErrorActionPreference='Stop'
# These are SDK artifacts, not GPL sources. Keep local build dependencies out of git.
$revision='043261f38d94d53b2438b0ffadb836f194c34a73'
$files=@{
    'audioenginebaseapo.h'='1859398A91A4498F23AD1E06755F9520138308268F4AC4927A3526C3DE1D6382'
    'audiomediatype.h'='20D550D6FE21FED26BEE3E1313791B859984CEF0BD7D1A143A1ACF92FA9481CC'
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach($name in $files.Keys){
    $path=Join-Path $Destination $name
    if(!(Test-Path -LiteralPath $path)){
        $url="https://raw.githubusercontent.com/microsoft/win32metadata/$revision/generation/WinSDK/RecompiledIdlHeaders/um/$name"
        Invoke-WebRequest -Uri $url -OutFile $path
    }
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $files[$name]){throw "Unexpected SDK header content: $name"}
}
