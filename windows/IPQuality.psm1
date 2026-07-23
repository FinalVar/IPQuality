#Requires -Version 7.2
Set-StrictMode -Version Latest

$script:IPQualityVersion = '0.2.0'
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36'
$script:SourceOrder = @(
    'IPinfo',
    'Scamalytics',
    'ipregistry',
    'ipapi',
    'AbuseIPDB',
    'IP2Location',
    'ipdata',
    'IPQS',
    'DB-IP'
)

function Get-IPQValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Default = $null
    )

    $current = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            return $Default
        }

        if ($current -is [Collections.IDictionary]) {
            if (-not $current.Contains($part)) {
                return $Default
            }
            $current = $current[$part]
            continue
        }

        if ($current -is [Collections.IList]) {
            $index = 0
            if (-not [int]::TryParse($part, [ref]$index) -or $index -lt 0 -or $index -ge $current.Count) {
                return $Default
            }
            $current = $current[$index]
            continue
        }

        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $Default
        }
        $current = $property.Value
    }

    if ($null -eq $current) {
        return $Default
    }
    return $current
}

function ConvertTo-IPQBoolean {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [bool]) {
        return $Value
    }
    if ($Value -is [int] -or $Value -is [long]) {
        return [bool]$Value
    }

    switch -Regex ("$Value".Trim()) {
        '^(?i:true|yes|y|1)$' { return $true }
        '^(?i:false|no|n|0)$' { return $false }
        default { return $null }
    }
}

function ConvertTo-IPQScore {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [switch]$Fraction
    )

    if ($null -eq $Value -or "$Value" -in @('', 'null', 'N/A')) {
        return $null
    }

    $number = 0.0
    $text = "$Value" -replace '[^0-9.\-]', ''
    if (-not [double]::TryParse(
        $text,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $null
    }

    if ($Fraction) {
        $number *= 100
    }
    return [Math]::Round($number, 2)
}

function ConvertFrom-IPQJson {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-IPQCurlPath {
    $command = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw '找不到 curl.exe。Windows 10/11 通常自带 curl；请修复系统 PATH 后重试。'
    }
    return $command.Source
}

function New-IPQContext {
    [CmdletBinding()]
    param(
        [ValidateSet(4, 6)][int]$AddressFamily,
        [AllowEmptyString()][string]$Proxy,
        [AllowEmptyString()][string]$Interface,
        [ValidateRange(2, 60)][int]$TimeoutSeconds = 10
    )

    if ($Proxy) {
        $proxyUri = $null
        if (-not [Uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$proxyUri)) {
            throw '代理格式无效。支持 http://、https://、socks4://、socks5:// 和 socks5h://。'
        }
        if ($proxyUri.Scheme -notin @('http', 'https', 'socks4', 'socks4a', 'socks5', 'socks5h')) {
            throw "不支持的代理协议：$($proxyUri.Scheme)"
        }
    }

    [pscustomobject]@{
        AddressFamily = $AddressFamily
        Proxy = $Proxy
        Interface = $Interface
        TimeoutSeconds = $TimeoutSeconds
        CurlPath = Get-IPQCurlPath
        RouteType = if ($Proxy) { 'Proxy' } else { 'Direct' }
    }
}

function Invoke-IPQRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'HEAD')][string]$Method = 'GET',
        [Collections.IDictionary]$Headers,
        [AllowNull()][string]$Body,
        [AllowEmptyString()][string]$ContentType,
        [switch]$NoRedirect
    )

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '--silent',
        '--show-error',
        '--compressed',
        '--connect-timeout', [string][Math]::Min(5, $Context.TimeoutSeconds),
        '--max-time', [string]$Context.TimeoutSeconds
    )) {
        $arguments.Add($argument)
    }

    if (-not $NoRedirect) {
        $arguments.Add('--location')
    }
    $arguments.Add($(if ($Context.AddressFamily -eq 4) { '--ipv4' } else { '--ipv6' }))

    if ($Context.Proxy) {
        $arguments.Add('--proxy')
        $arguments.Add($Context.Proxy)
    }
    if ($Context.Interface) {
        $arguments.Add('--interface')
        $arguments.Add($Context.Interface)
    }
    if ($Method -ne 'GET') {
        $arguments.Add('--request')
        $arguments.Add($Method)
    }
    if ($Headers) {
        foreach ($entry in $Headers.GetEnumerator()) {
            $arguments.Add('--header')
            $arguments.Add("$($entry.Key): $($entry.Value)")
        }
    }
    if ($ContentType) {
        $arguments.Add('--header')
        $arguments.Add("Content-Type: $ContentType")
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments.Add('--data-raw')
        $arguments.Add($Body)
    }

    $marker = "__IPQ_META_$([Guid]::NewGuid().ToString('N'))__"
    $arguments.Add('--write-out')
    $arguments.Add("`n${marker}%{http_code}`t%{url_effective}")
    $arguments.Add('--url')
    $arguments.Add($Uri)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Context.CurlPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $processTimeout = ($Context.TimeoutSeconds + 5) * 1000
    if (-not $process.WaitForExit($processTimeout)) {
        try {
            $process.Kill($true)
            [void]$process.WaitForExit(1000)
        }
        catch {
        }
        $timeoutResult = [pscustomobject]@{
            Success = $false
            StatusCode = 0
            EffectiveUrl = $Uri
            Body = ''
            Error = "请求超过 $($Context.TimeoutSeconds) 秒"
            ExitCode = -1
        }
        $process.Dispose()
        return $timeoutResult
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    $statusCode = 0
    $effectiveUrl = $Uri
    $responseBody = $stdout
    $markerIndex = $stdout.LastIndexOf("`n$marker", [StringComparison]::Ordinal)
    if ($markerIndex -ge 0) {
        $responseBody = $stdout.Substring(0, $markerIndex)
        $meta = $stdout.Substring($markerIndex + $marker.Length + 1)
        $metaParts = $meta -split "`t", 2
        [void][int]::TryParse($metaParts[0].Trim(), [ref]$statusCode)
        if ($metaParts.Count -gt 1 -and $metaParts[1].Trim()) {
            $effectiveUrl = $metaParts[1].Trim()
        }
    }

    $result = [pscustomobject]@{
        Success = ($process.ExitCode -eq 0)
        StatusCode = $statusCode
        EffectiveUrl = $effectiveUrl
        Body = $responseBody.TrimEnd("`r", "`n")
        Error = $stderr
        ExitCode = $process.ExitCode
    }
    $process.Dispose()
    return $result
}

function Test-IPQAddress {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Address,
        [ValidateSet(4, 6)][int]$AddressFamily
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsed)) {
        return $false
    }
    if ($AddressFamily -eq 4) {
        return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    }
    return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
}

function Get-IPQPublicAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)

    $endpoints = @(
        'https://myip.check.place',
        'https://api64.ipify.org',
        'https://ip.sb',
        'https://icanhazip.com',
        'https://ifconfig.co/ip',
        'https://ident.me'
    )

    foreach ($endpoint in $endpoints) {
        $response = Invoke-IPQRequest -Context $Context -Uri $endpoint
        $candidate = $response.Body.Trim()
        if ($response.Success -and (Test-IPQAddress -Address $candidate -AddressFamily $Context.AddressFamily)) {
            return [pscustomobject]@{
                Address = $candidate
                Endpoint = $endpoint
            }
        }
    }
    return $null
}

function Protect-IPQAddress {
    [CmdletBinding()]
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

function New-IPQFlags {
    param(
        [AllowNull()][object]$Proxy,
        [AllowNull()][object]$Tor,
        [AllowNull()][object]$Vpn,
        [AllowNull()][object]$Server,
        [AllowNull()][object]$Abuser,
        [AllowNull()][object]$Robot
    )
    [pscustomobject][ordered]@{
        Proxy = ConvertTo-IPQBoolean $Proxy
        Tor = ConvertTo-IPQBoolean $Tor
        VPN = ConvertTo-IPQBoolean $Vpn
        Server = ConvertTo-IPQBoolean $Server
        Abuser = ConvertTo-IPQBoolean $Abuser
        Robot = ConvertTo-IPQBoolean $Robot
    }
}

function New-IPQSourceResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Available,
        [AllowEmptyString()][string]$CountryCode,
        [AllowEmptyString()][string]$UsageType,
        [AllowEmptyString()][string]$CompanyType,
        [AllowNull()][object]$Score,
        [AllowEmptyString()][string]$RiskLevel = '',
        [AllowNull()][object]$Flags,
        [AllowEmptyString()][string]$Error
    )
    [pscustomobject][ordered]@{
        Name = $Name
        Available = $Available
        CountryCode = $CountryCode
        UsageType = $UsageType
        CompanyType = $CompanyType
        Score = $Score
        RiskLevel = $RiskLevel
        Flags = if ($null -ne $Flags) { $Flags } else { New-IPQFlags }
        Error = $Error
    }
}

