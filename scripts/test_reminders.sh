#!/usr/bin/env bash
# Проверка reminders.sh: отправляет только то, чей срок пришёл, убирает
# отправленное из очереди, не теряет напоминание при сбое связи и не ломается
# на мусоре в файле.
#
# Запуск:  bash scripts/test_reminders.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/reminders.sh"

fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Подменная отправка: вместо Telegram пишет текст в файл. Код возврата берём
# из SEND_RC — так проверяем поведение при недоступной связи.
cat > "$WORK/sender.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$SENT_LOG"
exit "${SEND_RC:-0}"
STUB
chmod +x "$WORK/sender.sh"
export SENT_LOG="$WORK/sent.log"

run() {
  REMINDERS_QUEUE="$WORK/queue.tsv" REMINDERS_LOG="$WORK/log" \
  REMINDERS_SENDER="$WORK/sender.sh" bash "$SCRIPT"
}

past=$(date -u -d '-1 hour' '+%FT%H:%MZ')
future=$(date -u -d '+1 day' '+%FT%H:%MZ')

# --- срок пришёл: отправляем и убираем из очереди ---------------------------
: >"$SENT_LOG"
printf '%s\t%s\n' "$past" "пора вставать" >"$WORK/queue.tsv"
run
grep -q 'пора вставать' "$SENT_LOG" || { echo "FAIL: не отправил напоминание, у которого вышел срок"; fail=1; }
grep -q 'пора вставать' "$WORK/queue.tsv" && { echo "FAIL: отправленное осталось в очереди — придёт ещё раз"; fail=1; }

# --- срок не пришёл: молчим и храним ----------------------------------------
: >"$SENT_LOG"
printf '%s\t%s\n' "$future" "это на завтра" >"$WORK/queue.tsv"
run
[ -s "$SENT_LOG" ] && { echo "FAIL: отправил напоминание раньше срока"; fail=1; }
grep -q 'это на завтра' "$WORK/queue.tsv" || { echo "FAIL: потерял будущее напоминание из очереди"; fail=1; }

# --- несколько строк: уходит только просроченная -----------------------------
: >"$SENT_LOG"
{ printf '# заметка\n'
  printf '%s\t%s\n' "$past" "сегодня"
  printf '%s\t%s\n' "$future" "потом"; } >"$WORK/queue.tsv"
run
grep -q 'сегодня' "$SENT_LOG" || { echo "FAIL: не отправил просроченную из нескольких"; fail=1; }
grep -q 'потом' "$SENT_LOG" && { echo "FAIL: отправил будущую вместе с просроченной"; fail=1; }
grep -q 'потом' "$WORK/queue.tsv" || { echo "FAIL: выкинул будущую строку"; fail=1; }
grep -q '# заметка' "$WORK/queue.tsv" || { echo "FAIL: потерял строку-комментарий"; fail=1; }

# --- связи нет: напоминание остаётся на следующую попытку -------------------
: >"$SENT_LOG"
printf '%s\t%s\n' "$past" "важное" >"$WORK/queue.tsv"
SEND_RC=1 run
grep -q 'важное' "$WORK/queue.tsv" || { echo "FAIL: при сбое связи напоминание пропало"; fail=1; }
: >"$SENT_LOG"
run
grep -q 'важное' "$SENT_LOG" || { echo "FAIL: не повторил попытку после сбоя"; fail=1; }

# --- мусор в файле не ломает работу -----------------------------------------
: >"$SENT_LOG"
{ printf 'не-дата\tчто-то\n'
  printf '%s\t%s\n' "$past" "нормальное"; } >"$WORK/queue.tsv"
if ! run; then echo "FAIL: упал на мусорной строке"; fail=1; fi
grep -q 'нормальное' "$SENT_LOG" || { echo "FAIL: из-за мусорной строки не дошёл до нормальной"; fail=1; }
grep -q 'не-дата' "$WORK/queue.tsv" && { echo "FAIL: мусорная строка осталась и будет мешать каждый раз"; fail=1; }

# --- нет файла очереди: тихо и без ошибки -----------------------------------
rm -f "$WORK/queue.tsv"
if ! run; then echo "FAIL: вернул ошибку, когда очереди нет"; fail=1; fi

[ "$fail" = 0 ] && echo "OK: все проверки reminders прошли"
exit "$fail"
