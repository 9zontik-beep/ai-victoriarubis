#!/usr/bin/env bash
# Проверка watchdog-keeper.sh: присматривает за сторожем. Сторож жив — молчит;
# сторож выключен — включает и один раз пишет владельцу; в пределах паузы
# сообщение не дублирует; поднять не удалось — текст другой.
#
# Запуск:  bash scripts/test_watchdog-keeper.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/watchdog-keeper.sh"

fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Стаб systemctl: состояния для is-active берёт по одной строке из файла
# (последняя строка повторяется), все вызовы пишет в журнал.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_LOG"
if [ "$1" = "is-active" ]; then
  line=$(head -1 "$STATES"); rest=$(tail -n +2 "$STATES")
  [ -n "$rest" ] && printf '%s\n' "$rest" >"$STATES"
  echo "$line"
  [ "$line" = active ] || exit 3
fi
exit 0
STUB
chmod +x "$WORK/bin/systemctl"

# Стаб отправки владельцу: пишет текст в файл вместо Telegram.
cat > "$WORK/bin/send.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$SENT_LOG"
exit "${SEND_RC:-0}"
STUB
chmod +x "$WORK/bin/send.sh"

export PATH="$WORK/bin:$PATH"
export SYSTEMCTL_LOG="$WORK/systemctl.log"
export STATES="$WORK/states.txt"
export SENT_LOG="$WORK/sent.log"

run() {
  : >"$SYSTEMCTL_LOG"
  KEEPER_UNIT=test-watchdog.service \
  KEEPER_SENDER="$WORK/bin/send.sh" \
  KEEPER_STATE="$WORK/keeper.state" \
  KEEPER_LOG="$WORK/keeper.log" \
  KEEPER_WAIT=0 \
  KEEPER_COOLDOWN="${COOLDOWN:-3600}" \
  bash "$SCRIPT"
}

# --- сторож жив: ни поднимать, ни писать -------------------------------------
printf 'active\n' >"$STATES"; : >"$SENT_LOG"
run || { echo "FAIL: вернул ошибку, хотя сторож жив"; fail=1; }
grep -q 'start' "$SYSTEMCTL_LOG" && { echo "FAIL: поднимал живого сторожа"; fail=1; }
[ -s "$SENT_LOG" ] && { echo "FAIL: написал владельцу без причины"; fail=1; }

# --- сторож выключен: поднять и написать один раз -----------------------------
printf 'inactive\nactive\n' >"$STATES"; : >"$SENT_LOG"; rm -f "$WORK/keeper.state"
run || { echo "FAIL: вернул ошибку, хотя сторожа поднял"; fail=1; }
grep -q 'reset-failed test-watchdog.service' "$SYSTEMCTL_LOG" || { echo "FAIL: не сбросил состояние перед запуском"; fail=1; }
grep -q 'start test-watchdog.service' "$SYSTEMCTL_LOG" || { echo "FAIL: не попытался включить сторожа"; fail=1; }
[ "$(wc -l <"$SENT_LOG")" = 1 ] || { echo "FAIL: ждал одно сообщение владельцу, получил $(wc -l <"$SENT_LOG")"; fail=1; }
grep -qi 'включил' "$SENT_LOG" || { echo "FAIL: в сообщении не сказано, что сторож включён: $(cat "$SENT_LOG")"; fail=1; }

# --- второй случай сразу же: поднимаем, но не дублируем сообщение -------------
printf 'inactive\nactive\n' >"$STATES"; : >"$SENT_LOG"
run || { echo "FAIL: вернул ошибку на повторном подъёме"; fail=1; }
grep -q 'start test-watchdog.service' "$SYSTEMCTL_LOG" || { echo "FAIL: во второй раз не стал поднимать сторожа"; fail=1; }
[ -s "$SENT_LOG" ] && { echo "FAIL: продублировал сообщение в пределах паузы"; fail=1; }

# --- пауза истекла: сообщение снова уходит ------------------------------------
printf 'inactive\nactive\n' >"$STATES"; : >"$SENT_LOG"
COOLDOWN=0 run || { echo "FAIL: вернул ошибку, когда пауза истекла"; fail=1; }
[ -s "$SENT_LOG" ] || { echo "FAIL: после паузы не написал владельцу"; fail=1; }

# --- поднять не удалось: другой текст и ненулевой код -------------------------
printf 'failed\nfailed\n' >"$STATES"; : >"$SENT_LOG"; rm -f "$WORK/keeper.state"
COOLDOWN=0 run && { echo "FAIL: смолчал об ошибке, хотя сторожа поднять не вышло"; fail=1; }
grep -qi 'не удалось' "$SENT_LOG" || { echo "FAIL: не предупредил, что поднять не вышло: $(cat "$SENT_LOG")"; fail=1; }

# --- сообщение не ушло: отметку о паузе не ставим -----------------------------
printf 'inactive\nactive\n' >"$STATES"; : >"$SENT_LOG"; rm -f "$WORK/keeper.state"
SEND_RC=1 run
[ -f "$WORK/keeper.state" ] && { echo "FAIL: записал отметку о паузе, хотя сообщение не ушло"; fail=1; }

if [ "$fail" = 0 ]; then echo "OK: все проверки прошли"; fi
exit "$fail"
