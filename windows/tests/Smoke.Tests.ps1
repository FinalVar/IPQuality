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
    DataSources = @()
    Consensus = $emptyConsensus
    Media = [pscustomobject]@{}
    Mail = $null
    DNSBlacklist = $null
    Warnings = @()
}
$reportText = Get-IPQualityReportText -Result $syntheticResult
Assert-True ($reportText -match '203\.0\.\*\.\*') '文本报告应包含掩码地址'

$offlineTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "ipquality-test-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $offlineTemporaryRoot)
try {
    $jsonPath = Join-Path $offlineTemporaryRoot 'report.json'
    $textPath = Join-Path $offlineTemporaryRoot 'report.txt'
    Export-IPQualityReport -Result @($syntheticResult) -Path $jsonPath
    Export-IPQualityReport -Result @($syntheticResult) -Path $textPath
    Assert-True (Test-Path -LiteralPath $jsonPath) 'JSON 报告应生成'
    Assert-True (Test-Path -LiteralPath $textPath) '文本报告应生成'
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
