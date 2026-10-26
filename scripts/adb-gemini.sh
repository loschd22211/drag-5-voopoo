#!/usr/bin/env bash
# CLI-версия инструмента: назначает Google/Gemini помощником на долгое нажатие
# кнопки питания через ADB. Работает в Linux и macOS.
#
#   ./scripts/adb-gemini.sh              # интерактивно, первый подключённый телефон
#   ./scripts/adb-gemini.sh <serial>     # конкретное устройство
#   ADB=/path/to/adb ./scripts/adb-gemini.sh

set -u

ADB="${ADB:-adb}"
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────"; }

ask() {
  # ask "вопрос" -> 0 если да
  local answer
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes|YES|д|Д|да|ДА) return 0 ;; *) return 1 ;; esac
}

need_adb() {
  if ! command -v "$ADB" >/dev/null 2>&1; then
    err "adb не найден в PATH."
    say "Поставь Android platform-tools: https://developer.android.com/tools/releases/platform-tools"
    say "Или укажи путь: ADB=/путь/к/adb $0"
    exit 1
  fi
  dim "$("$ADB" version | head -n1)"
}

pick_serial() {
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    SERIAL="$1"
    return
  fi
  DEVICES=()
  while IFS= read -r line; do
    [ -n "$line" ] && DEVICES+=("$line")
  done < <("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ ${#DEVICES[@]} -eq 0 ]; then
    err "Ни одного телефона в режиме device."
    say "Проверь: кабель, «Отладка по USB», подтверждение отпечатка на экране телефона."
    say "Состояние устройств:"; "$ADB" devices -l
    exit 1
  fi
  SERIAL="${DEVICES[0]}"
  if [ ${#DEVICES[@]} -gt 1 ]; then
    warn "Подключено несколько устройств, беру первое: $SERIAL"
  fi
}

sh_() { "$ADB" -s "$SERIAL" shell "$1"; }

main() {
  need_adb
  pick_serial "$@"

  hr
  say "Устройство: $SERIAL"
  local model android rom
  model=$(sh_ 'getprop ro.product.model' | tr -d '\r')
  android=$(sh_ 'getprop ro.build.version.release' | tr -d '\r')
  rom=$(sh_ 'getprop ro.build.version.oplusrom' | tr -d '\r')
  [ -z "$rom" ] && rom=$(sh_ 'getprop ro.build.display.id' | tr -d '\r')
  say "  модель:   $model"
  say "  Android:  $android"
  say "  прошивка: $rom"
  case "$model" in
    PLK*|PKG*|PHK*|PJD*) warn "Похоже на китайскую сборку — пункт в настройках может не работать, это норма." ;;
  esac

  hr
  say "Проверяю Google-компоненты…"
  local packages
  packages=$(sh_ 'pm list packages')
  for p in com.google.android.gms com.google.android.googlequicksearchbox com.google.android.apps.bard com.android.vending; do
    if printf '%s\n' "$packages" | grep -q "package:$p\$"; then ok "$p"; else warn "$p — НЕТ"; fi
  done

  hr
  say "Текущий помощник:"
  local cur_voi cur_ass
  cur_voi=$(sh_ 'settings get secure voice_interaction_service' | tr -d '\r')
  cur_ass=$(sh_ 'settings get secure assistant' | tr -d '\r')
  say "  assistant:                 ${cur_ass:-<не задан>}"
  say "  voice_interaction_service: ${cur_voi:-<не задан>}"

  hr
  say "Ищу голосовые сервисы Google на устройстве…"
  local services component
  services=$(sh_ 'cmd package query-services -a android.service.voice.VoiceInteractionService --brief' 2>/dev/null)
  if ! printf '%s' "$services" | grep -q '/'; then
    services=$(printf '%s\n' \
      'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService')
    dim "запрос сервисов не поддержан прошивкой, беру известный компонент"
  fi
  printf '%s\n' "$services" | grep '^com\.' | sed 's/^/  /'
  component=$(printf '%s\n' "$services" | grep -o 'com\.google[a-zA-Z0-9_.]*/[A-Za-z0-9_.$]*VoiceInteractionService' | head -n1)
  if [ -z "$component" ]; then
    err "Не нашёл компонент Google-помощника. Установлены ли приложение Google и Gemini?"
    exit 1
  fi
  ok "Выбран компонент: $component"

  hr
  if ask "Назначить его цифровым помощником по умолчанию?"; then
    sh_ "settings put secure assistant $component"
    sh_ "settings put secure voice_interaction_service $component"
    local after_ass after_voi
    after_ass=$(sh_ 'settings get secure assistant' | tr -d '\r')
    after_voi=$(sh_ 'settings get secure voice_interaction_service' | tr -d '\r')
    say "  assistant:                 ${after_ass:-<пусто>}"
    say "  voice_interaction_service: ${after_voi:-<пусто>}"
    if [ "$after_ass" = "$component" ] || [ "$after_voi" = "$component" ]; then
      ok "Применилось. Зажми кнопку питания на телефоне (≈0,5 с)."
    else
      warn "Система не приняла значение (прошивка защищает настройку)."
      warn "Тогда: экраны из блока ниже + Activity Launcher / MiCTS — см. docs/coloros-cn-notes.md"
    fi
  else
    dim "пропускаю"
  fi

  hr
  say "Экраны настроек, которые есть на этом устройстве:"
  for pkg in com.oplus.settings com.coloros.settings com.android.settings; do
    printf '%s\n' "$packages" | grep -q "package:$pkg\$" || continue
    "$ADB" -s "$SERIAL" shell "dumpsys package $pkg" 2>/dev/null \
      | grep -oE "$pkg/[A-Za-z0-9_.$]+" \
      | sort -u \
      | grep -iE 'power|button|assist|convenience|google' \
      | sed 's/^/  /'
  done

  say ""
  if ask "Открыть на телефоне «Приложения по умолчанию»?"; then
    sh_ 'am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS' >/dev/null 2>&1 \
      && ok "открыто" || warn "intent не сработал — открой вручную"
  fi

  hr
  if ask "Проверить запуск ассистента командой (телефон должен быть разблокирован)?"; then
    out=$(sh_ 'am start -a android.intent.action.VOICE_COMMAND' 2>&1)
    if printf '%s' "$out" | grep -qiE 'error|unable'; then
      err "ассистент не запустился: $out"
    else
      ok "команда ушла — смотри на экран телефона"
    fi
  fi

  hr
  dim "Готово. Если пункт в настройках всё равно не работает — docs/coloros-cn-notes.md"
}

main "$@"
