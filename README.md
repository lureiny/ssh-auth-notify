# ssh-auth-notify-systemd-run

SSH 登录通知工具。它通过 PAM `pam_exec.so` 在 SSH 登录成功后的 account 阶段触发一个极短 wrapper，wrapper 使用 `systemd-run` 启动 transient service，再由 worker 异步发送 Bark 或 Telegram 通知。

```text
PAM account
  -> pam_exec.so
  -> ssh-auth-notify-wrapper
  -> systemd-run transient service
  -> ssh-auth-notify-worker
  -> ssh-auth-notify-send
  -> Bark / Telegram
```

## 风险提示

安装会修改 `/etc/pam.d/sshd`，并新增 `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf` 来设置 `UsePAM yes`。它不会改写已有 `/etc/ssh/sshd_config`。请先保持一个已有 root session，不要在验证前关闭当前 SSH 会话。安装脚本会自动备份 PAM 文件，但错误 SSH/PAM 配置仍可能影响后续 SSH 登录。

## 安装

交互安装并配置：

```bash
sudo ./ssh-auth-notify-manager.sh install
```

如果已有配置不存在或不完整，安装过程会提示选择 Telegram 或 Bark 并写入最小必要配置。已有完整配置会被保留；需要重新配置时执行：

```bash
sudo ./ssh-auth-notify-manager.sh configure
```

或安装时直接写入最小配置：

```bash
sudo ./ssh-auth-notify-manager.sh install \
  --backends telegram \
  --telegram-bot-token 'TOKEN' \
  --telegram-chat-id 'CHAT_ID'
```

安装会检查依赖，安装脚本到 `/opt/ssh-auth-notify/scripts`，配置文件到 `/etc/ssh-auth-notify/env`，向 `/etc/pam.d/sshd` 插入带 marker 的 PAM block，并新增 `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf` 写入 `UsePAM yes`。无参数安装会在配置缺失或不完整时进入交互配置；非交互环境请使用 `--backends ...` 参数。

如果 `/etc/ssh/sshd_config` 没有启用 `Include /etc/ssh/sshd_config.d/*.conf`，这个 drop-in 不会生效；脚本只提示，不会自动修改已有 `sshd_config`。安装脚本会在写入配置后自动校验并 reload sshd。如果 reload 失败，会打印警告和手动命令。

## 配置

配置文件权限为 `0600`：

```bash
sudoedit /etc/ssh-auth-notify/env
```

Telegram 示例：

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

Bark 示例：

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

多后端示例：

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

`SSH_AUTH_NOTIFY_BACKEND` 是兼容旧版本的字段；新配置优先使用 `SSH_AUTH_NOTIFY_BACKENDS`。

`SSH_AUTH_NOTIFY_ONLY_USERS` 非空时只通知这些逗号分隔用户。`SSH_AUTH_NOTIFY_SKIP_USERS` 命中时跳过通知。

## 非持久化测试

测试模式不会写入 `/opt/ssh-auth-notify`，不会写入 `/etc/ssh-auth-notify`，不会修改 `/etc/pam.d/sshd`。

```bash
./ssh-auth-notify-manager.sh test \
  --backends telegram \
  --telegram-bot-token 'TOKEN' \
  --telegram-chat-id 'CHAT_ID' \
  --user demo \
  --rhost 1.2.3.4
```

```bash
./ssh-auth-notify-manager.sh test \
  --backends bark \
  --bark-url 'https://api.day.app/KEY' \
  --user demo \
  --rhost 1.2.3.4
```

多后端：

```bash
./ssh-auth-notify-manager.sh test \
  --backends telegram,bark \
  --telegram-bot-token 'TOKEN' \
  --telegram-chat-id 'CHAT_ID' \
  --bark-url 'https://api.day.app/KEY' \
  --user demo \
  --rhost 1.2.3.4
```

## 状态和卸载

```bash
sudo ./ssh-auth-notify-manager.sh status
sudo ./ssh-auth-notify-manager.sh uninstall
```

卸载会删除本项目 PAM marker block、删除 `/etc/ssh/sshd_config.d/99-ssh-auth-notify.conf`、删除 `/opt/ssh-auth-notify` 和 `/etc/ssh-auth-notify`。默认保留 PAM 备份；如需删除本项目备份：

```bash
sudo ./ssh-auth-notify-manager.sh uninstall --purge-backups
```

## 本地验收

一条命令执行基础检查：

```bash
bash -c 'set -e; files="ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send"; for f in $files; do bash -n "$f"; done; if command -v shellcheck >/dev/null 2>&1; then shellcheck $files; else echo "shellcheck not found; skipped"; fi'
```

```bash
bash -n ssh-auth-notify-manager.sh
bash -n scripts/ssh-auth-notify-wrapper
bash -n scripts/ssh-auth-notify-worker
bash -n scripts/ssh-auth-notify-send
command -v shellcheck >/dev/null && shellcheck ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send
```
