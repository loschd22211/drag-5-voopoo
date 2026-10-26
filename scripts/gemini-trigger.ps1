# Установщик ColorGoogle: держишь кнопку питания — открывается Gemini (ColorOS, без root).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-trigger.ps1
#   ... -Restore   вернуть как было (остановить агент, вернуть assistant/voice из бэкапа)
#
# Что делает по шагам:
#   1. находит adb (или скачивает platform-tools)
#   2. находит телефон, делает бэкап текущих настроек в .\colorgoogle-backup
#   3. скачивает APK ColorGoogle нужной версии и сверяет SHA-256
#   4. ставит APK с -r -g (сразу с разрешениями)
#   5. выдаёт READ_LOGS, назначает Google помощником, включает оверлей и уведомления
#   6. просит один раз доделать три тумблера в приложении (это только руками)
#   7. запускает shell-агент по официальной инструкции проекта и проверяет статус
#
# Файл сохранён в UTF-8 с BOM (см. docs/windows-encoding.md).
# Внешний проект: https://github.com/joeyandu/ColorGoogle (GPL-3.0-only), не связан с Google/OPPO.

param(
  [string]$Adb = "",
  [string]$Serial = "",
  [string]$Version = "v16.3.0",
  [string]$ApkPath = "",
  [switch]$Restore,
  [switch]$SkipActivate
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$Pkg = 'dev.evoker.homeholdcts'
$GoogleService = 'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService'
$WorkDir = Join-Path $env:LOCALAPPDATA 'gemini-power-button'
$BackupDir = Join-Path (Get-Location) 'colorgoogle-backup'
$ApkName = "ColorGoogle-$($Version.TrimStart('v')).apk"
$RepoApi = 'https://api.github.com/repos/joeyandu/ColorGoogle/releases/tags/' + $Version

function Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Die($t)  { Err $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

function Sh($cmd) {
  (& $script:AdbBin "-s" $script:Serial "shell" $cmd 2>&1 | Out-String).Trim()
}

# ------------------------------------------------------------------ adb

function Resolve-Adb {
  if ($Adb) {
    if (Test-Path $Adb) { $script:AdbBin = $Adb; Ok "adb: $Adb"; return }
    Die "файл не найден: $Adb"
  }
  $inPath = Get-Command adb -ErrorAction SilentlyContinue
  if ($inPath) { $script:AdbBin = $inPath.Source; Ok "adb: $($inPath.Source)"; return }

  $cached = Join-Path $WorkDir 'platform-tools\adb.exe'
  if (Test-Path $cached) { $script:AdbBin = $cached; Ok "adb: $cached"; return }

  Step "adb не найден — качаю platform-tools от Google (~10 МБ)"
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $zip = Join-Path $WorkDir 'platform-tools.zip'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $WorkDir -Force
  } catch {
    Die "не удалось скачать platform-tools: $($_.Exception.Message)"
  }
  if (-not (Test-Path $cached)) { Die "в архиве нет adb.exe" }
  $script:AdbBin = $cached
  Ok "adb: $cached"
}

function Resolve-Device {
  $lines = (& $script:AdbBin devices 2>&1 | Out-String) -split "`r?`n"
  $ready = @()
  foreach ($line in $lines) {
    if ($line -match '^\s*$' -or $line -match 'List of devices') { continue }
    $p = $line -split '\s+'
    if ($p.Count -ge 2 -and $p[1] -eq 'device') { $ready += $p[0] }
  }
  if (-not $ready) {
    Err "телефон не виден"
    Dim "проверь: кабель, «Отладка по USB», окно «Разрешить отладку» на экране телефона"
    Die "без телефона дальше нельзя"
  }
  $script:Serial = if ($Serial) { $Serial } else { @($ready)[0] }
  if ($ready -notcontains $script:Serial) { Die "устройство $($script:Serial) не найдено в списке adb" }
  Ok "телефон: $script:Serial"
}

# ------------------------------------------------------------------ apk

function Get-Apk {
  if ($ApkPath) {
    if (-not (Test-Path $ApkPath)) { Die "APK не найден: $ApkPath" }
    Ok "использую готовый APK: $ApkPath"
    return $ApkPath
  }

  $target = Join-Path $WorkDir $ApkName
  if (Test-Path $target) {
    Ok "APK уже скачан: $target"
    return $target
  }

  Step "Скачиваю $ApkName из релиза $Version"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod $RepoApi -UseBasicParsing -Headers @{ 'User-Agent' = 'gemini-power-button' }
  } catch {
    Die "не удалось получить данные релиза: $($_.Exception.Message)"
  }
  $asset = $release.assets | Where-Object { $_.name -eq $ApkName } | Select-Object -First 1
  if (-not $asset) {
    $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
    Die "в релизе $Version нет $ApkName. Доступно: $names"
  }
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  try {
    Invoke-WebRequest $asset.browser_download_url -OutFile $target -UseBasicParsing
  } catch {
    Die "скачивание не удалось: $($_.Exception.Message)"
  }
  Ok ("скачано: {0:N1} МБ" -f ((Get-Item $target).Length / 1048576))

  # проверка контрольной суммы, если в релизе есть SHA256SUMS
  $sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
  if ($sums) {
    try {
      $text = (Invoke-WebRequest $sums.browser_download_url -UseBasicParsing).Content
      $line = ($text -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($ApkName) } | Select-Object -First 1)
      if ($line) {
        $expected = ($line -split '\s+')[0].ToLower()
        $actual = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
          Remove-Item $target -Force
          Die "контрольная сумма не совпала — файл удалён. Ожидалось $expected, получено $actual"
        }
        Ok "SHA-256 совпал"
      }
    } catch {
      Warn "не смог проверить SHA-256: $($_.Exception.Message)"
    }
  }
  return $target
}

