#!/usr/bin/env bash
# Одна команда: сам скачивает adb, сам находит телефон, сам ставит Google вместо Breeno.
# Ничего не спрашивает. Linux / macOS.
#
#   bash scripts/oneclick.sh
#
# Если adb уже установлен — используется он, ничего не качается.

set -u

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()  { err "$*"; exit 1; }

GOOGLE_SERVICE="com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gemini-power-button"
ADB_BIN="${ADB:-}"

# ---------------------------------------------------------------- adb

find_or_install_adb() {
  if [ -n "${ADB:-}" ] && [ -x "${ADB%% *}" ]; then
    ADB_BIN="$ADB"; ok "использую adb из ADB: $ADB_BIN"; return
  fi
  if command -v adb >/dev/null 2>&1; then
    ADB_BIN="adb"; ok "adb уже установлен: $(command -v adb)"; return
  fi
  if [ -x "$CACHE_DIR/platform-tools/adb" ]; then
    ADB_BIN="$CACHE_DIR/platform-tools/adb"; ok "adb из кэша: $ADB_BIN"; return
  fi

  case "$(uname -s)" in
    Linux)  zip_url="https://dl.google.com/android/repository/platform-tools-latest-linux.zip" ;;
    Darwin) zip_url="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" ;;
    *) die "неизвестная система $(uname -s). Поставь platform-tools вручную." ;;
  esac

  command -v unzip >/dev/null 2>&1 || die "нужен unzip. Linux: sudo apt install unzip / brew install unzip"

  step "adb не найден — качаю platform-tools от Google (~10 МБ)"
  mkdir -p "$CACHE_DIR" || die "не могу создать $CACHE_DIR"
  local zip="$CACHE_DIR/platform-tools.zip"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "$zip_url" -o "$zip" || die "не удалось скачать platform-tools (нет интернета?)"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress "$zip_url" -O "$zip" || die "не удалось скачать platform-tools"
  else
    die "нужен curl или wget"
  fi
  unzip -oq "$zip" -d "$CACHE_DIR" || die "не удалось распаковать архив"
  chmod +x "$CACHE_DIR/platform-tools/adb" 2>/dev/null || true
  ADB_BIN="$CACHE_DIR/platform-tools/adb"
  ok "adb готов: $ADB_BIN"
}

# ---------------------------------------------------------------- устройство

