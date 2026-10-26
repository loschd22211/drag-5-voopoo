#!/usr/bin/env bash
# Снимает фирменный ассистент Breeno (он же HeyTap speech assist), который перехватывает
# долгое нажатие кнопки питания на ColorOS. Обратимо, без root.
#
#   bash scripts/breeno-off.sh                 # снять голосовой ассистент + экран ассистента
#   bash scripts/breeno-off.sh --all           # ещё и AI-движок OPPO (нужен другим функциям!)
#   bash scripts/breeno-off.sh --uninstall     # для защищённых пакетов: uninstall --user 0
#   bash scripts/breeno-off.sh --restore       # вернуть всё как было
#   bash scripts/breeno-off.sh --yes           # без подтверждений
#
# На ColorOS 16 пакета com.oplus.breeno нет: Breeno разложен на части —
#   com.heytap.speechassist        голосовой ассистент
#   com.coloros.assistantscreen    экран ассистента
#   com.oplus.aiunit / com.aiunit.aon   AI-движок (может быть нужен галерее, переводу и т.п.)

set -u

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_ERR" "$C_OFF" "$*"; }
step() { printf '\n%s▸ %s%s\n' "$C_B" "$*" "$C_OFF"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()  { err "$*"; exit 1; }

RESTORE=0; ASSUME_YES=0; UNINSTALL=0; INCLUDE_ENGINE=0
for arg in "$@"; do
  case "$arg" in
    --restore) RESTORE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --all) INCLUDE_ENGINE=1 ;;
  esac
done

VENDOR_RE='breeno|heytap\.speechassist|voiceassist|speechassist|assistantscreen|aiunit'
# даже если пакет скрыт для пользователя и не виден в pm list packages
KNOWN_VENDOR='com.heytap.speechassist com.coloros.assistantscreen com.oplus.aiunit com.aiunit.aon com.oplus.breeno'
DENY_RE='com\.oplus\.ocs$|coloros\.ota'

ADB_BIN="${ADB:-adb}"
command -v "$ADB_BIN" >/dev/null 2>&1 || die "adb не найден. Сначала запусти scripts/oneclick.sh"

SERIAL=$("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
[ -n "$SERIAL" ] || die "телефон не виден: проверь кабель и «Отладку по USB»"
ok "телефон: $SERIAL"

sh_() { "$ADB_BIN" -s "$SERIAL" shell "$1" 2>&1 | tr -d '\r'; }

classify() {
  case "$1" in
    *speechassist*|*breeno*|*voiceassist*) echo "voice" ;;
    *assistantscreen*) echo "screen" ;;
    *aiunit*) echo "engine" ;;
    *) echo "other" ;;
  esac
}

human_role() {
  case "$1" in
    voice) echo "голосовой ассистент Breeno" ;;
    screen) echo "экран ассистента Breeno" ;;
    engine) echo "AI-движок OPPO (риск: нужен другим функциям)" ;;
    *) echo "фирменный ассистент" ;;
  esac
}

step "Смотрю, что установлено"
installed=$(sh_ 'pm list packages --user 0')
disabled=$(sh_ 'pm list packages -d')

CANDIDATES=()
for pkg in $(printf '%s\n' "$installed" | sed -n 's/^package://p'); do
  printf '%s' "$pkg" | grep -qEi "$VENDOR_RE" || continue
  printf '%s' "$pkg" | grep -qEi "$DENY_RE" && continue
  CANDIDATES+=("$pkg")
done
# добавим уже отключённые, чтобы --restore их тоже видел
for pkg in $(printf '%s\n' "$disabled" | sed -n 's/^package://p'); do
  printf '%s' "$pkg" | grep -qEi "$VENDOR_RE" || continue
  case " ${CANDIDATES[*]:-} " in *" $pkg "*) ;; *) CANDIDATES+=("$pkg") ;; esac
done
# при восстановлении проверяем ещё и известные имена: скрытые для пользователя пакеты
# не видны ни в pm list packages --user 0, ни в pm list packages -d
if [ "$RESTORE" -eq 1 ]; then
  for pkg in $KNOWN_VENDOR; do
    case " ${CANDIDATES[*]:-} " in *" $pkg "*) ;; *) CANDIDATES+=("$pkg") ;; esac
  done
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  ok "фирменных ассистентов не найдено"
  dim "тогда смотри docs/coloros-cn-notes.md, раздел про Activity Launcher"
  exit 0
fi

for pkg in "${CANDIDATES[@]}"; do
  role=$(classify "$pkg")
  state="включён"
  printf '%s\n' "$disabled" | grep -qx "package:$pkg" && state="отключён"
  printf '%s\n' "$installed" | grep -qx "package:$pkg" || state="скрыт для пользователя"
  printf '  %-34s %-28s %s\n' "$pkg" "$(human_role "$role")" "$state"
