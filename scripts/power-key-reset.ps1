# Возвращает кнопку питания в заводское состояние и убирает ColorGoogle.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\power-key-reset.ps1
#   ... -KeepAssistant   не трогать assistant / voice_interaction_service
#
# Что делает:
#   1. останавливает shell-агент ColorGoogle (если он ещё жив)
#   2. удаляет приложение ColorGoogle, перебирая способы (pm uninstall падает
#      на ColorOS с DELETE_FAILED_INTERNAL_ERROR — это не значит, что пакет удалён)
#   3. возвращает Breeno на долгое нажатие питания
#   4. выключает AOSP-жест «удержание питания открывает помощника»
#   5. возвращает assistant / voice_interaction_service из .\colorgoogle-backup
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$KeepAssistant
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$Pkg = 'dev.evoker.homeholdcts'
$BackupDir = Join-Path (Get-Location) 'colorgoogle-backup'

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
      $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
      if (Test-Path $cached) { $bin = $cached }
      else { Stop-Script "adb не найден. Запусти scripts\oneclick.ps1 или укажи -Adb" }
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

function Test-Installed {
  $list = Sh 'pm list packages --user 0'
  return ($list -match ("package:" + [regex]::Escape($Pkg) + "(\r?\n|$)"))
}

# ---------------------------------------------------------------- main

Connect-Adb

Write-Step "Останавливаю агент ColorGoogle"
$stop = Sh "content call --uri content://$Pkg.desktopsearch --method stop"
if ($stop -match 'stopped=true') { Write-Ok "агент остановлен" }
else { Write-Dim "агента нет или он уже остановлен" }

Write-Step "Удаляю ColorGoogle"
if (-not (Test-Installed)) {
  Write-Ok "$Pkg уже не установлен"
} else {
  $removed = $false
  $attempts = @(
    "pm uninstall $Pkg",
    "pm uninstall --user 0 $Pkg",
    "pm uninstall -k --user 0 $Pkg",
    "cmd package uninstall $Pkg"
  )
  foreach ($cmd in $attempts) {
    $out = Sh $cmd
    if (-not (Test-Installed)) { Write-Ok "удалён (способ: $cmd)"; $removed = $true; break }
    $first = ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
    Write-Dim ("{0}: {1}" -f $cmd, $first)
  }
  if (-not $removed) {
    # ColorOS умеет не отдавать удаление; заморозка работает всегда
    Sh "pm suspend --user 0 $Pkg" | Out-Null
    $dump = Sh "dumpsys package $Pkg"
    if ($dump -match 'suspended=true') {
      Write-Warn "удалить не дал, но приложение заморожено (suspended=true)"
    } else {
      Write-Err "пакет остался активным — удали его вручную: Настройки -> Приложения -> ColorGoogle -> Удалить"
    }
  }
}

if (-not $KeepAssistant) {
  Write-Step "Возвращаю помощника из бэкапа"
  foreach ($pair in @(
      @{ F = 'assistant.txt'; K = 'assistant' },
      @{ F = 'voice-service.txt'; K = 'voice_interaction_service' }
    )) {
    $file = Join-Path $BackupDir $pair.F
    if (-not (Test-Path $file -PathType Leaf)) {
      Write-Dim "$($pair.K): бэкапа нет, значение не меняю"
      continue
    }
    $value = (Get-Content $file -Raw).Trim()
    if (-not $value -or $value -eq 'null') {
      Sh "settings --user 0 delete secure $($pair.K)" | Out-Null
      Write-Ok "$($pair.K): удалён (как было до настройки)"
    } else {
      Sh "settings --user 0 put secure $($pair.K) $value" | Out-Null
      Write-Ok "$($pair.K) = $value"
    }
  }
}

Write-Step "Возвращаю кнопку питания"
Sh 'settings put secure speech_assist_power_wakeup 1' | Out-Null
Sh 'settings put secure assist_gesture_enabled 0' | Out-Null
Sh 'settings put secure assist_gesture_wake_enabled 0' | Out-Null

$powerWake = Sh 'settings get secure speech_assist_power_wakeup'
$gesture = Sh 'settings get secure assist_gesture_enabled'
$assistant = Sh 'settings get secure assistant'
Write-Dim "speech_assist_power_wakeup: $powerWake   (1 = кнопку снова обрабатывает Breeno)"
Write-Dim "assist_gesture_enabled: $gesture"
Write-Dim "assistant: $assistant"

Write-Host ""
Write-Ok "готово"
Write-Dim "Если кнопка всё ещё ведёт себя странно — перезагрузи телефон."
Write-Host ""
Read-Host "Enter — закрыть"
