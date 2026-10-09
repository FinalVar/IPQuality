#Requires -Version 7.2
[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sample = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'examples/latest.json') -Raw |
    ConvertFrom-Json
if ($sample.Head.Demo -ne $true) { throw 'The offline sample must be labeled as a demo.' }
if ($Json) {
    $sample | ConvertTo-Json -Depth 12
    return
}
Import-Module (Join-Path $PSScriptRoot 'IPQuality.psm1') -Force
Write-Host 'OFFLINE DEMO / 合成数据演示 — 不联网，不代表真实检测结果' -ForegroundColor Yellow
Format-IPQualityReport -Result $sample
