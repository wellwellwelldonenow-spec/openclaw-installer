[CmdletBinding()]
param(
    [string]$Channel,
    [string]$ConfigPath,
    [ValidateSet('auto', 'browser', 'manual')]
    [string]$GuideMode = 'auto',
    [string]$Token,
    [string]$BotToken,
    [string]$AppToken,
    [string]$UserId,
    [string]$ChannelId,
    [string]$AppId,
    [string]$AppSecret,
    [string]$PluginId,
    [switch]$NoAutoApproveFirstDm,
    [ValidateRange(1, 3600)]
    [int]$AutoApproveTimeoutSec = 180,
    [switch]$NoRestart,
    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InteractiveMenu = $false
$script:Channel = $Channel
$script:ConfigPath = $ConfigPath
$script:GuideMode = $GuideMode.ToLowerInvariant()
$script:Token = $Token
$script:BotToken = $BotToken
$script:AppToken = $AppToken
$script:UserId = $UserId
$script:ChannelId = $ChannelId
$script:AppId = $AppId
$script:AppSecret = $AppSecret
$script:PluginId = $PluginId
$script:AutoApproveFirstFeishuDm = -not [bool]$NoAutoApproveFirstDm
$script:AutoApproveTimeoutSec = $AutoApproveTimeoutSec
$script:NoRestart = [bool]$NoRestart
$script:Test = [bool]$Test
$script:OpenClawBrowserAvailable = $null

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
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel telegram -Token "YOUR_BOT_TOKEN" -UserId "YOUR_CHAT_ID" -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel discord -Token "YOUR_BOT_TOKEN" -ChannelId "YOUR_CHANNEL_ID" -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel slack -BotToken "YOUR_XOXB_TOKEN" -AppToken "YOUR_XAPP_TOKEN" -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel feishu -GuideMode browser -AppId "YOUR_APP_ID" -AppSecret "YOUR_APP_SECRET" -Test
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel whatsapp
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel wechat -PluginId wechat
  powershell -ExecutionPolicy Bypass -File .\channel_setup.ps1 -Channel imessage

Supported channels:
  telegram, discord, slack, feishu, whatsapp, wechat, imessage

Options:
  -ConfigPath "PATH_TO_CONFIG"   Override OpenClaw config path
  -GuideMode "auto|browser|manual"   Feishu guide mode; browser uses openclaw browser
  -NoAutoApproveFirstDm   Disable automatic approval of the first Feishu DM user
  -AutoApproveTimeoutSec  How long to wait for the first Feishu DM pairing request
  -NoRestart           Skip gateway restart
  -Test                Run a basic credential test when supported
'@ | Write-Host
}

