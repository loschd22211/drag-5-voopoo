# Снимает фирменный ассистент Breeno (HeyTap speech assist), который перехватывает
# долгое нажатие кнопки питания на ColorOS. Обратимо, без root.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-off.ps1
#   ... -All          ещё и AI-движок OPPO (может быть нужен другим функциям!)
#   ... -Uninstall    для защищённых пакетов: uninstall --user 0 (тоже обратимо)
#   ... -Restore      вернуть всё как было
#
# На ColorOS 16 пакета com.oplus.breeno нет: Breeno разложен на части —
#   com.heytap.speechassist          голосовой ассистент
#   com.coloros.assistantscreen      экран ассистента
#   com.oplus.aiunit / com.aiunit.aon   AI-движок
#
# Файл сохранён в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [switch]$Restore,
  [switch]$Uninstall,
  [switch]$All,
  [switch]$Yes
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

$VendorPattern = 'breeno|heytap\.speechassist|voiceassist|speechassist|assistantscreen|aiunit'
$DenyPattern = 'com\.oplus\.ocs$|coloros\.ota'
# даже если пакет скрыт для пользователя и не виден в pm list packages
$KnownVendor = @(
  'com.heytap.speechassist',
  'com.coloros.assistantscreen',
  'com.oplus.aiunit',
  'com.aiunit.aon',
  'com.oplus.breeno'
)

function Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Die($t)  { Err $t; Write-Host ""; Read-Host "Enter - закрыть"; exit 1 }

function Sh($cmd) {
  (& $script:AdbBin "-s" $script:Serial "shell" $cmd 2>&1 | Out-String).Trim()
}

function Get-PackageSet($args) {
  $set = @{}
  foreach ($line in ((Sh $args) -split "`r?`n")) {
    if ($line -match '^package:(.+)$') { $set[$Matches[1].Trim()] = $true }
  }
  return $set
}

function Get-Role($pkg) {
  if ($pkg -match 'speechassist|breeno|voiceassist') { return 'voice' }
  if ($pkg -match 'assistantscreen') { return 'screen' }
  if ($pkg -match 'aiunit') { return 'engine' }
  return 'other'
}

function Get-RoleLabel($role) {
  switch ($role) {
    'voice'  { return 'голосовой ассистент Breeno' }
    'screen' { return 'экран ассистента Breeno' }
    'engine' { return 'AI-движок OPPO (риск: нужен другим функциям)' }
    default  { return 'фирменный ассистент' }
  }
}

function Ask($q) {
  if ($Yes) { return $true }
  $a = Read-Host "$q [y/N]"
  return ($a -match '^(y|yes|д|да)$')
}

# --------------------------------------------------------------- adb и телефон

$script:AdbBin = $Adb
if (-not $script:AdbBin) {
  $inPath = Get-Command adb -ErrorAction SilentlyContinue
  if ($inPath) { $script:AdbBin = $inPath.Source }
  else {
    $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
    if (Test-Path $cached) { $script:AdbBin = $cached }
    else { Die "adb не найден. Сначала запусти scripts\oneclick.ps1 — он его скачает." }
  }
}
Ok "adb: $script:AdbBin"

$ready = (& $script:AdbBin devices 2>&1 | Out-String) -split "`r?`n" |
  Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
  ForEach-Object { ($_ -split '\s+')[0] }
if (-not $ready) { Die "телефон не виден: проверь кабель и «Отладку по USB»" }
$script:Serial = @($ready)[0]
Ok "телефон: $script:Serial"

# --------------------------------------------------------------- что установлено

Step "Смотрю, что установлено"
$installed = Get-PackageSet "pm list packages --user 0"
$disabled  = Get-PackageSet "pm list packages -d"

$candidates = @()
foreach ($pkg in $installed.Keys) {
  if ($pkg -notmatch $VendorPattern) { continue }
  if ($pkg -match $DenyPattern) { continue }
  $candidates += $pkg
}
foreach ($pkg in $disabled.Keys) {
  if ($pkg -notmatch $VendorPattern) { continue }
  if ($candidates -notcontains $pkg) { $candidates += $pkg }
}
if ($Restore) {
  foreach ($pkg in $KnownVendor) {
    if ($candidates -notcontains $pkg) { $candidates += $pkg }
  }
}

if ($candidates.Count -eq 0) {
  Ok "фирменных ассистентов не найдено"
  Dim "тогда смотри docs/coloros-cn-notes.md, раздел про Activity Launcher"
  Read-Host "Enter - закрыть"
  exit 0
}

