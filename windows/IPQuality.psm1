#Requires -Version 7.2
Set-StrictMode -Version Latest

$script:IPQualityVersion = '0.5.0'
$script:UpstreamVersion = 'unknown'

function New-IPQUpstreamUserAgent {
    [CmdletBinding()]
    param()

    $chromeVersions = @(
        '145.0.0.0',
        '144.0.0.0',
        '143.0.0.0',
        '142.0.0.0',
        '141.0.0.0',
        '140.0.0.0'
    )
    $firefoxVersions = @(
        '147.0',
        '146.0',
        '145.0',
        '144.0',
        '143.0',
        '142.0',
        '141.0',
        '140.0'
    )
    if ([Random]::Shared.Next(0, 2) -eq 0) {
        $version = $chromeVersions[[Random]::Shared.Next(0, $chromeVersions.Count)]
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$version Safari/537.36"
    }

    $version = $firefoxVersions[[Random]::Shared.Next(0, $firefoxVersions.Count)]
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:$version) Gecko/20100101 Firefox/$version"
}

$script:UserAgent = New-IPQUpstreamUserAgent
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
$script:UpstreamScriptSha256 = ''
try {
    $upstreamScriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ip.sh'))
    if (Test-Path -LiteralPath $upstreamScriptPath) {
        $upstreamBytes = [IO.File]::ReadAllBytes($upstreamScriptPath)
        $script:UpstreamScriptSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($upstreamBytes)
        ).ToLowerInvariant()
        $upstreamText = [Text.Encoding]::UTF8.GetString($upstreamBytes)
        if ($upstreamText -match '(?m)^script_version="(?<version>[^"]+)"') {
            $script:UpstreamVersion = $Matches.version
        }
    }
}
catch {
}

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
        [AllowEmptyString()][string]$Cookie,
        [switch]$NoRedirect,
        [switch]$FailOnHttpError,
        [switch]$Tls13,
        [switch]$DiscardBody
    )

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '--silent',
        '--show-error',
        '--compressed',
        '--max-time', [string]$Context.TimeoutSeconds
    )) {
        $arguments.Add($argument)
    }

    if (-not $NoRedirect) {
        $arguments.Add('--location')
    }
    if ($FailOnHttpError) {
        $arguments.Add('--fail')
    }
    if ($Tls13) {
        $arguments.Add('--tlsv1.3')
    }
    $arguments.Add($(if ($Context.AddressFamily -eq 4) { '--ipv4' } else { '--ipv6' }))

    if ($Context.Proxy) {
        $arguments.Add('--proxy')
        $arguments.Add($Context.Proxy)
    }
    else {
        # curl honors ALL_PROXY/HTTPS_PROXY automatically. Upstream only uses a
        # proxy when -x is explicitly supplied, so Direct must bypass env proxies.
        $arguments.Add('--noproxy')
        $arguments.Add('*')
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
    if ($Cookie) {
        $arguments.Add('--cookie')
        $arguments.Add($Cookie)
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments.Add('--data-raw')
        $arguments.Add($Body)
    }
    if ($DiscardBody) {
        $arguments.Add('--output')
        $arguments.Add('NUL')
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
    if (-not $stderr -and $statusCode -ge 400) {
        $stderr = "HTTP $statusCode"
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

    $familySpecificEndpoint = if ($Context.AddressFamily -eq 4) {
        'https://api.ipify.org'
    }
    else {
        'https://api6.ipify.org'
    }
    $endpoints = @(
        'https://myip.check.place',
        $familySpecificEndpoint,
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

function ConvertTo-IPQDms {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Latitude,
        [AllowNull()][object]$Longitude
    )

    $latitudeNumber = 0.0
    $longitudeNumber = 0.0
    if (
        -not [double]::TryParse(
            "$Latitude",
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$latitudeNumber
        ) -or
        -not [double]::TryParse(
            "$Longitude",
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$longitudeNumber
        )
    ) {
        return ''
    }

    function ConvertTo-IPQDmsCoordinate {
        param(
            [double]$Coordinate,
            [string]$PositiveDirection,
            [string]$NegativeDirection
        )

        $direction = if ($Coordinate -lt 0) { $NegativeDirection } else { $PositiveDirection }
        $absolute = [Math]::Abs($Coordinate)
        $degrees = [Math]::Truncate($absolute)
        $minutesWithFraction = ($absolute - $degrees) * 60
        $minutes = [Math]::Truncate($minutesWithFraction)
        $seconds = [Math]::Round(($minutesWithFraction - $minutes) * 60, 0)
        return "$([int]$degrees)°$([int]$minutes)′$([int]$seconds)″$direction"
    }

    $latitudeDms = ConvertTo-IPQDmsCoordinate `
        -Coordinate $latitudeNumber `
        -PositiveDirection 'N' `
        -NegativeDirection 'S'
    $longitudeDms = ConvertTo-IPQDmsCoordinate `
        -Coordinate $longitudeNumber `
        -PositiveDirection 'E' `
        -NegativeDirection 'W'
    return "$longitudeDms, $latitudeDms"
}

function Get-IPQMapUrl {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Latitude,
        [AllowNull()][object]$Longitude,
        [AllowNull()][object]$AccuracyRadius,
        [ValidateSet('cn', 'en', 'jp', 'es', 'de', 'fr', 'ru', 'pt')]
        [string]$Language = 'cn'
    )

    if (
        [string]::IsNullOrWhiteSpace("$Latitude") -or
        [string]::IsNullOrWhiteSpace("$Longitude")
    ) {
        return ''
    }
    $radius = 0.0
    [void][double]::TryParse(
        "$AccuracyRadius",
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$radius
    )
    $zoom = if ($radius -gt 1000) {
        12
    }
    elseif ($radius -gt 500) {
        13
    }
    elseif ($radius -gt 250) {
        14
    }
    else {
        15
    }
    return "https://check.place/$Latitude,$Longitude,$zoom,$Language"
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
    $fallbackResponse = $null
    $fallbackData = $null
    if ($null -eq $data) {
        $fallbackResponse = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?lang=en"
        $fallbackData = ConvertFrom-IPQJson $fallbackResponse.Body
    }
    else {
        $fallbackResponse = Invoke-IPQRequest -Context $Context -Uri "https://ipinfo.check.place/${Address}?lang=en"
        $fallbackData = ConvertFrom-IPQJson $fallbackResponse.Body
    }

    if ($null -eq $data -and $null -eq $fallbackData) {
        return [pscustomobject][ordered]@{
            Available = $false
            Error = if ($response.Error) { $response.Error } elseif ($fallbackResponse.Error) { $fallbackResponse.Error } else { '返回内容不是有效 JSON' }
        }
    }

    function Get-IPQMaxMindField {
        param([string]$Path)

        $value = Get-IPQValue $data $Path
        if (-not [string]::IsNullOrWhiteSpace("$value") -and "$value" -ne 'null') {
            return $value
        }
        return Get-IPQValue $fallbackData $Path
    }

    [pscustomobject][ordered]@{
        Available = $true
        ASN = Get-IPQMaxMindField 'ASN.AutonomousSystemNumber'
        Organization = Get-IPQMaxMindField 'ASN.AutonomousSystemOrganization'
        City = Get-IPQMaxMindField 'City.Name'
        PostalCode = Get-IPQMaxMindField 'City.PostalCode'
        Latitude = Get-IPQMaxMindField 'City.Latitude'
        Longitude = Get-IPQMaxMindField 'City.Longitude'
        AccuracyRadius = Get-IPQMaxMindField 'City.AccuracyRadius'
        TimeZone = Get-IPQMaxMindField 'City.Location.TimeZone'
        SubdivisionCode = Get-IPQMaxMindField 'City.Subdivisions.0.IsoCode'
        Subdivision = Get-IPQMaxMindField 'City.Subdivisions.0.Name'
        CountryCode = Get-IPQMaxMindField 'Country.IsoCode'
        Country = Get-IPQMaxMindField 'Country.Name'
        RegisteredCountryCode = Get-IPQMaxMindField 'Country.RegisteredCountry.IsoCode'
        RegisteredCountry = Get-IPQMaxMindField 'Country.RegisteredCountry.Name'
        ContinentCode = Get-IPQMaxMindField 'City.Continent.Code'
        Continent = Get-IPQMaxMindField 'City.Continent.Name'
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

function ConvertFrom-IPQDbIpPage {
    [CmdletBinding()]
    param([AllowNull()][string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $null
    }
    $countryCode = ''
    if ($Body -match '"countryCode"\s*:\s*"(?<country>[A-Z]{2})"') {
        $countryCode = $Matches.country
    }

    $riskText = ''
    if ($Body -match '(?is)Estimated threat level for this IP address is\s*<span[^>]*>(?<risk>[^<]+)<') {
        $riskText = $Matches.risk.Trim()
    }
    $score = switch -Regex ($riskText) {
        '^(?i:low)$' { 0; break }
        '^(?i:medium)$' { 50; break }
        '^(?i:high)$' { 100; break }
        default { $null }
    }

    $flags = New-IPQFlags
    $crawlerIndex = $Body.IndexOf('>Crawler<', [StringComparison]::OrdinalIgnoreCase)
    if ($crawlerIndex -ge 0) {
        $tail = $Body.Substring($crawlerIndex)
        $matches = [regex]::Matches(
            $tail,
            '(?is)<span[^>]*class=["'']sr-only["''][^>]*>\s*(?<value>Yes|No)(?:\s|&nbsp;)*</span>'
        )
        if ($matches.Count -ge 3) {
            $flags.Robot = $matches[0].Groups['value'].Value -eq 'Yes'
            $flags.Proxy = $matches[1].Groups['value'].Value -eq 'Yes'
            $flags.Abuser = $matches[2].Groups['value'].Value -eq 'Yes'
        }
    }

    return [pscustomobject][ordered]@{
        CountryCode = $countryCode
        RiskText = $riskText
        Score = $score
        Flags = $flags
    }
}

function Get-IPQSourceDBIP {
    param([object]$Context, [string]$Address)

    $response = Invoke-IPQRequest -Context $Context -Uri "https://db-ip.com/$Address"
    $parsed = ConvertFrom-IPQDbIpPage -Body $response.Body
    if (-not $response.Success -or $null -eq $parsed) {
        return New-IPQSourceResult -Name 'DB-IP' -Available $false -Error $(if ($response.Error) { $response.Error } else { '页面内容为空' })
    }

    New-IPQSourceResult `
        -Name 'DB-IP' `
        -Available $true `
        -CountryCode $parsed.CountryCode `
        -Score $parsed.Score `
        -RiskLevel (Get-IPQRiskLevel -SourceName 'DB-IP' -Score $parsed.Score -Hint $parsed.RiskText) `
        -Flags $parsed.Flags `
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

function Get-IPQDnsServerAddresses {
    [CmdletBinding()]
    param([ValidateSet(4, 6)][int]$AddressFamily)

    $familyName = if ($AddressFamily -eq 4) { 'IPv4' } else { 'IPv6' }
    try {
        return @(
            Get-DnsClientServerAddress -AddressFamily $familyName -ErrorAction Stop |
                Where-Object { $_.ServerAddresses } |
                ForEach-Object ServerAddresses |
                Where-Object { $_ } |
                Select-Object -Unique
        )
    }
    catch {
        return @()
    }
}

function Test-IPQUpstreamDnsAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedAddress,
        [AllowEmptyString()][string]$DnsServer = ''
    )

    $resolved = $null
    if (-not [Net.IPAddress]::TryParse($ResolvedAddress, [ref]$resolved)) {
        return $false
    }
    if ($resolved.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $resolved.GetAddressBytes()
        if ($bytes[0] -eq 10) { return $false }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $false }

        $server = $null
        if (
            $DnsServer -and
            [Net.IPAddress]::TryParse($DnsServer, [ref]$server) -and
            $server.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
        ) {
            $serverBytes = $server.GetAddressBytes()
            if (
                $bytes[0] -eq $serverBytes[0] -and
                $bytes[1] -eq $serverBytes[1] -and
                $bytes[2] -eq $serverBytes[2]
            ) {
                return $false
            }
        }
        return $true
    }

    $text = $resolved.ToString()
    return -not (
        $text.StartsWith('fe8', [StringComparison]::OrdinalIgnoreCase) -or
        $text.StartsWith('fc', [StringComparison]::OrdinalIgnoreCase) -or
        $text.StartsWith('fd', [StringComparison]::OrdinalIgnoreCase) -or
        $text.StartsWith('ff', [StringComparison]::OrdinalIgnoreCase)
    )
}

function ConvertTo-IPQUpstreamUnlockType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool[]]$Checks)

    if ($Checks -contains $false) {
        return 'DNS'
    }
    return '原生'
}

function Invoke-IPQDnsCompatibilityProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [ValidateSet(4, 6)][int]$AddressFamily,
        [switch]$IncludeAnswerCount,
        [switch]$IncludeWildcard
    )

    $recordType = if ($AddressFamily -eq 4) { 'A' } else { 'AAAA' }
    $answerRecords = @()
    $addresses = @()
    try {
        $answerRecords = @(
            Resolve-DnsName -Name $Domain -Type $recordType -DnsOnly -ErrorAction Stop |
                Where-Object Section -eq 'Answer'
        )
        $addresses = @(
            $answerRecords |
                Where-Object {
                    $_.QueryType -eq $recordType -and
                    $null -ne $_.PSObject.Properties['IPAddress']
                } |
                ForEach-Object IPAddress |
                Where-Object { $_ }
        )
    }
    catch {
        $addresses = @()
    }

    $dnsServer = @(Get-IPQDnsServerAddresses -AddressFamily $AddressFamily | Select-Object -First 1)
    $check1 = if ($addresses.Count -gt 0) {
        Test-IPQUpstreamDnsAddress `
            -ResolvedAddress $addresses[0] `
            -DnsServer $(if ($dnsServer.Count -gt 0) { $dnsServer[0] } else { '' })
    }
    else {
        $false
    }
    $checks = [Collections.Generic.List[bool]]::new()
    $checks.Add($check1)

    if ($IncludeAnswerCount) {
        # Mirrors upstream Check_DNS_2: zero, one or two answers are classified as DNS.
        $checks.Add($answerRecords.Count -gt 2)
    }
    if ($IncludeWildcard) {
        $wildcardCount = 0
        try {
            $wildcardCount = @(
                Resolve-DnsName `
                    -Name "test$([Random]::Shared.Next(100000, 999999))$([Random]::Shared.Next(100000, 999999)).$Domain" `
                    -Type $recordType `
                    -DnsOnly `
                    -ErrorAction Stop |
                    Where-Object Section -eq 'Answer'
            ).Count
        }
        catch {
            $wildcardCount = 0
        }
        # Mirrors upstream Check_DNS_3: an NXDOMAIN/zero-answer response is native.
        $checks.Add($wildcardCount -eq 0)
    }

    [pscustomobject][ordered]@{
        Domain = $Domain
        Type = ConvertTo-IPQUpstreamUnlockType -Checks $checks.ToArray()
        Checks = $checks.ToArray()
        AnswerCount = $answerRecords.Count
    }
}

function Get-IPQMediaUnlockType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateSet(4, 6)][int]$AddressFamily
    )

    $specifications = @{
        TikTok = @([pscustomobject]@{ Domain = 'tiktok.com'; AnswerCount = $false; Wildcard = $true })
        DisneyPlus = @([pscustomobject]@{ Domain = 'disneyplus.com'; AnswerCount = $false; Wildcard = $true })
        Netflix = @([pscustomobject]@{ Domain = 'netflix.com'; AnswerCount = $true; Wildcard = $true })
        YouTubePremium = @([pscustomobject]@{ Domain = 'www.youtube.com'; AnswerCount = $false; Wildcard = $true })
        AmazonPrimeVideo = @([pscustomobject]@{ Domain = 'www.primevideo.com'; AnswerCount = $false; Wildcard = $true })
        Reddit = @([pscustomobject]@{ Domain = 'reddit.com'; AnswerCount = $true; Wildcard = $false })
        ChatGPT = @(
            [pscustomobject]@{ Domain = 'chat.openai.com'; AnswerCount = $true; Wildcard = $true },
            [pscustomobject]@{ Domain = 'ios.chat.openai.com'; AnswerCount = $true; Wildcard = $true },
            [pscustomobject]@{ Domain = 'api.openai.com'; AnswerCount = $false; Wildcard = $true }
        )
    }
    if (-not $specifications.ContainsKey($ServiceName)) {
        return [pscustomobject]@{ Type = '未知'; Evidence = '没有兼容性 DNS 规则' }
    }

    $probes = [Collections.Generic.List[object]]::new()
    foreach ($specification in $specifications[$ServiceName]) {
        $probes.Add((Invoke-IPQDnsCompatibilityProbe `
            -Domain $specification.Domain `
            -AddressFamily $AddressFamily `
            -IncludeAnswerCount:$specification.AnswerCount `
            -IncludeWildcard:$specification.Wildcard))
    }
    $type = if (@($probes | Where-Object Type -eq 'DNS').Count -gt 0) { 'DNS' } else { '原生' }
    $evidence = ($probes | ForEach-Object {
        "$($_.Domain):$($_.Type)(answers=$($_.AnswerCount))"
    }) -join '; '
    return [pscustomobject]@{ Type = $type; Evidence = $evidence }
}

function Test-IPQTikTok {
    param([object]$Context)

    $response = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://www.tiktok.com/' `
        -Headers ([ordered]@{ 'User-Agent' = $script:UserAgent })
    if ($response.Body -match 'Please wait\.\.\.') {
        $response = Invoke-IPQRequest `
            -Context $Context `
            -Uri 'https://www.tiktok.com/explore' `
            -Headers ([ordered]@{ 'User-Agent' = $script:UserAgent })
    }
    $region = Get-IPQRegionFromText $response.Body
    if ($region) {
        return New-IPQMediaResult -Name 'TikTok' -Status 'Available' -Region $region -Context $Context -Evidence '页面返回地区字段'
    }

    $fallbackHeaders = [ordered]@{
        'User-Agent' = $script:UserAgent
        Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9'
        'Accept-Encoding' = 'gzip'
        'Accept-Language' = 'en'
    }
    $fallback = Invoke-IPQRequest `
        -Context $Context `
        -Uri $(if ($response.Body -match 'Please wait\.\.\.') { 'https://www.tiktok.com/explore' } else { 'https://www.tiktok.com/' }) `
        -Headers $fallbackHeaders
    $fallbackRegion = Get-IPQRegionFromText $fallback.Body
    if ($fallbackRegion) {
        return New-IPQMediaResult `
            -Name 'TikTok' `
            -Status 'IDCOnly' `
            -Region $fallbackRegion `
            -Context $Context `
            -Evidence '官方兼容性第二次页面检测仅识别到 IDC 结果'
    }

    # The upstream fallback is sensitive to the rotating TikTok edge page.
    # One retry against /explore avoids converting a transient empty page into
    # a false block while preserving the same region-based decision rule.
    $retry = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://www.tiktok.com/explore' `
        -Headers $fallbackHeaders
    $retryRegion = Get-IPQRegionFromText $retry.Body
    if ($retryRegion) {
        return New-IPQMediaResult `
            -Name 'TikTok' `
            -Status 'IDCOnly' `
            -Region $retryRegion `
            -Context $Context `
            -Evidence '官方兼容性页面重试识别到 IDC 结果'
    }

    $requestErrors = @(
        $response.Error,
        $fallback.Error,
        $retry.Error
    ) | Where-Object { $_ }
    return New-IPQMediaResult `
        -Name 'TikTok' `
        -Status 'Error' `
        -Context $Context `
        -Error $(if ($requestErrors.Count) { $requestErrors -join '; ' } else { '页面未返回地区字段' })
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
        -Body $deviceBody `
        -NoRedirect
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
        -Body $exchangeBody `
        -NoRedirect
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
        -Body $graphBody
    $graphData = ConvertFrom-IPQJson $graph.Body
    if ($null -eq $graphData) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error $(if ($graph.Error) { $graph.Error } else { 'GraphQL 返回无效' })
    }

    $region = "$(Get-IPQValue $graphData 'extensions.sdk.session.location.countryCode' '')"
    $supported = ConvertTo-IPQBoolean (Get-IPQValue $graphData 'extensions.sdk.session.inSupportedLocation')
    $preview = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://disneyplus.com' `
        -DiscardBody
    $unavailable = $preview.EffectiveUrl -match 'unavailable'
    if ($region -eq 'JP') {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Available' -Region $region -Context $Context -Evidence 'Disney SDK location'
    }
    if ($region -and $supported -eq $false -and -not $unavailable) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Pending' -Region $region -Context $Context -Evidence '地区已识别但服务未标记可用'
    }
    if ($region -and $unavailable) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Blocked' -Context $Context -Evidence '预览页重定向到 unavailable'
    }
    if ($region -and $supported -eq $true) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Available' -Region $region -Context $Context -Evidence 'Disney SDK location'
    }
    if (-not $region) {
        return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Blocked' -Context $Context -Evidence '无可用地区'
    }
    return New-IPQMediaResult -Name 'DisneyPlus' -Status 'Error' -Context $Context -Error 'Disney+ 返回无法归类的状态'
}

function Resolve-IPQNetflixCompatibilityResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Responses,
        [Parameter(Mandatory)][object]$Context
    )

    if ($Responses.Count -ne 2 -or @($Responses | Where-Object { [string]::IsNullOrWhiteSpace($_.Body) }).Count -gt 0) {
        $errorText = @($Responses | Where-Object Error | Select-Object -First 1).Error
        return New-IPQMediaResult `
            -Name 'Netflix' `
            -Status 'Error' `
            -Context $Context `
            -Error $(if ($errorText) { $errorText } else { '官方兼容性片名页响应为空' })
    }

    $region = Get-IPQRegionFromText $Responses[0].Body
    if ($region) {
        $secondRegion = Get-IPQRegionFromText $Responses[1].Body
        if ($secondRegion) {
            $region = $secondRegion
        }
    }
    $firstUnavailable = $Responses[0].Body -match 'Oh no!'
    $secondUnavailable = $Responses[1].Body -match 'Oh no!'
    if ($firstUnavailable -and $secondUnavailable) {
        return New-IPQMediaResult `
            -Name 'Netflix' `
            -Status 'OriginalsOnly' `
            -Region $region `
            -Context $Context `
            -Evidence '两部官方测试影片均返回 Oh no!'
    }
    if (-not $firstUnavailable -or -not $secondUnavailable) {
        return New-IPQMediaResult `
            -Name 'Netflix' `
            -Status 'Available' `
            -Region $region `
            -Context $Context `
            -Evidence '至少一部官方测试影片可访问'
    }
    return New-IPQMediaResult -Name 'Netflix' -Status 'Blocked' -Context $Context -Evidence '官方兼容性兜底判定'
}

function Test-IPQNetflix {
    param([object]$Context)

    $headers = [ordered]@{ 'User-Agent' = $script:UserAgent }
    $responses = @(
        (Invoke-IPQRequest `
            -Context $Context `
            -Uri 'https://www.netflix.com/title/81280792' `
            -Headers $headers `
            -FailOnHttpError `
            -Tls13),
        (Invoke-IPQRequest `
            -Context $Context `
            -Uri 'https://www.netflix.com/title/70143836' `
            -Headers $headers `
            -FailOnHttpError `
            -Tls13)
    )
    return Resolve-IPQNetflixCompatibilityResult -Responses $responses -Context $Context
}

function Test-IPQYouTube {
    param([object]$Context)

    $headers = [ordered]@{
        'Accept-Language' = 'en'
    }
    $cookie = 'YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279'
    $response = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://www.youtube.com/premium' `
        -Headers $headers `
        -Cookie $cookie
    if (-not $response.Success) {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Error' -Context $Context -Error $response.Error
    }
    $region = Get-IPQRegionFromText $response.Body
    if ($response.Body -match 'www\.google\.cn') {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'China' -Region 'CN' -Context $Context -Evidence '页面指向 www.google.cn'
    }
    if ($response.Body -match 'Premium is not available in your country') {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'NoPremium' -Region $region -Context $Context -Evidence '页面明确提示 Premium 不可用'
    }
    if ($response.Body -match 'ad-free') {
        return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Available' -Region $region -Context $Context -Evidence 'Premium 页面可访问'
    }
    return New-IPQMediaResult -Name 'YouTubePremium' -Status 'Error' -Region $region -Context $Context -Error '页面未出现官方 ad-free 判据'
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
    return New-IPQMediaResult -Name 'AmazonPrimeVideo' -Status 'Blocked' -Context $Context -Evidence '页面未找到 currentTerritory'
}

function Test-IPQReddit {
    param([object]$Context)

    $headers = [ordered]@{ 'User-Agent' = $script:UserAgent }
    $response = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://www.reddit.com/' `
        -Headers $headers `
        -FailOnHttpError
    $region = Get-IPQRegionFromText $response.Body
    switch ($response.StatusCode) {
        200 { return New-IPQMediaResult -Name 'Reddit' -Status 'Available' -Region $region -Context $Context -Evidence 'HTTP 200' }
        403 { return New-IPQMediaResult -Name 'Reddit' -Status 'Blocked' -Context $Context -Evidence 'HTTP 403' }
        default {
            return New-IPQMediaResult `
                -Name 'Reddit' `
                -Status 'Error' `
                -Region $region `
                -Context $Context `
                -Error $(if ($response.Error) { $response.Error } else { "HTTP $($response.StatusCode)" })
        }
    }
}

function Resolve-IPQChatGPTCompatibilityResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Web,
        [Parameter(Mandatory)][object]$App,
        [AllowNull()][object]$Favicon,
        [Parameter(Mandatory)][object]$Trace,
        [Parameter(Mandatory)][object]$Context
    )

    $unsupportedCountry = $Web.Body -match 'unsupported_country'
    $vpnBlocked = $App.Body -match 'VPN'
    if ($unsupportedCountry -and $null -ne $Favicon -and $Favicon.StatusCode -ne 403) {
        $unsupportedCountry = $false
    }
    $region = ''
    if ($Trace.Body -match '(?m)^loc=(?<region>[A-Z]{2})\s*$') {
        $region = $Matches.region
    }

    if (-not $vpnBlocked -and -not $unsupportedCountry -and $Web.Success -and $App.Success) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Available' -Region $region -Context $Context -Evidence '官方 Web 与 iOS 判据均通过'
    }
    if ($vpnBlocked -and $unsupportedCountry) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Blocked' -Context $Context -Evidence 'Web 地区限制且 iOS 返回 VPN'
    }
    if (-not $unsupportedCountry -and $vpnBlocked -and $Web.Success) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'WebOnly' -Region $region -Context $Context -Evidence '仅官方 Web 判据通过'
    }
    if ($unsupportedCountry -and -not $vpnBlocked) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'AppOnly' -Region $region -Context $Context -Evidence '仅官方 iOS 判据通过'
    }
    if (-not $Web.Success -and $vpnBlocked) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Blocked' -Context $Context -Evidence 'Web 请求失败且 iOS 返回 VPN'
    }
    if ($Context.AddressFamily -eq 6 -and -not $vpnBlocked -and $App.Success) {
        return New-IPQMediaResult -Name 'ChatGPT' -Status 'Available' -Region $region -Context $Context -Evidence '官方 IPv6 兼容性分支通过'
    }
    return New-IPQMediaResult `
        -Name 'ChatGPT' `
        -Status 'Error' `
        -Region $region `
        -Context $Context `
        -Error (($Web.Error, $App.Error | Where-Object { $_ }) -join '; ')
}

function Test-IPQChatGPT {
    param([object]$Context)

    $edge119 = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0'
    $webHeaders = [ordered]@{
        Authority = 'api.openai.com'
        Accept = '*/*'
        'Accept-Language' = 'zh-CN,zh;q=0.9'
        Authorization = 'Bearer null'
        'Content-Type' = 'application/json'
        Origin = 'https://platform.openai.com'
        Referer = 'https://platform.openai.com/'
        'Sec-CH-UA' = '"Microsoft Edge";v="119", "Chromium";v="119", "Not?A_Brand";v="24"'
        'Sec-CH-UA-Mobile' = '?0'
        'Sec-CH-UA-Platform' = '"Windows"'
        'Sec-Fetch-Dest' = 'empty'
        'Sec-Fetch-Mode' = 'cors'
        'Sec-Fetch-Site' = 'same-site'
        'User-Agent' = $edge119
    }
    $appHeaders = [ordered]@{
        Authority = 'ios.chat.openai.com'
        Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
        'Accept-Language' = 'zh-CN,zh;q=0.9'
        'Sec-CH-UA' = '"Microsoft Edge";v="119", "Chromium";v="119", "Not?A_Brand";v="24"'
        'Sec-CH-UA-Mobile' = '?0'
        'Sec-CH-UA-Platform' = '"Windows"'
        'Sec-Fetch-Dest' = 'document'
        'Sec-Fetch-Mode' = 'navigate'
        'Sec-Fetch-Site' = 'none'
        'Sec-Fetch-User' = '?1'
        'Upgrade-Insecure-Requests' = '1'
        'User-Agent' = $edge119
    }
    $web = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://api.openai.com/compliance/cookie_requirements' `
        -Headers $webHeaders `
        -NoRedirect
    $app = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://ios.chat.openai.com/' `
        -Headers $appHeaders `
        -NoRedirect

    $favicon = $null
    if ($web.Body -match 'unsupported_country') {
        $faviconHeaders = [ordered]@{
            Authority = 'chatgpt.com'
            Accept = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8'
            'Accept-Language' = 'zh-CN,zh;q=0.9'
            Authorization = 'Bearer null'
            Origin = 'https://chatgpt.com'
            Referer = 'https://chatgpt.com/'
            'User-Agent' = $edge119
        }
        $favicon = Invoke-IPQRequest `
            -Context $Context `
            -Uri 'https://chatgpt.com/favicon.ico' `
            -Headers $faviconHeaders `
            -NoRedirect `
            -DiscardBody
    }
    $trace = Invoke-IPQRequest `
        -Context $Context `
        -Uri 'https://chat.openai.com/cdn-cgi/trace' `
        -NoRedirect
    return Resolve-IPQChatGPTCompatibilityResult `
        -Web $web `
        -App $app `
        -Favicon $favicon `
        -Trace $trace `
        -Context $Context
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
    $result = [ordered]@{}
    $index = 0
    foreach ($entry in $checks.GetEnumerator()) {
        $index++
        Write-Progress -Activity '检测流媒体与 AI 可用性' -Status $entry.Key -PercentComplete (($index / $checks.Count) * 100)
        try {
            $result[$entry.Key] = & $entry.Value
            if ($result[$entry.Key].Status -notin @('Error', 'Blocked')) {
                $unlock = Get-IPQMediaUnlockType -ServiceName $entry.Key -AddressFamily $Context.AddressFamily
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
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Address
    )

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

    if ($Context.Proxy) {
        $serviceMap = [ordered]@{}
        $details = [Collections.Generic.List[object]]::new()
        $order = 0
        foreach ($entry in $services.GetEnumerator()) {
            $serviceMap[$entry.Key] = $false
            $details.Add([pscustomobject][ordered]@{
                Order = $order
                Name = $entry.Key
                Domain = $entry.Value
                Reachable = $false
                Host = ''
                Error = '上游代理模式不将 SMTP 25 端口探测送入代理'
                State = 'ProxyUnsupported'
                Banner = ''
            })
            $order++
        }
        return [pscustomobject][ordered]@{
            RouteType = $Context.RouteType
            Port25 = $false
            Port25Status = 'ProxyUnsupported'
            SourceBinding = 'Proxy'
            Services = [pscustomobject]$serviceMap
            Port25Detail = [pscustomobject][ordered]@{
                Order = -1
                Name = '__Port25'
                Domain = ''
                Reachable = $false
                Host = 'smtp.mailgun.org'
                Error = '上游代理模式不检测本地 25 端口'
                State = 'ProxyUnsupported'
                Banner = ''
            }
            Details = $details.ToArray()
        }
    }

    $workItems = @(
        [pscustomobject]@{
            Order = -1
            Name = '__Port25'
            Domain = ''
            Host = 'smtp.mailgun.org'
        }
    )
    $order = 0
    foreach ($entry in $services.GetEnumerator()) {
        $workItems += [pscustomobject]@{
            Order = $order
            Name = $entry.Key
            Domain = $entry.Value
            Host = ''
        }
        $order++
    }

    $curlPath = $Context.CurlPath
    $family = $Context.AddressFamily
    $proxy = $Context.Proxy
    $interfaceName = $Context.Interface
    $publicAddress = $Address
    $publicAddressAssigned = $false
    try {
        $publicAddressAssigned = @(
            Get-NetIPAddress -IPAddress $Address -ErrorAction Stop
        ).Count -gt 0
    }
    catch {
        $publicAddressAssigned = $false
    }
    $localPortOccupied = $false
    try {
        $localPortOccupied = @(
            Get-NetTCPConnection -LocalPort 25 -ErrorAction SilentlyContinue
        ).Count -gt 0
    }
    catch {
        $localPortOccupied = $false
    }
    Write-Progress -Activity '检测 SMTP 25 端口' -Status '并发连接邮件服务' -PercentComplete 10
    $checks = @(
        $workItems | ForEach-Object -Parallel {
            $item = $_
            if ($item.Host) {
                $mxHosts = @($item.Host)
            }
            else {
                try {
                $mxHosts = @(
                    Resolve-DnsName -Name $item.Domain -Type MX -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.Type -eq 'MX' -and $_.NameExchange } |
                        Sort-Object Preference |
                        ForEach-Object { $_.NameExchange.TrimEnd('.') } |
                        Select-Object -First 1
                )
                }
                catch {
                    $mxHosts = @()
                }
            }
            if ($mxHosts.Count -eq 0) {
                [pscustomobject]@{
                    Order = $item.Order
                    Name = $item.Name
                    Domain = $item.Domain
                    Reachable = $false
                    Host = ''
                    Error = '未解析到 MX'
                    State = 'Blocked'
                    Banner = ''
                }
                return
            }
            if ($item.Name -eq '__Port25' -and $using:localPortOccupied) {
                [pscustomobject]@{
                    Order = $item.Order
                    Name = $item.Name
                    Domain = $item.Domain
                    Reachable = $null
                    Host = $mxHosts[0]
                    Error = '本地端口 25 已占用'
                    State = 'Occupied'
                    Banner = ''
                }
                return
            }
            if ($item.Name -eq '__Port25' -and $using:proxy) {
                [pscustomobject]@{
                    Order = $item.Order
                    Name = $item.Name
                    Domain = $item.Domain
                    Reachable = $false
                    Host = $mxHosts[0]
                    Error = '官方语义下代理模式不检测本地 25 端口'
                    State = 'ProxyUnsupported'
                    Banner = ''
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
                            if ($using:publicAddressAssigned) {
                                $localAddress = [Net.IPAddress]::Parse($using:publicAddress)
                                $localPort = if ($item.Name -eq '__Port25') { 25 } else { 0 }
                                $client.Client.Bind([Net.IPEndPoint]::new($localAddress, $localPort))
                            }
                            $connectTask = $client.ConnectAsync($targetAddress, 25)
                            if ($connectTask.Wait(3000) -and $client.Connected) {
                                $stream = $client.GetStream()
                                $stream.ReadTimeout = 4000
                                $buffer = [byte[]]::new(1024)
                                $banner = ''
                                try {
                                    $read = $stream.Read($buffer, 0, $buffer.Length)
                                    if ($read -gt 0) {
                                        $banner = [Text.Encoding]::ASCII.GetString($buffer, 0, $read).Trim()
                                    }
                                }
                                catch {
                                    $lastError = $_.Exception.GetBaseException().Message
                                }
                                if ($banner -match '(?m)^220[\s-]') {
                                    [pscustomobject]@{
                                        Order = $item.Order
                                        Name = $item.Name
                                        Domain = $item.Domain
                                        Reachable = $true
                                        Host = $hostName
                                        Error = ''
                                        State = 'Available'
                                        Banner = ($banner -split "`r?`n")[0]
                                    }
                                    return
                                }
                                $lastError = if ($banner) { "未收到 220：$(($banner -split "`r?`n")[0])" } elseif ($lastError) { $lastError } else { 'TCP 已连接但未收到 SMTP 220' }
                            }
                            else {
                                $lastError = 'TCP 连接超时'
                            }
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
                    '--show-error',
                    '--verbose',
                    '--connect-timeout', '3',
                    '--max-time', '5',
                    $(if ($using:family -eq 4) { '--ipv4' } else { '--ipv6' })
                )
                if ($using:proxy) {
                    $arguments += @('--proxy', $using:proxy)
                }
                else {
                    $arguments += @('--noproxy', '*')
                }
                if ($using:interfaceName) {
                    $arguments += @('--interface', $using:interfaceName)
                }
                $arguments += "smtp://${hostName}:25"
                $output = & $using:curlPath @arguments 2>&1
                $exitCode = $LASTEXITCODE
                $text = ($output | Out-String).Trim()
                $bannerMatch = [regex]::Match(
                    $text,
                    '(?m)^(?:<\s*)?(?<banner>220[\s-][^\r\n]*)'
                )
                if ($exitCode -eq 0 -or $bannerMatch.Success) {
                    [pscustomobject]@{
                        Order = $item.Order
                        Name = $item.Name
                        Domain = $item.Domain
                        Reachable = $true
                        Host = $hostName
                        Error = ''
                        State = 'Available'
                        Banner = $(if ($bannerMatch.Success) { $bannerMatch.Groups['banner'].Value } else { '' })
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
                State = 'Blocked'
                Banner = ''
            }
        } -ThrottleLimit 6 |
            Sort-Object Order
    )
    Write-Progress -Activity '检测 SMTP 25 端口' -Completed

    $portCheck = @($checks | Where-Object Name -eq '__Port25' | Select-Object -First 1)
    $serviceChecks = @($checks | Where-Object Name -ne '__Port25')
    $serviceMap = [ordered]@{}
    foreach ($check in $serviceChecks) {
        $serviceMap[$check.Name] = $check.Reachable
    }
    [pscustomobject][ordered]@{
        RouteType = $Context.RouteType
        Port25 = $(if ($portCheck.Count -gt 0) { $portCheck[0].Reachable } else { $false })
        Port25Status = $(if ($portCheck.Count -gt 0) { $portCheck[0].State } else { 'Blocked' })
        SourceBinding = $(if ($Context.Proxy) {
            'Proxy'
        }
        elseif ($publicAddressAssigned) {
            'ExactPublicAddress'
        }
        else {
            'NATEquivalent'
        })
        Services = [pscustomobject]$serviceMap
        Port25Detail = $(if ($portCheck.Count -gt 0) { $portCheck[0] } else { $null })
        Details = $serviceChecks
    }
}

function Test-IPQExpectedEmptyDnsErrorId {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$FullyQualifiedErrorId)

    return (
        $FullyQualifiedErrorId -like 'DNS_ERROR_RCODE_NAME_ERROR,*' -or
        $FullyQualifiedErrorId -like 'DNS_INFO_NO_RECORDS,*'
    )
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
                $answers = @(
                    Resolve-DnsName `
                        -Name $query `
                        -Type A `
                        -DnsOnly `
                        -QuickTimeout `
                        -ErrorAction Stop |
                        Where-Object {
                            $_.Section -eq 'Answer' -and
                            $_.QueryType -eq 'A' -and
                            $null -ne $_.PSObject.Properties['IPAddress']
                        } |
                        ForEach-Object IPAddress |
                        Where-Object { $_ }
                )
                if ($answers.Count -eq 1 -and $answers[0] -eq '127.0.0.2') {
                    [pscustomobject]@{ Zone = $zone; Status = 'Blacklisted'; Answers = $answers; HadError = $false; Error = '' }
                }
                elseif ($answers.Count -gt 0) {
                    [pscustomobject]@{ Zone = $zone; Status = 'Marked'; Answers = $answers; HadError = $false; Error = '' }
                }
                else {
                    [pscustomobject]@{ Zone = $zone; Status = 'Clean'; Answers = @(); HadError = $false; Error = '' }
                }
            }
            catch {
                # ForEach-Object -Parallel runs in an isolated runspace, so keep
                # this small predicate local instead of calling a module helper.
                $isExpectedEmpty = (
                    $_.FullyQualifiedErrorId -like 'DNS_ERROR_RCODE_NAME_ERROR,*' -or
                    $_.FullyQualifiedErrorId -like 'DNS_INFO_NO_RECORDS,*'
                )
                [pscustomobject]@{
                    Zone = $zone
                    Status = 'Clean'
                    Answers = @()
                    HadError = -not $isExpectedEmpty
                    Error = $(if ($isExpectedEmpty) { '' } else { $_.Exception.Message })
                }
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
        Errors = @($checks | Where-Object HadError).Count
        Details = @($checks | Where-Object { $_.Status -ne 'Clean' -or $_.HadError } | Sort-Object Status, Zone)
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
            $mail = Get-IPQMailChecks -Context $context -Address $address
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
        if (
            -not $SkipMail -and
            $null -ne $mail -and
            $mail.SourceBinding -eq 'NATEquivalent'
        ) {
            $warnings.Add('SMTP：出口公网 IP 不在本机网卡上，采用 NAT 等价探测；避免官方 Docker 的源地址绑定假失败')
        }
        if (
            -not $SkipDnsbl -and
            $null -ne $dnsbl -and
            $dnsbl.Errors -gt 0
        ) {
            $warnings.Add("DNSBL：$($dnsbl.Errors) 项查询异常；按官方 dig 空响应语义计入正常，并在 JSON 中保留错误")
        }

        $latitude = Get-IPQValue $maxMind 'Latitude'
        $longitude = Get-IPQValue $maxMind 'Longitude'
        $accuracyRadius = Get-IPQValue $maxMind 'AccuracyRadius'
        $countryCode = Get-IPQValue $maxMind 'CountryCode'
        $registeredCountryCode = Get-IPQValue $maxMind 'RegisteredCountryCode'
        $info = [pscustomobject][ordered]@{
            SourceAvailable = $maxMind.Available
            SourceError = Get-IPQValue $maxMind 'Error'
            ASN = Get-IPQValue $maxMind 'ASN'
            Organization = Get-IPQValue $maxMind 'Organization'
            City = Get-IPQValue $maxMind 'City'
            PostalCode = Get-IPQValue $maxMind 'PostalCode'
            SubdivisionCode = Get-IPQValue $maxMind 'SubdivisionCode'
            Subdivision = Get-IPQValue $maxMind 'Subdivision'
            CountryCode = $countryCode
            Country = Get-IPQValue $maxMind 'Country'
            RegisteredCountryCode = $registeredCountryCode
            RegisteredCountry = Get-IPQValue $maxMind 'RegisteredCountry'
            ContinentCode = Get-IPQValue $maxMind 'ContinentCode'
            Continent = Get-IPQValue $maxMind 'Continent'
            Latitude = $latitude
            Longitude = $longitude
            DMS = ConvertTo-IPQDms -Latitude $latitude -Longitude $longitude
            AccuracyRadiusKm = $accuracyRadius
            TimeZone = Get-IPQValue $maxMind 'TimeZone'
            Map = Get-IPQMapUrl `
                -Latitude $latitude `
                -Longitude $longitude `
                -AccuracyRadius $accuracyRadius
            GeoType = if (
                $countryCode -and
                $registeredCountryCode -and
                "$countryCode" -eq "$registeredCountryCode"
            ) {
                '原生IP'
            }
            elseif ($countryCode -and $registeredCountryCode) {
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
                UpstreamVersion = $script:UpstreamVersion
                Upstream = 'https://github.com/xykt/IPQuality'
                TimeUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
                TimeLocal = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') CST"
                Address = $displayAddress
                AddressFamily = "IPv$family"
                RouteType = $context.RouteType
                DiscoveryEndpoint = $public.Endpoint
                Privacy = if ($FullIP) { 'FullAddress' } else { 'MaskedAddress' }
                UserAgent = $script:UserAgent
                CompatibilityBaseline = $(if ($script:UpstreamScriptSha256) {
                    "xykt/IPQuality ip.sh sha256:$($script:UpstreamScriptSha256)"
                }
                else {
                    'xykt/IPQuality ip.sh (hash unavailable)'
                })
                ProxyPolicy = 'ExplicitOnly'
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
        'NoPremium' { return '禁会员' }
        'China' { return '中国' }
        'IDCOnly' { return '机房' }
        'WebOnly' { return '仅网页' }
        'AppOnly' { return '仅APP' }
        'Unknown' { return '未知' }
        default { return $(if ($Status) { $Status } else { '未知' }) }
    }
}

function ConvertTo-IPQPort25StatusLabel {
    param([AllowEmptyString()][string]$Status)
    switch ($Status) {
        'Available' { return '可用' }
        'Occupied' { return '占用' }
        'ProxyUnsupported' { return '代理不测' }
        default { return '阻断' }
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
        $port25Status = if ($null -ne $Result.Mail.PSObject.Properties['Port25Status']) {
            ConvertTo-IPQPort25StatusLabel $Result.Mail.Port25Status
        }
        else {
            $(if ($Result.Mail.Port25) { '可用' } else { '阻断' })
        }
        [void]$builder.AppendLine("本地 25 端口出站：$port25Status")
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

function Get-IPQDisplayWidth {
    param([AllowNull()][object]$Text)

    $width = 0
    foreach ($character in "$Text".ToCharArray()) {
        $code = [int]$character
        $width += if (
            ($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60)
        ) { 2 } else { 1 }
    }
    return $width
}

function Format-IPQFixedWidth {
    param(
        [AllowNull()][object]$Text,
        [Parameter(Mandatory)][int]$Width,
        [ValidateSet('Left', 'Center', 'Right')][string]$Align = 'Left'
    )

    $value = "$Text"
    while ((Get-IPQDisplayWidth $value) -gt $Width -and $value.Length -gt 0) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    $padding = [Math]::Max(0, $Width - (Get-IPQDisplayWidth $value))
    switch ($Align) {
        'Right' { return (' ' * $padding) + $value }
        'Center' {
            $left = [Math]::Floor($padding / 2)
            return (' ' * $left) + $value + (' ' * ($padding - $left))
        }
        default { return $value + (' ' * $padding) }
    }
}

function Get-IPQBadgeColor {
    param([AllowNull()][object]$Value)

    switch -Regex ("$Value") {
        '^(家宽|手机|原生|原生IP|解锁|可用|干净|否|未检出|极低风险|低风险)$' { return 'DarkGreen' }
        '^(机房|CDN|广播IP|屏蔽|失败|阻断|黑名单|是|检出|中国|禁会员|高风险|极高风险|建议封禁)$' { return 'DarkRed' }
        '^(商业|教育|政府|银行|组织|军队|图书馆|其他|DNS|待支持|仅自制|仅网页|仅APP|标记|冲突|较高风险|中风险|可疑IP|存在风险)$' { return 'DarkYellow' }
        default { return 'DarkGray' }
    }
}

function Write-IPQBadge {
    param(
        [AllowNull()][object]$Value,
        [ValidateRange(3, 20)][int]$Width = 9
    )

    $text = Format-IPQCell $Value
    $cell = Format-IPQFixedWidth -Text $text -Width $Width -Align Center
    Write-Host -NoNewline $cell -ForegroundColor White -BackgroundColor (Get-IPQBadgeColor $text)
}

function Write-IPQSectionTitle {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host $Text -ForegroundColor White
}

function Write-IPQKeyValue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$Value,
        [ConsoleColor]$Color = 'Green'
    )
    Write-Host -NoNewline (Format-IPQFixedWidth -Text $Label -Width 22) -ForegroundColor Cyan
    Write-Host (Format-IPQCell $Value) -ForegroundColor $Color
}

function Write-IPQMatrixHeader {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Values,
        [ValidateRange(5, 16)][int]$CellWidth,
        [ValidateRange(5, 16)][int]$LabelWidth = 9
    )
    Write-Host -NoNewline (Format-IPQFixedWidth -Text $Label -Width $LabelWidth) -ForegroundColor Cyan
    foreach ($value in $Values) {
        Write-Host -NoNewline (Format-IPQFixedWidth -Text $value -Width $CellWidth -Align Center) -ForegroundColor DarkCyan
    }
    Write-Host ''
}

function Write-IPQMatrixBadges {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Values,
        [ValidateRange(5, 16)][int]$CellWidth,
        [ValidateRange(5, 16)][int]$LabelWidth = 9
    )
    Write-Host -NoNewline (Format-IPQFixedWidth -Text $Label -Width $LabelWidth) -ForegroundColor Cyan
    foreach ($value in $Values) {
        $text = Format-IPQCell $value
        if ($text -in @('-', '不可用', '未知')) {
            Write-Host -NoNewline (Format-IPQFixedWidth -Text $text -Width $CellWidth -Align Center) -ForegroundColor DarkGray
            continue
        }
        $badgeWidth = [Math]::Min(
            $CellWidth - 1,
            [Math]::Max(4, (Get-IPQDisplayWidth $text) + 2)
        )
        $leftPadding = [Math]::Floor(($CellWidth - $badgeWidth) / 2)
        $rightPadding = $CellWidth - $badgeWidth - $leftPadding
        Write-Host -NoNewline (' ' * $leftPadding)
        Write-IPQBadge -Value $text -Width $badgeWidth
        Write-Host -NoNewline (' ' * $rightPadding)
    }
    Write-Host ''
}

