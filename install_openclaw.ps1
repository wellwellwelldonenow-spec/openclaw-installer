[CmdletBinding()]
param(
    [string]$ApiKey = $env:NEWAPI_API_KEY,
    [string]$ModelId = $env:OPENCLAW_MODEL_ID,
    [int]$GatewayPort = $(if ($env:OPENCLAW_PORT) { [int]$env:OPENCLAW_PORT } else { 18789 }),
    [switch]$SkipUpstreamCheck
)

$ErrorActionPreference = 'Stop'
$ProviderId = 'megabyai'
$BaseUrl = 'https://newapi.megabyai.cc/v1'
$DefaultModelId = 'gpt-5.3-codex'

function Write-Info($Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg($Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Throw-Fail($Message) {
    throw "[ERROR] $Message"
}

function Test-Command($Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = @($machine, $user) -join ';'
    if (-not [string]::IsNullOrWhiteSpace($combined)) {
        $env:Path = $combined
    }
}

function Get-NodeMajorVersion {
    if (-not (Test-Command 'node')) {
        return $null
    }

    $major = (& node -p "process.versions.node.split('.')[0]" 2>$null | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($major)) {
        return $null
    }

    return [int]$major
}

function Ensure-Node {
    $major = Get-NodeMajorVersion
    if ($major -ge 22) {
        Write-Info "已检测到 Node.js $(node -v)"
        return
    }

    if ($major) {
        Write-WarnMsg "当前 Node.js 版本过低：$(node -v)，将升级到 22+"
    } else {
        Write-WarnMsg '未检测到 Node.js，将自动安装 22+'
    }

    if (Test-Command 'winget') {
        Write-Info '使用 winget 安装 Node.js'
        winget install --exact --id OpenJS.NodeJS --accept-source-agreements --accept-package-agreements | Out-Null
    } elseif (Test-Command 'choco') {
        Write-Info '使用 Chocolatey 安装 Node.js'
        choco install nodejs -y | Out-Null
    } else {
        Throw-Fail '未找到 winget 或 choco，无法自动安装 Node.js。请先安装 Node.js 22+。'
    }

    Refresh-Path
    $major = Get-NodeMajorVersion
    if ($major -lt 22) {
        Throw-Fail "Node.js 安装后版本仍低于 22：$(node -v)"
    }

    Write-Info "Node.js 已就绪：$(node -v)"
}

function Get-InstalledOpenClawVersion {
    if (-not (Test-Command 'openclaw')) {
        return ''
    }

    return ((& openclaw --version 2>$null) | Select-Object -Last 1).Trim()
}

function Get-LatestOpenClawVersion {
    if (-not (Test-Command 'npm')) {
        return ''
    }

    return ((& npm view openclaw version --silent 2>$null) | Select-Object -Last 1).Trim()
}

function Ensure-OpenClaw {
    Write-Info '安装 OpenClaw'
    Refresh-Path

    $installedVersion = Get-InstalledOpenClawVersion
    $latestVersion = Get-LatestOpenClawVersion

    if ($installedVersion -and $latestVersion -and $installedVersion -eq $latestVersion) {
        Write-Info "检测到已安装最新版 OpenClaw：$installedVersion，跳过安装"
        return
    }

    if ($installedVersion -and $latestVersion) {
        Write-Info "检测到本地 OpenClaw：$installedVersion，npm 最新版：$latestVersion，将执行升级"
    } elseif ($installedVersion) {
        Write-WarnMsg "已安装 OpenClaw：$installedVersion，但未能确认 npm 最新版本，将尝试升级"
    } else {
        Write-Info '未检测到 OpenClaw，将执行安装'
    }

    & npm install -g openclaw@latest
    Refresh-Path

    if (-not (Test-Command 'openclaw')) {
        Throw-Fail 'OpenClaw 安装后未找到命令'
    }

    Write-Info "OpenClaw 版本：$(((& openclaw --version) | Select-Object -Last 1).Trim())"
}

function Prompt-ApiKey {
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        $script:ApiKey = Read-Host '请输入 NewAPI API Key'
    }

    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        Throw-Fail 'API Key 不能为空'
    }

    $env:NEWAPI_API_KEY = $script:ApiKey
}

