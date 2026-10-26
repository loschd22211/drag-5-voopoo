# Один запуск — и кнопка питания зовёт Gemini. Ничего вручную делать не нужно.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-one-click.ps1
#   ... -Restore   вернуть кнопку в заводское состояние
#
# Что делает сам:
#   1. находит adb (PATH, winget-папка, кэш скрипта)
#   2. выбирает телефон (если подключён один — без вопросов)
#   3. проверяет, что Google реально установлен
#   4. ищет в системе Google-помощника и назначает его (assistant + voice_interaction_service)
#   5. снимает Breeno с кнопки питания и включает жест «удержание → помощник»
#   6. включает постоянный VPN, если на телефоне есть Happ (иначе Gemini упирается в регион)
#   7. убирает ColorOS-душилку для Google/Gemini/Happ
#   8. сам «нажимает» кнопку и печатает вердикт: работает или почему нет
#
# Чего НЕ делает (проверено на PKG110, ColorOS 16 — не работает из shell):
#   * appops set — «uid 2000 does not have MANAGE_APP_OPS_MODES»
#   * pm grant READ_LOGS — «GRANT_RUNTIME_PERMISSIONS»
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

function Test-PowerButton {
  Say-Step "Проверка: «нажимаю» кнопку питания программно"
  Sh 'input keyevent KEYCODE_ASSIST' | Out-Null
  Start-Sleep -Seconds 5
  $win = Sh 'dumpsys window'
  $focus = ''
  $m = [regex]::Match($win, 'mCurrentFocus=Window\{[^}]*\}')
  if ($m.Success) { $focus = $m.Value -replace '\s+', ' ' }
  if (-not $focus) {
    $act = Sh 'dumpsys activity activities'
    $m2 = [regex]::Match($act, 'mResumedActivity[^\r\n]*')
    if ($m2.Success) { $focus = $m2.Value }
  }
  if (-not $focus) { Say-No "не смог прочитать, что на экране — посмотри глазами: открылся Gemini?"; return }

  Say-Dim $focus
  if ($focus -match 'googlequicksearchbox|apps\.bard') {
    Say-Ok "РАБОТАЕТ: помощник открылся"
    Say-Dim "Теперь зажми кнопку питания на телефоне на 2 секунды — должен открыться Gemini."
  } elseif ($focus -match 'systemui|globalactions') {
    Say-No "открылось меню выключения — прошивка не отдаёт кнопку помощнику"
    Say-Dim "Используй удержание нижней полосы жестов: assist_long_press_home_enabled=1 уже стоит."
  } else {
    Say-No "открылось другое приложение — смотри строку выше"
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

Test-PowerButton

Write-Host ""
Say-Dim "Откат: эта же команда с ключом -Restore"
Say-Dim "Если Gemini говорит про страну — дело не в кнопке, а в VPN/аккаунте (docs/coloros-cn-notes.md, 2.99)"
Write-Host ""
Read-Host "Enter — закрыть"
