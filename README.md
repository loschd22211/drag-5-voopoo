# Gemini на долгое нажатие кнопки питания — OnePlus / OPPO

Локальный инструмент, который делает на OnePlus Ace 5 (и любом OxygenOS/ColorOS 12+)
то, что «на нормальных телефонах» уже есть из коробки: **долгое нажатие кнопки питания
запускает Gemini / Google-ассистента**, а не меню выключения.

Работает через ADB с компьютера: веб-интерфейс или консольный скрипт. Телефон не нужно
рутовать, загрузчик разблокировать и что-либо прошивать.

> **Чего инструмент не делает.** Он не подключается к телефону «сам по интернету» — adb
> требует, чтобы телефон был подключён к тому компьютеру, где запущен инструмент (кабелем
> или по Wi-Fi-отладке). Сторонние сервисы и облака не используются: всё локально.

---

## Самый быстрый путь: одна команда

Если не хочется ничего настраивать руками — запусти один файл. Он сам скачает `adb`
(если его нет), сам найдёт телефон, сам поставит Google вместо Breeno и откроет на телефоне
нужный экран настроек. Ничего не спрашивает.

**Windows:** двойной клик по `scripts\oneclick.cmd`

> Если PowerShell выдаёт ошибки парсера и кракозябры (`РЅРµ РЅР°Р№РґРµРЅ`) — это кодировка,
> а не логика: файл `.ps1` должен быть в UTF-8 **с BOM**. Лечение в одну команду —
> [`docs/windows-encoding.md`](docs/windows-encoding.md).

**Linux / macOS:**

```bash
bash scripts/oneclick.sh
```

**Перед этим нужно ровно одно:** на телефоне включена «Отладка по USB»
(Настройки → Для разработчиков) и подтверждено окошко «Разрешить отладку?» на экране телефона.

### Режим USB — какой выбирать?

**Любой.** «Передача файлов», «Передача фотографий», «MIDI» или даже «Только зарядка» —
`adb` работает независимо от этого режима. Он нужен только для доступа компьютера к файлам.
Если сомневаешься — оставь «Только зарядка», этого достаточно.

---