function New-UnicodeText {
    param([int[]]$CodePoints)

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function Get-ZhText {
    param([Parameter(Mandatory = $true)][string]$Key)

    switch ($Key) {
        'menu_title' { return (New-UnicodeText @(0x6D88,0x606F,0x6E20,0x9053,0x4E00,0x952E,0x63A5,0x5165)) }
        'menu_help' { return (New-UnicodeText @(0x67E5,0x770B,0x547D,0x4EE4,0x884C,0x5E2E,0x52A9)) }
        'menu_exit' { return (New-UnicodeText @(0x9000,0x51FA)) }
        'menu_prompt' { return (New-UnicodeText @(0x8BF7,0x9009,0x62E9,0x8981,0x63A5,0x5165,0x7684,0x6E20,0x9053)) }
        'invalid_choice' { return (New-UnicodeText @(0x65E0,0x6548,0x9009,0x62E9,0xFF0C,0x8BF7,0x91CD,0x65B0,0x8F93,0x5165,0x3002)) }
        'restart_prompt' { return (New-UnicodeText @(0x914D,0x7F6E,0x5B8C,0x6210,0x540E,0x662F,0x5426,0x81EA,0x52A8,0x91CD,0x542F,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x7F51,0x5173,0xFF1F)) }
        'test_prompt' { return (New-UnicodeText @(0x662F,0x5426,0x7ACB,0x5373,0x6267,0x884C,0x4E00,0x6B21,0x6E20,0x9053,0x8FDE,0x901A,0x6027,0x6D4B,0x8BD5,0xFF1F)) }
        'feishu_portal_opened' { return (New-UnicodeText @(0x5DF2,0x4E3A,0x4F60,0x6253,0x5F00,0x98DE,0x4E66,0x5F00,0x53D1,0x8005,0x540E,0x53F0,0x3002)) }
        'feishu_portal_manual' { return (New-UnicodeText @(0x672A,0x80FD,0x81EA,0x52A8,0x6253,0x5F00,0x6D4F,0x89C8,0x5668,0xFF0C,0x8BF7,0x624B,0x52A8,0x8BBF,0x95EE,0xFF1A)) }
        'feishu_step_create' { return (New-UnicodeText @(0x521B,0x5EFA,0x4F01,0x4E1A,0x81EA,0x5EFA,0x5E94,0x7528,0x3002)) }
        'feishu_step_credentials' { return (New-UnicodeText @(0x5728,0x5E94,0x7528,0x51ED,0x8BC1,0x4E0E,0x57FA,0x7840,0x4FE1,0x606F,0x9875,0x590D,0x5236,0x20,0x41,0x70,0x70,0x20,0x49,0x44,0x20,0x548C,0x20,0x41,0x70,0x70,0x20,0x53,0x65,0x63,0x72,0x65,0x74,0x3002)) }
        'feishu_step_bot' { return (New-UnicodeText @(0x5F00,0x542F,0x5E94,0x7528,0x80FD,0x529B,0xFF1A,0x673A,0x5668,0x4EBA,0x3002)) }
        'feishu_step_permissions' { return (New-UnicodeText @(0x5F00,0x901A,0x6D88,0x606F,0x4E0E,0x7FA4,0x7EC4,0x76F8,0x5173,0x6743,0x9650,0x3002)) }
        'feishu_continue_prompt' { return (New-UnicodeText @(0x5B8C,0x6210,0x4EE5,0x4E0A,0x6B65,0x9AA4,0x540E,0x6309,0x56DE,0x8F66,0x7EE7,0x7EED,0x3002)) }
        'feishu_ws_ready' { return (New-UnicodeText @(0x5DF2,0x4E3A,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x914D,0x7F6E,0x20,0x46,0x65,0x69,0x73,0x68,0x75,0x20,0x57,0x65,0x62,0x53,0x6F,0x63,0x6B,0x65,0x74,0x20,0x8FDE,0x63A5,0x6A21,0x5F0F,0x3002)) }
        'feishu_ws_step' { return (New-UnicodeText @(0x8BF7,0x5728,0x20,0x4E8B,0x4EF6,0x4E0E,0x56DE,0x8C03,0x20,0x2D,0x3E,0x20,0x8BA2,0x9605,0x65B9,0x5F0F,0x20,0x91CC,0x9009,0x62E9,0x20,0x957F,0x8FDE,0x63A5,0x3002)) }
        'feishu_event_step' { return (New-UnicodeText @(0x5E76,0x6DFB,0x52A0,0x4E8B,0x4EF6,0xFF1A,0x63A5,0x6536,0x6D88,0x606F,0x3002)) }
        'feishu_publish_step' { return (New-UnicodeText @(0x521B,0x5EFA,0x7248,0x672C,0x5E76,0x786E,0x8BA4,0x53D1,0x5E03,0x3002)) }
        'guide_mode_title' { return (New-UnicodeText @(0x98DE,0x4E66,0x63A5,0x5165,0x65B9,0x5F0F)) }
        'guide_mode_prompt' { return (New-UnicodeText @(0x8BF7,0x9009,0x62E9,0x98DE,0x4E66,0x63A5,0x5165,0x65B9,0x5F0F)) }
        'guide_mode_browser' { return (New-UnicodeText @(0x81EA,0x52A8,0x5316,0x6D4F,0x89C8,0x5668,0x8F85,0x52A9,0xFF08,0x4F7F,0x7528,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x62,0x72,0x6F,0x77,0x73,0x65,0x72,0xFF09)) }
        'guide_mode_manual' { return (New-UnicodeText @(0x624B,0x52A8,0x6309,0x63D0,0x793A,0x64CD,0x4F5C)) }
        'guide_mode_invalid' { return (New-UnicodeText @(0x65E0,0x6548,0x9009,0x62E9,0xFF0C,0x8BF7,0x91CD,0x65B0,0x8F93,0x5165,0x3002)) }
        'feishu_portal_browser_opened' { return (New-UnicodeText @(0x5DF2,0x4F7F,0x7528,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x6D4F,0x89C8,0x5668,0x6253,0x5F00,0x98DE,0x4E66,0x5F00,0x53D1,0x8005,0x540E,0x53F0,0x3002)) }
        'feishu_browser_login_tip' { return (New-UnicodeText @(0x5982,0x672A,0x767B,0x5F55,0xFF0C,0x8BF7,0x5148,0x5728,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x6D4F,0x89C8,0x5668,0x5B8C,0x6210,0x767B,0x5F55,0x3001,0x4F01,0x4E1A,0x5207,0x6362,0x548C,0x5E94,0x7528,0x521B,0x5EFA,0x3002)) }
        'feishu_browser_scan_tip' { return (New-UnicodeText @(0x8BF7,0x5728,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x6D4F,0x89C8,0x5668,0x4E2D,0x626B,0x7801,0x767B,0x5F55,0x98DE,0x4E66,0xFF0C,0x767B,0x5F55,0x5B8C,0x6210,0x540E,0x811A,0x672C,0x4F1A,0x81EA,0x52A8,0x7EE7,0x7EED,0x3002)) }
        'feishu_browser_waiting' { return (New-UnicodeText @(0x6B63,0x5728,0x7B49,0x5F85,0x98DE,0x4E66,0x767B,0x5F55,0x5B8C,0x6210,0x2E,0x2E,0x2E)) }
        'feishu_browser_login_done' { return (New-UnicodeText @(0x68C0,0x6D4B,0x5230,0x98DE,0x4E66,0x767B,0x5F55,0x5B8C,0x6210,0xFF0C,0x7EE7,0x7EED,0x6267,0x884C,0x914D,0x7F6E,0x3002)) }
        'feishu_browser_login_timeout' { return (New-UnicodeText @(0x7B49,0x5F85,0x98DE,0x4E66,0x767B,0x5F55,0x8D85,0x65F6,0xFF0C,0x8BF7,0x786E,0x8BA4,0x5DF2,0x767B,0x5F55,0x540E,0x6309,0x56DE,0x8F66,0x7EE7,0x7EED,0xFF0C,0x6216,0x6309,0x20,0x43,0x74,0x72,0x6C,0x2B,0x43,0x20,0x53D6,0x6D88,0x3002)) }
        'browser_mode_unavailable' { return (New-UnicodeText @(0x5F53,0x524D,0x672A,0x68C0,0x6D4B,0x5230,0x53EF,0x7528,0x7684,0x20,0x4F,0x70,0x65,0x6E,0x43,0x6C,0x61,0x77,0x20,0x62,0x72,0x6F,0x77,0x73,0x65,0x72,0xFF0C,0x5DF2,0x56DE,0x9000,0x4E3A,0x624B,0x52A8,0x63D0,0x793A,0x6A21,0x5F0F,0x3002)) }
        default { return $Key }
    }
}

function Test-SupportedChannel {
    param([string]$Name)

    return $Name -in @('telegram', 'discord', 'slack', 'feishu', 'whatsapp', 'wechat', 'imessage')
}

function Test-InteractiveConsole {
    try {
        return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    }
    catch {
        return $true
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host -Prompt "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }

    return $answer.Trim().ToLowerInvariant() -in @('y', 'yes', '1')
}

function Open-ExternalUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [switch]$UseBrowserAutomation
    )

    if ($UseBrowserAutomation -and (Test-OpenClawBrowserAvailable)) {
        try {
            Invoke-OpenClawBrowser start | Out-Null
            Invoke-OpenClawBrowser open $Url | Out-Null
            return [pscustomobject]@{ Success = $true; Method = 'browser' }
        }
        catch {
            Write-WarnMsg "openclaw browser open failed; falling back to system browser."
        }
    }

    try {
        Start-Process $Url | Out-Null
        return [pscustomobject]@{ Success = $true; Method = 'system' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Method = 'none' }
    }
}

