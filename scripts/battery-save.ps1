# Экономия батареи: убираем 120 Гц в пользу 60 Гц (по явной просьбе пользователя) — и всё.
# Плюс необязательные тумблеры: таймаут экрана и low_power.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\battery-save.ps1
#   ... -Apply                       применить (снимок текущих значений в %TEMP%)
#   ... -Apply -ScreenTimeoutMs 30000  заодно таймаут экрана 30 с (опционально)
#   ... -Apply -BatterySaver           заодно включить режим энергосбережения (low_power) — опционально
#   ... -Restore                       вернуть ровно то, что было до -Apply (по снимку)
#
# Без ключей скрипт ТОЛЬКО ЧИТАЕТ: частоту экрана, таймаут, low_power. Ничего не меняет.
#
# ЧЕГО СКРИПТ НЕ ДЕЛАЕТ (принципиально):
#   * НЕ трогает яркость, автояркость, ночной режим, защиту глаз, анимации;
#   * НЕ трогает приложения, пакеты, Doze, его белый список — только два-три ключа settings;
#   * НЕ трогает тач-чувствительность / режим перчаток (oplus_glove_mode);
#   * AOD, «поднять для включения экрана», значок отпечатка на выключенном экране —
#     только подсказка, куда нажать руками: ключей этих тумблеров на ColorOS 17 мы не
#     знаем, а гадать нельзя.
#
# Обратимость: -Apply пишет снимок в %TEMP%\drag5-battery-save-backup.json один раз
# (исходную базу НЕ перезаписывает), -Restore возвращает из него.
#
# Прошивка ColorOS 17 (V17.0.0): частота читается в namespace `secure`
# (peak_refresh_rate / min_refresh_rate — battery-doctor читает их оттуда на этом
# телефоне). Если после -Apply значение «не прижилось» — ключ на этой сборке может
# игнорироваться; тогда: Настройки → Экран → Частота обновления → 60 Гц руками.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Apply,
  [switch]$Restore,
  [switch]$BatterySaver,
  [int]$ScreenTimeoutMs = 0
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-11-13.1"
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

$BackupFile = Join-Path $env:TEMP 'drag5-battery-save-backup.json'

function Read-State {
  $peak = (Sh 'settings get secure peak_refresh_rate').Trim()
  $min  = (Sh 'settings get secure min_refresh_rate').Trim()
  $timeout = (Sh 'settings get system screen_off_timeout').Trim()
  $low  = (Sh 'settings get global low_power').Trim()
  return @{
    'secure.peak_refresh_rate'  = $peak
    'secure.min_refresh_rate'   = $min
    'system.screen_off_timeout' = $timeout
    'global.low_power'          = $low
  }
}

function Write-StateTable($state, $title) {
  Write-Step $title
  foreach ($k in @('secure.peak_refresh_rate','secure.min_refresh_rate','system.screen_off_timeout','global.low_power')) {
    Write-Dim ("  {0} = {1}" -f $k, $state[$k])
  }
}

function Save-BackupIfNeeded($state) {
  if (Test-Path $BackupFile) {
    Write-Dim ("снимок уже есть, не перезаписываю (это исходная база): " + $BackupFile)
    return
  }
  $state | ConvertTo-Json | Set-Content -Path $BackupFile -Encoding UTF8
  Write-Ok ("снимок сохранён: " + $BackupFile)
}

function Restore-Backup {
  if (-not (Test-Path $BackupFile)) { Stop-Script "снимок не найден: $BackupFile — откатывать не от чего" }
  $snap = Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Step "Откат по снимку ($BackupFile)"
  $map = @{
    'secure.peak_refresh_rate'  = 'settings put secure peak_refresh_rate'
    'secure.min_refresh_rate'   = 'settings put secure min_refresh_rate'
    'system.screen_off_timeout' = 'settings put system screen_off_timeout'
    'global.low_power'          = 'settings put global low_power'
  }
  foreach ($k in @('secure.peak_refresh_rate','secure.min_refresh_rate','system.screen_off_timeout','global.low_power')) {
    $v = [string]$snap.$k
    if ([string]::IsNullOrWhiteSpace($v) -or $v -match '(?i)^(null|exception)') {
      Write-Warn ("  {0}: в снимке нечего восстанавливать, пропускаю" -f $k)
      continue
    }
    Sh ($map[$k] + ' ' + $v) | Out-Null
    Write-Ok ("  {0} -> {1}" -f $k, $v)
  }
  Write-Dim "снимок НЕ удаляю — при желании можно применить/откатить повторно"
}

