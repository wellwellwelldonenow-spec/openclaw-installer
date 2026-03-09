# openclaw-installer

一键安装和配置 OpenClaw 的脚本。

## 功能

- 自动检测系统类型与架构（macOS / Linux）
- 自动检测并安装 Node.js 22+
- macOS 自动检测 `Xcode Command Line Tools`
- macOS 自动安装 `Homebrew`，并固定使用 `Homebrew node@22`
- macOS 需要系统级安装时会自动触发 `sudo` 验证
- 自动写入 `~/.openclaw/.env`，把服务所需 `PATH` 固定下来
- 避免 `launchd` 因 `nvm`/shell PATH 导致网关无法拉起
- 自动检测 `openclaw` 是否已是 npm 最新版，是则跳过重装
- 自动安装或升级 `openclaw`
- 自动以无交互方式完成 `OpenClaw onboard`
- 运行时可输入自定义模型 ID，不输入则默认 `gpt-5.3-codex`
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 自动设置默认模型为 `megabyai/<你的模型ID>`
- 上游接口自动校验，优先使用 `curl`，失败时自动回退到 `Node.js` TLS 栈
- 网关健康检查失败时自动执行 `openclaw doctor` 并重装服务后重试
- 检测端口占用，自动尝试切换到下一个可用端口

## 直接一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh
```

脚本会在运行时：

- 先提示输入 API Key
- 再提示输入模型 ID
- 如果模型留空，则自动使用默认值 `gpt-5.3-codex`
- 如果本机 `openclaw` 已是最新版，则跳过重新安装

## macOS 说明

- 如果系统缺少 `Xcode Command Line Tools`，脚本会自动触发安装
- 如果本机缺少 `Homebrew`，脚本会自动安装 `Homebrew`
- 如果需要管理员权限，脚本会自动提示你输入一次 macOS 登录密码
- 脚本会优先使用 `Homebrew` 安装 `node@22`，避免 `launchd` 找不到 `nvm` 下的 Node
- 脚本会写入 `~/.openclaw/.env`，把 `PATH` 和 `OPENCLAW_PORT` 固定给后台服务
- 如果 `curl` 因 `LibreSSL SSL_connect` 失败，脚本会自动改用 `Node.js` 发起上游探测
- 如果网关进程存在但端口未监听，脚本会自动执行 `openclaw doctor` 并重试一次

## Windows / WSL2

- 这个仓库里的 `install_openclaw.sh` 主要面向 `macOS / Linux / WSL2`
- 如果你在原生 Windows PowerShell 环境，推荐优先使用官方安装方式：

```powershell
iwr -useb https://openclaw.ai/install.ps1 | iex
```

- 如果你想要最稳定的本地服务体验，推荐 `WSL2 Ubuntu`
- 在 `WSL2` 中运行本仓库脚本时，流程与 Linux 一致
- Windows 宿主机访问 WSL2 Gateway 时，优先尝试：`http://localhost:18789/`

## 常见排查

```bash
openclaw gateway status
openclaw logs --follow
openclaw doctor
openclaw status --all
```

查看端口：

```bash
lsof -nP -iTCP:18789 -sTCP:LISTEN
```

如果脚本最终仍提示网关未监听，它会自动打印最近的网关日志；常见日志位置：

- `/tmp/openclaw/openclaw-gateway.log`
- `~/.openclaw/logs/openclaw-gateway.log`

## 可选开关

跳过上游接口探测：

```bash
OPENCLAW_SKIP_UPSTREAM_CHECK=1 bash /tmp/install_openclaw.sh
```

适合网络环境特殊、但你确定 API Key 与 Base URL 正确时临时使用。
