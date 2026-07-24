#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$IPv4,
    [switch]$IPv6,
    [switch]$Direct,
    [string]$Proxy,
    [switch]$FullIP,
    [switch]$Lite,
    [switch]$NoRisk,
    [switch]$NoMedia,
    [switch]$NoMail,
    [switch]$NoDnsbl,
    [switch]$NoSave,
    [string]$Output,
    [ValidateRange(2, 60)][int]$TimeoutSeconds = 10,
    [ValidateRange(1, 100)][int]$DnsblConcurrency = 40,
    [ValidateRange(8, 32)][int]$ConsoleFontSize = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($IPv4 -and $IPv6) {
    throw 'IPv4 与 IPv6 不能同时指定。分别运行两次可得到更清晰的单窗口报告。'
}
if ($Direct -and $Proxy) {
    throw '-Direct 与 -Proxy 不能同时使用。'
}
if ($NoSave -and $Output) {
    throw '-NoSave 与 -Output 不能同时使用。'
}

function Get-IPQProxyDisplayName {
    param([Parameter(Mandatory)][string]$Value)

    $uri = [Uri]$Value
    $hostText = if ($uri.HostNameType -eq [UriHostNameType]::IPv6) {
        "[$($uri.Host)]"
    }
    else {
        $uri.Host
    }
    return "$($uri.Scheme)://${hostText}:$($uri.Port)"
}

function Test-IPQLocalProxyPort {
    param([Parameter(Mandatory)][Uri]$Uri)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Uri.DnsSafeHost, $Uri.Port)
        return $task.Wait(500) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Test-IPQProxyCandidate {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet(4, 6)][int]$AddressFamily
    )

    $uri = $null
    if (
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h') -or
        $uri.Port -lt 1
    ) {
        return $null
    }
    if (-not (Test-IPQLocalProxyPort -Uri $uri)) {
        return $null
    }

    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    $arguments = @(
        '--silent',
        '--show-error',
        '--max-time', '6',
        '--proxy', $Value,
        $(if ($AddressFamily -eq 4) { '--ipv4' } else { '--ipv6' }),
        'https://api64.ipify.org'
    )
    $address = (& $curl @arguments 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$parsed)) {
        return $null
    }
    $expectedFamily = if ($AddressFamily -eq 4) {
        [Net.Sockets.AddressFamily]::InterNetwork
    }
    else {
        [Net.Sockets.AddressFamily]::InterNetworkV6
    }
    if ($parsed.AddressFamily -ne $expectedFamily) {
        return $null
    }
    return [pscustomobject]@{
        Proxy = $Value
        Address = $parsed.ToString()
    }
}

function Find-IPQCurrentProxy {
    param([ValidateSet(4, 6)][int]$AddressFamily)

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        # Local DNS resolution makes curl's -4/-6 selection deterministic.
        # socks5h may let the proxy resolve an IPv4 probe hostname to IPv6.
        'socks5://127.0.0.1:7890',
        'socks5h://127.0.0.1:7890',
        [Environment]::GetEnvironmentVariable('ALL_PROXY'),
        [Environment]::GetEnvironmentVariable('HTTPS_PROXY'),
        [Environment]::GetEnvironmentVariable('HTTP_PROXY'),
        'http://127.0.0.1:7890',
        'socks5://127.0.0.1:10808',
        'socks5h://127.0.0.1:10808',
        'http://127.0.0.1:10809',
        'socks5://127.0.0.1:1080',
        'socks5h://127.0.0.1:1080'
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidates.Add($candidate.Trim())
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in $candidates) {
        if (-not $seen.Add($candidate)) {
            continue
        }
        $result = Test-IPQProxyCandidate -Value $candidate -AddressFamily $AddressFamily
        if ($null -ne $result) {
            return $result
        }
    }
    return $null
}

function Protect-IPQLauncherAddress {
    param([Parameter(Mandatory)][string]$Address)

    $parsed = [Net.IPAddress]::Parse($Address)
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $parts = $Address.Split('.')
        return "$($parts[0]).$($parts[1]).*.*"
    }
    $groups = $parsed.ToString().Split(':')
    $visible = [Math]::Min(3, $groups.Count)
    return (($groups[0..($visible - 1)] -join ':') + ':*:*:*:*:*')
}

$family = if ($IPv6) { 6 } else { 4 }
$selectedProxy = $Proxy
if (-not $Direct -and -not $selectedProxy) {
    Write-Host '正在识别当前节点的本地代理...' -ForegroundColor Cyan
    $detected = Find-IPQCurrentProxy -AddressFamily $family
    if ($null -eq $detected) {
        throw '没有找到可用的当前节点代理。请先在 v2rayN 中启用节点，或显式使用 -Proxy；测本地直连请使用 -Direct。'
    }
    $selectedProxy = $detected.Proxy
    Write-Host "当前节点代理：$(Get-IPQProxyDisplayName $selectedProxy)" -ForegroundColor Green
    Write-Host "预检出口：$(Protect-IPQLauncherAddress $detected.Address)" -ForegroundColor Green
}
elseif ($selectedProxy) {
    $validated = Test-IPQProxyCandidate -Value $selectedProxy -AddressFamily $family
    if ($null -eq $validated) {
        throw "代理不可用：$(Get-IPQProxyDisplayName $selectedProxy)"
    }
    Write-Host "指定代理：$(Get-IPQProxyDisplayName $selectedProxy)" -ForegroundColor Green
    Write-Host "预检出口：$(Protect-IPQLauncherAddress $validated.Address)" -ForegroundColor Green
}
else {
    Write-Host '检测路径：本机直连' -ForegroundColor Yellow
}

if (-not $NoSave -and -not $Output) {
    $reportsDirectory = Join-Path $PSScriptRoot 'reports'
    if (-not (Test-Path -LiteralPath $reportsDirectory)) {
        [void](New-Item -ItemType Directory -Path $reportsDirectory -Force)
    }
    $Output = Join-Path $reportsDirectory "ipq-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-ipv$family.json"
}

$invokeParameters = @{
    TimeoutSeconds = $TimeoutSeconds
    DnsblConcurrency = $DnsblConcurrency
    ConsoleFontSize = $ConsoleFontSize
}
$invokeParameters[$(if ($family -eq 4) { 'IPv4' } else { 'IPv6' })] = $true
if ($selectedProxy) {
    $invokeParameters.Proxy = $selectedProxy
}
foreach ($entry in ([ordered]@{
    FullIP = $FullIP
    Lite = $Lite
    NoRisk = $NoRisk
    NoMedia = $NoMedia
    NoMail = $NoMail
    NoDnsbl = $NoDnsbl
}).GetEnumerator()) {
    if ($entry.Value) {
        $invokeParameters[$entry.Key] = $true
    }
}
if ($Output) {
    $invokeParameters.Output = [IO.Path]::GetFullPath($Output)
}

& (Join-Path $PSScriptRoot 'IPQuality.ps1') @invokeParameters
