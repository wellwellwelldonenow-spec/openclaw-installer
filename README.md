# openclaw-installer

一键安装和配置 OpenClaw 的脚本。

## 功能

- 自动检测系统类型与架构（macOS / Linux）
- 自动检测并安装 Node.js 22+
- macOS 自动检测 `Xcode Command Line Tools`
- 缺失时自动触发 `xcode-select --install`
- 自动检测 `openclaw` 是否已是 npm 最新版，是则跳过重装
- 自动安装或升级 `openclaw`
- 自动以无交互方式完成 `OpenClaw onboard`
- 运行时可输入自定义模型 ID，不输入则默认 `gpt-5.3-codex`
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 自动设置默认模型为 `megabyai/<你的模型ID>`
- 上游接口自动校验，优先使用 `curl`，失败时自动回退到 `Node.js` TLS 栈
- 启动并校验 OpenClaw 网关与模型探测

## 直接一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/install_openclaw.sh -o /tmp/install_openclaw.sh && bash /tmp/install_openclaw.sh
```

脚本会在运行时：

- 先提示输入 API Key
- 再提示输入模型 ID
- 如果模型留空，则自动使用默认值 `gpt-5.3-codex`
- 如果本机 `openclaw` 已是最新版，则跳过重新安装

## 本地执行

```bash
chmod +x install_openclaw.sh
./install_openclaw.sh
```

也支持环境变量：

```bash
OPENCLAW_MODEL_ID='gpt-5.3-codex' ./install_openclaw.sh
```

也支持直接传 API Key：

```bash
./install_openclaw.sh 'YOUR_API_KEY'
```

不建议把 API Key 直接写进命令历史。

## macOS 说明

- 如果系统缺少 `Xcode Command Line Tools`，脚本会自动触发安装
- 你只需要按系统弹窗完成安装，然后重新运行脚本
- 如果本机已安装 Homebrew，脚本会优先尝试用 Homebrew 安装 Node.js 22
- 如果 `curl` 因 `LibreSSL SSL_connect` 失败，脚本会自动改用 `Node.js` 发起上游探测

## 可选开关

- 跳过上游接口探测：

```bash
OPENCLAW_SKIP_UPSTREAM_CHECK=1 bash /tmp/install_openclaw.sh
```

适合网络环境特殊、但你确定 API Key 与 Base URL 正确时临时使用。
