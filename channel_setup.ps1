[CmdletBinding()]
param(
    [ValidateSet('telegram', 'discord', 'slack', 'feishu', 'whatsapp', 'wechat', 'imessage')]
    [string]$Channel,
    [string]$ConfigPath,
    [string]$Token,
    [string]$BotToken,
    [string]$AppToken,
    [string]$UserId,
    [string]$ChannelId,
    [string]$AppId,
    [string]$AppSecret,
    [string]$PluginId,
    [switch]$NoRestart,
    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Throw-Fail([string]$Message) {
    throw $Message
}

function Show-Usage {
    @'
Usage:
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel telegram -Token <bot-token> -UserId <chat-id> -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel discord -Token <bot-token> -ChannelId <channel-id> -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel slack -BotToken <xoxb-token> -AppToken <xapp-token> -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel feishu -AppId <app-id> -AppSecret <app-secret> -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel whatsapp
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel wechat -PluginId wechat
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel imessage

Supported channels:
  telegram, discord, slack, feishu, whatsapp, wechat, imessage

Options:
  -ConfigPath <path>   Override OpenClaw config path
  -NoRestart           Skip gateway restart
  -Test                Run a basic credential test when supported
'@ | Write-Host
}

function Resolve-CliShim {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,
        [string[]]$PreferredPaths = @()
    )

    foreach ($candidate in $PreferredPaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    foreach ($commandName in @("$BaseName.cmd", "$BaseName.exe", $BaseName)) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -eq $command) { continue }

        $source = $command.Source
        if ([string]::IsNullOrWhiteSpace($source)) { continue }

        if ($source.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $cmdShim = [System.IO.Path]::ChangeExtension($source, '.cmd')
            if (Test-Path $cmdShim) {
                return $cmdShim
            }
        }

        return $source
    }

    return $null
}

function Get-OpenClawCommand {
    return Resolve-CliShim -BaseName 'openclaw' -PreferredPaths @(
        'C:\Program Files\nodejs\openclaw.cmd',
        'C:\Program Files (x86)\nodejs\openclaw.cmd',
        (Join-Path $env:APPDATA 'npm\openclaw.cmd'),
        (Join-Path $HOME '.npm-global\openclaw.cmd')
    )
}

function Get-NodeCommand {
    return Resolve-CliShim -BaseName 'node' -PreferredPaths @(
        'C:\Program Files\nodejs\node.exe',
        'C:\Program Files (x86)\nodejs\node.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )
}

function Assert-OpenClawInstalled {
    $openclawCommand = Get-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openclawCommand)) {
        Throw-Fail 'openclaw.cmd not found; complete OpenClaw installation first.'
    }

    $nodeCommand = Get-NodeCommand
    if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
        Throw-Fail 'node.exe not found; OpenClaw channel setup needs Node.js.'
    }
}

function Invoke-NativeCommandSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $stdoutPath = Join-Path $env:TEMP ("openclaw-channel-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $stderrPath = Join-Path $env:TEMP ("openclaw-channel-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))

    try {
        $process = Start-Process -FilePath $Command -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $combined = @($stdout, $stderr) -join [Environment]::NewLine

        return @{
            ExitCode = $process.ExitCode
            Output = $combined.Trim()
        }
    }
    finally {
        Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenClaw {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $openclawCommand = Get-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openclawCommand)) {
        Throw-Fail 'openclaw.cmd not found; complete OpenClaw installation first.'
    }

    $result = Invoke-NativeCommandSafe -Command $openclawCommand -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $message = if ([string]::IsNullOrWhiteSpace($result.Output)) {
            "openclaw failed with exit code $($result.ExitCode)"
        }
        else {
            $result.Output
        }
        throw $message
    }

    return $result.Output
}

function Resolve-ConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ConfigPath)) {
        return $script:ConfigPath
    }

    try {
        $resolved = (Invoke-OpenClaw config file | Select-Object -Last 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            $script:ConfigPath = $resolved
            return $script:ConfigPath
        }
    }
    catch {}

    $script:ConfigPath = Join-Path $HOME '.openclaw\openclaw.json'
    return $script:ConfigPath
}