function ConvertTo-IPQTypeLabel {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$SourceName,
        [AllowNull()][object]$Value
    )

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq 'null') {
        return '-'
    }

    $first = ($text -split '/')[0].Trim()
    switch -Regex ($first) {
        '^(?i:isp|fixed line isp)$' { return '家宽' }
        '^(?i:mobile isp|mob)$' { return '手机' }
        '^(?i:hosting|data center.*|dch)$' { return '机房' }
        '^(?i:content delivery network|cdn)$' { return 'CDN' }
        '^(?i:business|commercial|com)$' { return '商业' }
        '^(?i:education|university.*|edu)$' { return '教育' }
        '^(?i:government|gov)$' { return '政府' }
        '^(?i:banking)$' { return '银行' }
        '^(?i:organization|org)$' { return '组织' }
        '^(?i:military|mil)$' { return '军队' }
        '^(?i:library|lib)$' { return '图书馆' }
        '^(?i:search engine spider|ses)$' { return '蜘蛛' }
        '^(?i:reserved|rsv)$' { return '保留' }
        default { return '其他' }
    }
}

function Get-IPQRiskLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceName,
        [AllowNull()][object]$Score,
        [AllowEmptyString()][string]$Hint = ''
    )

    switch -Regex ($Hint.Trim()) {
        '^(?i:very low)$' { return '极低风险' }
        '^(?i:low)$' { return '低风险' }
        '^(?i:elevated)$' { return '较高风险' }
        '^(?i:medium)$' { return '中风险' }
        '^(?i:high)$' { return '高风险' }
        '^(?i:very high)$' { return '极高风险' }
    }
    if ($null -eq $Score) {
        return ''
    }

    $number = [double]$Score
    switch ($SourceName) {
        'Scamalytics' {
            if ($number -lt 20) { return '低风险' }
            if ($number -lt 60) { return '中风险' }
            if ($number -lt 90) { return '高风险' }
            return '极高风险'
        }
        'IP2Location' {
            if ($number -lt 33) { return '低风险' }
            if ($number -lt 66) { return '中风险' }
            return '高风险'
        }
        'AbuseIPDB' {
            if ($number -lt 25) { return '低风险' }
            if ($number -lt 75) { return '高风险' }
            return '建议封禁'
        }
        'IPQS' {
            if ($number -lt 75) { return '低风险' }
            if ($number -lt 85) { return '可疑IP' }
            if ($number -lt 90) { return '存在风险' }
            return '高风险'
        }
        'DB-IP' {
            if ($number -lt 33) { return '低风险' }
            if ($number -lt 66) { return '中风险' }
            return '高风险'
        }
        'ipapi' {
            if ($number -lt 0.85) { return '极低风险' }
            if ($number -lt 3) { return '低风险' }
            if ($number -lt 30) { return '较高风险' }
            if ($number -lt 70) { return '高风险' }
            return '极高风险'
        }
        default { return '' }
    }
}

function Get-IPQMaxMindInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Address
    )

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?lang=cn"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data) {
        return [pscustomobject][ordered]@{
            Available = $false
            Error = if ($response.Error) { $response.Error } else { '返回内容不是有效 JSON' }
        }
    }

    [pscustomobject][ordered]@{
        Available = $true
        ASN = Get-IPQValue $data 'ASN.AutonomousSystemNumber'
        Organization = Get-IPQValue $data 'ASN.AutonomousSystemOrganization'
        City = Get-IPQValue $data 'City.Name'
        PostalCode = Get-IPQValue $data 'City.PostalCode'
        Latitude = Get-IPQValue $data 'City.Latitude'
        Longitude = Get-IPQValue $data 'City.Longitude'
        AccuracyRadius = Get-IPQValue $data 'City.AccuracyRadius'
        TimeZone = Get-IPQValue $data 'City.Location.TimeZone'
        SubdivisionCode = Get-IPQValue $data 'City.Subdivisions.0.IsoCode'
        Subdivision = Get-IPQValue $data 'City.Subdivisions.0.Name'
        CountryCode = Get-IPQValue $data 'Country.IsoCode'
        Country = Get-IPQValue $data 'Country.Name'
        RegisteredCountryCode = Get-IPQValue $data 'Country.RegisteredCountry.IsoCode'
        RegisteredCountry = Get-IPQValue $data 'Country.RegisteredCountry.Name'
        ContinentCode = Get-IPQValue $data 'City.Continent.Code'
        Continent = Get-IPQValue $data 'City.Continent.Name'
        Error = ''
    }
}

function Merge-IPQBoolean {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Values)

    $normalized = @($Values | ForEach-Object { ConvertTo-IPQBoolean $_ })
    if ($normalized -contains $true) {
        return $true
    }
    $known = @($normalized | Where-Object { $null -ne $_ })
    if ($known.Count -gt 0 -and @($known | Where-Object { $_ -eq $false }).Count -eq $known.Count) {
        return $false
    }
    return $null
}

function Get-IPQSourceIPInfo {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.io/widget/demo/$Address"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data) {
        return New-IPQSourceResult -Name 'IPinfo' -Available $false -Error $(if ($response.Error) { $response.Error } else { '无有效 JSON' })
    }

    New-IPQSourceResult `
        -Name 'IPinfo' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'data.country' '')" `
        -UsageType "$(Get-IPQValue $data 'data.asn.type' '')" `
        -CompanyType "$(Get-IPQValue $data 'data.company.type' '')" `
        -Score $null `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'data.privacy.proxy') `
            -Tor (Get-IPQValue $data 'data.privacy.tor') `
            -Vpn (Get-IPQValue $data 'data.privacy.vpn') `
            -Server (Get-IPQValue $data 'data.privacy.hosting')) `
        -Error ''
}

function Get-IPQSourceScamalytics {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?db=scamalytics"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data) {
        return New-IPQSourceResult -Name 'Scamalytics' -Available $false -Error $(if ($response.Error) { $response.Error } else { '无有效 JSON' })
    }

    $robot = Merge-IPQBoolean @(
        (Get-IPQValue $data 'external_datasources.x4bnet.is_blacklisted_spambot'),
        (Get-IPQValue $data 'external_datasources.x4bnet.is_bot_operamini'),
        (Get-IPQValue $data 'external_datasources.x4bnet.is_bot_semrush')
    )
    New-IPQSourceResult `
        -Name 'Scamalytics' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'external_datasources.maxmind_geolite2.ip_country_code' '')" `
        -Score (ConvertTo-IPQScore (Get-IPQValue $data 'scamalytics.scamalytics_score')) `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'Scamalytics' -Score (ConvertTo-IPQScore (Get-IPQValue $data 'scamalytics.scamalytics_score'))) `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'external_datasources.firehol.is_proxy') `
            -Tor (Get-IPQValue $data 'external_datasources.x4bnet.is_tor') `
            -Vpn (Get-IPQValue $data 'scamalytics.scamalytics_proxy.is_vpn') `
            -Server (Get-IPQValue $data 'scamalytics.scamalytics_proxy.is_datacenter') `
            -Abuser (Get-IPQValue $data 'scamalytics.is_blacklisted_external') `
            -Robot $robot) `
        -Error ''
}

function Get-IPQSourceIPRegistry {
    param([object]$Context, [string]$Address)

    $apiKey = 'sb69ksjcajfs4c'
    $landing = Invoke-IPQRequest -Context $Context -Uri 'https://ipregistry.co'
    if ($landing.Body -match 'apiKey\s*=\s*["''](?<key>[a-zA-Z0-9]+)["'']') {
        $apiKey = $Matches.key
    }
    $headers = [ordered]@{
        Origin = 'https://ipregistry.co'
        Referer = 'https://ipregistry.co/'
        'User-Agent' = $script:UserAgent
    }
    $response = Invoke-IPQRequest -Context $Context -Uri "https://api.ipregistry.co/${Address}?hostname=true&key=$apiKey" -Headers $headers
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or (Get-IPQValue $data 'code')) {
        return New-IPQSourceResult -Name 'ipregistry' -Available $false -Error $(if ($response.Error) { $response.Error } else { "$(Get-IPQValue $data 'message' '无有效 JSON')" })
    }

    $tor = Merge-IPQBoolean @(
        (Get-IPQValue $data 'security.is_tor'),
        (Get-IPQValue $data 'security.is_tor_exit')
    )
    New-IPQSourceResult `
        -Name 'ipregistry' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'location.country.code' '')" `
        -UsageType "$(Get-IPQValue $data 'connection.type' '')" `
        -CompanyType "$(Get-IPQValue $data 'company.type' '')" `
        -Score $null `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'security.is_proxy') `
            -Tor $tor `
            -Vpn (Get-IPQValue $data 'security.is_vpn') `
            -Server (Get-IPQValue $data 'security.is_cloud_provider') `
            -Abuser (Get-IPQValue $data 'security.is_abuser')) `
        -Error ''
}

