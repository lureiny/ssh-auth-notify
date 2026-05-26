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
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_CONFIG_DIR}/99-ssh-auth-notify.conf"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-${0:-.}}"
SELF_DIR="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" 2>/dev/null && pwd || pwd)"
SRC_SCRIPT_DIR="${SELF_DIR}/scripts"
REMOTE_BASE_URL="${SSH_AUTH_NOTIFY_BASE_URL:-https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main}"
CHANNEL_FILES=(telegram.sh bark.sh)

INSTALL_BACKENDS=""
INSTALL_BARK_URL=""
INSTALL_TG_TOKEN=""
INSTALL_TG_CHAT_ID=""
INSTALL_TIMEOUT="5"
INSTALL_NODE_NAME=""
INSTALL_NODE_NAME_SET="0"
INSTALL_SEND_MACHINE_ADDR="0"
INSTALL_SEND_MACHINE_ADDR_SET="0"
INSTALL_MACHINE_ADDR=""
PURGE_BACKUPS=0
TEST_TMPDIR=""
TEST_SCRIPT_DIR=""

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

check_test_dependencies() {
  local missing=() cmd
  for cmd in bash curl python3 install; do
    have_cmd "${cmd}" || missing+=("${cmd}")
  done
  ((${#missing[@]} == 0)) || fatal "missing test dependencies: ${missing[*]}"
}

local_scripts_available() {
  local channel_file
  [[ -x "${SRC_SCRIPT_DIR}/ssh-auth-notify-wrapper" \
    && -x "${SRC_SCRIPT_DIR}/ssh-auth-notify-worker" \
    && -x "${SRC_SCRIPT_DIR}/ssh-auth-notify-send" ]] || return 1

  for channel_file in "${CHANNEL_FILES[@]}"; do
    [[ -r "${SRC_SCRIPT_DIR}/channels/${channel_file}" ]] || return 1
  done
}

download_project_script() {
  local name="${1:-}" dest="${2:-}" url
  [[ -n "${name}" && -n "${dest}" ]] || fatal "download_project_script requires name and dest"
  have_cmd curl || fatal "curl is required to download project scripts"
  url="${REMOTE_BASE_URL%/}/scripts/${name}"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "${url}" -o "${dest}"
  chmod 0755 "${dest}"
}

install_or_download_scripts() {
  local dest_dir="${1:-}" channel_file
  [[ -n "${dest_dir}" ]] || fatal "destination script directory is required"
  install -d -m 0755 "${dest_dir}"
  install -d -m 0755 "${dest_dir}/channels"

  if local_scripts_available; then
    install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-wrapper" "${dest_dir}/ssh-auth-notify-wrapper"
    install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-worker" "${dest_dir}/ssh-auth-notify-worker"
    install -m 0755 "${SRC_SCRIPT_DIR}/ssh-auth-notify-send" "${dest_dir}/ssh-auth-notify-send"
    for channel_file in "${CHANNEL_FILES[@]}"; do
      install -m 0755 "${SRC_SCRIPT_DIR}/channels/${channel_file}" "${dest_dir}/channels/${channel_file}"
    done
    return 0
  fi

  log "local scripts not found; downloading scripts from ${REMOTE_BASE_URL}"
  download_project_script "ssh-auth-notify-wrapper" "${dest_dir}/ssh-auth-notify-wrapper"
  download_project_script "ssh-auth-notify-worker" "${dest_dir}/ssh-auth-notify-worker"
  download_project_script "ssh-auth-notify-send" "${dest_dir}/ssh-auth-notify-send"
  for channel_file in "${CHANNEL_FILES[@]}"; do
    download_project_script "channels/${channel_file}" "${dest_dir}/channels/${channel_file}"
  done
}

primary_backend() {
  local backends="${1:-telegram}" first
  first="${backends%%,*}"
  first="${first//[[:space:]]/}"
  printf '%s' "${first}"
}

backend_list_contains() {
  local backends="${1:-}" needle="${2:-}" old_ifs item
  [[ -n "${backends}" && -n "${needle}" ]] || return 1
  old_ifs="${IFS}"
  IFS=',' read -r -a items <<<"${backends}"
  IFS="${old_ifs}"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

validate_backend_config() {
  local backends="${1:-}" old_ifs item seen=0
  [[ -n "${backends}" ]] || fatal "backend is required"
  old_ifs="${IFS}"
  IFS=',' read -r -a items <<<"${backends}"
  IFS="${old_ifs}"

  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "${item}" ]] || continue
    seen=1
    case "${item}" in
      telegram)
        [[ -n "${2:-}" ]] || fatal "telegram bot token is required"
        [[ -n "${3:-}" ]] || fatal "telegram chat id is required"
        ;;
      bark)
        [[ -n "${4:-}" ]] || fatal "bark url is required"
        ;;
      *) fatal "unsupported backend: ${item}" ;;
    esac
  done
  [[ "${seen}" -eq 1 ]] || fatal "backend is required"
}

