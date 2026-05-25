bark_required_vars() {
  printf "%s\n" BARK_URL
}

bark_validate() {
  require_vars BARK_URL
}

bark_send() {
  local title="${1:-}" body="${2:-}" timeout url title_enc body_enc
  timeout="$(notify_timeout)"
  title_enc="$(urlencode "${title}")"
  body_enc="$(urlencode "${body}")"
  url="${BARK_URL%/}/${title_enc}/${body_enc}"
  curl -fsS --max-time "${timeout}" "${url}" >/dev/null
}
