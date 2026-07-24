#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$secureNode = Read-Host '请粘贴 ss:// 节点（输入内容会隐藏）' -AsSecureString
$node = [Net.NetworkCredential]::new('', $secureNode).Password
if (-not $node) {
    throw '未输入节点'
}

try {
    & (Join-Path $PSScriptRoot 'Test-Node.ps1') -Node $node -IPv4
}
finally {
    $node = $null
    $secureNode.Dispose()
}