quote_env_value() {
  printf '%q' "${1:-}"
}

write_config_file() {
  local backends="${1:-telegram}" tg_token="${2:-}" tg_chat_id="${3:-}" bark_url="${4:-}" timeout="${5:-5}" node_name="${6:-}" send_machine_addr="${7:-0}" machine_addr="${8:-}"
  install -d -m 0700 "${CONFIG_DIR}"
  umask 077
  {
    printf '# comma-separated: telegram,bark\n'
    printf 'SSH_AUTH_NOTIFY_BACKENDS=%q\n' "${backends}"
    printf '# Deprecated compatibility field; first backend from SSH_AUTH_NOTIFY_BACKENDS.\n'
    printf 'SSH_AUTH_NOTIFY_BACKEND=%q\n' "$(primary_backend "${backends}")"
    printf '\n# Telegram\n'
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "${tg_token}"
    printf 'TELEGRAM_CHAT_ID=%q\n' "${tg_chat_id}"
    printf '\n# Bark\n'
    printf 'BARK_URL=%q\n' "${bark_url}"
    printf '\n# Common\n'
    printf 'SSH_AUTH_NOTIFY_TIMEOUT=%q\n' "${timeout}"
    if [[ -n "${node_name}" ]]; then
      printf 'SSH_AUTH_NOTIFY_HOST_ALIAS=%q\n' "${node_name}"
    else
      printf 'SSH_AUTH_NOTIFY_HOST_ALIAS=\n'
    fi
    printf 'SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=%q\n' "${send_machine_addr}"
    printf 'SSH_AUTH_NOTIFY_MACHINE_ADDR=%q\n' "${machine_addr}"
    printf 'SSH_AUTH_NOTIFY_DEBUG=0\n'
    printf 'SSH_AUTH_NOTIFY_SKIP_USERS=\n'
    printf 'SSH_AUTH_NOTIFY_ONLY_USERS=\n'
  } >"${CONFIG_FILE}"
  chmod 0600 "${CONFIG_FILE}"
}

update_config_key() {
  local key="${1:-}" value="${2:-}" tmp="${CONFIG_FILE}.tmp.${PROJECT_NAME}" quoted_value
  [[ -n "${key}" && -f "${CONFIG_FILE}" ]] || return 0
  quoted_value="$(quote_env_value "${value}")"
  awk -v key="${key}" -v value="${quoted_value}" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (updated != 1) {
        print key "=" value
      }
    }
  ' "${CONFIG_FILE}" >"${tmp}"
  install -m 0600 "${tmp}" "${CONFIG_FILE}"
  rm -f "${tmp}"
}

update_config_install_options() {
  if [[ "${INSTALL_NODE_NAME_SET}" -eq 1 ]]; then
    update_config_key "SSH_AUTH_NOTIFY_HOST_ALIAS" "${INSTALL_NODE_NAME}"
    log "updated node name in config: ${CONFIG_FILE}"
  fi
  if [[ "${INSTALL_SEND_MACHINE_ADDR_SET}" -eq 1 ]]; then
    update_config_key "SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR" "${INSTALL_SEND_MACHINE_ADDR}"
    update_config_key "SSH_AUTH_NOTIFY_MACHINE_ADDR" "${INSTALL_MACHINE_ADDR}"
    log "updated machine address options in config: ${CONFIG_FILE}"
  fi
}

