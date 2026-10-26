# Показывает, что на этой прошивке вообще есть про помощника: роль, сервис,
# все ключи настроек с power/assist/button и страница выбора помощника.
# Ничего не меняет — только читает и открывает экран настроек.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\assistant-keys.ps1
#
# Файл в UTF-8 с BOM (см. docs/windows-encoding.md).

param(
  [string]$Adb = "",
  [string]$Serial = ""
)

$ErrorActionPreference = "Continue"
$ScriptVersion = "2026-10-27.1"
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  chcp 65001 > $null
} catch {}

function Write-Ok($t)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $t }
function Write-Warn($t) { Write-Host "[!]  " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Err($t)  { Write-Host "[X]  " -ForegroundColor Red -NoNewline; Write-Host $t }
function Write-Step($t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Dim($t)  { Write-Host "     $t" -ForegroundColor DarkGray }
function Stop-Script($t) { Write-Err $t; Write-Host ""; Read-Host "Enter — закрыть"; exit 1 }

function Sh($cmd) {
  $line = '"' + $script:AdbBin + '" -s ' + $script:Serial + ' shell ' + $cmd + ' 2>&1'
  return (& cmd /c $line | Out-String).Trim()
}

function Connect-Adb {
  $bin = $Adb
  if (-not $bin) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if ($found) { $bin = $found.Source }
    else {
      $winget = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter 'adb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($winget) { $bin = $winget.FullName }
      else {
        $cached = Join-Path $env:LOCALAPPDATA 'gemini-power-button\platform-tools\adb.exe'
        if (Test-Path $cached) { $bin = $cached }
        else { Stop-Script "adb не найден. Поставь Platform-Tools (winget install Google.PlatformTools)" }
      }
    }
  }
  $script:AdbBin = $bin
  $devices = (& $bin devices 2>&1 | Out-String) -split "`r?`n" |
    Where-Object { ($_ -split '\s+')[1] -eq 'device' } |
    ForEach-Object { ($_ -split '\s+')[0] }
  if (-not $devices) { Stop-Script "телефон не виден: кабель, «Отладка по USB», подтверждение на экране" }
  $script:Serial = if ($Serial) { $Serial } else { @($devices)[0] }
  Write-Ok "adb: $bin"
  Write-Ok "телефон: $($script:Serial)"
}

# Ключ + текущее значение, только чтение.
function Show-Keys([string]$ns) {
  $raw = Sh ("settings list " + $ns)
  $rows = @(($raw -split "`r?`n") | Where-Object { $_ -match '(power|assist|button|gesture)' })
  if ($rows.Count -eq 0) { Write-Dim ("в " + $ns + ": ничего"); return }
  foreach ($r in $rows) { Write-Host ("     " + $r.Trim()) -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

Write-Step "Кто назначен помощником"
$role = Sh 'cmd role get-role-holders android.app.role.ASSISTANT'
Write-Dim ("роль ASSISTANT: " + ($role -replace "`r?`n", ' / '))
$assist = Sh 'settings get secure assistant'
Write-Dim ("settings secure assistant: " + $assist)
$voice = Sh 'settings get secure voice_interaction_service'
Write-Dim ("voice_interaction_service: " + $voice)
$svc = Sh 'cmd package query-services -a android.service.voice.VoiceInteractionService --brief'
foreach ($l in (($svc -split "`r?`n") | Select-Object -First 5)) {
  if ($l.Trim() -ne '') { Write-Dim ("сервис: " + $l.Trim()) }
}

Write-Step "Ключи про кнопку и жест (secure)"
Show-Keys 'secure'
Write-Step "Ключи про кнопку и жест (system)"
Show-Keys 'system'
Write-Step "Ключи про кнопку и жест (global)"
Show-Keys 'global'

Write-Step "Страницы настроек, где это может лежать"
$hit = 0
foreach ($pkg in @('com.oplus.settings', 'com.coloros.settings', 'com.android.settings')) {
  $inst = Sh ("pm list packages " + $pkg)
  if ($inst -notmatch ("package:" + [regex]::Escape($pkg))) { continue }
  $dump = Sh ("dumpsys package " + $pkg)
  $acts = @(($dump -split "`r?`n") | Where-Object { $_ -match 'Activity' -and $_ -match '(assist|power|button|gesture|shortcut)' } | Select-Object -First 10)
  foreach ($a in $acts) {
    Write-Dim ($a.Trim())
    $hit++
  }
}
if ($hit -eq 0) { Write-Warn "отдельных страниц «кнопка/помощник» в настройках не нашлось" }

Write-Step "Открываю выбор помощника"
Sh 'am start -a android.settings.VOICE_INPUT_SETTINGS' | Out-Null
Write-Dim "на экране телефона: «Цифровой помощник» / «Помощник и голосовой ввод»"
Write-Dim "если там нет пункта про кнопку питания — значит в этой прошивке его нет вообще"

Write-Host ""
Read-Host "Enter — закрыть"
