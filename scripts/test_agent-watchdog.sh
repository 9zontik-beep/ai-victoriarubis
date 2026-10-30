#!/usr/bin/env bash
# Проверка answer_dialogs из agent-watchdog.sh: сторож сам отвечает на
# стартовые вопросы Claude Code в живой сессии.
#
# Главный случай (сломал Василису 2026-10-30): в вопросе «доверяешь ли ты
# этой папке?» по умолчанию выбран «No, exit», поэтому отвечать надо
# Down+Enter, а не просто Enter — иначе агент закрывается на старте.
#
# Запуск:  bash scripts/test_agent-watchdog.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/agent-watchdog.sh"

fail=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  has-session)  exit "${TMUX_HAS_SESSION:-0}" ;;
  capture-pane) cat "$PANE_FILE" ;;
  send-keys)    shift 3; echo "$*" >>"$KEYS_LOG" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/tmux"
export KEYS_LOG="$WORK/keys.log"
export PANE_FILE="$WORK/pane.txt"
export PATH="$WORK/bin:$PATH"
export HOME="$WORK"
export WATCHDOG_LOG="$WORK/watchdog.log"

# shellcheck disable=SC1090
. "$SCRIPT"

# check NAME EXPECTED-KEYS  (пустая строка = клавиш быть не должно)
check() {
  local what="$1" expect="$2" got
  : >"$KEYS_LOG"
  answer_dialogs diag
  got=$(tr '\n' ' ' <"$KEYS_LOG" | sed 's/ *$//')
  if [ "$got" != "$expect" ]; then
    echo "FAIL: $what — ждал клавиши [$expect], получил [$got]"
    fail=1
  fi
}

# --- вопрос про доверие к папке: по умолчанию «No, exit» ---------------------
cat > "$PANE_FILE" <<'PANE'
 Accessing workspace:

 /root/ai-marketing/dashi-plugin-claude-code/plugin

 Quick safety check: Is this a project you created or one you trust?

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
PANE
check "вопрос про доверие к папке" "Down Enter"

# --- предупреждение про каналы разработки: нужный пункт уже выбран -----------
cat > "$PANE_FILE" <<'PANE'
  WARNING: Loading development channels

  Channels: server:dashi-channel

  ❯ 1. I am using this for local development
    2. Exit
PANE
check "предупреждение про каналы разработки" "Enter"

# --- режим bypass permissions: нужный пункт второй --------------------------
cat > "$PANE_FILE" <<'PANE'
  Bypass Permissions mode

  ❯ 1. No, exit
    2. Yes, I accept
PANE
check "вопрос про Bypass Permissions mode" "Down Enter"

# --- обычный рабочий экран: трогать нельзя ----------------------------------
cat > "$PANE_FILE" <<'PANE'
▎ Channels (experimental) messages from server:dashi-channel inject directly

❯ Try "how does <filepath> work?"
  ⏵⏵ bypass permissions on (shift+tab to cycle)
PANE
check "обычный рабочий экран" ""

# --- сессии нет: ни одной клавиши в пустоту ---------------------------------
cat > "$PANE_FILE" <<'PANE'
 ❯ No, exit
   Yes, I trust this folder
PANE
TMUX_HAS_SESSION=1 check "сессии нет" ""

if [ "$fail" = 0 ]; then echo "OK: все проверки прошли"; fi
exit "$fail"
