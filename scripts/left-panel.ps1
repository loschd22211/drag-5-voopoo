# Убирает левую страницу рабочего стола ColorOS (лента «热点资讯» с китайскими видео).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\left-panel.ps1
#   ... -Find      только показать, что на странице, ничего не менять
#   ... -Restore   вернуть выключенное этим скриптом
#
# Скрипт сам жмёт «домой», сам свайпает на левую страницу по реальному размеру
# экрана, сам читает её разметку и ищет иероглифы. Гасит только пакеты из
# $Allowed. Обои, будильник, заметки, файлы, звук и систему не трогает.
#
# Проверка честная: печатается число китайских надписей до и после. «Убрано»
# пишется только если их стало ноль, иначе — сколько осталось.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Find
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.4"
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

# Размер экрана в пикселях: свайп по центру, а не наугад.
function Get-ScreenSize {
  $raw = Sh 'wm size'
  $m = [regex]::Match($raw, 'Override size:\s*(\d+)x(\d+)')
  if (-not $m.Success) { $m = [regex]::Match($raw, 'Physical size:\s*(\d+)x(\d+)') }
  if (-not $m.Success) { return @(1080, 2400) }
  return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
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

function Disable-Package($pkg) {
  Sh ("pm disable-user --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'отключён') { return 'отключён' }
  Sh ("pm suspend --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'приостановлен') { return 'приостановлен' }
  return ''
}

# Только лента и её поставщики. Больше ничего.
$Allowed = @(
  'com.coloros.assistantscreen',
  'com.heytap.assistantscreen',
  'com.oplus.assistantscreen',
  'com.heytap.browser',
  'com.heytap.news',
  'com.oppo.news',
  'com.coloros.news',
  'com.heytap.quicksearchbox',
  'com.oppo.quicksearchbox',
  'com.oplus.contentportal',
  'com.heytap.pictorial'
)

$LeftPanelKeys = @(
  'key_com_coloros_assistantscreen',
  'remote_view_entry_com.coloros.assistantscreen',
  'assistant_screen_type',
  'asistant_screen_type'
)

function Get-ScreenDump {
  Sh 'uiautomator dump /sdcard/leftpanel.xml' | Out-Null
  $xml = Sh 'cat /sdcard/leftpanel.xml'
  if ($xml -notmatch '<hierarchy') { return $null }
  return $xml
}

function Get-DumpPackages($xml) {
  $counts = @{}
  foreach ($m in [regex]::Matches($xml, 'package="([^"]+)"')) {
    $n = $m.Groups[1].Value.Trim()
    if ($counts.ContainsKey($n)) { $counts[$n] = $counts[$n] + 1 } else { $counts[$n] = 1 }
  }
  return $counts
}

function Get-CjkTexts($xml) {
  $out = @()
  foreach ($m in [regex]::Matches($xml, 'text="([^"]*[\u4e00-\u9fff][^"]*)"')) {
    $t = $m.Groups[1].Value
    if ($out -notcontains $t) { $out += $t }
  }
  return $out
}

# Свайп вправо от первого экрана = страница «-1». Старт не у края, чтобы не
# поймать системный жест «назад», и на середине высоты, чтобы не попасть в виджет.
function Open-LeftPage([int]$Width, [int]$Height) {
  Sh 'input keyevent 3' | Out-Null
  Start-Sleep -Milliseconds 500
  $x1 = [int]($Width * 0.12)
  $x2 = [int]($Width * 0.88)
  $y = [int]($Height * 0.55)
  for ($i = 0; $i -lt 2; $i++) {
    Sh ("input swipe {0} {1} {2} {1} 220" -f $x1, $y, $x2) | Out-Null
    Start-Sleep -Milliseconds 700
  }
}

function Set-LeftPanelOff {
  foreach ($k in $LeftPanelKeys) { Sh ("settings put secure " + $k + " 0") | Out-Null }
}

function Test-InDump($xml, $pkg) {
  return ($xml -match ('package="' + [regex]::Escape($pkg) + '"'))
}

# Видно ли окно ленты в списке окон прямо сейчас.
function Test-PanelWindow {
  $win = Sh 'dumpsys window windows'
  $block = @()
  $lines = $win -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Window #\d+ Window\{.*assistantscreen') {
      for ($j = $i; $j -lt [Math]::Min($i + 40, $lines.Count); $j++) { $block += $lines[$j] }
      break
    }
  }
  $text = ($block -join "`n")
  if ($text -match 'isVisible=true' -or $text -match 'mHasSurface=true.*isVisible=true') { return $true }
  return $false
}

function Measure-Page {
  param([int]$Width, [int]$Height)
  Open-LeftPage -Width $Width -Height $Height
  $xml = Get-ScreenDump
  $cjk = @()
  if ($null -ne $xml) { $cjk = Get-CjkTexts $xml }
  return [pscustomobject]@{ Xml = $xml; Cjk = $cjk; Browser = (Test-PanelWindow) }
}

# ---------------------------------------------------------------- main

Connect-Adb

$size = Get-ScreenSize
$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}, экран {2}x{3}" -f $model, $rom, $size[0], $size[1])