load_existing_install_options() {
  [[ -f "${CONFIG_FILE}" ]] || return 0

  local SSH_AUTH_NOTIFY_HOST_ALIAS="" SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR="" SSH_AUTH_NOTIFY_MACHINE_ADDR=""
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  if [[ "${INSTALL_NODE_NAME_SET}" -eq 0 ]]; then
    INSTALL_NODE_NAME="${SSH_AUTH_NOTIFY_HOST_ALIAS:-}"
  fi
  if [[ "${INSTALL_SEND_MACHINE_ADDR_SET}" -eq 0 ]]; then
    INSTALL_SEND_MACHINE_ADDR="${SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR:-0}"
    INSTALL_MACHINE_ADDR="${SSH_AUTH_NOTIFY_MACHINE_ADDR:-}"
  fi
}

config_is_complete() {
  [[ -f "${CONFIG_FILE}" ]] || return 1

  local SSH_AUTH_NOTIFY_BACKENDS="" SSH_AUTH_NOTIFY_BACKEND="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID="" BARK_URL=""
  local old_ifs item seen=0
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  SSH_AUTH_NOTIFY_BACKENDS="${SSH_AUTH_NOTIFY_BACKENDS:-${SSH_AUTH_NOTIFY_BACKEND:-}}"
  [[ -n "${SSH_AUTH_NOTIFY_BACKENDS}" ]] || return 1

  old_ifs="${IFS}"
  IFS=',' read -r -a items <<<"${SSH_AUTH_NOTIFY_BACKENDS}"
  IFS="${old_ifs}"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "${item}" ]] || continue
    seen=1
    case "${item}" in
      telegram) [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]] || return 1 ;;
      bark) [[ -n "${BARK_URL}" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
  [[ "${seen}" -eq 1 ]]
}

ensure_install_config() {
  install -d -m 0700 "${CONFIG_DIR}"

  if [[ -n "${INSTALL_BACKENDS}" ]]; then
    write_config_file "${INSTALL_BACKENDS}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}" "${INSTALL_TIMEOUT}" "${INSTALL_NODE_NAME}" "${INSTALL_SEND_MACHINE_ADDR}" "${INSTALL_MACHINE_ADDR}"
    log "wrote config: ${CONFIG_FILE}"
    return 0
  fi

  if config_is_complete; then
    chmod 0600 "${CONFIG_FILE}"
    update_config_install_options
    log "config already exists and looks complete: ${CONFIG_FILE}"
    return 0
  fi

  if [[ -f "${CONFIG_FILE}" ]]; then
    warn "config exists but is incomplete: ${CONFIG_FILE}"
  else
    log "no config found; starting interactive configuration"
  fi

  if [[ ! -t 0 ]]; then
    fatal "configuration is required; rerun with --backends telegram,bark and credentials, or run interactively"
  fi

  configure_initial_interactive
}

install_scripts() {
  install_or_download_scripts "${SCRIPT_DIR}"
  log "installed scripts to ${SCRIPT_DIR}"
}

prepare_test_scripts() {
  if local_scripts_available; then
    TEST_SCRIPT_DIR="${SRC_SCRIPT_DIR}"
    return 0
  fi

  TEST_SCRIPT_DIR="${TEST_TMPDIR}/scripts"
  install_or_download_scripts "${TEST_SCRIPT_DIR}"
}

backup_file() {
  local file="${1:-}" label="${2:-file}"
  [[ -f "${file}" ]] || fatal "${label} not found: ${file}"
  local backup="${file}.bak.ssh-auth-notify.$(date +%Y%m%d-%H%M%S)"
  cp -a "${file}" "${backup}"
  log "backup ${label}: ${backup}"
}

backup_pam() {
  backup_file "${PAM_FILE}" "PAM"
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

sshd_dropin_present() {
  [[ -f "${SSHD_DROPIN}" ]]
}

sshd_config_includes_dropins() {
  [[ -f "${SSHD_CONFIG}" ]] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*Include[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        if ($i == "/etc/ssh/sshd_config.d/*.conf" || $i == "sshd_config.d/*.conf") { found=1 }
      }
    }
    END { exit(found == 1 ? 0 : 1) }
  ' "${SSHD_CONFIG}"
}

install_sshd_use_pam() {
  install -d -m 0755 "${SSHD_CONFIG_DIR}"
  {
    printf '# Created by ssh-auth-notify. Remove with: ssh-auth-notify-manager.sh uninstall\n'
    printf 'UsePAM yes\n'
  } >"${SSHD_DROPIN}"
  chmod 0644 "${SSHD_DROPIN}"
  log "installed sshd_config drop-in: ${SSHD_DROPIN}"

  if ! sshd_config_includes_dropins; then
    warn "${SSHD_CONFIG} does not appear to include ${SSHD_CONFIG_DIR}/*.conf; ${SSHD_DROPIN} may not take effect until Include is enabled manually"
  fi
}

find_sshd_binary() {
  local candidate
  for candidate in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done
  return 1
}

validate_sshd_config() {
  local sshd_bin
  if sshd_bin="$(find_sshd_binary)"; then
    "${sshd_bin}" -t -f "${SSHD_CONFIG}"
  else
    warn "sshd binary not found; skipping sshd_config validation before reload"
    return 0
  fi
}

reload_sshd() {
  if ! validate_sshd_config; then
    warn "sshd_config validation failed; sshd was not reloaded"
    return 0
  fi

  if have_cmd systemctl; then
    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
      log "reloaded sshd"
      return 0
    fi
  fi

  warn "could not reload sshd automatically; run: systemctl reload sshd || systemctl reload ssh"
  return 0
}

remove_sshd_use_pam_block() {
  if sshd_dropin_present; then
    rm -f -- "${SSHD_DROPIN}"
    log "removed sshd_config drop-in: ${SSHD_DROPIN}"
  else
    log "sshd_config drop-in not present: ${SSHD_DROPIN}"
  fi
}

parse_common_config_args() {
  while (($#)); do
    case "$1" in
      --backend|--backends) INSTALL_BACKENDS="${2:-}"; shift 2 ;;
      --bark-url) INSTALL_BARK_URL="${2:-}"; shift 2 ;;
      --telegram-bot-token) INSTALL_TG_TOKEN="${2:-}"; shift 2 ;;
      --telegram-chat-id) INSTALL_TG_CHAT_ID="${2:-}"; shift 2 ;;
      --timeout) INSTALL_TIMEOUT="${2:-5}"; shift 2 ;;
      --node-name|--host-alias) INSTALL_NODE_NAME="${2:-}"; INSTALL_NODE_NAME_SET="1"; shift 2 ;;
      --send-machine-address) INSTALL_SEND_MACHINE_ADDR="1"; INSTALL_SEND_MACHINE_ADDR_SET="1"; shift ;;
      --no-send-machine-address) INSTALL_SEND_MACHINE_ADDR="0"; INSTALL_SEND_MACHINE_ADDR_SET="1"; shift ;;
      --machine-address|--machine-host) INSTALL_MACHINE_ADDR="${2:-}"; INSTALL_SEND_MACHINE_ADDR="1"; INSTALL_SEND_MACHINE_ADDR_SET="1"; shift 2 ;;
      *) fatal "unknown argument: $1" ;;
    esac
  done
}