function Wait-ForEnter {
    param([string]$Prompt)

    if (Test-InteractiveConsole) {
        [void](Read-Host -Prompt $Prompt)
    }
}

function Invoke-OpenClawBrowser {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $allArgs = @('browser') + $Arguments
    return Invoke-OpenClaw @allArgs
}

function Test-OpenClawBrowserAvailable {
    if ($null -ne $script:OpenClawBrowserAvailable) {
        return [bool]$script:OpenClawBrowserAvailable
    }

    try {
        Invoke-OpenClawBrowser '--help' | Out-Null
        $script:OpenClawBrowserAvailable = $true
    }
    catch {
        $script:OpenClawBrowserAvailable = $false
    }

    return [bool]$script:OpenClawBrowserAvailable
}

function Test-FeishuBrowserLoggedIn {
    try {
        $tabs = Invoke-OpenClawBrowser tabs
    }
    catch {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($tabs)) {
        return $false
    }

    return $tabs -match 'https://open\.feishu\.cn/app(\?[^ \r\n]*)?'
}

function Wait-ForFeishuBrowserLogin {
    if (-not (Test-InteractiveConsole)) {
        return
    }

    Write-Info (Get-ZhText 'feishu_browser_scan_tip')
    Write-Info (Get-ZhText 'feishu_browser_waiting')

    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if (Test-FeishuBrowserLoggedIn) {
            Write-Info (Get-ZhText 'feishu_browser_login_done')
            return
        }

        Start-Sleep -Seconds 5
    }

    Write-WarnMsg (Get-ZhText 'feishu_browser_login_timeout')
    Wait-ForEnter -Prompt (Get-ZhText 'feishu_browser_login_timeout')
}

