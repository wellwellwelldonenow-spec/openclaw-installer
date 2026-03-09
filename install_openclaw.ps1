[CmdletBinding()]
param(
    [string]$ApiKey = $env:NEWAPI_API_KEY,
    [string]$ModelId = $env:OPENCLAW_MODEL_ID,
    [int]$GatewayPort = $(if ($env:OPENCLAW_PORT) { [int]$env:OPENCLAW_PORT } else { 18789 }),
    [switch]$SkipUpstreamCheck,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$GatewayPortInput = if ($PSBoundParameters.ContainsKey('GatewayPort') -or -not [string]::IsNullOrWhiteSpace($env:OPENCLAW_PORT)) { $GatewayPort } else { $null }
$ProviderId = 'megabyai'
$BaseUrl = 'https://newapi.megabyai.cc/v1'
$DefaultModelId = 'gpt-5.3-codex'
$EnableBrowserTool = $env:OPENCLAW_ENABLE_BROWSER_TOOL -ne '0'
$SkipServiceInstall = $false

function Initialize-ConsoleEncoding {
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [Console]::InputEncoding = $utf8NoBom
        [Console]::OutputEncoding = $utf8NoBom
        $global:OutputEncoding = $utf8NoBom
    } catch {}

    try {
        if ($env:OS -eq 'Windows_NT' -and (Get-Command chcp.com -ErrorAction SilentlyContinue)) {
            & chcp.com 65001 *> $null
        }
    } catch {}
}

function Proxy-AlreadyConfigured {
    return -not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or
        -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY) -or
        -not [string]::IsNullOrWhiteSpace($env:ALL_PROXY) -or
        -not [string]::IsNullOrWhiteSpace($env:https_proxy) -or
        -not [string]::IsNullOrWhiteSpace($env:http_proxy) -or
        -not [string]::IsNullOrWhiteSpace($env:all_proxy)
}

function Set-ProxyEnvironment([string]$ProxyUrl) {
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        Set-Item -Path "env:$name" -Value $ProxyUrl
    }
    Write-Info "Enabled local proxy automatically: $ProxyUrl"
}

function Get-ProxyEndpoint([string]$ProxyUrl) {
    try {
        $uri = [System.Uri]$ProxyUrl
        return @{
            Host = $uri.Host
            Port = $uri.Port
        }
    } catch {
        return $null
    }
}

function Test-ProxyPortOpen([string]$ProxyUrl) {
    $endpoint = Get-ProxyEndpoint $ProxyUrl
    if ($null -eq $endpoint) {
        return $false
    }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($endpoint.Host, $endpoint.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Get-ProxyFailureReason([string]$ProxyUrl, [System.Exception]$Exception) {
    if (-not (Test-ProxyPortOpen $ProxyUrl)) {
        return 'Port unreachable; proxy may not be running or listening on this port'
    }

    $messageParts = @()
    if ($null -ne $Exception -and -not [string]::IsNullOrWhiteSpace($Exception.Message)) {
        $messageParts += $Exception.Message
    }
    if ($null -ne $Exception -and $null -ne $Exception.InnerException -and -not [string]::IsNullOrWhiteSpace($Exception.InnerException.Message)) {
        $messageParts += $Exception.InnerException.Message
    }
    $message = ($messageParts -join ' ').Trim()

    if ($message -match '407|authentication|proxy authentication|required') {
        return 'Proxy requires authentication or rejected the GitHub connection'
    }
    if ($message -match 'SSL|TLS|secure channel') {
        return 'Proxy port is reachable, but TLS handshake to GitHub failed'
    }
    if ($message -match 'timed out|timeout|operation has timed out') {
        return 'Proxy port is reachable, but GitHub request timed out'
    }
    if ($message -match 'reset|forcibly closed|unexpected eof|early eof|empty reply') {
        return 'Proxy port is reachable, but the GitHub connection was interrupted'
    }
    if ($message -match 'name could not be resolved|remote name could not be resolved|dns') {
        return 'Proxy port is reachable, but DNS resolution failed'
    }
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        return "Proxy port is reachable, but GitHub request failed: $message"
    }

    return 'Proxy port is reachable, but GitHub request failed'
}

function Test-ProxyCandidate([string]$ProxyUrl) {
    try {
        $params = @{
            Uri = 'https://github.com'
            Proxy = $ProxyUrl
            TimeoutSec = 4
            Method = 'Head'
        }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $params.UseBasicParsing = $true
        }
        $response = Invoke-WebRequest @params
        return [pscustomobject]@{
            Success = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
            Reason = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Reason = Get-ProxyFailureReason -ProxyUrl $ProxyUrl -Exception $_.Exception
        }
    }
}

