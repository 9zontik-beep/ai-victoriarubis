#!/usr/bin/env bash
# reminders.sh — напоминания владельцу по часам. Cron запускает этот скрипт
# каждые пять минут; он смотрит очередь core/reminders.tsv и отправляет то,
# чей срок наступил, после чего строку из очереди убирает.
#
# Почему очередь, а не строка в cron на каждое напоминание: в cron пришлось бы
# писать текст и держать секреты рядом с расписанием, а разовые задания после
# срабатывания оставались бы мусором, который сработает снова через год.
#
# Формат очереди (разделитель — табуляция, строки с # игнорируются):
#   2026-10-30T09:00Z<TAB>текст напоминания
# Время — в UTC, чтобы не путаться с часовыми поясами владельца и сервера.
#
# Запуск:  scripts/reminders.sh   (cron вызывает без аргументов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE="${REMINDERS_QUEUE:-$ROOT/core/reminders.tsv}"
LOG="${REMINDERS_LOG:-$ROOT/core/reminders.log}"
SENDER="${REMINDERS_SENDER:-$ROOT/scripts/telegram-send.sh}"

[ -f "$QUEUE" ] || exit 0

log() { echo "$(date -u '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

now=$(date -u +%s)
kept=""
changed=0

while IFS=$'\t' read -r when text || [ -n "${when:-}" ]; do
  # Пустые строки и комментарии переносим в новую очередь как есть.
  case "${when:-}" in
    ''|'#'*) kept+="${when:-}${text:+$'\t'}${text:-}"$'\n'; continue ;;
  esac
  if [ -z "${text:-}" ]; then
    log "строка без текста, убрал: $when"
    changed=1
    continue
  fi
  due=$(date -u -d "$when" +%s 2>/dev/null)
  if [ -z "$due" ]; then
    log "непонятное время, убрал: $when ($text)"
    changed=1
    continue
  fi
  if (( due > now )); then
    kept+="$when"$'\t'"$text"$'\n'
    continue
  fi
  if "$SENDER" "$text" >/dev/null 2>&1; then
    log "отправил: $when $text"
    changed=1
  else
    # Телеграм или сеть недоступны — оставляем в очереди, попробуем через
    # пять минут. Иначе напоминание пропадёт молча.
    kept+="$when"$'\t'"$text"$'\n'
    log "НЕ отправил (оставил в очереди): $when $text"
  fi
done <"$QUEUE"

if (( changed )); then
  printf '%s' "$kept" >"$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
fi
exit 0