if ($Restore) {
  Write-Step "Возвращаю выключенное этим скриптом"
  $n = 0
  foreach ($p in $Allowed) {
    $st = Get-State $p
    if ($st -eq 'нет' -or $st -eq 'включён') { continue }
    Sh ("pm unsuspend --user 0 " + $p) | Out-Null
    Sh ("pm enable --user 0 " + $p) | Out-Null
    if ((Get-State $p) -eq 'включён') { Write-Dim ("включён: " + $p); $n++ }
  }
  Write-Ok ("включено обратно: " + $n)
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Ключи левой страницы"
foreach ($k in $LeftPanelKeys) {
  $v = Sh ("settings get secure " + $k)
  if ($v -eq 'null') { $v = '—' }
  Write-Dim ($k + " = " + $v)
}

if (-not $Find) {
  Set-LeftPanelOff
  Write-Ok "поставил в 0"
  Sh 'am force-stop com.android.launcher' | Out-Null
  Start-Sleep -Seconds 3
  Write-Dim "лончер перезапущен (ключи он читает только при старте)"
}

Write-Step "Открываю левую страницу сам"
Write-Dim "телефон держи разблокированным, экран не гаси"
$first = Measure-Page -Width $size[0] -Height $size[1]

if ($null -eq $first.Xml) {
  Stop-Script "разметку снять не удалось: разблокируй телефон и запусти ещё раз"
}

$counts = Get-DumpPackages $first.Xml
Write-Dim "на экране:"
foreach ($e in ($counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 6)) {
  Write-Host ("     {0}  ({1})" -f $e.Key, $e.Value) -ForegroundColor DarkGray
}

if ($first.Cjk.Count -eq 0 -and -not $first.Browser) {
  Write-Warn "китайских надписей нет и окна ленты не видно"
  Write-Dim "значит страница уже убрана либо не открылась"
  Write-Dim "открой её руками и запусти: ... -Find  — тогда скрипт скажет, кто её рисует"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Ok ("до правки: китайских надписей " + $first.Cjk.Count + ", окно ленты: " + $first.Browser)
foreach ($t in ($first.Cjk | Select-Object -First 10)) { Write-Host ("     " + $t) -ForegroundColor DarkGray }

$hits = @()
foreach ($p in $Allowed) {
  if (Test-InDump $first.Xml $p) { $hits += $p }
}
if ($hits.Count -eq 0) { $hits = @('com.coloros.assistantscreen', 'com.heytap.browser') }
Write-Ok ("гашу: " + ($hits -join ', '))

if ($Find) {
  Write-Host ""
  Write-Dim "режим -Find: ничего не менял"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Гашу"
foreach ($p in $hits) {
  $how = Disable-Package $p
  if ($how -ne '') { Write-Ok ("{0}: {1}" -f $p, $how) } else { Write-Warn ("{0}: не поддался" -f $p) }
}
Sh 'am force-stop com.android.launcher' | Out-Null
Start-Sleep -Seconds 3

Write-Step "Проверяю по факту"
$second = Measure-Page -Width $size[0] -Height $size[1]
if ($null -eq $second.Xml) {
  Write-Warn "второй замер не удался — посмотри глазами"
} else {
  Write-Dim ("после правки: китайских надписей " + $second.Cjk.Count + ", окно ленты: " + $second.Browser)
  if ($second.Cjk.Count -eq 0 -and -not $second.Browser) {
    Write-Ok "страницы нет"
  } elseif ($second.Cjk.Count -lt $first.Cjk.Count) {
    Write-Warn ("стало меньше, но не ноль: было " + $first.Cjk.Count + ", осталось " + $second.Cjk.Count)
    Write-Dim "скинь эти строки — добью остаток точечно"
  } else {
    Write-Warn "страница на месте: её рисует не тот пакет, что я погасил"
    Write-Dim "тогда остаётся только переключатель в настройках рабочего стола:"
    Write-Dim "долгое нажатие на пустом месте → шестерёнка → пункт 智能助手 / 负一屏 / 资讯"
  }
}

Write-Host ""
Write-Dim "Обои, будильник, заметки, файлы и остальную систему скрипт не трогает."
Write-Dim "Вернуть: эта же команда с ключом -Restore"
Write-Host ""
Read-Host "Enter — закрыть"
