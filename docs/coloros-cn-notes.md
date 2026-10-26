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

### Удаление пакета: `DELETE_FAILED_INTERNAL_ERROR`

`adb shell pm uninstall dev.evoker.homeholdcts` на ColorOS 16 отвечает
`Failure [DELETE_FAILED_INTERNAL_ERROR]` — то же самое, что мы видели на
`com.coloros.assistantscreen`. Помогает лестница: `pm uninstall --user 0`,
`pm uninstall -k --user 0`, `cmd package uninstall`, а если не взяло —
`pm suspend --user 0` (приложение остаётся, но заморожено). Всё это делает
`scripts/power-key-reset.ps1`, он же возвращает `assistant` из бэкапа и Breeno на кнопку.

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

## 2.97. ColorGoogle: мастер настройки на телефоне (Setup, страницы 1–5)

Свежая установка открывает **не настройки, а пятистраничный мастер** «Setup · Page 1/5».
Главный переключатель в нём **не на первой странице**, а первая страница требует
`READ_LOGS`. Отсюда и `error=Agent not connected` в ответе провайдера: агента ещё нет.

Важно: `pm grant ... READ_LOGS` на ColorOS 16 из shell не проходит
(`Neither user 2000 nor current process has android.permission.GRANT_RUNTIME_PERMISSIONS`),
а `appops set ... READ_LOGS allow` отвечает `Error: Unknown operation string` — в этой
сборке операция называется иначе, поэтому скрипт перебирает написания
(`cmd appops` с именем → `appops` со строкой операции).

**Мастер нельзя пролистать без настоящего `READ_LOGS`.** Проверено по исходникам
(`MainActivity.isCurrentSetupPageComplete()` → `isReadLogsGranted()` →
`checkSelfPermission("android.permission.READ_LOGS")`), а кнопка `Continue` на первой
странице включается только при `complete == true`. Значит:

- app-op (`appops set … READ_LOGS allow`) мастер **не удовлетворяет** — это не выдача
  разрешения, а режим операции;
- `pm grant` требует у вызывающего `GRANT_RUNTIME_PERMISSIONS`, которого на этой сборке
  у shell нет, поэтому команда из «Copy ADB one-shot» (`SetupCommands.java`) здесь падает;
- Shizuku работает тем же uid 2000, то есть упирается в ту же стену;
- без root пройти мастер нельзя.

Вывод: на прошивке, где shell не может выдать `READ_LOGS`, ColorGoogle не настроить.
Остаётся штатный путь OnePlus: **Настройки → Специальные возможности и удобства →
Кнопка питания → Держать нажатой → Цифровой помощник → Google**. Значение `assistant`
при этом уже указывает на `GsaVoiceInteractionService`.

---

## 2.98. Кнопка освобождена, но ничего не открывается

Последовательность, которая к этому приводит:

1. `speech_assist_power_wakeup=1` — кнопку забирает Breeno. Ставим `0` — Breeno с кнопки снят,
   и долгое нажатие возвращается к заводскому поведению, то есть к меню «Выключить / Перезагрузить».
2. `settings get secure assistant` показывает `…GsaVoiceInteractionService` — но это **только
   строчка**. Если Google-приложения нет, открывать по кнопке некому, и на
   `am start -a android.intent.action.ASSIST` система отвечает
   `com.android.internal.app.ResolverActivity` (диалог «чем открыть»). Это не поломка:
   современный помощник не обязан регистрировать `ACTION_ASSIST`, он живёт в
   `VoiceInteractionService`.

Проверки и ключи:

| Что | Команда | Смысл |
| --- | --- | --- |
| помощник вообще работает | `adb shell input keyevent KEYCODE_ASSIST` | идёт через `assistant`, минуя железо: если тут Gemini открылся — кнопка виновата, не Google |
| Google установлен | `pm path com.google.android.googlequicksearchbox` | без пакета `assistant` бессмыслен |
| Gemini отдельно | `pm path com.google.android.apps.bard` | не обязателен |
| жест | `settings put secure assist_gesture_enabled 1` | AOSP: удержание питания открывает помощника |
| жест без экрана | `settings put secure assist_gesture_wake_enabled 1` | то же на заблокированном экране |

