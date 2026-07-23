#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Node,
    [string]$SingBoxPath,
    [switch]$IPv4,
    [switch]$IPv6,
    [switch]$FullIP,
    [switch]$Json,
    [string]$Output,
    [switch]$Force,
    [switch]$Lite,
    [switch]$NoRisk,
    [switch]$NoMedia,
    [switch]$NoMail,
    [switch]$NoDnsbl,
    [switch]$ValidateOnly,
    [ValidateRange(2, 60)][int]$TimeoutSeconds = 10,
    [ValidateRange(1, 100)][int]$DnsblConcurrency = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-Base64Url {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = [Uri]::UnescapeDataString($Value).Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
        1 { throw '无效的 Base64URL 长度' }
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
}

function Split-HostPort {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match '^\[(?<host>[^\]]+)\]:(?<port>\d+)$') {
        return [pscustomobject]@{ Host = $Matches.host; Port = [int]$Matches.port }
    }
    $separator = $Value.LastIndexOf(':')
    if ($separator -le 0) {
        throw '节点缺少服务器端口'
    }
    $hostName = $Value.Substring(0, $separator)
    $portText = $Value.Substring($separator + 1)
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw '节点服务器端口无效'
    }
    return [pscustomobject]@{ Host = $hostName; Port = $port }
}

