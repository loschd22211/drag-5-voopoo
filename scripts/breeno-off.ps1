# Снимает фирменный ассистент (Breeno и родню), который перехватывает долгое нажатие
# кнопки питания, и оставляет помощником Google/Gemini.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-off.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-off.ps1 -Restore
#
# Файл сохранён в UTF-8 с BOM (см. docs/windows-encoding.md).
# Отключение обратимо: pm disable-user / pm enable, без root, приложение не удаляется.

param(
  [string]$Adb = "",
  [switch]$Restore,
  [switch]$Yes
)

$ErrorActionPreference = "Continue"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

# что считаем фирменным ассистентом
$VendorPattern = 'breeno|voiceassist|speechassist|assistantscreen|aiunit'
# что нельзя трогать даже если попало под шаблон (это не ассистенты)
$DenyPattern = 'com\.oplus\.ocs$|coloros\.ota|oplus\.aiunit\.engine$'

function Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Die($t)  { Err $t; Write-Host ""; Read-Host "Enter - закрыть"; exit 1 }

function Sh($cmd) {
  (& $script:AdbBin "-s" $script:Serial "shell" $cmd 2>&1 | Out-String).Trim()
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
    else { Die "adb не найден. Запусти сначала scripts\oneclick.ps1 — он его скачает." }
  }
}
Ok "adb: $script:AdbBin"

$ready = (& $script:AdbBin devices 2>&1 | Out-String) -split "`r?`n" |
  Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
  ForEach-Object { ($_ -split '\s+')[0] }
if (-not $ready) { Die "телефон не виден: проверь кабель и «Отладку по USB»" }
$script:Serial = @($ready)[0]
Ok "телефон: $script:Serial"

# --------------------------------------------------------------- что на телефоне

Step "Смотрю, какие фирменные ассистенты есть"
$all = Sh "pm list packages"
$disabled = Sh "pm list packages -d"
$candidates = @()
foreach ($line in ($all -split "`r?`n")) {
  if ($line -notmatch '^package:(.+)$') { continue }
  $pkg = $Matches[1].Trim()
  if ($pkg -notmatch $VendorPattern) { continue }
  if ($pkg -match $DenyPattern) { continue }
  $isDisabled = $disabled -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")
  $candidates += [pscustomobject]@{ Package = $pkg; Disabled = [bool]$isDisabled }
}

if ($candidates.Count -eq 0) {
  Ok "фирменных ассистентов не найдено — значит дело не в Breeno"
  Dim "тогда смотри docs/coloros-cn-notes.md, раздел про Activity Launcher"
  Read-Host "Enter - закрыть"
  exit 0
}
foreach ($c in $candidates) {
  $state = if ($c.Disabled) { "уже отключён" } else { "включён" }
  Dim "$($c.Package) — $state"
}

Step "Текущий помощник"
$cur = Sh "settings get secure assistant"
Dim "assistant: $cur"
if ($cur -match 'com\.google') { Ok "Google назначен помощником" }
else { Warn "помощник не Google — сначала запусти scripts\oneclick.ps1" }

# --------------------------------------------------------------- действие

if ($Restore) {
  Step "Включаю фирменные ассистенты обратно"
  foreach ($c in $candidates) {
    $out = Sh "pm enable $($c.Package)"
    if ($out -match 'Error|Exception') {
      $out = Sh "cmd package install-existing $($c.Package)"
    }
    if ($out -match 'Error|Exception') { Warn "$($c.Package): $out" } else { Ok "$($c.Package) включён" }
  }
  Dim "Проверь: зажатие кнопки питания снова откроет Breeno."
  Read-Host "Enter - закрыть"
  exit 0
}

$toDisable = @($candidates | Where-Object { -not $_.Disabled } | ForEach-Object { $_.Package })
if ($toDisable.Count -eq 0) {
  Ok "все фирменные ассистенты уже отключены"
  Read-Host "Enter - закрыть"
  exit 0
}

Step "Сейчас отключу: $($toDisable -join ', ')"
Dim "Это обратимо и не требует root: pm disable-user. Вернуть — ключ -Restore."
if (-not (Ask "Продолжить?")) { Die "отменено" }

$failed = @()
foreach ($pkg in $toDisable) {
  $out = Sh "pm disable-user --user 0 $pkg"
  if ($out -match 'Error|Exception|Unknown package') { $failed += $pkg; Warn "$pkg — не вышло: $out" }
  else { Ok "$pkg отключён" }
}

Step "Проверяю результат"
$disabledAfter = Sh "pm list packages -d"
$stillOn = @()
foreach ($pkg in $toDisable) {
  if ($disabledAfter -match ("package:" + [regex]::Escape($pkg) + "(\r?\n|$)")) { Ok "$pkg действительно отключён" }
  else { $stillOn += $pkg; Warn "$pkg всё ещё включён" }
}

Step "Пробую запустить ассистента"
$probe = Sh "am start -a android.intent.action.VOICE_COMMAND"
if ($probe -match '(?i)error|unable to resolve') { Warn "не запустился: $probe" }
else { Ok "команда запуска ушла — глянь на экран телефона" }

Write-Host ""
Write-Host "--- Готово ---" -ForegroundColor White
if ($stillOn.Count -eq 0) {
  Ok "Breeno снят. Зажми кнопку питания на 0,5 секунды."
  Dim "Если теперь открывается меню выключения, а не Gemini — включи помощника ещё раз:"
  Dim "  scripts\oneclick.ps1"
} else {
  Warn "Часть пакетов прошивка не дала отключить: $($stillOn -join ', ')"
  Dim "Это защита ColorOS. Дальше — только Activity Launcher (assistantguidedialog) или root."
}
Dim "Вернуть как было:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-off.ps1 -Restore"
Write-Host ""
Read-Host "Enter - закрыть"
