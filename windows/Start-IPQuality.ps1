#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('4')][switch]$IPv4,
    [Alias('6')][switch]$IPv6,
    [switch]$DualStack,
    [switch]$Direct,
    [Alias('x')][string]$Proxy,
    [Alias('i')][string]$Interface,
    [Alias('f')][switch]$FullIP,
    [Alias('j')][switch]$Json,
    [Alias('l')][ValidateSet('cn','en','jp','es','de','fr','ru','pt')][string]$Language = 'cn',
    [Alias('E')][switch]$English,
    [Alias('p')][switch]$Privacy,
    [switch]$AllowOnlineReport,
    [switch]$UpstreamJson,
    [Alias('h')][switch]$Help,
    [Alias('M')][switch]$Menu,
    [switch]$ShowSponsors,
    [switch]$CountRun,
    [Alias('n')][switch]$NoDependencyCheck,
    [Alias('y')][switch]$InstallDependencies,
    [switch]$Lite,
    [switch]$NoRisk,
    [switch]$NoMedia,
    [switch]$NoMail,
    [switch]$NoDnsbl,
    [switch]$NoSave,
    [Alias('o')][string]$Output,
    [switch]$Force,
    [ValidateRange(2, 60)][int]$TimeoutSeconds = 10,
    [ValidateRange(1, 100)][int]$DnsblConcurrency = 40,
    [ValidateRange(8, 32)][int]$ConsoleFontSize = 18
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Help) { & (Join-Path $PSScriptRoot 'IPQuality.ps1') -Help; return }
if ($Menu) { & (Join-Path $PSScriptRoot 'Show-IPQualityMenu.ps1'); return }
if ($ShowSponsors) { & (Join-Path $PSScriptRoot 'IPQuality.ps1') -ShowSponsors; return }
if ($UpstreamJson) { $Json = $true }
if ($Json) { $InformationPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue' }
function Write-IPQLauncherStatus {
    param([string]$Text, [ConsoleColor]$ForegroundColor)
    if (-not $Json) { Write-Host $Text -ForegroundColor $ForegroundColor }
}
if ($Privacy -and $AllowOnlineReport) { throw '-Privacy 与 -AllowOnlineReport 不能同时使用。' }
if ($DualStack -and ($IPv4 -or $IPv6)) { throw '-DualStack 与 -IPv4/-IPv6 不能同时使用。' }
if ($DualStack -and -not $Json -and -not [Console]::IsOutputRedirected) { throw '双栈用于 JSON 或重定向输出；可见窗口请分别检测 IPv4、IPv6。' }
if ($Interface -and -not $Direct) { throw '指定本机源地址/接口时请同时使用 -Direct，避免自动代理改变检测路径。' }

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
    $addressEndpoint = if ($AddressFamily -eq 4) {
        'https://api.ipify.org'
    }
    else {
        'https://api6.ipify.org'
    }
    $arguments = @(
        '--silent',
        '--show-error',
        '--max-time', '6',
        '--proxy', $Value,
        $(if ($AddressFamily -eq 4) { '--ipv4' } else { '--ipv6' }),
        $addressEndpoint
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
        # Prefer proxy-side DNS for the same routing semantics as the upstream
        # -x mode. Family-specific probe hosts keep IPv4/IPv6 deterministic.
        'socks5h://127.0.0.1:7890',
        'socks5://127.0.0.1:7890',
        [Environment]::GetEnvironmentVariable('ALL_PROXY'),
        [Environment]::GetEnvironmentVariable('HTTPS_PROXY'),
        [Environment]::GetEnvironmentVariable('HTTP_PROXY'),
        'http://127.0.0.1:7890',
        'socks5h://127.0.0.1:10808',
        'socks5://127.0.0.1:10808',
        'http://127.0.0.1:10809',
        'socks5h://127.0.0.1:1080',
        'socks5://127.0.0.1:1080'
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
    Write-IPQLauncherStatus '正在识别当前节点的本地代理...' -ForegroundColor Cyan
    $detected = Find-IPQCurrentProxy -AddressFamily $family
    if ($null -eq $detected) {
        throw '没有找到可用的当前节点代理。请先在 v2rayN 中启用节点，或显式使用 -Proxy；测本地直连请使用 -Direct。'
    }
    $selectedProxy = $detected.Proxy
    Write-IPQLauncherStatus "当前节点代理：$(Get-IPQProxyDisplayName $selectedProxy)" -ForegroundColor Green
    Write-IPQLauncherStatus "预检出口：$(Protect-IPQLauncherAddress $detected.Address)" -ForegroundColor Green
}
elseif ($selectedProxy) {
    $validated = Test-IPQProxyCandidate -Value $selectedProxy -AddressFamily $family
    if ($null -eq $validated) {
        throw "代理不可用：$(Get-IPQProxyDisplayName $selectedProxy)"
    }
    Write-IPQLauncherStatus "指定代理：$(Get-IPQProxyDisplayName $selectedProxy)" -ForegroundColor Green
    Write-IPQLauncherStatus "预检出口：$(Protect-IPQLauncherAddress $validated.Address)" -ForegroundColor Green
}
else {
    Write-IPQLauncherStatus '检测路径：本机直连' -ForegroundColor Yellow
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
    Language = $Language
}
if (-not $DualStack) { $invokeParameters[$(if ($family -eq 4) { 'IPv4' } else { 'IPv6' })] = $true }
if ($Interface) { $invokeParameters.Interface = $Interface }
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
    Json = $Json
    English = $English
    Privacy = $Privacy
    AllowOnlineReport = $AllowOnlineReport
    UpstreamJson = $UpstreamJson
    NoDependencyCheck = $NoDependencyCheck
    InstallDependencies = $InstallDependencies
    Force = $Force
    CountRun = $CountRun
}).GetEnumerator()) {
    if ($entry.Value) {
        $invokeParameters[$entry.Key] = $true
    }
}
if ($Output) {
    $invokeParameters.Output = [IO.Path]::GetFullPath($Output)
}

& (Join-Path $PSScriptRoot 'IPQuality.ps1') @invokeParameters
