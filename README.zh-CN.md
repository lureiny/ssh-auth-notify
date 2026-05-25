# ssh-auth-notify-systemd-run

[English](README.md) | [中文](README.zh-CN.md)

基于 PAM 和 `systemd-run` 的 SSH 登录通知工具。PAM 同步路径只执行极短 wrapper，wrapper 通过 transient systemd service 异步启动 worker，再由 sender 调用一个或多个 channel 模块发送通知。

```text
PAM account
  -> pam_exec.so
  -> ssh-auth-notify-wrapper
  -> systemd-run transient service
  -> ssh-auth-notify-worker
  -> ssh-auth-notify-send
  -> channel modules
```

## 风险提示

安装会修改 `/etc/pam.d/sshd`，并新增 `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf` 来设置 `UsePAM yes`。它不会改写已有 `/etc/ssh/sshd_config`。请先保持一个已有 root session，不要在验证前关闭当前 SSH 会话。安装脚本会自动备份 PAM 文件，但错误 SSH/PAM 配置仍可能影响后续 SSH 登录。

## 快速安装

不需要 clone 或下载整个仓库，直接通过 GitHub raw URL 运行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install
```

如果已有配置不存在或不完整，安装过程会提示选择 Telegram、Bark 或 `telegram,bark`。已有完整配置会保留。只重新配置通知参数：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- configure
```

非交互安装：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install --backends telegram,bark --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --bark-url https://api.day.app/KEY
```

manager 会从以下地址下载运行所需脚本和所有内置 channel 模块：

```text
https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main
```

如果使用 fork，可以覆盖下载源：

```bash
sudo SSH_AUTH_NOTIFY_BASE_URL="https://raw.githubusercontent.com/YOUR_NAME/ssh-auth-notify/main" bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install
```

如果 `/etc/ssh/sshd_config` 没有启用 `/etc/ssh/sshd_config.d/*.conf` 的 Include，drop-in 可能不会生效。脚本只提示，不会自动修改已有 `sshd_config`。安装后会尽量校验并 reload sshd。

## 命令语义

```bash
# 首次安装，或补齐缺失项；保留已有完整配置。
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- install

# 只更新代码文件：wrapper、worker、sender 和所有内置 channel。不会修改配置、PAM、sshd drop-in。
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- update

# 重新安装脚本并重建系统接入点；保留 /etc/ssh-auth-notify/env。
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- reinstall

# 状态和卸载。
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- status
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- uninstall
```

`reinstall` 不是 `uninstall && install`：它会保留 `/etc/ssh-auth-notify/env`，只删除并重建本项目 PAM marker 和 sshd drop-in，重新安装脚本和 channels，然后 reload sshd。

`uninstall` 会删除 PAM marker、sshd drop-in、`/opt/ssh-auth-notify` 和 `/etc/ssh-auth-notify`。默认保留 PAM 备份；如需删除备份，使用 `--purge-backups`。

## 配置

```bash
sudoedit /etc/ssh-auth-notify/env
```

Telegram：

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

Bark：

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

多 channel：

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

`SSH_AUTH_NOTIFY_BACKEND` 是兼容旧版本的字段，新配置优先使用 `SSH_AUTH_NOTIFY_BACKENDS`。`SSH_AUTH_NOTIFY_ONLY_USERS` 非空时只通知这些用户；`SSH_AUTH_NOTIFY_SKIP_USERS` 命中时跳过通知。

## Channel 模块

内置 channel 会一起安装到 `/opt/ssh-auth-notify/scripts/channels/`，用户只需要修改配置即可切换或组合 channel，不需要重新安装。

```text
scripts/channels/telegram.sh
scripts/channels/bark.sh
```

新增 `scripts/channels/<name>.sh`，`<name>` 必须匹配 `^[a-z][a-z0-9_]*$`，并实现：

```bash
<name>_required_vars()
<name>_validate()
<name>_send "$title" "$body"
```

sender 会通过 `channel_resolve` 得到这组函数，然后执行 validate 和 send。模块可以使用 helper：

```bash
require_vars VAR1 VAR2
notify_timeout
urlencode "text"
log_debug "message"
```

新增内置 channel，例如 `ntfy`，需要添加 `scripts/channels/ntfy.sh`，实现 `ntfy_required_vars`、`ntfy_validate`、`ntfy_send`，并把 `ntfy.sh` 加入 `ssh-auth-notify-manager.sh` 的 `CHANNEL_FILES`。这样本地安装和 URL 安装都会自动安装该模块。

## 非持久化测试

测试模式不会写入 `/opt/ssh-auth-notify`、`/etc/ssh-auth-notify` 或 `/etc/pam.d/sshd`。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/lureiny/ssh-auth-notify/main/ssh-auth-notify-manager.sh)" -- test --backends telegram,bark --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --bark-url https://api.day.app/KEY --user demo --rhost 1.2.3.4
```

## 本地验收

```bash
bash -c 'set -e; files="ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send scripts/channels/telegram.sh scripts/channels/bark.sh"; for f in $files; do bash -n "$f"; done; if command -v shellcheck >/dev/null 2>&1; then shellcheck $files; else echo "shellcheck not found; skipped"; fi'
```