prompt_backends_interactive() {
  local selected channel_file name i old_ifs item result

  if have_cmd whiptail && [[ -t 0 && -t 1 ]]; then
    local options=()
    for channel_file in "${CHANNEL_FILES[@]}"; do
      name="${channel_file%.sh}"
      if [[ "${name}" == "telegram" ]]; then
        options+=("${name}" "${name} notifications" ON)
      else
        options+=("${name}" "${name} notifications" OFF)
      fi
    done
    selected="$(whiptail --title "ssh-auth-notify" --checklist "Select notification channels" 15 72 8 "${options[@]}" 3>&1 1>&2 2>&3)" || return 1
    selected="${selected//"/}"
    selected="${selected// /,}"
    [[ -n "${selected}" ]] && { printf "%s" "${selected}"; return 0; }
  fi

  if have_cmd dialog && [[ -t 0 && -t 1 ]]; then
    local options=()
    for channel_file in "${CHANNEL_FILES[@]}"; do
      name="${channel_file%.sh}"
      if [[ "${name}" == "telegram" ]]; then
        options+=("${name}" "${name} notifications" on)
      else
        options+=("${name}" "${name} notifications" off)
      fi
    done
    selected="$(dialog --stdout --checklist "Select notification channels" 15 72 8 "${options[@]}")" || return 1
    selected="${selected//"/}"
    selected="${selected// /,}"
    [[ -n "${selected}" ]] && { printf "%s" "${selected}"; return 0; }
  fi

  printf "Available channels:\n" >&2
  i=1
  for channel_file in "${CHANNEL_FILES[@]}"; do
    printf "  %d) %s\n" "${i}" "${channel_file%.sh}" >&2
    i=$((i + 1))
  done
  read -r -p "Channels [1 or 1,2 or telegram,bark; default: 1]: " selected
  selected="${selected:-1}"
  selected="${selected//[[:space:]]/}"

  old_ifs="${IFS}"
  IFS="," read -r -a items <<<"${selected}"
  IFS="${old_ifs}"
  result=""
  for item in "${items[@]}"; do
    if [[ "${item}" =~ ^[0-9]+$ ]]; then
      i=1
      for channel_file in "${CHANNEL_FILES[@]}"; do
        if [[ "${i}" -eq "${item}" ]]; then
          name="${channel_file%.sh}"
          result="${result}${result:+,}${name}"
          break
        fi
        i=$((i + 1))
      done
    else
      result="${result}${result:+,}${item}"
    fi
  done

  printf "%s" "${result:-telegram}"
}

