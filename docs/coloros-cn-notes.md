# Китайская ColorOS и кнопка питания: подробный разбор

Заметки к инструменту `gemini-power-button`. Здесь то, что не влезло в README:
почему на CN-сборках OnePlus/OPPO настройка не работает и что с этим делают на практике.

---

## 1. Почему на китайской прошивке не работает штатный путь

Китайские сборки OnePlus (Ace 5, модели `PKG110` и родня) идут на ColorOS CN:

- Google-сервисы не предустановлены (включаются вручную: `Настройки → Система и
  обновления → Настройки Google → GMS`);
- роль системного ассистента закреплена за фирменным **Breeno** (`com.oplus.breeno`
  и связанные пакеты), который понимает только китайский и не переключается на другой язык;
- обработчик долгого нажатия кнопки питания у OPPO/OnePlus свой (`Settings.Secure`,
  экран вида `OplusPowerButtonSettingsActivity`), и в CN-сборках он либо не содержит пункта
  «Цифровой помощник», либо пункт есть, но нажатие ничего не запускает.

В глобальном OxygenOS путь штатный:

```
Настройки → Доступность и удобство (Accessibility & convenience) → Кнопка питания
          → «Нажать и удерживать» → «Цифровой помощник»
```

и отдельно:

```
Настройки → Приложения → Приложения по умолчанию → Цифровой помощник → Google
```

Если оба пункта есть и работают — инструмент из этого репозитория ничего не улучшит,
он просто подтвердит, что всё уже настроено.

---

## 2. Порядок действий от простого к сложному

### Шаг 0. Убедиться, что назначение вообще возможно

Запусти диагностику (`npm start` → «Проверить телефон» или `./scripts/adb-gemini.sh`).
Интересны две строки:

```
assistant:                 com.google.../GsaVoiceInteractionService
voice_interaction_service: com.google.../GsaVoiceInteractionService
```

Если после «Назначить» там остались прежние значения — прошивка отклонила запись.
Дальше смысла долбить adb нет, нужен путь через экраны настроек или обходные приложения.

Если значения записались, но кнопка всё равно открывает меню питания — прошивка
игнорирует помощника в обработчике клавиши. Тоже к шагу 2.

### Шаг 1. Обновление прошивки

В свежих сборках ColorOS (15 и особенно 16) выбор Google-помощника для долгого нажатия
появляется официально. По отзывам пользователей на 13/15 он при этом может «нажиматься и
ничего не делать», но проверить стоит: бесплатно и без риска.

### Шаг 2. Activity Launcher (без root, самый частый рабочий вариант)

