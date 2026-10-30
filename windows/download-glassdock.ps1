# Download and extract only. No elevation, installation or automatic execution.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$downloads = Join-Path $env:USERPROFILE 'Downloads'
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
Set-Location $downloads
$folder = Join-Path $downloads ('GlassDock-0.2.0-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (Test-Path -LiteralPath $folder) { throw 'Destination already exists; no files changed.' }
New-Item -ItemType Directory -Path $folder | Out-Null
$zip = Join-Path $folder 'GlassDock.zip'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/loschd22211/drag-5-voopoo/releases/download/glassdock-v0.2.0/GlassDock-0.2.0-win-x64.zip' -OutFile $zip
$expected = '50b3803fd8cb2ae3694b32772edb4d16348d8ae12238b6e162f78176ee7f6eb7'
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $expected) { throw 'SHA256 mismatch. Do not run the download.' }
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $folder 'App')
Write-Host ('Downloaded and verified. Open GlassDock.exe in: ' + (Join-Path $folder 'App'))
Invoke-Item (Join-Path $folder 'App')