load_configure_values() {
  CFG_BACKENDS="telegram"
  CFG_TG_TOKEN=""
  CFG_TG_CHAT_ID=""
  CFG_BARK_URL=""
  CFG_TIMEOUT="5"
  CFG_NODE_NAME=""
  CFG_SEND_MACHINE_ADDR="0"
  CFG_MACHINE_ADDR=""

  [[ -f "${CONFIG_FILE}" ]] || return 0

  local SSH_AUTH_NOTIFY_BACKENDS="" SSH_AUTH_NOTIFY_BACKEND="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID="" BARK_URL=""
  local SSH_AUTH_NOTIFY_TIMEOUT="" SSH_AUTH_NOTIFY_HOST_ALIAS="" SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR="" SSH_AUTH_NOTIFY_MACHINE_ADDR=""
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  CFG_BACKENDS="${SSH_AUTH_NOTIFY_BACKENDS:-${SSH_AUTH_NOTIFY_BACKEND:-telegram}}"
  CFG_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  CFG_TG_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  CFG_BARK_URL="${BARK_URL:-}"
  CFG_TIMEOUT="${SSH_AUTH_NOTIFY_TIMEOUT:-5}"
  CFG_NODE_NAME="${SSH_AUTH_NOTIFY_HOST_ALIAS:-}"
  CFG_SEND_MACHINE_ADDR="${SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR:-0}"
  CFG_MACHINE_ADDR="${SSH_AUTH_NOTIFY_MACHINE_ADDR:-}"
}

save_configure_values() {
  validate_backend_config "${CFG_BACKENDS}" "${CFG_TG_TOKEN}" "${CFG_TG_CHAT_ID}" "${CFG_BARK_URL}"
  write_config_file "${CFG_BACKENDS}" "${CFG_TG_TOKEN}" "${CFG_TG_CHAT_ID}" "${CFG_BARK_URL}" "${CFG_TIMEOUT}" "${CFG_NODE_NAME}" "${CFG_SEND_MACHINE_ADDR}" "${CFG_MACHINE_ADDR}"
  log "updated config: ${CONFIG_FILE}"
}

configure_channels_interactive() {
  local backends token_answer chat_answer bark_answer
  printf 'Current channels: %s\n' "${CFG_BACKENDS}"
  backends="$(prompt_backends_interactive)" || fatal "channel selection cancelled"

  if backend_list_contains "${backends}" "telegram"; then
    read -r -p "Telegram bot token [keep existing]: " token_answer
    [[ -n "${token_answer}" ]] && CFG_TG_TOKEN="${token_answer}"
    read -r -p "Telegram chat id [keep existing]: " chat_answer
    [[ -n "${chat_answer}" ]] && CFG_TG_CHAT_ID="${chat_answer}"
  fi
  if backend_list_contains "${backends}" "bark"; then
    read -r -p "Bark URL [keep existing]: " bark_answer
    [[ -n "${bark_answer}" ]] && CFG_BARK_URL="${bark_answer}"
  fi

  CFG_BACKENDS="${backends}"
  save_configure_values
}

