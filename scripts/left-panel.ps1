# Убирает левую страницу рабочего стола ColorOS (китайская лента рекомендаций).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\left-panel.ps1
#   ... -Find      только посмотреть, ничего не менять
#   ... -Restore   вернуть выключенное этим скриптом
#
# Скрипт сам листает на левую страницу, сам читает её разметку и ищет китайские
# надписи. Гасит только пакеты из белого списка $Allowed. Обои, будильник, файлы,
# звук, заметки и остальную систему не трогает никогда.
#
# Проверка честная: «убрано» пишется только если пакет был в разметке до и исчез
# после. Если страницу рисует сам лончер — так и пишется.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Find
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.3"
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

function Disable-Package($pkg) {
  Sh ("pm disable-user --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'отключён') { return 'отключён' }
  Sh ("pm suspend --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'приостановлен') { return 'приостановлен' }
  return ''
}

# Только контент: помощник, новости, лента, поиск, pictorial. Больше ничего.
$Allowed = @(
  'com.coloros.assistantscreen',
  'com.heytap.assistantscreen',
  'com.oplus.assistantscreen',
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

# Разметка экрана: что реально видно.
function Get-ScreenDump {
  Sh 'uiautomator dump /sdcard/leftpanel.xml' | Out-Null
  $xml = Sh 'cat /sdcard/leftpanel.xml'
  if ($xml -notmatch '<hierarchy') { return $null }
  return $xml
}

# Пакеты в разметке: точное совпадение имени, без подстрок.
function Get-DumpPackages($xml) {
  $counts = @{}
  foreach ($m in [regex]::Matches($xml, 'package="([^"]+)"')) {
    $n = $m.Groups[1].Value.Trim()
    if ($counts.ContainsKey($n)) { $counts[$n] = $counts[$n] + 1 } else { $counts[$n] = 1 }
  }
  return $counts
}

# Китайские надписи на экране — главный признак, что мы на той странице.
function Get-CjkTexts($xml) {
  $out = @()
  foreach ($m in [regex]::Matches($xml, 'text="([^"]*[\u4e00-\u9fff][^"]*)"')) {
    $t = $m.Groups[1].Value
    if ($out -notcontains $t) { $out += $t }
  }
  return $out
}

# Свайп вправо от первого экрана = переход на страницу «-1».
function Open-LeftPage {
  Sh 'input swipe 220 1150 1050 1150 160' | Out-Null
  Start-Sleep -Milliseconds 800
}

function Set-LeftPanelOff {
  foreach ($k in $LeftPanelKeys) { Sh ("settings put secure " + $k + " 0") | Out-Null }
}

# Пакет был в разметке (точное имя), а не просто упомянут в строке.
function Test-InDump($xml, $pkg) {
  return ($xml -match ('package="' + [regex]::Escape($pkg) + '"'))
}

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

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
  Write-Dim "вернуть вообще всё: scripts\restore-cn.ps1"
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
  # Лончер читает эти ключи при старте, поэтому перезапускаем его.
  Sh 'am force-stop com.android.launcher' | Out-Null
  Start-Sleep -Seconds 3
  Write-Dim "лончер перезапущен"
}

Write-Step "Листаю на левую страницу"
Write-Dim "телефон держи разблокированным, руками ничего не трогай"
Start-Sleep -Seconds 1

$firstXml = $null
$firstCjk = @()
for ($i = 1; $i -le 3; $i++) {
  Open-LeftPage
  $xml = Get-ScreenDump
  if ($null -eq $xml) { continue }
  $cjk = Get-CjkTexts $xml
  if ($cjk.Count -gt 0) { $firstXml = $xml; $firstCjk = $cjk; break }
  if ($null -eq $firstXml) { $firstXml = $xml }
}

if ($null -eq $firstXml) {
  Stop-Script "разметку экрана снять не удалось. Разблокируй телефон, открой рабочий стол и запусти ещё раз"
}

$pkgCounts = Get-DumpPackages $firstXml
Write-Dim "кто на странице:"
foreach ($e in ($pkgCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 6)) {
  Write-Host ("     {0}  ({1} элементов)" -f $e.Key, $e.Value) -ForegroundColor DarkGray
}

if ($firstCjk.Count -eq 0) {
  Write-Warn "китайских надписей на странице нет"
  Write-Dim "значит страница либо уже убрана, либо лента не подгрузилась"
  Write-Dim "полистай её вниз и запусти скрипт с ключом -Find, когда на экране будут иероглифы"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Ok ("китайских надписей: " + $firstCjk.Count)
foreach ($t in ($firstCjk | Select-Object -First 8)) { Write-Host ("     " + $t) -ForegroundColor DarkGray }

# Кто из белого списка реально присутствует в разметке.
$hits = @()
foreach ($p in $Allowed) {
  if (Test-InDump $firstXml $p) { $hits += $p }
}

Write-Host ""
if ($hits.Count -eq 0) {
  Write-Warn "отдельного приложения на странице нет — её рисует сам лончер"
  Write-Dim "такую страницу выключает только переключатель в настройках рабочего стола:"
  Write-Dim "долгое нажатие на пустом месте рабочего стола → шестерёнка (Настройки) →"
  Write-Dim "пункт со словом 智能助手 / 负一屏 / Breeno / Рекомендации → выключить"
  Write-Dim "скинь мне разметку этого экрана (скрипт с -Find), и я назову точный пункт"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Ok ("страницу рисует: " + ($hits -join ', '))

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

Write-Step "Проверка по факту"
Start-Sleep -Seconds 2
$secondXml = $null
$secondCjk = @()
for ($i = 1; $i -le 3; $i++) {
  Open-LeftPage
  $xml2 = Get-ScreenDump
  if ($null -eq $xml2) { continue }
  $secondXml = $xml2
  $secondCjk = Get-CjkTexts $xml2
  if ($secondCjk.Count -gt 0) { break }
}

if ($null -eq $secondXml) {
  Write-Warn "разметку после отключения снять не удалось — проверь глазами"
} else {
  $still = @()
  foreach ($p in $hits) { if (Test-InDump $secondXml $p) { $still += $p } }
  if ($still.Count -eq 0 -and $secondCjk.Count -eq 0) {
    Write-Ok "страницы нет: ни пакета, ни китайских надписей"
  } elseif ($still.Count -eq 0) {
    Write-Warn ("пакет ушёл, но иероглифов на экране ещё " + $secondCjk.Count)
    Write-Dim "значит ленту рисует не он; скинь разметку — разберу"
  } else {
    Write-Warn ("пакет на странице остался: " + ($still -join ', '))
  }
}

Write-Host ""
Write-Dim "Обои, будильник, заметки, файлы и остальную систему скрипт не трогает."
Write-Dim "Вернуть: эта же команда с ключом -Restore"
Write-Host ""
Read-Host "Enter — закрыть"
