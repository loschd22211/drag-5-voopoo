# Убирает «надзирателя за установкой» на ColorOS: магазин HeyTap и сканер APK.
# После этого сторонние APK ставятся сразу, без «проверки» и без блокировок.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\debloat-market.ps1
#   ... -Restore        вернуть магазин, сканер и проверку пакетов
#   ... -KeepVerifier   не трогать настройки проверки APK (только магазин/сканер)
#
# Что именно отключается:
#   com.heytap.market     магазин HeyTap (App Market)
#   com.oplus.appdetail   сканер устанавливаемых приложений (он и «думает» минутами)
#   settings global       verifier_verify_adb_installs / package_verifier_enable
#
# Всё обратимо, root не нужен. Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$KeepVerifier
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

# ВАЖНО: имена функций не должны совпадать с алиасами PowerShell.
# `Kill` — алиас Stop-Process, из-за него был сбой «не удается привязать InputObject».
$Targets = @(
  @{ Package = 'com.heytap.market';   Label = 'магазин HeyTap' },
  @{ Package = 'com.oppo.market';     Label = 'магазин OPPO' },
  @{ Package = 'com.oplus.appmarket'; Label = 'магазин OPPO (oplus)' },
  @{ Package = 'com.oplus.appdetail'; Label = 'сканер устанавливаемых APK' }
)

function Write-Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Write-Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Write-Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Stop-Script($t) { Write-Err $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

function Invoke-Sh([string]$Command) {
  (& $script:AdbBin '-s' $script:Serial 'shell' $Command 2>&1 | Out-String).Trim()
}

function Connect-Adb {
  $bin = $Adb
  if (-not $bin) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if ($found) { $bin = $found.Source }
    else {
      $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
      if (Test-Path $cached) { $bin = $cached }
      else { Stop-Script "adb не найден. Сначала запусти scripts\oneclick.ps1 — он его скачает." }
    }
  }
  $script:AdbBin = $bin
  Write-Ok "adb: $bin"

  $devices = (& $bin devices 2>&1 | Out-String) -split "`r?`n" |
    Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
    ForEach-Object { ($_ -split '\s+')[0] }
  if (-not $devices) { Stop-Script "телефон не виден: кабель, «Отладка по USB», подтверждение на экране" }
  $script:Serial = if ($Serial) { $Serial } else { @($devices)[0] }
  Write-Ok "телефон: $($script:Serial)"
}

function Test-Blocked([string]$Pkg) {
  $disabled = Invoke-Sh 'pm list packages -d'
  if ($disabled -match ("package:" + [regex]::Escape($Pkg) + "(\r?\n|$)")) { return $true }
  $installed = Invoke-Sh 'pm list packages --user 0'
  if (-not ($installed -match ("package:" + [regex]::Escape($Pkg) + "(\r?\n|$)"))) { return $true }
  $dump = Invoke-Sh "dumpsys package $Pkg"
  if ($dump -match 'suspended=true' -or $dump -match 'hidden=true') { return $true }
  return $false
}

# disable-user -> suspend -> uninstall -k --user 0; для каждого шага проверяем состояние
function Block-App([string]$Pkg) {
  foreach ($mode in @('disable-user', 'suspend', 'uninstall-user')) {
    switch ($mode) {
      'disable-user'   { $out = Invoke-Sh "pm disable-user --user 0 $Pkg" }
      'suspend'        { $out = Invoke-Sh "pm suspend --user 0 $Pkg" }
      'uninstall-user' { $out = Invoke-Sh "pm uninstall -k --user 0 $Pkg" }
    }
    if (Test-Blocked $Pkg) {
      Write-Ok "$Pkg заблокирован (способ: $mode)"
      return $true
    }
    Write-Dim ("{0}: {1}" -f $mode, (($out -split "`r?`n")[0]))
  }
  Write-Warn "$Pkg не поддался: disable-user, suspend и uninstall отказали"
  return $false
}

function Unblock-App([string]$Pkg) {
  Invoke-Sh "pm unsuspend --user 0 $Pkg" | Out-Null
  Invoke-Sh "pm unhide $Pkg" | Out-Null
  Invoke-Sh "pm enable $Pkg" | Out-Null
  Invoke-Sh "cmd package install-existing $Pkg" | Out-Null
  return -not (Test-Blocked $Pkg)
}

# ------------------------------------------------------------------ main

Connect-Adb

if ($Restore) {
  Write-Step "Возвращаю магазин и сканер"
  foreach ($t in $Targets) {
    $installed = Invoke-Sh 'pm list packages --user 0'
    if (-not ($installed -match ("package:" + [regex]::Escape($t.Package) + "(\r?\n|$)"))) {
      Write-Dim "$($t.Package): на этой сборке нет — пропускаю"
      continue
    }
    if (Unblock-App $t.Package) { Write-Ok "$($t.Package) включён" }
    else { Write-Warn "$($t.Package) не удалось вернуть вручную: pm enable $($t.Package)" }
  }
  Invoke-Sh 'settings put global verifier_verify_adb_installs 1' | Out-Null
  Invoke-Sh 'settings put global package_verifier_enable 1' | Out-Null
  Write-Ok "проверка пакетов включена обратно"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

if (-not $KeepVerifier) {
  Write-Step "Выключаю проверку APK"
  Invoke-Sh 'settings put global verifier_verify_adb_installs 0' | Out-Null
  Invoke-Sh 'settings put global package_verifier_enable 0' | Out-Null
  Invoke-Sh 'settings put global package_verifier_user_consent -1' | Out-Null
  Invoke-Sh 'settings put global install_non_market_apps 1' | Out-Null
  $check = Invoke-Sh 'settings get global verifier_verify_adb_installs'
  Write-Ok "verifier_verify_adb_installs = $check"
}

Write-Step "Отключаю магазин и сканер установок"
$installedAll = Invoke-Sh 'pm list packages --user 0'
$failed = @()
foreach ($t in $Targets) {
  if (-not ($installedAll -match ("package:" + [regex]::Escape($t.Package) + "(\r?\n|$)"))) {
    Write-Dim "$($t.Package) ($($t.Label)) — на этой сборке нет"
    continue
  }
  Write-Dim "$($t.Package) — $($t.Label)"
  if (-not (Block-App $t.Package)) { $failed += $t.Package }
}

Write-Step "Проверка"
$marketHere = $installedAll -match 'package:com\.heytap\.market(\r?\n|$)'
if ($marketHere) {
  if (Test-Blocked 'com.heytap.market') { Write-Ok "магазин HeyTap заблокирован" }
  else { Write-Warn "магазин HeyTap всё ещё активен" }
}
if ($failed.Count -eq 0) { Write-Ok "готово: установка сторонних APK больше не режется" }
else { Write-Warn "не поддались: $($failed -join ', ')" }

Write-Host ""
Write-Dim "Вернуть как было:  -Restore"
Write-Dim "Проверка:  adb shell settings get global verifier_verify_adb_installs   # должно быть 0"
Write-Host ""
Read-Host "Enter — закрыть"