configure_initial_interactive() {
  need_root
  install -d -m 0700 "${CONFIG_DIR}"

  local backends token chat_id bark_url node_name_answer
  backends="$(prompt_backends_interactive)" || fatal "channel selection cancelled"

  if backend_list_contains "${backends}" "telegram"; then
    read -r -p "Telegram bot token: " token
    read -r -p "Telegram chat id: " chat_id
  fi
  if backend_list_contains "${backends}" "bark"; then
    read -r -p "Bark URL, e.g. https://api.day.app/KEY: " bark_url
  fi

  if [[ "${INSTALL_NODE_NAME_SET}" -eq 0 ]]; then
    read -r -p "Node name [empty uses hostname]: " node_name_answer
    INSTALL_NODE_NAME="${node_name_answer}"
  fi

  validate_backend_config "${backends}" "${token:-}" "${chat_id:-}" "${bark_url:-}"
  write_config_file "${backends}" "${token:-}" "${chat_id:-}" "${bark_url:-}" "5" "${INSTALL_NODE_NAME}" "${INSTALL_SEND_MACHINE_ADDR}" "${INSTALL_MACHINE_ADDR}"
  log "updated config: ${CONFIG_FILE}"
}

configure_node_interactive() {
  local answer current
  current="${CFG_NODE_NAME:-empty uses hostname}"
  read -r -p "Node name [current: ${current}; '-' clears]: " answer
  case "${answer}" in
    "") log "node name unchanged" ;;
    -) CFG_NODE_NAME=""; save_configure_values ;;
    *) CFG_NODE_NAME="${answer}"; save_configure_values ;;
  esac
}

configure_machine_addr_interactive() {
  local enable_answer addr_answer current_addr
  if [[ "${CFG_SEND_MACHINE_ADDR}" == "1" ]]; then
    read -r -p "Send machine address? [Y/n]: " enable_answer
  else
    read -r -p "Send machine address? [y/N]: " enable_answer
  fi

  case "${enable_answer}" in
    y|Y|yes|YES) CFG_SEND_MACHINE_ADDR="1" ;;
    n|N|no|NO) CFG_SEND_MACHINE_ADDR="0" ;;
    "") ;;
    *) warn "invalid choice; keeping current setting" ;;
  esac

  if [[ "${CFG_SEND_MACHINE_ADDR}" == "1" ]]; then
    current_addr="${CFG_MACHINE_ADDR:-empty fetches ifconfig.me}"
    read -r -p "Machine address [current: ${current_addr}; '-' clears to fetch ifconfig.me]: " addr_answer
    case "${addr_answer}" in
      "") ;;
      -) CFG_MACHINE_ADDR="" ;;
      *) CFG_MACHINE_ADDR="${addr_answer}" ;;
    esac
  else
    CFG_MACHINE_ADDR=""
  fi

  save_configure_values
}

configure_interactive() {
  need_root
  install -d -m 0700 "${CONFIG_DIR}"
  load_configure_values

  local choice node_summary machine_summary
  while true; do
    node_summary="${CFG_NODE_NAME:-hostname fallback}"
    if [[ "${CFG_SEND_MACHINE_ADDR}" == "1" ]]; then
      machine_summary="enabled (${CFG_MACHINE_ADDR:-fetch ifconfig.me})"
    else
      machine_summary="disabled"
    fi

    printf '\nConfigure %s\n' "${PROJECT_NAME}"
    printf '  1) Channels and credentials: %s\n' "${CFG_BACKENDS}"
    printf '  2) Node name: %s\n' "${node_summary}"
    printf '  3) Machine address: %s\n' "${machine_summary}"
    printf '  0) Exit\n'
    read -r -p "Select item to modify: " choice

    case "${choice}" in
      1) configure_channels_interactive ;;
      2) configure_node_interactive ;;
      3) configure_machine_addr_interactive ;;
      0|q|Q|exit) break ;;
      *) warn "unknown menu item: ${choice}" ;;
    esac
  done
}