function ConvertFrom-ShadowsocksUri {
    param([Parameter(Mandatory)][string]$Uri)

    if (-not $Uri.StartsWith('ss://', [StringComparison]::OrdinalIgnoreCase)) {
        throw '当前节点启动器只支持 ss://。HTTP/SOCKS 代理请直接使用 IPQuality.ps1 -Proxy。'
    }

    $payload = $Uri.Substring(5)
    $fragmentIndex = $payload.IndexOf('#')
    if ($fragmentIndex -ge 0) {
        $payload = $payload.Substring(0, $fragmentIndex)
    }
    $query = ''
    $queryIndex = $payload.IndexOf('?')
    if ($queryIndex -ge 0) {
        $query = $payload.Substring($queryIndex + 1)
        $payload = $payload.Substring(0, $queryIndex)
    }
    if ($query -match '(^|&)plugin=') {
        throw '暂不支持带 SIP003 plugin 的 Shadowsocks 节点。'
    }

    $methodPassword = ''
    $hostPortText = ''
    $atIndex = $payload.LastIndexOf('@')
    if ($atIndex -ge 0) {
        $encodedUserInfo = $payload.Substring(0, $atIndex)
        $hostPortText = $payload.Substring($atIndex + 1)
        try {
            $methodPassword = ConvertFrom-Base64Url $encodedUserInfo
        }
        catch {
            $methodPassword = [Uri]::UnescapeDataString($encodedUserInfo)
        }
    }
    else {
        $decoded = ConvertFrom-Base64Url $payload
        $decodedAtIndex = $decoded.LastIndexOf('@')
        if ($decodedAtIndex -lt 1) {
            throw '旧式 ss:// 内容缺少服务器地址'
        }
        $methodPassword = $decoded.Substring(0, $decodedAtIndex)
        $hostPortText = $decoded.Substring($decodedAtIndex + 1)
    }

    $credentialSeparator = $methodPassword.IndexOf(':')
    if ($credentialSeparator -lt 1) {
        throw '节点缺少加密方法或密码'
    }
    $method = $methodPassword.Substring(0, $credentialSeparator)
    $password = $methodPassword.Substring($credentialSeparator + 1)
    if (-not $password) {
        throw '节点密码为空'
    }
    $server = Split-HostPort ([Uri]::UnescapeDataString($hostPortText).TrimEnd('/'))

    [pscustomobject]@{
        Method = $method
        Password = $password
        Server = $server.Host
        ServerPort = $server.Port
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($identity.User)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security
}

$nodeConfig = ConvertFrom-ShadowsocksUri -Uri $Node
if ($ValidateOnly) {
    [pscustomobject]@{
        Scheme = 'ss'
        Method = $nodeConfig.Method
        Server = $nodeConfig.Server
        ServerPort = $nodeConfig.ServerPort
        PasswordLength = $nodeConfig.Password.Length
    }
    return
}
if ($SingBoxPath) {
    $singBoxPath = [IO.Path]::GetFullPath($SingBoxPath)
    if (-not (Test-Path -LiteralPath $singBoxPath -PathType Leaf)) {
        throw "指定的 sing-box 不存在：$singBoxPath"
    }
    $versionText = & $singBoxPath version 2>$null | Select-Object -First 1
    if ("$versionText" -notmatch 'sing-box') {
        throw "指定文件不是有效的 sing-box：$singBoxPath"
    }
}
else {
    $singBoxPath = & (Join-Path $PSScriptRoot 'Install-SingBox.ps1')
}
$port = Get-FreeTcpPort
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "ipquality-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    Set-PrivateDirectoryAcl -Path $temporaryRoot
    $configPath = Join-Path $temporaryRoot 'config.json'

    $configuration = [ordered]@{
        log = [ordered]@{
            level = 'warn'
            timestamp = $true
        }
        inbounds = @(
            [ordered]@{
                type = 'socks'
                tag = 'socks-in'
                listen = '127.0.0.1'
                listen_port = $port
            }
        )
        outbounds = @(
            [ordered]@{
                type = 'shadowsocks'
                tag = 'ss-out'
                server = $nodeConfig.Server
                server_port = $nodeConfig.ServerPort
                method = $nodeConfig.Method
                password = $nodeConfig.Password
            }
        )
        route = [ordered]@{
            final = 'ss-out'
            auto_detect_interface = $true
        }
    }
    [IO.File]::WriteAllText(
        $configPath,
        ($configuration | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}
catch {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    throw
}

$process = $null
try {
    & $singBoxPath check -c $configPath
    if ($LASTEXITCODE -ne 0) {
        throw 'sing-box 配置检查失败'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $singBoxPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('run')
    [void]$startInfo.ArgumentList.Add('-c')
    [void]$startInfo.ArgumentList.Add($configPath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            break
        }
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connectTask = $client.ConnectAsync('127.0.0.1', $port)
            if ($connectTask.Wait(300) -and $client.Connected) {
                $ready = $true
                break
            }
        }
        catch {
        }
        finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 150
    }
    if (-not $ready) {
        $errorText = if ($process.HasExited) { $stderrTask.GetAwaiter().GetResult().Trim() } else { '本地 SOCKS 端口未就绪' }
        throw "sing-box 启动失败：$errorText"
    }

    Write-Host "临时 Shadowsocks 隧道已就绪（127.0.0.1:$port），开始检测。" -ForegroundColor Green
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'IPQuality.ps1'), '-Proxy', "socks5h://127.0.0.1:$port")) {
        $arguments.Add($argument)
    }
    foreach ($switchEntry in ([ordered]@{
        '-IPv4' = $IPv4
        '-IPv6' = $IPv6
        '-FullIP' = $FullIP
        '-Json' = $Json
        '-Force' = $Force
        '-Lite' = $Lite
        '-NoRisk' = $NoRisk
        '-NoMedia' = $NoMedia
        '-NoMail' = $NoMail
        '-NoDnsbl' = $NoDnsbl
    }).GetEnumerator()) {
        if ($switchEntry.Value) {
            $arguments.Add($switchEntry.Key)
        }
    }
    if ($Output) {
        $arguments.Add('-Output')
        $arguments.Add($Output)
    }
    $arguments.Add('-TimeoutSeconds')
    $arguments.Add([string]$TimeoutSeconds)
    $arguments.Add('-DnsblConcurrency')
    $arguments.Add([string]$DnsblConcurrency)

    & (Join-Path $PSHOME 'pwsh.exe') @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "IPQuality 检测失败，退出码 $LASTEXITCODE"
    }
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(3000)
            }
            catch {
            }
        }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
