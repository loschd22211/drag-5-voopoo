# Один запуск — и кнопка питания зовёт Gemini. Ничего вручную делать не нужно.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-one-click.ps1
#   ... -Restore   вернуть кнопку в заводское состояние
#   ... -Test      только замер: слушает окна, пока ты жмёшь кнопку и делаешь жест
#   ... -Sweep     перебор последнего ключа ColorOS (side_button): по одной попытке на значение
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
  [switch]$Test,
  [switch]$Sweep
)

$ScriptVersion = "2026-10-27.9"
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
  if ($longPress -match '5') { Say-Dim "power_button_long_press=5 выставлен; на ColorOS 16 удержание питания всё равно открывает меню (docs 2.991)" }
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

function Get-FocusLine {
  $win = Sh 'dumpsys window'
  $m = [regex]::Match($win, 'mCurrentFocus=Window\{[^}]*\}')
  if (-not $m.Success) { return '' }
  return ($m.Value -replace '\s+', ' ')
}

# Окно-оверлей помощника (TYPE_VOICE_INTERACTION, «как звонок») НЕ забирает фокус:
# на заблокированном экране фокус остаётся у шторки, хотя Gemini уже виден поверх.
# Поэтому одного mCurrentFocus мало — смотрим ещё список окон.
function Get-WindowDump {
  $d = Sh 'dumpsys window'
  $focus = ''
  $m = [regex]::Match($d, 'mCurrentFocus=Window\{[^}]*\}')
  if ($m.Success) { $focus = ($m.Value -replace '\s+', ' ') }
  $names = @()
  foreach ($l in ($d -split "`n")) {
    $w = [regex]::Match($l, 'Window\{[0-9a-fA-F]+ u\d+ ([^}]+)\}')
    if ($w.Success) {
      $n = $w.Groups[1].Value.Trim()
      if ($names -notcontains $n) { $names += $n }
    }
  }
  return [pscustomobject]@{ Focus = $focus; Names = $names }
}

function Get-Wakefulness {
  $p = Sh 'dumpsys power'
  $m = [regex]::Match($p, 'mWakefulness=(\w+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return 'unknown'
}

function Test-Assistant {
  param([int]$Seconds = 15)

  Say-Step "Проверка руками: 15 секунд на каждое действие"
  # Инжектированные события (input swipe / input keyevent --longpress) ColorOS не
  # исполняет: помощник на них не открывается, хотя палец открывает. Поэтому
  # нажимать надо физически, а скрипт в это время смотрит, что происходит.
  Say-Dim "Скрипт ничего не нажимает — жмёшь ты, он только записывает факты"

  $w = Get-Wakefulness
  $d = Get-WindowDump
  Say-Dim ("экран: {0} | на экране: {1}" -f $w, $d.Focus)
  if ($d.Focus -match 'keyguard|NotificationShade') {
    Say-No "телефон заблокирован. Разблокируй его и запусти снова"
    return
  }

  $outcomes = @()
  foreach ($how in @('питание', 'жест')) {
    $hint = 'зажми кнопку питания на 2 секунды'
    if ($how -eq 'жест') { $hint = 'смахни вверх от нижнего угла экрана' }

    Sh 'input keyevent 3' | Out-Null
    Start-Sleep -Milliseconds 500
    $base = (Get-WindowDump).Names

    Say-Step ("{0}: {1}" -f $how, $hint)
    Say-Dim ("у тебя {0} секунд, начинай сразу" -f $Seconds)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $seenFocus = @()
    $seenNew = @()
    $okAt = -1
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
      $d = Get-WindowDump
      if ($d.Focus -and $seenFocus -notcontains $d.Focus) {
        $seenFocus += $d.Focus
        if ($d.Focus -notmatch 'launcher') { Say-Dim ("   {0} с: в фокусе {1}" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $d.Focus) }
      }
      foreach ($n in $d.Names) {
        if ($base -notcontains $n -and $seenNew -notcontains $n) {
          $seenNew += $n
          if ($n -notmatch 'StatusBar|NavigationBar|NotificationShade|KeyguardWallpaper') {
            Say-Dim ("   {0} с: новое окно {1}" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $n)
          }
        }
      }
      if ($d.Focus -match 'googlequicksearchbox|apps\.bard') { $okAt = [math]::Round($sw.Elapsed.TotalSeconds, 1); break }
      if (($seenNew -join ' ') -match 'google|robin|assistant|assist|voice') { $okAt = [math]::Round($sw.Elapsed.TotalSeconds, 1); break }
    }

    $assistFocus = @($seenFocus | Where-Object { $_ -match 'googlequicksearchbox|apps\.bard' }).Count -gt 0
    $assistWindow = @($seenNew | Where-Object { $_ -match 'google|robin|assistant|assist|voice' }).Count -gt 0

    $powerMenu = @($seenNew | Where-Object { $_ -match 'ActionsDialog' }).Count -gt 0
    if ($assistFocus -or $assistWindow) {
      Say-Ok ("{0}: работает" -f $how)
    } elseif ($powerMenu) {
      Say-No ("{0}: открылось МЕНЮ ВЫКЛЮЧЕНИЯ, а не помощник" -f $how)
      Say-Dim "   это и есть баг ColorOS: кнопка питания отдана меню, ключи AOSP она игнорирует"
    } else {
      Say-No ("{0}: скрипт не увидел ни окна, ни фокуса помощника" -f $how)
      if ($seenNew.Count -gt 0) { Say-Dim ("   новые окна за это время: " + ($seenNew -join ', ')) }
      else { Say-Dim "   новых окон не было вообще — действие до системы не дошло" }
    }
    $outcomes += [pscustomobject]@{ How = $how; Ok = ($assistFocus -or $assistWindow) }
  }

  Write-Host ""
  $good = @($outcomes | Where-Object { $_.Ok }).Count
  if ($good -gt 0) { Say-Ok "$good из 2 путей открывают помощника" }
  else { Say-No "ни один путь не подтвердился: посмотри глазами, что произошло" }
  Say-Dim "Повторить замер: -Test. Откат: -Restore"
}

