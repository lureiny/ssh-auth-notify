#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="ssh-auth-notify"
INSTALL_DIR="/opt/${PROJECT_NAME}"
SCRIPT_DIR="${INSTALL_DIR}/scripts"
CONFIG_DIR="/etc/${PROJECT_NAME}"
CONFIG_FILE="${CONFIG_DIR}/env"
PAM_FILE="/etc/pam.d/sshd"
PAM_BEGIN="# BEGIN ssh-auth-notify"
PAM_END="# END ssh-auth-notify"
PAM_LINE="account optional pam_exec.so quiet type=account ${SCRIPT_DIR}/ssh-auth-notify-wrapper"

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT_DIR="${SELF_DIR}/scripts"

INSTALL_BACKEND=""
INSTALL_BARK_URL=""
INSTALL_TG_TOKEN=""
INSTALL_TG_CHAT_ID=""
INSTALL_TIMEOUT="5"
PURGE_BACKUPS=0
TEST_TMPDIR=""

log() { printf '[%s] %s\n' "${PROJECT_NAME}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${PROJECT_NAME}" "$*" >&2; }
fatal() { printf '[%s] ERROR: %s\n' "${PROJECT_NAME}" "$*" >&2; exit 1; }

cleanup_test_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf -- "${TEST_TMPDIR}"
  fi
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "this command must be run as root"
}