function Get-LocalListeningPorts {
    $ports = New-Object 'System.Collections.Generic.List[int]'

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        foreach ($row in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            if ($null -eq $row.LocalPort) { continue }
            $address = [string]$row.LocalAddress
            if ($address -notin @('127.0.0.1', '::1', '0.0.0.0', '::', '::0', '::ffff:127.0.0.1')) {
                continue
            }
            if (-not $ports.Contains([int]$row.LocalPort)) {
                $ports.Add([int]$row.LocalPort)
            }
        }
        return $ports | Sort-Object | Select-Object -First 64
    }

    foreach ($line in (netstat -ano -p tcp 2>$null)) {
        if ($line -notmatch 'LISTENING') { continue }
        $columns = ($line -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($columns.Count -lt 2) { continue }
        $localEndpoint = $columns[1]
        $portText = ($localEndpoint -replace '^.*:', '')
        $address = ($localEndpoint -replace ':\d+$', '')
        if ($address -notin @('127.0.0.1', '0.0.0.0', '[::1]', '[::]')) {
            continue
        }
        if ($portText -match '^\d+$') {
            $port = [int]$portText
            if (-not $ports.Contains($port)) {
                $ports.Add($port)
            }
        }
    }

    return $ports | Sort-Object | Select-Object -First 64
}

function Get-LocalProxyCandidates {
    foreach ($port in (Get-LocalListeningPorts)) {
        "http://127.0.0.1:$port"
    }
}

function Initialize-Proxy {
    if (Proxy-AlreadyConfigured) {
        Write-Info 'Proxy environment variables already set; keeping existing settings'
        return
    }

    $attempts = 0
    $diagnostics = New-Object 'System.Collections.Generic.List[string]'

    foreach ($candidate in (Get-LocalProxyCandidates)) {
        $attempts++
        $result = Test-ProxyCandidate $candidate
        if ($result.Success) {
            Set-ProxyEnvironment $candidate
            return
        }
        if ($diagnostics.Count -lt 4) {
            $diagnostics.Add(('{0} -> {1}' -f $candidate, $result.Reason))
        }
    }

    if ($attempts -gt 0) {
        Write-WarnMsg "No working local proxy detected after trying $attempts candidate ports"
        foreach ($item in $diagnostics) {
            Write-WarnMsg "Proxy probe: $item"
        }
        Write-WarnMsg 'If your proxy uses a different port, set HTTP_PROXY/HTTPS_PROXY/ALL_PROXY manually'
    }
}

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

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Initialize-WindowsInstallMode {
    if (Test-IsElevated) {
        Write-Info 'Running with administrator privileges; Scheduled Task install is allowed'
        $script:SkipServiceInstall = $false
        return
    }

    Write-WarnMsg 'Not running as administrator. Scheduled Task install will be skipped; gateway will run in user mode'
    Write-WarnMsg 'For persistent auto-start, rerun PowerShell as Administrator and install again'
    $script:SkipServiceInstall = $true
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

function Get-NpmCommand {
    return Resolve-CliShim -BaseName 'npm' -PreferredPaths @(
        'C:\Program Files\nodejs\npm.cmd',
        'C:\Program Files (x86)\nodejs\npm.cmd'
    )
}

function Get-OpenClawCommand {
    return Resolve-CliShim -BaseName 'openclaw' -PreferredPaths @(
        'C:\Program Files\nodejs\openclaw.cmd',
        'C:\Program Files (x86)\nodejs\openclaw.cmd',
        (Join-Path $HOME '.npm-global\openclaw.cmd')
    )
}

function Invoke-Npm {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $npmCommand = Get-NpmCommand
    if ([string]::IsNullOrWhiteSpace($npmCommand)) {
        Throw-Fail 'npm.cmd not found; Node.js may not be installed correctly'
    }

    $output = & $npmCommand @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "npm failed with exit code $exitCode"
        }
        throw $message
    }

    return $output
}

function Invoke-OpenClaw {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $openclawCommand = Get-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openclawCommand)) {
        Throw-Fail 'openclaw.cmd not found; complete OpenClaw installation first'
    }

    $output = & $openclawCommand @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "openclaw failed with exit code $exitCode"
        }
        throw $message
    }

    return $output
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = @($machine, $user) -join ';'
    if (-not [string]::IsNullOrWhiteSpace($combined)) {
        $env:Path = $combined
    }
}

function Add-PathEntries([string[]]$Entries) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($existing in ($env:Path -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($existing) -and -not $parts.Contains($existing)) {
            $parts.Add($existing)
        }
    }

    foreach ($entry in ($Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($parts.Contains($entry)) {
            $parts.Remove($entry) | Out-Null
        }
        $parts.Insert(0, $entry)
    }

    $env:Path = $parts -join ';'
}

function Get-SystemNodeDirectories {
    @(
        'C:\Program Files\nodejs',
        'C:\Program Files (x86)\nodejs'
    )
}

