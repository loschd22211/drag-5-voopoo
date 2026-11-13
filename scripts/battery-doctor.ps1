# Диагностика батареи: кто жрёт, почему быстро садится — и точечные исправления.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\battery-doctor.ps1
#   ... -Fix                        включить Doze (оптимизацию в простое) — единственное,
#                                   что -Fix делает сам
#   ... -Restrict pkg1,pkg2         запретить конкретным приложениям работать в фоне
#                                   (appops RUN_IN_BACKGROUND deny + остановить процесс)
#   ... -Unrestrict pkg1,pkg2       вернуть им фон обратно
#   ... -Unwhitelist pkg1,pkg2      убрать из белого списка Doze (обратимо)
#
# Без ключей скрипт ТОЛЬКО ЧИТАЕТ: здоровье и температуру батареи, расход с последней
# зарядки по приложениям, вейклоки, Doze и его белый список, частоту экрана,
# яркость, выключенные пакеты. Ничего не меняет.
#
# ЧЕГО СКРИПТ НЕ ДЕЛАЕТ (принципиально, ни при каких ключах):
#   * НЕ пишет ни одного ключа settings (яркость, частота, автоповорот, язык, регион,
#     тач-чувствительность / режим перчаток, ночной режим, анимации — не трогаем);
#   * НЕ удаляет и НЕ отключает приложения, НЕ чистит кэш и данные — файлы не затрагивает;
#   * НЕ трогает будильник, часы, обои, звук, Game Space, «Здоровье», Google-сервисы;
#   * -Restrict/-Unwhitelist отказываются работать на системных/нужных пакетах
#     ($NeverRestrict): gms, gsf, настройки, здоровье, будильник, гейм-бар и т.п.
#
# Хочешь убрать китайский софт — scripts\debloat-cn.ps1 (disable-user/suspend, обратимо -Restore).
# Пропали виджеты — scripts\widgets-fix.ps1. Шаги — scripts\steps-widget.ps1.
#
# Порядок: сначала запусти без ключей и прочитай вывод, потом решай.
# Не понял вывод — пришли его целиком, разберём.
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Fix,
  [string[]]$Restrict = @(),
  [string[]]$Unrestrict = @(),
  [string[]]$Unwhitelist = @()
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-11-13.2"
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

function Get-PkgList($raw) {
  $out = @()
  foreach ($line in ($raw -split "`r?`n")) {
    $m = [regex]::Match($line.Trim(), '^package:([A-Za-z0-9_.]+)')
    if ($m.Success) { $out += $m.Groups[1].Value }
  }
  return $out
}

# Пакеты, которые нельзя ограничивать и выбрасывать из белого списка Doze —
# ни под каким предлогом. Это не «удобство», а те, чьё ограничение ломает систему.
$NeverRestrict = @(
  'com.oplus.battery',
  'com.oplus.securitypermission',
  'com.oplus.ocs',
  'com.oplus.settings',
  'com.coloros.settings',
  'com.heytap.mcs',
  'com.oplus.healthservice',
  'com.heytap.health',
  'com.coloros.alarmclock',
  'com.android.deskclock',
  'com.coloros.filemanager',
  'com.coloros.wallpaper',
  'com.oplus.wallpapers',
  'com.heytap.colorfulengine',
  'com.oplus.games',
  'com.oplus.gamemode',
  'com.coloros.gamespaceui',
  'com.google.android.gms',
  'com.google.android.gsf',
  'com.google.android.gsf.login',
  'com.android.vending'
)
$NeverRestrictPrefixes = @(
  'com.android.',
  'com.oplus.settings',
  'com.coloros.settings'
)

function Test-Protected($pkg) {
  if ($NeverRestrict -contains $pkg) { return $true }
  foreach ($p in $NeverRestrictPrefixes) {
    if ($pkg.StartsWith($p)) { return $true }
  }
  return $false
}

function Test-PkgName($pkg) {
  return ($pkg -match '^[A-Za-z][A-Za-z0-9_.]{1,120}$')
}

# ---------------------------------------------------------------- действия

