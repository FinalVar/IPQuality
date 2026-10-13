#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'IPQuality.psm1') -Force
$module = Get-Module IPQuality

& $module {
    function Assert-Parity($Condition, $Message) { if (-not $Condition) { throw $Message } }
    function Response([string]$Body, [int]$Status=200) {
        [pscustomobject]@{Body=$Body;Success=($Status -eq 200);StatusCode=$Status;Error='';ExitCode=0}
    }
    $requests = [Collections.Generic.List[object]]::new()
    $responses = [Collections.Generic.Queue[object]]::new()
    function Invoke-IPQRequest {
        param($Context,$Uri,$Method,$Headers,$Body,$Resolve,[switch]$FailOnHttpError)
        $requests.Add([pscustomobject]@{Context=$Context;Uri=$Uri;Method=$Method;Body=$Body;Resolve=$Resolve;Headers=$Headers})
        if ($responses.Count -eq 0) { throw "Unexpected request: $Uri" }
        return $responses.Dequeue()
    }
    # Media unlock DNS is tested independently below: no fixture can hit the network.
    function Get-IPQMediaUnlockType { param($Name,$Context) return '原生' }
    $context = New-IPQContext -AddressFamily 4 -Proxy 'socks5h://127.0.0.1:7890' -Language jp
    $responses.Enqueue((Response '{"location":{"country_code":"JP"},"asn":{"type":"isp"},"company":{"type":"isp"}}'))
    $ipapi = Get-IPQSourceIPApi $context '203.0.113.42'
    Assert-Parity ($requests[-1].Uri -eq 'https://ipinfo.check.place/203.0.113.42?db=ipapi') 'ipapi must use the official new endpoint'
    Assert-Parity ($ipapi.Available -and $null -eq $ipapi.Score) 'missing abuser_score must not become zero'
    $responses.Enqueue((Response '<html>bad gateway</html>'))
    Assert-Parity (-not (Get-IPQSourceIPApi $context '203.0.113.42').Available) 'HTML must not be valid ipapi data'

    $responses.Enqueue((Response '<div data-api-key="public_demo-token"></div>'))
    $responses.Enqueue((Response '{"countryCode":"JP","threatLevel":"medium","isProxy":true,"isCrawler":false}'))
    $dbip = Get-IPQSourceDBIP $context '203.0.113.42'
    Assert-Parity ($dbip.Available -and $dbip.Score -eq 50 -and $dbip.Flags.Proxy -eq $true -and $dbip.Flags.Robot -eq $false -and $null -eq $dbip.Flags.Abuser) 'DB-IP two-stage parsing and missing-factor semantics'
    Assert-Parity ($requests[-1].Uri -eq 'https://api.db-ip.com/v2/public_demo-token/self?convertCurrencies' -and $requests[-1].Method -eq 'POST') 'DB-IP API method and path'
    Assert-Parity ($requests[-1].Context.Proxy -eq $context.Proxy -and $requests[-1].Headers['content-type'] -eq 'text/plain;charset=UTF-8') 'DB-IP must preserve explicit routing and request headers'
    $responses.Enqueue((Response '<div data-api-key="public_demo-token"></div>'))
    $responses.Enqueue((Response '{"error":"invalid"}'))
    Assert-Parity (-not (Get-IPQSourceDBIP $context '203.0.113.42').Available) 'DB-IP errors must remain unavailable'

    $responses.Enqueue((Response '{"countryCode":"DE","currentTerritory":"JP","currentTerritory":"US"}'))
    Assert-Parity ((Test-IPQPrimeVideo $context).Region -eq 'JP') 'Amazon must use the first currentTerritory only'
    $responses.Enqueue((Response '{"countryCode":"DE"}'))
    Assert-Parity ((Test-IPQPrimeVideo $context).Status -eq 'Blocked') 'Unrelated country codes must not imply PrimeVideo availability'
    $responses.Enqueue((Response '<app country="JP"><other country="US">'))
    Assert-Parity ((Test-IPQReddit $context).Region -eq 'JP') 'Reddit must use the first country attribute'
    Assert-Parity ($requests[-1].Uri -eq 'https://www.reddit.com/svc/shreddit/reddit-chat') 'Reddit new endpoint'
    $dnsCalls = [Collections.Generic.List[string]]::new()
    function Resolve-DnsName {
        param($Name,$Type,[switch]$DnsOnly,$ErrorAction)
        $dnsCalls.Add($Name)
        if ($Name -eq 'reddit.com') { throw 'No AAAA' }
        [pscustomobject]@{QueryType='AAAA';IPAddress='2001:db8::1';Section='Answer'}
    }
    $responses.Enqueue((Response '<app country="JP">'))
    $v6 = New-IPQContext -AddressFamily 6
    Assert-Parity ((Test-IPQReddit $v6).Status -eq 'Available') 'Reddit IPv6 fallback'
    Assert-Parity ($dnsCalls.Count -eq 2 -and $dnsCalls[1] -eq 'dualstack.reddit.map.fastly.net' -and $requests[-1].Resolve[0] -eq 'www.reddit.com:443:[2001:db8::1]') 'Reddit must resolve the upstream dualstack fallback'

    foreach ($answer in @('', 'not-an-ip')) { Assert-Parity (Test-IPQUpstreamDnsAddress $answer) 'empty/invalid DNS answer is native under the new upstream rule' }
    Assert-Parity ((Get-IPQDnsblAnswerStatus @('127.255.255.254')) -eq 'Clean') 'DNSBL provider errors must be Clean'
    Assert-Parity ((Get-IPQDnsblAnswerStatus @('127.0.0.2')) -eq 'Blacklisted') 'single 127.0.0.2 must be blacklisted'
    Assert-Parity ((Get-IPQDnsblAnswerStatus @('127.0.0.2','127.0.0.3')) -eq 'Marked') 'multiple answers must be marked'
    Assert-Parity ((Get-IPQDnsblAnswerStatus @()) -eq 'Clean') 'empty answers must be clean'

    $responses.Enqueue((Response '{"ASN":{"AutonomousSystemNumber":64500},"Country":{"IsoCode":"JP","Name":"日本"}}'))
    $responses.Enqueue((Response '{"City":{"Name":"Tokyo"}}'))
    $basic = Get-IPQMaxMindInfo $context '203.0.113.42'
    Assert-Parity ($requests[-2].Uri -match 'lang=jp$' -and $requests[-1].Uri -match 'lang=en$' -and $basic.Country -eq '日本' -and $basic.City -eq 'Tokyo') 'locale plus English field fallback'

    function Get-IPQPublicAddress { param($Context) [pscustomobject]@{Address='203.0.113.42';Endpoint='fixture'} }
    function Get-IPQMaxMindInfo { param($Context,$Address) [pscustomobject]@{Available=$false;Error='fixture unavailable'} }
    $responses.Enqueue((Response '{"data":{"country":"JP","abuse":{"country":"JP"},"city":"Tokyo","loc":"35.68,139.69","timezone":"Asia/Tokyo","asn":{"asn":"AS64500","name":"Example","type":"isp"}}}'))
    $lite = Invoke-IPQualityCheck -AddressFamily 4 -SkipRisk -SkipMedia -SkipMail -SkipDnsbl -Language jp 6>$null
    Assert-Parity ($lite.Head.Lite -and $lite.Info.Source -eq 'IPinfo' -and $lite.Info.City -eq 'Tokyo' -and $lite.Info.Map -match ',jp$') 'automatic Lite must preserve basic information using IPinfo'
    $sensitive = [pscustomobject]@{Error='failed 42.113.0.203.example and 203.0.113.42';Nested=@([pscustomobject]@{Address='203.0.113.42'})}
    Protect-IPQReportFields $sensitive '203.0.113.42'
    Assert-Parity (($sensitive | ConvertTo-Json -Depth 5) -notmatch '203\.0\.113\.42|42\.113\.0\.203') 'masked report must not expose the IP in DNS error messages'
    Assert-Parity ($responses.Count -eq 0) 'all queued request fixtures must be consumed'
    Assert-Parity ((Get-IPQTikTokRegion '{"countryCode":"US"}') -eq '') 'TikTok must not use an unrelated country field'
    Assert-Parity ((Get-IPQTikTokRegion '{"region":"HK","region":"JP"}') -eq 'JP') 'TikTok matches the last upstream region field'
    function Resolve-DnsName { throw 'fixture resolver failure' }
    function Get-IPQDnsServerAddresses { return '1.1.1.1' }
    $dns = Invoke-IPQDnsCompatibilityProbe -Domain 'example.invalid' -AddressFamily 4 -IncludeAnswerCount -IncludeWildcard
    Assert-Parity ($dns.Type -eq '原生') 'missing resolver output differs from a DNS answer count of zero'
    function Get-NetIPAddress { param($InterfaceAlias,$AddressFamily,$ErrorAction) [pscustomobject]@{IPAddress='192.0.2.5';AddressState='Preferred';SkipAsSource=$false} }
    Assert-Parity ((New-IPQContext -AddressFamily 4 -Interface 'Fixture NIC').Interface -eq '192.0.2.5') 'Windows interface alias must resolve to an address before passing to curl'
}