function Ensure-ConfigFile {
    $path = Resolve-ConfigPath
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (-not (Test-Path $path)) {
        '{}' | Set-Content -Path $path -Encoding UTF8
    }
}

function Mask-Value {
    param(
        [string]$Value,
        [int]$Prefix = 6,
        [int]$Suffix = 4
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    if ($Value.Length -le ($Prefix + $Suffix)) {
        return $Value
    }

    return '{0}...{1}' -f $Value.Substring(0, $Prefix), $Value.Substring($Value.Length - $Suffix)
}

function Prompt-Value {
    param(
        [string]$Prompt,
        [string]$Current,
        [switch]$Secret
    )

    if (-not [string]::IsNullOrWhiteSpace($Current)) {
        return $Current
    }

    if ($Secret) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        if ($null -eq $secure) {
            return ''
        }
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }

    return (Read-Host -Prompt $Prompt)
}

function Require-Value {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Throw-Fail "$Name is required."
    }
}

function Ensure-PluginEnabled {
    param([Parameter(Mandatory = $true)][string]$PluginName)

    try {
        Invoke-OpenClaw plugins enable $PluginName | Out-Null
    }
    catch {
        Write-WarnMsg "openclaw plugins enable $PluginName returned non-zero; continuing with config repair"
    }
}

function Ensure-PluginConfig {
    param(
        [Parameter(Mandatory = $true)][string]$PluginName,
        [string]$GroupPolicy = 'allowlist',
        [string]$DmPolicy = 'pairing'
    )

    Ensure-ConfigFile
    $path = Resolve-ConfigPath
    $nodeCommand = Get-NodeCommand
    if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
        Throw-Fail 'node.exe not found; OpenClaw channel setup needs Node.js.'
    }

    $scriptPath = Join-Path $env:TEMP ("openclaw-channel-config-{0}.js" -f ([guid]::NewGuid().ToString('N')))
    @'
const fs = require('fs');

const [configPath, pluginName, groupPolicy, dmPolicy] = process.argv.slice(2);
let config = {};

if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) {
    config = JSON.parse(raw);
  }
}

config.plugins = config.plugins || {};
config.plugins.allow = Array.isArray(config.plugins.allow) ? config.plugins.allow : [];
config.plugins.entries = config.plugins.entries && typeof config.plugins.entries === 'object' ? config.plugins.entries : {};
config.channels = config.channels && typeof config.channels === 'object' ? config.channels : {};

if (!config.plugins.allow.includes(pluginName)) {
  config.plugins.allow.push(pluginName);
}

config.plugins.entries[pluginName] = Object.assign({}, config.plugins.entries[pluginName] || {}, { enabled: true });
config.channels[pluginName] = Object.assign({ dmPolicy, groupPolicy }, config.channels[pluginName] || {});

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
'@ | Set-Content -Path $scriptPath -Encoding UTF8

    try {
        $result = Invoke-NativeCommandSafe -Command $nodeCommand -Arguments @($scriptPath, $path, $PluginName, $GroupPolicy, $DmPolicy)
        if ($result.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($result.Output)) {
                Throw-Fail "node failed with exit code $($result.ExitCode) while repairing plugin config."
            }
            Throw-Fail $result.Output
        }
    }
    finally {
        Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Restart-Gateway {
    if ($NoRestart) {
        Write-Info 'Gateway restart skipped'
        return
    }

    Write-Info 'Restarting OpenClaw gateway'
    try {
        Invoke-OpenClaw gateway restart | Out-Null
    }
    catch {
        try {
            Invoke-OpenClaw gateway start | Out-Null
        }
        catch {
            Write-WarnMsg "Gateway restart/start failed. Run 'openclaw gateway status --deep' manually."
        }
    }
}

function Test-TelegramChannel {
    if (-not $Test) { return }
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        Write-WarnMsg 'Telegram test skipped because -UserId was not provided'
        return
    }
    Write-Info 'Sending Telegram test message'
    $body = @{ chat_id = $UserId; text = 'OpenClaw Telegram channel setup completed.' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $Token) -ContentType 'application/json' -Body $body | Out-Null
}

