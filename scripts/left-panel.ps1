# Убирает левую страницу рабочего стола ColorOS (китайские рекомендации) и лишнее китайское.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\left-panel.ps1
#   ... -Find      только посмотреть, что за страница, ничего не менять
#   ... -Restore   включить выключенное обратно
#
# Скрипт не угадывает пакет: он просит открыть страницу, снимает дамп окон,
# активностей, слоёв SurfaceFlinger и журнала — и по ним определяет, кто её рисует.
# Ничего не удаляет: pm disable-user / pm suspend. Game Center и гейм-бар не трогаем.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
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

function Get-Lines($text, [string]$pattern, [int]$max) {
  if ($null -eq $text) { return @() }
  $out = @(($text -split "`r?`n") | Where-Object { $_ -match $pattern } | Select-Object -First $max)
  return $out
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

function Get-State($pkg) {
  $out = Sh ("pm list packages -d --user 0 " + $pkg)
  if ($out -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'отключён' }
  $dump = Sh ("dumpsys package " + $pkg)
  if ($dump -match 'suspended=true') { return 'приостановлен' }
  $out2 = Sh ("pm list packages --user 0 " + $pkg)
  if ($out2 -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'включён' }
  return 'нет'
}

# ColorOS на части пакетов отвечает "new state: default" и disable-user не срабатывает.
function Disable-Package($pkg) {
  Sh ("pm disable-user --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'отключён') { return 'отключён' }
  Sh ("pm suspend --user 0 " + $pkg) | Out-Null
  if ((Get-State $pkg) -eq 'приостановлен') { return 'приостановлен' }
  return ''
}

# Пакеты, которые пробуем первыми, если дамп ничего внятного не дал.
$Suspects = @(
  'com.coloros.assistantscreen',
  'com.heytap.assistantscreen',
  'com.oplus.assistantscreen',
  'com.coloros.assistant',
  'com.coloros.smartassistant',
  'com.oplus.smartassistant',
  'com.heytap.news',
  'com.oppo.news',
  'com.coloros.news',
  'com.heytap.browser',
  'com.coloros.pictorial',
  'com.oplus.aimemory',
  'com.heytap.recommend',
  'com.coloros.recommend'
)

# Что нельзя гасить ни при каких условиях.
$Keep = @(
  'com.android.systemui',
  'com.android.launcher',
  'com.oppo.launcher',
  'com.android.settings',
  'com.oplus.settings',
  'com.coloros.settings',
  'com.android.phone',
  'com.android.providers.telephony',
  'com.android.incallui',
  'com.oplus.camera',
  'com.coloros.gallery3d',
  'com.coloros.securitypermission',
  'com.oplus.games',
  'com.oplus.gamemode',
  'com.coloros.gamespaceui',
  'com.heytap.mcs'
)

$LeftPanelKeys = @(
  'key_com_coloros_assistantscreen',
  'remote_view_entry_com.coloros.assistantscreen',
  'assistant_screen_type',
  'asistant_screen_type'
)

function Get-KeyValues {
  $rows = @()
  foreach ($k in $LeftPanelKeys) {
    $v = Sh ("settings get secure " + $k)
    if ($v -eq 'null') { $v = '—' }
    $rows += [pscustomobject]@{ Key = $k; Value = $v }
  }
  return $rows
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

$pkgAll = Get-Packages ''
$installed = @{}
foreach ($p in $pkgAll) { $installed[$p] = $true }

if ($Restore) {
  # Ничего не запоминаем в файлах: возвращаем всё китайское, что сейчас выключено.
  Write-Step "Возвращаю китайские приложения"
  $n = 0
  foreach ($p in $pkgAll) {
    if ($Keep -contains $p) { continue }
    if ($Suspects -notcontains $p -and $p -notmatch '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { continue }
    if ((Get-State $p) -eq 'включён') { continue }
    Sh ("pm unsuspend --user 0 " + $p) | Out-Null
    Sh ("pm enable --user 0 " + $p) | Out-Null
    if ((Get-State $p) -eq 'включён') { $n++; Write-Dim ("включён: " + $p) }
  }
  Write-Ok ("включено обратно: " + $n)
  Write-Dim "ключи левой страницы оставил в 0 — включать её тебе не надо"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Что сейчас"
foreach ($row in (Get-KeyValues)) { Write-Dim ($row.Key + " = " + $row.Value) }
$present = @()
foreach ($p in $Suspects) { if ($installed.ContainsKey($p)) { $present += $p } }
if ($present.Count -gt 0) { Write-Dim ("похожие пакеты: " + ($present -join ', ')) }
else { Write-Dim "похожих пакетов в системе нет" }

Write-Step "Покажи страницу"
Write-Dim "свайпни рабочий стол вправо до упора — до той самой страницы с китайскими советами"
Write-Dim "страницу не закрывай, пока скрипт не закончит"
Sh 'logcat -c' | Out-Null
Read-Host "Enter — когда она на экране"

Write-Step "Смотрю, кто её рисует"
$winLines = Get-Lines (Sh 'dumpsys window windows') 'Window #|mCurrentFocus|mFocusedApp' 14
$actLines = Get-Lines (Sh 'dumpsys activity activities') 'ActivityRecord\{|topResumedActivity|mResumedActivity' 10
$sfLines  = Get-Lines (Sh 'dumpsys SurfaceFlinger --list') 'launcher|assist|news|feed|recommend|heytap|coloros|oplus' 14
$logLines = Get-Lines (Sh 'logcat -d -v brief') 'START u0' 12

Write-Dim "окна:"
foreach ($l in $winLines) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }
Write-Dim "активности:"
foreach ($l in $actLines) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }
Write-Dim "слои экрана:"
foreach ($l in $sfLines) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }
Write-Dim "журнал запуска:"
foreach ($l in $logLines) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }

$evidence = (($winLines + $actLines + $sfLines + $logLines) -join "`n")
$found = @()
foreach ($m in [regex]::Matches($evidence, 'com\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+')) {
  $name = $m.Value
  if ($Keep -contains $name) { continue }
  if (-not $installed.ContainsKey($name)) { continue }
  if ($found -notcontains $name) { $found += $name }
}
# Оставляем только подозрительных: помощник, новости, лента и родные оболочки.
$hits = @()
foreach ($p in $found) {
  if ($p -match '(assist|news|feed|recommend|breeno|smart|pictorial)') { $hits += $p }
}
foreach ($p in $Suspects) {
  if ($installed.ContainsKey($p) -and ($evidence -match [regex]::Escape($p)) -and ($hits -notcontains $p)) { $hits += $p }
}

Write-Host ""
if ($hits.Count -eq 0) {
  Write-Warn "отдельного пакета не видно — страница рисуется внутри лончера"
  Write-Dim "тогда её убирает только переключатель в настройках рабочего стола; ниже — ключи"
} else {
  Write-Ok ("нашёл: " + ($hits -join ', '))
}

if ($Find) {
  Write-Host ""
  Write-Dim "режим -Find: ничего не менял"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Гашу"
$off = 0
foreach ($p in $hits) {
  if ($Keep -contains $p) { continue }
  $how = Disable-Package $p
  if ($how -ne '') { Write-Ok ("{0}: {1}" -f $p, $how); $off++ }
  else { Write-Warn ("{0}: не поддался" -f $p) }
}
Set-LeftPanelOff
Write-Ok "ключи левой страницы в 0"

# Если страница осталась — пробуем известные пакеты-кандидаты.
Write-Step "Проверка"
Read-Host "Enter — свайпни на левую страницу ещё раз, потом Enter"
$after = Get-Lines (Sh 'dumpsys window windows') 'mCurrentFocus' 2
foreach ($l in $after) { Write-Host ("     " + $l.Trim()) -ForegroundColor DarkGray }

foreach ($p in $present) {
  if ($hits -contains $p) { continue }
  $how = Disable-Package $p
  if ($how -ne '') { Write-Ok ("{0}: {1}" -f $p, $how); $off++ }
}

Write-Host ""
Write-Ok ("выключено: " + $off)
Write-Dim "Вернуть: эта же команда с ключом -Restore"
Write-Host ""

# ---------------------------------------------------------------- остальное китайское

Write-Step "Что ещё китайское осталось включённым"
$enabled = Get-Packages ''
$offList = Get-Packages ' -d'
$cn = @()
foreach ($p in $enabled) {
  if ($offList -contains $p) { continue }
  if ($Keep -contains $p) { continue }
  if ($Suspects -contains $p) { continue }
  if ($p -notmatch '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { continue }
  if ($p -match '(security|permission|telephony|incallui|provider|camera|gallery|settings|launcher|systemui|engineer|diagnostic|update|ota|nfc|bluetooth|wifi|mms|contacts|dialer|sim|keyguard|framework|common)') { continue }
  $cn += $p
}
if ($cn.Count -eq 0) {
  Write-Ok "лишнего не видно"
} else {
  Write-Dim ("нашлось: " + $cn.Count)
  foreach ($p in $cn) { Write-Dim ("  " + $p) }
  Write-Host ""
  $ans = Read-Host "Выключить всё из списка? (y/n)"
  if ($ans -eq 'y') {
    $n = 0
    foreach ($p in $cn) {
      $how = Disable-Package $p
      if ($how -ne '') { $n++ }
    }
    Write-Ok ("выключено: " + $n)
    Write-Dim "вернуть всё: эта же команда с ключом -Restore (список выше — в scripts\debloat-cn.ps1)"
  } else {
    Write-Dim "ничего не менял"
  }
}

Write-Host ""
Read-Host "Enter — закрыть"
