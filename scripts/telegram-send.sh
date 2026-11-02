#!/usr/bin/env bash
# telegram-send.sh — отправляет владельцу сообщение в Telegram напрямую,
# минуя агента. Нужен там, где агента нет или он молчит: уведомление о
# запуске, напоминания по расписанию, сообщения от сторожа.
#
# Токен бота и Telegram-id владельца берутся из secrets/channel.env — те же,
# что использует сам агент.
#
# Запуск:  scripts/telegram-send.sh "текст сообщения"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${TELEGRAM_SEND_ENV:-$ROOT/secrets/channel.env}"
API_BASE="${TELEGRAM_SEND_API_BASE:-https://api.telegram.org}"

text="${1:-}"
[ -n "$text" ] || { echo "нечего отправлять: нужен текст сообщения" >&2; exit 2; }
[ -f "$ENV_FILE" ] || { echo "нет файла с настройками: $ENV_FILE" >&2; exit 3; }

token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
uid=$(grep -m1 -E '^TELEGRAM_ALLOWED_USER_IDS=|^TELEGRAM_ALLOWED_USERS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | cut -d, -f1)
if [ -z "$token" ] || [ -z "$uid" ]; then
  echo "в $ENV_FILE не нашёл токен бота или id владельца" >&2
  exit 3
fi

# Ответ Telegram читаем, а не выбрасываем: curl возвращает 0 и когда сервер
# отказал (бот заблокирован, неверный chat_id) — без этой проверки сбой
# отправки остался бы незамеченным.
answer=$(curl -s -m 15 "${API_BASE}/bot${token}/sendMessage" \
  --data-urlencode "chat_id=${uid}" --data-urlencode "text=${text}") || exit 4

case "$answer" in
  *'"ok":true'*) ;;
  '')
    echo "Telegram не ответил — сообщение, скорее всего, не ушло" >&2
    exit 4
    ;;
  *)
    # В ответе Telegram токена нет, поэтому показать его целиком безопасно.
    echo "Telegram не принял сообщение: $answer" >&2
    exit 5
    ;;
esac