confirm() {
  local prompt="${1:-Continue?}" answer
  read -r -p "${prompt} [y/N] " answer || true
  [[ "${answer}" == "y" || "${answer}" == "Y" || "${answer}" == "yes" || "${answer}" == "YES" ]]
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

find_pam_exec() {
  local candidates=(
    /lib/security/pam_exec.so
    /lib64/security/pam_exec.so
    /usr/lib/security/pam_exec.so
    /usr/lib64/security/pam_exec.so
    /usr/lib/*/security/pam_exec.so
    /usr/lib/*/security/pam_exec.so
  )
  local pattern expanded
  shopt -s nullglob
  for pattern in "${candidates[@]}"; do
    for expanded in ${pattern}; do
      [[ -e "${expanded}" ]] && return 0
    done
  done
  shopt -u nullglob
  return 1
}

pkg_install_command() {
  if have_cmd apt-get; then
    printf 'apt-get update && apt-get install -y systemd curl python3 libpam-modules'
  elif have_cmd dnf; then
    printf 'dnf install -y systemd curl python3 pam'
  elif have_cmd yum; then
    printf 'yum install -y systemd curl python3 pam'
  elif have_cmd pacman; then
    printf 'pacman -Sy --needed systemd curl python pam'
  elif have_cmd zypper; then
    printf 'zypper install -y systemd curl python3 pam'
  else
    return 1
  fi
}

install_missing_deps() {
  local missing=("$@") cmd
  if cmd="$(pkg_install_command)"; then
    log "suggested install command: ${cmd}"
    if confirm "Install missing dependencies now?"; then
      bash -c "${cmd}"
    else
      fatal "missing dependencies: ${missing[*]}"
    fi
  else
    fatal "missing dependencies: ${missing[*]}; install them manually"
  fi
}

check_dependencies() {
  local missing=() still_missing=() cmd
  for cmd in bash systemd-run curl python3 install grep sed awk; do
    have_cmd "${cmd}" || missing+=("${cmd}")
  done
  find_pam_exec || missing+=("pam_exec.so")

  if ((${#missing[@]} > 0)); then
    warn "missing dependencies: ${missing[*]}"
    install_missing_deps "${missing[@]}"
  fi

  for cmd in bash systemd-run curl python3 install grep sed awk; do
    have_cmd "${cmd}" || still_missing+=("${cmd}")
  done
  find_pam_exec || still_missing+=("pam_exec.so")
  ((${#still_missing[@]} == 0)) || fatal "dependencies still missing: ${still_missing[*]}"
}

write_config_file() {
  local backend="${1:-telegram}" tg_token="${2:-}" tg_chat_id="${3:-}" bark_url="${4:-}" timeout="${5:-5}"
  install -d -m 0700 "${CONFIG_DIR}"
  umask 077
  {
    printf '# telegram | bark\n'
    printf 'SSH_AUTH_NOTIFY_BACKEND=%q\n' "${backend}"
    printf '\n# Telegram\n'
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "${tg_token}"
    printf 'TELEGRAM_CHAT_ID=%q\n' "${tg_chat_id}"
    printf '\n# Bark\n'
    printf 'BARK_URL=%q\n' "${bark_url}"
    printf '\n# Common\n'
    printf 'SSH_AUTH_NOTIFY_TIMEOUT=%q\n' "${timeout}"
    printf 'SSH_AUTH_NOTIFY_HOST_ALIAS=\n'
    printf 'SSH_AUTH_NOTIFY_DEBUG=0\n'
    printf 'SSH_AUTH_NOTIFY_SKIP_USERS=\n'
    printf 'SSH_AUTH_NOTIFY_ONLY_USERS=\n'
  } >"${CONFIG_FILE}"
  chmod 0600 "${CONFIG_FILE}"
}

config_is_complete() {
  [[ -f "${CONFIG_FILE}" ]] || return 1

  local SSH_AUTH_NOTIFY_BACKEND="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID="" BARK_URL=""
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  case "${SSH_AUTH_NOTIFY_BACKEND}" in
    telegram) [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]] ;;
    bark) [[ -n "${BARK_URL}" ]] ;;
    *) return 1 ;;
  esac
}

ensure_install_config() {
  install -d -m 0700 "${CONFIG_DIR}"

  if [[ -n "${INSTALL_BACKEND}" ]]; then
    write_config_file "${INSTALL_BACKEND}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}" "${INSTALL_TIMEOUT}"
    log "wrote config: ${CONFIG_FILE}"
    return 0
  fi

  if config_is_complete; then
    chmod 0600 "${CONFIG_FILE}"
    log "config already exists and looks complete: ${CONFIG_FILE}"
    return 0
  fi

  if [[ -f "${CONFIG_FILE}" ]]; then
    warn "config exists but is incomplete: ${CONFIG_FILE}"
  else
    log "no config found; starting interactive configuration"
  fi

  if [[ ! -t 0 ]]; then
    fatal "configuration is required; rerun with --backend telegram|bark and credentials, or run interactively"
  fi

  configure_interactive
}

install_scripts() {
  [[ -d "${SRC_SCRIPT_DIR}" ]] || fatal "source scripts dir not found: ${SRC_SCRIPT_DIR}"
  install -d -m 0755 "${SCRIPT_DIR}"
  install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-wrapper" "${SCRIPT_DIR}/ssh-auth-notify-wrapper"
  install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-worker" "${SCRIPT_DIR}/ssh-auth-notify-worker"
  install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-send" "${SCRIPT_DIR}/ssh-auth-notify-send"
  log "installed scripts to ${SCRIPT_DIR}"
}

backup_pam() {
  [[ -f "${PAM_FILE}" ]] || fatal "PAM file not found: ${PAM_FILE}"
  local backup="${PAM_FILE}.bak.ssh-auth-notify.$(date +%Y%m%d-%H%M%S)"
  cp -a "${PAM_FILE}" "${backup}"
  log "backup PAM: ${backup}"
}

pam_has_block() {
  [[ -f "${PAM_FILE}" ]] && grep -Fq "${PAM_BEGIN}" "${PAM_FILE}" 2>/dev/null
}

install_pam_block() {
  [[ -f "${PAM_FILE}" ]] || fatal "PAM file not found: ${PAM_FILE}"
  if pam_has_block; then
    log "PAM block already installed"
    return 0
  fi

  backup_pam
  {
    printf '\n%s\n' "${PAM_BEGIN}"
    printf '%s\n' "${PAM_LINE}"
    printf '%s\n' "${PAM_END}"
  } >>"${PAM_FILE}"
  log "installed PAM block into ${PAM_FILE}"
}

remove_pam_block() {
  [[ -f "${PAM_FILE}" ]] || { warn "PAM file not found: ${PAM_FILE}"; return 0; }
  if ! pam_has_block; then
    log "PAM block not present"
    return 0
  fi
  backup_pam
  awk -v begin="${PAM_BEGIN}" -v end="${PAM_END}" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "${PAM_FILE}" >"${PAM_FILE}.tmp.${PROJECT_NAME}"
  install -m 0644 "${PAM_FILE}.tmp.${PROJECT_NAME}" "${PAM_FILE}"
  rm -f "${PAM_FILE}.tmp.${PROJECT_NAME}"
  log "removed PAM block from ${PAM_FILE}"
}

validate_backend_config() {
  local backend="${1:-}"
  case "${backend}" in
    telegram)
      [[ -n "${2:-}" ]] || fatal "telegram bot token is required"
      [[ -n "${3:-}" ]] || fatal "telegram chat id is required"
      ;;
    bark)
      [[ -n "${4:-}" ]] || fatal "bark url is required"
      ;;
    *) fatal "unsupported backend: ${backend}" ;;
  esac
}

