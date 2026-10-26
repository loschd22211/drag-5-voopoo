# Одна команда для Windows: сам скачивает adb, сам находит телефон,
# сам ставит Google вместо Breeno и открывает нужный экран настроек.
# Ничего не спрашивает.
#
#   В PowerShell:
#       powershell -NoProfile -ExecutionPolicy Bypass -File scripts\oneclick.ps1
#   или двойной клик по scripts\oneclick.cmd
#
# ВАЖНО: файл сохранён в UTF-8 с BOM. Если BOM потеряется (например, при
# редактировании в старом блокноте), Windows PowerShell 5.1 прочитает кириллицу
# как ANSI и выдаст ошибки парсера. Восстановить: см. docs/windows-encoding.md

param([string]$Adb = "")

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$GoogleService = "com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService"
$CacheDir = Join-Path $env:LOCALAPPDATA "gemini-power-button"

function Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Die($t)  { Err $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

function Sh($cmd) {
  (& $script:AdbBin "-s" $script:Serial "shell" $cmd 2>&1 | Out-String).Trim()
}

# --------------------------------------------------------------- adb

function Find-Or-Install-Adb {
  if ($Adb) {
    if (Test-Path $Adb) { $script:AdbBin = $Adb; Ok "adb из параметра: $Adb"; return }
    Die "файл не найден: $Adb"
  }
  $inPath = Get-Command adb -ErrorAction SilentlyContinue
  if ($inPath) { $script:AdbBin = $inPath.Source; Ok "adb уже установлен: $($inPath.Source)"; return }

  $cached = Join-Path $CacheDir "platform-tools\adb.exe"
  if (Test-Path $cached) { $script:AdbBin = $cached; Ok "adb из кэша: $cached"; return }

  Step "adb не найден - качаю platform-tools от Google (~10 МБ)"
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  $zipPath = Join-Path $CacheDir "platform-tools.zip"
  $url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
  } catch {
    Err "не удалось скачать platform-tools: $($_.Exception.Message)"
    Die "проверь интернет либо поставь отсюда: https://developer.android.com/tools/releases/platform-tools"
  }
  try {
    Expand-Archive -Path $zipPath -DestinationPath $CacheDir -Force
  } catch {
    Die "не удалось распаковать архив: $($_.Exception.Message)"
  }
  if (-not (Test-Path $cached)) { Die "в архиве нет adb.exe" }
  $script:AdbBin = $cached
  Ok "adb готов: $cached"
}

# --------------------------------------------------------------- устройство

function Claim-Device {
  Step "Ищу телефон"
  $lines = (& $script:AdbBin devices 2>&1 | Out-String) -split "`r?`n"
  $ready = @()
  $notReady = @()
  foreach ($line in $lines) {
    if ($line -match '^\s*$' -or $line -match 'List of devices') { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -lt 2) { continue }
    if ($parts[1] -eq "device") { $ready += $parts[0] } else { $notReady += "$($parts[0]) ($($parts[1]))" }
  }
  if ($ready.Count -eq 0) {
    Err "Телефон не виден."
    if ($notReady.Count -gt 0) {
      Warn "вижу устройство, но оно не авторизовано: $($notReady -join ', ')"
      Warn "посмотри на экран телефона: окно «Разрешить отладку по USB?» -> Разрешить"
    } else {
      Warn "проверь по порядку:"
      Dim "1. кабель нормальный (не только для зарядки), воткнут напрямую в компьютер"
      Dim "2. Настройки -> Для разработчиков -> «Отладка по USB» ВКЛ"
      Dim "3. режим USB менять не нужно - подходит любой"
      Dim "4. если окно с отпечатком было и нажал «Отмена» - переподключи кабель"
    }
    Die "без телефона дальше нельзя"
  }
  $script:Serial = $ready[0]
  if ($ready.Count -gt 1) { Warn "подключено несколько устройств, беру первое: $($script:Serial)" }
  Ok "телефон на связи: $($script:Serial)"
}

# --------------------------------------------------------------- экраны настроек