Порядок настройки на CN-прошивке: Настройки → Google (базовые сервисы) → поставить Google и
Gemini из Play Маркета → в приложении Google выбрать Gemini помощником → только потом трогать
ключи кнопки.

---

## 2.99. «Gemini не поддерживается в вашей стране» — кнопка тут ни при чём

Симптом: кнопка настроена правильно (`assistant` = `GsaVoiceInteractionService`,
`assist_gesture_enabled=1`, `speech_assist_power_wakeup=0`), Breeno с кнопки снят,
но `input keyevent KEYCODE_ASSIST` не открывает ничего, а само приложение Gemini
пишет «Gemini пока не поддерживается в вашей стране».

Это региональная блокировка Google, а не поломка прошивки. Она двухслойная:

| Слой | Как проверяется | Что делать |
| --- | --- | --- |
| IP-адрес | `gemini.google.com` в инкогнито под VPN поддерживаемой страны | VPN с чистым (не датацентровым) IP; в РФ OpenVPN/WireGuard режет DPI — нужен VLESS/Reality или обфускация |
| Регион аккаунта | `policies.google.com/country-association-form` | смена страны в платёжном профиле (раз в год, нужна карта страны) или новый аккаунт, созданный под зарубежным IP |
| Регион Play | приложение Gemini в Play не ставится/не запускается | Play → Настройки → Страна и профиль; либо веб-версия вместо приложения |

Порядок проверки, который экономит время:

1. Включить VPN, открыть `gemini.google.com` в инкогито на телефоне под нужным аккаунтом.
2. Работает — аккаунт в порядке, кнопка заработает после того, как приложение Google
   поднимет сессию помощника.
3. Не работает — смотреть `country-association-form`: если там Россия, VPN не поможет,
   нужен другой аккаунт.

Практическое следствие: помощник на кнопке питания живёт в фоне и должен открываться
мгновенно, а VPN в РФ часто отваливается и расходует батарею. Поэтому «Gemini по кнопке»
на российской сети — конструкция хрупкая, и это стоит понимать до настройки.

---

## 2.990. Последний неотработанный ключ: `settings global side_button`

Полный дамп глобальных ключей с «power»/«button» на PKG110:

```
power_button_long_press=5                  (игнорируется, см. 2.991)
power_button_long_press_duration_ms=350
emergency_gesture_power_button_cooldown_period_ms=3000
power_sounds_enabled=1
side_button=1                              ← единственный, который мы не трогали
```

Пункта про кнопку питания в настройках CN-прошивки **нет** (проверено поиском по
настройкам вручную), то есть вендорского переключателя «Google на долгое нажатие»
здесь не существует — в отличие от глобальных сборок, где он есть, но не работает.

`side_button` остаётся последним кандидатом. Что он переключает в ColorOS,
достоверно неизвестно: у OPPO/OnePlus этим именем исторически называли и боковую
кнопку, и ползунок режимов звука. Поэтому перебор сделан безопасно:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-one-click.ps1 -Sweep
```

Скрипт по очереди ставит `side_button` = 0, 2, 3, 4, 1, в каждом раунде просит
зажать питание на 2 секунды, слушает окна и:

* если появился помощник — останавливается и оставляет рабочее значение;
* если снова `ActionsDialog` — идёт дальше;
* если ни одно значение не сработало — **возвращает исходное**.

Побочный эффект возможен только один: если `side_button` окажется ползунком
режимов, телефон на время прогона переключится в другой звуковой режим. Возврат
значения возвращает и режим.

Отсюда же простое правило на будущее: прежде чем обещать что-то про кнопку
питания на ColorOS, проверь, есть ли в глобальных ключах `side_button` и что он
делает на конкретной прошивке.

### Результат перебора на PKG110 (27.10.2026)

```
side_button=0: меню выключения
side_button=2: меню выключения
side_button=3: меню выключения
side_button=4: меню выключения
side_button=1: меню выключения
```

Все пять значений дали тот же `ActionsDialog`. Значит `side_button` на этой
прошивке к кнопке питания отношения не имеет (скорее всего это профиль звука).

**Кнопка питания закрыта окончательно.** На PKG110 / ColorOS 16.1 (CN) удержание
питания не переназначается ни одним доступным из shell способом:

| способ | результат |
| --- | --- |
| `power_button_long_press=5` | значение принято, поведение не меняется |
| `key_home_long_press_action=2` | значение принято, поведение не меняется |
| `side_button=0/1/2/3/4` | всегда меню выключения (`ActionsDialog`) |
| пункт в настройках | отсутствует в CN-прошивке |
| `speech_assist_power_wakeup=0` | снимает Breeno, но помощника не подставляет |

Дальше только root/кастомная прошивка. Штатный путь вызова Gemini на этом
телефоне: **смахнуть от нижнего угла** (надёжнее с экрана блокировки) или
**виджет/ярлык Gemini** на рабочем столе.

---

## 2.991. Что реально открывает удержание питания: `ActionsDialog`

Первый честный замер «нажимает человек, скрипт слушает» на PKG110:

```
>> питание: зажми кнопку питания на 2 секунды
     5,3 с: в фокусе mCurrentFocus=Window{7abc414 u0 ActionsDialog}
     5,3 с: новое окно ActionsDialog

