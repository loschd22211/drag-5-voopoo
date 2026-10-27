# Передача контекста

Состояние на 2026-10-27, ветка `arena/ad8ac788-drag-5-voopoo`, `main` = PR #1–#45.

## Устройство

OnePlus Ace 5 (PKG110), ColorOS 16.1 (`V16.1.0`), китайская сборка, Android 16.
Доступ только через adb по кабелю: `adb -s 544205f6`. Пользователь запускает
скрипты сам в Windows PowerShell 5.1, cwd `C:\Users\user`, репозиторий на рабочем
столе: `OneDrive\Desktop\drag-5-voopoo-arena-9556c5bb-drag-5-voopoo`.

## Что закрыто

* Кнопка питания → Gemini: **невозможно**. Роль `ASSISTANT` у Google, но SystemUI
  зовёт `com.heytap.speechassist` напрямую; после его выключения жест просто
  ничего не делает. Перебор `side_button` не завершён (скрипт `gemini-one-click.ps1
  -Sweep`), но ожидаемо ничего не даст (docs 2.988, 2.991).
* Ускорение телефона и чистка китайского: сделано, пользователь доволен.
* Плеер на локскрине: включены `media_controls_lock_screen` и
  `lockscreen_show_controls`. Карточки нет, потому что канал уведомления VK Совы
  (`re.sova.five`, `audio_playback_channel`) имеет `importance=2` из 5 — такие
  Android на локскрин не выносит. Из shell важность не меняется, только руками
  (docs 2.1008).

## Что осталось

* **Левая страница («热点资讯»)** не убирается. Диагностика: в разметке страницы
  только `com.android.launcher` (26 элементов), Google и Duolingo, иероглифов
  ноль; окно `com.coloros.assistantscreen` в `dumpsys window` есть, пакет
  приостановлен, лента остаётся. Вывод: рисует лончер (или ColorOS рисует её через
  поверхность лончера). Из adb не выключается — нужен переключатель в настройках
  рабочего стола (долгое нажатие на пустом месте → шестерёнка → 智能助手 / 负一屏 /
  资讯).
* **Счётчик шагов**: датчики есть (`step_counter`, `step_detector`), приложение
  «Здоровье» на устройстве — только `com.oplus.healthservice` (служба без иконки).
  Виджет ставится из приложения OHealth; `widgets-fix.ps1` включает обратно всё,
  что гасили.
* Пользователь просил больше не давать команд этим агентом; данные и скрипты
  лежат в репозитории.

## Грабли, на которые уже наступили

1. `raw.githubusercontent.com` отдаёт кэш. Скачивание только через
   `api.github.com/repos/.../contents/...?ref=main` + `[IO.File]::WriteAllBytes`.
2. Пользователь запускает блок без первой строки `cd` → `WriteAllBytes` падает на
   `C:\Users\user\scripts\...`. Всегда давать `cd` первой строкой одного блока.
3. Устаревшая копия скрипта в папке: по выводу не видно версии. Поэтому в скриптах
   печатается `версия скрипта`; сверять её с `main`.
4. `"$var: текст"` — ParserError в PS 5.1, только `${var}:`.
5. `pm suspend` не убивает процесс: после выключения пакета нужен `am force-stop`,
   иначе окно остаётся на экране.
6. Массовое «выключить всё китайское» (список из 157 пакетов) снесло обои,
   будильник, файлы и звук. Так делать нельзя; возврат — `scripts/restore-cn.ps1`.
7. `pm uninstall` не использовать: только `disable-user` / `suspend` /
   `restore-cn.ps1`.
8. Гейм-бар и Game Space (`com.oplus.games`, `com.oplus.gamemode`,
   `com.coloros.gamespaceui`) не трогать никогда.
9. Файлы `scripts/*.ps1` — UTF-8 **с BOM**, иначе PS 5.1 показывает кракозябры и
   падает на скобках.

## Скрипты

| файл | назначение |
|---|---|
| `scripts/left-panel.ps1` | левая страница: свайп по `wm size`, скриншот-hash, force-stop, `-Find`, `-Restore` |
| `scripts/restore-cn.ps1` | включает обратно всё китайское, ничего не выключает |
| `scripts/widgets-fix.ps1` | возвращает поставщиков виджетов, печатает `dumpsys appwidget` |
| `scripts/steps-widget.ps1` | включает «Здоровье», проверяет датчик шагов |
| `scripts/lockscreen-player.ps1` | плеер на локскрине: ключи + важность канала, `-Raw` |
| `scripts/assistant-keys.ps1` | только чтение: роль, ключи power/assist/button |
| `scripts/debloat-cn.ps1` | деблоат CN (здоровье из списка убрано), `-Restore` |
| `scripts/breeno-gesture.ps1` | эксперимент с жестом Breeno, `-Panel`, `-Restore` |

Проверки: `npm test` → 39 тестов. Парсер PowerShell: `tree_sitter` +
`tree_sitter_powershell`, `/tmp/checkps.py` (пересоздавать при потере).
