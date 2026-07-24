#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$Online
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][string]$Message
    )
    if ("$Actual" -ne "$Expected") {
        throw "$Message。期望：$Expected；实际：$Actual"
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $windowsRoot 'IPQuality.psm1'
Import-Module $modulePath -Force
$module = Get-Module IPQuality
$entryScript = Get-Content -Raw (Join-Path $windowsRoot 'IPQuality.ps1')
$launcherScript = Get-Content -Raw (Join-Path $windowsRoot 'Start-IPQuality.ps1')

Assert-True (
    $entryScript -match '\[int\]\$ConsoleFontSize\s*=\s*22'
) '底层入口的默认控制台字号应固定为 22'
Assert-True (
    $launcherScript -match '\[int\]\$ConsoleFontSize\s*=\s*22'
) '日常启动器的默认控制台字号应固定为 22'
$localDnsSocksIndex = $launcherScript.IndexOf(
    "'socks5://127.0.0.1:7890'",
    [StringComparison]::Ordinal
)
$remoteDnsSocksIndex = $launcherScript.IndexOf(
    "'socks5h://127.0.0.1:7890'",
    [StringComparison]::Ordinal
)
Assert-True (
    $localDnsSocksIndex -ge 0 -and
    $remoteDnsSocksIndex -ge 0 -and
    $localDnsSocksIndex -lt $remoteDnsSocksIndex
) 'IPv4/IPv6 预检应先使用可严格控制地址族的本地 DNS SOCKS5'
Assert-True (
    $entryScript -match '\$targetWidth\s*=\s*\[Math\]::Min\(74,'
) '标准控制台宽度应固定为 74 列'
Assert-True (
    $entryScript -match '\$targetHeight\s*=\s*\[Math\]::Min\(47,'
) '标准控制台高度应固定为 47 行'
Assert-True (
    $entryScript -notmatch 'Write-Host\s+"报告已保存'
) '保存提示不得额外占用报告正文行'

$parserErrors = 0
foreach ($file in (Get-ChildItem -LiteralPath $windowsRoot -Recurse -Include *.ps1, *.psm1 -File)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $parserErrors += $errors.Count
}
Assert-Equal $parserErrors 0 '所有 PowerShell 文件应通过语法解析'

& $module {
    $sample = [pscustomobject]@{
        nested = [pscustomobject]@{
            values = @([pscustomobject]@{ id = 7 })
        }
    }
    if ((Get-IPQValue $sample 'nested.values.0.id') -ne 7) {
        throw '嵌套数组路径解析失败'
    }
    if ((Protect-IPQAddress '203.0.113.42') -ne '203.0.*.*') {
        throw 'IPv4 掩码失败'
    }
    if ((Protect-IPQAddress '2001:db8:1234:5678::1') -notmatch '^2001:db8:1234:') {
        throw 'IPv6 掩码失败'
    }

    $positive = New-IPQSourceResult -Name One -Available $true -Flags (New-IPQFlags -Proxy $true)
    $negative = New-IPQSourceResult -Name Two -Available $true -Flags (New-IPQFlags -Proxy $false)
    $consensus = Get-IPQConsensus -Sources @($positive, $negative)
    if ($consensus.Proxy.Verdict -ne 'Mixed') {
        throw '冲突风险源必须标为 Mixed'
    }
    if ((ConvertTo-IPQTypeLabel -SourceName IPinfo -Value isp) -ne '家宽') {
        throw 'IPinfo ISP 应映射为家宽'
    }
    if ((ConvertTo-IPQTypeLabel -SourceName IP2Location -Value 'DCH/Hosting') -ne '机房') {
        throw 'IP2Location DCH 应映射为机房'
    }
    if ((ConvertTo-IPQTypeLabel -SourceName AbuseIPDB -Value 'Fixed Line ISP') -ne '家宽') {
        throw 'AbuseIPDB 固网应映射为家宽'
    }
    if ((Get-IPQRiskLevel -SourceName IPQS -Score 92) -ne '高风险') {
        throw 'IPQS 高分风险等级映射失败'
    }
    if ((Get-IPQDisplayWidth '家宽') -ne 4) {
        throw '控制台布局应按双宽计算中文字符'
    }
    if ((Get-IPQDisplayWidth (Format-IPQFixedWidth -Text '家宽' -Width 8 -Align Center)) -ne 8) {
        throw '控制台固定宽度单元格应保持目标显示宽度'
    }
    if ($script:UserAgent -notmatch '(?:Chrome/(?:140|141|142|143|144|145)\.0\.0\.0|Firefox/(?:140|141|142|143|144|145|146|147)\.0)') {
        throw 'User-Agent 应与上游当前随机版本集合一致'
    }
    if ((ConvertTo-IPQDms -Latitude '33.9395' -Longitude '-84.2008') -ne '84°12′3″W, 33°56′22″N') {
        throw 'DMS 坐标格式应与上游一致'
    }
    if ((Get-IPQMapUrl -Latitude '33.9395' -Longitude '-84.2008' -AccuracyRadius 1001) -ne 'https://check.place/33.9395,-84.2008,12,cn') {
        throw '地图缩放和 URL 应与上游一致'
    }
    $dbIpFixture = @'
<code class="language-json">{"countryCode":"US"}</code>
<th class='text-center'>Crawler</th><th>Proxy</th><th>Attack source</th>
<span class="sr-only">No&nbsp;&nbsp;</span>
<span class="sr-only">Yes&nbsp;&nbsp;</span>
<span class="sr-only">No&nbsp;&nbsp;</span>
Estimated threat level for this IP address is <span class='label'>Low</span>
'@
    $dbIpParsed = ConvertFrom-IPQDbIpPage -Body $dbIpFixture
    if (
        $dbIpParsed.CountryCode -ne 'US' -or
        $dbIpParsed.Score -ne 0 -or
        $dbIpParsed.Flags.Robot -ne $false -or
        $dbIpParsed.Flags.Proxy -ne $true -or
        $dbIpParsed.Flags.Abuser -ne $false
    ) {
        throw 'DB-IP 页面 Yes/No 与 &nbsp; 解析应与上游一致'
    }
    if (-not (Test-IPQExpectedEmptyDnsErrorId 'DNS_ERROR_RCODE_NAME_ERROR,Microsoft.DnsClient.Commands.ResolveDnsName')) {
        throw 'DNSBL 的 NXDOMAIN 必须按上游空响应计为正常'
    }
    if (Test-IPQExpectedEmptyDnsErrorId 'DNS_ERROR_RCODE_SERVER_FAILURE,Microsoft.DnsClient.Commands.ResolveDnsName') {
        throw 'DNSBL 的服务器故障不得伪装成正常 NXDOMAIN'
    }
    $proxyMail = Get-IPQMailChecks -Context ([pscustomobject]@{
        Proxy = 'socks5h://127.0.0.1:7890'
        RouteType = 'Proxy'
    }) -Address '203.0.113.10'
    if (
        $proxyMail.Port25Status -ne 'ProxyUnsupported' -or
        @($proxyMail.Services.PSObject.Properties | Where-Object Value -eq $true).Count -ne 0
    ) {
        throw '代理模式邮件结果应与上游全部不可用语义一致'
    }
    if ((ConvertTo-IPQUpstreamUnlockType -Checks @($true, $false, $true)) -ne 'DNS') {
        throw '任一官方 DNS 检查失败时应标为 DNS'
    }
    if ((ConvertTo-IPQUpstreamUnlockType -Checks @($true, $true)) -ne '原生') {
        throw '全部官方 DNS 检查通过时应标为原生'
    }
    if (Test-IPQUpstreamDnsAddress -ResolvedAddress '192.168.1.2' -DnsServer '1.1.1.1') {
        throw '官方兼容性 DNS 检查不得把私网响应标为原生'
    }
    if (Test-IPQUpstreamDnsAddress -ResolvedAddress '1.1.1.9' -DnsServer '1.1.1.1') {
        throw '官方兼容性 DNS 检查不得把 DNS 服务器同 /24 响应标为原生'
    }
    if (-not (Test-IPQUpstreamDnsAddress -ResolvedAddress '8.8.8.8' -DnsServer '1.1.1.1')) {
        throw '官方兼容性 DNS 检查应接受独立公网响应'
    }

    $context = [pscustomobject]@{ AddressFamily = 4 }
    $emptyResponse = [pscustomobject]@{ Body = ''; Error = 'curl failed'; Success = $false; ExitCode = 35 }
    $ohNoResponse = [pscustomobject]@{ Body = '<html>Oh no!</html>'; Error = ''; Success = $true; ExitCode = 0 }
    $availableResponse = [pscustomobject]@{ Body = '<html>"id":"US","countryName":"United States"</html>'; Error = ''; Success = $true; ExitCode = 0 }
    if ((Resolve-IPQNetflixCompatibilityResult -Responses @($emptyResponse, $availableResponse) -Context $context).Status -ne 'Error') {
        throw 'Netflix 任一官方片名页为空时应判为失败'
    }
    if ((Resolve-IPQNetflixCompatibilityResult -Responses @($ohNoResponse, $ohNoResponse) -Context $context).Status -ne 'OriginalsOnly') {
        throw 'Netflix 两部官方片名页均受限时应判为仅自制'
    }
    if ((Resolve-IPQNetflixCompatibilityResult -Responses @($ohNoResponse, $availableResponse) -Context $context).Status -ne 'Available') {
        throw 'Netflix 至少一部官方片名页可用时应判为解锁'
    }

    $allowed = [pscustomobject]@{ Body = '{}'; Error = ''; Success = $true }
    $vpn = [pscustomobject]@{ Body = 'VPN'; Error = ''; Success = $true }
    $unsupported = [pscustomobject]@{ Body = 'unsupported_country'; Error = ''; Success = $true }
    $trace = [pscustomobject]@{ Body = "fl=1`nloc=US`n"; Error = ''; Success = $true }
    $favicon403 = [pscustomobject]@{ StatusCode = 403 }
    if ((Resolve-IPQChatGPTCompatibilityResult -Web $allowed -App $allowed -Favicon $null -Trace $trace -Context $context).Status -ne 'Available') {
        throw 'ChatGPT Web 与 iOS 官方判据通过时应判为解锁'
    }
    if ((Resolve-IPQChatGPTCompatibilityResult -Web $allowed -App $vpn -Favicon $null -Trace $trace -Context $context).Status -ne 'WebOnly') {
        throw 'ChatGPT 仅 Web 判据通过时应判为仅网页'
    }
    if ((Resolve-IPQChatGPTCompatibilityResult -Web $unsupported -App $allowed -Favicon $favicon403 -Trace $trace -Context $context).Status -ne 'AppOnly') {
        throw 'ChatGPT Web 地区受限而 iOS 可用时应判为仅 APP'
    }
    if ((ConvertTo-IPQMediaStatusLabel 'NoPremium') -ne '禁会员') {
        throw 'YouTube Premium 官方状态标签映射失败'
    }
    if ((ConvertTo-IPQMediaStatusLabel 'IDCOnly') -ne '机房') {
        throw 'TikTok IDC 官方状态标签映射失败'
    }
}

function ConvertTo-TestBase64Url {
    param([string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).
        TrimEnd('=').
        Replace('+', '-').
        Replace('/', '_')
}

$sip002 = "ss://$(ConvertTo-TestBase64Url '2022-blake3-aes-256-gcm:server:key')@example.com:443/?type=tcp#synthetic"
$legacy = "ss://$(ConvertTo-TestBase64Url 'aes-256-gcm:p@ss@[2001:db8::1]:8388')"
$parsedSip002 = & (Join-Path $windowsRoot 'Test-Node.ps1') -Node $sip002 -ValidateOnly
$parsedLegacy = & (Join-Path $windowsRoot 'Test-Node.ps1') -Node $legacy -ValidateOnly
Assert-Equal $parsedSip002.Method '2022-blake3-aes-256-gcm' 'SIP002 方法解析'
Assert-Equal $parsedSip002.ServerPort 443 'SIP002 端口解析'
Assert-Equal $parsedSip002.PasswordLength 10 '包含冒号的密码应完整保留'
Assert-Equal $parsedLegacy.Server '2001:db8::1' '旧格式 IPv6 服务器解析'
Assert-Equal $parsedLegacy.PasswordLength 4 '包含 @ 的旧格式密码应完整保留'

$emptyConsensus = & $module { Get-IPQConsensus -Sources @() }
$syntheticResult = [pscustomobject][ordered]@{
    Head = [pscustomobject]@{
        Version = 'test'
        Address = '203.0.*.*'
        AddressFamily = 'IPv4'
        RouteType = 'Direct'
        TimeUtc = '2026-01-01 00:00:00 UTC'
    }
    Info = [pscustomobject]@{
        ASN = 64500
        Organization = 'Example'
        City = 'Test City'
        Subdivision = 'Test State'
        Country = 'Test Country'
        RegisteredCountry = 'Test Country'
        TimeZone = 'Etc/UTC'
        Map = ''
    }
    DataSources = @(
        [pscustomobject]@{
            Name = 'IPinfo'
            Available = $true
            CountryCode = 'US'
            UsageType = 'isp'
            CompanyType = 'isp'
            Score = $null
            RiskLevel = ''
            Flags = [pscustomobject]@{
                Proxy = $false
                Tor = $false
                VPN = $false
                Server = $false
                Abuser = $null
                Robot = $null
            }
            Error = ''
        }
    )
    Consensus = & $module {
        $source = New-IPQSourceResult -Name IPinfo -Available $true -Flags (New-IPQFlags -Proxy $false -Tor $false -Vpn $false -Server $false)
        Get-IPQConsensus -Sources @($source)
    }
    Media = [pscustomobject]@{
        ChatGPT = [pscustomobject]@{
            Name = 'ChatGPT'
            Status = 'Available'
            Region = 'US'
            Type = '原生'
            TypeEvidence = 'synthetic'
            Evidence = 'synthetic'
            Error = ''
        }
    }
    Mail = $null
    DNSBlacklist = $null
    Warnings = @('synthetic warning')
}
$reportText = Get-IPQualityReportText -Result $syntheticResult
Assert-True ($reportText -match '203\.0\.\*\.\*') '文本报告应包含掩码地址'
Assert-True ($reportText -match '二、IP类型属性') '报告应包含原版 IP 类型模块'
Assert-True ($reportText -match '结论：家宽') '报告应显示家宽综合判断'
Assert-True ($reportText -match '五、流媒体及 AI 服务解锁检测') '报告应包含流媒体与 AI 模块'
Assert-True ($reportText -match 'ChatGPT.+解锁.+US.+原生') 'ChatGPT 应显示状态、地区和解锁方式'
$prettyOutput = (& { Format-IPQualityReport -Result $syntheticResult } 6>&1 | Out-String)
Assert-True ($prettyOutput -match '二、IP类型属性') '彩色控制台报告应包含 IP 类型矩阵'
Assert-True ($prettyOutput -match '五、流媒体及\s*AI服务解锁检测') '彩色控制台报告应包含流媒体矩阵'
Assert-True ($prettyOutput -match 'IP2Location ipapi ipregistry IPQS SCAMALYTICS ipdata IPinfo DB-IP') '风险因子矩阵应保留完整数据库名称'
Assert-True ($prettyOutput -notmatch '数据源警告') '数据源警告应保留在报告文件，不额外占用 47 行控制台'

$offlineTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "ipquality-test-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $offlineTemporaryRoot)
try {
    $jsonPath = Join-Path $offlineTemporaryRoot 'report.json'
    $textPath = Join-Path $offlineTemporaryRoot 'report.txt'
    Export-IPQualityReport -Result @($syntheticResult) -Path $jsonPath
    Export-IPQualityReport -Result @($syntheticResult) -Path $textPath
    Assert-True (Test-Path -LiteralPath $jsonPath) 'JSON 报告应生成'
    Assert-True (Test-Path -LiteralPath $textPath) '文本报告应生成'
    Assert-True ((Get-Content -LiteralPath $textPath -Raw) -notmatch [char]27) '文本报告不得包含 ANSI 控制字符'
    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-Equal $json.Head.AddressFamily 'IPv4' 'JSON 报告结构'
}
finally {
    if (Test-Path -LiteralPath $offlineTemporaryRoot) {
        Remove-Item -LiteralPath $offlineTemporaryRoot -Recurse -Force
    }
}

if ($Online) {
    $result = @(Invoke-IPQualityCheck -AddressFamily 4 -SkipRisk -SkipMedia -SkipMail -SkipDnsbl -TimeoutSeconds 3)
    if ($result.Count -eq 0) {
        Write-Warning 'SKIP: 当前网络没有可用 IPv4 出口，未执行在线断言。'
    }
    else {
        Assert-Equal $result.Count 1 '在线 IPv4 冒烟测试应产生一份结果'
        Assert-True ([bool]$result[0].Info.ASN) '在线结果应包含 ASN'
        Assert-True ($result[0].Head.Address -match '\*') '默认报告必须掩码 IP'
    }
}

Write-Host 'PASS: IPQuality for Windows smoke tests' -ForegroundColor Green