function Get-IPQSourceIPApi {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://api.ipapi.is/?q=$Address"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or (Get-IPQValue $data 'error')) {
        return New-IPQSourceResult -Name 'ipapi' -Available $false -Error $(if ($response.Error) { $response.Error } else { "$(Get-IPQValue $data 'message' '无有效 JSON')" })
    }

    $rawScore = "$(Get-IPQValue $data 'company.abuser_score' '')"
    $riskHint = if ($rawScore -match '\((?<level>[^)]+)\)') { $Matches.level } else { '' }
    $score = ConvertTo-IPQScore $rawScore -Fraction
    New-IPQSourceResult `
        -Name 'ipapi' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'location.country_code' '')" `
        -UsageType "$(Get-IPQValue $data 'asn.type' '')" `
        -CompanyType "$(Get-IPQValue $data 'company.type' '')" `
        -Score $score `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'ipapi' -Score $score -Hint $riskHint) `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'is_proxy') `
            -Tor (Get-IPQValue $data 'is_tor') `
            -Vpn (Get-IPQValue $data 'is_vpn') `
            -Server (Get-IPQValue $data 'is_datacenter') `
            -Abuser (Get-IPQValue $data 'is_abuser') `
            -Robot (Get-IPQValue $data 'is_crawler')) `
        -Error ''
}

function Get-IPQSourceAbuseIPDB {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?db=abuseipdb"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or $null -eq (Get-IPQValue $data 'data')) {
        return New-IPQSourceResult -Name 'AbuseIPDB' -Available $false -Error $(if ($response.Error) { $response.Error } else { '无有效 JSON' })
    }

    $score = ConvertTo-IPQScore (Get-IPQValue $data 'data.abuseConfidenceScore')
    New-IPQSourceResult `
        -Name 'AbuseIPDB' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'data.countryCode' '')" `
        -UsageType "$(Get-IPQValue $data 'data.usageType' '')" `
        -Score $score `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'AbuseIPDB' -Score $score) `
        -Flags (New-IPQFlags -Abuser $(if ($null -eq $score) { $null } elseif ($score -gt 0) { $true } else { $false })) `
        -Error ''
}

function Get-IPQSourceIP2Location {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?db=ip2location"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or (Get-IPQValue $data 'error.error_code')) {
        return New-IPQSourceResult -Name 'IP2Location' -Available $false -Error $(if ($response.Error) { $response.Error } else { "$(Get-IPQValue $data 'error.error_message' '无有效 JSON')" })
    }

    $proxy = Merge-IPQBoolean @(
        (Get-IPQValue $data 'is_proxy'),
        (Get-IPQValue $data 'proxy.is_public_proxy'),
        (Get-IPQValue $data 'proxy.is_web_proxy')
    )
    $robot = Merge-IPQBoolean @(
        (Get-IPQValue $data 'proxy.is_web_crawler'),
        (Get-IPQValue $data 'proxy.is_scanner'),
        (Get-IPQValue $data 'proxy.is_botnet')
    )
    New-IPQSourceResult `
        -Name 'IP2Location' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'country_code' '')" `
        -UsageType "$(Get-IPQValue $data 'usage_type' '')" `
        -CompanyType "$(Get-IPQValue $data 'as_info.as_usage_type' '')" `
        -Score (ConvertTo-IPQScore (Get-IPQValue $data 'fraud_score')) `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'IP2Location' -Score (ConvertTo-IPQScore (Get-IPQValue $data 'fraud_score'))) `
        -Flags (New-IPQFlags `
            -Proxy $proxy `
            -Tor (Get-IPQValue $data 'proxy.is_tor') `
            -Vpn (Get-IPQValue $data 'proxy.is_vpn') `
            -Server (Get-IPQValue $data 'proxy.is_data_center') `
            -Abuser (Get-IPQValue $data 'proxy.is_spammer') `
            -Robot $robot) `
        -Error ''
}

function Get-IPQSourceIPData {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?db=ipdata"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or (Get-IPQValue $data 'message')) {
        return New-IPQSourceResult -Name 'ipdata' -Available $false -Error $(if ($response.Error) { $response.Error } else { "$(Get-IPQValue $data 'message' '无有效 JSON')" })
    }

    $abuser = Merge-IPQBoolean @(
        (Get-IPQValue $data 'threat.is_threat'),
        (Get-IPQValue $data 'threat.is_known_abuser'),
        (Get-IPQValue $data 'threat.is_known_attacker')
    )
    New-IPQSourceResult `
        -Name 'ipdata' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'country_code' '')" `
        -Score $null `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'threat.is_proxy') `
            -Tor (Get-IPQValue $data 'threat.is_tor') `
            -Server (Get-IPQValue $data 'threat.is_datacenter') `
            -Abuser $abuser) `
        -Error ''
}

function Get-IPQSourceIPQS {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?db=ipqualityscore"
    $data = ConvertFrom-IPQJson $response.Body
    if ($null -eq $data -or (Get-IPQValue $data 'success') -eq $false) {
        return New-IPQSourceResult -Name 'IPQS' -Available $false -Error $(if ($response.Error) { $response.Error } else { "$(Get-IPQValue $data 'message' '无有效 JSON')" })
    }

    New-IPQSourceResult `
        -Name 'IPQS' `
        -Available $true `
        -CountryCode "$(Get-IPQValue $data 'country_code' '')" `
        -Score (ConvertTo-IPQScore (Get-IPQValue $data 'fraud_score')) `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'IPQS' -Score (ConvertTo-IPQScore (Get-IPQValue $data 'fraud_score'))) `
        -Flags (New-IPQFlags `
            -Proxy (Get-IPQValue $data 'proxy') `
            -Tor (Get-IPQValue $data 'tor') `
            -Vpn (Get-IPQValue $data 'vpn') `
            -Abuser (Get-IPQValue $data 'recent_abuse') `
            -Robot (Get-IPQValue $data 'bot_status')) `
        -Error ''
}

function Get-IPQSourceDBIP {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://db-ip.com/$Address"
    if (-not $response.Success -or [string]::IsNullOrWhiteSpace($response.Body)) {
        return New-IPQSourceResult -Name 'DB-IP' -Available $false -Error $(if ($response.Error) { $response.Error } else { '页面内容为空' })
    }

    $body = $response.Body
    $countryCode = ''
    if ($body -match '"countryCode"\s*:\s*"(?<country>[A-Z]{2})"') {
        $countryCode = $Matches.country
    }

    $riskText = ''
    if ($body -match '(?is)Estimated threat level for this IP address is\s*<span[^>]*>(?<risk>[^<]+)<') {
        $riskText = $Matches.risk.Trim()
    }
    $score = switch -Regex ($riskText) {
        '^(?i:low)$' { 0; break }
        '^(?i:medium)$' { 50; break }
        '^(?i:high)$' { 100; break }
        default { $null }
    }

    $flags = New-IPQFlags
    $crawlerIndex = $body.IndexOf('>Crawler<', [StringComparison]::OrdinalIgnoreCase)
    if ($crawlerIndex -ge 0) {
        $tail = $body.Substring($crawlerIndex)
        $matches = [regex]::Matches($tail, '(?is)<span[^>]*class=["'']sr-only["''][^>]*>\s*(?<value>Yes|No)\s*</span>')
        if ($matches.Count -ge 3) {
            $flags.Robot = $matches[0].Groups['value'].Value -eq 'Yes'
            $flags.Proxy = $matches[1].Groups['value'].Value -eq 'Yes'
            $flags.Abuser = $matches[2].Groups['value'].Value -eq 'Yes'
        }
    }

    New-IPQSourceResult `
        -Name 'DB-IP' `
        -Available $true `
        -CountryCode $countryCode `
        -Score $score `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'DB-IP' -Score $score -Hint $riskText) `
        -Flags $flags `
        -Error ''
}

function Get-IPQRiskSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Address
    )

    $checks = [ordered]@{
        IPinfo = { Get-IPQSourceIPInfo -Context $Context -Address $Address }
        Scamalytics = { Get-IPQSourceScamalytics -Context $Context -Address $Address }
        ipregistry = { Get-IPQSourceIPRegistry -Context $Context -Address $Address }
        ipapi = { Get-IPQSourceIPApi -Context $Context -Address $Address }
        AbuseIPDB = { Get-IPQSourceAbuseIPDB -Context $Context -Address $Address }
        IP2Location = { Get-IPQSourceIP2Location -Context $Context -Address $Address }
        ipdata = { Get-IPQSourceIPData -Context $Context -Address $Address }
        IPQS = { Get-IPQSourceIPQS -Context $Context -Address $Address }
        'DB-IP' = { Get-IPQSourceDBIP -Context $Context -Address $Address }
    }

    $results = [Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($entry in $checks.GetEnumerator()) {
        $index++
        Write-Progress -Activity '查询 IP 风险数据库' -Status $entry.Key -PercentComplete (($index / $checks.Count) * 100)
        try {
            $results.Add((& $entry.Value))
        }
        catch {
            $results.Add((New-IPQSourceResult -Name $entry.Key -Available $false -Error $_.Exception.Message))
        }
    }
    Write-Progress -Activity '查询 IP 风险数据库' -Completed
    return $results.ToArray()
}