function Invoke-Restrict($pkgs, $deny) {
  foreach ($pkg in $pkgs) {
    if (-not (Test-PkgName $pkg)) { Write-Warn ("{0}: не похоже на имя пакета — пропускаю" -f $pkg); continue }
    if (Test-Protected $pkg) { Write-Warn ("{0}: системный/нужный пакет — не трогаю" -f $pkg); continue }
    $op = 'allow'
    if ($deny) { $op = 'deny' }
    $out = Sh ("appops set " + $pkg + " RUN_IN_BACKGROUND " + $op)
    if ($deny) { Sh ("am force-stop " + $pkg) | Out-Null }
    if ($deny) {
      Write-Ok ("{0}: фон запрещён, процесс остановлен" -f $pkg)
      Write-Dim "вернуть: battery-doctor.ps1 -Unrestrict " + $pkg
    } else {
      Write-Ok ("{0}: фон разрешён обратно" -f $pkg)
    }
    if ($out) { Write-Dim ("ответ: " + ($out -replace '\s+', ' ')) }
  }
}

function Invoke-Unwhitelist($pkgs) {
  foreach ($pkg in $pkgs) {
    if (-not (Test-PkgName $pkg)) { Write-Warn ("{0}: не похоже на имя пакета — пропускаю" -f $pkg); continue }
    if (Test-Protected $pkg) { Write-Warn ("{0}: системный/нужный пакет — не трогаю" -f $pkg); continue }
    $out = Sh ("dumpsys deviceidle whitelist -" + $pkg)
    Write-Ok ("{0}: убран из белого списка Doze" -f $pkg)
    Write-Dim ("ответ: " + (($out -replace '\s+', ' ') -replace '^$', '(пусто = сработало)'))
    Write-Dim ("вернуть: adb shell dumpsys deviceidle whitelist +" + $pkg)
  }
}

# ---------------------------------------------------------------- main

Connect-Adb
Write-Dim ("версия скрипта: " + $ScriptVersion)
$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
$android = Sh 'getprop ro.build.version.release'
Write-Dim ("{0}, Android {1}, прошивка {2}" -f $model, $android, $rom)
Write-Dim "файлы, обои, будильник, язык, тач-режим (перчатки) скрипт не трогает никогда"