>> жест: смахни вверх от нижнего угла
     (ни новых окон, ни смены фокуса)
```

`ActionsDialog` — это **меню выключения** ColorOS. То есть удержание кнопки питания
на V16.1.0 честно открывает меню, а не помощника, при выставленных
`power_button_long_press=5` и `key_home_long_press_action=2`. Это ровно то, на что
жалуются владельцы OnePlus после 16.0.3.501: пункт «Google-помощник на долгое
нажатие питания» в настройках есть, но выходит меню выключения.

Вывод, который стоит перестать проверять заново: **без рута кнопку питания на этой
прошивке помощнику не отдать**. Ключи AOSP она принимает в базу и игнорирует.
Остаётся жест, и он тоже живёт не везде: в замере с главного экрана от нижнего угла
не сработал ни разу, а на **экране блокировки** помощник открывался оверлеем.

Практика: если помощник нужен быстро — экран блокировки + смахнуть от нижнего угла,
либо ярлык/виджет помощника на рабочем столе.

---

## 2.992. Инжектированные события ColorOS не исполняет — проверка только руками

Замер «5 попыток кнопкой, 5 попыток жестом» через adb на PKG110 дал **0 из 5 по
обоим путям**, при том что палец в то же время открывал Gemini. Причина в способе
эмуляции:

| эмуляция | что происходит |
| --- | --- |
| `input keyevent --longpress 26` | событие уходит, но SystemUI/ColorOS не трактует его как «удержание питания → помощник» |
| `input swipe 0.02W H-10 0.5W 0.55H 300` | corner-жест помощника не срабатывает: ромно-специфичный детектор угловых свайпов не реагирует на инжектированные touch-события |

Вывод: **удержание кнопки питания и угловой жест помощника на ColorOS из shell не
воспроизводятся вообще**. Ни `KEYCODE_ASSIST`, ни `--longpress 26`, ни `input swipe`
не годятся как проверка. Единственный достоверный источник — палец пользователя.

Поэтому `-Test` больше ничего не эмулирует: он **слушает**. Пятнадцать секунд
опрашивает `dumpsys window`, запоминает исходный набор окон, печатает каждое новое
окно и каждую смену фокуса с секундами, и по ним решает. Если помощник открылся
оверлеем, в списке появится его окно — а `mCurrentFocus` при этом может не
измениться (см. 2.993).

Что это даёт на практике: замер перестал быть «тестом», который врёт, и стал
журналом фактов, который можно прислать в чат.

---

## 2.993. Помощник открывается ОВЕРЛЕЕМ — вот почему замер врал

Главное наблюдение с устройства: Gemini приходит не полноэкранным приложением, а
**сессией голосового взаимодействия** — маленьким окном «как входящий звонок»,
поверх блокировки, и работает даже при выключенном экране.

Отсюда две вещи:

1. Такое окно имеет тип `TYPE_VOICE_INTERACTION` и **не забирает фокус**. На
   заблокированном экране `mCurrentFocus` остаётся у `NotificationShade` или
   `launcher`, хотя Gemini уже висит поверх и отвечает.
2. Любая проверка вида «mCurrentFocus содержит googlequicksearchbox» его **не
   видит**. Именно поэтому `-Test` выдал 0 из 5 по обоим путям — при том, что
   помощник в этот момент реально открывался.

Смотреть надо список окон, а не фокус:

```
adb shell dumpsys window windows | Select-String -Pattern "VoiceInteraction|AssistPreview|googlequicksearchbox"
```

В скрипте теперь три независимых источника улик — фокус, список окон и журнал
событий (`am_focused_activity`), — и попытка считается успешной по любому из них.
Плюс `Reset-Screen`: перед каждой попыткой экран будится (`KEYCODE_WAKEUP`),
меню/помощник закрываются (`BACK`, `HOME`), и если телефон всё-таки заблокирован,
скрипт честно говорит «разблокируй», а не пишет «не работает».

**Практический вывод:** оверлей поверх блокировки — это не баг, а самый удобный
режим: телефон в кармане, экран погашен, удержал кнопку — Gemini слушает.

---

## 2.994. Замер: питание против жеста (`-Test`)

Скрипт умеет мерить, не меняя настроек:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gemini-one-click.ps1 -Test
```