function Resolve-FeishuBrowserHelperPath {
    $localHelper = if ($PSCommandPath) {
        Join-Path (Split-Path -Parent $PSCommandPath) 'feishu_browser_automation.js'
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($localHelper) -and (Test-Path $localHelper)) {
        return $localHelper
    }

    $downloadedHelper = Join-Path $env:TEMP 'openclaw-feishu-browser-automation.js'
    $helperUrl = 'https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/feishu_browser_automation.js'

    if (-not (Test-Path $downloadedHelper)) {
        Write-Info 'Downloading Feishu browser automation helper'
        Invoke-WebRequest -UseBasicParsing -Uri $helperUrl -OutFile $downloadedHelper
    }

    return $downloadedHelper
}

function Invoke-FeishuBrowserAutomation {
    $nodeCommand = Get-NodeCommand
    if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
        Throw-Fail 'node.exe not found; Feishu browser automation needs Node.js.'
    }

    $helperPath = Resolve-FeishuBrowserHelperPath
    $appName = 'OpenClaw Gateway {0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $appDescription = 'OpenClaw Feishu channel integration'

    Write-Info 'Running Feishu browser automation'
    $result = Invoke-NativeCommandSafe -Command $nodeCommand -Arguments @(
        $helperPath,
        '--app-name',
        $appName,
        '--app-description',
        $appDescription
    )

    if ($result.ExitCode -ne 0) {
        $message = if ([string]::IsNullOrWhiteSpace($result.Output)) {
            'Feishu browser automation failed.'
        }
        else {
            $result.Output
        }
        throw $message
    }

    $payload = $result.Output | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($payload.appId) -or [string]::IsNullOrWhiteSpace($payload.appSecret)) {
        Throw-Fail 'Feishu browser automation did not return App ID / App Secret.'
    }

    $script:AppId = [string]$payload.appId
    $script:AppSecret = [string]$payload.appSecret
    Write-Info ('Feishu browser automation completed: {0}' -f $script:AppId)
}