claim_device() {
  step "Ищу телефон"
  local devices=()
  while IFS= read -r line; do
    [ -n "$line" ] && devices+=("$line")
  done < <("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}')

  if [ ${#devices[@]} -eq 0 ]; then
    local unauthorized=()
    while IFS= read -r line; do
      [ -n "$line" ] && unauthorized+=("$line")
    done < <("$ADB_BIN" devices | awk 'NR>1 && $2!="device" && $1!="" {print $1" "$2}')
    err "Телефон не виден."
    if [ ${#unauthorized[@]} -gt 0 ]; then
      warn "Вижу устройство, но оно не авторизовано: ${unauthorized[*]}"
      warn "Посмотри на экран телефона — там должно быть окошко «Разрешить отладку по USB?» → Разрешить."
    else
      warn "Проверь по порядку:"
      warn "  1. Кабель нормальный (не только для зарядки), воткнут в компьютер напрямую."
      warn "  2. На телефоне: Настройки → Для разработчиков → «Отладка по USB» ВКЛ."
      warn "  3. Режим USB менять не нужно — любой подходит."
      warn "  4. Если окошко с отпечатком было и ты нажал «Отмена» — отключи и подключи кабель снова."
    fi
    die "Останавливаюсь: без телефона дальше нельзя."
  fi

  SERIAL="${devices[0]}"
  if [ ${#devices[@]} -gt 1 ]; then
    warn "Подключено несколько устройств, беру первое: $SERIAL"
    dim "другие: ${devices[*]:1}"
  fi
  ok "телефон на связи: $SERIAL"
}

sh_() { "$ADB_BIN" -s "$SERIAL" shell "$1" 2>&1 | tr -d '\r'; }

# ---------------------------------------------------------------- main

find_or_install_adb
claim_device

step "1/6  Проверяю сборку телефона"
model=$(sh_ 'getprop ro.product.model')
android=$(sh_ 'getprop ro.build.version.release')
rom=$(sh_ 'getprop ro.build.version.oplusrom')
[ -z "$rom" ] && rom=$(sh_ 'getprop ro.build.display.id')
region=$(sh_ 'getprop ro.build.region')
printf '  модель:   %s\n  Android:  %s\n  прошивка: %s\n  регион:   %s\n' \
  "${model:-?}" "${android:-?}" "${rom:-?}" "${region:-?}"
case "$model" in
  PLK*|PKG*|PHK*|PJD*|PJF*|PJH*) warn "это китайская сборка — именно на них Breeno и не даёт выбрать Google" ;;
esac

step "2/6  Что установлено из Google"
packages=$(sh_ 'pm list packages')
have_google_app=0; have_gms=0; have_gemini=0
printf '%s\n' "$packages" | grep -q 'package:com.google.android.googlequicksearchbox$' && { ok "приложение Google"; have_google_app=1; } || warn "приложения Google НЕТ"
printf '%s\n' "$packages" | grep -q 'package:com.google.android.gms$' && { ok "Google Play services"; have_gms=1; } || warn "Google Play services НЕТ"
printf '%s\n' "$packages" | grep -q 'package:com.google.android.apps.bard$' && { ok "Gemini"; have_gemini=1; } || warn "Gemini НЕТ (без него кнопка будет звать старый Ассистент)"
printf '%s\n' "$packages" | grep -qi 'package:com.oplus.breeno' && warn "найден Breeno — сейчас он и перехватывает кнопку"

step "3/6  Ищу голосовой сервис Google на устройстве"
component=$(sh_ 'cmd package query-services -a android.service.voice.VoiceInteractionService --brief' \
  | grep -o 'com\.google[A-Za-z0-9_.]*/[A-Za-z0-9_.$]*VoiceInteractionService' | head -n1)
if [ -z "$component" ]; then
  component="$GOOGLE_SERVICE"
  warn "прошивка не отдала список — беру стандартный компонент"
fi
ok "компонент: $component"

step "4/6  Назначаю Google цифровым помощником (вместо Breeno)"
sh_ "settings put secure assistant $component" >/dev/null 2>&1
sh_ "settings put secure voice_interaction_service $component" >/dev/null 2>&1
after_ass=$(sh_ 'settings get secure assistant')
after_voi=$(sh_ 'settings get secure voice_interaction_service')
printf '  assistant:                 %s\n  voice_interaction_service: %s\n' "${after_ass:-<пусто>}" "${after_voi:-<пусто>}"

applied=0
{ [ "$after_ass" = "$component" ] || [ "$after_voi" = "$component" ]; } && applied=1

step "5/6  Проверяю, что ассистент запускается"
probe=$(sh_ 'am start -a android.intent.action.VOICE_COMMAND')
if printf '%s' "$probe" | grep -qiE 'error|unable to resolve'; then
  warn "команда запуска не сработала — это нормально, если телефон заблокирован"
else
  ok "команда запуска ушла — глянь на экран телефона"
fi

step "6/6  Итог"

if [ $applied -eq 1 ] && [ $have_google_app -eq 1 ]; then
  ok "Google назначен помощником. Зажми кнопку питания на 0,5 секунды и проверь."
  dim "Если всё равно открывается Breeno или меню питания — смотри блок ниже."
else
  if [ $have_google_app -eq 0 ]; then
    err "Сначала поставь приложение Google и Gemini (Play Маркет), иначе назначать нечего."
    dim "На китайской прошивке сначала: Настройки → Система и обновления → Настройки Google → включить GMS."
  else
    err "Прошивка не приняла настройку — она защищает выбор помощника. Это не лечится adb."
  fi
fi

# экраны под кнопку питания
step "Что ещё есть на телефоне (открываю нужный экран)"
power_activity=""
for pkg in com.oplus.settings com.coloros.settings com.android.settings; do
  printf '%s\n' "$packages" | grep -q "package:$pkg\$" || continue
  while IFS= read -r act; do
    [ -z "$act" ] && continue
    dim "  $act"
    case "$act" in
      *PowerButton*|*power*|*ButtonAndGesture*) [ -z "$power_activity" ] && power_activity="$act" ;;
    esac
  done < <("$ADB_BIN" -s "$SERIAL" shell "dumpsys package $pkg" 2>/dev/null | grep -oE "$pkg/[A-Za-z0-9_.$]+" | sort -u | grep -iE 'power|button|assist|convenience|google')
done

if [ -n "$power_activity" ]; then
  sh_ "am start -n $power_activity" >/dev/null 2>&1 && ok "открыл на телефоне экран: $power_activity"
  dim "Там выбери «Цифровой помощник» вместо меню питания/Breeno."
else
  sh_ 'am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS' >/dev/null 2>&1 \
    && ok "открыл «Приложения по умолчанию» на телефоне"
fi

printf '\n%s— Готово —%s\n' "$C_B" "$C_OFF"
if [ $applied -eq 0 ]; then
  printf '%sЕсли экран с кнопкой питания не помог — остаётся один бесплатный путь без root:%s\n' "$C_DIM" "$C_OFF"
  printf '  1) Play Маркет → Activity Launcher\n'
  printf '  2) в нём в поиске: assistantguidedialog → запустить → Set\n'
  printf '  3) зажать кнопку питания\n'
  printf 'Подробнее: docs/coloros-cn-notes.md\n'
fi
printf '%sРежим USB менять не нужно. Отключить отладку можно потом: Настройки → Для разработчиков.%s\n' "$C_DIM" "$C_OFF"
