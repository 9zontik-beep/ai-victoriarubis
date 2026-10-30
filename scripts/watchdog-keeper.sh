#!/usr/bin/env bash
# watchdog-keeper.sh — присматривает за сторожем агентов.
#
# Зачем: сторож (agent-watchdog.service) поднимает упавших агентов, но за
# самим сторожем до этого не следил никто. Сервер возвращает его только
# после падения: если службу ОСТАНОВИЛИ командой, systemd считает это
# намерением и обратно не включает. Так и вышло 2026-10-30 — сторож был
# остановлен в 16:08 CET, никто этого не заметил, и цикл перезапусков
# Василисы разбирали руками.
#
# Что делает: раз в пять минут (cron) смотрит состояние службы. Жив — молчит.
# Не жив — сбрасывает зависшее состояние, включает и пишет владельцу, потому
# что сам факт выключения означает, что кто-то или что-то его выключило, и
# знать об этом нужно. Повторные сообщения придерживает паузой, чтобы при
# постоянно падающей службе не заваливать чат.
#
# Запуск:  scripts/watchdog-keeper.sh   (cron вызывает без аргументов)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="${KEEPER_UNIT:-agent-watchdog.service}"
SENDER="${KEEPER_SENDER:-$ROOT/scripts/telegram-send.sh}"
STATE="${KEEPER_STATE:-$ROOT/core/watchdog-keeper.state}"
LOG="${KEEPER_LOG:-$ROOT/core/watchdog-keeper.log}"
COOLDOWN="${KEEPER_COOLDOWN:-3600}"
# Пауза после `start`: службе нужно время подняться, иначе сразу после
# запуска она ещё "activating" и мы зря напишем, что поднять не вышло.
WAIT="${KEEPER_WAIT:-3}"

log() { echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

state=$(systemctl is-active "$UNIT" 2>/dev/null)
[ "$state" = "active" ] && exit 0

log "unit $UNIT is ${state:-unknown} — reviving"
systemctl reset-failed "$UNIT" >/dev/null 2>&1
systemctl start "$UNIT" >/dev/null 2>&1
[ "$WAIT" = "0" ] || sleep "$WAIT"
state=$(systemctl is-active "$UNIT" 2>/dev/null)

if [ "$state" = "active" ]; then
  msg="Сторож агентов был выключен — я включил его обратно. Агенты снова под присмотром."
  rc=0
else
  msg="Сторож агентов выключен, и включить его не удалось (состояние: ${state:-неизвестно}). Агенты сейчас без присмотра — скажи тех-спецу."
  rc=1
fi

now=$(date +%s)
last=$(cat "$STATE" 2>/dev/null)
case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac

if (( now - last >= COOLDOWN )); then
  if "$SENDER" "$msg" >/dev/null 2>&1; then
    # Отметку о паузе ставим только когда сообщение действительно ушло,
    # иначе молчание из-за сбоя связи закрыло бы нас на час.
    echo "$now" >"$STATE"
    log "notified owner: $msg"
  else
    log "notify FAILED (will retry next run): $msg"
  fi
else
  log "owner not notified (cooldown ${COOLDOWN}s): $msg"
fi

exit "$rc"
