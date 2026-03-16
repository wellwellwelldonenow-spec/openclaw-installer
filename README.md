# openclaw-installer

一键安装和配置 OpenClaw 的脚本，支持：

- `macOS / Linux / WSL2`：`install_openclaw.sh`
- `Windows PowerShell`：`install_openclaw.ps1`

## 功能

- 自动检测并安装 Node.js 22+
- Linux/macOS 后台服务强制优先使用系统 Node，不使用 `nvm/fnm/asdf/volta` 的运行时
- 自动检测 `openclaw` 是否已是 npm 最新版，是则跳过重装
- 自动安装或升级 `openclaw`
- 不运行 `OpenClaw onboard`，直接写入配置并启动 Gateway
- Windows 安装前自动自检 `node/npm` 路径、系统架构和杀毒软件环境
- 自动写入 `gateway.mode=local`、`gateway.bind=loopback`、`gateway.port`
- 运行时可输入自定义模型 ID，不输入则默认 `gpt-5.3-codex`
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 自动设置默认模型为 `megabyai/<你的模型ID>`
- 自动写入 `OPENCLAW_GATEWAY_PORT`、`OPENCLAW_CONFIG_PATH`、`OPENCLAW_STATE_DIR` 到服务环境
- 默认启用 `browser` tool，并默认使用 `openai-responses`
- Linux 在启用 `browser` tool 时会自动补装 Chrome/Chromium
- Linux 安装时会自动检测 browser 运行环境；若是 `root` 或无图形显示，会自动写入 `browser.noSandbox=true` / `browser.headless=true`
- 安装完成后会执行一次 `openclaw browser start` 自检；若命中 `Running as root without --no-sandbox` 或 `Missing X server or $DISPLAY`，会自动修复配置并重启 Gateway
- Linux 在未提供 `NEWAPI_API_KEY` 时，会优先尝试用当前机器 IP 作为用户名/密码自动申请 NewAPI token
- Linux 的飞书脚本默认会先启动一个临时网页授权页，要求输入访问密钥 `megaaifeishu` 后才能生成飞书授权链接；授权成功后脚本自动继续，网页可关闭
- 如需切回 `openai-completions`，可通过 `OPENCLAW_PROVIDER_API` 手动覆盖
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
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 | iex
```

如果用户访问 GitHub 需要显式套代理，可改用：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser; $env:OPENCLAW_PROXY_URL='http://YOUR_PROXY_HOST:PORT'; $env:HTTP_PROXY=$env:OPENCLAW_PROXY_URL; $env:HTTPS_PROXY=$env:OPENCLAW_PROXY_URL; $env:ALL_PROXY=$env:OPENCLAW_PROXY_URL; $script = Join-Path $env:TEMP 'install_openclaw.ps1'; iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script; powershell -NoProfile -ExecutionPolicy Bypass -File $script -ProxyUrl $env:OPENCLAW_PROXY_URL
```

适用于：

- `Windows PowerShell`
- `PowerShell 7` on Windows

脚本会自动使用新的 Windows 专用流程：

- 优先调用官方安装脚本：`iwr -useb https://openclaw.ai/install.ps1 | iex`
- 如果官方脚本失败，再回退到：`npm install -g openclaw@latest`
- 不进入新手引导，直接写入第三方 API 和 Gateway 配置
- 写入 `%USERPROFILE%\.openclaw\.env`
- 安装/升级 `openclaw`
- 自动检查 `node/npm` 环境，遇到 `3221225477` 时提示排查杀毒软件和 Node 损坏
- 检测到 `node/npm` 崩溃时自动清理 npm 缓存、旧的 OpenClaw shim 并重试一次
- 若清理后仍异常，自动通过 `winget` 或 `Chocolatey` 重装 Node.js 环境
- 自动打印 `node/npm` 路径、关键环境变量、`APPDATA/TEMP` 可写性等诊断摘要
- 初始化并修复 Gateway

### 方法一：使用官方安装脚本（推荐）

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
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