$fixture = Get-Content -Raw (Join-Path $root 'examples/latest.json') | ConvertFrom-Json
$fixture.Head | Add-Member Language en
# Complete optional fields in the older synthetic demo fixture.
foreach ($field in @('DMS','Map','SubdivisionCode','Subdivision','PostalCode','Latitude','Longitude','ContinentCode','Continent','CountryCode','Country','RegisteredCountryCode','RegisteredCountry','GeoType')) {
    if (-not $fixture.Info.PSObject.Properties[$field]) { $fixture.Info | Add-Member $field $null }
}
$ansi = Get-IPQualityReportAnsi $fixture
if ($ansi -notmatch '\x1b\[' -or $ansi -notmatch 'Streaming and AI' -or $ansi -match '风险因子|解锁检测') { throw 'English ANSI renderer failed' }
$plain = Get-IPQualityReportText $fixture
if ($plain -match '\x1b\[' -or $plain -notmatch 'Basic information') { throw 'English plain text export failed' }
$compat = ConvertTo-IPQualityUpstreamReport $fixture
if ($compat.PSObject.Properties.Name.Count -ne 7 -or -not $compat.Factor.Contains('CountryCode') -or -not $compat.Type.Company.Contains('IP2LOCATION')) { throw 'Official JSON structure incomplete' }
if ($compat.Media.ChatGPT.Status -ne 'Yes' -or $compat.Media.ChatGPT.Type -ne 'Native' -or $compat.Factor.Proxy.Count -ne 9) { throw 'Official English JSON labels or factor columns incomplete' }

