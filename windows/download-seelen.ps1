# Windows PowerShell 5.1. Downloads only; never executes the installer.
param([string]$Destination = (Join-Path $env:USERPROFILE 'Downloads\Windows-Glass'))
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'drag-5-voopoo-windows-glass'; 'Accept' = 'application/vnd.github+json' }
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/eythaann/Seelen-UI/releases/latest' -Headers $headers
$assets = @($release.assets | Where-Object { $_.name -match '^Seelen\.UI_[0-9.]+_x64-setup\.exe$' })
if ($assets.Count -ne 1) { throw 'Expected exactly one official x64 installer. Open the GitHub releases page manually.' }
$asset = $assets[0]
$uri = [Uri]$asset.browser_download_url
if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.AbsolutePath.StartsWith('/eythaann/Seelen-UI/releases/download/')) {
  throw 'Unexpected download URL; stopped.'
}
Write-Host ('Version: {0}' -f $release.tag_name)
Write-Host ('Source: {0}' -f $uri.AbsoluteUri)
Write-Host ('Size: {0:N1} MB' -f ($asset.size / 1MB))
Write-Host ('Destination: {0}' -f $Destination)
if ((Read-Host 'Download only? Type YES to continue') -cne 'YES') { Write-Host 'Cancelled.'; exit 0 }
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$path = Join-Path $Destination $asset.name
if (Test-Path -LiteralPath $path) { throw 'File already exists. Move it or choose another Destination; no overwrite performed.' }
$partial = $path + '.partial'
if (Test-Path -LiteralPath $partial) { throw 'Partial download already exists; inspect it before retrying.' }
Invoke-WebRequest -UseBasicParsing -Uri $uri.AbsoluteUri -OutFile $partial
if ((Get-Item -LiteralPath $partial).Length -ne $asset.size) { throw 'Size mismatch. Partial file retained; do not execute it.' }
$hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
if ($asset.digest -and $asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
  if ($hash -ine $Matches[1]) { throw 'SHA256 mismatch. Partial file retained; do not execute it.' }
  Write-Host 'SHA256 matches the GitHub release digest.'
} else {
  Write-Warning 'Release has no SHA256 digest. Local hash is not independent proof of authenticity.'
}
Move-Item -LiteralPath $partial -Destination $path
$signature = Get-AuthenticodeSignature -LiteralPath $path
Write-Host ('Saved: {0}' -f $path)
Write-Host ('SHA256: {0}' -f $hash)
Write-Host ('Authenticode status: {0}' -f $signature.Status)
Write-Host 'Nothing installed or launched. Do not bypass SmartScreen or antivirus warnings.'