function Write-IPQMatrixTexts {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Values,
        [ValidateRange(5, 16)][int]$CellWidth,
        [ValidateRange(5, 16)][int]$LabelWidth = 9
    )
    Write-Host -NoNewline (Format-IPQFixedWidth -Text $Label -Width $LabelWidth) -ForegroundColor Cyan
    foreach ($value in $Values) {
        $text = Format-IPQCell $value
        $color = switch ($text) {
            '是' { 'Red' }
            '否' { 'Green' }
            '无' { 'Green' }
            '-' { 'DarkGray' }
            default { 'Green' }
        }
        Write-Host -NoNewline (Format-IPQFixedWidth -Text $text -Width $CellWidth -Align Center) -ForegroundColor $color
    }
    Write-Host ''
}

function Write-IPQRiskBar {
    param([Parameter(Mandatory)][object]$Source)

    $score = [Math]::Max(0, [Math]::Min(100, [double]$Source.Score))
    $sourceName = "$($Source.Name)"
    $displayName = switch ($sourceName) {
        'Scamalytics' { 'SCAMALYTICS' }
        default { $sourceName }
    }
    $riskLevel = Get-IPQValue $Source 'RiskLevel' ''
    if (-not $riskLevel) {
        $riskLevel = Get-IPQRiskLevel -SourceName $sourceName -Score $score
    }

    $scaleScore = $score
    $lowBoundary = 33.0
    $mediumBoundary = 66.0
    $maximumBoundary = 100.0
    switch ($sourceName) {
        'IP2Location' {
            $lowBoundary = 33
            $mediumBoundary = 66
            $maximumBoundary = 99
        }
        'Scamalytics' {
            $lowBoundary = 20
            $mediumBoundary = 60
            $maximumBoundary = 100
        }
        'ipapi' {
            $scaleScore = $score * 100
            $lowBoundary = 85
            $mediumBoundary = 300
            $maximumBoundary = 10000
        }
        'AbuseIPDB' {
            $lowBoundary = 25
            $mediumBoundary = 25
            $maximumBoundary = 100
        }
        'IPQS' {
            $lowBoundary = 75
            $mediumBoundary = 85
            $maximumBoundary = 100
        }
    }

    if ($scaleScore -ge $mediumBoundary) {
        $denominator = [Math]::Max(1, $maximumBoundary - $mediumBoundary)
        $coloredWidth = 33 + [Math]::Floor(15 * (($scaleScore - $mediumBoundary) / $denominator))
    }
    elseif ($scaleScore -ge $lowBoundary) {
        $denominator = [Math]::Max(1, $mediumBoundary - $lowBoundary)
        $coloredWidth = 17 + [Math]::Floor(16 * (($scaleScore - $lowBoundary) / $denominator))
    }
    else {
        $denominator = [Math]::Max(1, $lowBoundary)
        $coloredWidth = 1 + [Math]::Floor(16 * ($scaleScore / $denominator))
    }
    $coloredWidth = [Math]::Max(1, [Math]::Min(48, $coloredWidth))

    $displayScore = if ($sourceName -eq 'DB-IP') {
        ''
    }
    elseif ($sourceName -eq 'ipapi') {
        "$($Source.Score)%"
    }
    else {
        "$($Source.Score)"
    }
    $marker = "$displayScore|"
    $coloredWidth = [Math]::Max($coloredWidth, $marker.Length)
    $characters = [char[]](' ' * $coloredWidth)
    $markerStart = $coloredWidth - $marker.Length
    for ($index = 0; $index -lt $marker.Length; $index++) {
        $characters[$markerStart + $index] = $marker[$index]
    }
    $track = -join $characters

    Write-Host -NoNewline (Format-IPQFixedWidth -Text "$displayName：" -Width 17) -ForegroundColor Cyan
    $greenLength = [Math]::Min(16, $coloredWidth)
    $yellowLength = [Math]::Min(16, [Math]::Max(0, $coloredWidth - 16))
    $redLength = [Math]::Max(0, $coloredWidth - 32)
    if ($greenLength -gt 0) {
        Write-Host -NoNewline $track.Substring(0, $greenLength) -ForegroundColor White -BackgroundColor DarkGreen
    }
    if ($yellowLength -gt 0) {
        Write-Host -NoNewline $track.Substring(16, $yellowLength) -ForegroundColor White -BackgroundColor DarkYellow
    }
    if ($redLength -gt 0) {
        Write-Host -NoNewline $track.Substring(32, $redLength) -ForegroundColor White -BackgroundColor DarkRed
    }
    Write-Host $riskLevel -ForegroundColor (Get-IPQBadgeColor $riskLevel)
}