function Prompt-Model {
    if (-not [string]::IsNullOrWhiteSpace($script:ModelId)) {
        Write-Info "使用环境变量指定模型：$script:ModelId"
        return
    }

    $inputModel = Read-Host "请输入模型 ID（默认 $DefaultModelId）"
    if ([string]::IsNullOrWhiteSpace($inputModel)) {
        $script:ModelId = $DefaultModelId
    } else {
        $script:ModelId = $inputModel.Trim()
    }

    Write-Info "使用模型：$script:ModelId"
}

function Test-PortListening([int]$Port) {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    }

    $output = netstat -ano | Select-String -Pattern ":$Port\s+.*LISTENING"
    return $null -ne $output
}

function Choose-GatewayPort {
    $candidate = $GatewayPort
    $maxPort = $GatewayPort + 20

    while ($candidate -le $maxPort) {
        if (Test-PortListening $candidate) {
            Write-WarnMsg "端口 $candidate 已被占用，尝试下一个端口"
            $candidate++
            continue
        }

        $script:GatewayPort = $candidate
        $env:OPENCLAW_PORT = [string]$candidate
        Write-Info "将使用网关端口：$candidate"
        return
    }

    Throw-Fail '未找到可用网关端口，请手动设置 OPENCLAW_PORT'
}

function Write-ServiceEnv {
    param(
        [string]$ConfigPath = (Join-Path $HOME '.openclaw\openclaw.json')
    )

    $configHome = Join-Path $HOME '.openclaw'
    $envFile = Join-Path $configHome '.env'
    New-Item -ItemType Directory -Path $configHome -Force | Out-Null

    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Split-Path -Parent (Get-Command node).Source),
        'C:\Program Files\nodejs',
        'C:\Program Files (x86)\nodejs',
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        foreach ($part in ($candidate -split ';')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            if (-not $pathEntries.Contains($part)) {
                $pathEntries.Add($part)
            }
        }
    }

    $stateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { $configHome }

    @(
        "PATH=$($pathEntries -join ';')",
        "OPENCLAW_PORT=$GatewayPort",
        "OPENCLAW_GATEWAY_PORT=$GatewayPort",
        "OPENCLAW_CONFIG_PATH=$ConfigPath",
        "OPENCLAW_STATE_DIR=$stateDir"
    ) | Set-Content -Path $envFile -Encoding UTF8

    Write-Info "已写入服务环境文件：$envFile"
}

function Test-UpstreamWithPowerShell {
    try {
        $params = @{
            Uri = "$BaseUrl/models"
            Headers = @{ Authorization = "Bearer $ApiKey" }
            TimeoutSec = 30
        }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $params.UseBasicParsing = $true
        }
        $response = Invoke-WebRequest @params
        return $response.StatusCode -eq 200
    } catch {
        Write-WarnMsg "PowerShell 校验失败：$($_.Exception.Message)"
        return $false
    }
}

function Test-UpstreamWithNode {
    $script = @"
const url = process.argv[1];
const apiKey = process.argv[2];
(async () => {
  try {
    const response = await fetch(url, { headers: { Authorization: `Bearer ${apiKey}` } });
    process.exit(response.status === 200 ? 0 : 1);
  } catch (error) {
    console.error(String(error && error.stack ? error.stack : error));
    process.exit(1);
  }
})();
"@
    & node -e $script "$BaseUrl/models" "$ApiKey"
    return $LASTEXITCODE -eq 0
}