function Invoke-FeishuBrowserFinalize {
    $nodeCommand = Get-NodeCommand
    if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
        Throw-Fail 'node.exe not found; Feishu browser automation needs Node.js.'
    }

    $helperPath = Resolve-FeishuBrowserHelperPath
    Write-Info 'Running Feishu browser post-config automation'
    $result = Invoke-NativeCommandSafe -Command $nodeCommand -Arguments @(
        $helperPath,
        '--mode',
        'finalize',
        '--app-id',
        $script:AppId,
        '--version-notes',
        'OpenClaw Feishu channel auto setup'
    )

    if ($result.ExitCode -ne 0) {
        $message = if ([string]::IsNullOrWhiteSpace($result.Output)) {
            'Feishu browser post-config automation failed.'
        }
        else {
            $result.Output
        }
        throw $message
    }

    $payload = $result.Output | ConvertFrom-Json
    if (-not $payload.published) {
        Throw-Fail 'Feishu browser post-config automation did not finish publishing.'
    }

    Write-Info ('Feishu browser post-config completed: {0}' -f $script:AppId)
}

function Select-FeishuGuideMode {
    if ($script:GuideMode -in @('browser', 'manual')) {
        if ($script:GuideMode -eq 'browser' -and -not (Test-OpenClawBrowserAvailable)) {
            Write-WarnMsg (Get-ZhText 'browser_mode_unavailable')
            $script:GuideMode = 'manual'
        }

        return $script:GuideMode
    }

    if (-not (Test-InteractiveConsole)) {
        if (Test-OpenClawBrowserAvailable) {
            return 'browser'
        }

        return 'manual'
    }

    if (-not (Test-OpenClawBrowserAvailable)) {
        $script:GuideMode = 'manual'
        return 'manual'
    }

    while ($true) {
        Write-Host ''
        Write-Host (Get-ZhText 'guide_mode_title') -ForegroundColor Cyan
        Write-Host ("  1. " + (Get-ZhText 'guide_mode_browser'))
        Write-Host ("  2. " + (Get-ZhText 'guide_mode_manual'))

        $choice = (Read-Host -Prompt (Get-ZhText 'guide_mode_prompt')).Trim().ToLowerInvariant()
        switch ($choice) {
            '1' { $script:GuideMode = 'browser'; return 'browser' }
            '2' { $script:GuideMode = 'manual'; return 'manual' }
            default { Write-WarnMsg (Get-ZhText 'guide_mode_invalid') }
        }
    }
}

function Show-FeishuSetupGuide {
    if (-not (Test-InteractiveConsole)) {
        return $script:GuideMode
    }

    $guideMode = Select-FeishuGuideMode
    $portalUrl = 'https://open.feishu.cn/app?lang=zh-CN'
    $openResult = Open-ExternalUrl -Url $portalUrl -UseBrowserAutomation:($guideMode -eq 'browser')
    if ($openResult.Success) {
        if ($openResult.Method -eq 'browser') {
            Write-Info (Get-ZhText 'feishu_portal_browser_opened')
            Write-Host ("  0. " + (Get-ZhText 'feishu_browser_login_tip'))
            Wait-ForFeishuBrowserLogin
            return $guideMode
        }
        else {
            Write-Info (Get-ZhText 'feishu_portal_opened')
        }
    }
    else {
        Write-WarnMsg ((Get-ZhText 'feishu_portal_manual') + " $portalUrl")
    }

    Write-Host ("  1. " + (Get-ZhText 'feishu_step_create'))
    Write-Host ("  2. " + (Get-ZhText 'feishu_step_credentials'))
    Write-Host ("  3. " + (Get-ZhText 'feishu_step_bot'))
    Write-Host ("  4. " + (Get-ZhText 'feishu_step_permissions'))
    Wait-ForEnter -Prompt (Get-ZhText 'feishu_continue_prompt')
    return $guideMode
}

