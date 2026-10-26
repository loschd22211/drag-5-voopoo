# Возвращает виджеты: включает обратно всё, что могло их отключить, и показывает,
# у каких приложений они вообще есть.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\widgets-fix.ps1
#   ... -Find      только посмотреть, ничего не включать
#
# Виджеты пропадают не «сами»: их отдают приложения-поставщики, а деблоат и
# массовое выключение гасят их вместе с приложением. Скрипт снимает suspend и
# включает все китайские пакеты, затем читает список виджетов из системы.
#
# Ничего не выключает и не удаляет. Файл в UTF-8 с BOM.

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Find
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.1"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

function Write-Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Write-Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Write-Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Stop-Script($t) { Write-Err $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

function Sh($cmd) {
  $line = '"' + $script:AdbBin + '" -s ' + $script:Serial + ' shell ' + $cmd + ' 2>&1'
  return (& cmd /c $line | Out-String).Trim()
}

function Connect-Adb {
  $bin = $Adb
  if (-not $bin) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if ($found) { $bin = $found.Source }
    else {
      $winget = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter 'adb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($winget) { $bin = $winget.FullName }
      else {
        $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
        if (Test-Path $cached) { $bin = $cached }
        else { Stop-Script "adb не найден. Поставь Platform-Tools (winget install Google.PlatformTools)" }
      }
    }
  }
  $script:AdbBin = $bin
  $devices = (& $bin devices 2>&1 | Out-String) -split "`r?`n" |
    Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
    ForEach-Object { ($_ -split '\s+')[0] }
  if (-not $devices) { Stop-Script "телефон не виден: кабель, «Отладка по USB», подтверждение на экране" }
  $script:Serial = if ($Serial) { $Serial } else { @($devices)[0] }
  Write-Ok "adb: $bin"
  Write-Ok "телефон: $($script:Serial)"
}

function Get-Packages($filter) {
  $raw = Sh ("pm list packages --user 0" + $filter)
  $names = @()
  foreach ($line in ($raw -split "`r?`n")) {
    $m = [regex]::Match($line, '^package:(.+)$')
    if ($m.Success) { $names += $m.Groups[1].Value.Trim() }
  }
  return $names
}

# Гейм-бар и игры не трогаем даже в откате.
$Keep = @(
  'com.oplus.games',
  'com.oplus.gamemode',
  'com.coloros.gamespaceui'
)

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

$installed = Get-Packages ''
$cn = @()
foreach ($p in $installed) {
  if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $cn += $p }
}

Write-Step "Что сейчас выключено"
$disabled = Get-Packages ' -d'
$cnOff = @()
foreach ($p in $disabled) {
  if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $cnOff += $p }
}
Write-Dim ("китайских выключенных: " + $cnOff.Count)

if (-not $Find) {
  Write-Step "Включаю всё обратно"
  $i = 0
  while ($i -lt $cn.Count) {
    $end = [Math]::Min($i + 25, $cn.Count - 1)
    $chunk = $cn[$i..$end]
    $sb = ""
    foreach ($p in $chunk) {
      if ($Keep -contains $p) { continue }
      $sb += "pm unsuspend --user 0 " + $p + "; pm enable --user 0 " + $p + "; "
    }
    if ($sb -ne "") { Sh $sb | Out-Null }
    $i = $end + 1
  }
  $after = Get-Packages ' -d'
  $left = 0
  foreach ($p in $after) {
    if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $left++ }
  }
  Write-Ok ("выключенных осталось: " + $left)
  Sh 'am force-stop com.android.launcher' | Out-Null
  Start-Sleep -Seconds 2
}

Write-Step "У каких приложений есть виджеты"
$dump = Sh 'dumpsys appwidget'
$providers = @()
foreach ($m in [regex]::Matches($dump, 'package=([A-Za-z0-9_.]+)')) {
  $n = $m.Groups[1].Value
  if ($providers -notcontains $n) { $providers += $n }
}
if ($providers.Count -eq 0) {
  foreach ($m in [regex]::Matches($dump, 'com\.[A-Za-z0-9_.]+\.(?:widget|Widget)[A-Za-z0-9_.]*')) {
    $n = $m.Value
    if ($providers -notcontains $n) { $providers += $n }
  }
}
if ($providers.Count -eq 0) {
  Write-Warn "система не отдала список виджетов"
  Write-Dim "проверь вручную: долгое нажатие на пустом месте стола → «Виджеты»"
} else {
  Write-Ok ("виджеты есть у " + $providers.Count + " приложений")
  foreach ($p in ($providers | Sort-Object | Select-Object -First 12)) { Write-Dim $p }
}

Write-Step "Приложение «Здоровье» и шаги"
$health = @()
foreach ($p in $installed) {
  if ($p -match '(health|sport|fitness|step)') { $health += $p }
}
if ($health.Count -eq 0) {
  Write-Warn "приложения про здоровье нет"
} else {
  foreach ($p in $health) {
    $act = Sh ("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER " + $p)
    if ($act -match 'No activity found') {
      Write-Dim ($p + ": без иконки (служба, а не приложение)")
    } else {
      Write-Dim ($p + ": открывается")
      $short = ($act -split "`r?`n") | Select-Object -Last 1
      Sh ("am start -n " + $short.Trim()) | Out-Null
    }
  }
}

Write-Host ""
Write-Dim "Если виджеты всё ещё пустые — перезагрузи телефон: список виджетов читается"
Write-Dim "лончером при старте, после включения пакетов он обновляется не всегда."
Write-Host ""
Read-Host "Enter — закрыть"