function Verify-UpstreamApi {
    Write-Info '验证上游 NewAPI 接口'

    if ($SkipUpstreamCheck) {
        Write-WarnMsg '已跳过上游接口校验（-SkipUpstreamCheck）'
        return
    }

    if (Test-UpstreamWithPowerShell) {
        return
    }

    Write-WarnMsg 'PowerShell 探测失败，改用 Node.js TLS 栈重试'
    if (Test-UpstreamWithNode) {
        return
    }

    Throw-Fail 'API Key 无效、上游接口不可用，或本机网络/TLS 连接存在问题'
}

function Test-GatewayHealth {
    try {
        & openclaw gateway health *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    } catch {}

    $statusOutput = ''
    try {
        $statusOutput = (& openclaw gateway status --deep 2>&1 | Out-String)
    } catch {
        $statusOutput = ($_ | Out-String)
    }

    return $statusOutput -match 'RPC probe:\s+ok'
}

function Invoke-GatewayForegroundProbe {
    $probeLog = Join-Path $env:TEMP 'openclaw-gateway-foreground.log'
    Write-WarnMsg '后台服务仍未就绪，尝试前台启动一次以抓取首个报错'

    if (Test-Path $probeLog) {
        Remove-Item $probeLog -Force -ErrorAction SilentlyContinue
    }

    $job = Start-Job -ScriptBlock {
        param($Port, $ProbeLog)
        & openclaw gateway run --port $Port --bind loopback --verbose *> $ProbeLog
    } -ArgumentList $GatewayPort, $probeLog

    Start-Sleep -Seconds 12
    if ($job.State -eq 'Running') {
        Stop-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null

    if (Test-Path $probeLog) {
        Get-Content -Path $probeLog -TotalCount 160 | Out-Host
    }
}

function Show-GatewayDiagnostics {
    Write-WarnMsg '开始采集网关诊断信息'

    try { & openclaw config get gateway.mode } catch {}
    try { & openclaw config get gateway.bind } catch {}
    try { & openclaw config get gateway.port } catch {}
    try { & openclaw gateway status --deep } catch { try { & openclaw gateway status } catch {} }
    try { & openclaw status --all } catch {}
    try { & openclaw logs --limit 200 --plain } catch {}

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue
        if (-not $listener) {
            Invoke-GatewayForegroundProbe
        }
    }
}

function Repair-GatewayService {
    Write-WarnMsg '网关健康检查失败，尝试执行 openclaw doctor --fix 修复服务'
    try { & openclaw doctor --fix } catch { try { & openclaw doctor --yes } catch {} }
    & openclaw gateway install --runtime node --port $GatewayPort --force
    try {
        & openclaw gateway restart
    } catch {
        & openclaw gateway start
    }
    Start-Sleep -Seconds 3
}

function Install-AndStartGateway {
    Write-Info '安装并启动网关'
    & openclaw gateway install --runtime node --port $GatewayPort --force
    try {
        & openclaw gateway restart
    } catch {
        & openclaw gateway start
    }
    Start-Sleep -Seconds 3

    if (-not (Test-GatewayHealth)) {
        Repair-GatewayService
    }

    if (-not (Test-GatewayHealth)) {
        Show-GatewayDiagnostics
        Throw-Fail '网关仍未就绪，请优先执行 openclaw gateway status --deep 和 openclaw logs --follow'
    }

    try { & openclaw gateway status } catch {}
}

function Get-ConfigPath {
    try {
        $lines = & openclaw config file 2>$null
        $last = ($lines | Select-Object -Last 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($last)) {
            return $last
        }
    } catch {}

    return (Join-Path $HOME '.openclaw\openclaw.json')
}

