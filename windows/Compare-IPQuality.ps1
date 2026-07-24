#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OriginalPath,
    [Parameter(Mandatory)][string]$WindowsPath,
    [string]$Output,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value {
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

function ConvertFrom-OriginalBadge {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = "$Value" -replace '(?:x1b|\x1b)\[[0-9;]*m', ''
    return $text.Trim()
}

function ConvertTo-CanonicalMediaStatus {
    param([AllowNull()][object]$Value)

    $text = ConvertFrom-OriginalBadge $Value
    switch ($text) {
        '解锁' { return 'Available' }
        '屏蔽' { return 'Blocked' }
        '失败' { return 'Error' }
        '仅自制' { return 'OriginalsOnly' }
        '禁会员' { return 'NoPremium' }
        '中国' { return 'China' }
        '机房' { return 'IDCOnly' }
        '待支持' { return 'Pending' }
        '仅网页' { return 'WebOnly' }
        '仅APP' { return 'AppOnly' }
        default { return $text }
    }
}

function ConvertTo-CanonicalScore {
    param([AllowNull()][object]$Value)

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
        return "$Value"
    }
    return [Math]::Round($number, 2)
}

function ConvertTo-ComparableText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or "$Value" -eq 'null') {
        return '<null>'
    }
    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [float]) {
        return ([double]$Value).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    }
    return "$Value".Trim()
}

function ConvertTo-CanonicalOptionalText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = (ConvertFrom-OriginalBadge $Value).Trim()
    if ($text -in @('', '-', 'N/A', 'null')) {
        return $null
    }
    return $text
}

function Test-ComparisonValueAvailable {
    param([AllowNull()][object]$Value)

    return $null -ne (ConvertTo-CanonicalOptionalText $Value)
}

$originalFullPath = [IO.Path]::GetFullPath($OriginalPath)
$windowsFullPath = [IO.Path]::GetFullPath($WindowsPath)
foreach ($path in @($originalFullPath, $windowsFullPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "报告不存在：$path"
    }
}

$original = Get-Content -Raw -LiteralPath $originalFullPath | ConvertFrom-Json
$windowsReport = Get-Content -Raw -LiteralPath $windowsFullPath | ConvertFrom-Json
if ($windowsReport -is [Collections.IList]) {
    if ($windowsReport.Count -ne 1) {
        throw 'Windows 报告必须只包含一个地址族，才能与单份原版报告比较。'
    }
    $windowsReport = $windowsReport[0]
}

$details = [Collections.Generic.List[object]]::new()
function Add-Comparison {
    param(
        [Parameter(Mandatory)][ValidateSet('Core', 'Availability', 'LiveService', 'Resolver')]
        [string]$Class,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Item,
        [AllowNull()][object]$OriginalValue,
        [AllowNull()][object]$WindowsValue
    )

    $originalText = ConvertTo-ComparableText $OriginalValue
    $windowsText = ConvertTo-ComparableText $WindowsValue
    $details.Add([pscustomobject][ordered]@{
        Class = $Class
        Section = $Section
        Item = $Item
        Original = $originalText
        Windows = $windowsText
        Match = $originalText -eq $windowsText
    })
}

Add-Comparison Core Head Address (Get-Value $original 'Head.IP') (Get-Value $windowsReport 'Head.Address')
$originalInfoAvailable = (
    (Test-ComparisonValueAvailable (Get-Value $original 'Info.ASN')) -or
    (Test-ComparisonValueAvailable (Get-Value $original 'Info.Region.Code'))
)
$windowsInfoAvailable = Get-Value $windowsReport 'Info.SourceAvailable' $null
if ($null -eq $windowsInfoAvailable) {
    $windowsInfoAvailable = (
        (Test-ComparisonValueAvailable (Get-Value $windowsReport 'Info.ASN')) -or
        (Test-ComparisonValueAvailable (Get-Value $windowsReport 'Info.CountryCode'))
    )
}
foreach ($definition in @(
    @('ASN', 'Info.ASN', 'Info.ASN'),
    @('Organization', 'Info.Organization', 'Info.Organization'),
    @('City', 'Info.City.Name', 'Info.City'),
    @('PostalCode', 'Info.City.PostalCode', 'Info.PostalCode'),
    @('Subdivision', 'Info.City.Subdivisions', 'Info.Subdivision'),
    @('CountryCode', 'Info.Region.Code', 'Info.CountryCode'),
    @('RegisteredCountryCode', 'Info.RegisteredRegion.Code', 'Info.RegisteredCountryCode'),
    @('ContinentCode', 'Info.Continent.Code', 'Info.ContinentCode'),
    @('TimeZone', 'Info.TimeZone', 'Info.TimeZone'),
    @('GeoType', 'Info.Type', 'Info.GeoType')
)) {
    $originalInfoValue = Get-Value $original $definition[1]
    $windowsInfoValue = Get-Value $windowsReport $definition[2]
    if ($definition[0] -in @('PostalCode', 'Subdivision')) {
        $originalInfoValue = ConvertTo-CanonicalOptionalText $originalInfoValue
        $windowsInfoValue = ConvertTo-CanonicalOptionalText $windowsInfoValue
    }
    $infoClass = if ($originalInfoAvailable -and $windowsInfoAvailable) {
        'Core'
    }
    else {
        'Availability'
    }
    Add-Comparison $infoClass Info $definition[0] `
        $originalInfoValue `
        $windowsInfoValue
}

