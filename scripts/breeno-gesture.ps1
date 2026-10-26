# Пытается подменить «быстрый поиск Breeno» на Google/Gemini на долгом нажатии
# полосы жестов и честно показывает, вышло или нет.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-gesture.ps1
#   ... -Restore   вернуть Breeno как было
#   ... -Panel     только убрать левую китайскую панель (Breeno/assistant screen)
#
# Что делает:
#   1. возвращает Breeno-пакеты в работу (иначе жест мёртвый и ловить нечего)
#   2. снимает, какую активити ром запускает по жесту (журнал событий)
#   3. выдаёт Google роль системного ассистента (role ASSISTANT)
#   4. замеряет, что открывается после этого — окна, а не догадки
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Panel
)

$ScriptVersion = '2026-10-27.8'
$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$GooglePkg = 'com.google.android.googlequicksearchbox'
$BreenoPkgs = @('com.coloros.assistantscreen', 'com.heytap.speechassist')

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
      else { Stop-Script "adb не найден. Поставь Platform-Tools (winget install Google.PlatformTools)" }
    }
  }
  $script:AdbBin = $bin
  $devices = (& $bin devices 2>&1 | Out-String) -split "`r?`n" |
    Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
    ForEach-Object { ($_ -split '\s+')[0] }
  if (-not $devices) { Stop-Script "телефон не виден: кабель, «Отладка по USB», подтверждение на экране" }
  $script:Serial = if ($Serial) { $Serial } else { @($devices)[0] }
  Write-Dim ("версия скрипта: " + $ScriptVersion)
  Write-Ok "adb: $bin"
  Write-Ok "телефон: $($script:Serial)"
}

function Get-FocusLine {
  $win = Sh 'dumpsys window'
  $m = [regex]::Match($win, 'mCurrentFocus=Window\{[^}]*\}')
  if (-not $m.Success) { return '' }
  return ($m.Value -replace '\s+', ' ')
}

# Левая панель ColorOS (Breeno/assistant screen) включается теми же ключами,
# которыми мы возвращали Breeno. Поэтому в конце прогона её надо снять обратно.
function Remove-LeftPanel {
  Sh 'pm suspend --user 0 com.coloros.assistantscreen' | Out-Null
  Sh 'settings put secure key_com_coloros_assistantscreen 0' | Out-Null
  Sh 'settings put secure remote_view_entry_com.coloros.assistantscreen 0' | Out-Null
  Sh 'settings put secure assistant_screen_type 0' | Out-Null
  Sh 'settings put secure asistant_screen_type 0' | Out-Null
  Write-Ok "левая китайская панель снята"
}

function Enable-Breeno {
  foreach ($p in $BreenoPkgs) {
    Sh ("cmd package install-existing --user 0 " + $p) | Out-Null
    Sh ("pm unsuspend --user 0 " + $p) | Out-Null
    Sh ("pm enable --user 0 " + $p) | Out-Null
  }
  Sh 'settings put secure key_com_coloros_assistantscreen 1' | Out-Null
  Sh 'settings put secure remote_view_entry_com.coloros.assistantscreen 1' | Out-Null
}

function Watch-Press {
  param([int]$Seconds = 12)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $seen = @()
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    Start-Sleep -Milliseconds 600
    $f = Get-FocusLine
    if ($f -and $seen -notcontains $f) {
      $seen += $f
      if ($f -notmatch 'launcher') { Write-Dim ("   {0} с: {1}" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $f) }
      if ($f -match 'ActionsDialog') { Write-Dim "   это меню выключения: нажата кнопка питания, а не полоса жестов" }
    }
  }
  return $seen
}

function Test-PressForAssistant {
  param([string]$Hint)
  Sh 'input keyevent 3' | Out-Null
  Start-Sleep -Milliseconds 400
  Write-Dim $Hint
  $seen = Watch-Press -Seconds 10
  $gem = @($seen | Where-Object { $_ -match 'googlequicksearchbox|apps\.bard' }).Count -gt 0
  return [pscustomobject]@{ Gemini = $gem; Seen = $seen }
}

# ---------------------------------------------------------------- main

Connect-Adb

Write-Step "Кто сейчас держит роль ассистента"
$role = Sh 'cmd role get-role-holders android.app.role.ASSISTANT'
if (-not $role) { Write-Dim "роль никому не выдана" } else { foreach ($l in ($role -split "`n")) { Write-Dim $l.Trim() } }