# ------------------------------------------------------------------ backup

function Save-Backup {
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  $assistantFile = Join-Path $BackupDir 'assistant.txt'
  if (-not (Test-Path $assistantFile)) {
    Sh 'settings --user 0 get secure assistant' | Set-Content $assistantFile -Encoding UTF8
    Sh 'settings --user 0 get secure voice_interaction_service' | Set-Content (Join-Path $BackupDir 'voice-service.txt') -Encoding UTF8
    Sh 'dumpsys deviceidle whitelist' | Set-Content (Join-Path $BackupDir 'whitelist.txt') -Encoding UTF8
    Ok "бэкап текущих настроек: $BackupDir"
  } else {
    Dim "бэкап уже есть, не перезаписываю: $BackupDir"
  }
}

# ------------------------------------------------------------------ main

Resolve-Adb
Resolve-Device

$model = Sh 'getprop ro.product.model'
$android = Sh 'getprop ro.build.version.release'
$rom = Sh 'getprop ro.build.version.oplusrom'
Step "Телефон"
Dim "модель:   $model"
Dim "Android:  $android"
Dim "прошивка: $rom"

# --------------------------------------------------------------- restore

if ($Restore) {
  Step "Возвращаю как было"
  Sh "content call --uri content://$Pkg.desktopsearch --method stop" | Out-Null
  Ok "агент остановлен (если работал)"

  foreach ($pair in @(
      @{ F = 'assistant.txt'; K = 'assistant' },
      @{ F = 'voice-service.txt'; K = 'voice_interaction_service' }
    )) {
    $file = Join-Path $BackupDir $pair.F
    if (-not (Test-Path $file)) { Dim "$($pair.K): бэкапа нет, пропускаю"; continue }
    $value = (Get-Content $file -Raw).Trim()
    if (-not $value -or $value -eq 'null') {
      Sh "settings --user 0 delete secure $($pair.K)" | Out-Null
      Ok "$($pair.K): удалён (как было до установки)"
    } else {
      Sh "settings --user 0 put secure $($pair.K) $value" | Out-Null
      Ok "$($pair.K): восстановлен = $value"
    }
  }
  Dim ("Сам APK остаётся установленным. Удалить: {0} -s {1} uninstall {2}" -f $script:AdbBin, $script:Serial, $Pkg)
  Read-Host "Enter — закрыть"
  exit 0
}

# --------------------------------------------------------------- install

Save-Backup
$apk = Get-Apk

Step "Ставлю ColorGoogle"
$install = (& $script:AdbBin -s $script:Serial install -r -g $apk 2>&1 | Out-String).Trim()
if ($install -match 'Success') {
  Ok "установлено"
} elseif ($install -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
  Warn "уже стоит сборка с другой подписью (например, официальный MindTrigger)."
  Dim "Удалять автоматически нельзя — потеряются настройки. Реши сам:"
  Dim ("  {0} -s {1} uninstall {2}   — затем запусти скрипт снова" -f $script:AdbBin, $script:Serial, $Pkg)
  Die "остановился, чтобы ничего не сломать"
} elseif ($install -match 'INSTALL_FAILED_ALREADY_EXISTS|INSTALL_FAILED_VERSION_DOWNGRADE') {
  Warn $install
  Die "другой версии уже стоит — укажи нужную через -Version"
} else {
  Warn $install
  Die "установка не удалась"
}

Step "Разрешения и роль помощника"
$grant = Sh "pm grant $Pkg android.permission.READ_LOGS"
if ($grant -match 'Error|Exception') { Warn "READ_LOGS: $grant" } else { Ok "READ_LOGS выдан" }