# Full six-score report must fit the established console, in both languages.
$full = $fixture | ConvertTo-Json -Depth 16 | ConvertFrom-Json
$full.Info.DMS='139°41′24″E, 35°40′48″N'; $full.Info.Map='https://check.place/35.68,139.69,15,cn'
$full.DataSources = & $module { foreach($name in $script:SourceOrder) { New-IPQSourceResult -Name $name -Available $true -Score 50 -RiskLevel '中风险' -CountryCode JP -UsageType isp -CompanyType isp -Flags (New-IPQFlags) } }
$full.Mail=[pscustomobject]@{Port25=$false;Port25Status='ProxyUnsupported';Services=[pscustomobject][ordered]@{Gmail=$false;Outlook=$false;Yahoo=$false;Apple=$false;QQ=$false;MailRU=$false;AOL=$false;GMX=$false;MailCOM=$false;'163'=$false;Sohu=$false;Sina=$false}}
foreach ($lang in @('cn','en')) {
    $full.Head.Language=$lang
    $lines=((Get-IPQualityReportAnsi $full) -replace '\x1b\[[0-9;]*m','') -split '\r?\n'
    if ($lines.Count -ne 46) { throw "Full $lang report must have 46 rows, got $($lines.Count)" }
    & $module { param($lines) foreach($line in $lines) { if ((Get-IPQDisplayWidth $line) -gt 74) { throw 'Report exceeds 74 columns' } } } $lines
}

& $module {
    param($fixture)
    $uploadFiles = @()
    function Invoke-IPQRequest {
        param($Context,$Uri,$Method,$Form,$FormFiles)
        if ($Uri -ne 'https://upload.check.place' -or $Method -ne 'POST' -or $Form.type -ne 'ip') { throw 'Official upload contract mismatch' }
        $script:uploadFiles = @($FormFiles.Values)
        $data = Get-Content -Raw $FormFiles.json | ConvertFrom-Json
        if ($data.Head.IP -ne '203.0.*.*' -or (Get-Content -Raw $FormFiles.content) -notmatch '\x1b\[') { throw 'Upload payload invalid' }
        [pscustomobject]@{Success=$true;Body='https://Report.Check.Place/test-fixture'}
    }
    if ((Publish-IPQualityReport $fixture) -ne 'https://report.check.place/test-fixture') { throw 'Share link validation' }
    foreach ($path in $script:uploadFiles) { if (Test-Path -LiteralPath $path) { throw 'Upload temporary file leaked' } }
    function Invoke-IPQRequest { [pscustomobject]@{Success=$true;Body='https://unrelated.invalid/x'} }
    $rejected = $false
    try { Publish-IPQualityReport $fixture | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unrelated report URL must be rejected' }
} $fixture

foreach ($name in @('IPQuality.ps1','Start-IPQuality.ps1')) {
    $command = Get-Command (Join-Path $root $name)
    foreach ($alias in @('4','6','x','i','f','j','o','l','E','p','h','M','n','y')) {
        if ($alias -notin @($command.Parameters.Values.Aliases)) { throw "Missing upstream parameter $alias in $name" }
    }
    $help = & (Join-Path $root $name) -h | Out-String
    if ($help -notmatch 'AllowOnlineReport|UpstreamJson') { throw 'Offline help failed' }
}
Write-Host 'PASS: upstream endpoint, rule, fallback, language, ANSI, JSON, CLI and upload-contract tests' -ForegroundColor Green
