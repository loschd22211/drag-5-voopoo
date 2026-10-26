# Убирает китайские предустановленные приложения и слегка ускоряет телефон.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\debloat-cn.ps1
#   ... -Restore   включить всё обратно
#
# Ничего не удаляет: pm disable-user --user 0, всё возвращается ключом -Restore.
# Game Center и гейм-бар не трогаем (см. $Keep).
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore
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

# Что выключаем. Только те пакеты, которые не ломают систему, звонки, камеру,
# галерею и обновления. Всё возвращается ключом -Restore.
$Targets = @(
  'com.heytap.browser',        # браузер HeyTap
  'com.heytap.market',         # магазин приложений HeyTap
  'com.heytap.themestore',     # магазин тем
  'com.nearme.themestore',     # старый магазин тем
  'com.nearme.gamecenter',     # игровой магазин (не гейм-бар)
  'com.coloros.video',         # видеоплеер
  'com.heytap.yoli',           # видео Yoli
  'com.oppo.news',             # новости
  'com.heytap.news',
  'com.heytap.reader',         # читалка
  'com.oppo.book',
  'com.heytap.book',
  'com.oppo.community',        # форум OPPO
  'com.heytap.community',
  'com.heytap.member',         # программа лояльности
  'com.oplus.member',
  'com.oneplus.member',
  'com.heytap.store',          # магазин устройств
  'com.coloros.pictorial',     # журнал на экране блокировки
  'com.coloros.assistantscreen',
  'com.heytap.speechassist',
  'com.coloros.familyguard',
  'com.oplus.aimemory',
  'com.coloros.weather2'
)

# Что не трогаем ни при каких условиях (гейм-бар, игры, связь).
$Keep = @(
  'com.oplus.games',
  'com.oplus.gamemode',
  'com.coloros.gamespaceui',
  'com.heytap.mcs',
  'com.oplus.securitypermission'
)

function Get-State($pkg) {
  $out = Sh ("pm list packages -d --user 0 " + $pkg)
  if ($out -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'отключён' }
  $dump = Sh ("dumpsys package " + $pkg)
  if ($dump -match 'suspended=true') { return 'приостановлен' }
  $out2 = Sh ("pm list packages --user 0 " + $pkg)
  if ($out2 -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { return 'включён' }
  return 'нет'
}

# ColorOS на части пакетов (браузер, market, assistantscreen) отвечает
# "new state: default" и disable-user не срабатывает. Тогда приостанавливаем:
# pm suspend --user 0, откат — pm unsuspend.
function Disable-Package($pkg) {
  $r = Sh ("pm disable-user --user 0 " + $pkg)
  $state = Get-State $pkg
  if ($state -eq 'отключён') { return [pscustomobject]@{ Ok = $true; How = 'disable'; Out = '' } }
  Sh ("pm suspend --user 0 " + $pkg) | Out-Null
  $state = Get-State $pkg
  if ($state -eq 'приостановлен') { return [pscustomobject]@{ Ok = $true; How = 'suspend'; Out = '' } }
  return [pscustomobject]@{ Ok = $false; How = ''; Out = ($r -replace '\s+', ' ') }
}

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

if ($Restore) {
  Write-Step "Возвращаю приложения"
  $n = 0
  foreach ($p in $Targets) {
    Sh ("pm unsuspend --user 0 " + $p) | Out-Null
    Sh ("pm enable --user 0 " + $p) | Out-Null
    if ((Get-State $p) -eq 'включён') { $n++ }
  }
  Write-Ok ("включено обратно: " + $n)
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Write-Step "Отключаю китайские предустановленные приложения"
$off = 0
$skip = 0
foreach ($p in $Targets) {
  if ($Keep -contains $p) { continue }
  $state = Get-State $p
  if ($state -eq 'нет') { Write-Dim ("{0}: не установлен" -f $p); $skip++; continue }
  if ($state -eq 'отключён') { Write-Dim ("{0}: уже отключён" -f $p); $off++; continue }
  $res = Disable-Package $p
  if ($res.Ok) {
    $word = 'отключён'
    if ($res.How -eq 'suspend') { $word = 'приостановлен' }
    Write-Ok ("{0}: {1}" -f $p, $word)
    $off++
  } else {
    Write-Warn ("{0}: не поддался ({1})" -f $p, $res.Out)
  }
}

Write-Step "Что оставили"
foreach ($k in $Keep) { Write-Dim ("{0}: не трогаем" -f $k) }

Write-Step "Ускорение интерфейса"
Sh 'settings put global window_animation_scale 0.5' | Out-Null
Sh 'settings put global transition_animation_scale 0.5' | Out-Null
Sh 'settings put global animator_duration_scale 0.5' | Out-Null
$w = Sh 'settings get global window_animation_scale'
$t = Sh 'settings get global transition_animation_scale'
$a = Sh 'settings get global animator_duration_scale'
Write-Ok ("анимации: window={0}, transition={1}, animator={2}" -f $w, $t, $a)
Write-Dim "хочешь рывком быстрее — поставь эти ключи в 0, хочешь как было — 1"

Write-Host ""
Write-Ok ("отключено: {0}" -f $off)
Write-Dim "Вернуть всё: эта же команда с ключом -Restore"
Write-Dim "Перезагрузка не нужна, но после неё эффект заметнее"
Write-Host ""
Read-Host "Enter — закрыть"