function Test-DiscordChannel {
    if (-not $Test) { return }
    if ([string]::IsNullOrWhiteSpace($ChannelId)) {
        Write-WarnMsg 'Discord test skipped because -ChannelId was not provided'
        return
    }
    Write-Info 'Sending Discord test message'
    $headers = @{ Authorization = "Bot $Token" }
    $body = @{ content = 'OpenClaw Discord channel setup completed.' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri ("https://discord.com/api/v10/channels/{0}/messages" -f $ChannelId) -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
}

function Test-SlackChannel {
    if (-not $Test) { return }
    Write-Info 'Checking Slack bot token'
    $headers = @{ Authorization = "Bearer $BotToken" }
    Invoke-RestMethod -Method Get -Uri 'https://slack.com/api/auth.test' -Headers $headers | Out-Null
}

function Test-FeishuChannel {
    if (-not $Test) { return }
    Write-Info 'Checking Feishu app credentials'
    $body = @{ app_id = $AppId; app_secret = $AppSecret } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' -ContentType 'application/json' -Body $body | Out-Null
}

function Setup-Telegram {
    $script:Token = Prompt-Value -Prompt 'Telegram bot token' -Current $script:Token -Secret
    $script:UserId = Prompt-Value -Prompt 'Telegram user/chat id for test (optional)' -Current $script:UserId
    Require-Value -Name '-Token' -Value $script:Token

    Ensure-PluginEnabled -PluginName 'telegram'
    Ensure-PluginConfig -PluginName 'telegram'
    try {
        Invoke-OpenClaw channels add --channel telegram --token $script:Token | Out-Null
    }
    catch {
        Write-WarnMsg "openclaw channels add --channel telegram returned non-zero; verify with 'openclaw channels list'"
    }

    Restart-Gateway
    Write-Info 'Telegram configured'
    Write-Host ("  token: {0}" -f (Mask-Value -Value $script:Token))
    Test-TelegramChannel
}

function Setup-Discord {
    $script:Token = Prompt-Value -Prompt 'Discord bot token' -Current $script:Token -Secret
    $script:ChannelId = Prompt-Value -Prompt 'Discord channel id for test (optional)' -Current $script:ChannelId
    Require-Value -Name '-Token' -Value $script:Token

    Ensure-PluginEnabled -PluginName 'discord'
    Ensure-PluginConfig -PluginName 'discord' -GroupPolicy 'open' -DmPolicy 'pairing'
    try {
        Invoke-OpenClaw channels add --channel discord --token $script:Token | Out-Null
    }
    catch {
        Write-WarnMsg "openclaw channels add --channel discord returned non-zero; verify with 'openclaw channels list'"
    }
    try {
        Invoke-OpenClaw config set channels.discord.groupPolicy open | Out-Null
    }
    catch {
        Write-WarnMsg 'Failed to set channels.discord.groupPolicy=open'
    }

    Restart-Gateway
    Write-Info 'Discord configured'
    Write-Host ("  token: {0}" -f (Mask-Value -Value $script:Token))
    Test-DiscordChannel
}

function Setup-Slack {
    $script:BotToken = Prompt-Value -Prompt 'Slack bot token' -Current $script:BotToken -Secret
    $script:AppToken = Prompt-Value -Prompt 'Slack app token' -Current $script:AppToken -Secret
    Require-Value -Name '-BotToken' -Value $script:BotToken
    Require-Value -Name '-AppToken' -Value $script:AppToken

    Ensure-PluginEnabled -PluginName 'slack'
    Ensure-PluginConfig -PluginName 'slack'
    try {
        Invoke-OpenClaw channels add --channel slack --bot-token $script:BotToken --app-token $script:AppToken | Out-Null
    }
    catch {
        Write-WarnMsg "openclaw channels add --channel slack returned non-zero; verify with 'openclaw channels list'"
    }

    Restart-Gateway
    Write-Info 'Slack configured'
    Write-Host ("  bot token: {0}" -f (Mask-Value -Value $script:BotToken))
    Write-Host ("  app token: {0}" -f (Mask-Value -Value $script:AppToken))
    Test-SlackChannel
}

function Setup-Feishu {
    $script:AppId = Prompt-Value -Prompt 'Feishu app id' -Current $script:AppId
    $script:AppSecret = Prompt-Value -Prompt 'Feishu app secret' -Current $script:AppSecret -Secret
    Require-Value -Name '-AppId' -Value $script:AppId
    Require-Value -Name '-AppSecret' -Value $script:AppSecret

    $pluginList = ''
    try { $pluginList = Invoke-OpenClaw plugins list | Out-String } catch {}
    if ($pluginList -notmatch 'feishu') {
        Write-Info 'Installing Feishu plugin'
        try {
            Invoke-OpenClaw plugins install '@m1heng-clawd/feishu' | Out-Null
        }
        catch {
            Write-WarnMsg 'Feishu plugin install returned non-zero; continuing'
        }
    }

    Ensure-PluginEnabled -PluginName 'feishu'
    Ensure-PluginConfig -PluginName 'feishu'
    try { Invoke-OpenClaw channels add --channel feishu | Out-Null } catch { Write-WarnMsg "openclaw channels add --channel feishu returned non-zero; verify with 'openclaw channels list'" }
    try { Invoke-OpenClaw config set channels.feishu.appId $script:AppId | Out-Null } catch { Write-WarnMsg 'Failed to set feishu appId' }
    try { Invoke-OpenClaw config set channels.feishu.appSecret $script:AppSecret | Out-Null } catch { Write-WarnMsg 'Failed to set feishu appSecret' }
    try { Invoke-OpenClaw config set channels.feishu.enabled true | Out-Null } catch { Write-WarnMsg 'Failed to set feishu enabled=true' }
    try { Invoke-OpenClaw config set channels.feishu.connectionMode websocket | Out-Null } catch { Write-WarnMsg 'Failed to set feishu connectionMode=websocket' }
    try { Invoke-OpenClaw config set channels.feishu.domain feishu | Out-Null } catch { Write-WarnMsg 'Failed to set feishu domain=feishu' }
    try { Invoke-OpenClaw config set channels.feishu.requireMention true | Out-Null } catch { Write-WarnMsg 'Failed to set feishu requireMention=true' }

    Restart-Gateway
    Write-Info 'Feishu configured'
    Write-Host ("  app id: {0}" -f (Mask-Value -Value $script:AppId -Prefix 8 -Suffix 4))
    Test-FeishuChannel
}

function Setup-WhatsApp {
    Ensure-PluginEnabled -PluginName 'whatsapp'
    Ensure-PluginConfig -PluginName 'whatsapp'
    Write-Info 'Starting WhatsApp login flow'
    Invoke-OpenClaw channels login --channel whatsapp --verbose | Out-Null
    Restart-Gateway
    Write-Info 'WhatsApp configured'
}

function Setup-WeChat {
    if ([string]::IsNullOrWhiteSpace($script:PluginId)) {
        $script:PluginId = 'wechat'
    }
    $script:PluginId = Prompt-Value -Prompt 'WeChat plugin id' -Current $script:PluginId
    Require-Value -Name '-PluginId' -Value $script:PluginId

    Ensure-PluginEnabled -PluginName $script:PluginId
    Ensure-PluginConfig -PluginName $script:PluginId
    Restart-Gateway

    Write-Info 'WeChat plugin enabled'
    Write-Host ("  plugin: {0}" -f $script:PluginId)
}

function Setup-IMessage {
    Throw-Fail 'iMessage setup requires macOS. Use channel_setup.sh on macOS instead.'
}

if (-not $PSBoundParameters.ContainsKey('Channel')) {
    Show-Usage
    exit 1
}

Assert-OpenClawInstalled
Ensure-ConfigFile

switch ($Channel) {
    'telegram' { Setup-Telegram }
    'discord' { Setup-Discord }
    'slack' { Setup-Slack }
    'feishu' { Setup-Feishu }
    'whatsapp' { Setup-WhatsApp }
    'wechat' { Setup-WeChat }
    'imessage' { Setup-IMessage }
    default { Throw-Fail "Unsupported channel: $Channel" }
}

Write-Host ''
Write-Info 'Done. Recommended checks:'
Write-Host '  openclaw channels list'
Write-Host '  openclaw gateway status --deep'