Делает по 5 попыток двумя путями и печатает секунды до окна помощника:

| путь | чем эмулируется |
| --- | --- |
| удержание кнопки питания | `input keyevent --longpress 26` — тот же путь в PhoneWindowManager, что у физической кнопки |
| жест от нижнего угла | `input swipe 0.03W H-12 0.5W 0.55H 300` — реальные touch-события, их ловит SystemUI |

На PKG110 (ColorOS 16.1) результат был такой: **питание — 0 попаданий,
жест — попадает, но через раз** (холодный старт Gemini).

Вывод: кнопка питания помощнику на этой прошивке не отдаётся. Выбор
«Google-помощник на долгое нажатие питания» в ColorOS 16 есть в настройках,
но не работает (жалобы на r/oneplus после 16.0.3.501), и ключами AOSP
(`power_button_long_press`, `key_home_long_press_action`) это не лечится —
они выставляются, но SystemUI их игнорирует. Рабочий путь — жест.

Почему жест «через раз»: первый вызов поднимает процесс GSA с нуля. Лечится
тремя вещами — снять заморозку (`cached_apps_freezer=disabled`) и перезагрузиться,
закрепить карточку Gemini в «недавних», и дать приложению батарею без ограничений.

---

## 2.995. Кто держит кнопку питания

На PKG110 кнопку разбирают два независимых механизма, и они не конфликтуют:

| Ключ | Значение | Поведение |
| --- | --- | --- |
| `settings get secure speech_assist_power_wakeup` | `1` | долгое нажатие отдаётся `com.heytap.speechassist` (Breeno) |
| | `0` | Breeno с кнопки снят, остаётся заводское меню «Выключить / Перезагрузить» |
| `settings get secure assist_gesture_enabled` | `1` | AOSP-жест: удержание питания открывает помощника из `assistant` |
| | `0` | жест выключен |

Важное наблюдение по этому устройству: **из коробки `assistant` уже указывал на
`GsaVoiceInteractionService`** — бэкап, снятый до всех правок, содержит именно Google.
То есть прошивка пришла с настроенным Google, а Breeno параллельно держал кнопку.

Отсюда простой вывод: если Gemini доступен аккаунту, достаточно `speech_assist_power_wakeup=0`
и `assist_gesture_enabled=1`. Если Gemini регионом закрыт — оба ключа бесполезны, потому что
открывать нечего.

---

## 2.999. Что в итоге сработало на PKG110 (ColorOS 16.1)

Проверено на живом устройстве, сверху вниз:

| Шаг | Команда/ключ | Итог |
| --- | --- | --- |
| Google назначен помощником | `settings --user 0 put secure assistant …GsaVoiceInteractionService` | окно `googlequicksearchbox` поднимается |
| Breeno снят с кнопки | `settings put secure speech_assist_power_wakeup 0` | иначе кнопку забирает `com.heytap.speechassist` |
| жест включён | `assist_gesture_enabled 1`, `assist_gesture_wake_enabled 1` | удержание питания поднимает robin-активити |
| сеть под помощником | `always_on_vpn_app com.happproxy` + whitelist | без VPN Gemini отдаёт «ошибку 1060» (регион) |
| долгое нажатие полосы | `assist_long_press_home_enabled 1` | запасной вызов, работает даже когда кнопка не отдаётся |