function Get-IPQConsensus {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Sources)

    $result = [ordered]@{}
    foreach ($factor in @('Proxy', 'Tor', 'VPN', 'Server', 'Abuser', 'Robot')) {
        $values = @(
            $Sources |
                Where-Object { $_.Available } |
                ForEach-Object { $_.Flags.$factor } |
                Where-Object { $null -ne $_ }
        )
        $positive = @($values | Where-Object { $_ -eq $true }).Count
        $negative = @($values | Where-Object { $_ -eq $false }).Count
        $result[$factor] = [pscustomobject][ordered]@{
            Positive = $positive
            Negative = $negative
            Available = $values.Count
            Verdict = if ($values.Count -eq 0) {
                'Unknown'
            }
            elseif ($positive -gt 0 -and $negative -gt 0) {
                'Mixed'
            }
            elseif ($positive -gt 0) {
                'Detected'
            }
            else {
                'NotDetected'
            }
        }
    }
    return [pscustomobject]$result
}

function Get-IPQTypeAssessment {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Sources)

    $rows = [Collections.Generic.List[object]]::new()
    $homeSignals = 0
    $idcSignals = 0
    foreach ($name in @('IPinfo', 'ipregistry', 'ipapi', 'IP2Location', 'AbuseIPDB')) {
        $matches = @($Sources | Where-Object Name -eq $name)
        if ($matches.Count -eq 0 -or -not $matches[0].Available) {
            $rows.Add([pscustomobject][ordered]@{
                Name = $name
                Available = $false
                UsageType = ''
                UsageLabel = '-'
                CompanyType = ''
                CompanyLabel = '-'
            })
            continue
        }

        $source = $matches[0]
        $usageLabel = ConvertTo-IPQTypeLabel -SourceName $name -Value $source.UsageType
        $companyLabel = ConvertTo-IPQTypeLabel -SourceName $name -Value $source.CompanyType
        if ($usageLabel -eq '家宽' -or $companyLabel -eq '家宽') { $homeSignals++ }
        if ($usageLabel -in @('机房', 'CDN') -or $companyLabel -in @('机房', 'CDN')) { $idcSignals++ }
        $rows.Add([pscustomobject][ordered]@{
            Name = $name
            Available = $true
            UsageType = $source.UsageType
            UsageLabel = $usageLabel
            CompanyType = $source.CompanyType
            CompanyLabel = $companyLabel
        })
    }

    $verdict = if ($homeSignals -gt 0 -and $idcSignals -eq 0) {
        '家宽'
    }
    elseif ($idcSignals -gt 0 -and $homeSignals -eq 0) {
        '机房'
    }
    elseif ($homeSignals -gt 0 -and $idcSignals -gt 0) {
        '混合（数据库结论冲突）'
    }
    else {
        '未知'
    }
    return [pscustomobject][ordered]@{
        Verdict = $verdict
        HomeSignals = $homeSignals
        DatacenterSignals = $idcSignals
        Sources = $rows.ToArray()
    }
}

function New-IPQMediaResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$Region = '',
        [Parameter(Mandatory)][object]$Context,
        [AllowEmptyString()][string]$Evidence = '',
        [AllowEmptyString()][string]$Error = ''
    )

    [pscustomobject][ordered]@{
        Name = $Name
        Status = $Status
        Region = $Region
        Type = '未知'
        TypeEvidence = ''
        Evidence = $Evidence
        Error = $Error
    }
}

function Get-IPQRegionFromText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    foreach ($pattern in @(
        '"contentRegion"\s*:\s*"(?<region>[A-Z]{2})"',
        '"countryOfSignup"\s*:\s*"(?<region>[A-Z]{2})"',
        '"currentTerritory"\s*:\s*"(?<region>[A-Z]{2})"',
        '"region"\s*:\s*"(?<region>[A-Z]{2})"',
        'country\s*=\s*"(?<region>[A-Z]{2})"',
        '"id"\s*:\s*"(?<region>[A-Z]{2})"\s*,\s*"countryName"'
    )) {
        if ($Text -match $pattern) {
            return $Matches.region
        }
    }
    return ''
}

function Test-IPQGlobalAddress {
    param([Parameter(Mandatory)][string]$Address)

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }
    if ([Net.IPAddress]::IsLoopback($parsed)) {
        return $false
    }
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $parsed.GetAddressBytes()
        if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $false }
        return $true
    }

    if ($parsed.IsIPv6LinkLocal -or $parsed.IsIPv6Multicast -or $parsed.IsIPv6SiteLocal) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    return (($bytes[0] -band 0xFE) -ne 0xFC)
}

function Get-IPQMediaUnlockType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Domain,
        [ValidateSet(4, 6)][int]$AddressFamily
    )

    $recordType = if ($AddressFamily -eq 4) { 'A' } else { 'AAAA' }
    foreach ($name in $Domain) {
        try {
            $addresses = @(
                Resolve-DnsName -Name $name -Type $recordType -DnsOnly -ErrorAction Stop |
                    Where-Object { $null -ne $_.PSObject.Properties['IPAddress'] } |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ }
            )
        }
        catch {
            return [pscustomobject]@{ Type = 'DNS'; Evidence = "$name 正常域名未获得 $recordType 记录" }
        }
        if ($addresses.Count -eq 0 -or @($addresses | Where-Object { -not (Test-IPQGlobalAddress $_) }).Count -gt 0) {
            return [pscustomobject]@{ Type = 'DNS'; Evidence = "$name 返回空地址、私网地址或保留地址" }
        }

        $randomName = "ipq-$([Guid]::NewGuid().ToString('N')).$name"
        $wildcard = @()
        try {
            $wildcard = @(
                Resolve-DnsName -Name $randomName -Type $recordType -DnsOnly -ErrorAction Stop |
                    Where-Object { $null -ne $_.PSObject.Properties['IPAddress'] } |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ }
            )
        }
        catch {
            $wildcard = @()
        }
        if ($wildcard.Count -gt 0) {
            return [pscustomobject]@{ Type = 'DNS'; Evidence = "$name 的随机子域名被 DNS 合成" }
        }
    }
    return [pscustomobject]@{ Type = '原生'; Evidence = '正常域名解析为公网地址，随机子域名未被合成' }
}

function Test-IPQTikTok {
    param([object]$Context)

    $headers = [ordered]@{
        'User-Agent' = $script:UserAgent
        'Accept-Language' = 'en'
    }
    $response = Invoke-IPQRequest -Context $Context -Uri 'https://www.tiktok.com/' -Headers $headers
    if (-not $response.Success) {
        return New-IPQMediaResult -Name 'TikTok' -Status 'Error' -Context $Context -Error $response.Error
    }
    $region = Get-IPQRegionFromText $response.Body
    if ($region) {
        return New-IPQMediaResult -Name 'TikTok' -Status 'Available' -Region $region -Context $Context -Evidence '页面返回地区字段'
    }
    if ($response.StatusCode -in @(401, 403, 451)) {
        return New-IPQMediaResult -Name 'TikTok' -Status 'Blocked' -Context $Context -Evidence "HTTP $($response.StatusCode)"
    }
    return New-IPQMediaResult -Name 'TikTok' -Status 'Unknown' -Context $Context -Evidence "HTTP $($response.StatusCode)，未找到地区字段"
}