$typeNames = @('IPinfo', 'ipregistry', 'ipapi', 'IP2Location', 'AbuseIPDB')
foreach ($name in $typeNames) {
    $windowsType = @(
        $windowsReport.TypeAssessment.Sources |
            Where-Object Name -eq $name |
            Select-Object -First 1
    )
    $originalUsage = ConvertTo-CanonicalOptionalText (Get-Value $original "Type.Usage.$name")
    $windowsUsage = ConvertTo-CanonicalOptionalText $(
        if ($windowsType.Count -and $windowsType[0].Available) {
            $windowsType[0].UsageLabel
        }
        else {
            $null
        }
    )
    $usageClass = if (
        (Test-ComparisonValueAvailable $originalUsage) -and
        (Test-ComparisonValueAvailable $windowsUsage)
    ) {
        'Core'
    }
    else {
        'Availability'
    }
    Add-Comparison $usageClass Type "$name.Usage" $originalUsage $windowsUsage

    $originalCompany = ConvertTo-CanonicalOptionalText (Get-Value $original "Type.Company.$name")
    if ($null -ne $originalCompany) {
        $windowsCompany = ConvertTo-CanonicalOptionalText $(
            if ($windowsType.Count -and $windowsType[0].Available) {
                $windowsType[0].CompanyLabel
            }
            else {
                $null
            }
        )
        $companyClass = if (
            (Test-ComparisonValueAvailable $originalCompany) -and
            (Test-ComparisonValueAvailable $windowsCompany)
        ) {
            'Core'
        }
        else {
            'Availability'
        }
        Add-Comparison $companyClass Type "$name.Company" $originalCompany $windowsCompany
    }
}

$scoreNames = [ordered]@{
    IP2Location = 'IP2LOCATION'
    Scamalytics = 'SCAMALYTICS'
    ipapi = 'ipapi'
    AbuseIPDB = 'AbuseIPDB'
    IPQS = 'IPQS'
    'DB-IP' = 'DBIP'
}
foreach ($entry in $scoreNames.GetEnumerator()) {
    $windowsSource = @(
        $windowsReport.DataSources |
            Where-Object Name -eq $entry.Key |
            Select-Object -First 1
    )
    $originalScore = ConvertTo-CanonicalScore (Get-Value $original "Score.$($entry.Value)")
    $windowsScore = if ($windowsSource.Count -and $windowsSource[0].Available) {
        ConvertTo-CanonicalScore $windowsSource[0].Score
    }
    else {
        $null
    }
    $scoreClass = if ($null -ne $originalScore -and $null -ne $windowsScore) {
        'Core'
    }
    else {
        'Availability'
    }
    Add-Comparison $scoreClass Score $entry.Key $originalScore $windowsScore
}

$factorSources = [ordered]@{
    IP2Location = 'IP2LOCATION'
    ipapi = 'ipapi'
    ipregistry = 'ipregistry'
    IPQS = 'IPQS'
    Scamalytics = 'SCAMALYTICS'
    ipdata = 'ipdata'
    IPinfo = 'IPinfo'
    'DB-IP' = 'DBIP'
}
foreach ($factor in @('CountryCode', 'Proxy', 'Tor', 'VPN', 'Server', 'Abuser', 'Robot')) {
    foreach ($entry in $factorSources.GetEnumerator()) {
        $windowsSource = @(
            $windowsReport.DataSources |
                Where-Object Name -eq $entry.Key |
                Select-Object -First 1
        )
        $windowsValue = if ($windowsSource.Count) {
            if (-not $windowsSource[0].Available) {
                $null
            }
            elseif ($factor -eq 'CountryCode') {
                $windowsSource[0].CountryCode
            }
            else {
                Get-Value $windowsSource[0] "Flags.$factor"
            }
        }
        else {
            $null
        }
        $originalValue = Get-Value $original "Factor.$factor.$($entry.Value)"
        $factorClass = if ($null -ne $originalValue -and $null -ne $windowsValue) {
            'Core'
        }
        else {
            'Availability'
        }
        Add-Comparison $factorClass Factor "$factor.$($entry.Key)" $originalValue $windowsValue
    }
}

