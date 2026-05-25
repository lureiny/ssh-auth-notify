#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

bash -n ssh-auth-notify-manager.sh
bash -n scripts/ssh-auth-notify-wrapper
bash -n scripts/ssh-auth-notify-worker
bash -n scripts/ssh-auth-notify-send
bash -n scripts/channels/telegram.sh
bash -n scripts/channels/bark.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send scripts/channels/telegram.sh scripts/channels/bark.sh
else
  printf 'shellcheck not found; skipped\n' >&2
fi
