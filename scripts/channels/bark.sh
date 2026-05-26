bark_required_vars() {
  printf "%s\n" BARK_URL
}

bark_validate() {
  require_vars BARK_URL
}

bark_send() {
  local title="${1:-}" body="${2:-}" timeout payload
  timeout="$(notify_timeout)"
  payload="$(jq -cn --arg title "${title}" --arg body "${body}" '{title: $title, body: $body}')"
  curl -fsS --max-time "${timeout}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -X POST "${BARK_URL%/}" \
    --data-binary "${payload}" >/dev/null
}
