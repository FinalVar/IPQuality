#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$IPv4,
    [switch]$IPv6,
    [string]$Proxy,
    [string]$Interface,
    [switch]$FullIP,
    [switch]$Json,
    [string]$Output,
    [switch]$Force,
    [switch]$Lite,
    [switch]$NoRisk,
    [switch]$NoMedia,
    [switch]$NoMail,
    [switch]$NoDnsbl,
    [ValidateRange(2, 60)]
    [int]$TimeoutSeconds = 10,
    [ValidateRange(1, 100)]
    [int]$DnsblConcurrency = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'IPQuality.psm1'
Import-Module $modulePath -Force
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    try {
        $Host.UI.RawUI.WindowTitle = if ($Lite) { 'IPQuality Lite - 正在检测' } else { 'IPQuality Full - 正在检测' }
    }
    catch {
    }
}

if ($IPv4 -and -not $IPv6) {
    $families = @(4)
}
elseif ($IPv6 -and -not $IPv4) {
    $families = @(6)
}
else {
    $families = @(4, 6)
}

try {
    $results = @(Invoke-IPQualityCheck `
        -AddressFamily $families `
        -Proxy $Proxy `
        -Interface $Interface `
        -FullIP:$FullIP `
        -Lite:$Lite `
        -SkipRisk:$NoRisk `
        -SkipMedia:$NoMedia `
        -SkipMail:$NoMail `
        -SkipDnsbl:$NoDnsbl `
        -TimeoutSeconds $TimeoutSeconds `
        -DnsblConcurrency $DnsblConcurrency)

    if ($results.Count -eq 0) {
        throw '没有发现可用的 IPv4 或 IPv6 出口。请检查网络、代理地址或协议选项。'
    }

    if ($Json) {
        $rendered = if ($results.Count -eq 1) {
            $results[0] | ConvertTo-Json -Depth 12
        }
        else {
            $results | ConvertTo-Json -Depth 12
        }
        $rendered
    }
    else {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
            Clear-Host
        }
        foreach ($result in $results) {
            Format-IPQualityReport -Result $result
        }
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
            try {
                $Host.UI.RawUI.WindowTitle = if ($Lite) { 'IPQuality Lite - 检测结果' } else { 'IPQuality Full - 检测结果' }
            }
            catch {
            }
        }
    }

    if ($Output) {
        Export-IPQualityReport -Result $results -Path $Output -Force:$Force
        Write-Host "`n报告已保存：$([IO.Path]::GetFullPath($Output))" -ForegroundColor Green
    }
}
catch {
    Write-Error $_
    exit 1
}
