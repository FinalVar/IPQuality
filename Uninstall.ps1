[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$PurgeReports,
    [switch]$KeepPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$minimumVersion = [Version]'7.2'
if ($PSVersionTable.PSVersion -lt $minimumVersion) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        throw @'
卸载器需要 PowerShell 7.2 或更新版本。
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
卸载器需要 PowerShell 7.2 或更新版本。
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
    if ($PurgeReports) {
        $arguments.Add('-PurgeReports')
    }
    if ($KeepPath) {
        $arguments.Add('-KeepPath')
    }
    & $pwsh @arguments
    exit $LASTEXITCODE
}

$uninstaller = Join-Path $PSScriptRoot 'windows\Uninstall-IPQuality.ps1'
$parameters = @{}
if ($Destination) {
    $parameters.Destination = $Destination
}
if ($PurgeReports) {
    $parameters.PurgeReports = $true
}
if ($KeepPath) {
    $parameters.KeepPath = $true
}

$result = & $uninstaller @parameters
Write-Host ''
Write-Host 'IPQuality for Windows 已卸载。' -ForegroundColor Green
if ($result.ReportsPreserved) {
    Write-Host "检测报告已保留：$($result.Destination)\windows\reports" `
        -ForegroundColor Cyan
}
$result
