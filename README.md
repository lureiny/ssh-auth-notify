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

安装会修改 `/etc/pam.d/sshd`。请先保持一个已有 root session，不要在验证前关闭当前 SSH 会话。安装脚本会自动备份 PAM 文件，但错误 PAM 配置仍可能影响后续 SSH 登录。

## 安装

交互配置：

```bash
sudo ./ssh-auth-notify-manager.sh install
sudo ./ssh-auth-notify-manager.sh configure
```

或安装时直接写入最小配置：

```bash
sudo ./ssh-auth-notify-manager.sh install \
  --backend telegram \
  --telegram-bot-token 'TOKEN' \
  --telegram-chat-id 'CHAT_ID'
```

安装会检查依赖，安装脚本到 `/opt/ssh-auth-notify/scripts`，配置文件到 `/etc/ssh-auth-notify/env`，并向 `/etc/pam.d/sshd` 插入带 marker 的 PAM block。

## 配置

配置文件权限为 `0600`：

```bash
sudoedit /etc/ssh-auth-notify/env
```

Telegram 示例：

```bash
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
SSH_AUTH_NOTIFY_BACKEND=bark
BARK_URL=https://api.day.app/your_key
SSH_AUTH_NOTIFY_TIMEOUT=5
SSH_AUTH_NOTIFY_HOST_ALIAS=
SSH_AUTH_NOTIFY_DEBUG=0
SSH_AUTH_NOTIFY_SKIP_USERS=
SSH_AUTH_NOTIFY_ONLY_USERS=
```

`SSH_AUTH_NOTIFY_ONLY_USERS` 非空时只通知这些逗号分隔用户。`SSH_AUTH_NOTIFY_SKIP_USERS` 命中时跳过通知。

## 非持久化测试

测试模式不会写入 `/opt/ssh-auth-notify`，不会写入 `/etc/ssh-auth-notify`，不会修改 `/etc/pam.d/sshd`。

```bash
./ssh-auth-notify-manager.sh test \
  --backend telegram \
  --telegram-bot-token 'TOKEN' \
  --telegram-chat-id 'CHAT_ID' \
  --user demo \
  --rhost 1.2.3.4
```

```bash
./ssh-auth-notify-manager.sh test \
  --backend bark \
  --bark-url 'https://api.day.app/KEY' \
  --user demo \
  --rhost 1.2.3.4
```

## 状态和卸载

```bash
sudo ./ssh-auth-notify-manager.sh status
sudo ./ssh-auth-notify-manager.sh uninstall
```

卸载会删除本项目 PAM marker block、`/opt/ssh-auth-notify` 和 `/etc/ssh-auth-notify`。默认保留 PAM 备份；如需删除本项目备份：

```bash
sudo ./ssh-auth-notify-manager.sh uninstall --purge-backups
```

## 本地验收

一条命令执行基础检查：

```bash
bash -c 'set -e; bash -n ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send; if command -v shellcheck >/dev/null 2>&1; then shellcheck ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send; else echo "shellcheck not found; skipped"; fi'
```

```bash
bash -n ssh-auth-notify-manager.sh
bash -n scripts/ssh-auth-notify-wrapper
bash -n scripts/ssh-auth-notify-worker
bash -n scripts/ssh-auth-notify-send
command -v shellcheck >/dev/null && shellcheck ssh-auth-notify-manager.sh scripts/ssh-auth-notify-wrapper scripts/ssh-auth-notify-worker scripts/ssh-auth-notify-send
```
