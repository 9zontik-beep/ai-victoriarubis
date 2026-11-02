#!/usr/bin/env bash
# Проверка notify-startup.sh: при запуске агента уходит одно сообщение
# владельцу, повторный запуск в течение паузы молчит, а без настроек скрипт
# не ломает старт агента.
#
# Запуск:  bash scripts/test_notify-startup.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/notify-startup.sh"

fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Подменный curl: вместо Telegram пишет свои аргументы в файл.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$@" >>"$CURL_LOG"
printf '%s' "${CURL_OUT-$CURL_OK}"
STUB
chmod +x "$WORK/bin/curl"
export CURL_LOG="$WORK/curl.log"
# Так Telegram отвечает на успешную отправку; отказ тесты подставляют в CURL_OUT.
export CURL_OK='{"ok":true,"result":{"message_id":1}}'
export PATH="$WORK/bin:$PATH"

cat > "$WORK/channel.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:TESTTOKEN
TELEGRAM_ALLOWED_USER_IDS=206792865,999
ENV

# Настройки бота подсовываем общему отправщику (telegram-send.sh) — им
# пользуется notify-startup.
run() { TELEGRAM_SEND_ENV="$1" NOTIFY_STARTUP_STAMP="$WORK/stamp" \
  NOTIFY_STARTUP_LOG="$WORK/notice.log" bash "$SCRIPT"; }

# --- первый запуск: сообщение уходит ----------------------------------------
: >"$CURL_LOG"
run "$WORK/channel.env"
grep -q '123:TESTTOKEN' "$CURL_LOG" || { echo "FAIL: не отправил сообщение при старте"; fail=1; }
grep -q 'chat_id=206792865' "$CURL_LOG" || { echo "FAIL: отправил не владельцу (нужен первый id из списка)"; fail=1; }
# «вернулся» или «вернулась» — род у каждого агента свой.
grep -q 'вернул' "$CURL_LOG" || { echo "FAIL: в тексте нет «я вернулся»"; fail=1; }
[ -f "$WORK/stamp" ] || { echo "FAIL: не записал метку времени"; fail=1; }

# --- повторный запуск сразу: молчит -----------------------------------------
: >"$CURL_LOG"
run "$WORK/channel.env"
[ -s "$CURL_LOG" ] && { echo "FAIL: прислал второе сообщение сразу (краш-луп = спам)"; fail=1; }

# --- пауза прошла: сообщение снова уходит -----------------------------------
: >"$CURL_LOG"
echo $(( $(date +%s) - 700 )) >"$WORK/stamp"
run "$WORK/channel.env"
grep -q 'sendMessage' "$CURL_LOG" || { echo "FAIL: после паузы не отправил"; fail=1; }

# --- битая метка не блокирует отправку --------------------------------------
: >"$CURL_LOG"
echo "мусор" >"$WORK/stamp"
run "$WORK/channel.env"
grep -q 'sendMessage' "$CURL_LOG" || { echo "FAIL: из-за битой метки замолчал навсегда"; fail=1; }

# --- нет настроек: тихо и без ошибки (иначе ломается запуск агента) ---------
: >"$CURL_LOG"
rm -f "$WORK/stamp"
if ! run "$WORK/нет-такого-файла.env"; then
  echo "FAIL: вернул ошибку без настроек — это уронит старт агента"; fail=1
fi
[ -s "$CURL_LOG" ] && { echo "FAIL: что-то отправил без настроек"; fail=1; }

: >"$CURL_LOG"
echo 'TELEGRAM_BOT_TOKEN=' >"$WORK/empty.env"
if ! run "$WORK/empty.env"; then
  echo "FAIL: вернул ошибку при пустом токене"; fail=1
fi
[ -s "$CURL_LOG" ] && { echo "FAIL: отправил без токена"; fail=1; }

# --- Telegram отказал: старт агента не ломаем, но причину записываем -------
: >"$CURL_LOG"; rm -f "$WORK/stamp" "$WORK/notice.log"
if ! CURL_OUT='{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}' \
     run "$WORK/channel.env"; then
  echo "FAIL: вернул ошибку при отказе Telegram — это уронит старт агента"; fail=1
fi
[ -f "$WORK/stamp" ] && { echo "FAIL: записал метку, хотя сообщение не ушло (следующий старт промолчит)"; fail=1; }
grep -q 'Forbidden' "$WORK/notice.log" 2>/dev/null \
  || { echo "FAIL: неудачная отправка нигде не записана — сбой остался невидимым"; fail=1; }

# --- отправщик сломан совсем ------------------------------------------------
rm -f "$WORK/stamp" "$WORK/notice.log"
if ! NOTIFY_STARTUP_SENDER=/bin/false TELEGRAM_SEND_ENV="$WORK/channel.env" \
     NOTIFY_STARTUP_STAMP="$WORK/stamp" NOTIFY_STARTUP_LOG="$WORK/notice.log" bash "$SCRIPT"; then
  echo "FAIL: вернул ошибку при сломанном отправщике"; fail=1
fi
[ -s "$WORK/notice.log" ] || { echo "FAIL: молча проглотил сломанный отправщик"; fail=1; }

# --- удачная отправка ничего не пишет в журнал ------------------------------
rm -f "$WORK/stamp" "$WORK/notice.log"
run "$WORK/channel.env"
[ -s "$WORK/notice.log" ] && { echo "FAIL: записал жалобу при удачной отправке"; fail=1; }

# --- журнал не растёт бесконечно --------------------------------------------
rm -f "$WORK/stamp"
: >"$WORK/notice.log"
for i in $(seq 1 60); do echo "старая строка $i" >>"$WORK/notice.log"; done
NOTIFY_STARTUP_SENDER=/bin/false TELEGRAM_SEND_ENV="$WORK/channel.env" \
  NOTIFY_STARTUP_STAMP="$WORK/stamp" NOTIFY_STARTUP_LOG="$WORK/notice.log" bash "$SCRIPT"
lines=$(wc -l <"$WORK/notice.log")
[ "$lines" -le 50 ] || { echo "FAIL: журнал раздувается: строк $lines"; fail=1; }

[ "$fail" = 0 ] && echo "OK: все проверки notify-startup прошли"
exit "$fail"
