# Возвращает счётчик шагов: включает приложение «Здоровье» (OHealth) обратно.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\steps-widget.ps1
#
# Счётчик шагов на ColorOS живёт в com.heytap.health / com.oplus.healthservice.
# Скрипт деблоата выключал com.heytap.health — из-за этого виджет и пропал.
# Здесь всё возвращается, проверяется датчик шагов и открывается приложение,
# из которого виджет ставится на рабочий стол.
#
# Ничего не выключает. Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = ""
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

function Get-State($pkg) {
  $out = Sh ("pm list packages -d --user 0 " + $pkg)
  if ($out -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'отключён' }
  $dump = Sh ("dumpsys package " + $pkg)
  if ($dump -match 'suspended=true') { return 'приостановлен' }
  $out2 = Sh ("pm list packages --user 0 " + $pkg)
  if ($out2 -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'включён' }
  return 'нет'
}

# Кто отвечает за шаги на этой прошивке.
$HealthPkgs = @(
  'com.heytap.health',
  'com.oplus.healthservice',
  'com.heytap.sport',
  'com.oplus.sport'
)

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

Write-Step "Кто отвечает за шаги"
$found = @()
foreach ($p in $HealthPkgs) {
  $st = Get-State $p
  if ($st -eq 'нет') { continue }
  Write-Dim ($p + ": " + $st)
  $found += $p
}
if ($found.Count -eq 0) {
  Write-Warn "приложения «Здоровье» в системе нет"
  Write-Dim "тогда шаги показывает только виджет Google Fit / стороннее приложение из Play"
}

Write-Step "Включаю обратно"
$n = 0
foreach ($p in $found) {
  Sh ("pm unsuspend --user 0 " + $p) | Out-Null
  Sh ("pm enable --user 0 " + $p) | Out-Null
  if ((Get-State $p) -eq 'включён') { Write-Ok ("включён: " + $p); $n++ }
  elseif ((Get-State $p) -eq 'приостановлен') { Write-Warn ("не поддался: " + $p) }
}
if ($n -eq 0 -and $found.Count -gt 0) { Write-Dim "всё уже было включено" }

Write-Step "Датчик шагов на телефоне"
$sensors = Sh 'dumpsys sensorservice'
$stepSensors = @(($sensors -split "`r?`n") | Where-Object { $_ -match '(?i)step' } | Select-Object -First 4)
if ($stepSensors.Count -eq 0) {
  Write-Warn "в списке датчиков нет шагомера — тогда считает только телефон в кармане через своё ПО"
} else {
  foreach ($l in $stepSensors) { Write-Dim ($l.Trim()) }
}

Write-Step "Открываю приложение"
$launched = ''
foreach ($p in $found) {
  $r = Sh ("monkey -p " + $p + " -c android.intent.category.LAUNCHER 1")
  if ($r -notmatch 'No activities found') { $launched = $p; break }
}
if ($launched -ne '') { Write-Ok ("открыл: " + $launched) } else { Write-Warn "открыть не удалось — зайди в «Здоровье» вручную" }

Write-Host ""
Write-Dim "Дальше на телефоне:"
Write-Dim "1) долгое нажатие на пустом месте рабочего стола → «Виджеты»;"
Write-Dim "2) найди «Здоровье» / OHealth → виджет «Шаги» → перетащи на стол;"
Write-Dim "3) если нужен счётчик на экране блокировки: Настройки → Экран блокировки →"
Write-Dim "   «Показывать шаги» (в CN-сборке пункт может называться 锁屏计步)."
Write-Host ""
Read-Host "Enter — закрыть"