parse_test_args() {
  TEST_BACKENDS=""
  TEST_BARK_URL=""
  TEST_TG_TOKEN=""
  TEST_TG_CHAT_ID=""
  TEST_USER="demo"
  TEST_RHOST="127.0.0.1"
  TEST_TTY="ssh"

  while (($#)); do
    case "$1" in
      --backend|--backends) TEST_BACKENDS="${2:-}"; shift 2 ;;
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

  [[ -n "${TEST_BACKENDS}" ]] || read -r -p "Backends [telegram/bark/telegram,bark]: " TEST_BACKENDS
  TEST_BACKENDS="${TEST_BACKENDS:-telegram}"

  if backend_list_contains "${TEST_BACKENDS}" "telegram"; then
    [[ -n "${TEST_TG_TOKEN}" ]] || read -r -p "Telegram bot token: " TEST_TG_TOKEN
    [[ -n "${TEST_TG_CHAT_ID}" ]] || read -r -p "Telegram chat id: " TEST_TG_CHAT_ID
  fi
  if backend_list_contains "${TEST_BACKENDS}" "bark"; then
    [[ -n "${TEST_BARK_URL}" ]] || read -r -p "Bark URL: " TEST_BARK_URL
  fi
  validate_backend_config "${TEST_BACKENDS}" "${TEST_TG_TOKEN}" "${TEST_TG_CHAT_ID}" "${TEST_BARK_URL}"
  check_test_dependencies

  local tmpconf
  TEST_TMPDIR="$(mktemp -d)"
  tmpconf="${TEST_TMPDIR}/env"
  trap cleanup_test_tmpdir EXIT

  umask 077
  {
    printf 'SSH_AUTH_NOTIFY_BACKENDS=%q\n' "${TEST_BACKENDS}"
    printf 'SSH_AUTH_NOTIFY_BACKEND=%q\n' "$(primary_backend "${TEST_BACKENDS}")"
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "${TEST_TG_TOKEN}"
    printf 'TELEGRAM_CHAT_ID=%q\n' "${TEST_TG_CHAT_ID}"
    printf 'BARK_URL=%q\n' "${TEST_BARK_URL}"
    printf 'SSH_AUTH_NOTIFY_TIMEOUT=5\n'
    printf 'SSH_AUTH_NOTIFY_HOST_ALIAS=test-host\n'
    printf 'SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=0\n'
    printf 'SSH_AUTH_NOTIFY_MACHINE_ADDR=\n'
    printf 'SSH_AUTH_NOTIFY_DEBUG=1\n'
    printf 'SSH_AUTH_NOTIFY_SKIP_USERS=\n'
    printf 'SSH_AUTH_NOTIFY_ONLY_USERS=\n'
  } >"${tmpconf}"
  chmod 0600 "${tmpconf}"
  prepare_test_scripts

  log "running non-persistent test; no PAM or install paths will be modified"
  PAM_USER="${TEST_USER}" \
  PAM_RHOST="${TEST_RHOST}" \
  PAM_SERVICE="sshd" \
  PAM_TTY="${TEST_TTY}" \
  PAM_TYPE="account" \
  SSH_AUTH_NOTIFY_CONFIG="${tmpconf}" \
  SSH_AUTH_NOTIFY_SENDER="${TEST_SCRIPT_DIR}/ssh-auth-notify-send" \
  "${TEST_SCRIPT_DIR}/ssh-auth-notify-worker" --source test
}

cmd_update() {
  need_root
  install_scripts
  log "update complete"
}

cmd_configure() {
  parse_common_config_args "$@"
  need_root
  install -d -m 0700 "${CONFIG_DIR}"

  if [[ -n "${INSTALL_BACKENDS}" ]]; then
    load_existing_install_options
    validate_backend_config "${INSTALL_BACKENDS}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}"
    write_config_file "${INSTALL_BACKENDS}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}" "${INSTALL_TIMEOUT}" "${INSTALL_NODE_NAME}" "${INSTALL_SEND_MACHINE_ADDR}" "${INSTALL_MACHINE_ADDR}"
    log "updated config: ${CONFIG_FILE}"
    return 0
  fi

  if [[ "${INSTALL_NODE_NAME_SET}" -eq 1 || "${INSTALL_SEND_MACHINE_ADDR_SET}" -eq 1 ]]; then
    [[ -f "${CONFIG_FILE}" ]] || fatal "config not found: ${CONFIG_FILE}"
    update_config_install_options
    log "updated config: ${CONFIG_FILE}"
    return 0
  fi

  configure_interactive
}

cmd_reinstall() {
  parse_common_config_args "$@"
  if [[ -n "${INSTALL_BACKENDS}" ]]; then
    validate_backend_config "${INSTALL_BACKENDS}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}"
  fi
  need_root
  check_dependencies
  remove_pam_block
  remove_sshd_use_pam_block
  install_scripts
  ensure_install_config
  install_sshd_use_pam
  install_pam_block
  reload_sshd
  log "reinstall complete"
  log "kept config: ${CONFIG_FILE}"
}

cmd_install() {
  parse_common_config_args "$@"
  if [[ -n "${INSTALL_BACKENDS}" ]]; then
    validate_backend_config "${INSTALL_BACKENDS}" "${INSTALL_TG_TOKEN}" "${INSTALL_TG_CHAT_ID}" "${INSTALL_BARK_URL}"
  fi
  need_root
  check_dependencies
  install_scripts
  ensure_install_config
  install_sshd_use_pam
  install_pam_block
  reload_sshd
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
  remove_sshd_use_pam_block
  reload_sshd
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
  log "wrapper: ${SCRIPT_DIR}/ssh-auth-notify-wrapper $([[ -x "${SCRIPT_DIR}/ssh-auth-notify-wrapper" ]] && echo present || echo missing)"
  log "worker: ${SCRIPT_DIR}/ssh-auth-notify-worker $([[ -x "${SCRIPT_DIR}/ssh-auth-notify-worker" ]] && echo present || echo missing)"
  log "sender: ${SCRIPT_DIR}/ssh-auth-notify-send $([[ -x "${SCRIPT_DIR}/ssh-auth-notify-send" ]] && echo present || echo missing)"
  local channel_file
  for channel_file in "${CHANNEL_FILES[@]}"; do
    log "channel: ${SCRIPT_DIR}/channels/${channel_file} $([[ -r "${SCRIPT_DIR}/channels/${channel_file}" ]] && echo present || echo missing)"
  done
  if pam_has_block; then
    log "PAM block: present"
  else
    log "PAM block: missing"
  fi
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "config permissions: $(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || stat -f '%Lp' "${CONFIG_FILE}" 2>/dev/null || echo unknown)"
  fi
  if sshd_dropin_present; then
    log "sshd_config drop-in: present (${SSHD_DROPIN})"
  else
    log "sshd_config drop-in: missing (${SSHD_DROPIN})"
  fi
  if sshd_config_includes_dropins; then
    log "sshd_config.d Include: present"
  else
    log "sshd_config.d Include: missing or unknown"
  fi
}

usage() {
  cat <<USAGE
Usage:
  $0 install [--backends telegram,bark] [--telegram-bot-token TOKEN] [--telegram-chat-id ID] [--bark-url URL] [--timeout SECONDS] [--node-name NAME] [--send-machine-address|--no-send-machine-address] [--machine-address ADDR_OR_HOST]
  $0 update
  $0 reinstall [--backends telegram,bark] [--telegram-bot-token TOKEN] [--telegram-chat-id ID] [--bark-url URL] [--timeout SECONDS] [--node-name NAME] [--send-machine-address|--no-send-machine-address] [--machine-address ADDR_OR_HOST]
  $0 configure [--node-name NAME] [--send-machine-address|--no-send-machine-address] [--machine-address ADDR_OR_HOST]
  $0 test [--backends telegram,bark] [--telegram-bot-token TOKEN] [--telegram-chat-id ID] [--bark-url URL] [--user USER] [--rhost IP] [--tty TTY]
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
    update) cmd_update "$@" ;;
    reinstall) cmd_reinstall "$@" ;;
    configure) cmd_configure "$@" ;;
    test) cmd_test "$@" ;;
    status) cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    -h|--help|help) usage ;;
    *) usage; fatal "unknown command: ${cmd}" ;;
  esac
}

main "$@"
