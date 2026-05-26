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

## Why This Project

- Low login impact: PAM only runs a small wrapper, then `systemd-run` starts the notification worker asynchronously. Slow network calls or channel APIs do not block the SSH login path.
- Multiple notification channels: Telegram and Bark are built in, and channels can be combined with `SSH_AUTH_NOTIFY_BACKENDS=telegram,bark`.
- One-command install and update: the manager installs scripts, channel modules, PAM integration, and the `UsePAM yes` sshd drop-in.
- Safe reconfiguration: `configure` uses an interactive menu loop, so you can update channels, node name, or machine address one item at a time.
- Clear host identity: set a display node name for the notification title, and optionally include the machine's external IPv4 or fixed domain/IP in the message body.
- User filtering: notify only selected users or skip selected users with comma-separated config fields.

## Notification Example

Title:

```text
🔐 SSH Login · prod-api-01
```

Body:

```text
✅ New SSH login detected

👤 User: root
🌐 Remote IP: 203.0.113.25
🖥️ Host: ssh.example.com
🔧 Service: sshd
💻 Terminal: ssh
📌 Event: Account session
🕒 Time: 2026-05-26 10:27:20
🚀 Trigger: PAM hook
```

The title host comes from `--node-name` or the local hostname. The body `Host` line appears only when machine address display is enabled; it uses `--machine-address ADDR_OR_HOST` or fetches the external IPv4 from `ifconfig.me` when enabled without a fixed value.

## Safety Notice

Installation modifies `/etc/pam.d/sshd` and creates `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf` with `UsePAM yes`. It does not rewrite an existing `/etc/ssh/sshd_config`. Keep an existing root session open before installing, and do not close your current SSH session until a new login has been verified. PAM is backed up before modification.

## Quick Install

Run directly from the GitHub raw URL. No clone is required.

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install
```

If no complete config exists, install opens a channel checklist when `whiptail` or `dialog` is available, then asks for the required credentials and an optional node name. On minimal systems it falls back to a numbered text prompt. Existing complete config is preserved. Pass `--node-name NAME` during install or reinstall to set the display name used in notifications; when omitted, the worker falls back to the machine hostname. Machine address display is disabled by default; enable it with `--send-machine-address`, disable it with `--no-send-machine-address`, or pass `--machine-address ADDR_OR_HOST` to enable it with a fixed IPv4/domain. If enabled without a fixed value, the worker fetches the external IPv4 from `ifconfig.me`. Reconfigure from an interactive menu. After changing one item, the menu is shown again so you can continue editing channels, node name, or machine address options:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- configure
```


You can also update only the display options non-interactively when a config already exists:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- configure --node-name prod-api-01 --machine-address ssh.example.com
```

Non-interactive install example:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install --backends telegram,bark --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --bark-url https://api.day.app/KEY --node-name prod-api-01 --machine-address ssh.example.com
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
SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=0
SSH_AUTH_NOTIFY_MACHINE_ADDR=
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
SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=0
SSH_AUTH_NOTIFY_MACHINE_ADDR=
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
SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=0
SSH_AUTH_NOTIFY_MACHINE_ADDR=
SSH_AUTH_NOTIFY_DEBUG=0
SSH_AUTH_NOTIFY_SKIP_USERS=
SSH_AUTH_NOTIFY_ONLY_USERS=
```

`SSH_AUTH_NOTIFY_BACKEND` is kept for compatibility. New config should use `SSH_AUTH_NOTIFY_BACKENDS`. `SSH_AUTH_NOTIFY_HOST_ALIAS` overrides the host shown in notifications; leave it empty to use `hostname -f`/`hostname`. `SSH_AUTH_NOTIFY_SEND_MACHINE_ADDR=1` adds the machine address field. `SSH_AUTH_NOTIFY_MACHINE_ADDR` can be a fixed IPv4 address or domain; leave it empty to fetch the external IPv4 from `ifconfig.me` when the field is enabled. If `SSH_AUTH_NOTIFY_ONLY_USERS` is set, only those comma-separated users are notified. `SSH_AUTH_NOTIFY_SKIP_USERS` suppresses matching users.

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
Channels can choose the message format they consume. The worker passes both a plain list body (`--body`) and an HTML body (`--body-html`); Telegram uses HTML with a `<pre>` block for aligned fields, while Bark uses the plain emoji list for mobile notifications.

```bash
require_vars VAR1 VAR2
notify_timeout
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