done

step "Текущий помощник"
cur=$(sh_ 'settings get secure assistant')
dim "assistant: $cur"
printf '%s' "$cur" | grep -q 'com\.google' && ok "Google назначен помощником" \
  || warn "помощник не Google — сначала запусти scripts/oneclick.sh"

# ------------------------------------------------------------------ restore

if [ "$RESTORE" -eq 1 ]; then
  step "Возвращаю фирменные ассистенты"
  for pkg in "${CANDIDATES[@]}"; do
    out=$(sh_ "pm enable $pkg")
    if printf '%s' "$out" | grep -qEi 'Error|Exception|Unknown package'; then
      out=$(sh_ "cmd package install-existing $pkg")
    fi
    if printf '%s' "$out" | grep -qEi 'Unknown package|not found'; then
      dim "$pkg: на этой сборке нет — пропускаю"
    elif printf '%s' "$out" | grep -qEi 'Error|Exception'; then
      warn "$pkg: $out"
    else
      ok "$pkg включён"
    fi
  done
  dim "Проверь: долгое нажатие снова откроет Breeno."
  exit 0
fi

# ------------------------------------------------------------------ disable

TARGETS=()
for pkg in "${CANDIDATES[@]}"; do
  role=$(classify "$pkg")
  printf '%s\n' "$installed" | grep -qx "package:$pkg" || continue
  printf '%s\n' "$disabled" | grep -qx "package:$pkg" && continue
  if [ "$role" = "engine" ] && [ "$INCLUDE_ENGINE" -eq 0 ]; then
    dim "пропускаю $pkg (AI-движок; включить в работу: --all)"
    continue
  fi
  TARGETS+=("$pkg")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  ok "нечего отключать — всё уже снято"
  dim "если кнопка всё ещё открывает Breeno, попробуй: --all"
  exit 0
fi

step "Отключаю: ${TARGETS[*]}"
dim "Обратимо, без root. Вернуть: bash scripts/breeno-off.sh --restore"
if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Продолжить? [y/N] " answer
  case "$answer" in y|Y|д|Д|да|ДА) ;; *) die "отменено" ;; esac
fi

FAILED=()
for pkg in "${TARGETS[@]}"; do
  out=$(sh_ "pm disable-user --user 0 $pkg")
  if printf '%s' "$out" | grep -q 'new state: disabled'; then
    ok "$pkg отключён"
  else
    warn "$pkg не поддался: $out"
    FAILED+=("$pkg")
  fi
done

# второй проход по защищённым
if [ ${#FAILED[@]} -gt 0 ] && [ "$UNINSTALL" -eq 1 ]; then
  step "Повторяю через uninstall --user 0"
  STILL=()
  for pkg in "${FAILED[@]}"; do
    out=$(sh_ "pm uninstall --user 0 $pkg")
    if printf '%s' "$out" | grep -q 'Success'; then
      ok "$pkg скрыт для пользователя (вернуть: --restore)"
    else
      warn "$pkg: $out"
      STILL+=("$pkg")
    fi
  done
  FAILED=("${STILL[@]:-}")
  [ ${#FAILED[@]} -eq 1 ] && [ -z "${FAILED[0]:-}" ] && FAILED=()
fi

step "Проверяю результат"
disabled_after=$(sh_ 'pm list packages -d')
installed_after=$(sh_ 'pm list packages --user 0')
REALLY_FAILED=()
for pkg in "${TARGETS[@]}"; do
  if printf '%s\n' "$disabled_after" | grep -qx "package:$pkg"; then
    ok "$pkg отключён"
  elif ! printf '%s\n' "$installed_after" | grep -qx "package:$pkg"; then
    ok "$pkg скрыт для пользователя"
  else
    warn "$pkg всё ещё активен"
    REALLY_FAILED+=("$pkg")
  fi
done

step "Пробую запустить ассистента"
probe=$(sh_ 'am start -a android.intent.action.VOICE_COMMAND')
printf '%s' "$probe" | grep -qiE 'error|unable to resolve' \
  && warn "не запустился: $probe" \
  || ok "команда запуска ушла — глянь на экран телефона"

printf '\n%s— Готово —%s\n' "$C_B" "$C_OFF"
if [ ${#REALLY_FAILED[@]} -eq 0 ]; then
  ok "Breeno снят. Зажми кнопку питания на 0,5 секунды."
  dim "Если кнопка теперь открывает меню выключения, а не Gemini — прогони scripts/oneclick.sh"
else
  warn "Прошивка не дала снять: ${REALLY_FAILED[*]}"
  dim "Попробуй жёстче: bash scripts/breeno-off.sh --uninstall"
  dim "Если и это не сработает — Activity Launcher (assistantguidedialog) или root."
fi
dim "Вернуть как было: bash scripts/breeno-off.sh --restore"
