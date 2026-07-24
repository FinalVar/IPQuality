[CmdletBinding()]
param(
    [string]$Destination,
    [string]$ShimDirectory,
    [switch]$NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$minimumVersion = [Version]'7.2'
if ($PSVersionTable.PSVersion -lt $minimumVersion) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        throw @'
IPQuality 需要 PowerShell 7.2 或更新版本。
请先从 Microsoft 更新 PowerShell：
https://aka.ms/powershell-release?tag=stable
'@
    }
    $pwsh = $null
    $pathCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $standardPwsh = if (
        -not [string]::IsNullOrWhiteSpace($env:ProgramFiles)
    ) {
        [IO.Path]::Combine(
            $env:ProgramFiles,
            'PowerShell',
            '7',
            'pwsh.exe'
        )
    }
    $candidates = @(
        $standardPwsh,
        $(if ($pathCommand) { $pathCommand.Source })
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        try {
            $candidateVersion = [Version](
                & $candidate `
                    -NoLogo `
                    -NoProfile `
                    -Command (
                        '[Console]::Write(' +
                        '$PSVersionTable.PSVersion.ToString())'
                    )
            )
            if ($candidateVersion -ge $minimumVersion) {
                $pwsh = $candidate
                break
            }
        }
        catch {
        }
    }
    if (-not $pwsh) {
        throw @'
IPQuality 需要 PowerShell 7.2 或更新版本。
请先从 Microsoft 安装 PowerShell：
https://aka.ms/powershell-release?tag=stable
'@
    }
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $PSCommandPath
    )) {
        $arguments.Add($argument)
    }
    if ($Destination) {
        $arguments.Add('-Destination')
        $arguments.Add($Destination)
    }
    if ($ShimDirectory) {
        $arguments.Add('-ShimDirectory')
        $arguments.Add($ShimDirectory)
    }
    if ($NoPath) {
        $arguments.Add('-NoPath')
    }
    & $pwsh @arguments
    exit $LASTEXITCODE
}

$installer = Join-Path $PSScriptRoot 'windows\Install-IPQuality.ps1'
$parameters = @{}
if ($Destination) {
    $parameters.Destination = $Destination
}
if ($ShimDirectory) {
    $parameters.ShimDirectory = $ShimDirectory
}
if ($NoPath) {
    $parameters.NoPath = $true
}

$result = & $installer @parameters
if (-not $result.Installed) {
    throw '安装器没有返回成功状态。'
}

Write-Host ''
Write-Host 'IPQuality for Windows 安装完成。' -ForegroundColor Green
Write-Host "安装目录：$($result.Destination)"
Write-Host "命令入口：$($result.Shim)"
Write-Host "卸载入口：$($result.Uninstaller)"
if ($result.ShimOnUserPath) {
    Write-Host '以后在任意新终端或“运行”窗口输入 ipq 即可。' `
        -ForegroundColor Cyan
}
else {
    Write-Warning '未配置 PATH；请直接运行上面显示的 ipq.cmd。'
}
if ($result.RestartTerminalRecommended) {
    Write-Host '已经打开的终端需要关闭后重新打开一次。' `
        -ForegroundColor Yellow
}

$result
