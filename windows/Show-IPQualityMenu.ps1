#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host 'IPQuality — Windows 本地菜单'
Write-Host '1 当前节点 IPv4  2 当前节点 IPv6  3 本机直连 IPv4  4 指定代理  0 退出'
$choice = Read-Host '选择'
$options = @{}
switch ($choice) {
    '1' { $options.IPv4 = $true }
    '2' { $options.IPv6 = $true }
    '3' { $options.Direct = $true }
    '4' { $options.Proxy = Read-Host '代理 URL' }
    '0' { return }
    default { throw '无效选项。' }
}
$language = Read-Host '基础信息语言 cn/en/jp/es/de/fr/ru/pt，回车中文'
if ($language) { $options.Language = $language }
$output = Read-Host '导出路径 .json/.ansi/.txt，回车默认本地 JSON'
if ($output) { $options.Output = $output }
if ((Read-Host '显示完整 IP？输入 y 启用') -eq 'y') { $options.FullIP = $true }
if ((Read-Host '上传官方在线报告？输入 y 启用，回车保持本地') -eq 'y') { $options.AllowOnlineReport = $true }
& (Join-Path $PSScriptRoot 'Start-IPQuality.ps1') @options