Sh "settings --user 0 put secure assistant $GoogleService" | Out-Null
Sh "settings --user 0 put secure voice_interaction_service $GoogleService" | Out-Null
$curAss = Sh 'settings --user 0 get secure assistant'
$curVoi = Sh 'settings --user 0 get secure voice_interaction_service'
if ($curAss -match 'com\.google' -or $curVoi -match 'com\.google') { Ok "Google назначен помощником" }
else { Warn "прошивка не приняла assistant — кнопка может не сработать: $curAss / $curVoi" }

Sh "appops set $Pkg SYSTEM_ALERT_WINDOW allow" | Out-Null
Ok "«Поверх других приложений» разрешено"
Sh "pm grant $Pkg android.permission.POST_NOTIFICATIONS" | Out-Null
Ok "уведомления разрешены"
Sh "dumpsys deviceidle whitelist +$Pkg" | Out-Null
Ok "оптимизация батареи отключена для приложения"

Step "Открываю ColorGoogle на телефоне"
Sh "monkey -p $Pkg -c android.intent.category.LAUNCHER 1" | Out-Null
Ok "приложение запущено"

Write-Host ""
Write-Host "--- Три тумблера руками (30 секунд, без этого агент не стартует) ---" -ForegroundColor White
Write-Host "  1. Включи ГЛАВНЫЙ переключатель (Main switch / Enable service)."
Write-Host "  2. Включи 'Power button triggering' (триггер по кнопке питания)."
Write-Host "  3. Разреши уведомления, если приложение попросит."
Dim "Остальное (READ_LOGS, оверлей, батарея, роль помощника) уже выдано через adb."

if (-not $SkipActivate) {
  Write-Host ""
  Read-Host "Сделал три тумблера? Нажми Enter — запущу агент"

  Step "Запускаю shell-агент (официальный скрипт проекта)"
  $scriptLines = @(
    '#!/system/bin/sh',
    'set -eu',
    'state=$(content call --uri content://dev.evoker.homeholdcts.desktopsearch --method status --arg compact)',
    'case "$state" in',
    '  *runEnabled=true*) ;;',
    '  *runEnabled=false*) echo "Main switch is off; enable ColorGoogle before activation."; exit 2 ;;',
    '  *) echo "Cannot read main switch; activation refused."; exit 3 ;;',
    'esac',
    'if pidof colorgoogle-search >/dev/null; then',
    '  echo "Agent already exists; not stopping it. Check version and connection status below."',
    '  content call --uri content://dev.evoker.homeholdcts.desktopsearch --method status',
    '  exit 0',
    'fi',
    'apk=$(pm path --user 0 dev.evoker.homeholdcts | sed -n "s/^package://p" | head -n 1)',
    'test -r "$apk"',
    'export CLASSPATH="$apk"',
    'nohup setsid app_process / --nice-name=colorgoogle-search dev.evoker.homeholdcts.DesktopSearchAgent </dev/null >/data/local/tmp/colorgoogle-search.log 2>&1 &',
    'sleep 2',
    'content call --uri content://dev.evoker.homeholdcts.desktopsearch --method status'
  )
  $scriptText = ($scriptLines -join "`n") + "`n"
  $localScript = Join-Path $WorkDir 'colorgoogle-activate.sh'
  # переводы строк в unix-формат, иначе sh на телефоне ругнётся
  [IO.File]::WriteAllText($localScript, ($scriptText -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

  $push = (& $script:AdbBin -s $script:Serial push $localScript /data/local/tmp/colorgoogle-activate.sh 2>&1 | Out-String)
  if ($push -notmatch 'pushed|1 file') { Warn $push }
  $result = Sh 'sh /data/local/tmp/colorgoogle-activate.sh'
  Write-Host $result

  if ($result -match 'runEnabled=false|Main switch is off') {
    Warn "главный переключатель ещё выключен — включи его в приложении и запусти скрипт снова"
  } elseif ($result -match 'runEnabled=true|running|connected|status') {
    Ok "агент запущен"
  } else {
    Warn "проверь статус вручную: content call --uri content://$Pkg.desktopsearch --method status"
  }
}

Write-Host ""
Write-Host "--- Проверка ---" -ForegroundColor White
Dim "Закрой всё лишнее, выключи экран и зажми кнопку питания на 1–2 секунды."
Dim "Должен открыться Gemini. Если нет — смотри docs/coloros-cn-notes.md, раздел ColorGoogle."
Write-Host ""
Dim "Вернуть как было:  -Restore   (остановит агент и вернёт assistant/voice из бэкапа)"
Dim ("Удалить приложение:  {0} -s {1} uninstall {2}" -f $script:AdbBin, $script:Serial, $Pkg)
Write-Host ""
Read-Host "Enter — закрыть"
