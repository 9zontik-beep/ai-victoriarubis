#!/usr/bin/env bash
# notify-startup.sh — говорит владельцу «я вернулся» сразу после запуска
# агента. Нужен потому, что сам агент при старте молчит: он оживает только
# когда ему приходит сообщение, а значит факт перезапуска владелец замечает
# сам. Висит на хуке SessionStart (см. .claude/settings.json).
#
# Отправку делает scripts/telegram-send.sh — тем же ботом и тому же владельцу,
# что и сам агент.
#
# Запуск:  scripts/notify-startup.sh   (хук вызывает без аргументов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENDER="${NOTIFY_STARTUP_SENDER:-$ROOT/scripts/telegram-send.sh}"
# Метка последней отправки: при краш-лупе агент может стартовать каждые
# полминуты, и без паузы владелец получит поток одинаковых сообщений.
STAMP="${NOTIFY_STARTUP_STAMP:-$ROOT/.claude/.last-startup-notice}"
THROTTLE="${NOTIFY_STARTUP_THROTTLE:-600}"
TEXT="${NOTIFY_STARTUP_TEXT:-Я вернулся и снова на связи.}"
# Журнал неудачных отправок: хук не вправе ронять запуск агента, поэтому
# ошибку он проглатывает — но она должна остаться записанной, иначе владелец
# просто не получает сообщений и никто об этом не знает.
LOG="${NOTIFY_STARTUP_LOG:-$ROOT/.claude/.last-startup-notice.log}"
LOG_KEEP="${NOTIFY_STARTUP_LOG_KEEP:-50}"

note() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%F %T %Z')" "$1" >>"$LOG" 2>/dev/null
  # Журнал пишется при каждом старте, поэтому держим только хвост.
  if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt "$LOG_KEEP" ]; then
    tail -n "$LOG_KEEP" "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  fi
}

# Хук не должен ронять запуск агента: любая неудача — молча в сторону.
fail() { exit 0; }

now=$(date +%s)
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null)
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  (( now - last < THROTTLE )) && fail
fi

if ! reason=$("$SENDER" "$TEXT" 2>&1 >/dev/null); then
  note "сообщение о запуске не ушло: ${reason:-причина неизвестна}"
  fail
fi

mkdir -p "$(dirname "$STAMP")" 2>/dev/null
echo "$now" >"$STAMP" 2>/dev/null
exit 0
