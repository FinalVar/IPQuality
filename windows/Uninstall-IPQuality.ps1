#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$PurgeReports,
    [switch]$KeepPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-IPQNormalizedPathEntry {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    $expanded = [Environment]::ExpandEnvironmentVariables(
        $Value.Trim().Trim('"')
    )
    try {
        return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    }
    catch {
        return $expanded.TrimEnd('\')
    }
}

function Remove-IPQUserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    $normalizedTarget = Get-IPQNormalizedPathEntry $Path
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entry = $Path.TrimEnd('\')
    if ("$userPath".Equals(
        $entry,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        [Environment]::SetEnvironmentVariable('Path', '', 'User')
        return $true
    }
    $managedSuffix = ";$entry"
    if ("$userPath".EndsWith(
        $managedSuffix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            "$userPath".Substring(
                0,
                "$userPath".Length - $managedSuffix.Length
            ),
            'User'
        )
        return $true
    }
    $entries = @([regex]::Split("$userPath", ';'))
    $kept = @(
        $entries |
            Where-Object {
                -not (Get-IPQNormalizedPathEntry $_).Equals(
                    $normalizedTarget,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($kept.Count -eq $entries.Count) {
        return $false
    }
    [Environment]::SetEnvironmentVariable(
        'Path',
        ($kept -join ';'),
        'User'
    )
    return $true
}

function Send-IPQEnvironmentChanged {
    try {
        if (-not ('IPQuality.UninstallNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace IPQuality {
    public static class UninstallNative {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr window,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result
        );
    }
}
'@
        }
        $result = [UIntPtr]::Zero
        [void][IPQuality.UninstallNative]::SendMessageTimeout(
            [IntPtr]0xffff,
            [uint32]0x001A,
            [UIntPtr]::Zero,
            'Environment',
            [uint32]2,
            [uint32]3000,
            [ref]$result
        )
    }
    catch {
    }
}

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $runningDestination = [IO.Path]::GetFullPath(
        (Split-Path -Parent $PSScriptRoot)
    )
    $preferredDestination = Join-Path $env:LOCALAPPDATA 'Programs\IPQuality'
    $legacyDestination = Join-Path $env:USERPROFILE (
        'Documents\Codex\Tools\IPQuality-Windows'
    )
    $Destination = if (
        Test-Path -LiteralPath (
            Join-Path $runningDestination '.ipquality-install.json'
        ) -PathType Leaf
    ) {
        $runningDestination
    }
    elseif (
        Test-Path -LiteralPath (
            Join-Path $preferredDestination '.ipquality-install.json'
        ) -PathType Leaf
    ) {
        $preferredDestination
    }
    else {
        $legacyDestination
    }
}

$destinationRoot = [IO.Path]::GetFullPath($Destination)
$manifestPath = Join-Path $destinationRoot '.ipquality-install.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "没有找到 IPQuality 安装清单：$manifestPath"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$manifestProperties = @($manifest.PSObject.Properties.Name)
if (
    'Product' -notin $manifestProperties -or
    'Destination' -notin $manifestProperties -or
    'ShimDirectory' -notin $manifestProperties -or
    'ShimPath' -notin $manifestProperties -or
    $manifest.Product -ne 'IPQuality-Windows' -or
    [string]::IsNullOrWhiteSpace("$($manifest.Destination)") -or
    [string]::IsNullOrWhiteSpace("$($manifest.ShimDirectory)") -or
    [string]::IsNullOrWhiteSpace("$($manifest.ShimPath)") -or
    -not ([IO.Path]::GetFullPath("$($manifest.Destination)")).Equals(
        $destinationRoot,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw '安装清单与目标目录不匹配，已拒绝卸载。'
}

$shimRoot = [IO.Path]::GetFullPath("$($manifest.ShimDirectory)")
$shimPath = [IO.Path]::GetFullPath("$($manifest.ShimPath)")
$expectedShimPath = [IO.Path]::GetFullPath(
    (Join-Path $shimRoot 'ipq.cmd')
)
if (-not $shimPath.Equals(
    $expectedShimPath,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw '安装清单中的命令入口路径异常，已拒绝卸载。'
}

if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
    $shimContent = Get-Content -Raw -LiteralPath $shimPath
    if (
        $shimContent -notmatch 'Start-IPQuality\.ps1' -or
        $shimContent -notmatch 'IPQuality'
    ) {
        throw "命令入口已被其他内容替换，已拒绝删除：$shimPath"
    }
}

if ($PurgeReports) {
    $broadTargets = @(
        [IO.Path]::GetPathRoot($destinationRoot),
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramFiles,
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
        $env:ProgramData,
        $env:windir,
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments')
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if (@(
        $broadTargets |
            Where-Object {
                $destinationRoot.TrimEnd('\').Equals(
                    $_,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    ).Count -gt 0) {
        throw "拒绝递归删除系统或用户宽目录：$destinationRoot"
    }
}

$refFileNames = @()
$runtimeFileNames = @()
if (-not $PurgeReports) {
    $refFileNames = if ('RefFiles' -in $manifestProperties) {
        @($manifest.RefFiles)
    }
    else {
        @(
            'ad1.ans',
            'ad2.ans',
            'ad3.ans',
            'ad4.ans',
            'ad5.ans',
            'ad6.ans',
            'ad7.ans',
            'ad8.ans',
            'cookies.txt',
            'dnsbl.list',
            'iata-icao.csv',
            'iso3166.json',
            'sponsor.ans',
            'upgrade_bash.sh'
        )
    }
    foreach ($fileName in $refFileNames) {
        if (
            [string]::IsNullOrWhiteSpace("$fileName") -or
            [IO.Path]::GetFileName("$fileName") -ne "$fileName"
        ) {
            throw '安装清单中的参考数据文件名异常，已拒绝卸载。'
        }
    }

    $runtimeFileNames = if ('RuntimeFiles' -in $manifestProperties) {
        @($manifest.RuntimeFiles)
    }
    else {
        @(
            'IPQuality.ps1',
            'IPQuality.psm1',
            'Start-IPQuality.ps1',
            'Start-IPQuality.cmd',
            'Prompt-Node.ps1',
            'Test-Node.ps1',
            'Start-NodeCheck.cmd',
            'Install-SingBox.ps1',
            'Compare-IPQuality.ps1',
            'Install-IPQuality.ps1',
            'Uninstall-IPQuality.ps1',
            'README.md'
        )
    }
    foreach ($fileName in $runtimeFileNames) {
        if (
            [string]::IsNullOrWhiteSpace("$fileName") -or
            [IO.Path]::GetFileName("$fileName") -ne "$fileName"
        ) {
            throw '安装清单中的运行文件名异常，已拒绝卸载。'
        }
    }
}

$pathRemoved = $false
$pathWasManaged = (
    'PathManaged' -in $manifestProperties -and
    $manifest.PathManaged
)
if (-not $KeepPath -and $pathWasManaged) {
    $pathRemoved = Remove-IPQUserPathEntry -Path $shimRoot
    if ($pathRemoved) {
        Send-IPQEnvironmentChanged
    }
}
if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
    Remove-Item -LiteralPath $shimPath -Force
}

$reportsDirectory = Join-Path $destinationRoot 'windows\reports'
$reportsPreserved = (
    -not $PurgeReports -and
    (Test-Path -LiteralPath $reportsDirectory)
)
if ($PurgeReports) {
    Remove-Item -LiteralPath $destinationRoot -Recurse -Force
}
else {
    $refDirectory = Join-Path $destinationRoot 'ref'
    foreach ($fileName in $refFileNames) {
        $refPath = Join-Path $refDirectory "$fileName"
        if (Test-Path -LiteralPath $refPath -PathType Leaf) {
            Remove-Item -LiteralPath $refPath -Force
        }
    }
    if (
        (Test-Path -LiteralPath $refDirectory -PathType Container) -and
        $null -eq (Get-ChildItem -LiteralPath $refDirectory -Force |
            Select-Object -First 1)
    ) {
        Remove-Item -LiteralPath $refDirectory -Force
    }

    $singBoxDirectory = Join-Path (
        $destinationRoot
    ) 'windows\tools\sing-box'
    if (Test-Path -LiteralPath $singBoxDirectory -PathType Container) {
        Remove-Item -LiteralPath $singBoxDirectory -Recurse -Force
    }
    $toolsDirectory = Join-Path $destinationRoot 'windows\tools'
    if (
        (Test-Path -LiteralPath $toolsDirectory -PathType Container) -and
        $null -eq (Get-ChildItem -LiteralPath $toolsDirectory -Force |
            Select-Object -First 1)
    ) {
        Remove-Item -LiteralPath $toolsDirectory -Force
    }
    foreach ($file in @(
        (Join-Path $destinationRoot 'LICENSE'),
        (Join-Path $destinationRoot 'ip.sh')
    )) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force
        }
    }
    $windowsDirectory = Join-Path $destinationRoot 'windows'
    foreach ($fileName in $runtimeFileNames) {
        if ("$fileName".Equals(
            'Uninstall-IPQuality.ps1',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        $runtimePath = Join-Path $windowsDirectory $fileName
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            Remove-Item -LiteralPath $runtimePath -Force
        }
    }
    $binDirectory = Join-Path $destinationRoot 'bin'
    if (
        (Test-Path -LiteralPath $binDirectory -PathType Container) -and
        $null -eq (Get-ChildItem -LiteralPath $binDirectory -Force |
            Select-Object -First 1)
    ) {
        Remove-Item -LiteralPath $binDirectory -Force
    }
    $manifest | Add-Member `
        -NotePropertyName Installed `
        -NotePropertyValue $false `
        -Force
    if (-not $KeepPath) {
        $manifest | Add-Member `
            -NotePropertyName PathManaged `
            -NotePropertyValue $false `
            -Force
    }
    $manifest | Add-Member `
        -NotePropertyName UninstalledUtc `
        -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) `
        -Force
    [IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
}

[pscustomobject][ordered]@{
    Uninstalled = $true
    Destination = $destinationRoot
    PathRemoved = $pathRemoved
    ReportsPreserved = $reportsPreserved
    Purged = [bool]$PurgeReports
}