> **Где лежит код.** Всё, что ниже, находится в ветке `arena/9556c5bb-drag-5-voopoo`
> (PR #1). В `main` пока пусто — если качаешь архив через «Download ZIP», переключись
> на эту ветку, иначе получишь пустой репозиторий.

## Установка одной командой (PowerShell, Windows)

Репозиторий приватный, поэтому нужна авторизация. Открой PowerShell (Win → «PowerShell»)
и вставь целиком этот блок — он сам скачает проект на Рабочий стол и запустит настройку:

```powershell
$ErrorActionPreference = 'Stop'
$repo   = 'loschd22211/drag-5-voopoo'
$branch = 'arena/9556c5bb-drag-5-voopoo'
$dest   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'drag-5-voopoo'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }

if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh repo clone $repo $dest -- --branch $branch
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    git clone --branch $branch "https://github.com/$repo.git" $dest
} else {
    Start-Process "https://github.com/$repo/tree/$branch"
    throw 'ни git, ни gh не установлены — используй план Б из README (два шага в браузере)'
}

Get-ChildItem $dest -Recurse -File | Unblock-File
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dest 'scripts\oneclick.ps1')
```

Если `git`/`gh` не установлены — **план Б**, без установки чего-либо:

1. Открой в браузере (ты уже авторизован): 
   https://github.com/loschd22211/drag-5-voopoo/tree/arena/9556c5bb-drag-5-voopoo
2. Зелёная кнопка **Code → Download ZIP**.
3. Вставь в PowerShell:

```powershell
$zip = Get-ChildItem "$HOME\Downloads\*.zip" |
       Where-Object Name -like 'drag-5-voopoo*' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Expand-Archive $zip.FullName -DestinationPath ([Environment]::GetFolderPath('Desktop')) -Force
$dir = Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Directory -Filter 'drag-5-voopoo-*' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-ChildItem $dir.FullName -Recurse -File | Unblock-File
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir.FullName 'scripts\oneclick.ps1')
```

---

## Что внутри

| Что | Для чего |
| --- | --- |
| `server/` | Локальный веб-интерфейс на Node.js без зависимостей: диагностика, назначение помощника, дифф настроек |
| `scripts/oneclick.cmd` / `oneclick.ps1` | **Windows: одна кнопка** — сам скачивает adb и всё настраивает |
| `scripts/oneclick.sh` | **Linux/macOS: одна команда**, без вопросов |
| `scripts/adb-gemini.sh` | CLI для Linux/macOS — всё то же, но с подтверждением на каждом шаге |
| `scripts/adb-gemini.ps1` | CLI для Windows (PowerShell) |
| `tools/mock-adb` | Фейковый adb: демо-режим без телефона, на нём же гоняются тесты |
| `test/smoke.js` | 13 проверок логики без реального устройства |
| `docs/coloros-cn-notes.md` | Что делать, если прошивка блокирует настройку (китайские сборки) |
| `docs/windows-encoding.md` | Если PowerShell ругается на «отсутствует `}`» и показывает кракозябры |
| `scripts/breeno-off.sh` / `breeno-off.ps1` | Снять фирменный Breeno, который перехватывает кнопку (обратимо) |
| `scripts/gemini-trigger.ps1` | Если кнопку не отдаёт даже suspend: ставит ColorGoogle, который забирает кнопку питания и открывает Gemini |
| `scripts/gemini-one-click.ps1` (`-Test` — только замер, `-Restore` — откат) | **Главный:** один запуск — сам назначает Google помощником, снимает Breeno, включает жест и VPN, проверяет кнопку |
| `scripts/lockscreen-player.ps1` | включает карточку плеера на экране блокировки и говорит, что мешает (важность канала / нет MediaSession) |
| `scripts/debloat-cn.ps1` | отключает китайские предустановленные приложения (гейм-бар не трогает) и ускоряет анимации; `-Restore` возвращает |
| `scripts/breeno-gesture.ps1` | пробует переназначить «быстрый поиск Breeno» (долгое нажатие полосы) на Google: возвращает Breeno, ловит компонент, выдаёт роль ASSISTANT, замеряет; `-Restore` откатывает |
| `scripts/power-key-reset.ps1` | Возвращает кнопку питания в заводское состояние и убирает ColorGoogle (обратимо) |
| `scripts/debloat-market.ps1` | Убирает магазин HeyTap и сканер APK, чтобы сторонние приложения ставились без «проверки» |

---

## Требования

1. **Node.js 18+** — только для веб-интерфейса (CLI работает и без него).
2. **Android platform-tools** — то есть `adb` в `PATH`:
   - Windows: [platform-tools](https://developer.android.com/tools/releases/platform-tools) → распаковать → добавить папку в `PATH`
   - macOS: `brew install --cask android-platform-tools`
   - Linux: `sudo apt install android-tools-adb` (или распаковать platform-tools)
3. **На телефоне:** «Для разработчиков» → «Отладка по USB» → подключить кабелем → подтвердить
   отпечаток RSA на экране.

Проверка, что всё видно:

```bash
adb devices -l
# R5CT...  device product:OP5D1L1 model:PKG110 device:OP5D1L1 transport_id:1
```

---

## Быстрый старт

### Вариант 1: веб-интерфейс (удобнее)

```bash
git clone <этот-репозиторий>
cd drag-5-voopoo
npm start                      # http://127.0.0.1:7676
```

Подключить телефон, открыть страницу и идти по шагам 1 → 6:

1. **Подключение** — «Найти телефон» (или сопряжение по Wi-Fi).
2. **Диагностика** — модель, прошивка, наличие Google-сервисов, текущий помощник,
   найденные системные экраны. Ничего не меняет.
3. **Назначить помощника** — выбираешь компонент (по умолчанию подставляется Google)
   и нажимаешь «Назначить».
4. **Проверка** — кнопка запуска ассистента и быстрые переходы в нужные экраны настроек
   прямо на телефоне.
5. **Кнопка питания** — список экранов вида «Power button», которые реально есть на твоей
   прошивке, с кнопкой «Открыть».
6. **Дифф настроек** — снимок → переключил руками на телефоне → сравнение: видно точные
   ключи, которые изменились (и меняется ли вообще хоть что-то).

### Вариант 2: консоль

```bash
./scripts/adb-gemini.sh                 # Linux / macOS
./scripts/adb-gemini.sh R5CT12345678    # конкретное устройство
```

```powershell
.\scripts\adb-gemini.ps1                # Windows
.\scripts\adb-gemini.ps1 -Serial R5CT12345678
```

Скрипт спрашивает подтверждение на каждый шаг (`-Yes` / `y` — согласиться со всеми).

### Вариант 3: вручную, две команды

Если не хочется запускать ничего лишнего:

```bash
adb shell settings put secure assistant com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService
adb shell settings put secure voice_interaction_service com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService
```

Это ровно то же, что делает инструмент. Компонент лучше взять из диагностики: на разных
прошивках он отличается (`GsaVoiceInteractionService`, `AssistantVoiceInteractionService` и т.п.).

---

## Демо-режим (без телефона)

```bash
npm run demo      # то же самое с фейковым adb
```

Интерфейс полностью рабочий, но данные — вымышленный китайский Ace 5 (`PKG110`,
ColorOS 15.0.1). Удобно, чтобы посмотреть, что вообще будет происходить, до подключения
телефона. В шапке горит бейдж «ДЕМО-РЕЖИМ».

```bash
npm test          # 13 проверок на том же фейковом adb
```

---

## Как это работает внутри

| Шаг | Команда |
| --- | --- |
| Список устройств | `adb devices -l` |
| Свойства, прошивка, модель | `adb shell getprop` |
| Установленные пакеты | `adb shell pm list packages` |
| Текущий помощник | `adb shell settings list secure` → `assistant`, `voice_interaction_service` |
| Доступные голосовые сервисы | `adb shell cmd package query-services -a android.service.voice.VoiceInteractionService --brief` |
| Экраны настроек под кнопку питания | `adb shell dumpsys package com.oplus.settings` + фильтр по `power/button/assist` |
| Назначение | `adb shell settings put secure assistant <pkg>/<Service>` |
| Проверка запуска | `adb shell am start -a android.intent.action.VOICE_COMMAND` |
| Снимок/дифф | `settings list secure|system|global` с фильтром по `assist/voice/power/button/key` |

Ничего не пишется в системный раздел: меняются только записи `Settings.Secure`, то есть
те же самые параметры, что и через обычные настройки. Откат — одна команда:

```bash
adb shell settings delete secure assistant
adb shell settings delete secure voice_interaction_service
```

---

## Если не сработало

Три самых частых исхода и что делать:

| Симптом | Причина | Что делать |
| --- | --- | --- |
| Назначение «не применилось» (значение вернулось) | прошивка защищает `Settings.Secure` от записи через adb | открыть экран «Power button» из шага 5 и переключить руками + `docs/coloros-cn-notes.md` |
| Значение записалось, но кнопка открывает Breeno | Breeno ставит свой обработчик клавиши поверх роли помощника | `scripts/breeno-off.sh` / `breeno-off.ps1`: перебирают `disable-user → suspend → hide → uninstall` и проверяют результат по `dumpsys`. На ColorOS 16 обычно срабатывает `suspend` |
| Значение записалось, но кнопка всё равно открывает меню питания | системный обработчик кнопки игнорирует помощника | `docs/coloros-cn-notes.md`, раздел «Activity Launcher / MiCTS» |
| Breeno снят (`speechassist` off, `assistantscreen` suspended), а кнопка всё равно зовёт Breeno | вызов зашит в обработчик клавиши на уровне фреймворка | `scripts/gemini-trigger.ps1` — ставит ColorGoogle, он перехватывает кнопку сам |
| `InvalidVariableReferenceWithDrive` в скрипте | `"$имя: текст"` — PS читает `$имя:` как ссылку на диск | писать `"${имя}: текст"`, ловится тестом |
| Замер кнопки всегда `0 из 5` | ColorOS не исполняет `input keyevent --longpress 26` и `input swipe` для помощника | жать руками, `-Test` слушает окна, см. 2.992 |
| `am start …robin.main.MainActivity` → `SecurityException: not exported` | активность Gemini не exported для shell | проверять только через `input keyevent --longpress 26`, см. 2.998 |
| Плеер не виден на экране блокировки | `media_controls_lock_screen=0` | `settings put secure media_controls_lock_screen 1`, см. 2.996 |
| `pm uninstall` → `DELETE_FAILED_INTERNAL_ERROR` | ColorOS не отдаёт пакет этим путём | `scripts/power-key-reset.ps1` перебирает `pm uninstall --user 0`, `cmd package uninstall`, затем `pm suspend` |
| Долгое нажатие питания зовёт Breeno, а хочется меню выключения | ключ `speech_assist_power_wakeup=1` | `adb shell settings put secure speech_assist_power_wakeup 0` (обратно — `1`) |
| Gemini: «не поддерживается в вашей стране» | региональная блокировка Google (IP + регион аккаунта) | см. 2.99: проверка через инкогнито и country-association-form |
| Кнопка питания открывает меню выключения, помощник молчит | нет Google-приложения либо не включён жест | `input keyevent KEYCODE_ASSIST` как проверка; `assist_gesture_enabled=1`; см. 2.98 |
| `am start -a android.intent.action.ASSIST` → `ResolverActivity` | никто не зарегистрировал этот intent (норма для современного помощника) | проверять через `KEYCODE_ASSIST`, а не через intent |
| Мастер Setup 1/5 не пускает дальше | `Continue` включается только при настоящем `READ_LOGS`, а app-op его не заменяет | штатный путь OnePlus: Настройки → Специальные возможности → Кнопка питания → Удержание → Google |
| `Cannot read main switch; activation refused.` | приложение не отдаёт состояние — главный переключатель не включён | открыть приложение, включить главный переключатель, затем `-Status` |
| `Error: Unknown operation string: READ_LOGS` | `appops` знает только строку операции | `android:read_logs` |
| `READ_LOGS: SecurityException ... GRANT_RUNTIME_PERMISSIONS` | `pm grant` не может выдать это разрешение | скрипт выдаёт его через `appops set ... READ_LOGS allow` |
| APK не ставится: «проверка» висит минутами или `INSTALL_FAILED_VERIFICATION_FAILURE` | магазин HeyTap + сканер `com.oplus.appdetail` + включённый верификатор | `scripts/debloat-market.ps1` (обратимо, `-Restore`) |
| `GitHub API rate limit exceeded` при скачивании APK | лимит 60 запросов/час на IP без авторизации | установщик качает по прямой ссылке на файл, API — только резерв |
| Gemini открывается, но не слушает микрофон | нет разрешения | шаг 4 → «Выдать микрофон Gemini» |
| «Окей, Google» не работает вообще | на китайских сборках часто нет нужной системной библиотеки | кнопка будет работать, голосовая активация — нет; это ограничение прошивки |

Подробный разбор по китайским сборкам OnePlus/OPPO (Breeno, Activity Launcher, MiCTS,
ShortX/LSPosed, риски перепрошивки на OxygenOS) — в [`docs/coloros-cn-notes.md`](docs/coloros-cn-notes.md).

---

## Безопасность и ограничения

- Сервер по умолчанию слушает `127.0.0.1` — снаружи недоступен. `HOST=0.0.0.0` только если
  осознанно открываешь его в локальной сети (у него есть доступ к `adb shell`).
- `/api/raw` выполняет произвольную shell-команду на телефоне — это отладочный инструмент,
  не выставляй его в интернет.
- Инструмент не рутирует телефон, не разблокирует загрузчик, не шьёт прошивки.
- Часть прошивок (особенно CN) может сбрасывать назначение после перезагрузки — тогда
  поможет `docs/coloros-cn-notes.md`; дифф из шага 6 покажет, сбрасывается ли оно у тебя.
- Названия экранов в ColorOS меняются от версии к версии, поэтому инструмент их ищет,
  а не хардкодит: если чего-то не нашёл — смотри шаг 5 и открывай вручную.

---

## Структура

```
server/
  adb.js            вся логика: парсеры, диагностика, действия
  server.js         HTTP-сервер и API (без зависимостей)
  public/           интерфейс: index.html, app.js, style.css
scripts/
  oneclick.sh       одна команда: всё автоматически (Linux/macOS)
  oneclick.ps1      одна команда: всё автоматически (Windows)
  oneclick.cmd      двойной клик для Windows
  gemini-trigger.ps1  ColorGoogle: кнопка питания -> Gemini (последний рубеж)
  debloat-market.ps1  магазин HeyTap и сканер APK: установка без надзирателя
  adb-gemini.sh     CLI для Linux/macOS (с вопросами)
  adb-gemini.ps1    CLI для Windows
tools/
  mock-adb          фейковый adb для демо и тестов
test/
  smoke.js          npm test
docs/
  coloros-cn-notes.md
```

Лицензия: MIT.