function Ensure-OpenClawBootstrap {
    $configHome = Join-Path $HOME '.openclaw'
    $hasConfig = (Test-Path $configHome) -and ((Get-ChildItem -Path $configHome -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

    if ($hasConfig) {
        Write-Info '检测到已有 OpenClaw 配置，跳过 onboard'
    } else {
        Write-Info '无交互初始化 OpenClaw'
        try {
            & openclaw onboard --non-interactive --mode local --auth-choice custom-api-key --custom-provider-id $ProviderId --custom-compatibility openai --custom-base-url $BaseUrl --custom-model-id $ModelId --custom-api-key $ApiKey --gateway-port $GatewayPort --gateway-bind loopback --skip-skills
        } catch {
            Write-WarnMsg '无交互 onboard 失败，回退到最小初始化流程'
            New-Item -ItemType Directory -Path $configHome -Force | Out-Null
        }
    }
}

function Write-OpenClawConfig {
    $configPath = Get-ConfigPath
    $configDir = Split-Path -Parent $configPath
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak.$([DateTimeOffset]::Now.ToUnixTimeSeconds())" -Force
    }

    Write-Info "写入 OpenClaw 配置：$configPath"

    $nodeScript = @"
const fs = require('fs');
const [configPath, apiKey, baseUrl, providerId, modelId, modelName, gatewayPort] = process.argv.slice(1);
let config = {};
if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) config = JSON.parse(raw);
}
config.models = config.models || {};
config.models.mode = 'merge';
config.models.providers = config.models.providers || {};
const existingProvider = config.models.providers[providerId] || {};
config.models.providers[providerId] = {
  ...existingProvider,
  baseUrl,
  apiKey,
  api: 'openai-completions',
  models: [{ id: modelId, name: modelName, input: ['text'], contextWindow: 64000, maxTokens: 4096 }],
};
config.gateway = config.gateway || {};
config.gateway.mode = 'local';
config.gateway.bind = 'loopback';
config.gateway.port = Number(gatewayPort);
config.gateway.reload = config.gateway.reload || {};
config.gateway.reload.mode = config.gateway.reload.mode || 'hybrid';
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.agents.defaults.model.primary = `${providerId}/${modelId}`;
config.agents.defaults.models = config.agents.defaults.models || {};
config.agents.defaults.models[`${providerId}/${modelId}`] = {
  ...(config.agents.defaults.models[`${providerId}/${modelId}`] || {}),
};
config.agents.defaults.memorySearch = config.agents.defaults.memorySearch || {};
if (typeof config.agents.defaults.memorySearch.provider === 'undefined' && typeof config.agents.defaults.memorySearch.enabled === 'undefined') {
  config.agents.defaults.memorySearch.enabled = false;
  config.agents.defaults.memorySearch.fallback = 'none';
}
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
"@

    & node -e $nodeScript $configPath $ApiKey $BaseUrl $ProviderId $ModelId "$ModelId (newapi)" $GatewayPort
}

function Validate-OpenClaw {
    Write-Info '校验 OpenClaw 配置'
    & openclaw config validate
}

function Probe-Provider {
    Write-Info '探测模型可用性'
    try {
        & openclaw models status --probe --probe-provider $ProviderId --json
    } catch {
        Write-WarnMsg '模型探测失败，请检查网络、API Key 或上游模型权限'
    }
}

if (-not ($PSVersionTable -and ($env:OS -eq 'Windows_NT'))) {
    Throw-Fail '当前脚本面向 Windows PowerShell / PowerShell on Windows。macOS/Linux/WSL2 请使用 install_openclaw.sh。'
}

Prompt-ApiKey
Prompt-Model
Ensure-Node
Choose-GatewayPort
Ensure-OpenClaw
Ensure-OpenClawBootstrap
$configPath = Get-ConfigPath
Write-ServiceEnv -ConfigPath $configPath
Verify-UpstreamApi
Write-OpenClawConfig
Validate-OpenClaw
Install-AndStartGateway
Probe-Provider

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host "- OpenClaw 已安装并初始化"
Write-Host "- 网关端口：$GatewayPort"
Write-Host "- Provider：$ProviderId"
Write-Host "- Model：$ModelId"
Write-Host ''
Write-Host '可继续手动测试：'
Write-Host '  openclaw gateway status --deep'
Write-Host '  openclaw logs --follow'