function Get-SystemGitDirectories {
    @(
        'C:\Program Files\Git\cmd',
        'C:\Program Files\Git\bin',
        'C:\Program Files (x86)\Git\cmd',
        'C:\Program Files (x86)\Git\bin'
    )
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

function Test-ServiceSafeNodePath {
    if (-not (Test-Command 'node')) {
        return $false
    }

    $nodePath = (Get-Command node).Source
    return ($nodePath -like 'C:\Program Files\nodejs\node.exe' -or $nodePath -like 'C:\Program Files (x86)\nodejs\node.exe')
}

function Test-VersionManagerPath($PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    $normalized = $PathValue.ToLowerInvariant().Replace('/', '\')
    return $normalized.Contains('\nvm\') -or
        $normalized.Contains('\fnm\') -or
        $normalized.Contains('\volta\') -or
        $normalized.Contains('\asdf\') -or
        $normalized.Contains('\shim\') -or
        $normalized.Contains('\shims\')
}

function Prefer-SystemNodePath {
    Refresh-Path
    Add-PathEntries (Get-SystemNodeDirectories)
    if ((Get-NodeMajorVersion) -ge 22 -and (Test-ServiceSafeNodePath)) {
        Write-Info "Switched to system Node.js: $(node -v) ($((Get-Command node).Source))"
        return $true
    }

    return $false
}

function Ensure-Node {
    Prefer-SystemNodePath | Out-Null

    $major = Get-NodeMajorVersion
    $needsInstall = $false

    if ($major -ge 22) {
        if (-not (Test-ServiceSafeNodePath)) {
            Write-WarnMsg "Current Node.js path is not service-safe on Windows: $((Get-Command node).Source). Switching to system Node.js 22+"
            $needsInstall = $true
        } else {
            Write-Info "Detected Node.js $(node -v)"
        }
    } elseif ($major) {
        Write-WarnMsg "Current Node.js version is too old: $(node -v). Upgrading to 22+"
        $needsInstall = $true
    } else {
        Write-WarnMsg 'Node.js not found; installing 22+ automatically'
        $needsInstall = $true
    }

    if ($needsInstall) {
        if (Test-Command 'winget') {
            Write-Info 'Installing Node.js with winget'
            winget install --exact --id OpenJS.NodeJS --accept-source-agreements --accept-package-agreements | Out-Null
        } elseif (Test-Command 'choco') {
            Write-Info 'Installing Node.js with Chocolatey'
            choco install nodejs -y | Out-Null
        } else {
            Throw-Fail 'winget and choco were not found. Install Node.js 22+ manually first.'
        }
    }

    Refresh-Path
    Add-PathEntries (Get-SystemNodeDirectories)
    $major = Get-NodeMajorVersion
    if ($major -lt 22) {
        Throw-Fail "Node.js version is still below 22 after install: $(node -v)"
    }
    if (-not (Test-ServiceSafeNodePath)) {
        Throw-Fail "Still not using a system Node.js path: $((Get-Command node).Source)"
    }

    Write-Info "Node.js ready: $(node -v) ($((Get-Command node).Source))"
}

function Ensure-Git {
    Refresh-Path
    Add-PathEntries (Get-SystemGitDirectories)

    if (Test-Command 'git') {
        try {
            Write-Info "Detected Git $((& git --version | Select-Object -Last 1).Trim())"
        } catch {
            Write-Info 'Detected Git'
        }
        return
    }

    Write-WarnMsg 'Git not found; installing it because npm may need git to install OpenClaw dependencies'
    if (Test-Command 'winget') {
        Write-Info 'Installing Git with winget'
        winget install --exact --id Git.Git --accept-source-agreements --accept-package-agreements | Out-Null
    } elseif (Test-Command 'choco') {
        Write-Info 'Installing Git with Chocolatey'
        choco install git -y | Out-Null
    } else {
        Throw-Fail 'Git is required but winget and choco were not found. Install Git manually first.'
    }

    Refresh-Path
    Add-PathEntries (Get-SystemGitDirectories)
    if (-not (Test-Command 'git')) {
        Throw-Fail 'Git install finished, but git.exe is still not available in PATH'
    }

    try {
        Write-Info "Git ready: $((& git --version | Select-Object -Last 1).Trim())"
    } catch {
        Write-Info 'Git ready'
    }
}

function Test-NpmGitMissing([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return $Message -match 'spawn git' -or
        $Message -match 'syscall spawn git' -or
        $Message -match 'path git' -or
        $Message -match 'git error occurred'
}

function Get-InstalledOpenClawVersion {
    if ([string]::IsNullOrWhiteSpace((Get-OpenClawCommand))) {
        return ''
    }

    try {
        return ((Invoke-OpenClaw --version 2>$null) | Select-Object -Last 1).Trim()
    } catch {
        return ''
    }
}

function Get-LatestOpenClawVersion {
    if ([string]::IsNullOrWhiteSpace((Get-NpmCommand))) {
        return ''
    }

    try {
        return ((Invoke-Npm view openclaw version --silent 2>$null) | Select-Object -Last 1).Trim()
    } catch {
        return ''
    }
}

function Ensure-OpenClaw {
    Write-Info 'Installing OpenClaw'
    Refresh-Path

    $installedVersion = Get-InstalledOpenClawVersion
    $latestVersion = Get-LatestOpenClawVersion

    if ($installedVersion -and $latestVersion -and $installedVersion -eq $latestVersion) {
        $existingOpenClaw = Get-OpenClawCommand
        if (Test-VersionManagerPath $existingOpenClaw) {
            Write-WarnMsg "Detected openclaw under a version-manager path: $existingOpenClaw. Reinstalling with system npm"
        } else {
            Write-Info "Latest OpenClaw already installed: $installedVersion. Skipping install"
            return
        }
    }

    if ($installedVersion -and $latestVersion) {
        Write-Info "Local OpenClaw: $installedVersion; npm latest: $latestVersion. Upgrading"
    } elseif ($installedVersion) {
        Write-WarnMsg "OpenClaw $installedVersion is installed, but npm latest could not be confirmed. Trying upgrade"
    } else {
        Write-Info 'OpenClaw not found; installing'
    }

    try {
        Invoke-Npm install -g openclaw@latest
    } catch {
        if (-not (Test-Command 'git') -or (Test-NpmGitMissing $_.Exception.Message)) {
            Write-WarnMsg 'npm install reported a missing Git dependency; ensuring Git and retrying once'
            Ensure-Git
            Invoke-Npm install -g openclaw@latest
        } else {
            throw
        }
    }
    Refresh-Path

    if ([string]::IsNullOrWhiteSpace((Get-OpenClawCommand))) {
        Throw-Fail 'OpenClaw command not found after installation'
    }

    Write-Info "OpenClaw version: $(((Invoke-OpenClaw --version) | Select-Object -Last 1).Trim())"
}

function Prompt-ApiKey {
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        $script:ApiKey = Read-Host 'Enter NewAPI API key'
    }

    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        Throw-Fail 'API key cannot be empty'
    }

    $env:NEWAPI_API_KEY = $script:ApiKey
}

function Prompt-Model {
    if (-not [string]::IsNullOrWhiteSpace($script:ModelId)) {
        Write-Info "Using model from environment: $script:ModelId"
        return
    }

    $nonInteractive = $false
    try {
        $nonInteractive = [Console]::IsInputRedirected -or (-not [Environment]::UserInteractive)
    } catch {
        $nonInteractive = -not [Environment]::UserInteractive
    }

    if ($nonInteractive) {
        $script:ModelId = $DefaultModelId
        Write-Info "Non-interactive environment; using default model: $script:ModelId"
        return
    }

    $inputModel = Read-Host "Enter model ID (default $DefaultModelId)"
    if ([string]::IsNullOrWhiteSpace($inputModel)) {
        $script:ModelId = $DefaultModelId
    } else {
        $script:ModelId = $inputModel.Trim()
    }

    Write-Info "Using model: $script:ModelId"
}

function Test-PortListening([int]$Port) {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    }

    $output = netstat -ano | Select-String -Pattern ":$Port\s+.*LISTENING"
    return $null -ne $output
}

function Get-ConfiguredGatewayPort {
    $envFile = Join-Path $HOME '.openclaw\.env'
    if (Test-Path $envFile) {
        $line = Get-Content -Path $envFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^OPENCLAW_GATEWAY_PORT=' } | Select-Object -First 1
        if ($line) {
            $value = ($line -replace '^OPENCLAW_GATEWAY_PORT=', '').Trim()
            if ($value -match '^\d+$') {
                return [int]$value
            }
        }
    }

    $configPath = Join-Path $HOME '.openclaw\openclaw.json'
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
            if ($config.gateway.port) {
                return [int]$config.gateway.port
            }
        } catch {}
    }

    return $null
}

function Choose-GatewayPort {
    $candidate = $GatewayPort
    $maxPort = $GatewayPort + 20
    $existingPort = Get-ConfiguredGatewayPort

    if ($null -eq $GatewayPortInput -and $existingPort -and (Test-GatewayHealth)) {
        $candidate = $existingPort
    }

    while ($candidate -le $maxPort) {
        if (Test-PortListening $candidate) {
            if ($existingPort -and $candidate -eq $existingPort -and (Test-GatewayHealth)) {
                $script:GatewayPort = $candidate
                $env:OPENCLAW_PORT = [string]$candidate
                Write-Info "Detected a healthy OpenClaw gateway on port $candidate. Reusing it"
                return
            }

            Write-WarnMsg "Port $candidate is already in use; trying next port"
            $candidate++
            continue
        }

        $script:GatewayPort = $candidate
        $env:OPENCLAW_PORT = [string]$candidate
        Write-Info "Using gateway port: $candidate"
        return
    }

    Throw-Fail 'No available gateway port found. Set OPENCLAW_PORT manually'
}

function Get-ServicePath {
    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Split-Path -Parent (Get-Command node).Source),
        'C:\Program Files\nodejs',
        'C:\Program Files (x86)\nodejs',
        (Join-Path $HOME '.local\bin'),
        (Join-Path $HOME '.npm-global\bin'),
        (Join-Path $HOME 'bin'),
        (Join-Path $HOME '.bun\bin'),
        (Join-Path $HOME '.local\share\pnpm'),
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

    $filteredEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $pathEntries) {
        if (Test-VersionManagerPath $entry) { continue }
        if (-not $filteredEntries.Contains($entry)) { $filteredEntries.Add($entry) }
    }

    return ($filteredEntries -join ';')
}

function Write-ServiceEnv {
    param(
        [string]$ConfigPath = (Join-Path $HOME '.openclaw\openclaw.json')
    )

    $configHome = Join-Path $HOME '.openclaw'
    $envFile = Join-Path $configHome '.env'
    New-Item -ItemType Directory -Path $configHome -Force | Out-Null

    $stateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { $configHome }
    $servicePath = Get-ServicePath

    @(
        "PATH=$servicePath",
        "OPENCLAW_PORT=$GatewayPort",
        "OPENCLAW_GATEWAY_PORT=$GatewayPort",
        "OPENCLAW_CONFIG_PATH=$ConfigPath",
        "OPENCLAW_STATE_DIR=$stateDir",
        'NODE_COMPILE_CACHE=%TEMP%\openclaw-compile-cache',
        'OPENCLAW_NO_RESPAWN=1'
    ) | Set-Content -Path $envFile -Encoding UTF8

    Write-Info "Wrote service environment file: $envFile"
}

function Invoke-OpenClawWithServiceEnv {
    param(
        [string]$ConfigPath,
        [string]$StateDir,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $openclawPath = Get-OpenClawCommand
    $previousPath = $env:Path
    $previousPort = $env:OPENCLAW_PORT
    $previousGatewayPort = $env:OPENCLAW_GATEWAY_PORT
    $previousConfigPath = $env:OPENCLAW_CONFIG_PATH
    $previousStateDir = $env:OPENCLAW_STATE_DIR
    $previousCompileCache = $env:NODE_COMPILE_CACHE
    $previousNoRespawn = $env:OPENCLAW_NO_RESPAWN

    try {
        $env:Path = Get-ServicePath
        $env:OPENCLAW_PORT = [string]$GatewayPort
        $env:OPENCLAW_GATEWAY_PORT = [string]$GatewayPort
        $env:OPENCLAW_CONFIG_PATH = $ConfigPath
        $env:OPENCLAW_STATE_DIR = $StateDir
        $env:NODE_COMPILE_CACHE = Join-Path $env:TEMP 'openclaw-compile-cache'
        $env:OPENCLAW_NO_RESPAWN = '1'
        $output = & $openclawPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $message = ($output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = "openclaw failed with exit code $exitCode"
            }
            throw $message
        }

        return $output
    } finally {
        $env:Path = $previousPath
        $env:OPENCLAW_PORT = $previousPort
        $env:OPENCLAW_GATEWAY_PORT = $previousGatewayPort
        $env:OPENCLAW_CONFIG_PATH = $previousConfigPath
        $env:OPENCLAW_STATE_DIR = $previousStateDir
        $env:NODE_COMPILE_CACHE = $previousCompileCache
        $env:OPENCLAW_NO_RESPAWN = $previousNoRespawn
    }
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
        Write-WarnMsg "PowerShell upstream check failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-UpstreamWithNode {
    $script = @'
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
'@
    & node -e $script "$BaseUrl/models" "$ApiKey"
    return $LASTEXITCODE -eq 0
}

function Verify-UpstreamApi {
    Write-Info 'Verifying upstream NewAPI endpoint'

    if ($SkipUpstreamCheck) {
        Write-WarnMsg 'Skipped upstream check (-SkipUpstreamCheck)'
        return
    }

    if (Test-UpstreamWithPowerShell) {
        return
    }

    Write-WarnMsg 'PowerShell probe failed; retrying with Node.js TLS stack'
    if (Test-UpstreamWithNode) {
        return
    }

    Throw-Fail 'API key invalid, upstream unavailable, or local network/TLS connectivity is broken'
}

function Test-GatewayHealth {
    try {
        Invoke-OpenClaw gateway health *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    } catch {}

    $statusOutput = ''
    try {
        $statusOutput = (Invoke-OpenClaw gateway status --deep 2>&1 | Out-String)
    } catch {
        $statusOutput = ($_ | Out-String)
    }

    return $statusOutput -match 'RPC probe:\s+ok'
}

function Test-ServiceInstallAccessDenied([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return $Message -match 'Access is denied' -or
        $Message -match '拒绝访问' -or
        $Message -match 'schtasks create failed'
}

function Start-GatewayWithoutService {
    param(
        [string]$ConfigPath,
        [string]$StateDir
    )

    $openclawPath = Get-OpenClawCommand
    if ([string]::IsNullOrWhiteSpace($openclawPath)) {
        Throw-Fail 'openclaw.cmd not found; cannot start gateway in no-service mode'
    }

    $stdoutLog = Join-Path $env:TEMP 'openclaw-gateway-stdout.log'
    $stderrLog = Join-Path $env:TEMP 'openclaw-gateway-stderr.log'
    Remove-Item -Path $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    $previousPath = $env:Path
    $previousPort = $env:OPENCLAW_PORT
    $previousGatewayPort = $env:OPENCLAW_GATEWAY_PORT
    $previousConfigPath = $env:OPENCLAW_CONFIG_PATH
    $previousStateDir = $env:OPENCLAW_STATE_DIR
    $previousCompileCache = $env:NODE_COMPILE_CACHE
    $previousNoRespawn = $env:OPENCLAW_NO_RESPAWN

    try {
        $env:Path = Get-ServicePath
        $env:OPENCLAW_PORT = [string]$GatewayPort
        $env:OPENCLAW_GATEWAY_PORT = [string]$GatewayPort
        $env:OPENCLAW_CONFIG_PATH = $ConfigPath
        $env:OPENCLAW_STATE_DIR = $StateDir
        $env:NODE_COMPILE_CACHE = Join-Path $env:TEMP 'openclaw-compile-cache'
        $env:OPENCLAW_NO_RESPAWN = '1'

        Write-WarnMsg 'Starting gateway in no-service user mode'
        $commandLine = "`"$openclawPath`" gateway run --port $GatewayPort --bind loopback 1>> `"$stdoutLog`" 2>> `"$stderrLog`""
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $commandLine) -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 5
    } finally {
        $env:Path = $previousPath
        $env:OPENCLAW_PORT = $previousPort
        $env:OPENCLAW_GATEWAY_PORT = $previousGatewayPort
        $env:OPENCLAW_CONFIG_PATH = $previousConfigPath
        $env:OPENCLAW_STATE_DIR = $previousStateDir
        $env:NODE_COMPILE_CACHE = $previousCompileCache
        $env:OPENCLAW_NO_RESPAWN = $previousNoRespawn
    }

    if (-not (Test-GatewayHealth)) {
        if (Test-Path $stderrLog) {
            Get-Content -Path $stderrLog -TotalCount 120 | Out-Host
        }
        if (Test-Path $stdoutLog) {
            Get-Content -Path $stdoutLog -TotalCount 120 | Out-Host
        }
    }
}

function Invoke-GatewayForegroundProbe {
    $probeLog = Join-Path $env:TEMP 'openclaw-gateway-foreground.log'
    Write-WarnMsg 'Background gateway is still not healthy; trying one foreground run to capture the first error'

    if (Test-Path $probeLog) {
        Remove-Item $probeLog -Force -ErrorAction SilentlyContinue
    }

    $job = Start-Job -ScriptBlock {
        param($Port, $ProbeLog)
        Invoke-OpenClaw gateway run --port $Port --bind loopback --verbose *> $ProbeLog
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
    Write-WarnMsg 'Collecting gateway diagnostics'

    try { Invoke-OpenClaw config get gateway.mode } catch {}
    try { Invoke-OpenClaw config get gateway.bind } catch {}
    try { Invoke-OpenClaw config get gateway.port } catch {}
    try { Invoke-OpenClaw gateway status --deep } catch { try { Invoke-OpenClaw gateway status } catch {} }
    try { Invoke-OpenClaw status --all } catch {}
    try { Invoke-OpenClaw logs --limit 200 --plain } catch {}

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue
        if (-not $listener) {
            Invoke-GatewayForegroundProbe
        }
    }
}

function Repair-GatewayService {
    $configPath = Get-ConfigPath
    $stateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { Join-Path $HOME '.openclaw' }

    Write-WarnMsg 'Gateway health check failed; trying openclaw doctor --fix'
    try { Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir doctor --fix } catch { try { Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir doctor --yes } catch {} }
    if ($script:SkipServiceInstall) {
        Start-GatewayWithoutService -ConfigPath $configPath -StateDir $stateDir
        return
    } else {
        try {
            Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway install --runtime node --port $GatewayPort --force
        } catch {
            if (Test-ServiceInstallAccessDenied $_.Exception.Message) {
                Start-GatewayWithoutService -ConfigPath $configPath -StateDir $stateDir
                return
            }
            throw
        }
    }
    try {
        Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway restart
    } catch {
        Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway start
    }
    Start-Sleep -Seconds 3
}

function Install-AndStartGateway {
    $configPath = Get-ConfigPath
    $stateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { Join-Path $HOME '.openclaw' }

    Write-Info 'Installing and starting gateway'
    $serviceInstallOk = -not $script:SkipServiceInstall
    if (-not $script:SkipServiceInstall) {
        try {
            Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway install --runtime node --port $GatewayPort --force
        } catch {
            if (Test-ServiceInstallAccessDenied $_.Exception.Message) {
                $serviceInstallOk = $false
            } else {
                throw
            }
        }
    }

    if ($serviceInstallOk) {
        try {
            Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway restart
        } catch {
            Invoke-OpenClawWithServiceEnv -ConfigPath $configPath -StateDir $stateDir gateway start
        }
    } else {
        Start-GatewayWithoutService -ConfigPath $configPath -StateDir $stateDir
    }
    Start-Sleep -Seconds 3

    if (-not (Test-GatewayHealth)) {
        Repair-GatewayService
    }

    if (-not (Test-GatewayHealth)) {
        Show-GatewayDiagnostics
        Throw-Fail 'Gateway is still not ready. Run openclaw gateway status --deep and openclaw logs --follow first'
    }

    try { Invoke-OpenClaw gateway status } catch {}
}

function Get-ConfigPath {
    try {
        $lines = Invoke-OpenClaw config file 2>$null
        $last = ($lines | Select-Object -Last 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($last)) {
            if ($last.StartsWith('~/') -or $last.StartsWith('~\')) {
                return (Join-Path $HOME ($last.Substring(2) -replace '/', '\'))
            }
            if ($last.StartsWith('$HOME/')) {
                return (Join-Path $HOME ($last.Substring(6) -replace '/', '\'))
            }
            if ($last.StartsWith('$HOME\')) {
                return (Join-Path $HOME $last.Substring(6))
            }
            return $last
        }
    } catch {}

    return (Join-Path $HOME '.openclaw\openclaw.json')
}

function Ensure-OpenClawBootstrap {
    $configHome = Join-Path $HOME '.openclaw'
    $hasConfig = (Test-Path $configHome) -and ((Get-ChildItem -Path $configHome -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)

    if ($hasConfig) {
        Write-Info 'Existing OpenClaw config detected; skipping onboard'
    } else {
        Write-Info 'Running non-interactive OpenClaw bootstrap'
        try {
            Invoke-OpenClaw onboard --non-interactive --accept-risk --mode local --auth-choice custom-api-key --custom-provider-id $ProviderId --custom-compatibility openai --custom-base-url $BaseUrl --custom-model-id $ModelId --custom-api-key $ApiKey --gateway-port $GatewayPort --gateway-bind loopback --skip-daemon --skip-health --skip-skills
        } catch {
            Write-WarnMsg 'Non-interactive onboard failed; falling back to minimal initialization'
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

    Write-Info "Writing OpenClaw config: $configPath"

    $nodeScript = @'
const fs = require('fs');
const crypto = require('crypto');
const [configPath, apiKey, baseUrl, providerId, modelId, modelName, gatewayPort, enableBrowserToolRaw] = process.argv.slice(1);
const enableBrowserTool = enableBrowserToolRaw === '1';
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
config.gateway.auth = config.gateway.auth || {};
if (typeof config.gateway.auth.token !== 'string' || !config.gateway.auth.token.trim()) {
  config.gateway.auth.token = crypto.randomBytes(24).toString('hex');
}
if (!config.gateway.auth.mode || (config.gateway.auth.mode === 'password' && !config.gateway.auth.password)) {
  config.gateway.auth.mode = 'token';
}
config.tools = config.tools || {};
const denyList = Array.isArray(config.tools.deny) ? config.tools.deny.filter((entry) => typeof entry === 'string' && entry.trim()) : [];
const denySet = new Set(denyList);
if (enableBrowserTool) {
  denySet.delete('browser');
} else {
  denySet.add('browser');
}
config.tools.deny = Array.from(denySet);
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
'@

    & node -e $nodeScript $configPath $ApiKey $BaseUrl $ProviderId $ModelId "$ModelId (newapi)" $GatewayPort $(if ($EnableBrowserTool) { '1' } else { '0' })
}

function Get-GatewayToken([string]$ConfigPath) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path $ConfigPath)) {
        return $null
    }

    $nodeScript = @'
const fs = require('fs');
const configPath = process.argv[1];
try {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const token = config && config.gateway && config.gateway.auth && config.gateway.auth.token;
  if (typeof token === 'string' && token.trim()) {
    process.stdout.write(token.trim());
  }
} catch {}
'@

    $token = (& node -e $nodeScript $ConfigPath 2>$null | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    return $token
}

function Open-Dashboard([string]$ConfigPath) {
    $stateDir = if ($env:OPENCLAW_STATE_DIR) { $env:OPENCLAW_STATE_DIR } else { Join-Path $HOME '.openclaw' }
    $dashboardOutput = ''
    try {
        $dashboardOutput = (Invoke-OpenClawWithServiceEnv -ConfigPath $ConfigPath -StateDir $stateDir dashboard 2>&1 | Out-String)
    } catch {
        $dashboardOutput = ($_ | Out-String)
    }

    $dashboardUrl = $null
    $match = [regex]::Match($dashboardOutput, 'https?://\S+')
    if ($match.Success) {
        $dashboardUrl = $match.Value.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($dashboardUrl)) {
        $dashboardUrl = "http://127.0.0.1:$GatewayPort/"
    }

    try {
        Start-Process $dashboardUrl | Out-Null
    } catch {}

    Write-Info "Control UI: $dashboardUrl"
    $token = Get-GatewayToken $ConfigPath
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        Write-Info "Gateway token: $token"
        Write-WarnMsg 'If the UI shows unauthorized, paste the gateway token above into Control UI settings'
    }
}

function Validate-OpenClaw {
    Write-Info 'Validating OpenClaw config'
    Invoke-OpenClaw config validate
}

function Probe-Provider {
    Write-Info 'Probing provider/model availability'
    try {
        Invoke-OpenClaw models status --probe --probe-provider $ProviderId --json
    } catch {
        Write-WarnMsg 'Model probe failed. Check network, API key, or upstream model permissions'
    }
}

function Remove-PathSafe([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return }
    if (Test-Path $PathValue) {
        Remove-Item -Path $PathValue -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-OpenClawPackage {
    $npmCandidates = New-Object System.Collections.Generic.List[string]

    $resolvedNpm = Get-NpmCommand
    if (-not [string]::IsNullOrWhiteSpace($resolvedNpm)) {
        $npmCandidates.Add($resolvedNpm)
    }

    foreach ($candidate in @(
        'C:\Program Files\nodejs\npm.cmd',
        'C:\Program Files (x86)\nodejs\npm.cmd'
    )) {
        if ((Test-Path $candidate) -and (-not $npmCandidates.Contains($candidate))) {
            $npmCandidates.Add($candidate)
        }
    }

    foreach ($npmBin in $npmCandidates) {
        & $npmBin uninstall -g openclaw *> $null
    }

    foreach ($pathValue in @(
        'C:\Program Files\nodejs\openclaw.cmd',
        'C:\Program Files\nodejs\openclaw',
        (Join-Path $HOME '.npm-global\openclaw.cmd'),
        (Join-Path $HOME '.npm-global\openclaw')
    )) {
        Remove-PathSafe $pathValue
    }
}

function Remove-GatewayTask {
    foreach ($taskName in @('OpenClaw Gateway')) {
        if (Test-Command 'schtasks') {
            schtasks /Delete /TN $taskName /F *> $null
        }
    }

    Remove-PathSafe (Join-Path $HOME '.openclaw\gateway.cmd')
}

function Remove-OpenClawState {
    Remove-PathSafe (Join-Path $HOME '.openclaw')

    foreach ($pattern in @(
        (Join-Path $env:TEMP 'openclaw'),
        (Join-Path $env:TEMP 'openclaw-*'),
        (Join-Path $env:TEMP 'openclaw_home_*'),
        (Join-Path $env:TEMP 'openclaw_gateway_*')
    )) {
        Remove-Item -Path $pattern -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ScriptInstalledNode {
    if (-not (Test-ServiceSafeNodePath)) {
        return
    }

    if (Test-Command 'winget') {
        winget uninstall --exact --id OpenJS.NodeJS --accept-source-agreements *> $null
    } elseif (Test-Command 'choco') {
        choco uninstall nodejs -y *> $null
    }
}

function Invoke-Uninstall {
    Write-Info 'Removing OpenClaw and script-created environment'
    Remove-GatewayTask
    Remove-OpenClawPackage
    Remove-OpenClawState
    Remove-ScriptInstalledNode
    Write-Info 'Uninstall complete'
}

if (-not ($PSVersionTable -and ($env:OS -eq 'Windows_NT'))) {
    Throw-Fail 'This script targets Windows PowerShell / PowerShell on Windows. Use install_openclaw.sh for macOS/Linux/WSL2.'
}

Initialize-ConsoleEncoding
Initialize-WindowsInstallMode
Initialize-Proxy

if ($Uninstall) {
    Invoke-Uninstall
    exit 0
}

Prompt-ApiKey
Prompt-Model
Ensure-Node
Ensure-Git
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
Open-Dashboard -ConfigPath $configPath

Write-Host ''
Write-Host 'Install complete.' -ForegroundColor Green
Write-Host '- OpenClaw installed and initialized'
Write-Host "- Gateway port: $GatewayPort"
Write-Host "- Provider: $ProviderId"
Write-Host "- Model: $ModelId"
Write-Host "- Browser tool: $(if ($EnableBrowserTool) { 'enabled' } else { 'disabled (set OPENCLAW_ENABLE_BROWSER_TOOL=0 to keep it off)' })"
Write-Host "- Dashboard: http://127.0.0.1:$GatewayPort/"
Write-Host "- Gateway token: $(if ($token = Get-GatewayToken $configPath) { $token } else { 'not read; run openclaw config get gateway.auth.token' })"
Write-Host ''
Write-Host 'Manual tests:'
Write-Host '  openclaw gateway status --deep'
Write-Host '  openclaw logs --follow'
