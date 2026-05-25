telegram_required_vars() {
  printf "%s\n" TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
}

telegram_validate() {
  require_vars TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
}

telegram_send() {
  local title="${1:-}" body="${2:-}" timeout api
  timeout="$(notify_timeout)"
  api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  curl -fsS --max-time "${timeout}" -X POST "${api}" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${title}

${body}" \
    --data "disable_web_page_preview=true" >/dev/null
}