如果机器已经装过 OpenClaw，但 `browser` 用不了，不想整套重装，可以直接运行单独修复脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/repair_openclaw_browser.sh -o /tmp/repair_openclaw_browser.sh && bash /tmp/repair_openclaw_browser.sh
```

这个脚本会：

- 自动检测并安装 Chrome/Chromium（Linux）
- 自动修复 `browser.noSandbox=true`（root 环境）
- 自动修复 `browser.headless=true`（无 `DISPLAY/WAYLAND_DISPLAY` 环境）
- 自动重启 Gateway，并执行一次 `openclaw browser start` 自检

如果你希望 Linux 脚本自动创建 NewAPI 用户并获取 token，请在执行前提供管理 Key：

```bash
export OPENCLAW_NEWAPI_ADMIN_KEY='YOUR_FIXED_ADMIN_KEY'
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh
```

自动申请规则：

- 用户名默认使用当前机器的主 IPv4
- 密码默认使用当前机器的主 IPv4
- `display_name` 默认使用当前机器的主 IPv4
- 如自动申请失败，会自动回退到原来的手动输入 `NewAPI API Key` 流程

如果用户访问 GitHub 需要显式套代理，可改用：

```bash
OPENCLAW_PROXY_URL='http://YOUR_PROXY_HOST:PORT' HTTP_PROXY='http://YOUR_PROXY_HOST:PORT' HTTPS_PROXY='http://YOUR_PROXY_HOST:PORT' ALL_PROXY='http://YOUR_PROXY_HOST:PORT' sh -c 'curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh --proxy "$OPENCLAW_PROXY_URL"'
```

## macOS / Windows 控制台应用

仓库内置了一个本地控制台界面，适合 macOS / Windows：

- 安装前输入 API Key、模型 ID，并先做上游可用性检测
- 安装时可直接套本地代理，或读取 `vless://` 节点并临时拉起代理内核
- 安装完成后代理自动关闭
- 应用内临时代理默认启用白名单规则，只允许 GitHub 和安装链路必需域名
- 提供 `openclaw dashboard`、`gateway status --deep`、`doctor --fix`、`channels list` 等常用按钮
- 提供卸载 OpenClaw 按钮，直接调用仓库现有卸载脚本
- 提供飞书官方插件配置入口，也可配置 Telegram / Discord / Slack 等频道

启动方式：

```bash
npm install
npm run control-app
```

说明：

- 控制台应用默认监听 `http://127.0.0.1:3218/`
- 如需让应用直接接管 `vless://`，请把 `sing-box` 或 `xray` 二进制放到 `app/bin/` 下
- Linux 继续推荐直接跑 `install_openclaw.sh`；脚本现在会在需要时自动安装 Chrome/Chromium

桌面应用方式：

```bash
npm install
npm run desktop
```

打包当前系统桌面应用：

```bash
npm install
npm run dist
```

按平台单独打包：

```bash
npm install
npm run build:mac
npm run build:win
```

当前本地已验证可产出 macOS 包：`dist/OpenClaw Control-0.1.0-arm64-mac.zip`

桌面包形态：

- macOS：`.dmg` 和 `.zip`
- Windows：安装版 `nsis` 和免安装 `portable`

macOS 下载注意：

- Apple Silicon Mac 下载 `arm64` 版本
- Intel Mac 下载 `x64` 版本
- 当前桌面包最低要求 macOS 11

如果你要让用户“下载就能直接使用”，推荐从仓库的 Releases 页面分发：

- 给仓库打一个 `v*` 版本 tag
- GitHub Actions 会自动构建桌面应用
- 构建完成后会把 `.dmg`、`.zip`、`.exe` 上传到 Release Assets

macOS 如果要彻底消除“Apple 无法验证”提示，还需要在仓库 Secrets 中配置：

- `APPLE_SIGNING_CERT_BASE64`
- `APPLE_SIGNING_CERT_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

说明：

- `APPLE_SIGNING_CERT_BASE64` 是 `.p12` 开发者证书的 Base64 文本
- `APPLE_SIGNING_CERT_PASSWORD` 是该 `.p12` 的导出密码
- `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID` 用于 notarize
- 未配置这些 Secrets 时，macOS 安装包仍会构建，但不会完成正式签名和 notarize

## One-Click Channel Setup

- macOS / Linux / WSL2:

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/channel_setup.sh -o /tmp/channel_setup.sh && bash /tmp/channel_setup.sh
bash /tmp/channel_setup.sh telegram --token "YOUR_BOT_TOKEN" --user-id "YOUR_CHAT_ID" --test
```