Приложение [Activity Launcher](https://play.google.com/store/apps/details?id=de.szalkowski.activitylauncher)
умеет запускать скрытые активности системы и, что важнее, может показать диалог выбора
помощника, который прошивка не показывает в настройках:

1. Установить Activity Launcher.
2. Открыть, дождаться загрузки списка (если пусто — закрыть из недавних и открыть снова).
3. Найти активность `assistantguidedialog` (поиск по списку).
4. Запустить, в появившемся окне нажать **Set**.
5. Проверить: зажать кнопку питания.

Тот же трюк с `assistantguidedialog` используют и на китайских Xiaomi — это, по сути,
стандартный обход отсутствующего системного экрана. Если поиск ничего не даёт — попробуй
`Assist` / `VoiceInput` / `assistant` в поиске по активностям.

### Шаг 3. MiCTS (open source)

[parallelcc/MiCTS](https://github.com/parallelcc/MiCTS) — приложение, которое добавляет
вызов ассистента / Circle to Search на прошивках, где Google-помощник выпилен. Работает без
root, запускается из Smart Sidebar, сайдбара или через собственный триггер.

Ограничение, о котором пишут пользователи ColorOS: голосовую активацию («Окей, Google»)
это не лечит, только запуск по жесту.

### Шаг 4. ShortX + LSPosed (нужен root)

Если цель — именно физическая кнопка питания и ничего больше не устраивает, жест
переназначается на уровне системы: ShortX (или Key Mapper) через LSPosed. Требует
разблокированного загрузчика и root, то есть убивает гарантию, банковские приложения
и обновления по воздуху. Для «просто хочу как на нормальном телефоне» — избыточно.

### Шаг 5. Перепрошивка на глобальный OxygenOS — не рекомендуется

Технически возможно, но: полное стирание данных, риск anti-rollback (кирпич при
понижении версии), официальной процедуры OnePlus для этого не даёт, а после перепрошивки
возможны проблемы с камерами, диапазонами и оплатой. Ради одной кнопки — плохая сделка.

---

## 2.5. Breeno не отпускает кнопку даже после назначения Google

Самая частая картина на ColorOS CN: команда

```bash
adb shell settings put secure assistant com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService
```

проходит, `settings get secure assistant` показывает Google — **а долгое нажатие всё равно
открывает Breeno**. Причина: Breeno ставит собственный обработчик клавиши, который
работает поверх роли «цифрового помощника». Пока его пакеты включены, кнопка принадлежит ему.

### На ColorOS 16 пакета `com.oplus.breeno` нет

Breeno разложен на части. Реальный список с OnePlus Ace 5 (PKG110, Android 16, ColorOS 16 CN):

| Пакет | Что это | Отключается через `disable-user` | Риск |
| --- | --- | --- | --- |
| `com.heytap.speechassist` | голосовой ассистент (сам Breeno) | да → `new state: disabled-user` | низкий |
| `com.coloros.assistantscreen` | экран ассистента Breeno | **нет** → `new state: default` | низкий |
| `com.oplus.aiunit` | AI-движок OPPO | **нет** → `new state: default` | средний: им пользуются другие функции |
| `com.aiunit.aon` | always-on часть AI-движка | да | средний |

Найти актуальные имена на своём устройстве:

```bash
adb shell pm list packages | grep -Ei 'breeno|speechassist|voiceassist|assistantscreen|aiunit'
```

### Порядок действий

1. Снять голосовой пакет — этого обычно достаточно:

   ```bash
   adb shell pm disable-user --user 0 com.heytap.speechassist
   adb shell pm list packages -d | grep -i speechassist     # проверить, что отключился
   ```

2. Если кнопка всё ещё открывает Breeno — снять экран ассистента. Он защищён от
   `disable-user`, поэтому нужен более сильный режим:

   ```bash
   adb shell pm uninstall --user 0 com.coloros.assistantscreen
   ```

   Это **не удаление**: пакет скрывается только для пользователя 0 и возвращается командой
   `adb shell cmd package install-existing com.coloros.assistantscreen`.

3. AI-движок (`com.oplus.aiunit`, `com.aiunit.aon`) трогать в последнюю очередь: им
   пользуются галерея, перевод, обработка фото. Отключай только если без этого кнопка
   не отпускает.

### Что реально работает на ColorOS 16 (снято с устройства)

Проверено на OnePlus Ace 5, `PKG110`, Android 16, ColorOS 16 CN, пакет
`com.coloros.assistantscreen` (экран ассистента Breeno):

| Команда | Ответ системы | Результат |
| --- | --- | --- |
| `pm disable-user --user 0 <pkg>` | `new state: default` | ❌ отказ, состояние не меняется |
| `pm disable --user 0 <pkg>` | `SecurityException: Shell cannot change component state for null to 2` | ❌ shell-у запрещено |
| `pm hide <pkg>` | `SecurityException: Access denied, requires: android.permission.MANAGE_USERS` | ❌ нужен root |
| `pm suspend --user 0 <pkg>` | `new suspended state: true` | ✅ **работает** |
| `pm uninstall --user 0 <pkg>` | `Failure [DELETE_FAILED_INTERNAL_ERROR]` | ❌ прошивка запрещает |
| `pm unsuspend --user 0 <pkg>` | `new suspended state: false` | ✅ откат проходит |

Вывод: **`suspend` — единственный рабочий рычаг для защищённых пакетов Breeno без root.**
Именно эту лестницу (`disable-user → suspend → hide → uninstall`) перебирают скрипты,
проверяя результат по состоянию, а не по тексту ответа.

Проверить, что пакет действительно приостановлен:

```bash
adb shell dumpsys package com.coloros.assistantscreen | grep 'User 0:'
# ... installed=true hidden=false suspended=true ...
```

Важно: приостановленный пакет **не появляется** в `pm list packages -d` и остаётся
в `pm list packages --user 0` — поэтому проверять нужно `suspended=true` в `dumpsys`.

### Важно про `new state: default`

Если `pm disable-user` отвечает `new state: default` — **это не успех**, а отказ: состояние
пакета не изменилось (проверяется через `pm list packages -d`). Мой первый скрипт считал
такую строку успехом, из-за чего на реальном телефоне создавалось ложное впечатление, что
всё снято. Теперь проверка идёт по фактическому состоянию, а не по тексту ответа.

### Готовые скрипты

```bash
bash scripts/breeno-off.sh                # голосовой пакет + экран ассистента
bash scripts/breeno-off.sh --uninstall    # для защищённых — uninstall --user 0
bash scripts/breeno-off.sh --all          # ещё и AI-движок (осторожно)
bash scripts/breeno-off.sh --restore      # вернуть всё обратно
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\breeno-off.ps1
# ключи: -Uninstall, -All, -Restore, -Yes
```

В веб-интерфейсе — карточка «Фирменный ассистент (Breeno)»: «Снять Breeno»,
«Жёстче: скрыть для пользователя», «Вернуть всё обратно».

### Что НЕЛЬЗЯ трогать

`com.oplus.ocs`, `coloros.ota`, `com.android.virtualization.terminal` — это не ассистенты
(облако OPPO, обновления, виртуализация). Скрипты их отсекают автоматически.

### Про обратимость

`pm disable-user` и `pm uninstall --user 0` не трогают системный раздел и не требуют root.
Возврат — `pm enable` / `cmd package install-existing`. Единственный побочный эффект:
обновление прошивки может вернуть пакеты в строй — тогда скрипт просто прогоняется снова.

### Отдельная ловушка: `$` в именах активностей

Классы вида `com.android.settings/.Settings$PowerMenuSettingsActivity` содержат `$`.
Если передать такую команду без кавычек, **шелл телефона** подставит вместо
`$PowerMenuSettingsActivity` пустую переменную, и откроется просто «Настройки»
(в выводе будет `cmp=com.android.settings/.Settings`). Правильно — в одинарных кавычках:

```bash
adb shell am start -n 'com.android.settings/.Settings$PowerMenuSettingsActivity'
```

```powershell
& $adb -s $serial shell "am start -n 'com.android.settings/.Settings`$PowerMenuSettingsActivity'"
```

---

## 2.9. Если кнопку не отдаёт даже suspend: ColorGoogle

Когда `speechassist` отключён, `assistantscreen` приостановлен, а долгое нажатие всё равно
открывает Breeno — вызов зашит в обработчик клавиши на уровне фреймворка. adb тут бессилен,
но есть приложение, которое перехватывает кнопку само.

### Почему ColorGoogle, а не MiCTS

| | ColorGoogle | MiCTS |
| --- | --- | --- |
| Забирает **кнопку питания** | да, включая выключенный экран | нет, это про Circle to Search |
| Нужен root | нет | нет (для базового режима) |
| Проверено на | OPPO, Android 16, ColorOS 16.0.10.501 | OnePlus Ace 5, ColorOS 16.0.10 (preview-сборка) |
| Лицензия / источник | GPL-3.0, форк MindTrigger Assist v16.2.0 | GPL-3.0, оригинал |

Для задачи «нажал кнопку — открылся Gemini» подходит только ColorGoogle.
Проект: https://github.com/joeyandu/ColorGoogle (неофициальный, не связан с Google/OPPO).

### Что делает установщик `scripts/gemini-trigger.ps1`

1. Находит adb (или скачивает platform-tools).
2. Делает бэкап `assistant`, `voice_interaction_service` и whitelist в `.\colorgoogle-backup`.
3. Скачивает APK нужного релиза и сверяет SHA-256 по `SHA256SUMS`.
4. Ставит с `install -r -g` (разрешения сразу, без ручных диалогов).
5. Выдаёт `READ_LOGS`, назначает Google помощником, включает оверлей, уведомления,
   снимает оптимизацию батареи.
6. Открывает приложение: остаётся включить **главный тумблер** и **Power button trigger** —
   это только руками, изнутри приложения.
7. Запускает shell-агент официальным скриптом проекта и показывает статус.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-trigger.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-trigger.ps1 -Restore
```

### Важные детали, на которых спотыкаются

- **`voice_interaction_service` пустой.** ColorOS CN держит роль помощника за Google, но
  оставляет `Settings.Secure.voice_interaction_service` пустым — тогда
  `VoiceInteractionManagerService` вообще не поднимает сервис. Установщик заполняет оба ключа.
- **Permission grants не запускают агент.** Нужен отдельный запуск
  `activate-agent.sh` (в установщике — шаг 7), причём главный тумблер должен быть уже включён,
  иначе скрипт отвечает `Main enable switch is off` и выходит с кодом 2.
- **Конфликтующие OEM-компоненты.** Проект называет `com.heytap.speechassist` и
  `com.coloros.colordirectservice`. Первый у нас уже отключён; второй не трогай без нужды.
  Не удаляй `com.oplus.ovoicemanager` и `com.heytap.quicksearchbox`.
- **O+Connect.** На тестовом устройстве его фоновая служба при подключении USB перезапускала
  adb-демон и убивала привилегированный агент. Если функции отваливаются после подключения
  кабеля — проверь его службы и активируй агент заново.
- **Откат.** `-Restore` останавливает агент и возвращает `assistant` /
  `voice_interaction_service` из бэкапа. Само приложение остаётся, удаляется через
  `adb uninstall dev.evoker.homeholdcts`.

---

## 2.95. «Скачивается, но не ставится»: магазин HeyTap и сканер APK

Симптомы: установка висит на «Проверка приложения», потом отказ; либо
`INSTALL_FAILED_VERIFICATION_FAILURE`; либо вообще ничего не происходит.

Виноваты три вещи, все снимаются без root:

| Что | Как проявляется | Команда |
| --- | --- | --- |
| `com.heytap.market` (App Market) | режет сторонние APK, подсовывает каталог | `pm disable-user --user 0` → при отказе `pm suspend` |
| `com.oplus.appdetail` (сканер установок) | «думает» минутами и блокирует | то же |
| `verifier_verify_adb_installs` / `package_verifier_enable` | `INSTALL_FAILED_VERIFICATION_FAILURE` | `settings put global ... 0` |

Готовый скрипт: `scripts/debloat-market.ps1` (возврат — `-Restore`).

### Грабли, на которые уже наступили

1. **`Kill` — алиас `Stop-Process`.** Функция с таким именем не вызывается:
   PowerShell падает с `ParameterBindingException: не удается преобразовать "com.heytap.market"`.
   В скриптах репозитория функции называются `Block-App` / `Unblock-App`.
2. **GitHub API отдаёт `403 rate limit exceeded`** (60 запросов в час на IP без авторизации).
   Поэтому установщик качает APK **по прямой ссылке**
   `https://github.com/joeyandu/ColorGoogle/releases/download/<tag>/<file>.apk`,
   а API использует только как резерв.
3. **`$apk = Join-Path $env:TEMP $asset.name` при пустом `$asset`** даёт путь к папке
   `C:\Users\<user>\AppData\Local\Temp\` — и следующий `Remove-Item` пытается снести
   **весь Temp**. В скрипте теперь отдельная папка `...\gemini-power-button\apk`,
   проверка `-PathType Leaf` и обязательная проверка размера файла.
4. **Суффиксы `10MB` / `1MB`** ломают часть парсеров и старый PowerShell — используем числа.

---

## 2.96. ColorGoogle: почему агент не стартует

| Сообщение | Что это значит | Что делать |
| --- | --- | --- |
| `Cannot read main switch; activation refused.` | `content call ... --method status --arg compact` не вернул `runEnabled` — провайдер не ответил, главный переключатель не прочитан | открыть приложение и включить главный переключатель, проверить: `scripts/gemini-trigger.ps1 -Status` |
| `Main switch is off; enable ColorGoogle before activation.` | провайдер ответил, но главный переключатель выключен | то же |
| `SecurityException: grantRuntimePermission: Neither user 2000 nor current process has android.permission.GRANT_RUNTIME_PERMISSIONS` | `pm grant READ_LOGS` не работает: READ_LOGS не runtime-разрешение, а shell на Android 13+ не имеет права выдавать такие | `adb shell appops set dev.evoker.homeholdcts READ_LOGS allow` (так и делает скрипт) |

Провайдер `content://dev.evoker.homeholdcts.desktopsearch` объявлен с
`android:permission="android.permission.DUMP"` и пускает только uid 2000, поэтому
диагностика требует именно `adb shell`. Ответ читается так:
`runEnabled` — главный переключатель, `agentConnected` — агент,
`wakeActive` — читает ли агент события кнопки (без READ_LOGS будет `false`).

`wakeActive=false` при `runEnabled=true` — самый частый вид «всё включено, но кнопка молчит»:
агент жив, а лог ему недоступен.

---

## 3. Что не заведётся даже при рабочей кнопке

- **«Окей, Google» / Voice Match.** На CN-сборках часто отсутствует системная библиотека,
  от которой зависит постоянное прослушивание, поэтому фраза не поднимает ассистента,
  даже если кнопка работает. Лечится только модификацией приложения Google — вне рамок
  этого инструмента.
- **Circle to Search** — привязан к тем же системным интеграциям.
- **Экран блокировки** — запуск ассистента с заблокированного экрана ColorOS обычно
  запрещает; сначала разблокируй, потом держи кнопку.

---

## 4. Сброс после перезагрузки

На части сборок назначение помощника не держится: после перезагрузки или очистки недавних
приложений система возвращает Breeno/пустое значение. Признаки и лечение:

- инструмент: шаг 6 «Дифф настроек» — сними снимок до и после перезагрузки, увидишь,
  сбрасывается ли `secure:assistant`;
- костыль: повторный запуск `scripts/adb-gemini.sh` после перезагрузки (30 секунд);
- иногда помогает выставить помощника сначала в `None`, потом снова Google — это
  перестраивает внутренний кэш выбора;
- агрессивная экономия батареи может «снимать» разрешения приложения Google: шаг 4 →
  «Убрать оптимизацию батареи», плюс автозапуск для Google в настройках ColorOS.

---

## 5. Откат

Полный откат к состоянию «как было»:

```bash
adb shell settings delete secure assistant
adb shell settings delete secure voice_interaction_service
```

После этого система вернётся к Breeno или к пустому значению — как было до запуска.
Никакие файлы, разделы и счётчики не меняются, гарантия не затрагивается.

---

## 6. Полезные ссылки

- Справка Google: как назначить помощника и как убрать его с кнопки —
  [support.google.com/gemini/answer/14554984](https://support.google.com/gemini/answer/14554984),
  [support.google.com/gemini/answer/16938321](https://support.google.com/gemini/answer/16938321)
- Памятка по ColorOS и Google-сервисам (включая трюк с `assistantguidedialog`) —
  [xdaforums.com/t/how-to-fix-issues-on-coloros](https://xdaforums.com/t/how-to-fix-issues-on-coloros.4708096/)
- MiCTS — [github.com/parallelcc/MiCTS](https://github.com/parallelcc/MiCTS)
- Обсуждение помощника на кнопке в ColorOS 16 —
  [reddit.com/r/oneplus](https://www.reddit.com/r/oneplus/comments/1qp94ke/coloros_16_latest_update_added_google_feed_in/)

Команды и названия экранов в разных версиях ColorOS отличаются: если пункт не совпадает
буквально — ищи по смыслу («Кнопка питания», «Удобство», «Спец. возможности», «Помощник»)
или используй поиск внутри настроек.
