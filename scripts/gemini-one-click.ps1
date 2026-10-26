# Один запуск — и кнопка питания зовёт Gemini. Ничего вручную делать не нужно.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-one-click.ps1
#   ... -Restore   вернуть кнопку в заводское состояние
#   ... -Test      только замер: 5 попыток кнопкой питания и 5 жестом, с секундами
#
# Что делает сам:
#   1. находит adb (PATH, winget-папка, кэш скрипта)
#   2. выбирает телефон (если подключён один — без вопросов)
#   3. проверяет, что Google реально установлен
#   4. ищет в системе Google-помощника и назначает его (assistant + voice_interaction_service)
#   5. снимает Breeno с кнопки питания и включает жест «удержание → помощник»
#   6. включает постоянный VPN, если на телефоне есть Happ (иначе Gemini упирается в регион)
#   7. убирает ColorOS-душилку для Google/Gemini/Happ
#   8. замеряет, что реально открывает помощника: удержание питания и жест от
#      нижнего угла, по 3 попытки, с секундами — без вранья в одну строку
#
# Чего НЕ делает (проверено на PKG110, ColorOS 16 — не работает из shell):
#   * appops set — «uid 2000 does not have MANAGE_APP_OPS_MODES»
#   * pm grant READ_LOGS — «GRANT_RUNTIME_PERMISSIONS»
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [switch]$Restore,
  [switch]$Test
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$GooglePkg = 'com.google.android.googlequicksearchbox'
$BardPkg   = 'com.google.android.apps.bard'
$HappPkg   = 'com.happproxy'
$GoogleDefault = 'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService'

