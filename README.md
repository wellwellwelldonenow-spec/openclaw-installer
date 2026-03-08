# openclaw-installer

一键安装和配置 OpenClaw 的脚本。

## 功能

- 自动检测并安装 Node.js 22+
- 自动安装或升级 `openclaw`
- 自动初始化本地网关
- 自动写入 `https://newapi.megabyai.cc/v1` 的 OpenAI 兼容配置
- 启动并校验 OpenClaw 网关与模型探测

## 使用

```bash
chmod +x install_openclaw.sh
./install_openclaw.sh
```

脚本会在运行时提示输入 API Key，并自动完成剩余步骤。

也支持传参：

```bash
./install_openclaw.sh 'YOUR_API_KEY'
```

不建议把 API Key 直接写进命令历史。