function Show-FeishuPostConfigGuide {
    Write-Info (Get-ZhText 'feishu_ws_ready')
    Write-Host ("  1. " + (Get-ZhText 'feishu_step_bot'))
    Write-Host ("  2. " + (Get-ZhText 'feishu_step_permissions'))
    Write-Host ("  3. " + (Get-ZhText 'feishu_ws_step'))
    Write-Host ("  4. " + (Get-ZhText 'feishu_event_step'))
    Write-Host ("  5. " + (Get-ZhText 'feishu_publish_step'))
}

function Show-ChannelMenu {
    while ($true) {
        Write-Host ''
        Write-Host ("OpenClaw " + (Get-ZhText 'menu_title')) -ForegroundColor Cyan
        Write-Host '  1. Telegram'
        Write-Host '  2. Discord'
        Write-Host '  3. Slack'
        Write-Host '  4. Feishu'
        Write-Host '  5. WhatsApp'
        Write-Host '  6. WeChat Plugin'
        Write-Host '  7. iMessage'
        Write-Host ("  h. " + (Get-ZhText 'menu_help'))
        Write-Host ("  q. " + (Get-ZhText 'menu_exit'))

        $choice = (Read-Host -Prompt (Get-ZhText 'menu_prompt')).Trim().ToLowerInvariant()
        switch ($choice) {
            '1' { $script:Channel = 'telegram'; break }
            '2' { $script:Channel = 'discord'; break }
            '3' { $script:Channel = 'slack'; break }
            '4' { $script:Channel = 'feishu'; break }
            '5' { $script:Channel = 'whatsapp'; break }
            '6' { $script:Channel = 'wechat'; break }
            '7' { $script:Channel = 'imessage'; break }
            'h' { Show-Usage }
            'q' { exit 0 }
            default { Write-WarnMsg (Get-ZhText 'invalid_choice') }
        }

        if (-not [string]::IsNullOrWhiteSpace($script:Channel)) {
            break
        }
    }

    $script:InteractiveMenu = $true
}

