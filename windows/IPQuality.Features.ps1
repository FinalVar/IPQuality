# Shared output and compatibility features for the native Windows runtime.
# Detection rules originate in xykt/IPQuality (AGPL-3.0); see the feature map.
$script:IPQOutputLanguage = 'cn'
$script:IPQAnsiBuffer = $null

function ConvertFrom-IPQIPInfoBasic {
    param([Parameter(Mandatory)][object]$Data)
    $iso = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ref\iso3166.json') -Raw | ConvertFrom-Json
    $countryCode = Get-IPQValue $Data 'data.country'
    $registered = Get-IPQValue $Data 'data.abuse.country'
    $country = $iso | Where-Object { $_.'alpha-2' -eq $countryCode } | Select-Object -First 1
    $registration = $iso | Where-Object { $_.'alpha-2' -eq $registered } | Select-Object -First 1
    $coordinates = "$(Get-IPQValue $Data 'data.loc' '')".Split(',')
    [pscustomobject]@{
        Available = $true; Error = ''
        ASN = ("$(Get-IPQValue $Data 'data.asn.asn' '')" -replace '^AS','')
        Organization = Get-IPQValue $Data 'data.asn.name'
        City = Get-IPQValue $Data 'data.city'; PostalCode = Get-IPQValue $Data 'data.postal'
        TimeZone = Get-IPQValue $Data 'data.timezone'
        Latitude = $(if ($coordinates.Count -eq 2) { $coordinates[0] } else { $null })
        Longitude = $(if ($coordinates.Count -eq 2) { $coordinates[1] } else { $null })
        AccuracyRadius = 1001
        CountryCode = $countryCode; Country = Get-IPQValue $country 'name'
        Continent = Get-IPQValue $country 'region'; ContinentCode = $null
        RegisteredCountryCode = $registered; RegisteredCountry = Get-IPQValue $registration 'name'
    }
}

function Protect-IPQReportFields {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Address)
    if ($null -eq $Value) { return }
    $targets = @($Address)
    if ($Address -notmatch ':') { $targets += ($Address.Split('.')[3..0] -join '.') }
    if ($Value -is [Collections.IList]) {
        for ($i=0; $i -lt $Value.Count; $i++) {
            if ($Value[$i] -is [string]) {
                foreach ($target in $targets) { $Value[$i] = $Value[$i].Replace($target, (Protect-IPQAddress $target)) }
            } else { Protect-IPQReportFields -Value $Value[$i] -Address $Address }
        }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Value -is [string]) {
                foreach ($target in $targets) { $property.Value = $property.Value.Replace($target, (Protect-IPQAddress $target)) }
            } else { Protect-IPQReportFields -Value $property.Value -Address $Address }
        }
    }
}

$script:IPQEnglishLabels = @{
    '一、基础信息（Maxmind 数据库）'='I. Basic information (MaxMind)'
    '一、基础信息（IPinfo 数据库）'='I. Basic information (IPinfo fallback)'
    '二、IP类型属性'='II. IP types'; '三、风险评分'='III. Risk scores'
    '四、风险因子'='IV. Risk factors'; '五、流媒体及AI服务解锁检测'='V. Streaming and AI services'
    '六、邮局连通性及黑名单检测'='VI. Mail connectivity and blacklists'
    '自治系统号：'='ASN:'; '组织：'='Organization:'; '坐标：'='Coordinates:'
    '地图：'='Map:'; '城市：'='City:'; '使用地：'='Location:'; '注册地：'='Registered:'
    '时区：'='Time zone:'; 'IP类型：'='IP type:'; '数据库：'='Source:'
    '使用类型：'='Usage:'; '公司类型：'='Company:'; '风险等级：'='Risk level:'
    '库：'='DB:'; '地区：'='Region:'; '代理：'='Proxy:'; '服务器：'='Server:'
    '滥用：'='Abuser:'; '机器人：'='Robot:'; '服务商：'='Service:'
    '状态：'='Status:'; '方式：'='Type:'; '通信：'='Mail:'
    '本地25端口出站：'='Outbound port 25: '; 'IP地址黑名单数据库：'='DNSBL: '
    '极低       低'='Very low / Low'; '中等'='Medium'; '高       极高'='High / Very high'
    '家宽'='ISP'; '手机'='Mobile'; '机房'='Hosting'; '商业'='Business'; '教育'='Education'
    '政府'='Gov'; '银行'='Bank'; '组织'='Org'; '军队'='Military'; '图书馆'='Library'; '其他'='Other'
    '原生IP'='Native'; '广播IP'='Bcast'; '原生'='Native'; '未知'='Unknown'
    '极低风险'='Very low'; '低风险'='Low'; '较高风险'='Elevated'; '中风险'='Medium'
    '高风险'='High'; '极高风险'='Very high'; '建议封禁'='Ban'; '可疑IP'='Suspect'; '存在风险'='Risky'
    '是'='Yes'; '否'='No'; '无'='N/A'; '不可用'='N/A'; '没有可用评分'='No available scores'
    '解锁'='Yes'; '屏蔽'='No'; '失败'='Failed'; '仅自制'='Original'; '禁会员'='NoPrem'
    '中国'='China'; '待支持'='Pending'; '仅网页'='WebOnly'; '仅APP'='AppOnly'
    '可用'='Open'; '阻断'='Blocked'; '占用'='Busy'; '代理不测'='Proxy: not tested'
    '已跳过'='Skipped'; '不支持'='N/A'; '检出'='Detected'; '未检出'='Clear'; '冲突'='Mixed'
}