- Windows PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
$script = Join-Path $env:TEMP 'channel_setup.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/channel_setup.ps1 -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel telegram -Token "YOUR_BOT_TOKEN" -UserId "YOUR_CHAT_ID" -Test
```

Supported channels:

- `telegram`
- `discord`
- `slack`
- `feishu`
- `whatsapp`
- `wechat`
- `imessage` (macOS only)

Examples:

```bash
bash /tmp/channel_setup.sh discord --token "YOUR_BOT_TOKEN" --channel-id "YOUR_CHANNEL_ID" --test
bash /tmp/channel_setup.sh slack --bot-token "YOUR_XOXB_TOKEN" --app-token "YOUR_XAPP_TOKEN" --test
bash /tmp/channel_setup.sh feishu --guide-mode manual --app-id "YOUR_APP_ID" --app-secret "YOUR_APP_SECRET" --test
bash /tmp/channel_setup.sh feishu --app-id "YOUR_APP_ID" --app-secret "YOUR_APP_SECRET" --feishu-web-auth-secret "megaaifeishu" --test
bash /tmp/channel_setup.sh whatsapp
```

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel discord -Token "YOUR_BOT_TOKEN" -ChannelId "YOUR_CHANNEL_ID" -Test
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel slack -BotToken "YOUR_XOXB_TOKEN" -AppToken "YOUR_XAPP_TOKEN" -Test
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel feishu -GuideMode manual -AppId "YOUR_APP_ID" -AppSecret "YOUR_APP_SECRET" -Test
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel whatsapp
```

The channel setup scripts try to:

- enable the required plugin
- repair `plugins.allow`, `plugins.entries`, and default channel policy in the config file
- configure the channel with `openclaw` CLI
- optionally restart the gateway and run a basic credential test
- enter a Chinese interactive menu automatically when run without arguments
- for Feishu, prefer the bundled official `@openclaw/feishu` plugin and fall back to installing the official package only when the bundled plugin is unavailable
- for Feishu, guide app creation, bot capability, permission batch import, long-connection (`WebSocket`) event setup, and app publishing in the official console flow
- for Feishu, the operator guidance follows the official plugin doc: `https://bytedance.larkoffice.com/docx/MFK7dDFLFoVlOGxWCv5cTXKmnMh`
- for Feishu on Linux, start a temporary web page before `openclaw channels add --channel feishu`; after entering the access key `megaaifeishu`, the operator can click a button to generate a Feishu auth link, complete OAuth, then let the script continue automatically
- for Feishu on Linux, the temporary page defaults to port `38459`; use `--feishu-web-auth-public-base-url` when the host is behind NAT/reverse proxy, or `--no-feishu-web-auth` to skip this step

Use `openclaw channels list` and `openclaw gateway status --deep` after setup to verify the result.

## 卸载

- macOS / Linux / WSL2：

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh --uninstall
```

- Windows PowerShell：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script -Uninstall
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
- 默认启用 `browser` tool；安装脚本默认使用 `openai-responses`

## Windows / WSL2 说明

- 原生 Windows PowerShell 推荐顺序：官方 `install.ps1` -> `npm install -g openclaw@latest`
- 如果你更偏向 Linux 体验，推荐 `WSL2 Ubuntu`
- 在 `WSL2` 中如果你只安装 OpenClaw，可直接运行：`curl -fsSL https://openclaw.ai/install.sh | bash`
- 在 `WSL2` 中如果你还需要本仓库自动写入第三方 API 配置，继续使用 `install_openclaw.sh`
- 本仓库脚本不会进入 `openclaw onboard` 新手引导，而是直接生成配置并启动服务
- Windows 宿主机访问 WSL2 Gateway 时，优先尝试：`http://localhost:18789/`

### 方法三：使用 WSL2（强烈推荐）

1. 安装 `WSL2 Ubuntu`

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
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
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Get-NetTCPConnection -LocalPort 18789 -State Listen
```

常见日志位置：

- macOS / Linux: `/tmp/openclaw/openclaw-gateway.log`
- Windows: `%USERPROFILE%\.openclaw\logs\`

## 可选开关

- 强制指定 provider API adapter：

```bash
OPENCLAW_PROVIDER_API=openai-responses bash /tmp/install_openclaw.sh
OPENCLAW_PROVIDER_API=openai-completions bash /tmp/install_openclaw.sh
```

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
$env:OPENCLAW_PROVIDER_API = 'openai-responses'
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script
```

- 禁用 `browser` tool：

```bash
OPENCLAW_ENABLE_BROWSER_TOOL=0 bash /tmp/install_openclaw.sh
```

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
$env:OPENCLAW_ENABLE_BROWSER_TOOL = '0'
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script
```

- `bash` 版跳过基础上游连通性校验：

```bash
OPENCLAW_SKIP_UPSTREAM_CHECK=1 bash /tmp/install_openclaw.sh
```

- `PowerShell` 版跳过基础上游连通性校验：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
$script = Join-Path $env:TEMP 'install_openclaw.ps1'
iwr -useb https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.ps1 -OutFile $script
powershell -NoProfile -ExecutionPolicy Bypass -File $script -SkipUpstreamCheck
```