Что **не** работает из shell на этой прошивке и не нужно пытаться:

- `appops set …` любых операций → `uid 2000 does not have MANAGE_APP_OPS_MODES`;
- `pm grant … READ_LOGS` → `Neither user 2000 nor current process has android.permission.GRANT_RUNTIME_PERMISSIONS`;
- поэтому ColorGoogle (единственный перехватчик питания без root) здесь не настраивается.

Проверка «открылось ли» надёжнее всего по фокусу окна:

```
adb shell dumpsys window   → искать mCurrentFocus=Window{… com.google.android.googlequicksearchbox}
```

Всё перечисленное делает один скрипт: `scripts/gemini-one-click.ps1` (откат — `-Restore`).

---

## 2.998. Запустить Gemini из shell нельзя — вообще

Попытка измерить холодный старт напрямую:

```
adb shell am start -W -n com.google.android.googlequicksearchbox/com.google.android.apps.search.assistant.surfaces.voice.robin.main.MainActivity
```

даёт

```
java.lang.SecurityException: Permission Denial: starting Intent { ... mCallingUid=2000 }
from null (pid=4558, uid=2000) not exported from uid 10128
```

Активность `robin` (интерфейс Gemini) **не exported**: uid 2000 (shell) её запускать не
имеет права. Значит:

* `am start` для Gemini/robin бесполезен — ни как «прогрев», ни как проверка;
* проверять кнопку можно только теми путями, которыми ходит сама система:
  роль помощника + key event (`input keyevent --longpress 26`).

Цена ошибки: именно из-за этого `KEYCODE_ASSIST`/`am start` выдавали «ничего не
произошло», хотя физическая кнопка работала.

**Что ещё видно в `settings list secure` на PKG110:**

```
assist_gesture_enabled=1            assist_gesture_wake_enabled=1
assist_long_press_home_enabled=1    key_home_long_press_action=2
assistant=…googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService
default_voice_assist_picker_service=…GsaVoiceInteractionService
speech_assist_power_wakeup=0
assistant_screen_type=2             assistant_screen_type_left_enable=0
```

`assistant_screen_type` — это **не** кнопка питания: ключ отвечает за панель Google
Discover слева от рабочего стола (2 = Discover есть, 0 = нет), и у него есть
дубликат с опечаткой `asistant_screen_type`. Не путать с помощником по кнопке.

`cached_apps_freezer` на этой прошивке равен `device_default`, а не `enabled`:
решение о заморозке принимает сама ColorOS, поставить `disabled` можно, но эффект
проверять только после перезагрузки.

---

## 2.997. «Помощник открылся через минуту» и подсказка на экране блокировки

Два разных явления, которые легко принять за одно.

**Долгая задержка.** Окно Gemini появляется через 20–60 с после нажатия. Это не
«кнопка не работает», а холодный старт: ColorOS держит фоновые приложения
замороженными (`cached_apps_freezer`), а Google просыпается через VPN-туннель.
Снимается так:

```
adb shell settings get global cached_apps_freezer      # enabled по умолчанию
adb shell settings put global cached_apps_freezer disabled
```

Полный эффект — после перезагрузки. Обратная сторона: больше памяти занято
фоновыми приложениями, батарея чуть быстрее садится.

**Подсказка «смахните, чтобы использовать цифровой помощник» на локскрине.**
Это системная плашка SystemUI о том, что жест снизу теперь отдан помощнику —
появляется, когда назначен помощник и включены `assist_gesture_enabled` /
`assist_long_press_home_enabled` / `key_home_long_press_action`. Сама по себе она
ничего не запускает; если помощник в этот момент ещё грузится, выглядит как
«смахнул — ничего». Проверить, какие ключи реально стоят:

```
adb shell settings list secure | Select-String -Pattern "assist|key_home"
```

**Почему нельзя верить программной проверке кнопки.** `input keyevent 219`
(`KEYCODE_ASSIST`) на ColorOS поднимает окно через раз: запуск из shell упирается
в ограничения фонового старта активности. Плюс один замер фокуса через
фиксированную паузу даёт ложный вердикт «открылось другое приложение».
Надёжнее эмулировать само удержание питания — `input keyevent --longpress 26`:
это тот же путь в `PhoneWindowManager`, что и у физической кнопки. И фокус надо
опрашивать несколько секунд подряд, а не один раз.

