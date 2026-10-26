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

function Get-FocusLine {
  $win = Sh 'dumpsys window'
  $m = [regex]::Match($win, 'mCurrentFocus=Window\{[^}]*\}')
  if (-not $m.Success) { return '' }
  return ($m.Value -replace '\s+', ' ')
}

# Окно-оверлей помощника (TYPE_VOICE_INTERACTION, «как звонок») НЕ забирает фокус:
# на заблокированном экране фокус остаётся у шторки, хотя Gemini уже виден поверх.
# Поэтому одного mCurrentFocus мало — смотрим ещё список окон.
function Get-AssistantWindows {
  $win = Sh 'dumpsys window windows'
  $marks = @()
  foreach ($l in ($win -split "`n")) {
    if ($l -match 'Window\{' -and $l -match 'googlequicksearchbox|AssistPreview|VoiceInteraction|robin') {
      $marks += ($l -replace '\s+', ' ').Trim()
    }
  }
  return $marks
}

function Get-Wakefulness {
  $p = Sh 'dumpsys power'
  $m = [regex]::Match($p, 'mWakefulness=(\w+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return 'unknown'
}

# Перед каждой попыткой: включаем экран и убираем помощника, иначе вторая попытка
# проверяет уже не кнопку, а заставку. Именно из-за этого прошлый замер дал 0 из 5.
function Reset-Screen {
  $w = Get-Wakefulness
  if ($w -ne 'Awake') {
    Sh 'input keyevent 224' | Out-Null   # KEYCODE_WAKEUP
    Start-Sleep -Milliseconds 700
  }
  Sh 'input keyevent 4' | Out-Null       # BACK: закрыть меню/помощника, если открыт
  Sh 'input keyevent 3' | Out-Null       # HOME
  Start-Sleep -Milliseconds 700
  $f = Get-FocusLine
  if ($f -match 'keyguard|NotificationShade') { return $false }
  return $true
}

function Invoke-Attempt {
  param([string]$How, [int]$Seconds = 12)

  if (-not (Reset-Screen)) {
    return [pscustomobject]@{ Ok = $false; Secs = 0; Focus = ''; Seen = @(); Locked = $true; Hit = '' }
  }

  $before = Get-FocusLine
  Sh 'logcat -b events -c' | Out-Null

  if ($How -eq 'power') {
    Sh 'input keyevent --longpress 26' | Out-Null
  } else {
    $size = Get-ScreenSize
    $w = $size[0]; $h = $size[1]
    Sh ("input swipe {0} {1} {2} {3} 300" -f [int]($w * 0.02), ($h - 10), [int]($w * 0.5), [int]($h * 0.55)) | Out-Null
  }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $seen = @()
  $focus = ''
  $overlay = ''
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    Start-Sleep -Milliseconds 600
    $line = Get-FocusLine
    if ($line -and $seen -notcontains $line) { $seen += $line }
    if ($line -match 'googlequicksearchbox|apps\.bard') { $focus = $line; break }
    $marks = Get-AssistantWindows
    if ($marks.Count -gt 0) { $overlay = $marks[0]; break }
  }

  # Дублирующая улика из журнала событий: даже если окно уже ушло, факт фокуса останется
  $hit = ''
  $ev = Sh 'logcat -b events -d'
  foreach ($l in ($ev -split "`n")) {
    if ($l -match 'am_focused_activity' -and $l -match 'googlequicksearchbox') { $hit = ($l -replace '\s+', ' ').Trim(); break }
  }

  $ok = ($focus -ne '') -or ($hit -ne '') -or ($overlay -ne '')
  return [pscustomobject]@{ Ok = $ok; Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Focus = $focus; Overlay = $overlay; Seen = $seen; Locked = $false; Hit = $hit; Before = $before }
}

function Test-Assistant {
  param([int]$Tries = 3)

  Say-Step "Замер: чем реально открывается помощник"
  Say-Dim "телефон трогать не нужно, всё делается через adb"

  $w = Get-Wakefulness
  $f = Get-FocusLine
  Say-Dim ("экран: {0} | на экране: {1}" -f $w, $f)
  if ($f -match 'keyguard|NotificationShade') {
    Say-No "телефон заблокирован. Разблокируй его и запусти снова — со шторки замер не работает"
    return
  }

  $results = @()
  foreach ($how in @('power', 'gesture')) {
    $title = 'питание'
    if ($how -eq 'gesture') { $title = 'жест ' }
    $okCount = 0
    $secs = @()
    for ($i = 1; $i -le $Tries; $i++) {
      $r = Invoke-Attempt -How $how
      if ($r.Locked) {
        Say-No ("{0}, попытка {1}: телефон ушёл в блокировку — разблокируй и повтори" -f $title, $i)
        $results += [pscustomobject]@{ How = $how; Ok = $false; Secs = 0 }
        continue
      }
      if ($r.Ok) {
        $okCount++
        $secs += $r.Secs
        $via = 'окно'
        if ($r.Overlay) { $via = 'оверлей' }
        if ($r.Focus) { $via = 'фокус' }
        Write-Host ("     {0}, попытка {1}: ДА, {2} с ({3})" -f $title, $i, $r.Secs, $via) -ForegroundColor Green
      } else {
        $what = 'ничего'
        if ($r.Seen.Count -gt 0) { $what = $r.Seen[$r.Seen.Count - 1] }
        Write-Host ("     {0}, попытка {1}: нет. На экране: {2}" -f $title, $i, $what) -ForegroundColor Yellow
      }
      if ($r.Seen.Count -gt 1) { Say-Dim ("       фокус по ходу: " + ($r.Seen -join ' | ')) }
      $results += [pscustomobject]@{ How = $how; Ok = $r.Ok; Secs = $r.Secs }
    }

    Write-Host ""
    if ($okCount -gt 0) {
      $avg = [math]::Round((($secs | Measure-Object -Average).Average), 1)
      if ($how -eq 'power') { Say-Ok ("кнопка питания: {0} из {1}, среднее {2} с" -f $okCount, $Tries, $avg) }
      else { Say-Ok ("жест от нижнего угла: {0} из {1}, среднее {2} с" -f $okCount, $Tries, $avg) }
    } else {
      if ($how -eq 'power') { Say-No ("кнопка питания: 0 из {0} — ColorOS не отдаёт удержание питания помощнику" -f $Tries) }
      else { Say-No ("жест от нижнего угла: 0 из {0}" -f $Tries) }
    }
  }

  $powerOk = ($results | Where-Object { $_.How -eq 'power' -and $_.Ok }).Count
  $gestureOk = ($results | Where-Object { $_.How -eq 'gesture' -and $_.Ok }).Count
  if ($powerOk -eq 0 -and $gestureOk -gt 0) {
    Say-Dim "Вывод: кнопка питания на этой прошивке помощнику не отдаётся, рабочий путь — жест."
  }
  if ($powerOk -eq 0 -and $gestureOk -eq 0) {
    Say-Dim "Оба пути молчат. Проверь руками: зажми питание на 2 с и смахни от нижнего угла."
    Say-Dim "Если руками открывается, а тут нет — значит из shell запуск не проходит (docs 2.998)."
  }
  if ($gestureOk -gt 0 -and $gestureOk -lt $Tries) {
    Say-Dim "Жест срабатывает через раз: это холодный старт. Перезагрузи телефон и повтори -Test."
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