if ($Panel) {
  Write-Step "Убираю левую китайскую панель"
  Remove-LeftPanel
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

if ($Restore) {
  Write-Step "Возвращаю Breeno"
  Enable-Breeno
  Write-Ok "Breeno-пакеты включены, ключи assistantscreen вернул в 1"
  Write-Dim "Google при этом остаётся назначенным помощником (secure assistant)"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Возвращаю Breeno в работу, чтобы жест вообще срабатывал"
Enable-Breeno
Write-Ok "готово"

Write-Step "Ловлю, что ром запускает по жесту"
Sh 'logcat -c' | Out-Null
Write-Dim "зажми ПОЛОСУ ЖЕСТОВ внизу экрана (не кнопку питания) и держи 1-2 секунды"
$cmpPkg = ''
$seenBefore = Watch-Press -Seconds 12
$log = Sh 'logcat -d -t 400'
$hits = @()
foreach ($l in ($log -split "`n")) {
  if ($l -match 'START u0|act=android.intent.action.ASSIST|android.intent.action.VOICE_ASSIST') { $hits += ($l -replace '\s+', ' ').Trim() }
}
if ($hits.Count -eq 0) {
  Write-Warn "в журнале ничего: либо жест ничего не запускает, либо лог не пишется"
} else {
  foreach ($h in ($hits | Select-Object -Last 5)) { Write-Dim $h }
  $cmp = [regex]::Match(($hits -join ' '), 'cmp=([A-Za-z0-9_.]+)/([A-Za-z0-9_.$]+)')
  if ($cmp.Success) { Write-Dim ("компонент: " + $cmp.Groups[1].Value + "/" + $cmp.Groups[2].Value) }
}
# окно тоже говорит, кто открылся — берём пакет из фокуса, если журнал молчит
foreach ($f in $seenBefore) {
  $mPkg = [regex]::Match($f, 'u0 ([A-Za-z0-9_.]+)/')
  if ($mPkg.Success -and $mPkg.Groups[1].Value -ne 'com.android.launcher') { $cmpPkg = $mPkg.Groups[1].Value }
}
if ($cmpPkg -eq '') { $cmpPkg = 'com.heytap.speechassist' }
if ($cmpPkg -ne '') { Write-Dim ("держит жест: " + $cmpPkg) }

Write-Step "Выдаю Google роль системного ассистента"
$r = Sh ("cmd role add-role-holder --user 0 android.app.role.ASSISTANT " + $GooglePkg)
Write-Dim ($r -replace '\s+', ' ')
$after = Sh 'cmd role get-role-holders android.app.role.ASSISTANT'
if ($after -match [regex]::Escape($GooglePkg)) { Write-Ok "роль ASSISTANT у Google" }
else { Write-Warn "роль Google не досталась (ром может запрещать смену роли)" }

Write-Step "Проверка: зажми полосу ещё раз"
$seenAfter = Watch-Press -Seconds 12
$gotGemini = @($seenAfter | Where-Object { $_ -match 'googlequicksearchbox|apps\.bard' }).Count -gt 0
if ($gotGemini) {
  Write-Ok "Работает: по жесту открывается Google"
} else {
  Write-Warn "Google по жесту не открылся"
  if ($seenAfter.Count -gt 0) { Write-Dim ("в фокусе было: " + ($seenAfter -join ' | ')) }
  Write-Dim "Скорее всего обработчик жеста зашит в SystemUI рома и роль ему не указ"
  Write-Dim "Вернуть Breeno как было: эта же команда с ключом -Restore"
}

Write-Step "Гашу пакет, который держит жест"
# Из замера видно, кто открывается по жесту. Если погасить этот пакет, у SystemUI
# остаётся два варианта: ничего не делать или упасть на роль ASSISTANT (Google).
$pkg = 'com.heytap.speechassist'
if ($cmpPkg -ne '') { $pkg = $cmpPkg }
Write-Dim ("пакет: " + $pkg)

$found = ''
Sh ("pm disable-user --user 0 " + $pkg) | Out-Null
$r1 = Test-PressForAssistant -Hint "зажми полосу (пакет отключён)"
if ($r1.Gemini) { $found = 'отключён' }

if (-not $found) {
  Sh ("pm uninstall --user 0 " + $pkg) | Out-Null
  $r2 = Test-PressForAssistant -Hint "зажми полосу (пакет снят для пользователя)"
  if ($r2.Gemini) { $found = 'снят' }
}

Write-Host ""
if ($found -ne '') {
  Write-Ok ("Работает: жест открывает Google, пакет " + $found)
  Write-Dim ("вернуть Breeno: cmd package install-existing --user 0 " + $pkg)
} else {
  Write-Warn "Даже без этого пакета Google по жесту не открывается"
  Write-Dim "Значит SystemUI рома просто проглатывает жест, на роль ASSISTANT он не падает"
  Write-Dim ("пакет оставил отключённым, чтобы не видеть «страница недоступна»; вернуть: cmd package install-existing --user 0 " + $pkg)
}

Write-Host ""
Remove-LeftPanel

Write-Host ""
Read-Host "Enter — закрыть"