---

## 2.9965. Скрипт для плеера: `scripts/lockscreen-player.ps1`

Проверка и включение карточки плеера одной командой:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\lockscreen-player.ps1
```

Что делает:

1. ставит `media_controls_lock_screen=1` и `lockscreen_show_controls=1`, печатает
   прежнее значение;
2. читает `dumpsys media_session` и показывает, какое приложение реально играет и
   в каком состоянии (`state=3` — играет);
3. находит уведомление этого приложения в `dumpsys notification --noredact` и
   печатает **канал и его важность**;
4. выносит вердикт по одному из трёх сценариев:
   * важность канала ниже DEFAULT (3) — ColorOS такие уведомления на локскрин не
     выносит, поднять можно только в настройках (каналы меняет приложение/человек,
     не shell);
   * приложение играет, но уведомления не публикует — системный плеер ему
     недоступен, это ограничение приложения;
   * всё на месте — значит ром выносит только свой плеер.

Зачем скрипт, если причина известна: `media_controls_lock_screen` мог вернуться в
`0` после перезагрузки, а важность канала у каждого плеера своя. Скрипт отвечает
на вопрос «что именно мешает» без перебора настроек вслепую.

Первый прогон на реальном устройстве дал `state=-1` — разбор был наивным: в
`dumpsys media_session` строка `package=` встречается больше одного раза на сессию,
и состояние сбрасывалось. Теперь дамп режется по `MediaSessionRecord{`, состояние
читается из `PlaybackState {state=N}` внутри блока, а `-Raw` печатает сырые строки,
если формат снова окажется другим.

Ещё важно: скрипт больше не выходит с «ничего не играет» — он показывает все сессии
и всё равно проверяет уведомления, потому что карточка плеера на локскрине висит и
на паузе.

**Формат состояния в Android 16.** Реальный дамп (PKG110, Android 16):

```
    package=com.android.server.telecom
      package=re.sova.five
      state=PlaybackState {state=PLAYING(3), position=0, buffered position=0, ...}
```

Два урока:

* состояние печатается как `PLAYING(3)`, а не `3` — регулярка на голое число не
  ловит;
* `package=` в дампе идёт несколько раз подряд, и первым стоит
  `com.android.server.telecom` (служебная запись). Состояние относится к
  **последней** увиденной записи, а `com.android.*` надо вообще не показывать.

После правки скрипт печатает `re.sova.five: играет (state=3)` и переходит к
важности канала.

**Кэш raw.githubusercontent.** После правки скрипта старый файл может ещё отдаваться
из кэша CDN: в логе видно старые фразы, которых в `main` уже нет. Поэтому у скрипта
теперь есть `$ScriptVersion` и он печатает её первой строкой. Если версия старая —
качать с обходом кэша:

```powershell
$u = 'https://raw.githubusercontent.com/loschd22211/drag-5-voopoo/main/scripts/lockscreen-player.ps1?x=' + (Get-Random)
Invoke-WebRequest $u -OutFile .\scripts\lockscreen-player.ps1 -UseBasicParsing
```

---

## 2.996. Плеер на экране блокировки (сторонние приложения)

Симптом: китайский плеер на локскрине виден, а Sova / VK / Spotify — нет.

Причина в одном ключе:

```
settings get secure media_controls_lock_screen   → 0
```

`0` означает «карточку плеера на экране блокировки не показывать»; для системного
плеера ColorOS тянет её своим механизмом (`media_button_receiver=com.heytap.music/...`),
поэтому он работает и при нуле. Лечение:

```
adb shell settings put secure media_controls_lock_screen 1
adb shell settings put secure lockscreen_show_controls 1
```

Если после этого карточки нет — смотреть уведомление плеера. У Sova, например,
уведомление есть (`channel=audio_playback_channel`, группа `music_player_group`,
кнопки «предыдущая / воспроизвести / следующая»), но `importance=2` (LOW):
ColorOS такие уведомления на локскрин не выносит. Поднимается в
`Настройки → Уведомления → приложение → важность`.

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
