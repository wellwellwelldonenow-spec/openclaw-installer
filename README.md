# openclaw-installer

一键安装和配置 OpenClaw 的脚本，支持：

- `macOS / Linux / WSL2`：`install_openclaw.sh`
- `Windows PowerShell`：`install_openclaw.ps1`

## 功能

- 自动检测并安装 Node.js 22+
- Linux/macOS 后台服务强制优先使用系统 Node，不使用 `nvm/fnm/asdf/volta` 的运行时
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

## Windows 安装

本仓库的 Windows 安装逻辑只调整 `OpenClaw` 的安装方式，不改第三方 API、模型和 Gateway 配置写入逻辑。

脚本内部现在按以下顺序处理 Windows 原生安装：

1. 官方安装脚本（推荐）
2. npm 全局安装
3. WSL2 Ubuntu（强烈推荐，适合更稳定的本地 Gateway）

### 本仓库一键执行

```powershell
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 | iex
```

适用于：

- `Windows PowerShell`
- `PowerShell 7` on Windows

脚本会自动使用新的 Windows 专用流程：

- 优先调用官方安装脚本：`iwr -useb https://openclaw.ai/install.ps1 | iex`
- 如果官方脚本失败，再回退到：`npm install -g openclaw@latest`
- 写入 `%USERPROFILE%\.openclaw\.env`
- 安装/升级 `openclaw`
- 初始化并修复 Gateway

### 方法一：使用官方安装脚本（推荐）

```powershell
iwr -useb https://openclaw.ai/install.ps1 | iex
```

### 方法二：使用 npm 安装

```powershell
npm install -g openclaw@latest
```

## macOS / Linux / WSL2 一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh
```

## 卸载

- macOS / Linux / WSL2：

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh --uninstall
```

- Windows PowerShell：

```powershell
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
& $script -Uninstall
```

如果要做“纯净重装”，卸载后再删除用户态数据：

- macOS / Linux / WSL2：

```bash
rm -rf ~/.openclaw
```

- Windows PowerShell：

```powershell
Remove-Item -Recurse -Force "$HOME\.openclaw"
```

然后重新执行安装命令即可。

## macOS 说明

- 自动检测 `Xcode Command Line Tools`
- 自动安装 `Homebrew`，并固定使用 `Homebrew node@22`
- 需要系统级安装时会自动触发 `sudo` 验证
- 自动写入 `~/.openclaw/.env`，把 `PATH`、`OPENCLAW_PORT`、`OPENCLAW_CONFIG_PATH` 固定给后台服务
- 避免 `launchd` 因 `nvm`/shell PATH 导致网关无法拉起
- 默认在未配置 embedding provider 时关闭 `memorySearch`，避免无意义告警

## Windows / WSL2 说明

- 原生 Windows PowerShell 推荐顺序：官方 `install.ps1` -> `npm install -g openclaw@latest`
- 如果你更偏向 Linux 体验，推荐 `WSL2 Ubuntu`
- 在 `WSL2` 中如果你只安装 OpenClaw，可直接运行：`curl -fsSL https://openclaw.ai/install.sh | bash`
- 在 `WSL2` 中如果你还需要本仓库自动写入第三方 API 配置，继续使用 `install_openclaw.sh`
- Windows 宿主机访问 WSL2 Gateway 时，优先尝试：`http://localhost:18789/`

### 方法三：使用 WSL2（强烈推荐）

1. 安装 `WSL2 Ubuntu`

```powershell
wsl --install
```

重启电脑后完成 Ubuntu 初始化。

2. 在 `WSL2` 中安装 OpenClaw

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
curl -fsSL https://openclaw.ai/install.sh | bash
```

3. 启动 Gateway

```bash
openclaw gateway status
openclaw gateway --port 18789
openclaw gateway restart
```

4. 验证安装

```bash
openclaw status
openclaw health
```

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