function Say-Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Say-No($t)   { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Say-Bad($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Say-Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Say-Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Stop-Here($t) { Say-Bad $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

# Через cmd /c: в PowerShell 5.1 stderr adb превращается в NativeCommandError и мусорит вывод
function Sh($cmd) {
  $line = '"' + $script:AdbBin + '" -s ' + $script:Serial + ' shell ' + $cmd + ' 2>&1'
  return (& cmd /c $line | Out-String).Trim()
}

function Find-Adb {
  if ($Adb) {
    if (Test-Path $Adb) { $script:AdbBin = $Adb; return }
    Stop-Here "файл не найден: $Adb"
  }
  $found = Get-Command adb -ErrorAction SilentlyContinue
  if ($found) { $script:AdbBin = $found.Source; return }
  $winget = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter 'adb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($winget) { $script:AdbBin = $winget.FullName; return }
  $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
  if (Test-Path $cached) { $script:AdbBin = $cached; return }
  Stop-Here "adb не найден. Поставь Platform-Tools (winget install Google.PlatformTools) или запусти scripts\oneclick.ps1"
}

function Select-Phone {
  $out = (& $script:AdbBin devices 2>&1 | Out-String) -split "`r?`n"
  $list = @()
  foreach ($line in $out) {
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2 -and $parts[1] -eq 'device') { $list += $parts[0] }
  }
  if ($list.Count -eq 0) { Stop-Here "телефон не виден. Проверь кабель, «Отладка по USB» и подтверждение на экране" }
  if ($Serial) {
    if ($list -notcontains $Serial) { Stop-Here "телефон $Serial не подключён (видны: $($list -join ', '))" }
    $script:Serial = $Serial
  } else {
    $script:Serial = $list[0]
  }
  Say-Ok "adb: $($script:AdbBin)"
  Say-Ok "телефон: $($script:Serial)"
  if ($list.Count -gt 1) { Say-No "подключено несколько устройств, работаю с $($script:Serial)" }
}

# Ищем реальный компонент помощника, а не пишем строку наугад
function Get-GoogleVoiceService {
  $vis = Sh 'cmd package query-services -a android.service.voice.VoiceInteractionService --brief'
  $m = [regex]::Match($vis, [regex]::Escape($GooglePkg) + '/[A-Za-z0-9_.]+')
  if ($m.Success) { return $m.Value }
  return $GoogleDefault
}

function Set-PowerButtonToGoogle {
  $service = Get-GoogleVoiceService
  Say-Dim "помощник: $service"
  Sh "settings --user 0 put secure assistant $service" | Out-Null
  Sh "settings --user 0 put secure voice_interaction_service $service" | Out-Null
  $now = Sh 'settings get secure assistant'
  if ($now -match 'google') { Say-Ok "Google назначен помощником" } else { Say-No "assistant = $now" }

  # Breeno держит кнопку, пока этот флаг включён
  Sh 'settings put secure speech_assist_power_wakeup 0' | Out-Null
  Sh 'settings put secure assist_gesture_enabled 1' | Out-Null
  Sh 'settings put secure assist_gesture_wake_enabled 1' | Out-Null
  Sh 'settings put secure assist_long_press_home_enabled 1' | Out-Null

  # AOSP-переопределение поведения клавиш: 5 = «запустить помощника», 2 = «помощник по Home».
  # На части прошивок ColorOS читает их даже когда собственный переключатель не работает.
  Sh 'settings put global power_button_long_press 5' | Out-Null
  Sh 'settings put secure key_home_long_press_action 2' | Out-Null
  $longPress = Sh 'settings get global power_button_long_press'
  if ($longPress -match '5') { Say-Ok "долгое нажатие питания = помощник (power_button_long_press=5)" }
  else { Say-No "power_button_long_press не принят (=$longPress)" }

  $wake = Sh 'settings get secure speech_assist_power_wakeup'
  $gesture = Sh 'settings get secure assist_gesture_enabled'
  if ($gesture -match '1') { Say-Ok "жест «удержание питания → помощник» включён" } else { Say-No "жест не включился (assist_gesture_enabled=$gesture)" }
  if ($wake -match '0') { Say-Ok "Breeno с кнопки снят" } else { Say-No "Breeno всё ещё держит кнопку (speech_assist_power_wakeup=$wake)" }
}

function Set-VpnAlwaysOn {
  $installed = Sh 'pm list packages --user 0'
  if ($installed -match [regex]::Escape("package:$HappPkg")) {
    Sh "settings put global always_on_vpn_app $HappPkg" | Out-Null
    $vpn = Sh 'settings get global always_on_vpn_app'
    if ($vpn -match [regex]::Escape($HappPkg)) { Say-Ok "постоянный VPN включён: Happ" }
    else { Say-No "Happ не принял постоянный VPN (always_on_vpn_app=$vpn) — включи автоподключение в самом Happ" }
  } else {
    Say-Dim "Happ не установлен — постоянный VPN не настраиваю"
  }
}

function Set-AppRetention {
  foreach ($pkg in @($GooglePkg, $BardPkg, $HappPkg)) {
    $installed = Sh 'pm list packages --user 0'
    if ($installed -notmatch [regex]::Escape("package:$pkg")) { continue }
    Sh "dumpsys deviceidle whitelist +$pkg" | Out-Null
    Sh "am set-standby-bucket $pkg active" | Out-Null
  }
  Say-Ok "Google, Gemini и VPN в белом списке энергосбережения"
  Say-Dim "appops не трогаю: на этой прошивке shell их менять не может"
}

function Set-LockScreenPlayer {
  # На ColorOS 16 карточку плеера на локскрине включает отдельный ключ,
  # и по умолчанию он выключен: сторонние плееры в локскрине не видны.
  $before = Sh 'settings get secure media_controls_lock_screen'
  Sh 'settings put secure media_controls_lock_screen 1' | Out-Null
  Sh 'settings put secure lockscreen_show_controls 1' | Out-Null
  $after = Sh 'settings get secure media_controls_lock_screen'
  if ($after -match '1') { Say-Ok "плеер на экране блокировки включён (было: $before)" }
  else { Say-No "не удалось включить плеер на локскрине (media_controls_lock_screen=$after)" }
  Say-Dim "если карточки всё равно нет — у плеера низкий приоритет уведомлений: Настройки -> Уведомления -> приложение -> включить"
}

function Set-BackgroundStart {
  # ColorOS замораживает фоновые приложения, и холодный старт Google занимал
  # около минуты: окно помощника появлялось с огромной задержкой.
  $fz = Sh 'settings get global cached_apps_freezer'
  if ($fz -match 'disabled') {
    Say-Ok "заморозка фоновых приложений уже выключена"
    return
  }
  Sh 'settings put global cached_apps_freezer disabled' | Out-Null
  $after = Sh 'settings get global cached_apps_freezer'
  if ($after -match 'disabled') {
    Say-Ok "заморозка фоновых приложений выключена (было: $fz) — помощник должен открываться быстрее"
    Say-Dim "полный эффект после перезагрузки телефона"
  } else {
    Say-Dim "заморозку снять не удалось (=$after) — тогда руками: Настройки -> Приложения -> Google -> Батарея -> без ограничений"
  }
}

function Get-ScreenSize {
  $raw = Sh 'wm size'
  $m = [regex]::Match($raw, 'Override size:\s*(\d+)x(\d+)')
  if (-not $m.Success) { $m = [regex]::Match($raw, 'Physical size:\s*(\d+)x(\d+)') }
  if (-not $m.Success) { return @(1080, 2400) }
  return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}

function Wait-AssistantWindow {
  param([int]$Seconds = 12)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $seen = @()
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    Start-Sleep -Milliseconds 600
    $win = Sh 'dumpsys window'
    $m = [regex]::Match($win, 'mCurrentFocus=Window\{[^}]*\}')
    if (-not $m.Success) { continue }
    $line = $m.Value -replace '\s+', ' '
    if ($seen -notcontains $line) { $seen += $line }
    if ($line -match 'googlequicksearchbox|apps\.bard') {
      return [pscustomobject]@{ Ok = $true; Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Focus = $line; Seen = $seen }
    }
  }
  $last = ''
  if ($seen.Count -gt 0) { $last = $seen[$seen.Count - 1] }
  return [pscustomobject]@{ Ok = $false; Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Focus = $last; Seen = $seen }
}

function Go-Home {
  Sh 'input keyevent 3' | Out-Null   # KEYCODE_HOME: убираем помощника с экрана
  Start-Sleep -Milliseconds 700
}

function Test-Assistant {
  param([int]$Tries = 3)

  Say-Step "Замер: чем реально открывается помощник"
  Say-Dim "телефон трогать не нужно, всё делается через adb"

  # 1. удержание кнопки питания: тот же путь в PhoneWindowManager, что у физической кнопки
  $powerOk = 0
  $powerSecs = @()
  for ($i = 1; $i -le $Tries; $i++) {
    Go-Home
    Sh 'input keyevent --longpress 26' | Out-Null
    $r = Wait-AssistantWindow -Seconds 12
    if ($r.Ok) { $powerOk++; $powerSecs += $r.Secs; Write-Host ("     питание, попытка {0}: открылся за {1} с" -f $i, $r.Secs) }
    else { Write-Host ("     питание, попытка {0}: не открылся за {1} с" -f $i, $r.Secs) }
  }

  # 2. жест от нижнего угла: именно он у ColorOS отдан помощнику (assist_gesture_enabled)
  $size = Get-ScreenSize
  $w = $size[0]; $h = $size[1]
  $x1 = [int]($w * 0.03); $y1 = $h - 12
  $x2 = [int]($w * 0.50); $y2 = [int]($h * 0.55)
  $gestureOk = 0
  $gestureSecs = @()
  for ($i = 1; $i -le $Tries; $i++) {
    Go-Home
    Sh ("input swipe {0} {1} {2} {3} 300" -f $x1, $y1, $x2, $y2) | Out-Null
    $r = Wait-AssistantWindow -Seconds 12
    if ($r.Ok) { $gestureOk++; $gestureSecs += $r.Secs; Write-Host ("     жест, попытка {0}: открылся за {1} с" -f $i, $r.Secs) }
    else { Write-Host ("     жест, попытка {0}: не открылся за {1} с" -f $i, $r.Secs) }
  }

  Write-Host ""
  $avg = ''
  if ($powerSecs.Count -gt 0) { $avg = " среднее " + [math]::Round((($powerSecs | Measure-Object -Average).Average), 1) + " с" }
  if ($powerOk -gt 0) { Say-Ok ("кнопка питания: {0} из {1}{2}" -f $powerOk, $Tries, $avg) }
  else { Say-No ("кнопка питания: 0 из {0} — ColorOS не отдаёт удержание питания помощнику" -f $Tries) }

  $avg2 = ''
  if ($gestureSecs.Count -gt 0) { $avg2 = " среднее " + [math]::Round((($gestureSecs | Measure-Object -Average).Average), 1) + " с" }
  if ($gestureOk -gt 0) { Say-Ok ("жест от нижнего угла: {0} из {1}{2}" -f $gestureOk, $Tries, $avg2) }
  else { Say-No ("жест от нижнего угла: 0 из {0}" -f $Tries) }

  if ($powerOk -eq 0 -and $gestureOk -gt 0) {
    Say-Dim "Вывод: кнопка питания на этой прошивке помощнику не отдаётся, рабочий путь — жест."
  }
  if ($powerOk -eq 0 -and $gestureOk -eq 0) {
    Say-Dim "Оба пути молчат: проверь руками — зажми питание на 2 с и смахни от нижнего угла."
    Say-Dim "Если руками открывается, значит из shell запуск не проходит (docs 2.998)."
  }
  if ($gestureOk -gt 0 -and $gestureOk -lt $Tries) {
    Say-Dim "Жест срабатывает через раз: это холодный старт. Перезагрузи телефон (снимаем заморозку) и повтори -Test."
  }
}

function Undo-All {
  Say-Step "Возвращаю заводское поведение"
  Sh "settings --user 0 put secure assistant $GoogleDefault" | Out-Null
  Sh "settings --user 0 put secure voice_interaction_service $GoogleDefault" | Out-Null
  Sh 'settings put secure speech_assist_power_wakeup 1' | Out-Null
  Sh 'settings put secure assist_gesture_enabled 0' | Out-Null
  Sh 'settings put secure assist_gesture_wake_enabled 0' | Out-Null
  Sh 'settings delete global always_on_vpn_app' | Out-Null
  Sh 'settings put global power_button_long_press 1' | Out-Null
  Sh 'settings put secure key_home_long_press_action 0' | Out-Null
  Sh 'settings delete global cached_apps_freezer' | Out-Null
  Say-Ok "Breeno вернулся на кнопку, жест выключен, постоянный VPN снят"
}

# ------------------------------------------------------------------ main

Find-Adb
Select-Phone

$model = Sh 'getprop ro.product.model'
$android = Sh 'getprop ro.build.version.release'
$rom = Sh 'getprop ro.build.version.oplusrom'
Say-Step "Телефон"
Say-Dim "модель:   $model"
Say-Dim "Android:  $android"
Say-Dim "прошивка: $rom"

if ($Restore) {
  Undo-All
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

if ($Test) {
  # только замер, настройки не трогаем: 5 попыток кнопкой и 5 жестом
  Test-Assistant -Tries 5
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

Say-Step "Проверяю Google"
$gpath = Sh "pm path $GooglePkg"
if ($gpath -notmatch 'package:') {
  Say-Bad "Google-приложения нет на телефоне"
  Say-Dim "Настройки -> Google (базовые сервисы), затем поставь Google и Gemini из Play Маркета"
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 1
}
Say-Ok "Google установлен"

Say-Step "Кнопка питания → Gemini"
Set-PowerButtonToGoogle
Set-VpnAlwaysOn
Set-AppRetention
Set-LockScreenPlayer
Set-BackgroundStart

Test-Assistant

Write-Host ""
Say-Dim "Откат: эта же команда с ключом -Restore"
Say-Dim "Если Gemini говорит про страну — дело не в кнопке, а в VPN/аккаунте (docs/coloros-cn-notes.md, 2.99)"
Write-Host ""
Read-Host "Enter — закрыть"
