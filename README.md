# ssh-auth-notify-systemd-run

[English](README.md) | [中文](README.zh-CN.md)

SSH login notifications using PAM plus `systemd-run`. The PAM path is intentionally short: a wrapper starts a detached transient systemd service, then a worker sends notifications through one or more channels.

```text
PAM account
  -> pam_exec.so
  -> ssh-auth-notify-wrapper
  -> systemd-run transient service
  -> ssh-auth-notify-worker
  -> ssh-auth-notify-send
  -> channel modules
```

## Safety Notice

Installation modifies `/etc/pam.d/sshd` and creates `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf` with `UsePAM yes`. It does not rewrite an existing `/etc/ssh/sshd_config`. Keep an existing root session open before installing, and do not close your current SSH session until a new login has been verified. PAM is backed up before modification.

## Quick Install

Run directly from the GitHub raw URL. No clone is required.

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install
```

If no complete config exists, install opens a channel checklist when `whiptail` or `dialog` is available, then asks for the required credentials. On minimal systems it falls back to a numbered text prompt. Existing complete config is preserved. Reconfigure only the notification config with:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- configure
```

Non-interactive install example:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install --backends telegram,bark --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --bark-url https://api.day.app/KEY
```

The manager downloads all runtime scripts and built-in channel modules from:

```text
https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main
```

For a fork, override the base URL:

```bash
sudo SSH_AUTH_NOTIFY_BASE_URL="https://raw.githubusercontent.com/YOUR_NAME/ssh-auth-notify/main" bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install
```

If `/etc/ssh/sshd_config` does not include `/etc/ssh/sshd_config.d/*.conf`, the drop-in may not take effect. The script warns about this but does not edit the existing sshd_config. It validates and reloads sshd after install when possible.

## Commands

```bash
# First install or repair missing pieces. Keeps complete config.
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install

# Update code only: wrapper, worker, sender, and all built-in channel modules. Does not touch config, PAM, or sshd drop-in.
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- update

# Reinstall scripts and rebuild integration markers. Keeps /etc/ssh-auth-notify/env.
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- reinstall

# Status and uninstall.
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- status
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- uninstall
```

`reinstall` is not `uninstall && install`: it preserves `/etc/ssh-auth-notify/env`, removes and recreates only the project PAM marker and sshd drop-in, reinstalls scripts and channels, then reloads sshd.

`uninstall` removes the PAM marker, sshd drop-in, `/opt/ssh-auth-notify`, and `/etc/ssh-auth-notify`. PAM backups are kept unless `--purge-backups` is used.

## Configuration

Config file:

```bash
sudoedit /etc/ssh-auth-notify/env
```

Telegram:

```bash
SSH_AUTH_NOTIFY_BACKENDS=telegram
SSH_AUTH_NOTIFY_BACKEND=telegram
TELEGRAM_BOT_TOKEN=123456:abcdef
TELEGRAM_CHAT_ID=123456789
SSH_AUTH_NOTIFY_TIMEOUT=5
SSH_AUTH_NOTIFY_HOST_ALIAS=
SSH_AUTH_NOTIFY_DEBUG=0
SSH_AUTH_NOTIFY_SKIP_USERS=
SSH_AUTH_NOTIFY_ONLY_USERS=
```

Bark:

```bash
SSH_AUTH_NOTIFY_BACKENDS=bark
SSH_AUTH_NOTIFY_BACKEND=bark
BARK_URL=https://api.day.app/your_key
SSH_AUTH_NOTIFY_TIMEOUT=5
SSH_AUTH_NOTIFY_HOST_ALIAS=
SSH_AUTH_NOTIFY_DEBUG=0
SSH_AUTH_NOTIFY_SKIP_USERS=
SSH_AUTH_NOTIFY_ONLY_USERS=
```

Multiple channels:

```bash
SSH_AUTH_NOTIFY_BACKENDS=telegram,bark
SSH_AUTH_NOTIFY_BACKEND=telegram
TELEGRAM_BOT_TOKEN=123456:abcdef
TELEGRAM_CHAT_ID=123456789
BARK_URL=https://api.day.app/your_key
SSH_AUTH_NOTIFY_TIMEOUT=5
SSH_AUTH_NOTIFY_HOST_ALIAS=
SSH_AUTH_NOTIFY_DEBUG=0
SSH_AUTH_NOTIFY_SKIP_USERS=
SSH_AUTH_NOTIFY_ONLY_USERS=
```

`SSH_AUTH_NOTIFY_BACKEND` is kept for compatibility. New config should use `SSH_AUTH_NOTIFY_BACKENDS`. If `SSH_AUTH_NOTIFY_ONLY_USERS` is set, only those comma-separated users are notified. `SSH_AUTH_NOTIFY_SKIP_USERS` suppresses matching users.

## Channel Modules

Built-in channels are installed together under `/opt/ssh-auth-notify/scripts/channels/`, so users can switch channels by editing config without reinstalling.

```text
scripts/channels/telegram.sh
scripts/channels/bark.sh
```

A channel file `scripts/channels/<name>.sh` must implement:

```bash
<name>_required_vars()
<name>_validate()
<name>_send "$title" "$body"
```

The sender resolves a channel into this function set, then calls validate and send. Channel modules can use these helpers from the sender:

```bash
require_vars VAR1 VAR2
notify_timeout
urlencode "text"
log_debug "message"
```

To add a built-in channel such as `ntfy`, add `scripts/channels/ntfy.sh`, implement `ntfy_required_vars`, `ntfy_validate`, and `ntfy_send`, then add `ntfy.sh` to `CHANNEL_FILES` in `ssh-auth-notify-manager.sh`. That makes local install and URL install download the module automatically.

## Non-persistent Test

Test mode does not write `/opt/ssh-auth-notify`, `/etc/ssh-auth-notify`, or `/etc/pam.d/sshd`.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- test --backends telegram,bark --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --bark-url https://api.day.app/KEY --user demo --rhost 1.2.3.4
```

## Local Validation

```bash
bash -c 'set -e; files="ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send scripts/channels/telegram.sh scripts/channels/bark.sh"; for f in $files; do bash -n "$f"; done; if command -v shellcheck >/dev/null 2>&1; then shellcheck $files; else echo "shellcheck not found; skipped"; fi'
```
