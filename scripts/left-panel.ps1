# Убирает левую страницу рабочего стола ColorOS (лента «热点资讯» с китайскими видео).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\left-panel.ps1
#   ... -Find      только показать, что на странице, ничего не менять
#   ... -Restore   вернуть выключенное этим скриптом
#
# Скрипт сам жмёт «домой» и сам пробует разные свайпы, проверяя по скриншоту,
# что страница действительно сменилась. Только после этого он что-то гасит.
#
# Важно: suspend не убивает уже запущенный процесс — лента остаётся на экране.
# Поэтому после выключения пакета идёт am force-stop, и только потом проверка.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Find
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.5"
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
  $how = ''
  if ((Get-State $pkg) -eq 'отключён') { $how = 'отключён' }
  else {
    Sh ("pm suspend --user 0 " + $pkg) | Out-Null
    if ((Get-State $pkg) -eq 'приостановлен') { $how = 'приостановлен' }
  }
  # suspend не убивает процесс: без force-stop лента остаётся на экране
  Sh ("am force-stop " + $pkg) | Out-Null
  return $how
}

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

# Отпечаток экрана: по нему видно, сменилась ли страница после свайпа.
function Get-ScreenHash {
  Sh 'screencap -p /sdcard/leftpanel.png' | Out-Null
  $out = Sh 'md5sum /sdcard/leftpanel.png'
  $m = [regex]::Match($out, '([0-9a-fA-F]{32})')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-ScreenDump {
  Sh 'uiautomator dump /sdcard/leftpanel.xml' | Out-Null
  $xml = Sh 'cat /sdcard/leftpanel.xml'
  if ($xml -notmatch '<hierarchy') { return $null }
  return $xml
}

function Get-CjkTexts($xml) {
  if ($null -eq $xml) { return @() }
  $out = @()
  foreach ($m in [regex]::Matches($xml, 'text="([^"]*[\u4e00-\u9fff][^"]*)"')) {
    $t = $m.Groups[1].Value
    if ($out -notcontains $t) { $out += $t }
  }
  return $out
}

function Get-DumpPackages($xml) {
  $counts = @{}
  if ($null -eq $xml) { return $counts }
  foreach ($m in [regex]::Matches($xml, 'package="([^"]+)"')) {
    $n = $m.Groups[1].Value.Trim()
    if ($counts.ContainsKey($n)) { $counts[$n] = $counts[$n] + 1 } else { $counts[$n] = 1 }
  }
  return $counts
}

# Блок окна ленты целиком (до следующего «Window #»), а не соседние окна.
function Test-PanelWindow {
  $win = Sh 'dumpsys window windows'
  $lines = $win -split "`r?`n"
  $block = @()
  $inside = $false
  foreach ($l in $lines) {
    if ($l -match 'Window #\d+ Window\{') {
      $inside = ($l -match 'assistantscreen')
      if ($inside) { $block = @($l); continue }
    }
    if ($inside) { $block += $l }
  }
  $text = ($block -join "`n")
  if ($text -eq '') { return $false }
  if ($text -match 'isVisible=true') { return $true }
  if ($text -match 'mViewVisibility=0x0' -and $text -match 'mHasSurface=true') { return $true }
  return $false
}

function Invoke-Swipe([string]$Variant, [int]$Width, [int]$Height) {
  if ($Variant -eq 'A') {
    Sh ("input swipe {0} {1} {2} {1} 250" -f [int]($Width * 0.10), [int]($Height * 0.55), [int]($Width * 0.90)) | Out-Null
  } elseif ($Variant -eq 'B') {
    Sh ("input swipe {0} {1} {2} {1} 400" -f [int]($Width * 0.25), [int]($Height * 0.75), [int]($Width * 0.95)) | Out-Null
  } else {
    Sh ("input swipe {0} {1} {2} {1} 600" -f [int]($Width * 0.05), [int]($Height * 0.35), [int]($Width * 0.85)) | Out-Null
  }
  Start-Sleep -Milliseconds 900
}

# Идём на левую страницу, пока не сменится картинка экрана.
function Open-LeftPage([int]$Width, [int]$Height) {
  Sh 'input keyevent 3' | Out-Null
  Start-Sleep -Milliseconds 700
  $home = Get-ScreenHash
  foreach ($variant in @('A', 'B', 'C')) {
    for ($try = 1; $try -le 2; $try++) {
      Invoke-Swipe -Variant $variant -Width $Width -Height $Height
      $now = Get-ScreenHash
      if ($now -ne '' -and $home -ne '' -and $now -ne $home) {
        return [pscustomobject]@{ Changed = $true; Variant = $variant; Try = $try }
      }
    }
  }
  return [pscustomobject]@{ Changed = $false; Variant = ''; Try = 0 }
}

function Measure-Page([int]$Width, [int]$Height) {
  $move = Open-LeftPage -Width $Width -Height $Height
  $xml = Get-ScreenDump
  $cjk = Get-CjkTexts $xml
  return [pscustomobject]@{
    Xml = $xml
    Cjk = $cjk
    Moved = $move.Changed
    Variant = $move.Variant
    Window = (Test-PanelWindow)
  }
}

function Set-LeftPanelOff {
  foreach ($k in $LeftPanelKeys) { Sh ("settings put secure " + $k + " 0") | Out-Null }
}

function Test-InDump($xml, $pkg) {
  if ($null -eq $xml) { return $false }
  return ($xml -match ('package="' + [regex]::Escape($pkg) + '"'))
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
}

Write-Step "Открываю левую страницу сам"
Write-Dim "телефон держи разблокированным, экран не гаси"
$first = Measure-Page -Width $size[0] -Height $size[1]

if (-not $first.Moved) {
  Write-Warn "ни один свайп не сменил экран — до левой страницы не добрался"
  Write-Dim "оставь телефон на рабочем столе, не в приложении, и запусти ещё раз"
  Write-Dim "либо пролистай вручную: тогда запусти скрипт с ключом -Find"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Ok ("страница открылась (свайп " + $first.Variant + ")")

$counts = Get-DumpPackages $first.Xml
Write-Dim "на экране:"
foreach ($e in ($counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 6)) {
  Write-Host ("     {0}  ({1})" -f $e.Key, $e.Value) -ForegroundColor DarkGray
}
Write-Dim ("китайских надписей: " + $first.Cjk.Count + ", окно ленты: " + $first.Window)
foreach ($t in ($first.Cjk | Select-Object -First 10)) { Write-Host ("     " + $t) -ForegroundColor DarkGray }

$hits = @()
foreach ($p in $Allowed) {
  if (Test-InDump $first.Xml $p) { $hits += $p }
}
if ($hits.Count -eq 0 -and $first.Window) { $hits = @('com.coloros.assistantscreen', 'com.heytap.browser') }
if ($hits.Count -eq 0) { $hits = @('com.coloros.assistantscreen', 'com.heytap.browser') }

if ($Find) {
  Write-Ok ("гасил бы: " + ($hits -join ', '))
  Write-Host ""
  Write-Dim "режим -Find: ничего не менял"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Гашу и убиваю процессы"
foreach ($p in $hits) {
  $how = Disable-Package $p
  if ($how -ne '') { Write-Ok ("{0}: {1} + force-stop" -f $p, $how) } else { Write-Warn ("{0}: не поддался" -f $p) }
}
Sh 'am force-stop com.android.launcher' | Out-Null
Start-Sleep -Seconds 3

Write-Step "Проверяю по факту"
$second = Measure-Page -Width $size[0] -Height $size[1]
if (-not $second.Moved) {
  Write-Warn "после правки до страницы не добрался — проверь глазами"
} else {
  Write-Dim ("китайских надписей: " + $second.Cjk.Count + ", окно ленты: " + $second.Window)
  if ($second.Cjk.Count -eq 0 -and -not $second.Window) {
    Write-Ok "ленты нет: ни надписей, ни окна"
  } elseif ($second.Window -and $second.Cjk.Count -eq 0) {
    Write-Warn "окно ленты ещё в системе, но текста нет — возможно, страница уже пустая"
    Write-Dim "посмотри глазами: если на странице пусто, дело сделано"
  } else {
    Write-Warn ("лента на месте, иероглифов " + $second.Cjk.Count)
    Write-Dim "тогда её держит лончер: долгое нажатие на пустом месте → шестерёнка →"
    Write-Dim "пункт 智能助手 / 负一屏 / 资讯 → выключить"
  }
}

Write-Host ""
Write-Dim "Вернуть: эта же команда с ключом -Restore"
Write-Host ""
Read-Host "Enter — закрыть"