function ConvertTo-IPQDisplayText {
    param([AllowNull()][object]$Text)
    $value = "$Text"
    if ($script:IPQOutputLanguage -eq 'cn') { return $value }
    $trimmed = $value.Trim()
    if ($script:IPQEnglishLabels.ContainsKey($trimmed)) {
        return $value.Replace($trimmed, $script:IPQEnglishLabels[$trimmed])
    }
    $value = $value -replace '^IP质量体检报告：','IP QUALITY REPORT: '
    $value = $value -replace '^报告时间：','Time: ' -replace '  脚本版本：','  Upstream: '
    $value = $value -replace '^有效 ','Total ' -replace '^正常 ','Clean ' -replace '^已标记 ','Marked ' -replace '^黑名单 ','Listed '
    return $value
}

function Write-IPQHost {
    param(
        [Parameter(Position=0, ValueFromRemainingArguments=$true)][AllowNull()][object[]]$Object,
        [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )
    $text = ConvertTo-IPQDisplayText ([string]::Join(' ', [string[]]$Object))
    if ($null -ne $script:IPQAnsiBuffer) {
        $colors = @(30,34,32,36,31,35,33,37,90,94,92,96,91,95,93,97)
        $codes = @()
        if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $codes += $colors[[int]$ForegroundColor] }
        if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $codes += 10 + $colors[[int]$BackgroundColor] }
        if ($codes.Count) { [void]$script:IPQAnsiBuffer.Append("`e[$($codes -join ';')m") }
        [void]$script:IPQAnsiBuffer.Append($text)
        if ($codes.Count) { [void]$script:IPQAnsiBuffer.Append("`e[0m") }
        if (-not $NoNewline) { [void]$script:IPQAnsiBuffer.AppendLine() }
    } else {
        $forward = @{ Object=$text; NoNewline=$NoNewline }
        foreach ($key in @('ForegroundColor','BackgroundColor')) {
            if ($PSBoundParameters.ContainsKey($key)) { $forward[$key]=$PSBoundParameters[$key] }
        }
        Write-Host @forward
    }
}

function Get-IPQualityReportAnsi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)
    $oldBuffer = $script:IPQAnsiBuffer
    $oldLanguage = $script:IPQOutputLanguage
    try {
        $script:IPQOutputLanguage = Get-IPQValue $Result.Head 'Language' 'cn'
        $script:IPQAnsiBuffer = [Text.StringBuilder]::new()
        Write-IPQPrettyReport -Result $Result
        return $script:IPQAnsiBuffer.ToString().TrimEnd()
    } finally {
        $script:IPQAnsiBuffer = $oldBuffer
        $script:IPQOutputLanguage = $oldLanguage
    }
}

