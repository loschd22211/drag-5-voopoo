# Возвращает всё китайское, что было выключено, обратно.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restore-cn.ps1
#
# Нужен, если что-то погасили лишнего (обои, будильник, файлы, звук).
# Скрипт ничего не выбирает: он берёт все установленные пакеты с китайскими
# префиксами, снимает suspend и включает. Ничего не скачивает и не удаляет.
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

function Get-Packages($filter) {
  $raw = Sh ("pm list packages --user 0" + $filter)
  $names = @()
  foreach ($line in ($raw -split "`r?`n")) {
    $m = [regex]::Match($line, '^package:(.+)$')
    if ($m.Success) { $names += $m.Groups[1].Value.Trim() }
  }
  return $names
}

# ---------------------------------------------------------------- main

Connect-Adb

$model = Sh 'getprop ro.product.model'
$rom = Sh 'getprop ro.build.version.oplusrom'
Write-Dim ("версия скрипта: " + $ScriptVersion)
Write-Dim ("{0}, прошивка {1}" -f $model, $rom)

Write-Step "Считаю, что выключено"
$disabledBefore = Get-Packages ' -d'
$cnDisabled = @()
foreach ($p in $disabledBefore) {
  if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $cnDisabled += $p }
}
Write-Dim ("всего выключенных: " + $disabledBefore.Count + ", из них китайских: " + $cnDisabled.Count)

Write-Step "Включаю обратно"
$all = Get-Packages ''
$cn = @()
foreach ($p in $all) {
  if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $cn += $p }
}
Write-Dim ("китайских пакетов в системе: " + $cn.Count + " — снимаю suspend и включаю все")

# Одной пачкой на устройстве: 150 пакетов по одной adb-команде — это минуты,
# поэтому команды идут списком внутри одного shell.
$i = 0
while ($i -lt $cn.Count) {
  $end = [Math]::Min($i + 25, $cn.Count - 1)
  $chunk = $cn[$i..$end]
  $sb = ""
  foreach ($p in $chunk) {
    $sb += "pm unsuspend --user 0 " + $p + "; pm enable --user 0 " + $p + "; "
  }
  Sh $sb | Out-Null
  Write-Dim ("включено: " + ($end + 1) + " из " + $cn.Count)
  $i = $end + 1
}

Write-Step "Проверка"
$disabledAfter = Get-Packages ' -d'
$left = @()
foreach ($p in $disabledAfter) {
  if ($p -match '^com\.(heytap|coloros|oplus|oppo|nearme|oneplus)\.') { $left += $p }
}
Write-Ok ("китайских выключенных было " + $cnDisabled.Count + ", осталось " + $left.Count)
if ($left.Count -gt 0) {
  foreach ($p in $left) { Write-Dim ("остался выключенным: " + $p) }
}

Write-Host ""
Write-Dim "Если обои остались чёрными — задай их заново в Настройки → Обои и стиль."
Write-Dim "Перезагрузка не обязательна, но после неё всё встанет на место."
Write-Host ""
Read-Host "Enter — закрыть"