function Configure-MenuOptions {
    if (-not $script:InteractiveMenu) {
        return
    }

    $script:NoRestart = -not (Read-YesNo -Prompt (Get-ZhText 'restart_prompt') -Default $true)

    switch ($script:Channel) {
        'telegram' { $script:Test = Read-YesNo -Prompt (Get-ZhText 'test_prompt') -Default $true }
        'discord' { $script:Test = Read-YesNo -Prompt (Get-ZhText 'test_prompt') -Default $true }
        'slack' { $script:Test = Read-YesNo -Prompt (Get-ZhText 'test_prompt') -Default $true }
        'feishu' { $script:Test = Read-YesNo -Prompt (Get-ZhText 'test_prompt') -Default $true }
        default { $script:Test = $false }
    }
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

function Expand-ConfigPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expanded = $Path.Trim().Trim('"', "'")
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        return $null
    }

    if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        return (Join-Path $HOME ($expanded.Substring(2) -replace '/', '\'))
    }

    if ($expanded.StartsWith('$HOME/')) {
        return (Join-Path $HOME ($expanded.Substring(6) -replace '/', '\'))
    }

    if ($expanded.StartsWith('$HOME\')) {
        return (Join-Path $HOME $expanded.Substring(6))
    }

    return $expanded
}

function Convert-OpenClawOutputToConfigPath {
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $null
    }

    $lines = @(
        $Output -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    [array]::Reverse($lines)
    foreach ($line in $lines) {
        $candidate = $line
        if ($candidate -match '^(?i)config\s+file\s*:\s*(.+)$') {
            $candidate = $matches[1].Trim()
        }

        $candidate = Expand-ConfigPath -Path $candidate
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if ($candidate -notmatch '(?i)([\\/]|^[A-Z]:|^\\\\|(^|[\\/])openclaw\.json$)') {
            continue
        }

        try {
            [System.IO.Path]::GetFullPath($candidate) | Out-Null
            return $candidate
        }
        catch {}
    }

    return $null
}

function Resolve-ConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ConfigPath)) {
        $script:ConfigPath = Expand-ConfigPath -Path $script:ConfigPath
        return $script:ConfigPath
    }

    try {
        $resolved = Convert-OpenClawOutputToConfigPath -Output (Invoke-OpenClaw config file)
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
    if ($script:NoRestart) {
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
    if (-not $script:Test) { return }
    if ([string]::IsNullOrWhiteSpace($script:UserId)) {
        Write-WarnMsg 'Telegram test skipped because -UserId was not provided'
        return
    }
    Write-Info 'Sending Telegram test message'
    $body = @{ chat_id = $script:UserId; text = 'OpenClaw Telegram channel setup completed.' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $script:Token) -ContentType 'application/json' -Body $body | Out-Null
}

function Test-DiscordChannel {
    if (-not $script:Test) { return }
    if ([string]::IsNullOrWhiteSpace($script:ChannelId)) {
        Write-WarnMsg 'Discord test skipped because -ChannelId was not provided'
        return
    }
    Write-Info 'Sending Discord test message'
    $headers = @{ Authorization = "Bot $script:Token" }
    $body = @{ content = 'OpenClaw Discord channel setup completed.' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri ("https://discord.com/api/v10/channels/{0}/messages" -f $script:ChannelId) -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
}

function Test-SlackChannel {
    if (-not $script:Test) { return }
    Write-Info 'Checking Slack bot token'
    $headers = @{ Authorization = "Bearer $script:BotToken" }
    Invoke-RestMethod -Method Get -Uri 'https://slack.com/api/auth.test' -Headers $headers | Out-Null
}

function Test-FeishuChannel {
    if (-not $script:Test) { return }
    Write-Info 'Checking Feishu app credentials'
    $body = @{ app_id = $script:AppId; app_secret = $script:AppSecret } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' -ContentType 'application/json' -Body $body | Out-Null
}

function Resolve-FeishuAllowFromPath {
    $configPath = Resolve-ConfigPath
    $stateDir = Split-Path -Parent $configPath
    return (Join-Path (Join-Path $stateDir 'credentials') 'feishu-default-allowFrom.json')
}

function Test-FeishuHasAllowedDmUsers {
    $allowFromPath = Resolve-FeishuAllowFromPath
    if (-not (Test-Path $allowFromPath)) {
        return $false
    }

    try {
        $data = Get-Content -Path $allowFromPath -Raw | ConvertFrom-Json
        $allowFrom = @($data.allowFrom | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        return $allowFrom.Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-FirstFeishuPairingRequest {
    try {
        $raw = Invoke-OpenClaw pairing list feishu --json
    }
    catch {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    $start = $raw.IndexOf('{')
    if ($start -lt 0) {
        return $null
    }

    try {
        $payload = $raw.Substring($start) | ConvertFrom-Json
    }
    catch {
        return $null
    }

    $requests = @($payload.requests)
    if ($requests.Count -eq 0) {
        return $null
    }

    $sorted = $requests | Sort-Object @{
        Expression = {
            try {
                $timestamp = ''
                if ($null -ne $_.createdAt -and -not [string]::IsNullOrWhiteSpace([string]$_.createdAt)) {
                    $timestamp = [string]$_.createdAt
                }
                elseif ($null -ne $_.lastSeenAt -and -not [string]::IsNullOrWhiteSpace([string]$_.lastSeenAt)) {
                    $timestamp = [string]$_.lastSeenAt
                }
                [DateTimeOffset]::Parse($timestamp).ToUnixTimeMilliseconds()
            }
            catch {
                0
            }
        }
    }

    $request = $sorted | Select-Object -First 1
    if ($null -eq $request -or [string]::IsNullOrWhiteSpace([string]$request.code)) {
        return $null
    }

    return [pscustomobject]@{
        Code = [string]$request.code
        Id = [string]$request.id
    }
}

function Wait-ApproveFirstFeishuDmUser {
    if (-not $script:AutoApproveFirstFeishuDm) {
        return
    }

    if (Test-FeishuHasAllowedDmUsers) {
        Write-Info 'Feishu DM allowlist already has entries; skipping first-user auto approval'
        return
    }

    $deadline = (Get-Date).AddSeconds($script:AutoApproveTimeoutSec)
    Write-Info ("Waiting up to {0}s to auto-approve the first Feishu private chat user" -f $script:AutoApproveTimeoutSec)
    Write-Info 'Send the first private message to the Feishu bot now'

    while ((Get-Date) -lt $deadline) {
        $request = Get-FirstFeishuPairingRequest
        if ($null -ne $request) {
            try {
                Invoke-OpenClaw pairing approve feishu $request.Code --notify | Out-Null
                if ([string]::IsNullOrWhiteSpace($request.Id)) {
                    Write-Info 'Approved first Feishu private chat user'
                }
                else {
                    Write-Info ("Approved first Feishu private chat user: {0}" -f $request.Id)
                }
                return
            }
            catch {
                Write-WarnMsg ("Automatic approval for Feishu pairing code {0} failed; retrying" -f $request.Code)
            }
        }

        Start-Sleep -Seconds 3
    }

    Write-WarnMsg ("No Feishu private chat pairing request arrived within {0}s" -f $script:AutoApproveTimeoutSec)
    Write-WarnMsg "If needed, run: openclaw pairing list feishu --json"
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
    $selectedGuideMode = $script:GuideMode
    $browserPostConfigDone = $false
    $shouldShowGuide = (Test-InteractiveConsole) -and (
        ([string]::IsNullOrWhiteSpace($script:AppId) -or [string]::IsNullOrWhiteSpace($script:AppSecret)) -or
        ($script:GuideMode -ne 'auto')
    )
    if ($shouldShowGuide) {
        $selectedGuideMode = Show-FeishuSetupGuide
    }

    if (($selectedGuideMode -eq 'browser') -and
        ([string]::IsNullOrWhiteSpace($script:AppId) -or [string]::IsNullOrWhiteSpace($script:AppSecret))) {
        try {
            Invoke-FeishuBrowserAutomation
        }
        catch {
            Write-WarnMsg "Feishu browser automation failed; falling back to manual credentials input."
            if (-not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                Write-WarnMsg $_.Exception.Message
            }
        }
    }

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

    if ($selectedGuideMode -eq 'browser') {
        Start-Sleep -Seconds 5
        try {
            Invoke-FeishuBrowserFinalize
            $browserPostConfigDone = $true
        }
        catch {
            Write-WarnMsg "Feishu browser post-config automation failed; falling back to manual finishing steps."
            if (-not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                Write-WarnMsg $_.Exception.Message
            }
        }
    }

    Write-Info 'Feishu configured'
    Write-Host ("  app id: {0}" -f (Mask-Value -Value $script:AppId -Prefix 8 -Suffix 4))
    if (-not $browserPostConfigDone) {
        Show-FeishuPostConfigGuide
    }
    Test-FeishuChannel
    Wait-ApproveFirstFeishuDmUser
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
    if (Test-InteractiveConsole) {
        Show-ChannelMenu
        Configure-MenuOptions
    }
    else {
        Show-Usage
        exit 1
    }
}

if (-not [string]::IsNullOrWhiteSpace($script:Channel) -and -not (Test-SupportedChannel -Name $script:Channel)) {
    Throw-Fail "Unsupported channel: $script:Channel"
}

Assert-OpenClawInstalled
Ensure-ConfigFile

switch ($script:Channel) {
    'telegram' { Setup-Telegram }
    'discord' { Setup-Discord }
    'slack' { Setup-Slack }
    'feishu' { Setup-Feishu }
    'whatsapp' { Setup-WhatsApp }
    'wechat' { Setup-WeChat }
    'imessage' { Setup-IMessage }
    default { Throw-Fail "Unsupported channel: $script:Channel" }
}

Write-Host ''
Write-Info 'Done. Recommended checks:'
Write-Host '  openclaw channels list'
Write-Host '  openclaw gateway status --deep'
