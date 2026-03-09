# openclaw-installer

一键安装和配置 OpenClaw 的脚本。

## 功能

- 自动检测系统类型与架构（macOS / Linux）
- 自动检测并安装 Node.js 22+
- macOS 自动检测 `Xcode Command Line Tools`
- macOS 自动安装 `Homebrew`，并固定使用 `Homebrew node@22`
- macOS 需要系统级安装时会自动触发 `sudo` 验证
- 避免 `launchd` 因 `nvm`/shell PATH 导致网关无法拉起
- 自动检测 `openclaw` 是否已是 npm 最新版，是则跳过重装
- 自动安装或升级 `openclaw`
- 自动以无交互方式完成 `OpenClaw onboard`
- 运行时可输入自定义模型 ID，不输入则默认 `gpt-5.3-codex`
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 自动设置默认模型为 `megabyai/<你的模型ID>`
- 上游接口自动校验，优先使用 `curl`，失败时自动回退到 `Node.js` TLS 栈
- 网关健康检查失败时自动执行 `openclaw doctor` 并重装服务后重试

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
- 如果 `curl` 因 `LibreSSL SSL_connect` 失败，脚本会自动改用 `Node.js` 发起上游探测
- 如果网关进程存在但端口未监听，脚本会自动执行 `openclaw doctor` 并重试一次

## 可选开关

- 跳过上游接口探测：

```bash
OPENCLAW_SKIP_UPSTREAM_CHECK=1 bash /tmp/install_openclaw.sh
```

适合网络环境特殊、但你确定 API Key 与 Base URL 正确时临时使用。