function Write-IPQPrettyReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    $lineWidth = 72
    $separator = '#' * $lineWidth
    Write-Host $separator -ForegroundColor DarkGray
    Write-Host (Format-IPQFixedWidth -Text "IP质量体检报告：$($Result.Head.Address)" -Width $lineWidth -Align Center) -ForegroundColor Green
    Write-Host (Format-IPQFixedWidth -Text 'https://github.com/xykt/IPQuality' -Width $lineWidth -Align Center) -ForegroundColor DarkCyan
    Write-Host (Format-IPQFixedWidth -Text 'ipq' -Width $lineWidth -Align Center) -ForegroundColor Gray
    $reportTime = Get-IPQValue $Result.Head 'TimeLocal' (Get-IPQValue $Result.Head 'TimeUtc')
    $upstreamVersion = Get-IPQValue $Result.Head 'UpstreamVersion' (Get-IPQValue $Result.Head 'Version')
    Write-Host (Format-IPQFixedWidth -Text "报告时间：$reportTime  脚本版本：$upstreamVersion" -Width $lineWidth -Align Center) -ForegroundColor Gray
    Write-Host $separator -ForegroundColor DarkGray

    Write-IPQSectionTitle '一、基础信息（Maxmind 数据库）'
    Write-IPQKeyValue '自治系统号：' "AS$(Format-IPQCell (Get-IPQValue $Result.Info 'ASN'))"
    Write-IPQKeyValue '组织：' (Get-IPQValue $Result.Info 'Organization')
    $cityParts = @(
        (Get-IPQValue $Result.Info 'Subdivision'),
        (Get-IPQValue $Result.Info 'City'),
        (Get-IPQValue $Result.Info 'PostalCode')
    ) | Where-Object { $_ }
    $dms = Get-IPQValue $Result.Info 'DMS'
    if ($dms) {
        Write-IPQKeyValue '坐标：' $dms
    }
    $map = Get-IPQValue $Result.Info 'Map' ''
    if ($map) {
        Write-IPQKeyValue '地图：' $map
    }
    Write-IPQKeyValue '城市：' ($cityParts -join ', ')
    Write-IPQKeyValue '使用地：' "[$(Format-IPQCell (Get-IPQValue $Result.Info 'CountryCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'Country')), [$(Format-IPQCell (Get-IPQValue $Result.Info 'ContinentCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'Continent'))"
    Write-IPQKeyValue '注册地：' "[$(Format-IPQCell (Get-IPQValue $Result.Info 'RegisteredCountryCode'))] $(Format-IPQCell (Get-IPQValue $Result.Info 'RegisteredCountry'))"
    Write-IPQKeyValue '时区：' (Get-IPQValue $Result.Info 'TimeZone')
    $geoType = Get-IPQValue $Result.Info 'GeoType' '未知'
    Write-Host -NoNewline (Format-IPQFixedWidth -Text 'IP类型：' -Width 22) -ForegroundColor Cyan
    Write-Host -NoNewline '   '
    Write-IPQBadge -Value $geoType -Width 8
    Write-Host ''

    Write-IPQSectionTitle '二、IP类型属性'
    if (@($Result.DataSources).Count -eq 0) {
        Write-Host '已跳过' -ForegroundColor DarkGray
    }
    else {
        $assessment = Get-IPQValue $Result 'TypeAssessment'
        if ($null -eq $assessment) {
            $assessment = Get-IPQTypeAssessment -Sources $Result.DataSources
        }
        $typeNames = @('IPinfo', 'ipregistry', 'ipapi', 'IP2Location', 'AbuseIPDB')
        Write-IPQMatrixHeader -Label '数据库：' -Values $typeNames -CellWidth 12 -LabelWidth 11
        Write-IPQMatrixBadges -Label '使用类型：' -Values @($assessment.Sources | ForEach-Object { if ($_.Available) { $_.UsageLabel } else { '不可用' } }) -CellWidth 12 -LabelWidth 11
        Write-IPQMatrixBadges -Label '公司类型：' -Values @($assessment.Sources | ForEach-Object { if ($_.Available) { $_.CompanyLabel } else { '不可用' } }) -CellWidth 12 -LabelWidth 11
    }

    Write-IPQSectionTitle '三、风险评分'
    Write-Host -NoNewline (Format-IPQFixedWidth -Text '风险等级：' -Width 17) -ForegroundColor Cyan
    Write-Host -NoNewline (Format-IPQFixedWidth -Text '极低       低' -Width 16 -Align Center) -ForegroundColor White -BackgroundColor DarkGreen
    Write-Host -NoNewline (Format-IPQFixedWidth -Text '中等' -Width 16 -Align Center) -ForegroundColor White -BackgroundColor DarkYellow
    Write-Host (Format-IPQFixedWidth -Text '高       极高' -Width 16 -Align Center) -ForegroundColor White -BackgroundColor DarkRed
        $scoreSources = @(
            foreach ($name in @('IP2Location', 'Scamalytics', 'ipapi', 'AbuseIPDB', 'IPQS', 'DB-IP')) {
                $Result.DataSources |
                    Where-Object { $_.Name -eq $name -and $_.Available -and $null -ne $_.Score } |
                    Select-Object -First 1
            }
        )
    if ($scoreSources.Count -eq 0) {
        Write-Host '没有可用评分' -ForegroundColor DarkGray
    }
    else {
        foreach ($source in $scoreSources) {
            Write-IPQRiskBar -Source $source
        }
    }

    Write-IPQSectionTitle '四、风险因子'
    if (@($Result.DataSources).Count -eq 0) {
        Write-Host '已跳过' -ForegroundColor DarkGray
    }
    else {
        $factorOrder = @('IP2Location', 'ipapi', 'ipregistry', 'IPQS', 'Scamalytics', 'ipdata', 'IPinfo', 'DB-IP')
        $factorSourceList = [Collections.Generic.List[object]]::new()
        foreach ($name in $factorOrder) {
            $match = @($Result.DataSources | Where-Object Name -eq $name)
            $factorSourceList.Add($(if ($match.Count) { $match[0] } else { $null }))
        }
        $factorSources = $factorSourceList.ToArray()
        Write-Host -NoNewline '库： ' -ForegroundColor Cyan
        Write-Host 'IP2Location ipapi ipregistry IPQS SCAMALYTICS ipdata IPinfo DB-IP' -ForegroundColor DarkCyan
        Write-IPQMatrixTexts -Label '地区：' -Values @($factorSources | ForEach-Object { if ($null -ne $_ -and $_.Available -and $_.CountryCode) { "[$($_.CountryCode)]" } else { '-' } }) -CellWidth 8 -LabelWidth 8
        foreach ($definition in @(
            @('代理：', 'Proxy'),
            @('Tor：', 'Tor'),
            @('VPN：', 'VPN'),
            @('服务器：', 'Server'),
            @('滥用：', 'Abuser'),
            @('机器人：', 'Robot')
        )) {
            $propertyName = $definition[1]
            Write-IPQMatrixTexts -Label $definition[0] -Values @(
                $factorSources | ForEach-Object {
                    if ($null -ne $_ -and $_.Available) { Format-IPQFactor $_.Flags.$propertyName } else { '无' }
                }
            ) -CellWidth 8 -LabelWidth 8
        }
    }

    Write-IPQSectionTitle '五、流媒体及AI服务解锁检测'
    if (@($Result.Media.PSObject.Properties).Count -eq 0) {
        Write-Host '已跳过' -ForegroundColor DarkGray
    }
    else {
        $mediaOrder = @('TikTok', 'DisneyPlus', 'Netflix', 'YouTubePremium', 'AmazonPrimeVideo', 'Reddit', 'ChatGPT')
        $mediaLabels = @('TikTok', 'Disney+', 'Netflix', 'YouTube', 'AmazonPV', 'Reddit', 'ChatGPT')
        $mediaItemList = [Collections.Generic.List[object]]::new()
        foreach ($name in $mediaOrder) {
            $mediaItemList.Add((Get-IPQValue $Result.Media $name))
        }
        $mediaItems = $mediaItemList.ToArray()
        Write-IPQMatrixHeader -Label '服务商：' -Values $mediaLabels -CellWidth 9
        Write-IPQMatrixBadges -Label '状态：' -Values @($mediaItems | ForEach-Object { if ($null -ne $_) { ConvertTo-IPQMediaStatusLabel $_.Status } else { '失败' } }) -CellWidth 9
        Write-IPQMatrixTexts -Label '地区：' -Values @($mediaItems | ForEach-Object { if ($null -ne $_ -and $_.Region) { "[$($_.Region)]" } else { '-' } }) -CellWidth 9
        Write-IPQMatrixBadges -Label '方式：' -Values @($mediaItems | ForEach-Object { if ($null -ne $_) { Format-IPQCell $_.Type } else { '-' } }) -CellWidth 9
    }

    Write-IPQSectionTitle '六、邮局连通性及黑名单检测'
    Write-Host -NoNewline '本地25端口出站：' -ForegroundColor Cyan
    if ($null -eq $Result.Mail) {
        Write-Host '已跳过' -ForegroundColor DarkGray
    }
    else {
        $port25Status = if ($null -ne $Result.Mail.PSObject.Properties['Port25Status']) {
            ConvertTo-IPQPort25StatusLabel $Result.Mail.Port25Status
        }
        else {
            $(if ($Result.Mail.Port25) { '可用' } else { '阻断' })
        }
        $port25Color = switch ($port25Status) {
            '可用' { 'Green' }
            '占用' { 'Yellow' }
            '代理不测' { 'DarkYellow' }
            default { 'Red' }
        }
        Write-Host $port25Status -ForegroundColor $port25Color
    }
    if ($null -ne $Result.Mail) {
        $serviceProperties = @($Result.Mail.Services.PSObject.Properties)
        Write-Host -NoNewline '通信：  ' -ForegroundColor Cyan
        foreach ($property in $serviceProperties) {
            Write-Host -NoNewline $property.Name -ForegroundColor White -BackgroundColor $(if ($property.Value) { 'DarkGreen' } else { 'DarkRed' })
            Write-Host -NoNewline ' '
        }
        Write-Host ''
    }
    Write-Host -NoNewline 'IP地址黑名单数据库：  ' -ForegroundColor Cyan
    if ($null -eq $Result.DNSBlacklist) {
        Write-Host -NoNewline '已跳过' -ForegroundColor DarkGray
    }
    elseif (-not $Result.DNSBlacklist.Supported) {
        Write-Host -NoNewline '不支持' -ForegroundColor DarkGray
    }
    else {
        foreach ($summary in @(
            @("有效 $($Result.DNSBlacklist.Total)", 'Cyan'),
            @("正常 $($Result.DNSBlacklist.Clean)", 'Green'),
            @("已标记 $($Result.DNSBlacklist.Marked)", 'Yellow'),
            @("黑名单 $($Result.DNSBlacklist.Blacklisted)", 'Red')
        )) {
            Write-Host -NoNewline "$($summary[0])   " -ForegroundColor $summary[1]
        }
    }
    Write-Host ''

    Write-Host ('=' * $lineWidth) -ForegroundColor DarkGray
}

function Format-IPQualityReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    $terminalWidth = 0
    try {
        $terminalWidth = $Host.UI.RawUI.WindowSize.Width
    }
    catch {
        $terminalWidth = 0
    }
    if ($terminalWidth -gt 0 -and $terminalWidth -lt 72) {
        Write-Host ''
        Write-Host (Get-IPQualityReportText -Result $Result)
        return
    }
    Write-IPQPrettyReport -Result $Result
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
