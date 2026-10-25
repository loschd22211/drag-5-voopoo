# CLI-версия для Windows (PowerShell 5.1+).
#
#   .\scripts\adb-gemini.ps1
#   .\scripts\adb-gemini.ps1 -Serial R5CT12345678
#   .\scripts\adb-gemini.ps1 -Adb "C:\platform-tools\adb.exe"

param(
  [string]$Serial = "",
  [string]$Adb = "adb",
  [switch]$Yes
)

$ErrorActionPreference = "Continue"

function Say($t) { Write-Host $t }
function Ok($t) { Write-Host "OK  " -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host "!   " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err($t) { Write-Host "X   " -ForegroundColor Red -NoNewline; Write-Host $t }
function Dim($t) { Write-Host $t -ForegroundColor DarkGray }
function Hr { Write-Host ("-" * 56) }

function AskYes($question) {
  if ($Yes) { return $true }
  $answer = Read-Host "$question [y/N]"
  return ($answer -match '^(y|yes|д|да)$')
}

function A($arguments) {
  & $Adb "-s" $script:Serial @arguments 2>&1 | Out-String
}

function Sh($cmd) {
  (& $Adb "-s" $script:Serial "shell" $cmd 2>&1 | Out-String).Trim()
}

# --- проверка adb ---
try {
  $version = (& $Adb version 2>&1 | Out-String)
  Dim ($version.Split("`n")[0].Trim())
} catch {
  Err "adb не найден. Поставь platform-tools и добавь в PATH, либо укажи -Adb 'C:\platform-tools\adb.exe'"
  exit 1
}

# --- выбор устройства ---
if (-not $Serial) {
  $devices = (& $Adb devices | Select-String -Pattern "^\S+\s+device$" | ForEach-Object { ($_ -split "\s+")[0] })
  if (-not $devices) {
    Err "Ни одного телефона в режиме device. Проверь кабель, «Отладка по USB» и подтверждение отпечатка на экране."
    & $Adb devices -l
    exit 1
  }
  $script:Serial = @($devices)[0]
  if (@($devices).Count -gt 1) { Warn "Подключено несколько устройств, беру первое: $($script:Serial)" }
} else {
  $script:Serial = $Serial
}

Hr
Say "Устройство: $($script:Serial)"
$model = Sh "getprop ro.product.model"
$android = Sh "getprop ro.build.version.release"
$rom = Sh "getprop ro.build.version.oplusrom"
if (-not $rom) { $rom = Sh "getprop ro.build.display.id" }
Say "  модель:   $model"
Say "  Android:  $android"
Say "  прошивка: $rom"
if ($model -match '^(PLK|PKG|PHK|PJD)') {
  Warn "Похоже на китайскую сборку — пункт в настройках может не работать, это норма."
}

Hr
Say "Проверяю Google-компоненты…"
$packages = Sh "pm list packages"
foreach ($p in @(
    "com.google.android.gms",
    "com.google.android.googlequicksearchbox",
    "com.google.android.apps.bard",
    "com.android.vending"
  )) {
  if ($packages -match ("package:" + [regex]::Escape($p) + "(\r?\n|$)")) { Ok $p } else { Warn "$p — НЕТ" }
}

Hr
Say "Текущий помощник:"
$curVoi = Sh "settings get secure voice_interaction_service"
$curAss = Sh "settings get secure assistant"
if (-not $curAss -or $curAss -eq "null") { $curAss = "<не задан>" }
if (-not $curVoi -or $curVoi -eq "null") { $curVoi = "<не задан>" }
Say "  assistant:                 $curAss"
Say "  voice_interaction_service: $curVoi"

Hr
Say "Ищу голосовые сервисы Google…"
$services = Sh "cmd package query-services -a android.service.voice.VoiceInteractionService --brief"
if ($services -notmatch '/') {
  $services = "com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService"
  Dim "запрос сервисов не поддержан прошивкой, беру известный компонент"
}
($services -split "`n") | Where-Object { $_ -match '^com\.' } | ForEach-Object { Say "  $($_.Trim())" }

$match = [regex]::Match($services, '(com\.google[A-Za-z0-9_.]*/[A-Za-z0-9_.$]*VoiceInteractionService)')
if (-not $match.Success) {
  Err "Не нашёл компонент Google-помощника. Установлены ли приложение Google и Gemini?"
  exit 1
}
$component = $match.Groups[1].Value
Ok "Компонент: $component"

Hr
if (AskYes "Назначить его цифровым помощником по умолчанию?") {
  Sh "settings put secure assistant $component" | Out-Null
  Sh "settings put secure voice_interaction_service $component" | Out-Null
  $afterAss = Sh "settings get secure assistant"
  $afterVoi = Sh "settings get secure voice_interaction_service"
  Say "  assistant:                 $afterAss"
  Say "  voice_interaction_service: $afterVoi"
  if ($afterAss -eq $component -or $afterVoi -eq $component) {
    Ok "Применилось. Зажми кнопку питания на телефоне (около 0.5 с)."
  } else {
    Warn "Система не приняла значение (прошивка защищает настройку)."
    Warn "Используй экраны ниже + Activity Launcher / MiCTS — см. docs/coloros-cn-notes.md"
  }
}

Hr
Say "Экраны настроек, связанные с кнопкой питания:"
foreach ($pkg in @("com.oplus.settings", "com.coloros.settings", "com.android.settings")) {
  if ($packages -notmatch ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { continue }
  $dump = Sh "dumpsys package $pkg"
  [regex]::Matches($dump, [regex]::Escape($pkg) + '/[A-Za-z0-9_.$]+') |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique |
    Where-Object { $_ -match '(?i)power|button|assist|convenience|google' } |
    ForEach-Object { Say "  $_" }
}

Hr
if (AskYes "Открыть на телефоне «Приложения по умолчанию»?") {
  Sh "am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS" | Out-Null
  Ok "команда отправлена"
}

if (AskYes "Проверить запуск ассистента (телефон должен быть разблокирован)?") {
  $out = Sh "am start -a android.intent.action.VOICE_COMMAND"
  if ($out -match '(?i)error|unable') { Err "ассистент не запустился: $out" } else { Ok "команда ушла — смотри на экран телефона" }
}

Hr
Dim "Готово. Если настройка не держится — docs/coloros-cn-notes.md"
