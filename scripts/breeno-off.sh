#!/usr/bin/env bash
# Снимает фирменный ассистент (Breeno и родню), который перехватывает долгое нажатие
# кнопки питания. Обратимо, без root.
#
#   bash scripts/breeno-off.sh            # снять
#   bash scripts/breeno-off.sh --restore  # вернуть обратно
#   bash scripts/breeno-off.sh --yes      # без вопросов

set -u

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()  { err "$*"; exit 1; }

RESTORE=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --restore) RESTORE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
  esac
done

VENDOR_RE='breeno|voiceassist|speechassist|assistantscreen|aiunit'
DENY_RE='com\.oplus\.ocs$|coloros\.ota|oplus\.aiunit\.engine$'

ADB_BIN="${ADB:-adb}"
command -v "$ADB_BIN" >/dev/null 2>&1 || die "adb не найден. Сначала запусти scripts/oneclick.sh"

SERIAL=$("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
[ -n "$SERIAL" ] || die "телефон не виден: проверь кабель и «Отладку по USB»"
ok "телефон: $SERIAL"

sh_() { "$ADB_BIN" -s "$SERIAL" shell "$1" 2>&1 | tr -d '\r'; }

step "Смотрю, какие фирменные ассистенты есть"
all=$(sh_ 'pm list packages')
disabled=$(sh_ 'pm list packages -d')

CANDIDATES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  pkg="${line#package:}"
  printf '%s' "$pkg" | grep -qEi "$VENDOR_RE" || continue
  printf '%s' "$pkg" | grep -qEi "$DENY_RE" && continue
  CANDIDATES+=("$pkg")
  if printf '%s\n' "$disabled" | grep -qx "package:$pkg"; then
    dim "  $pkg — уже отключён"
  else
    dim "  $pkg — включён"
  fi
done < <(printf '%s\n' "$all")

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  ok "фирменных ассистентов не найдено — дело не в Breeno"
  dim "тогда смотри docs/coloros-cn-notes.md, раздел про Activity Launcher"
  exit 0
fi

step "Текущий помощник"
cur=$(sh_ 'settings get secure assistant')
dim "assistant: $cur"
printf '%s' "$cur" | grep -q 'com\.google' && ok "Google назначен помощником" || warn "помощник не Google — сначала scripts/oneclick.sh"

if [ "$RESTORE" -eq 1 ]; then
  step "Включаю фирменные ассистенты обратно"
  for pkg in "${CANDIDATES[@]}"; do
    out=$(sh_ "pm enable $pkg")
    printf '%s' "$out" | grep -qEi 'Error|Exception' && out=$(sh_ "cmd package install-existing $pkg")
    if printf '%s' "$out" | grep -qEi 'Error|Exception'; then warn "$pkg: $out"; else ok "$pkg включён"; fi
  done
  dim "Проверь: зажатие кнопки питания снова откроет Breeno."
  exit 0
fi

TO_DISABLE=()
for pkg in "${CANDIDATES[@]}"; do
  printf '%s\n' "$disabled" | grep -qx "package:$pkg" || TO_DISABLE+=("$pkg")
done

if [ ${#TO_DISABLE[@]} -eq 0 ]; then
  ok "все фирменные ассистенты уже отключены"
  exit 0
fi

step "Сейчас отключу: ${TO_DISABLE[*]}"
dim "Обратимо, без root: pm disable-user. Вернуть — scripts/breeno-off.sh --restore"

if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Продолжить? [y/N] " answer
  case "$answer" in y|Y|д|Д|да|ДА) ;; *) die "отменено" ;; esac
fi

STILL_ON=()
for pkg in "${TO_DISABLE[@]}"; do
  out=$(sh_ "pm disable-user --user 0 $pkg")
  if printf '%s' "$out" | grep -qEi 'Error|Exception|Unknown package'; then
    warn "$pkg — не вышло: $out"
    STILL_ON+=("$pkg")
  else
    ok "$pkg отключён"
  fi
done

step "Проверяю результат"
disabled_after=$(sh_ 'pm list packages -d')
FAILED=()
for pkg in "${TO_DISABLE[@]}"; do
  if printf '%s\n' "$disabled_after" | grep -qx "package:$pkg"; then
    ok "$pkg действительно отключён"
  else
    warn "$pkg всё ещё включён"
    FAILED+=("$pkg")
  fi
done

step "Пробую запустить ассистента"
probe=$(sh_ 'am start -a android.intent.action.VOICE_COMMAND')
if printf '%s' "$probe" | grep -qiE 'error|unable to resolve'; then
  warn "не запустился: $probe"
else
  ok "команда запуска ушла — глянь на экран телефона"
fi

printf '\n%s— Готово —%s\n' "$C_B" "$C_OFF"
if [ ${#FAILED[@]} -eq 0 ]; then
  ok "Breeno снят. Зажми кнопку питания на 0,5 секунды."
  dim "Если открывается меню выключения, а не Gemini — прогони scripts/oneclick.sh ещё раз."
else
  warn "Часть пакетов прошивка не дала отключить: ${FAILED[*]}"
  dim "Это защита ColorOS. Дальше — Activity Launcher (assistantguidedialog) или root."
fi
dim "Вернуть как было: bash scripts/breeno-off.sh --restore"
