#!/usr/bin/env bash
# Проверка telegram-send.sh: уходит сообщение владельцу (первый id из списка),
# и понятная ошибка вместо тихого молчания, когда нечего или некому отправлять.
#
# Запуск:  bash scripts/test_telegram-send.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/telegram-send.sh"

fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$@" >>"$CURL_LOG"
printf '%s' "${CURL_OUT-$CURL_OK}"
exit "${CURL_RC:-0}"
STUB
chmod +x "$WORK/bin/curl"
export CURL_LOG="$WORK/curl.log"
# Обычный ответ Telegram на успешную отправку; тесты подменяют его CURL_OUT.
export CURL_OK='{"ok":true,"result":{"message_id":1}}'

export PATH="$WORK/bin:$PATH"

cat > "$WORK/channel.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:TESTTOKEN
TELEGRAM_ALLOWED_USER_IDS=206792865,999
ENV

run() { TELEGRAM_SEND_ENV="$1" bash "$SCRIPT" "${2:-}"; }

# --- обычная отправка --------------------------------------------------------
: >"$CURL_LOG"
run "$WORK/channel.env" "привет" || { echo "FAIL: вернул ошибку на обычной отправке"; fail=1; }
grep -q 'bot123:TESTTOKEN/sendMessage' "$CURL_LOG" || { echo "FAIL: не позвал Telegram с токеном бота"; fail=1; }
grep -q 'chat_id=206792865' "$CURL_LOG" || { echo "FAIL: отправил не владельцу (нужен первый id из списка)"; fail=1; }
grep -q 'text=привет' "$CURL_LOG" || { echo "FAIL: потерял текст сообщения"; fail=1; }

# --- нет текста --------------------------------------------------------------
: >"$CURL_LOG"
run "$WORK/channel.env" "" && { echo "FAIL: промолчал об отсутствии текста"; fail=1; }
[ -s "$CURL_LOG" ] && { echo "FAIL: позвал Telegram с пустым текстом"; fail=1; }

# --- нет файла настроек ------------------------------------------------------
: >"$CURL_LOG"
run "$WORK/нет-файла.env" "привет" && { echo "FAIL: промолчал об отсутствии настроек"; fail=1; }

# --- настройки есть, токена нет ---------------------------------------------
printf 'TELEGRAM_ALLOWED_USER_IDS=206792865\n' >"$WORK/no-token.env"
run "$WORK/no-token.env" "привет" && { echo "FAIL: промолчал об отсутствии токена"; fail=1; }

# --- Telegram недоступен: ошибка наружу, чтобы вызвавший повторил ------------
: >"$CURL_LOG"
CURL_RC=7 run "$WORK/channel.env" "привет" && { echo "FAIL: скрыл сбой связи — напоминание пропадёт"; fail=1; }

# --- Telegram ответил отказом: ошибка наружу, а не тихий успех --------------
: >"$CURL_LOG"
CURL_OUT='{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}' \
  run "$WORK/channel.env" "привет" \
  && { echo "FAIL: принял отказ Telegram за успешную отправку"; fail=1; }

# --- отказ объясняется человеку ---------------------------------------------
out=$(CURL_OUT='{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}' \
  run "$WORK/channel.env" "привет" 2>&1)
case "$out" in
  *Forbidden*) ;;
  *) echo "FAIL: не сказал, почему Telegram отказал: $out"; fail=1 ;;
esac

# --- пустой ответ (связь оборвалась на полуслове) ---------------------------
: >"$CURL_LOG"
CURL_OUT='' run "$WORK/channel.env" "привет" \
  && { echo "FAIL: пустой ответ Telegram принял за успех"; fail=1; }

# --- токен не утекает в сообщение об ошибке ---------------------------------
out=$(CURL_OUT='{"ok":false,"description":"Bad Request"}' run "$WORK/channel.env" "привет" 2>&1)
case "$out" in
  *TESTTOKEN*) echo "FAIL: показал токен бота в ошибке"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "OK: все проверки telegram-send прошли"
exit "$fail"
