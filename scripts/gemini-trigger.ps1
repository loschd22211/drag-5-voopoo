# Установщик ColorGoogle: держишь кнопку питания — открывается Gemini (ColorOS, без root).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-trigger.ps1
#   ... -Restore   вернуть как было (остановить агент, вернуть assistant/voice из бэкапа)
#   ... -Status    ничего не менять: показать состояние приложения, агента и READ_LOGS
#
# Что делает по шагам:
#   1. находит adb (или скачивает platform-tools)
#   2. находит телефон, делает бэкап текущих настроек в .\colorgoogle-backup
#   3. скачивает APK ColorGoogle по прямой ссылке (GitHub API только как резерв)
#      и сверяет SHA-256, если доступен SHA256SUMS
#   4. ставит APK с -r -g (сразу с разрешениями)
#   5. выдаёт READ_LOGS через app-op (pm grant на новых Android из shell не проходит),
#      назначает Google помощником, включает оверлей и уведомления
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
  [switch]$Status,
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
  # Через cmd /c: в PowerShell 5.1 stderr нативной программы превращается в
  # NativeCommandError и засоряет вывод (и $Error) — а нам нужен просто текст.
  $line = '"' + $script:AdbBin + '" -s ' + $script:Serial + ' shell ' + $cmd + ' 2>&1'
  $out = & cmd /c $line | Out-String
  return $out.Trim()
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
    if (-not (Test-Path $ApkPath -PathType Leaf)) { Die "APK не найден: $ApkPath" }
    Ok "использую готовый APK: $ApkPath"
    return (Resolve-Path $ApkPath).Path
  }

  # отдельная папка: никогда не работаем с путём, если имя файла не определилось
  $apkDir = Join-Path $WorkDir 'apk'
  New-Item -ItemType Directory -Force -Path $apkDir | Out-Null
  $target = Join-Path $apkDir $ApkName

  if ((Test-Path $target -PathType Leaf) -and ((Get-Item $target).Length -gt 10000000)) {
    Ok "APK уже скачан: $target"
    return $target
  }

  # 1) прямая ссылка на файл в релизе — не требует GitHub API и не упирается в лимиты
  $directUrl = "https://github.com/joeyandu/ColorGoogle/releases/download/$Version/$ApkName"
  # 2) API — только как резерв, у него лимит 60 запросов в час на IP
  $urls = @($directUrl)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod $RepoApi -UseBasicParsing -Headers @{ 'User-Agent' = 'gemini-power-button' }
    foreach ($asset in $release.assets) {
      if ($asset.name -eq $ApkName -and $asset.browser_download_url) { $urls += $asset.browser_download_url }
      if ($asset.name -eq 'SHA256SUMS') { $script:SumsUrl = $asset.browser_download_url }
    }
    if (-not $script:SumsUrl) {
      $script:SumsUrl = "https://github.com/joeyandu/ColorGoogle/releases/download/$Version/SHA256SUMS"
    }
  } catch {
    Warn "GitHub API недоступен ($($_.Exception.Message)) — качаю по прямой ссылке"
    $script:SumsUrl = "https://github.com/joeyandu/ColorGoogle/releases/download/$Version/SHA256SUMS"
  }

  Step "Скачиваю $ApkName"
  $downloaded = $false
  foreach ($url in $urls) {
    try {
      Invoke-WebRequest $url -OutFile $target -UseBasicParsing
      if ((Test-Path $target -PathType Leaf) -and ((Get-Item $target).Length -gt 10000000)) { $downloaded = $true; break }
      Warn "файл подозрительно маленький, пробую другой адрес"
    } catch {
      Warn "не вышло: $($_.Exception.Message)"
    }
  }
  if (-not $downloaded) {
    # последний шанс — curl.exe, он есть в Windows 10/11
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
      Step "Пробую curl.exe"
      & curl.exe -L --retry 2 --max-time 300 -o $target $directUrl | Out-Null
      if ((Test-Path $target -PathType Leaf) -and ((Get-Item $target).Length -gt 10000000)) { $downloaded = $true }
    }
  }
  if (-not $downloaded) {
    Err "APK не скачался."
    Dim "Скачай вручную в браузере:"
    Dim $directUrl
    Dim "и запусти:  -ApkPath `"$env:USERPROFILE\Downloads\$ApkName`""
    Die "без файла дальше нельзя"
  }
  Ok ("скачано: {0:N1} МБ" -f ((Get-Item $target).Length / 1048576))

  # проверка контрольной суммы, если доступен SHA256SUMS
  if ($script:SumsUrl) {
    try {
      $text = (Invoke-WebRequest $script:SumsUrl -UseBasicParsing).Content
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

function Get-ReadLogsState {
  $op = $script:ReadLogsOp
  if (-not $op) { $op = 'android:read_logs' }
  $out = Sh "appops get $Pkg $op"
  if ($out -match 'Unknown|Error') { $out = Sh "cmd appops get $Pkg READ_LOGS" }
  return $out
}

function Set-ReadLogsAllowed {
  # На разных сборках ColorOS операция называется по-разному, а `appops` и
  # `cmd appops` разбирают строку по-своему. Пробуем все варианты по очереди.
  $forms = @(
    @{ Set = "cmd appops set $Pkg READ_LOGS allow";   Get = "cmd appops get $Pkg READ_LOGS" },
    @{ Set = "appops set $Pkg android:read_logs allow"; Get = "appops get $Pkg android:read_logs" },
    @{ Set = "appops set $Pkg READ_LOGS allow";         Get = "appops get $Pkg READ_LOGS" }
  )
  foreach ($f in $forms) {
    $null = Sh $f.Set
    $check = Sh $f.Get
    if ($check -match 'allow' -and $check -notmatch 'Unknown|Error') {
      $script:ReadLogsOp = ($f.Set -replace '^\S+ appops set \S+ ', '' -replace ' allow$', '')
      return $true
    }
  }
  return $false
}

function Show-State {
  Step "Состояние ColorGoogle"
  $path = Sh "pm path $Pkg"
  if (-not $path) {
    Warn "приложение не установлено"
    return
  }
  $apkLine = ($path -split "`n" | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
  if ($apkLine) { Dim ("apk: " + ($apkLine -replace '^\s*package:', '')) }
  $readLogs = Get-ReadLogsState
  if ($readLogs -match ': allow') { Ok "READ_LOGS: разрешён (appops)" }
  else { Warn "READ_LOGS: $readLogs" }

  $raw = Sh "content call --uri content://$Pkg.desktopsearch --method status"
  Dim "ответ провайдера:"
  Write-Host $raw

  if ($raw -match 'runEnabled=(true|false)') {
    $run = $Matches[1]
  } else {
    # провайдер не ответил — дальше гадать бессмысленно, показываем как есть
    if ($raw -match 'ADB shell required') {
      Warn "adb работает не как shell (uid 2000) — приложение отказывает. Перезапусти adb server: adb kill-server; adb start-server"
    } elseif ($raw -match 'SecurityException|permission') {
      Warn "нет доступа к провайдеру — обычно значит, что adb-сессия без разрешения DUMP"
    } else {
      Warn "главный переключатель не читается"
      Dim "1. Открой ColorGoogle на телефоне вручную (не через скрипт)."
      Dim "2. Включи самый верхний переключатель — главный (Main switch / Enable service)."
      Dim "3. Вернись сюда и запусти:  -Status"
    }
    return
  }

  if ($run -eq 'true') { Ok "главный переключатель: включён" }
  else {
    Warn "главный переключатель: ВЫКЛЮЧЕН"
    Dim "Открой приложение и включи его — без этого агент не стартует."
    return
  }

  if ($raw -match 'agentConnected=true') { Ok "агент подключён" }
  else { Warn "агент не запущен (нужен шаг активации)" }

  $agentPid = Sh 'pidof colorgoogle-search'
  if ($agentPid) { Dim "процесс агента: $agentPid" } else { Dim "процесса colorgoogle-search нет" }
  if ($raw -match 'lifecycle=([A-Z]+)') { Dim "lifecycle: $($Matches[1])" }
  if ($raw -match 'wakeActive=(true|false)') { Dim "wakeActive: $($Matches[1])" }
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

if ($Status) {
  Show-State
  Write-Host ""
  Read-Host "Enter — закрыть"
  exit 0
}

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
# READ_LOGS — не runtime-разрешение: `pm grant` из shell на Android 13+ падает с
# SecurityException (GRANT_RUNTIME_PERMISSIONS). Рабочий путь — app-op, им shell управляет.
$null = Sh "pm grant $Pkg android.permission.READ_LOGS"
if (Set-ReadLogsAllowed) { Ok "READ_LOGS разрешён (appops)" }
else {
  Warn "READ_LOGS включить не удалось — не критично для кнопки (агент работает как shell, у него лог есть)"
  Dim ("состояние: " + (Get-ReadLogsState))
}

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
  } elseif ($result -match 'agentConnected=true|Agent already exists') {
    Ok "агент запущен"
    if ($result -match 'wakeActive=false') { Warn "wakeActive=false: агент живой, но события кнопки не читает — проверь READ_LOGS" }
  } else {
    Warn "агент не стартовал — смотрю, что отвечает приложение"
    Show-State
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
