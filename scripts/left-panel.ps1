# Убирает левую страницу рабочего стола ColorOS (китайские рекомендации).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\left-panel.ps1
#   ... -Find      только посмотреть, кто рисует страницу
#   ... -Restore   вернуть выключенное этим скриптом
#
# Важно: скрипт НЕ выключает «всё китайское списком». Он трогает только тот
# пакет, который реально рисует левую страницу, и только если это контент
# (помощник, новости, лента, поиск). Обои, будильник, файлы, звук, батарея
# и остальная система не трогаются никогда.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Find
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.2"
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

function Get-Lines($text, [string]$pattern, [int]$max) {
  if ($null -eq $text) { return @() }
  return @(($text -split "`r?`n") | Where-Object { $_ -match $pattern } | Select-Object -First $max)
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

# Что разрешено гасить: только контентные приложения. Всё остальное — никогда.
$Allowed = @(
  'com.coloros.assistantscreen',
  'com.heytap.assistantscreen',
  'com.oplus.assistantscreen',
  'com.coloros.assistant',
  'com.heytap.news',
  'com.oppo.news',
  'com.coloros.news',
  'com.heytap.browser',
  'com.heytap.quicksearchbox',
  'com.oppo.quicksearchbox',
  'com.oplus.contentportal',
  'com.heytap.pictorial'
)

$Keep = @(
  'com.android.launcher',
  'com.oppo.launcher',
  'com.android.systemui',
  'com.android.settings'
)

$LeftPanelKeys = @(
  'key_com_coloros_assistantscreen',
  'remote_view_entry_com.coloros.assistantscreen',
  'assistant_screen_type',
  'asistant_screen_type'
)

# Слепок экрана: кто реально нарисовал то, что видно.
function Get-ScreenDump {
  Sh 'uiautomator dump /sdcard/leftpanel.xml' | Out-Null
  $xml = Sh 'cat /sdcard/leftpanel.xml'
  if ($xml -notmatch '<hierarchy') { return $null }
  return $xml
}

# Пакеты внутри разметки, по частоте: самый частый — тот, кто рисует страницу.
function Get-DumpPackages($xml) {
  $counts = @{}
  foreach ($m in [regex]::Matches($xml, 'package="([^"]+)"')) {
    $n = $m.Groups[1].Value
    if ($counts.ContainsKey($n)) { $counts[$n] = $counts[$n] + 1 } else { $counts[$n] = 1 }
  }
  return $counts
}

function Get-DumpTexts($xml, [int]$max) {
  $out = @()
  foreach ($m in [regex]::Matches($xml, 'text="([^"]+)"')) {
    $t = $m.Groups[1].Value
    if ($t.Trim() -ne '' -and $out -notcontains $t) { $out += $t }
    if ($out.Count -ge $max) { break }
  }
  return $out
}

function Set-LeftPanelOff {
  foreach ($k in $LeftPanelKeys) { Sh ("settings put secure " + $k + " 0") | Out-Null }
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
  Write-Dim "если нужно вернуть вообще всё китайское — scripts\restore-cn.ps1"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Что сейчас"
foreach ($k in $LeftPanelKeys) {
  $v = Sh ("settings get secure " + $k)
  if ($v -eq 'null') { $v = '—' }
  Write-Dim ($k + " = " + $v)
}

Write-Step "Покажи страницу"
Write-Dim "свайпни рабочий стол вправо до упора — до страницы с китайскими советами"
Write-Dim "оставь её на экране и вернись в PowerShell"
Sh 'logcat -c' | Out-Null
Read-Host "Enter — когда она на экране"

Write-Step "Смотрю, кто её рисует"
$sfLines = Get-Lines (Sh 'dumpsys SurfaceFlinger --list') 'launcher|assist|news|feed|recommend|heytap|coloros|oplus|pictorial' 12
foreach ($l in $sfLines) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }

$xml = Get-ScreenDump
if ($null -eq $xml) {
  Write-Warn "разметку экрана снять не удалось (uiautomator не ответил)"
} else {
  $texts = Get-DumpTexts $xml 8
  if ($texts.Count -gt 0) {
    Write-Dim "что написано на странице:"
    foreach ($t in $texts) { Write-Host ("     " + $t) -ForegroundColor DarkGray }
  }
  $counts = Get-DumpPackages $xml
  Write-Dim "кто нарисовал:"
  $sorted = $counts.GetEnumerator() | Sort-Object -Property Value -Descending
  foreach ($e in ($sorted | Select-Object -First 6)) {
    Write-Host ("     {0}  ({1} элементов)" -f $e.Key, $e.Value) -ForegroundColor DarkGray
  }
}

# Кто из разрешённых реально присутствует на странице.
$hits = @()
if ($null -ne $xml) {
  foreach ($p in $Allowed) {
    if ($xml -match ('package="' + [regex]::Escape($p) + '"')) { $hits += $p }
  }
}
# Ничего не нашлось — берём того, кого видно в слоях экрана.
if ($hits.Count -eq 0) {
  foreach ($p in $Allowed) {
    foreach ($l in $sfLines) {
      if ($l -match [regex]::Escape($p)) { if ($hits -notcontains $p) { $hits += $p } }
    }
  }
}

Write-Host ""
if ($hits.Count -eq 0) {
  Write-Warn "страницу рисует не отдельное приложение, а сам лончер"
  Write-Dim "такую страницу выключает только переключатель в настройках рабочего стола"
  Write-Dim "долгое нажатие на пустом месте рабочего стола → Настройки рабочего стола →"
  Write-Dim "страница «Помощник» / «Рекомендации» / «智能助手» → выключить"
  Write-Host ""
  Write-Dim "ключи я всё равно поставлю в 0"
  if (-not $Find) { Set-LeftPanelOff; Write-Ok "ключи левой страницы в 0" }
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

Write-Step "Гашу только это"
foreach ($p in $hits) {
  if ($Keep -contains $p) { continue }
  $how = Disable-Package $p
  if ($how -ne '') { Write-Ok ("{0}: {1}" -f $p, $how) } else { Write-Warn ("{0}: не поддался" -f $p) }
}
Set-LeftPanelOff
Write-Ok "ключи левой страницы в 0"

Write-Step "Проверка"
Read-Host "Enter — открой левую страницу ещё раз и нажми Enter"
$xml2 = Get-ScreenDump
if ($null -eq $xml2) {
  Write-Warn "разметку снять не удалось — проверь глазами"
} else {
  $still = @()
  foreach ($p in $hits) {
    if ($xml2 -match ('package="' + [regex]::Escape($p) + '"')) { $still += $p }
  }
  if ($still.Count -eq 0) {
    Write-Ok "на странице больше нет этого приложения — убрано"
  } else {
    Write-Warn ("всё ещё видно: " + ($still -join ', '))
    Write-Dim "значит страницу держит лончер; выключается только в настройках рабочего стола"
  }
}

Write-Host ""
Write-Dim "Обои, будильник, файлы, звук и остальную систему скрипт не трогает."
Write-Dim "Вернуть: эта же команда с ключом -Restore"
Write-Host ""
Read-Host "Enter — закрыть"