foreach ($pkg in $candidates) {
  $role = Get-Role $pkg
  $state = if ($disabled.ContainsKey($pkg)) { 'отключён' } elseif (-not $installed.ContainsKey($pkg)) { 'скрыт для пользователя' } else { 'включён' }
  Dim ("{0,-34} {1,-38} {2}" -f $pkg, (Get-RoleLabel $role), $state)
}

Step "Текущий помощник"
$cur = Sh "settings get secure assistant"
Dim "assistant: $cur"
if ($cur -match 'com\.google') { Ok "Google назначен помощником" }
else { Warn "помощник не Google — сначала запусти scripts\oneclick.ps1" }

# --------------------------------------------------------------- restore

if ($Restore) {
  Step "Возвращаю фирменные ассистенты"
  foreach ($pkg in $candidates) {
    $out = Sh "pm enable $pkg"
    if ($out -match 'Error|Exception|Unknown package') {
      $out = Sh "cmd package install-existing $pkg"
    }
    if ($out -match 'Unknown package|not found') { Dim "$pkg : на этой сборке нет — пропускаю" }
    elseif ($out -match 'Error|Exception') { Warn "$pkg : $out" }
    else { Ok "$pkg включён" }
  }
  Dim "Проверь: долгое нажатие снова откроет Breeno."
  Read-Host "Enter - закрыть"
  exit 0
}

# --------------------------------------------------------------- disable

$targets = @()
foreach ($pkg in $candidates) {
  if (-not $installed.ContainsKey($pkg)) { continue }
  if ($disabled.ContainsKey($pkg)) { continue }
  if ((Get-Role $pkg) -eq 'engine' -and -not $All) {
    Dim "пропускаю $pkg (AI-движок; включить в работу: -All)"
    continue
  }
  $targets += $pkg
}

if ($targets.Count -eq 0) {
  Ok "нечего отключать — всё уже снято"
  Dim "если кнопка всё ещё открывает Breeno, попробуй: -All"
  Read-Host "Enter - закрыть"
  exit 0
}

Step "Отключаю: $($targets -join ', ')"
Dim "Обратимо, без root. Вернуть: scripts\breeno-off.ps1 -Restore"
if (-not (Ask "Продолжить?")) { Die "отменено" }

$failed = @()
foreach ($pkg in $targets) {
  $out = Sh "pm disable-user --user 0 $pkg"
  if ($out -match 'new state: disabled') { Ok "$pkg отключён" }
  else { Warn "$pkg не поддался: $out"; $failed += $pkg }
}

if ($failed.Count -gt 0 -and $Uninstall) {
  Step "Повторяю через uninstall --user 0"
  $still = @()
  foreach ($pkg in $failed) {
    $out = Sh "pm uninstall --user 0 $pkg"
    if ($out -match 'Success') { Ok "$pkg скрыт для пользователя (вернуть: -Restore)" }
    else { Warn "$pkg : $out"; $still += $pkg }
  }
  $failed = $still
}

Step "Проверяю результат"
$disabledAfter  = Get-PackageSet "pm list packages -d"
$installedAfter = Get-PackageSet "pm list packages --user 0"
$reallyFailed = @()
foreach ($pkg in $targets) {
  if ($disabledAfter.ContainsKey($pkg)) { Ok "$pkg отключён" }
  elseif (-not $installedAfter.ContainsKey($pkg)) { Ok "$pkg скрыт для пользователя" }
  else { Warn "$pkg всё ещё активен"; $reallyFailed += $pkg }
}

Step "Пробую запустить ассистента"
$probe = Sh "am start -a android.intent.action.VOICE_COMMAND"
if ($probe -match '(?i)error|unable to resolve') { Warn "не запустился: $probe" }
else { Ok "команда запуска ушла — глянь на экран телефона" }

Write-Host ""
Write-Host "--- Готово ---" -ForegroundColor White
if ($reallyFailed.Count -eq 0) {
  Ok "Breeno снят. Зажми кнопку питания на 0,5 секунды."
  Dim "Если кнопка открывает меню выключения, а не Gemini — прогони scripts\oneclick.ps1"
} else {
  Warn "Прошивка не дала снять: $($reallyFailed -join ', ')"
  Dim "Попробуй жёстче:  scripts\breeno-off.ps1 -Uninstall"
  Dim "Если и это не поможет — Activity Launcher (assistantguidedialog) или root."
}
Dim "Вернуть как было:  scripts\breeno-off.ps1 -Restore"
Write-Host ""
Read-Host "Enter - закрыть"