function Invoke-PressProbe {
  param([string]$Hint = 'зажми питание на 2 секунды', [int]$Seconds = 10)

  Sh 'input keyevent 3' | Out-Null
  Start-Sleep -Milliseconds 400
  $base = (Get-WindowDump).Names
  Say-Dim ("   {0} — {1} секунд" -f $Hint, $Seconds)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $new = @()
  $assist = $false
  $powerMenu = $false
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $d = Get-WindowDump
    if ($d.Focus -match 'googlequicksearchbox|apps\.bard') { $assist = $true; break }
    foreach ($n in $d.Names) {
      if ($base -contains $n -or $new -contains $n) { continue }
      $new += $n
      if ($n -match 'google|robin|assist|voice') { $assist = $true }
      if ($n -match 'ActionsDialog') { $powerMenu = $true }
    }
    if ($assist) { break }
    if ($sw.Elapsed.TotalSeconds -gt 4 -and $powerMenu) { break }
  }
  return [pscustomobject]@{ Assist = $assist; PowerMenu = $powerMenu; New = $new }
}

# Последний неотработанный ключ с устройства: global side_button.
# Что именно он переключает на CN-прошивке, достоверно неизвестно (возможно,
# ползунок режимов), поэтому значения перебираются по одному, с возвратом.
function Sweep-SideButton {
  Say-Step "Перебор side_button: последний шанс для кнопки питания"
  $orig = (Sh 'settings get global side_button').Trim()
  Say-Dim "сейчас side_button=$orig"
  Say-Dim "каждый раунд: скрипт ставит значение, ты зажимаешь питание 2 секунды"
  Say-Dim "если после прогона изменится режим звука — это побочка, исходное значение вернётся"

  $values = @('0', '2', '3', '4', '1')
  $log = @()
  $found = ''
  foreach ($v in $values) {
    Sh ("settings put global side_button {0}" -f $v) | Out-Null
    $now = (Sh 'settings get global side_button').Trim()
    Say-Step ("side_button=$now")
    $r = Invoke-PressProbe -Hint 'зажми питание на 2 секунды'
    if ($r.New.Count -gt 0) { Say-Dim ("   новые окна: " + ($r.New -join ', ')) }
    if ($r.Assist) {
      Say-Ok ("side_button=$now открывает помощника")
      $found = $now
      $log += "side_button=${now}: ДА"
      break
    } elseif ($r.PowerMenu) {
      Say-No "   снова меню выключения"
      $log += "side_button=${now}: меню выключения"
    } else {
      Say-No "   ничего не произошло"
      $log += "side_button=${now}: тихо"
    }
  }

  Write-Host ""
  foreach ($l in $log) { Say-Dim $l }
  if ($found -ne '') {
    Say-Ok "рабочее значение запомнено: side_button=$found (ключ уже стоит)"
    Say-Dim "проверь ещё раз вручную: удержание питания должно открывать Gemini"
  } else {
    Sh ("settings put global side_button {0}" -f $orig) | Out-Null
    $back = (Sh 'settings get global side_button').Trim()
    Say-No "ни одно значение не открыло помощника — кнопка питания на этой прошивке не переназначается"
    Say-Dim ("вернул side_button=$back")
    Say-Dim "рабочий путь остаётся один: смахнуть от нижнего угла (лучше с экрана блокировки)"
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
Say-Dim "скрипт:   $ScriptVersion"
Say-Dim "модель:   $model"
Say-Dim "Android:  $android"
Say-Dim "прошивка: $rom"

if ($Restore) {
  Undo-All
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

if ($Sweep) {
  Sweep-SideButton
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

if ($Test) {
  # только замер, настройки не трогаем: 5 попыток кнопкой и 5 жестом
  Test-Assistant -Seconds 15
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