function ConvertTo-IPQualityUpstreamReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)
    $info = $Result.Info
    $english = (Get-IPQValue $Result.Head 'Language' 'cn') -ne 'cn'
    function Export-Label($Value) {
        if (-not $english -or $null -eq $Value) { return $Value }
        $labels = @{
            '原生IP'='Geo-consistent';'广播IP'='Geo-discrepant';'家宽'='ISP';'机房'='Hosting';'手机'='Mobile ISP'
            '商业'='Business';'教育'='Education';'政府'='Government';'银行'='Banking';'组织'='Organization';'军队'='Military';'图书馆'='Library';'其他'='Other'
            '解锁'='Yes';'屏蔽'='Block';'失败'='Failed';'待支持'='Pending';'中国'='China';'禁会员'='NoPrem.';'仅自制'='NF.Only';'仅网页'='WebOnly';'仅APP'='APPOnly';'原生'='Native';'DNS'='ViaDNS';'未知'='Unknown'
        }
        if ($labels.ContainsKey("$Value")) { return $labels["$Value"] }
        return $Value
    }
    $usage = [ordered]@{}; $company = [ordered]@{}; $scores = [ordered]@{}
    $factors = [ordered]@{}
    $names = [ordered]@{IPinfo='IPinfo';Scamalytics='SCAMALYTICS';ipregistry='ipregistry';ipapi='ipapi';AbuseIPDB='AbuseIPDB';IP2Location='IP2LOCATION';ipdata='ipdata';IPQS='IPQS';'DB-IP'='DBIP'}
    foreach ($factor in @('CountryCode','Proxy','Tor','VPN','Server','Abuser','Robot')) { $factors[$factor] = [ordered]@{} }
    $assessment = Get-IPQValue $Result 'TypeAssessment'
    if ($null -eq $assessment) { $assessment = Get-IPQTypeAssessment -Sources $Result.DataSources }
    foreach ($source in $assessment.Sources) {
        $key = $names[$source.Name]
        $usage[$key] = $(if ($source.Available) { Export-Label $source.UsageLabel } else { $null })
        if ($key -ne 'AbuseIPDB') { $company[$key] = $(if ($source.Available) { Export-Label $source.CompanyLabel } else { $null }) }
    }
    foreach ($entry in $names.GetEnumerator()) {
        $source = $Result.DataSources | Where-Object Name -eq $entry.Key | Select-Object -First 1
        $available = $null -ne $source -and $source.Available
        if ($entry.Key -in @('IP2Location','Scamalytics','ipapi','AbuseIPDB','IPQS','DB-IP')) {
            $scores[$entry.Value] = $(if ($available) { $source.Score } else { $null })
        }
        if ($entry.Key -ne 'AbuseIPDB') {
            $factors.CountryCode[$entry.Value] = $(if ($available) { $source.CountryCode } else { $null })
            foreach ($factor in @('Proxy','Tor','VPN','Server','Abuser','Robot')) {
                $factors[$factor][$entry.Value] = $(if ($available) { $source.Flags.$factor } else { $null })
            }
        }
    }
    # Upstream retains the deprecated IPWHOIS column as null; no active detector.
    foreach ($factor in $factors.Values) { $factor.IPWHOIS = $null }
    $media = [ordered]@{}
    foreach ($property in $Result.Media.PSObject.Properties) {
        $key = if ($property.Name -eq 'YouTubePremium') { 'Youtube' } else { $property.Name }
        $status = Export-Label (ConvertTo-IPQMediaStatusLabel $property.Value.Status)
        if ($english -and $property.Value.Status -eq 'IDCOnly') { $status = 'IDC' }
        $media[$key] = [ordered]@{Status=$status;Region=$property.Value.Region;Type=(Export-Label $property.Value.Type)}
    }
    $mail = [ordered]@{Port25=$null}
    if ($null -ne $Result.Mail) {
        $mail.Port25 = $Result.Mail.Port25
        foreach ($property in $Result.Mail.Services.PSObject.Properties) { $mail[$property.Name]=$property.Value }
    }
    $mail.DNSBlacklist = [ordered]@{}
    foreach ($field in @('Total','Clean','Marked','Blacklisted')) { $mail.DNSBlacklist[$field] = Get-IPQValue $Result.DNSBlacklist $field }
    [pscustomobject][ordered]@{
        Head=[ordered]@{IP=$Result.Head.Address;Command='ipq';GitHub=$script:RepositoryUrl;Time=$(if ($english) { Get-IPQValue $Result.Head 'TimeUtc' } else { Get-IPQValue $Result.Head 'TimeLocal' (Get-IPQValue $Result.Head 'TimeUtc') });Version=$script:UpstreamVersion}
        Info=[ordered]@{
            ASN=$info.ASN;Organization=$info.Organization;Latitude=$info.Latitude;Longitude=$info.Longitude
            DMS=$info.DMS;Map=$info.Map;TimeZone=$info.TimeZone
            City=[ordered]@{Name=$info.City;PostalCode=$info.PostalCode;SubCode=$info.SubdivisionCode;Subdivisions=$info.Subdivision}
            Region=[ordered]@{Code=$info.CountryCode;Name=$info.Country}
            Continent=[ordered]@{Code=$info.ContinentCode;Name=$info.Continent}
            RegisteredRegion=[ordered]@{Code=$info.RegisteredCountryCode;Name=$info.RegisteredCountry};Type=(Export-Label $info.GeoType)
        }
        Type=[ordered]@{Usage=$usage;Company=$company};Score=$scores;Factor=$factors;Media=$media;Mail=$mail
    }
}

function Publish-IPQualityReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [string]$Proxy,
        [string]$Interface,
        [ValidateRange(2,60)][int]$TimeoutSeconds=10
    )
    $context = New-IPQContext -AddressFamily $(if ($Result.Head.AddressFamily -eq 'IPv6') { 6 } else { 4 }) -Proxy $Proxy -Interface $Interface -TimeoutSeconds $TimeoutSeconds
    $jsonPath = Join-Path ([IO.Path]::GetTempPath()) ('ipq-share-'+[Guid]::NewGuid().ToString('N')+'.json')
    $ansiPath = [IO.Path]::ChangeExtension($jsonPath, '.ansi')
    try {
        [IO.File]::WriteAllText($jsonPath, ((ConvertTo-IPQualityUpstreamReport $Result) | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($ansiPath, (Get-IPQualityReportAnsi $Result), [Text.UTF8Encoding]::new($false))
        $response = Invoke-IPQRequest -Context $context -Uri 'https://upload.check.place' -Method POST -Form @{type='ip'} -FormFiles @{json=$jsonPath;content=$ansiPath}
        $url = $null
        if (-not $response.Success -or -not [Uri]::TryCreate($response.Body.Trim(), [UriKind]::Absolute, [ref]$url) -or $url.Scheme -ne 'https' -or $url.Host -ine 'Report.Check.Place') {
            throw '在线报告服务没有返回有效的 HTTPS 报告链接。'
        }
        return $url.AbsoluteUri
    } finally {
        foreach ($path in @($jsonPath,$ansiPath)) { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path } }
    }
}