$mediaNames = [ordered]@{
    TikTok = 'TikTok'
    DisneyPlus = 'DisneyPlus'
    Netflix = 'Netflix'
    Youtube = 'YouTubePremium'
    AmazonPrimeVideo = 'AmazonPrimeVideo'
    Reddit = 'Reddit'
    ChatGPT = 'ChatGPT'
}
foreach ($entry in $mediaNames.GetEnumerator()) {
    $originalMedia = Get-Value $original "Media.$($entry.Key)"
    $windowsMedia = Get-Value $windowsReport "Media.$($entry.Value)"
    Add-Comparison LiveService Media "$($entry.Key).Status" `
        (ConvertTo-CanonicalMediaStatus (Get-Value $originalMedia 'Status')) `
        (Get-Value $windowsMedia 'Status')
    Add-Comparison LiveService Media "$($entry.Key).Region" `
        (Get-Value $originalMedia 'Region' '') `
        (Get-Value $windowsMedia 'Region' '')
    Add-Comparison Resolver Media "$($entry.Key).Type" `
        (ConvertFrom-OriginalBadge (Get-Value $originalMedia 'Type')) `
        (Get-Value $windowsMedia 'Type')
}

Add-Comparison Core Mail Port25 (Get-Value $original 'Mail.Port25') (Get-Value $windowsReport 'Mail.Port25')
foreach ($service in @(
    'Gmail', 'Outlook', 'Yahoo', 'Apple', 'QQ', 'MailRU',
    'AOL', 'GMX', 'MailCOM', '163', 'Sohu', 'Sina'
)) {
    Add-Comparison Core Mail $service `
        (Get-Value $original "Mail.$service") `
        (Get-Value $windowsReport "Mail.Services.$service")
}

foreach ($field in @('Total', 'Clean', 'Marked', 'Blacklisted')) {
    Add-Comparison Resolver DNSBlacklist $field `
        (Get-Value $original "Mail.DNSBlacklist.$field") `
        (Get-Value $windowsReport "DNSBlacklist.$field")
}

$sameEgress = (
    (ConvertTo-ComparableText (Get-Value $original 'Head.IP')) -eq
    (ConvertTo-ComparableText (Get-Value $windowsReport 'Head.Address'))
)
$summary = [ordered]@{
    SameEgress = $sameEgress
}
foreach ($class in @('Core', 'Availability', 'LiveService', 'Resolver')) {
    $classRows = @($details | Where-Object Class -eq $class)
    $summary["${class}Compared"] = $classRows.Count
    $summary["${class}Matched"] = @($classRows | Where-Object Match).Count
    $summary["${class}Mismatches"] = @($classRows | Where-Object { -not $_.Match }).Count
}
$summary.StrictMatch = (
    $sameEgress -and
    @($details | Where-Object { -not $_.Match }).Count -eq 0
)
$summary.CoreMatch = (
    $sameEgress -and
    $summary.CoreMismatches -eq 0
)

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    OriginalPath = $originalFullPath
    WindowsPath = $windowsFullPath
    Summary = [pscustomobject]$summary
    Differences = @($details | Where-Object { -not $_.Match })
    Details = $details.ToArray()
}

if ($Output) {
    $outputFullPath = [IO.Path]::GetFullPath($Output)
    $directory = Split-Path -Parent $outputFullPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText(
        $outputFullPath,
        ($result | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

if (-not $Quiet) {
    Write-Host "同出口：$($summary.SameEgress)" -ForegroundColor $(if ($summary.SameEgress) { 'Green' } else { 'Red' })
    Write-Host "核心字段：$($summary.CoreMatched)/$($summary.CoreCompared)" -ForegroundColor $(if ($summary.CoreMismatches -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "数据源可用性：$($summary.AvailabilityMatched)/$($summary.AvailabilityCompared)" -ForegroundColor $(if ($summary.AvailabilityMismatches -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "实时服务：$($summary.LiveServiceMatched)/$($summary.LiveServiceCompared)" -ForegroundColor $(if ($summary.LiveServiceMismatches -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "解析器相关：$($summary.ResolverMatched)/$($summary.ResolverCompared)" -ForegroundColor $(if ($summary.ResolverMismatches -eq 0) { 'Green' } else { 'Yellow' })
    $differences = @($result.Differences)
    if ($differences.Count) {
        $differences |
            Select-Object Class, Section, Item, Original, Windows |
            Format-Table -AutoSize
    }
    else {
        Write-Host '所有归一化字段完全一致。' -ForegroundColor Green
    }
}

$result
