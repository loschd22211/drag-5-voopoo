# Почему плеер не появляется на экране блокировки — и как это включить.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\lockscreen-player.ps1
#
# Что делает:
#   1. находит adb и телефон
#   2. включает карточку плеера на локскрине (media_controls_lock_screen,
#      lockscreen_show_controls) — на ColorOS 16 они выключены по умолчанию
#   3. смотрит активные медиасессии: какое приложение реально играет и умеет ли оно
#      отдавать плеер системе (MediaSession)
#   4. находит уведомление этого приложения и печатает важность канала: при
#      важности ниже DEFAULT ColorOS не выносит плеер на экран блокировки
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = ""
)

$ErrorActionPreference = "Continue"
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

# Медиасессии: package + состояние воспроизведения (3 = играет)
function Get-MediaSessions {
  $raw = Sh 'dumpsys media_session'
  $sessions = @()
  $pkg = ''
  $state = -1
  foreach ($line in ($raw -split "`n")) {
    $mPkg = [regex]::Match($line, 'package=([A-Za-z0-9_.]+)')
    if ($mPkg.Success) {
      if ($pkg -ne '' -and $state -ge 0) { $sessions += [pscustomobject]@{ Pkg = $pkg; State = $state } }
      $pkg = $mPkg.Groups[1].Value
      $state = -1
    }
    $mSt = [regex]::Match($line, 'state=PlaybackState \{state=(\d+)')
    if ($mSt.Success) { $state = [int]$mSt.Groups[1].Value }
  }
  if ($pkg -ne '') { $sessions += [pscustomobject]@{ Pkg = $pkg; State = $state } }
  return $sessions
}

# Уведомление приложения: канал и его важность
function Get-NotificationInfo {
  param([string]$Package)
  $raw = Sh 'dumpsys notification --noredact'
  foreach ($line in ($raw -split "`n")) {
    if ($line -notmatch 'NotificationRecord' -or $line -notmatch [regex]::Escape('pkg=' + $Package)) { continue }
    $mImp = [regex]::Match($line, 'importance=(\d+)')
    $mCh = [regex]::Match($line, 'channel=([^ ,\)]+)')
    if ($mImp.Success) {
      return [pscustomobject]@{
        Importance = [int]$mImp.Groups[1].Value
        Channel    = $(if ($mCh.Success) { $mCh.Groups[1].Value } else { '?' })
      }
    }
  }
  return $null
}

# ---------------------------------------------------------------- main

Connect-Adb

Write-Step "Ключи экрана блокировки"
$before = Sh 'settings get secure media_controls_lock_screen'
Sh 'settings put secure media_controls_lock_screen 1' | Out-Null
Sh 'settings put secure lockscreen_show_controls 1' | Out-Null
$after = Sh 'settings get secure media_controls_lock_screen'
$controls = Sh 'settings get secure lockscreen_show_controls'
if ($after -match '1') { Write-Ok "media_controls_lock_screen = 1 (было: $before)" }
else { Write-Warn "media_controls_lock_screen = $after — не принято ромом" }
Write-Dim "lockscreen_show_controls = $controls"

Write-Step "Активные медиасессии"
$sessions = @(Get-MediaSessions)
if ($sessions.Count -eq 0) {
  Write-Warn "ни одной медиасессии: включи трек и запусти скрипт снова"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}
$playing = @()
foreach ($s in $sessions) {
  $label = 'пауза'
  if ($s.State -eq 3) { $label = 'играет' } elseif ($s.State -eq 2) { $label = 'буферизует' } elseif ($s.State -eq 1) { $label = 'остановлено' }
  Write-Dim ("{0}: {1} (state={2})" -f $s.Pkg, $label, $s.State)
  if ($s.State -eq 3 -or $s.State -eq 2) { $playing += $s.Pkg }
}

if ($playing.Count -eq 0) {
  Write-Warn "сейчас ничего не играет — включи трек и запусти снова"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Уведомление и важность канала"
$needFix = @()
$unknown = @()
foreach ($pkg in $playing) {
  $info = Get-NotificationInfo -Package $pkg
  if (-not $info) {
    Write-Warn ("{0}: уведомления с плеером нет — приложение не публикует его во время игры" -f $pkg)
    $unknown += $pkg
    continue
  }
  $level = 'LOW'
  if ($info.Importance -ge 4) { $level = 'HIGH' }
  elseif ($info.Importance -eq 3) { $level = 'DEFAULT' }
  elseif ($info.Importance -eq 2) { $level = 'LOW' }
  elseif ($info.Importance -le 1) { $level = 'MIN/NONE' }
  if ($info.Importance -ge 3) {
    Write-Ok ("{0}: канал {1}, важность {2} ({3}) — плееру есть что показать" -f $pkg, $info.Channel, $info.Importance, $level)
  } else {
    Write-Warn ("{0}: канал {1}, важность {2} ({3}) — ColorOS такие на локскрин не выносит" -f $pkg, $info.Channel, $info.Importance, $level)
    $needFix += [pscustomobject]@{ Pkg = $pkg; Channel = $info.Channel; Importance = $info.Importance }
  }
}

Write-Host ""
if ($needFix.Count -gt 0) {
  foreach ($f in $needFix) {
    Write-Dim ("Подними важность: Настройки -> Уведомления -> {0} -> канал «{1}» -> важность «Высокая»" -f $f.Pkg, $f.Channel)
  }
  Write-Dim "Это единственное, что нельзя сделать из adb: каналы уведомлений меняет только само приложение или ты руками"
} elseif ($unknown.Count -gt 0) {
  Write-Dim "Приложение играет, но не отдаёт уведомление — системный плеер на локскрине ему недоступен"
  Write-Dim "Это ограничение приложения, не настройка телефона"
} else {
  Write-Ok "Все настройки на месте: ключи включены, важность канала достаточная"
  Write-Dim "Если карточки всё равно нет — ColorOS показывает только свой плеер, а сторонние не выносит"
}

Write-Host ""
Write-Dim "Проверка: включи трек, нажми питание (экран гаснет), посмотри на экран блокировки"
Write-Host ""
Read-Host "Enter — закрыть"