parse_common_config_args() {
  while (($#)); do
    case "$1" in
      --backend) INSTALL_BACKEND="${2:-}"; shift 2 ;;
      --bark-url) INSTALL_BARK_URL="${2:-}"; shift 2 ;;
      --telegram-bot-token) INSTALL_TG_TOKEN="${2:-}"; shift 2 ;;
      --telegram-chat-id) INSTALL_TG_CHAT_ID="${2:-}"; shift 2 ;;
      --timeout) INSTALL_TIMEOUT="${2:-5}"; shift 2 ;;
      *) fatal "unknown argument: $1" ;;
    esac
  done
}

configure_interactive() {
  need_root
  install -d -m 0700 "${CONFIG_DIR}"

  local backend token chat_id bark_url
  read -r -p "Backend [telegram/bark]: " backend
  backend="${backend:-telegram}"

  if [[ "${backend}" == "telegram" ]]; then
    read -r -p "Telegram bot token: " token
    read -r -p "Telegram chat id: " chat_id
    validate_backend_config "${backend}" "${token}" "${chat_id}" ""
    write_config_file "${backend}" "${token}" "${chat_id}" "" "5"
  elif [[ "${backend}" == "bark" ]]; then
    read -r -p "Bark URL, e.g. https://api.day.app/KEY: " bark_url
    validate_backend_config "${backend}" "" "" "${bark_url}"
    write_config_file "${backend}" "" "" "${bark_url}" "5"
  else
    fatal "unsupported backend: ${backend}"
  fi

  log "updated config: ${CONFIG_FILE}"
}

parse_test_args() {
  TEST_BACKEND=""
  TEST_BARK_URL=""
  TEST_TG_TOKEN=""
  TEST_TG_CHAT_ID=""
  TEST_USER="demo"
  TEST_RHOST="127.0.0.1"
  TEST_TTY="ssh"

  while (($#)); do
    case "$1" in
      --backend) TEST_BACKEND="${2:-}"; shift 2 ;;
      --bark-url) TEST_BARK_URL="${2:-}"; shift 2 ;;
      --telegram-bot-token) TEST_TG_TOKEN="${2:-}"; shift 2 ;;
      --telegram-chat-id) TEST_TG_CHAT_ID="${2:-}"; shift 2 ;;
      --user) TEST_USER="${2:-}"; shift 2 ;;
      --rhost) TEST_RHOST="${2:-}"; shift 2 ;;
      --tty) TEST_TTY="${2:-}"; shift 2 ;;
      *) fatal "unknown test argument: $1" ;;
    esac
  done
}