function Test-IPQDisneyPlus {
    param([object]$Context)

    $token = 'ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84'
    $headers = [ordered]@{
        Authorization = "Bearer $token"
        'User-Agent' = $script:UserAgent
    }
    $deviceBody = '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}'
    $device = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://disney.api.edge.bamgrid.com/devices' `
        -Method POST `
        -Headers $headers `
        -ContentType 'application/json; charset=UTF-8' `
        -Body $deviceBody
    $deviceData = ConvertFrom-IPQJson $device.Body
    $assertion = Get-IPQValue $deviceData 'assertion'
    if (-not $device.Success -or -not $assertion) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error $(if ($device.Error) { $device.Error } else { '无法获取设备 assertion' })
    }

    $cookieFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ref\cookies.txt'))
    if (-not (Test-Path -LiteralPath $cookieFile)) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error '缺少 ref/cookies.txt'
    }
    $templates = Get-Content -LiteralPath $cookieFile
    if ($templates.Count -lt 8) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error 'Disney+ 请求模板不完整'
    }

    $exchangeBody = $templates[0].Replace('DISNEYASSERTION', [Uri]::EscapeDataString("$assertion"))
    $exchange = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://disney.api.edge.bamgrid.com/token' `
        -Method POST `
        -Headers $headers `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $exchangeBody
    $exchangeData = ConvertFrom-IPQJson $exchange.Body
    if ((Get-IPQValue $exchangeData 'error_description') -eq 'forbidden-location' -or $exchange.StatusCode -eq 403) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Blocked' -Context $Context -Evidence 'forbidden-location'
    }
    $refreshToken = Get-IPQValue $exchangeData 'refresh_token'
    if (-not $refreshToken) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error $(if ($exchange.Error) { $exchange.Error } else { '无法获取 refresh token' })
    }

    $graphBody = $templates[7].Replace('ILOVEDISNEY', "$refreshToken")
    $graphHeaders = [ordered]@{
        Authorization = $token
        'User-Agent' = $script:UserAgent
    }
    $graph = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql' `
        -Method POST `
        -Headers $graphHeaders `
        -ContentType 'application/json' `
        -Body $graphBody
    $graphData = ConvertFrom-IPQJson $graph.Body
    if ($null -eq $graphData) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error $(if ($graph.Error) { $graph.Error } else { 'GraphQL 返回无效' })
    }

    $region = "$(Get-IPQValue $graphData 'extensions.sdk.session.location.countryCode' '')"
    $supported = ConvertTo-IPQBoolean (Get-IPQValue $graphData 'extensions.sdk.session.inSupportedLocation')
    if ($supported -eq $true -or $region -eq 'JP') {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Available' -Region $region -Context $Context -Evidence 'Disney SDK location'
    }
    if ($region) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Pending' -Region $region -Context $Context -Evidence '地区已识别但服务未标记可用'
    }
    return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Blocked' -Context $Context -Evidence '无可用地区'
}

function Test-IPQNetflix {
    param([object]$Context)

    $headers = [ordered]@{ 'User-Agent' = $script:UserAgent }
    $responses = @(
        (Invoke-IPQRequest -Context $Context -Uri 'https://www.netflix.com/title/81280792' -Headers $headers),
        (Invoke-IPQRequest -Context $Context -Uri 'https://www.netflix.com/title/70143836' -Headers $headers)
    )
    if (@($responses | Where-Object { -not $_.Success }).Count -gt 0) {
        $errorText = ($responses | Where-Object Error | Select-Object -First 1).Error
        return New-IPQMediaResult -Name 'Netflix' -Status 'Error' -Context $Context -Error $errorText
    }
    if (@($responses | Where-Object { $_.StatusCode -in @(403, 451) }).Count -gt 0) {
        return New-IPQMediaResult -Name 'Netflix' -Status 'Blocked' -Context $Context -Evidence 'HTTP 拒绝'
    }

    $region = ''
    foreach ($response in $responses) {
        $region = Get-IPQRegionFromText $response.Body
        if ($region) {
            break
        }
    }
    $unavailable = @($responses | Where-Object { $_.Body -match 'Oh no!|not available in your region' }).Count
    if ($unavailable -eq $responses.Count) {
        return New-IPQMediaResult -Name 'Netflix' -Status 'OriginalsOnly' -Region $region -Context $Context -Evidence '两部地区限定影片均不可用'
    }
    return New-IPQMediaResult -Name 'Netflix' -Status 'Available' -Region $region -Context $Context -Evidence '至少一部地区限定影片可访问'
}

function Test-IPQYouTube {
    param([object]$Context)

    $headers = [ordered]@{
        'User-Agent' = $script:UserAgent
        'Accept-Language' = 'en'
        Cookie = 'CONSENT=YES+cb.20220301-11-p0.en+FX+700'
    }
    $response = Invoke-IPQRequest -Context $Context -Uri 'https://www.youtube.com/premium' -Headers $headers
    if (-not $response.Success) {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Error' -Context $Context -Error $response.Error
    }
    $region = Get-IPQRegionFromText $response.Body
    if ($response.Body -match 'Premium is not available in your country') {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Blocked' -Region $region -Context $Context -Evidence '页面明确提示地区不可用'
    }
    if ($response.Body -match 'ad-free|YouTube Premium|youtubePremium') {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Available' -Region $region -Context $Context -Evidence 'Premium 页面可访问'
    }
    return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Unknown' -Region $region -Context $Context -Evidence "HTTP $($response.StatusCode)"
}

function Test-IPQPrimeVideo {
    param([object]$Context)

    $headers = [ordered]@{ 'User-Agent' = $script:UserAgent }
    $response = Invoke-IPQRequest -Context $Context -Uri 'https://www.primevideo.com' -Headers $headers
    if (-not $response.Success) {
        return New-IPQMediaResult -Name 'AmazonPrimeVideo' -Status 'Error' -Context $Context -Error $response.Error
    }
    $region = Get-IPQRegionFromText $response.Body
    if ($region) {
        return New-IPQMediaResult -Name 'AmazonPrimeVideo' -Status 'Available' -Region $region -Context $Context -Evidence 'currentTerritory'
    }
    if ($response.StatusCode -in @(403, 451)) {
        return New-IPQMediaResult -Name 'AmazonPrimeVideo' -Status 'Blocked' -Context $Context -Evidence "HTTP $($response.StatusCode)"
    }
    return New-IPQMediaResult -Name 'AmazonPrimeVideo' -Status 'Unknown' -Context $Context -Evidence '未找到地区字段'
}

function Test-IPQReddit {
    param([object]$Context)

    $headers = [ordered]@{ 'User-Agent' = $script:UserAgent }
    $response = Invoke-IPQRequest -Context $Context -Uri 'https://www.reddit.com/' -Headers $headers
    if (-not $response.Success) {
        return New-IPQMediaResult -Name 'Reddit' -Status 'Error' -Context $Context -Error $response.Error
    }
    $region = Get-IPQRegionFromText $response.Body
    switch ($response.StatusCode) {
        200 { return New-IPQMediaResult -Name 'Reddit' -Status 'Available' -Region $region -Context $Context -Evidence 'HTTP 200' }
        403 { return New-IPQMediaResult -Name 'Reddit' -Status 'Blocked' -Context $Context -Evidence 'HTTP 403' }
        default { return New-IPQMediaResult -Name 'Reddit' -Status 'Unknown' -Region $region -Context $Context -Evidence "HTTP $($response.StatusCode)" }
    }
}

function Test-IPQChatGPT {
    param([object]$Context)

    $headers = [ordered]@{
        'User-Agent' = $script:UserAgent
        Accept = '*/*'
        Origin = 'https://platform.openai.com'
        Referer = 'https://platform.openai.com/'
        Authorization = 'Bearer null'
    }
    $web = Invoke-IPQRequest -Context $Context -Uri 'https://api.openai.com/compliance/cookie_requirements' -Headers $headers
    $app = Invoke-IPQRequest -Context $Context -Uri 'https://ios.chat.openai.com/' -Headers ([ordered]@{ 'User-Agent' = $script:UserAgent })
    $trace = Invoke-IPQRequest -Context $Context -Uri 'https://chat.openai.com/cdn-cgi/trace'
    $region = ''
    if ($trace.Body -match '(?m)^loc=(?<region>[A-Z]{2})\s*$') {
        $region = $Matches.region
    }

    $webAllowed = $web.Success -and $web.Body -notmatch 'unsupported_country'
    $appAllowed = $app.Success -and $app.Body -notmatch '(?i)VPN'
    if ($webAllowed -and $appAllowed) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Available' -Region $region -Context $Context -Evidence 'Web 与 iOS 端点均可用'
    }
    if ($webAllowed) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'WebOnly' -Region $region -Context $Context -Evidence '仅 Web 端点通过'
    }
    if ($appAllowed) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'AppOnly' -Region $region -Context $Context -Evidence '仅 iOS 端点通过'
    }
    if ($web.Success -or $app.Success) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Blocked' -Region $region -Context $Context -Evidence '端点返回地区/VPN 限制'
    }
    return New-IPQMediaResult -Name 'ChatGPT' -Status 'Error' -Region $region -Context $Context -Error (($web.Error, $app.Error | Where-Object { $_ }) -join '; ')
}

function Get-IPQMediaChecks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)

    $checks = [ordered]@{
        TikTok = { Test-IPQTikTok -Context $Context }
        DisneyPlus = { Test-IPQDisneyPlus -Context $Context }
        Netflix = { Test-IPQNetflix -Context $Context }
        YouTubePremium = { Test-IPQYouTube -Context $Context }
        AmazonPrimeVideo = { Test-IPQPrimeVideo -Context $Context }
        Reddit = { Test-IPQReddit -Context $Context }
        ChatGPT = { Test-IPQChatGPT -Context $Context }
    }
    $domains = @{
        TikTok = @('tiktok.com')
        DisneyPlus = @('disneyplus.com')
        Netflix = @('netflix.com')
        YouTubePremium = @('www.youtube.com')
        AmazonPrimeVideo = @('www.primevideo.com')
        Reddit = @('reddit.com')
        ChatGPT = @('chat.openai.com', 'ios.chat.openai.com', 'api.openai.com')
    }
    $result = [ordered]@{}
    $index = 0
    foreach ($entry in $checks.GetEnumerator()) {
        $index++
        Write-Progress -Activity '检测流媒体与 AI 可用性' -Status $entry.Key -PercentComplete (($index / $checks.Count) * 100)
        try {
            $result[$entry.Key] = & $entry.Value
            if ($result[$entry.Key].Status -notin @('Error', 'Blocked')) {
                $unlock = Get-IPQMediaUnlockType -Domain $domains[$entry.Key] -AddressFamily $Context.AddressFamily
                $result[$entry.Key].Type = $unlock.Type
                $result[$entry.Key].TypeEvidence = $unlock.Evidence
            }
        }
        catch {
            $result[$entry.Key] = New-IPQMediaResult -Name $entry.Key -Status 'Error' -Context $Context -Error $_.Exception.Message
        }
    }
    Write-Progress -Activity '检测流媒体与 AI 可用性' -Completed
    return [pscustomobject]$result
}

function Get-IPQMxHosts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Domain)

    try {
        return @(
            Resolve-DnsName -Name $Domain -Type MX -DnsOnly -ErrorAction Stop |
                Where-Object { $_.Type -eq 'MX' -and $_.NameExchange } |
                Sort-Object Preference |
                ForEach-Object { $_.NameExchange.TrimEnd('.') } |
                Select-Object -Unique
        )
    }
    catch {
        return @()
    }
}

function Test-IPQSmtpService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Domain
    )

    $mxHosts = @(Get-IPQMxHosts -Domain $Domain | Select-Object -First 2)
    if ($mxHosts.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Name = $Name
            Domain = $Domain
            Reachable = $false
            Host = ''
            Error = '未解析到 MX'
        }
    }

    $smtpContext = $Context.PSObject.Copy()
    $smtpContext.TimeoutSeconds = [Math]::Min(5, $Context.TimeoutSeconds)
    $lastError = ''
    foreach ($hostName in $mxHosts) {
        $response = Invoke-IPQRequest -Context $smtpContext -Uri "smtp://${hostName}:25" -NoRedirect
        if ($response.Success -or $response.Body -match '(?m)^220[\s-]' -or $response.Error -match '(?m)^220[\s-]') {
            return [pscustomobject][ordered]@{
                Name = $Name
                Domain = $Domain
                Reachable = $true
                Host = $hostName
                Error = ''
            }
        }
        $lastError = if ($response.Error) { $response.Error } else { "curl exit $($response.ExitCode)" }
    }

    [pscustomobject][ordered]@{
        Name = $Name
        Domain = $Domain
        Reachable = $false
        Host = $mxHosts[0]
        Error = $lastError
    }
}

function Get-IPQMailChecks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Context)

    $services = [ordered]@{
        Gmail = 'gmail.com'
        Outlook = 'outlook.com'
        Yahoo = 'yahoo.com'
        Apple = 'me.com'
        QQ = 'qq.com'
        MailRU = 'mail.ru'
        AOL = 'aol.com'
        GMX = 'gmx.com'
        MailCOM = 'mail.com'
        '163' = '163.com'
        Sohu = 'sohu.com'
        Sina = 'sina.com'
    }

    $workItems = @()
    $order = 0
    foreach ($entry in $services.GetEnumerator()) {
        $workItems += [pscustomobject]@{
            Order = $order
            Name = $entry.Key
            Domain = $entry.Value
        }
        $order++
    }

    $curlPath = $Context.CurlPath
    $family = $Context.AddressFamily
    $proxy = $Context.Proxy
    $interfaceName = $Context.Interface
    Write-Progress -Activity '检测 SMTP 25 端口' -Status '并发连接邮件服务' -PercentComplete 10
    $checks = @(
        $workItems | ForEach-Object -Parallel {
            $item = $_
            try {
                $mxHosts = @(
                    Resolve-DnsName -Name $item.Domain -Type MX -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.Type -eq 'MX' -and $_.NameExchange } |
                        Sort-Object Preference |
                        ForEach-Object { $_.NameExchange.TrimEnd('.') } |
                        Select-Object -First 2
                )
            }
            catch {
                $mxHosts = @()
            }
            if ($mxHosts.Count -eq 0) {
                [pscustomobject]@{
                    Order = $item.Order
                    Name = $item.Name
                    Domain = $item.Domain
                    Reachable = $false
                    Host = ''
                    Error = '未解析到 MX'
                }
                return
            }

            $lastError = ''
            foreach ($hostName in $mxHosts) {
                if (-not $using:proxy -and -not $using:interfaceName) {
                    try {
                        $targetFamily = if ($using:family -eq 4) {
                            [Net.Sockets.AddressFamily]::InterNetwork
                        }
                        else {
                            [Net.Sockets.AddressFamily]::InterNetworkV6
                        }
                        $targetAddress = [Net.Dns]::GetHostAddresses($hostName) |
                            Where-Object AddressFamily -eq $targetFamily |
                            Select-Object -First 1
                        if ($null -eq $targetAddress) {
                            $lastError = "没有 IPv$using:family 地址"
                            continue
                        }
                        $client = [Net.Sockets.TcpClient]::new($targetFamily)
                        try {
                            $connectTask = $client.ConnectAsync($targetAddress, 25)
                            if ($connectTask.Wait(3000) -and $client.Connected) {
                                [pscustomobject]@{
                                    Order = $item.Order
                                    Name = $item.Name
                                    Domain = $item.Domain
                                    Reachable = $true
                                    Host = $hostName
                                    Error = ''
                                }
                                return
                            }
                            $lastError = 'TCP 连接超时'
                        }
                        finally {
                            $client.Dispose()
                        }
                    }
                    catch {
                        $lastError = $_.Exception.GetBaseException().Message
                    }
                    continue
                }

                $arguments = @(
                    '--silent',
                    '--show-error',
                    '--connect-timeout', '3',
                    '--max-time', '5',
                    $(if ($using:family -eq 4) { '--ipv4' } else { '--ipv6' })
                )
                if ($using:proxy) {
                    $arguments += @('--proxy', $using:proxy)
                }
                if ($using:interfaceName) {
                    $arguments += @('--interface', $using:interfaceName)
                }
                $arguments += "smtp://${hostName}:25"
                $output = & $using:curlPath @arguments 2>&1
                $exitCode = $LASTEXITCODE
                $text = ($output | Out-String).Trim()
                if ($exitCode -in @(0, 8, 56) -or $text -match '(?m)^220[\s-]') {
                    [pscustomobject]@{
                        Order = $item.Order
                        Name = $item.Name
                        Domain = $item.Domain
                        Reachable = $true
                        Host = $hostName
                        Error = ''
                    }
                    return
                }
                $lastError = if ($text) { $text } else { "curl exit $exitCode" }
            }
            [pscustomobject]@{
                Order = $item.Order
                Name = $item.Name
                Domain = $item.Domain
                Reachable = $false
                Host = $mxHosts[0]
                Error = $lastError
            }
        } -ThrottleLimit 6 |
            Sort-Object Order
    )
    Write-Progress -Activity '检测 SMTP 25 端口' -Completed

    $serviceMap = [ordered]@{}
    foreach ($check in $checks) {
        $serviceMap[$check.Name] = $check.Reachable
    }
    [pscustomobject][ordered]@{
        RouteType = $Context.RouteType
        Port25 = @($checks | Where-Object Reachable).Count -gt 0
        Services = [pscustomobject]$serviceMap
        Details = @($checks)
    }
}

function Get-IPQDnsblChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1, 100)][int]$Concurrency = 40
    )

    if (-not (Test-IPQAddress -Address $Address -AddressFamily 4)) {
        return [pscustomobject][ordered]@{
            Supported = $false
            Total = 0
            Clean = 0
            Marked = 0
            Blacklisted = 0
            Errors = 0
            Details = @()
        }
    }

    $listPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ref\dnsbl.list'))
    if (-not (Test-Path -LiteralPath $listPath)) {
        throw '缺少 ref/dnsbl.list'
    }
    $zones = @(
        Get-Content -LiteralPath $listPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Sort-Object -Unique
    )
    $reversed = ($Address.Split('.')[3..0] -join '.')
    Write-Progress -Activity '查询 DNS 黑名单' -Status "$($zones.Count) 个 DNSBL" -PercentComplete 10
    $checks = @(
        $zones | ForEach-Object -Parallel {
            $zone = $_
            $query = "$using:reversed.$zone"
            try {
                $answers = @([Net.Dns]::GetHostAddresses($query) | ForEach-Object ToString)
                if ($answers -contains '127.0.0.2') {
                    [pscustomobject]@{ Zone = $zone; Status = 'Blacklisted'; Answers = $answers }
                }
                elseif ($answers.Count -gt 0) {
                    [pscustomobject]@{ Zone = $zone; Status = 'Marked'; Answers = $answers }
                }
                else {
                    [pscustomobject]@{ Zone = $zone; Status = 'Clean'; Answers = @() }
                }
            }
            catch [Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -in @(
                    [Net.Sockets.SocketError]::HostNotFound,
                    [Net.Sockets.SocketError]::NoData
                )) {
                    [pscustomobject]@{ Zone = $zone; Status = 'Clean'; Answers = @() }
                }
                else {
                    [pscustomobject]@{ Zone = $zone; Status = 'Error'; Answers = @(); Error = $_.Exception.SocketErrorCode.ToString() }
                }
            }
            catch {
                [pscustomobject]@{ Zone = $zone; Status = 'Error'; Answers = @(); Error = $_.Exception.Message }
            }
        } -ThrottleLimit $Concurrency
    )
    Write-Progress -Activity '查询 DNS 黑名单' -Completed

    [pscustomobject][ordered]@{
        Supported = $true
        Total = $checks.Count
        Clean = @($checks | Where-Object Status -eq 'Clean').Count
        Marked = @($checks | Where-Object Status -eq 'Marked').Count
        Blacklisted = @($checks | Where-Object Status -eq 'Blacklisted').Count
        Errors = @($checks | Where-Object Status -eq 'Error').Count
        Details = @($checks | Where-Object Status -ne 'Clean' | Sort-Object Status, Zone)
    }
}

function Invoke-IPQualityCheck {
    [CmdletBinding()]
    param(
        [ValidateSet(4, 6)][int[]]$AddressFamily = @(4, 6),
        [AllowEmptyString()][string]$Proxy,
        [AllowEmptyString()][string]$Interface,
        [switch]$FullIP,
        [switch]$Lite,
        [switch]$SkipRisk,
        [switch]$SkipMedia,
        [switch]$SkipMail,
        [switch]$SkipDnsbl,
        [ValidateRange(2, 60)][int]$TimeoutSeconds = 10,
        [ValidateRange(1, 100)][int]$DnsblConcurrency = 40
    )

    $allResults = [Collections.Generic.List[object]]::new()
    foreach ($family in ($AddressFamily | Select-Object -Unique)) {
        $context = New-IPQContext `
            -AddressFamily $family `
            -Proxy $Proxy `
            -Interface $Interface `
            -TimeoutSeconds $TimeoutSeconds
        Write-Host "`n正在发现 IPv$family 出口（$($context.RouteType)）..." -ForegroundColor Cyan
        $public = Get-IPQPublicAddress -Context $context
        if ($null -eq $public) {
            Write-Warning "未发现可用 IPv$family 出口，已跳过。"
            continue
        }

        $address = $public.Address
        $displayAddress = if ($FullIP) { $address } else { Protect-IPQAddress $address }
        Write-Host "出口地址：$displayAddress" -ForegroundColor Green

        Write-Host '正在查询基础地理与 ASN 信息...' -ForegroundColor DarkCyan
        $maxMind = Get-IPQMaxMindInfo -Context $context -Address $address

        $sources = @()
        if (-not $SkipRisk) {
            if ($Lite) {
                $sources = @(
                    Get-IPQSourceIPInfo -Context $context -Address $address
                    Get-IPQSourceIPRegistry -Context $context -Address $address
                    Get-IPQSourceIPApi -Context $context -Address $address
                    Get-IPQSourceDBIP -Context $context -Address $address
                )
            }
            else {
                $sources = @(Get-IPQRiskSources -Context $context -Address $address)
            }
        }
        $consensus = Get-IPQConsensus -Sources $sources
        $typeAssessment = Get-IPQTypeAssessment -Sources $sources

        $media = [pscustomobject][ordered]@{}
        if (-not $SkipMedia) {
            $media = Get-IPQMediaChecks -Context $context
        }

        $mail = $null
        if (-not $SkipMail) {
            $mail = Get-IPQMailChecks -Context $context
        }

        $dnsbl = $null
        if (-not $SkipDnsbl) {
            if ($family -eq 4) {
                $dnsbl = Get-IPQDnsblChecks -Address $address -Concurrency $DnsblConcurrency
            }
            else {
                $dnsbl = [pscustomobject][ordered]@{
                    Supported = $false
                    Total = 0
                    Clean = 0
                    Marked = 0
                    Blacklisted = 0
                    Errors = 0
                    Details = @()
                }
            }
        }

        $warnings = [Collections.Generic.List[string]]::new()
        if (-not $maxMind.Available) {
            $warnings.Add("MaxMind：$($maxMind.Error)")
        }
        foreach ($source in ($sources | Where-Object { -not $_.Available })) {
            $warnings.Add("$($source.Name)：$($source.Error)")
        }
        if (-not $SkipMedia) {
            foreach ($property in $media.PSObject.Properties) {
                if ($property.Value.Status -eq 'Error') {
                    $warnings.Add("$($property.Name)：$($property.Value.Error)")
                }
            }
        }

        $info = [pscustomobject][ordered]@{
            ASN = $maxMind.ASN
            Organization = $maxMind.Organization
            City = $maxMind.City
            PostalCode = $maxMind.PostalCode
            SubdivisionCode = $maxMind.SubdivisionCode
            Subdivision = $maxMind.Subdivision
            CountryCode = $maxMind.CountryCode
            Country = $maxMind.Country
            RegisteredCountryCode = $maxMind.RegisteredCountryCode
            RegisteredCountry = $maxMind.RegisteredCountry
            ContinentCode = $maxMind.ContinentCode
            Continent = $maxMind.Continent
            Latitude = $maxMind.Latitude
            Longitude = $maxMind.Longitude
            AccuracyRadiusKm = $maxMind.AccuracyRadius
            TimeZone = $maxMind.TimeZone
            Map = if ($maxMind.Latitude -and $maxMind.Longitude) {
                "https://www.google.com/maps?q=$($maxMind.Latitude),$($maxMind.Longitude)"
            }
            else {
                ''
            }
            GeoType = if (
                $maxMind.CountryCode -and
                $maxMind.RegisteredCountryCode -and
                "$($maxMind.CountryCode)" -eq "$($maxMind.RegisteredCountryCode)"
            ) {
                '原生IP'
            }
            elseif ($maxMind.CountryCode -and $maxMind.RegisteredCountryCode) {
                '广播IP'
            }
            else {
                '未知'
            }
        }

        $allResults.Add([pscustomobject][ordered]@{
            Head = [pscustomobject][ordered]@{
                Tool = 'IPQuality for Windows'
                Version = $script:IPQualityVersion
                Upstream = 'https://github.com/xykt/IPQuality'
                TimeUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
                Address = $displayAddress
                AddressFamily = "IPv$family"
                RouteType = $context.RouteType
                DiscoveryEndpoint = $public.Endpoint
                Privacy = if ($FullIP) { 'FullAddress' } else { 'MaskedAddress' }
            }
            Info = $info
            DataSources = $sources
            TypeAssessment = $typeAssessment
            Consensus = $consensus
            Media = $media
            Mail = $mail
            DNSBlacklist = $dnsbl
            Warnings = $warnings.ToArray()
        })
    }
    return $allResults.ToArray()
}

