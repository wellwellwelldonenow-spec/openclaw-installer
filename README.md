# openclaw-installer

一键安装和配置 OpenClaw 的脚本，支持：

- `macOS / Linux / WSL2`：`install_openclaw.sh`
- `Windows PowerShell`：`install_openclaw.ps1`

## 功能

- 自动检测并安装 Node.js 22+
- 自动检测 `openclaw` 是否已是 npm 最新版，是则跳过重装
- 自动安装或升级 `openclaw`
- 自动以无交互方式完成 `OpenClaw onboard`
- 自动写入 `gateway.mode=local`、`gateway.bind=loopback`、`gateway.port`
- 运行时可输入自定义模型 ID，不输入则默认 `gpt-5.3-codex`
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 自动设置默认模型为 `megabyai/<你的模型ID>`
- 自动写入 `OPENCLAW_GATEWAY_PORT`、`OPENCLAW_CONFIG_PATH`、`OPENCLAW_STATE_DIR` 到服务环境
- 上游接口自动校验，优先使用系统请求栈，失败时自动回退到 `Node.js` TLS 栈
- 网关健康检查失败时自动执行 `openclaw doctor --fix` 并重装服务后重试
- 失败时自动输出 `gateway status --deep`、`status --all`、日志和一次前台启动诊断
- 检测端口占用，自动尝试切换到下一个可用端口

## Windows PowerShell 一键执行

```powershell
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 | iex
```

适用于：

- `Windows PowerShell`
- `PowerShell 7` on Windows

脚本会自动使用 Windows 专用流程：

- 优先尝试 `winget` 安装 Node.js
- 回退到 `choco` 安装 Node.js
- 写入 `%USERPROFILE%\.openclaw\.env`
- 安装/升级 `openclaw`
- 初始化并修复 Gateway

## macOS / Linux / WSL2 一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh
```

## macOS 说明

- 自动检测 `Xcode Command Line Tools`
- 自动安装 `Homebrew`，并固定使用 `Homebrew node@22`
- 需要系统级安装时会自动触发 `sudo` 验证
- 自动写入 `~/.openclaw/.env`，把 `PATH` 和 `OPENCLAW_PORT` 固定给后台服务
- 避免 `launchd` 因 `nvm`/shell PATH 导致网关无法拉起
- 默认在未配置 embedding provider 时关闭 `memorySearch`，避免无意义告警

## Windows / WSL2 说明

- 原生 Windows PowerShell 请使用 `install_openclaw.ps1`
- 如果你更偏向 Linux 体验，推荐 `WSL2 Ubuntu`
- 在 `WSL2` 中运行本仓库脚本时，流程与 Linux 一致
- Windows 宿主机访问 WSL2 Gateway 时，优先尝试：`http://localhost:18789/`

## 常见排查

```bash
openclaw gateway status --deep
openclaw logs --follow
openclaw doctor --fix
openclaw status --all
```

查看端口：

- macOS / Linux:

```bash
lsof -nP -iTCP:18789 -sTCP:LISTEN
```

- Windows PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 18789 -State Listen
```

常见日志位置：

- macOS / Linux: `/tmp/openclaw/openclaw-gateway.log`
- Windows: `%USERPROFILE%\.openclaw\logs\`

## 可选开关

- `bash` 版跳过上游接口探测：

```bash
OPENCLAW_SKIP_UPSTREAM_CHECK=1 bash /tmp/install_openclaw.sh
```

- `PowerShell` 版跳过上游接口探测：

```powershell
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
& $script -SkipUpstreamCheck
```