cmd_test() {
  parse_test_args "$@"

  [[ -n "${TEST_BACKEND}" ]] || read -r -p "Backend [telegram/bark]: " TEST_BACKEND
  TEST_BACKEND="${TEST_BACKEND:-telegram}"

  if [[ "${TEST_BACKEND}" == "telegram" ]]; then
    [[ -n "${TEST_TG_TOKEN}" ]] || read -r -p "Telegram bot token: " TEST_TG_TOKEN
    [[ -n "${TEST_TG_CHAT_ID}" ]] || read -r -p "Telegram chat id: " TEST_TG_CHAT_ID
  elif [[ "${TEST_BACKEND}" == "bark" ]]; then
    [[ -n "${TEST_BARK_URL}" ]] || read -r -p "Bark URL: " TEST_BARK_URL
  fi
  validate_backend_config "${TEST_BACKEND}" "${TEST_TG_TOKEN}" "${TEST_TG_CHAT_ID}" "${TEST_BARK_URL}"

  local tmpconf
  TEST_TMPDIR="$(mktemp -d)"
  tmpconf="${TEST_TMPDIR}/env"
  trap cleanup_test_tmpdir EXIT

  umask 077
  {
    printf 'SSH_AUTH_NOTIFY_BACKEND=%q\n' "${TEST_BACKEND}"
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "${TEST_TG_TOKEN}"
    printf 'TELEGRAM_CHAT_ID=%q\n' "${TEST_TG_CHAT_ID}"
    printf 'BARK_URL=%q\n' "${TEST_BARK_URL}"
    printf 'SSH_AUTH_NOTIFY_TIMEOUT=5\n'
    printf 'SSH_AUTH_NOTIFY_HOST_ALIAS=test-host\n'
    printf 'SSH_AUTH_NOTIFY_DEBUG=1\n'
    printf 'SSH_AUTH_NOTIFY_SKIP_USERS=\n'
    printf 'SSH_AUTH_NOTIFY_ONLY_USERS=\n'
  } >"${tmpconf}"
  chmod 0600 "${tmpconf}"

  log "running non-persistent test; no PAM or install paths will be modified"
  PAM_USER="${TEST_USER}" \
  PAM_RHOST="${TEST_RHOST}" \
  PAM_SERVICE="sshd" \
  PAM_TTY="${TEST_TTY}" \
  PAM_TYPE="account" \
  SSH_AUTH_NOTIFY_CONFIG="${tmpconf}" \
  SSH_AUTH_NOTIFY_SENDER="${SRC_SCRIPT_DIR}/ssh-auth-notify-send" \
  "${SRC_SCRIPT_DIR}/ssh-auth-notify-worker" --source test
}

cmd_install() {
  parse_common_config_args "$@"
  if [[ -n "${INSTALL_BACKEND}" ]]; then
    validate_backend_config "${INSTALL_BACKEND}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}"
  fi
  need_root
  check_dependencies
  install_scripts
  ensure_install_config
  install_pam_block
  log "install complete"
  log "edit ${CONFIG_FILE} or run: sudo $0 configure"
}

cmd_uninstall() {
  need_root
  while (($#)); do
    case "$1" in
      --purge-backups) PURGE_BACKUPS=1; shift ;;
      *) fatal "unknown uninstall argument: $1" ;;
    esac
  done
  remove_pam_block
  rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
  log "removed ${INSTALL_DIR} and ${CONFIG_DIR}"
  if [[ "${PURGE_BACKUPS}" -eq 1 ]]; then
    rm -f "${PAM_FILE}".bak.ssh-auth-notify.*
    log "removed PAM backups for ${PROJECT_NAME}"
  fi
}

cmd_status() {
  log "install dir: ${INSTALL_DIR} $([[ -d "${INSTALL_DIR}" ]] && echo present || echo missing)"
  log "config: ${CONFIG_FILE} $([[ -f "${CONFIG_FILE}" ]] && echo present || echo missing)"
  if pam_has_block; then
    log "PAM block: present"
  else
    log "PAM block: missing"
  fi
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "config permissions: $(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || stat -f '%Lp' "${CONFIG_FILE}" 2>/dev/null || echo unknown)"
  fi
}

usage() {
  cat <<USAGE
Usage:
  $0 install [--backend telegram|bark] [--telegram-bot-token TOKEN] [--telegram-chat-id ID] [--bark-url URL] [--timeout SECONDS]
  $0 configure
  $0 test [--backend telegram|bark] [--telegram-bot-token TOKEN] [--telegram-chat-id ID] [--bark-url URL] [--user USER] [--rhost IP] [--tty TTY]
  $0 status
  $0 uninstall [--purge-backups]
USAGE
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 1; }
  shift || true
  case "${cmd}" in
    install) cmd_install "$@" ;;
    configure) configure_interactive "$@" ;;
    test) cmd_test "$@" ;;
    status) cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    -h|--help|help) usage ;;
    *) usage; fatal "unknown command: ${cmd}" ;;
  esac
}

main "$@"