function Format-IPQCell {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or "$Value" -eq '') {
        return '-'
    }
    if ($Value -is [bool]) {
        return $(if ($Value) { 'YES' } else { 'NO' })
    }
    return "$Value"
}

function Format-IPQFactor {
    param([AllowNull()][object]$Value)
    $normalized = ConvertTo-IPQBoolean $Value
    if ($null -eq $normalized) { return '无' }
    return $(if ($normalized) { '是' } else { '否' })
}

function ConvertTo-IPQMediaStatusLabel {
    param([AllowEmptyString()][string]$Status)
    switch ($Status) {
        'Available' { return '解锁' }
        'Blocked' { return '屏蔽' }
        'Error' { return '失败' }
        'Pending' { return '待支持' }
        'OriginalsOnly' { return '仅自制' }
        'WebOnly' { return '仅网页' }
        'AppOnly' { return '仅APP' }
        'Unknown' { return '未知' }
        default { return $(if ($Status) { $Status } else { '未知' }) }
    }
}

function Get-IPQualityReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine('########################################################################')
    [void]$builder.AppendLine("                    IP质量体检报告：$($Result.Head.Address)")
    [void]$builder.AppendLine('                 https://github.com/FinalVar/IPQuality')
    [void]$builder.AppendLine("检测时间：$($Result.Head.TimeUtc)  Windows版：$($Result.Head.Version)")
    [void]$builder.AppendLine("地址族：$($Result.Head.AddressFamily)  网络路径：$($Result.Head.RouteType)")
    [void]$builder.AppendLine('########################################################################')
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('一、基础信息（MaxMind 数据库）')
    [void]$builder.AppendLine("自治系统号：            AS$(Format-IPQCell (Get-IPQValue $Result.Info 'ASN'))")
    [void]$builder.AppendLine("组织：                  $(Format-IPQCell (Get-IPQValue $Result.Info 'Organization'))")
    [void]$builder.AppendLine("城市：                  $(Format-IPQCell (Get-IPQValue $Result.Info 'Subdivision')), $(Format-IPQCell (Get-IPQValue $Result.Info 'City')), $(Format-IPQCell (Get-IPQValue $Result.Info 'PostalCode'))")
    [void]$builder.AppendLine("使用地：                [$(Format-IPQCell (Get-IPQValue $Result.Info 'CountryCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'Country')), [$(Format-IPQCell (Get-IPQValue $Result.Info 'ContinentCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'Continent'))")
    [void]$builder.AppendLine("注册地：                [$(Format-IPQCell (Get-IPQValue $Result.Info 'RegisteredCountryCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'RegisteredCountry'))")
    [void]$builder.AppendLine("时区：                  $(Format-IPQCell (Get-IPQValue $Result.Info 'TimeZone'))")
    $map = Get-IPQValue $Result.Info 'Map' ''
    if ($map) {
        [void]$builder.AppendLine("地图：                  $map")
    }
    [void]$builder.AppendLine("IP类型：                $(Format-IPQCell (Get-IPQValue $Result.Info 'GeoType' '未知'))")
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('二、IP类型属性')
    if (@($Result.DataSources).Count -eq 0) {
        [void]$builder.AppendLine('已跳过')
    }
    else {
        [void]$builder.AppendLine('数据库             使用类型     公司类型     原始使用类型')
        $typeAssessment = Get-IPQValue $Result 'TypeAssessment'
        if ($null -eq $typeAssessment) {
            $typeAssessment = Get-IPQTypeAssessment -Sources $Result.DataSources
        }
        foreach ($source in $typeAssessment.Sources) {
            if (-not $source.Available) {
                [void]$builder.AppendLine(('{0,-18} {1}' -f $source.Name, '不可用'))
                continue
            }
            [void]$builder.AppendLine(('{0,-18} {1,-12} {2,-12} {3}' -f $source.Name, $source.UsageLabel, $source.CompanyLabel, (Format-IPQCell $source.UsageType)))
        }
        [void]$builder.AppendLine("综合判断：家宽信号 $($typeAssessment.HomeSignals)，机房/CDN 信号 $($typeAssessment.DatacenterSignals)，结论：$($typeAssessment.Verdict)")
    }
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('三、风险评分')
    $scoreSources = @($Result.DataSources | Where-Object { $_.Available -and $null -ne $_.Score })
    if ($scoreSources.Count -eq 0) {
        [void]$builder.AppendLine('没有可用评分')
    }
    else {
        foreach ($source in $scoreSources) {
            $riskLevel = Get-IPQValue $source 'RiskLevel' ''
            if (-not $riskLevel) {
                $riskLevel = Get-IPQRiskLevel -SourceName $source.Name -Score $source.Score
            }
            [void]$builder.AppendLine(('{0,-18}: {1,7}%  {2}' -f $source.Name, $source.Score, (Format-IPQCell $riskLevel)))
        }
    }
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('四、风险因子')
    if (@($Result.DataSources).Count -eq 0) {
        [void]$builder.AppendLine('已跳过')
    }
    else {
        [void]$builder.AppendLine('数据库             地区  代理 Tor  VPN 服务器 滥用 机器人')
        foreach ($source in $Result.DataSources) {
            if (-not $source.Available) {
                [void]$builder.AppendLine(('{0,-18} {1}' -f $source.Name, '不可用'))
                continue
            }
            [void]$builder.AppendLine(('{0,-18} {1,-5} {2,-4} {3,-4} {4,-4} {5,-6} {6,-4} {7}' -f @(
                $source.Name,
                (Format-IPQCell $source.CountryCode),
                (Format-IPQFactor $source.Flags.Proxy),
                (Format-IPQFactor $source.Flags.Tor),
                (Format-IPQFactor $source.Flags.VPN),
                (Format-IPQFactor $source.Flags.Server),
                (Format-IPQFactor $source.Flags.Abuser),
                (Format-IPQFactor $source.Flags.Robot)
            )))
        }
        [void]$builder.AppendLine('交叉判定（阳性/有效数据源）：')
        foreach ($factor in @('Proxy', 'Tor', 'VPN', 'Server', 'Abuser', 'Robot')) {
            $item = $Result.Consensus.$factor
            $verdict = switch ($item.Verdict) {
                'Detected' { '检出' }
                'NotDetected' { '未检出' }
                'Mixed' { '冲突' }
                default { '未知' }
            }
            [void]$builder.AppendLine(('  {0,-7}: {1,-6} ({2}/{3})' -f $factor, $verdict, $item.Positive, $item.Available))
        }
    }
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('五、流媒体及 AI 服务解锁检测')
    if (@($Result.Media.PSObject.Properties).Count -eq 0) {
        [void]$builder.AppendLine('已跳过')
    }
    else {
        [void]$builder.AppendLine('服务商                 状态       地区     方式')
        foreach ($property in $Result.Media.PSObject.Properties) {
            $item = $property.Value
            [void]$builder.AppendLine(('{0,-22} {1,-10} {2,-8} {3}' -f $property.Name, (ConvertTo-IPQMediaStatusLabel $item.Status), (Format-IPQCell $item.Region), (Format-IPQCell $item.Type)))
        }
    }
    [void]$builder.AppendLine()

    [void]$builder.AppendLine('六、邮局连通性及黑名单检测')
    if ($null -eq $Result.Mail) {
        [void]$builder.AppendLine('邮件连通性：已跳过')
    }
    else {
        [void]$builder.AppendLine("本地 25 端口出站：$(if ($Result.Mail.Port25) { '可用' } else { '阻断' })")
        [void]$builder.Append('通信：')
        foreach ($property in $Result.Mail.Services.PSObject.Properties) {
            [void]$builder.Append(" $($property.Name)=$(if ($property.Value) { '可用' } else { '阻断' })")
        }
        [void]$builder.AppendLine()
    }
    if ($null -eq $Result.DNSBlacklist) {
        [void]$builder.AppendLine('DNSBL：已跳过')
    }
    elseif (-not $Result.DNSBlacklist.Supported) {
        [void]$builder.AppendLine('DNSBL：IPv6 暂不支持反向查询')
    }
    else {
        [void]$builder.AppendLine("IP地址黑名单数据库：总数 $($Result.DNSBlacklist.Total)  干净 $($Result.DNSBlacklist.Clean)  标记 $($Result.DNSBlacklist.Marked)  黑名单 $($Result.DNSBlacklist.Blacklisted)  错误 $($Result.DNSBlacklist.Errors)")
        foreach ($detail in $Result.DNSBlacklist.Details) {
            [void]$builder.AppendLine("  $($detail.Status): $($detail.Zone) [$($detail.Answers -join ', ')]")
        }
    }

    if (@($Result.Warnings).Count -gt 0) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('[数据源警告]')
        foreach ($warning in $Result.Warnings) {
            [void]$builder.AppendLine("  - $warning")
        }
    }
    [void]$builder.AppendLine('========================================================================')
    return $builder.ToString().TrimEnd()
}

function Format-IPQualityReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    Write-Host ''
    Write-Host (Get-IPQualityReportText -Result $Result)
}

function Export-IPQualityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Result,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "输出文件已存在：$fullPath。使用 -Force 才会覆盖。"
    }
    $directory = Split-Path -Parent $fullPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    if ([IO.Path]::GetExtension($fullPath) -ieq '.json') {
        $content = if ($Result.Count -eq 1) {
            $Result[0] | ConvertTo-Json -Depth 12
        }
        else {
            $Result | ConvertTo-Json -Depth 12
        }
    }
    else {
        $content = ($Result | ForEach-Object { Get-IPQualityReportText -Result $_ }) -join "`r`n`r`n"
    }

    $temporaryPath = "$fullPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporaryPath, $content, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-IPQualityCheck',
    'Format-IPQualityReport',
    'Get-IPQualityReportText',
    'Export-IPQualityReport'
)