function Get-RankedActivities {
  # Возвращает экраны настроек, отсортированные по полезности для кнопки питания.
  param([string]$PackagesDump)
  $noise = 'fuelgauge|PowerUsage|TimePower|PowerOffPrompt|PowerWakeUp|NotificationAssistant|OneHanded|Receiver$|Service$|Provider$|GuideActivity$'
  $priority = @(
    'PowerMenuSettingsActivity',
    'PowerButton',
    'ManageAssistActivity',
    'SpeechAssistantActivity',
    'AssistantSettingsActivity',
    'ButtonsAndGestures',
    'ButtonNavigationSettings',
    'ConvenienceTools',
    'DoubleTapPowerSettings',
    'OplusGoogleSettings'
  )

  $found = @()
  foreach ($pkg in @("com.oplus.settings", "com.coloros.settings", "com.android.settings")) {
    if ($PackagesDump -notmatch ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { continue }
    $dump = Sh "dumpsys package $pkg"
    $acts = [regex]::Matches($dump, '[a-z0-9_.]*settings/[A-Za-z0-9_.$]+') |
      ForEach-Object { $_.Value } | Sort-Object -Unique |
      Where-Object { $_ -match '(?i)power|button|assist|convenience|gesture' -and $_ -notmatch $noise }
    $found += $acts
  }

  $ranked = @()
  foreach ($pattern in $priority) {
    foreach ($act in $found) {
      if ($act -like "*$pattern*" -and $ranked -notcontains $act) { $ranked += $act }
    }
  }
  return $ranked
}

# --------------------------------------------------------------- main

Find-Or-Install-Adb
try { Dim ((& $script:AdbBin version 2>&1 | Out-String).Split("`n")[0].Trim()) } catch {}
Claim-Device

Step "1/6  Проверяю сборку телефона"
$model = Sh "getprop ro.product.model"
$android = Sh "getprop ro.build.version.release"
$rom = Sh "getprop ro.build.version.oplusrom"
if (-not $rom) { $rom = Sh "getprop ro.build.display.id" }
$region = Sh "getprop ro.build.region"
Dim "модель:   $model"
Dim "Android:  $android"
Dim "прошивка: $rom"
Dim "регион:   $region"
if ($model -match '^(PLK|PKG|PHK|PJD|PJF|PJH)') {
  Warn "это китайская сборка - на них Breeno и занимает место помощника"
}

Step "2/6  Что установлено из Google"
$packages = Sh "pm list packages"
$haveGoogleApp = $false
if ($packages -match 'package:com\.google\.android\.googlequicksearchbox(\r?\n|$)') { Ok "приложение Google"; $haveGoogleApp = $true } else { Warn "приложения Google НЕТ" }
if ($packages -match 'package:com\.google\.android\.gms(\r?\n|$)') { Ok "Google Play services" } else { Warn "Google Play services НЕТ" }
if ($packages -match 'package:com\.google\.android\.apps\.bard(\r?\n|$)') { Ok "Gemini" } else { Warn "Gemini НЕТ (без него кнопка позовёт старый Ассистент)" }
if ($packages -match 'package:com\.oplus\.breeno') { Warn "найден Breeno - сейчас он перехватывает кнопку" }

Step "3/6  Ищу голосовой сервис Google на устройстве"
$component = ""
$m = [regex]::Match(
  (Sh "cmd package query-services -a android.service.voice.VoiceInteractionService --brief"),
  '(com\.google[A-Za-z0-9_.]*/[A-Za-z0-9_.$]*VoiceInteractionService)'
)
if ($m.Success) { $component = $m.Groups[1].Value }
if (-not $component) {
  $component = $GoogleService
  Warn "прошивка не отдала список - беру стандартный компонент"
}
Ok "компонент: $component"

Step "4/6  Назначаю Google цифровым помощником (вместо Breeno)"
Sh "settings put secure assistant $component" | Out-Null
Sh "settings put secure voice_interaction_service $component" | Out-Null
$afterAss = Sh "settings get secure assistant"
$afterVoi = Sh "settings get secure voice_interaction_service"
Dim "assistant:                 $afterAss"
Dim "voice_interaction_service: $afterVoi"
$applied = ($afterAss -eq $component) -or ($afterVoi -eq $component)

Step "5/6  Проверяю, что ассистент запускается"
$probe = Sh "am start -a android.intent.action.VOICE_COMMAND"
if ($probe -match '(?i)error|unable to resolve') {
  Warn "команда запуска не сработала - это нормально, если телефон заблокирован"
} else {
  Ok "команда запуска ушла - глянь на экран телефона"
}

Step "6/6  Итог"
if ($applied -and $haveGoogleApp) {
  Ok "Google назначен помощником. Зажми кнопку питания на 0,5 секунды и проверь."
} elseif (-not $haveGoogleApp) {
  Err "Сначала поставь приложение Google и Gemini (Play Маркет), иначе назначать нечего."
  Dim "На китайской прошивке сначала: Настройки -> Система и обновления -> Настройки Google -> включить GMS"
} else {
  Err "Прошивка не приняла настройку - она защищает выбор помощника, adb тут не поможет."
}

Step "6/6+  Экраны настроек, которые есть на телефоне"
$ranked = Get-RankedActivities -PackagesDump $packages
if ($ranked.Count -eq 0) {
  Sh "am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS" | Out-Null
  Ok "открыл «Приложения по умолчанию» на телефоне"
} else {
  for ($i = 0; $i -lt [Math]::Min(6, $ranked.Count); $i++) {
    if ($i -eq 0) { Write-Host "     * " -ForegroundColor Green -NoNewline; Write-Host $ranked[$i] }
    else { Dim "$($i + 1). $($ranked[$i])" }
  }
  Sh "am start -n '$($ranked[0])'" | Out-Null
  Ok "открыл на телефоне: $($ranked[0])"
  Dim "там переключи на «Цифровой помощник» (Digital assistant), если есть выбор"
}

if ($ranked.Count -gt 1) {
  Write-Host ""
  Dim "если открылся не тот экран — вставь в PowerShell нужную строку:"
  for ($i = 0; $i -lt [Math]::Min(3, $ranked.Count); $i++) {
    Dim "& '$script:AdbBin' -s $script:Serial shell am start -n '$($ranked[$i])'"
  }
}

Write-Host ""
Write-Host "--- Готово ---" -ForegroundColor White
if (-not $applied) {
  Dim "Если экран с кнопкой питания не помог - остаётся путь без root:"
  Dim "1) Play Маркет -> Activity Launcher"
  Dim "2) в нём в поиске: assistantguidedialog -> запустить -> Set"
  Dim "3) зажать кнопку питания"
  Dim "подробнее: docs/coloros-cn-notes.md"
}
Dim "Режим USB менять не нужно. Отключить отладку потом: Настройки -> Для разработчиков."
Write-Host ""
Read-Host "Enter — закрыть"