# ---- режим действий (без полной диагностики) -----------------------------
$actionCount = $Restrict.Count + $Unrestrict.Count + $Unwhitelist.Count
if ($actionCount -gt 0) {
  Write-Step "Применяю точечные исправления"
  if ($Restrict.Count)    { Invoke-Restrict $Restrict $true }
  if ($Unrestrict.Count)  { Invoke-Restrict $Unrestrict $false }
  if ($Unwhitelist.Count) { Invoke-Unwhitelist $Unwhitelist }
  Write-Step "Готово"
  Write-Dim "Уведомления от ограниченного приложения могут приходить с задержкой — это и есть смысл."
  Write-Dim "Если что-то сломалось — откати -Unrestrict / команду из вывода обратно."
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

# ---- -Fix: единственное, что скрипт меняет сам ----------------------------
if ($Fix) {
  Write-Step "-Fix: включаю Doze (оптимизация в простое)"
  $r = Sh 'dumpsys deviceidle enable'
  if ($r -match '(?i)enabl') {
    Write-Ok "Doze включён — в простое приложения ограничиваются системой"
  } else {
    Write-Warn ("неожиданный ответ системы: " + ($r -replace '\s+', ' '))
    Write-Dim "если Doze и так был включён, это не ошибка"
  }
  Write-Dim "обратно (только если ОЧЕНЬ нужно): adb shell dumpsys deviceidle disable"
  Write-Dim "всё остальное -Fix не делает: остальные решения принимаешь ты по отчёту ниже"
}

# ---- 1. здоровье и температура батареи ------------------------------------
Write-Step "Батарея: здоровье, температура, заряд"
$bat = Sh 'dumpsys battery'
function BatVal($name) {
  $m = [regex]::Match($bat, '(?im)^\s*' + $name + ':\s*([0-9]+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return $null
}
$level = BatVal 'level'
$status = BatVal 'status'
$health = BatVal 'health'
$temp = BatVal 'temp'
$voltage = BatVal 'voltage'
$statusMap = @{ 1 = 'неизвестно'; 2 = 'заряжается'; 3 = 'разряжается'; 4 = 'не заряжается'; 5 = 'заряжена' }
$statusText = 'неизвестно'
if ($null -ne $status -and $statusMap.ContainsKey($status)) { $statusText = $statusMap[$status] }
if ($null -ne $level) { Write-Dim ("заряд: {0}%, статус: {1}" -f $level, $statusText) }
if ($null -ne $temp) {
  $t = [math]::Round($temp / 10.0, 1)
  $tempText = ("температура: {0}°C" -f $t)
  if ($t -ge 43) { Write-Warn ($tempText + " — горячо: чехол, длительная зарядка, игры — убери лишнее") } else { Write-Dim $tempText }
} else {
  Write-Dim "температуры в dumpsys battery нет — на ColorOS 17 этот блок может называться иначе"
}
if ($null -ne $health) {
  if ($health -eq 2) { Write-Ok "здоровье батареи: норма (health=2)" }
  else {
    Write-Warn ("здоровье батареи: health={0} — не «норма» (2)" -f $health)
    Write-Dim "никакие скрипты износ не лечат: либо сервис/замена АКБ, либо привычки (не греть, не сажать в ноль)"
  }
}
if ($null -ne $voltage) { Write-Dim ("напряжение: {0} мВ" -f $voltage) }

# ---- 2. кто съел заряд с последней зарядки --------------------------------
Write-Step "Расход с последней зарядки по приложениям"
$bs = Sh 'dumpsys batterystats --charged'
$since = 'с последней зарядки'
if (-not $bs -or $bs.Length -lt 200) {
  $bs = Sh 'dumpsys batterystats'
  $since = 'с последней полной зарядки (или перезагрузки)'
}
$entries = @()
foreach ($line in ($bs -split "`r?`n")) {
  if ($line -notmatch 'mAh') { continue }
  if ($line -match '(?i)capacity') { continue }
  $m = [regex]::Match($line, '([\d][\d\s,  ]*)\s*mAh')
  if (-not $m.Success) { continue }
  $numRaw = $m.Groups[1].Value -replace '[,\s\u00A0]', ''
  $mah = 0.0
  if (-not [double]::TryParse($numRaw, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$mah)) { continue }
  $pkg = ''
  $pm = [regex]::Match($line, '(?:[a-z][a-z0-9_]*\.){1,}[A-Za-z0-9_]+')
  if ($pm.Success) { $pkg = $pm.Value }
  $pct = ''
  $pp = [regex]::Match($line, '\(\s*([0-9.,]+)\s*%\)')
  if ($pp.Success) { $pct = $pp.Groups[1].Value + '%' }
  $entries += [pscustomobject]@{ Mah = $mah; Pkg = $pkg; Pct = $pct; Raw = ($line.Trim() -replace '\s+', ' ') }
}
$screenLine = [regex]::Match($bs, '(?im)^.*screen\s*on.*$')
if ($screenLine.Success) { Write-Dim ("экран включён был: " + (($screenLine.Value.Trim() -replace '\s+', ' '))) }
if ($entries.Count -eq 0) {
  Write-Warn "не удалось разобрать «Estimated power» — прошивка печатает расход в другом формате"
  Write-Dim "первые 600 символов вывода dumpsys batterystats:"
  Write-Dim ($bs.Substring(0, [math]::Min(600, $bs.Length)))
} else {
  $top = $entries | Sort-Object Mah -Descending | Select-Object -First 12
  Write-Dim ("показан расход {0}, топ по mAh:" -f $since)
  foreach ($e in $top) {
    $name = $e.Pkg
    if (-not $name) { $name = '(не распознан — сырая строка ниже)' }
    $pct = ''
    if ($e.Pct) { $pct = " ({0})" -f $e.Pct }
    Write-Dim ("  {0,8:N1} mAh{1}  {2}" -f $e.Mah, $pct, $name)
  }
  $missingPkgs = @($top | Where-Object { -not $_.Pkg }).Count
  if ($missingPkgs -gt 0) {
    Write-Dim "имена не распознаны (Android 17 печатает расход в другом формате) — сырые строки как есть:"
    $rawCount = 0
    foreach ($line in ($bs -split "`r?`n")) {
      if ($line -match 'mAh' -and $line -notmatch '(?i)capacity') {
        Write-Dim ("      " + ($line.Trim() -replace '\s+', ' '))
        $rawCount++
        if ($rawCount -ge 20) { break }
      }
    }
  }
  Write-Dim "подозрительные цифры с большим mAh — кандидаты в -Restrict (после твоего решения)"
}

# ---- 3. Doze: состояние и белый список ------------------------------------
Write-Step "Doze (сон в простое) и белый список"
$idle = Sh 'dumpsys deviceidle'
$idleLines = @($idle -split "`r?`n" | Where-Object { $_ -match 'mLightIdleEnabled|mDeepIdleEnabled|mState|state:|maintenance|Deep idle|Light idle' } | Select-Object -First 10)
if ($idleLines.Count) {
  foreach ($l in $idleLines) { Write-Dim ($l.Trim()) }
} else {
  Write-Dim "состояние Doze явными ключами не печатается — первые строки как есть:"
  $head = @($idle -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 12)
  foreach ($l in $head) { Write-Dim ("  " + $l.Trim()) }
}
$wl = Sh 'dumpsys power'
$wlLines = @($wl -split "`r?`n" | Where-Object { $_ -match '(?i)wake\s*lock|mWakefulness|last awake' } | Select-Object -First 10)
if ($wlLines.Count) {
  Write-Dim "что держит телефон в бодрствовании:"
  foreach ($l in $wlLines) { Write-Dim ("  " + $l.Trim()) }
} else {
  Write-Dim "вейклоки в dumpsys power не перечислены (бывает на ColorOS) — это не ошибка"
}
$whitelist = Sh 'dumpsys deviceidle whitelist'
Write-Dim "белый список Doze (все записи; эти приложения сон не получают):"
$wlAll = @($whitelist -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
foreach ($l in ($wlAll | Select-Object -First 40)) { Write-Dim ("  " + $l.Trim()) }
$cnWl = @($wlAll | Where-Object { $_ -match '(?i)heytap|coloros|oplus|oppo|nearme|oneplus' })
if ($cnWl.Count) {
  Write-Warn ("в белом списке {0} записей с китайскими префиксами — они никогда не уходят в сон" -f $cnWl.Count)
  foreach ($l in $cnWl) { Write-Dim ("      " + $l.Trim()) }
  Write-Dim "убрать конкретную: battery-doctor.ps1 -Unwhitelist <пакет> (обратимо)"
}

# ---- 4. экран: главную статью расхода --------------------------------------
Write-Step "Экран и частота (только смотрим — не меняем)"
$size = Sh 'wm size'
Write-Dim ("размер экрана: " + $size)
$peak = Sh 'settings get secure peak_refresh_rate'
$min = Sh 'settings get secure min_refresh_rate'
if ($peak -and $peak -notmatch '(?i)null|exception') { Write-Dim ("peak_refresh_rate: {0}" -f $peak) }
if ($min -and $min -notmatch '(?i)null|exception') { Write-Dim ("min_refresh_rate: {0}" -f $min) }
$dispRaw = Sh 'dumpsys display'
$dl = @($dispRaw -split "`r?`n" | Where-Object { $_ -match '(?i)refresh' } | Select-Object -First 6)
if ($dl.Count) {
  foreach ($l in $dl) { Write-Dim ("  " + $l.Trim()) }
} else {
  Write-Dim "  частота в дампе не перечислена (бывает на ColorOS) — смотри экранные настройки руками"
}
Write-Dim "подсказки по экрану:"
Write-Dim "  120 Гц вместо 60/90 — заметная посадка: Настройки → Экран → Частота обновления;"
Write-Dim "  AOD / «всегда на экране» (息屏显示) — часы и уведомления на тёмном фоне тоже жгут,"
Write-Dim "  выключается в Настройки → Экран блокировки;"
$bri = Sh 'settings get system screen_brightness'
$bmode = Sh 'settings get system screen_brightness_mode'
if ($bri -and $bri -notmatch '(?i)null|exception') { Write-Dim ("  яркость сейчас: {0} из 255; режим: {1} (1 = авто)" -f $bri, $bmode) }
Write-Dim "  яркость выше половины на OLED — всегда топ расхода; автояркость обычно помогает."

# ---- 5. анимации (честно: НЕ про батарею) ----------------------------------
Write-Step "Анимации"
$w = Sh 'settings get global window_animation_scale'
$t = Sh 'settings get global transition_animation_scale'
$a = Sh 'settings get global animator_duration_scale'
Write-Dim ("window={0}, transition={1}, animator={2}" -f $w, $t, $a)
Write-Dim "ускоренные анимации батарею НЕ садят — наоборот, перерисовка короче."
Write-Dim "если подозрение на них осталось — поставь 1 и поживи с неделю."

# ---- 6. тач/перчатки: только показываем, что ключи есть --------------------
Write-Step "Тач-чувствительность / перчатки (только читаем)"
function Select-Keys($raw, $words) {
  ($raw -split "`r?`n" | Where-Object { $_ -match $words }) -join "`n"
}
$tSys = Select-Keys (Sh 'settings list system')  '(?i)touch|glove|sensit|finger'
$tSec = Select-Keys (Sh 'settings list secure')  '(?i)touch|glove|sensit'
$tGlob = Select-Keys (Sh 'settings list global') '(?i)touch|glove|sensit'
$anyTouch = $false
if ($tSys)  { $anyTouch = $true; Write-Dim "system:" ; foreach ($l in ($tSys -split "`r?`n")) { Write-Dim ("  " + $l.Trim()) } }
if ($tSec)  { $anyTouch = $true; Write-Dim "secure:" ; foreach ($l in ($tSec -split "`r?`n")) { Write-Dim ("  " + $l.Trim()) } }
if ($tGlob) { $anyTouch = $true; Write-Dim "global:" ; foreach ($l in ($tGlob -split "`r?`n")) { Write-Dim ("  " + $l.Trim()) } }
if (-not $anyTouch) {
  Write-Dim "ключей по словам touch/glove/sensit не нашлось — это не ошибка."
}
Write-Dim "эти ключи скрипт НЕ пишет ни при каких флагах — зимняя настройка перчаток в безопасности."

# ---- 7. выключенные пакеты (и виджеты) ------------------------------------
Write-Step "Выключенные пакеты"
$disabled = Get-PkgList (Sh 'pm list packages -d')
$cnDisabled = @($disabled | Where-Object { $_ -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.' })
Write-Dim ("всего выключено: {0}, из них китайских: {1}" -f $disabled.Count, $cnDisabled.Count)
if ($cnDisabled.Count) {
  Write-Dim "это и есть причина «виджеты пропали»: у виджета мёртвое приложение-поставщик."
  Write-Dim "вернуть: scripts\widgets-fix.ps1 (включает всё погашенное, ничего не выключая)"
}

# ---- 8. что делать дальше ---------------------------------------------------
Write-Step "Что делать дальше"
Write-Dim "1) Видишь конкретный пакет с большим расходом и не пользуешься им:"
Write-Dim "   battery-doctor.ps1 -Restrict <пакет>     запретить фон (обратимо: -Unrestrict)"
Write-Dim "2) Китайский софт, которым в России не пользуешься (HeyTap-маркет, новости, читалки):"
Write-Dim "   scripts\debloat-cn.ps1                   отключит обратимо (откат: -Restore)"
Write-Dim "3) Пропали виджеты / нужен счётчик шагов:"
Write-Dim "   scripts\widgets-fix.ps1   и   scripts\steps-widget.ps1"
Write-Dim "4) Яркость / 120 Гц / AOD — только руками в настройках телефона."
Write-Dim "5) Ничего не понял — пришли этот вывод целиком, разберём по строкам."
Write-Host ""
Write-Ok "Скрипт ничего не удалял; ключи настроек не трогал (Doze — только с ключом -Fix)."
Write-Host ""
Read-Host "Enter — закрыть"