function Apply-Settings($state) {
  Save-BackupIfNeeded $state

  Write-Step "Частота обновления: 120 Гц -> 60 Гц"
  Sh 'settings put secure peak_refresh_rate 60' | Out-Null
  Sh 'settings put secure min_refresh_rate 60'  | Out-Null
  $peak = (Sh 'settings get secure peak_refresh_rate').Trim()
  $min  = (Sh 'settings get secure min_refresh_rate').Trim()
  if ($peak -eq '60') { Write-Ok "peak_refresh_rate = 60" } else {
    Write-Warn ("peak_refresh_rate читается как «{0}», а не 60" -f $peak)
    Write-Dim "на этой сборке ключ может игнорироваться — тогда руками:"
    Write-Dim "Настройки → Экран → Частота обновления → 60 Гц («Стандартная»)"
  }
  if ($min -eq '60') { Write-Ok "min_refresh_rate = 60" } else { Write-Warn ("min_refresh_rate читается как «{0}»" -f $min) }

  if ($ScreenTimeoutMs -gt 0) {
    if ($ScreenTimeoutMs -lt 5000 -or $ScreenTimeoutMs -gt 600000) {
      Stop-Script "ScreenTimeoutMs должен быть от 5000 до 600000 миллисекунд (5–600 с)"
    }
    Write-Step ("Таймаут экрана -> {0} мс" -f $ScreenTimeoutMs)
    Sh ('settings put system screen_off_timeout ' + $ScreenTimeoutMs) | Out-Null
    $t = (Sh 'settings get system screen_off_timeout').Trim()
    if ($t -eq [string]$ScreenTimeoutMs) { Write-Ok ("screen_off_timeout = " + $t) } else { Write-Warn ("screen_off_timeout читается как «{0}»" -f $t) }
  }

  if ($BatterySaver) {
    Write-Step "Режим энергосбережения (low_power)"
    Sh 'settings put global low_power 1' | Out-Null
    $lp = (Sh 'settings get global low_power').Trim()
    if ($lp -eq '1') { Write-Ok "low_power = 1" } else {
      Write-Warn ("low_power читается как «{0}» — на ColorOS ключ может не прижиться," -f $lp)
      Write-Dim "тогда включи в шторке «Энергосбережение» вручную"
    }
  }
}

function Write-ManualChecklist {
  Write-Host ""
  Write-Host "Что скрипт сознательно НЕ трогает — и что стоит сделать руками:" -ForegroundColor Cyan
  Write-Dim "  1. Яркость: не трогаю (ты выбираешь сам). Помни: экран = ~96% твоего расхода"
  Write-Dim "     (по battery-doctor: screen-on discharge 179 mAh против 8 mAh у всего остального)."
  Write-Dim "  2. «Поднять для включения экрана» (экран срабатывает впустую при поднятии):"
  Write-Dim "     Настройки → поиск «подняти» → выключи «Поднять для включения экрана»"
  Write-Dim "     (там же может быть «Двойное нажатие для включения экрана»)."
  Write-Dim "  3. Значок отпечатка на выключенном экране (кусочек матрицы светит постоянно):"
  Write-Dim "     выключи — разблокировка отпечатком сработает и без иконки."
  Write-Dim "  4. AOD: судя по «вспыхнул на 2–3 с и погас», у тебя короткий режим — тратит мало."
  Write-Dim "     Если нужен полный ноль: Настройки → Экран → Always on Display → выключить."
  Write-Dim "  5. Местоположение → Сканирование → «Сканирование Wi-Fi» и «Сканирование Bluetooth»:"
  Write-Dim "     эти два работают даже при ВЫКЛЮЧЕННЫХ модулях — выключи."
  Write-Dim "  6. На ночь ноль расхода: Настройки → Дополнительные настройки →"
  Write-Dim "     «Автовключение/выключение»; время включения поставь заранее до будильника."
  Write-Dim "  7. Жор по приложениям: Настройки → Аккумулятор → Расход заряда —"
  Write-Dim "     любое приложение с большим фоном удаляй/ограничивай фон прямо оттуда."
  Write-Host ""
  Write-Host "Откат: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\battery-save.ps1 -Restore"
}

# --------------------------------------------------------------------------

Write-Host ("battery-save.ps1 v" + $ScriptVersion) -ForegroundColor Cyan
Connect-Adb
$state = Read-State
Write-StateTable $state "Сейчас"

if ($Restore) {
  Restore-Backup
} elseif ($Apply) {
  Apply-Settings $state
  Write-StateTable (Read-State) "Стало"
} else {
  Write-Step "Это сухой прогон — ничего не пишу"
  Write-Dim "  применить 60 Гц:        ... -Apply"
  Write-Dim "  заодно таймаут 30 с:    ... -Apply -ScreenTimeoutMs 30000"
  Write-Dim "  заодно энергосбережение: ... -Apply -BatterySaver"
  Write-Dim "  вернуть как было:       ... -Restore"
}
Write-ManualChecklist
