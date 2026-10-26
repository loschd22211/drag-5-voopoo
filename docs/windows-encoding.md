# Windows PowerShell и кириллица в `.ps1`

## Симптом

При запуске скрипта вываливается куча ошибок парсера, а в тексте видны кракозябры:

```
Отсутствует закрывающий знак "}" в блоке операторов или определении типа.
+ ... РЅРµ РЅР°Р№РґРµРЅ - РєР°С‡Р°СЋ platform-tools РѕС‚ Google (~10 РњР‘)"
```

## Причина

Windows PowerShell 5.1 (тот, что стоит в Windows по умолчанию) читает `.ps1`
**без BOM** как ANSI (в русской локали — cp1251), а не как UTF-8. Каждая русская буква
превращается в два-три мусорных символа, и один из них оказывается кавычкой — строка
«рвётся», парсер теряет `}` и падает. Логика скрипта при этом не повреждена.

PowerShell 7 (pwsh) читает UTF-8 без BOM нормально, поэтому проблема воспроизводится
не у всех.

## Лечение (30 секунд)

Перезаписать файл в UTF-8 **с BOM**:

```powershell
$f = "$HOME\OneDrive\Desktop\drag-5-voopoo-arena-9556c5bb-drag-5-voopoo\scripts\oneclick.ps1"
$txt = Get-Content -Raw -Encoding UTF8 $f
[IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($true)))
powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

То же для всех `.ps1` в папке:

```powershell
Get-ChildItem "$HOME\OneDrive\Desktop\drag-5-voopoo-*\scripts\*.ps1" | ForEach-Object {
  $t = Get-Content -Raw -Encoding UTF8 $_.FullName
  [IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($true)))
}
```

## Как этого не допускать

- В репозитории `oneclick.ps1` и `adb-gemini.ps1` хранятся **с BOM** — так и должно быть.
  `npm test` проверяет это отдельным тестом: если BOM пропадёт, тест упадёт.
- Если правишь файл в VS Code: справа внизу → `UTF-8 with BOM`.
- Если правишь в старом «Блокноте» — он может срезать BOM при сохранении.
- Альтернатива: запускать через PowerShell 7 (`pwsh`), он BOM не требует.

## Проверка без запуска скрипта

```powershell
$bytes = [IO.File]::ReadAllBytes($f)[0..2]
'{0:X2} {1:X2} {2:X2}' -f $bytes[0], $bytes[1], $bytes[2]   # должно быть: EF BB BF
```
