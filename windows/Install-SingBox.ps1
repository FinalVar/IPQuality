#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '1.13.14'
$packageName = "sing-box-$version-windows-amd64.zip"
$packageSha256 = 'f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341'
$downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/v$version/$packageName"
$toolsRoot = Join-Path $PSScriptRoot 'tools\sing-box'
$installRoot = Join-Path $toolsRoot $version
$executable = Join-Path $installRoot 'sing-box.exe'

function Test-InstalledSingBox {
    if (-not (Test-Path -LiteralPath $executable)) {
        return $false
    }
    try {
        $versionText = & $executable version 2>$null | Select-Object -First 1
        return "$versionText" -match [Regex]::Escape($version)
    }
    catch {
        return $false
    }
}

if ((Test-InstalledSingBox) -and -not $Force) {
    $executable
    return
}

if (-not $Force) {
    $existingCommand = Get-Command sing-box.exe -ErrorAction SilentlyContinue
    if ($null -ne $existingCommand) {
        try {
            $existingVersion = & $existingCommand.Source version 2>$null | Select-Object -First 1
            if ("$existingVersion" -match 'sing-box') {
                Write-Host "复用 PATH 中的 sing-box：$($existingCommand.Source)" -ForegroundColor Green
                $existingCommand.Source
                return
            }
        }
        catch {
        }
    }
}

if ((Test-Path -LiteralPath $installRoot) -and -not $Force) {
    throw "检测到不完整或版本不符的安装：$installRoot。使用 -Force 才会替换。"
}

[void](New-Item -ItemType Directory -Path $toolsRoot -Force)
$stagingRoot = Join-Path $toolsRoot ".install-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $stagingRoot)

try {
    $archivePath = Join-Path $stagingRoot $packageName
    $downloaded = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "正在下载 sing-box $version（第 $attempt/3 次）..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -TimeoutSec 60
            $downloaded = $true
            break
        }
        catch {
            if (Test-Path -LiteralPath $archivePath) {
                Remove-Item -LiteralPath $archivePath -Force
            }
            if ($attempt -eq 3) {
                throw
            }
        }
    }
    if (-not $downloaded) {
        throw 'sing-box 下载失败'
    }

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $packageSha256) {
        throw "sing-box 包校验失败。期望 $packageSha256，实际 $actualHash"
    }

    $expandedRoot = Join-Path $stagingRoot 'expanded'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedRoot
    $sourceRoot = Get-ChildItem -LiteralPath $expandedRoot -Directory | Select-Object -First 1
    if ($null -eq $sourceRoot -or -not (Test-Path -LiteralPath (Join-Path $sourceRoot.FullName 'sing-box.exe'))) {
        throw 'sing-box 压缩包结构不符合预期'
    }

    if (Test-Path -LiteralPath $installRoot) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
    Move-Item -LiteralPath $sourceRoot.FullName -Destination $installRoot
    if (-not (Test-InstalledSingBox)) {
        throw 'sing-box 安装后版本验证失败'
    }
    Write-Host "sing-box $version 已安装并通过 SHA-256 校验。" -ForegroundColor Green
    $executable
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
