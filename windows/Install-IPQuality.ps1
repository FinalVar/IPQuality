#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$ShimDirectory,
    [switch]$NoPath
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

function Add-IPQUserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    $normalizedTarget = Get-IPQNormalizedPathEntry $Path
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @(
        "$userPath" -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    $alreadyPresent = @(
        $entries |
            Where-Object {
                (Get-IPQNormalizedPathEntry $_).Equals(
                    $normalizedTarget,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    ).Count -gt 0

    if (-not $alreadyPresent) {
        $entry = $Path.TrimEnd('\')
        $newUserPath = if ([string]::IsNullOrEmpty($userPath)) {
            $entry
        }
        else {
            "$userPath;$entry"
        }
        [Environment]::SetEnvironmentVariable(
            'Path',
            $newUserPath,
            'User'
        )
    }
    if (
        -not @(
            $env:Path -split ';' |
                Where-Object {
                    (Get-IPQNormalizedPathEntry $_).Equals(
                        $normalizedTarget,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        ).Count
    ) {
        $entry = $Path.TrimEnd('\')
        $env:Path = if ([string]::IsNullOrEmpty($env:Path)) {
            $entry
        }
        else {
            "$env:Path;$entry"
        }
    }
    return -not $alreadyPresent
}

function Test-IPQUserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    $normalizedTarget = Get-IPQNormalizedPathEntry $Path
    return @(
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
            Where-Object {
                (Get-IPQNormalizedPathEntry $_).Equals(
                    $normalizedTarget,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    ).Count -gt 0
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
        if (-not ('IPQuality.InstallNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace IPQuality {
    public static class InstallNative {
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
        [void][IPQuality.InstallNative]::SendMessageTimeout(
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

function ConvertTo-IPQCmdPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($definition in @(
        @('LOCALAPPDATA', $env:LOCALAPPDATA),
        @('USERPROFILE', $env:USERPROFILE)
    )) {
        if ([string]::IsNullOrWhiteSpace($definition[1])) {
            continue
        }
        $root = [IO.Path]::GetFullPath($definition[1]).TrimEnd('\')
        if (
            $fullPath.Equals(
                $root,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $fullPath.StartsWith(
                "$root\",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return "%$($definition[0])%$($fullPath.Substring($root.Length))"
        }
    }
    return $fullPath
}

function Get-IPQSourceFingerprint {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$RelativePaths
    )

    [string[]]$orderedPaths = @(
        $RelativePaths |
            ForEach-Object { "$_".Replace('/', '\') } |
            Select-Object -Unique
    )
    [Array]::Sort(
        $orderedPaths,
        [StringComparer]::OrdinalIgnoreCase
    )
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($relativePath in $orderedPaths) {
        $sourcePath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "来源指纹文件缺失：$sourcePath"
        }
        $fileHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [IO.File]::ReadAllBytes($sourcePath)
            )
        ).ToLowerInvariant()
        $portablePath = $relativePath.Replace('\', '/')
        $entries.Add("$portablePath`t$fileHash")
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(
        ($entries -join "`n")
    )
    [pscustomobject][ordered]@{
        Algorithm = 'SHA256(path<TAB>sha256;LF;v1)'
        Value = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($payload)
        ).ToLowerInvariant()
        FileCount = $entries.Count
    }
}

$sourceWindows = [IO.Path]::GetFullPath($PSScriptRoot)
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $sourceWindows))

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $preferredDestination = Join-Path $env:LOCALAPPDATA 'Programs\IPQuality'
    $legacyDestination = Join-Path $env:USERPROFILE (
        'Documents\Codex\Tools\IPQuality-Windows'
    )
    $Destination = if (
        Test-Path -LiteralPath (
            Join-Path $preferredDestination 'windows\Start-IPQuality.ps1'
        ) -PathType Leaf
    ) {
        $preferredDestination
    }
    elseif (
        Test-Path -LiteralPath (
            Join-Path $legacyDestination 'windows\Start-IPQuality.ps1'
        ) -PathType Leaf
    ) {
        $legacyDestination
    }
    else {
        $preferredDestination
    }
}

$destinationRoot = [IO.Path]::GetFullPath($Destination)
$destinationWindows = Join-Path $destinationRoot 'windows'
$destinationRef = Join-Path $destinationRoot 'ref'
$reportsDirectory = Join-Path $destinationWindows 'reports'
$manifestPath = Join-Path $destinationRoot '.ipquality-install.json'
$manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
$wasInstalled = $false
$previousManifest = $null
$previousPathManaged = $false
if ($manifestExists) {
    try {
        $previousManifest = Get-Content -Raw -LiteralPath $manifestPath |
            ConvertFrom-Json
    }
    catch {
        throw "现有安装清单无法读取，已拒绝覆盖：$manifestPath"
    }
    $manifestProperties = @($previousManifest.PSObject.Properties.Name)
    if (
        'Product' -notin $manifestProperties -or
        'Destination' -notin $manifestProperties -or
        'ShimDirectory' -notin $manifestProperties -or
        'ShimPath' -notin $manifestProperties -or
        $previousManifest.Product -ne 'IPQuality-Windows' -or
        [string]::IsNullOrWhiteSpace(
            "$($previousManifest.Destination)"
        ) -or
        [string]::IsNullOrWhiteSpace(
            "$($previousManifest.ShimDirectory)"
        ) -or
        [string]::IsNullOrWhiteSpace(
            "$($previousManifest.ShimPath)"
        ) -or
        -not ([IO.Path]::GetFullPath(
            "$($previousManifest.Destination)"
        )).Equals(
            $destinationRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "现有安装清单与目标目录不匹配，已拒绝覆盖：$manifestPath"
    }
    if (
        'Installed' -in $manifestProperties -and
        $previousManifest.Installed
    ) {
        $wasInstalled = $true
    }
    if (
        'PathManaged' -in $manifestProperties -and
        $previousManifest.PathManaged
    ) {
        $previousPathManaged = $true
    }
}

if ([string]::IsNullOrWhiteSpace($ShimDirectory)) {
    if ($null -ne $previousManifest) {
        $ShimDirectory = "$($previousManifest.ShimDirectory)"
    }
    else {
        $legacyShimRoot = Join-Path $env:USERPROFILE '.local\bin'
        $legacyShimPath = Join-Path $legacyShimRoot 'ipq.cmd'
        if (Test-Path -LiteralPath $legacyShimPath -PathType Leaf) {
            $legacyShimContent = Get-Content -Raw -LiteralPath $legacyShimPath
            $expectedLauncher = [IO.Path]::GetFullPath(
                (Join-Path $destinationWindows 'Start-IPQuality.ps1')
            )
            if (
                $legacyShimContent.IndexOf(
                    $expectedLauncher,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0 -and
                $legacyShimContent -match 'IPQuality'
            ) {
                $ShimDirectory = $legacyShimRoot
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ShimDirectory)) {
        $ShimDirectory = Join-Path $destinationRoot 'bin'
    }
}
$shimRoot = [IO.Path]::GetFullPath($ShimDirectory)
$shimPath = Join-Path $shimRoot 'ipq.cmd'

$sourcePrefix = "$($sourceRoot.TrimEnd('\'))\"
$destinationPrefix = "$($destinationRoot.TrimEnd('\'))\"
if (
    $destinationRoot.Equals(
        $sourceRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
    $destinationRoot.StartsWith(
        $sourcePrefix,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
    $sourceRoot.StartsWith(
        $destinationPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw '安装目录不能与源代码目录相同，也不能互相包含。'
}

$looksLikeLegacyInstall = (
    (Test-Path -LiteralPath (
        Join-Path $destinationRoot 'windows\Start-IPQuality.ps1'
    ) -PathType Leaf) -and
    (Test-Path -LiteralPath (
        Join-Path $destinationRoot 'windows\IPQuality.psm1'
    ) -PathType Leaf) -and
    (Test-Path -LiteralPath (
        Join-Path $destinationRoot 'ref\dnsbl.list'
    ) -PathType Leaf) -and
    (Test-Path -LiteralPath (
        Join-Path $destinationRoot 'LICENSE'
    ) -PathType Leaf)
)
if (
    (Test-Path -LiteralPath $destinationRoot -PathType Container) -and
    -not $manifestExists -and
    -not $looksLikeLegacyInstall -and
    $null -ne (Get-ChildItem -LiteralPath $destinationRoot -Force |
        Select-Object -First 1)
) {
    throw "安装目录并非空目录或既有 IPQuality 安装，已拒绝覆盖：$destinationRoot"
}

$previousShimRoot = ''
$previousShimPath = ''
$previousPathStillPresent = $false
if ($null -ne $previousManifest) {
    $previousShimRoot = [IO.Path]::GetFullPath(
        "$($previousManifest.ShimDirectory)"
    )
    $previousShimPath = [IO.Path]::GetFullPath(
        "$($previousManifest.ShimPath)"
    )
    if (-not $previousShimPath.Equals(
        (Join-Path $previousShimRoot 'ipq.cmd'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '现有安装清单中的命令入口路径异常，已拒绝覆盖。'
    }
    if ($previousPathManaged) {
        $previousPathStillPresent = Test-IPQUserPathEntry -Path (
            $previousShimRoot
        )
    }
}
$shimChanged = (
    $previousShimRoot -and
    -not $previousShimRoot.Equals(
        $shimRoot,
        [StringComparison]::OrdinalIgnoreCase
    )
)
if ($NoPath -and $shimChanged -and $previousPathStillPresent) {
    throw (
        '使用 -NoPath 时不能更换既有的命令入口目录，' +
        '否则会遗留由安装器管理的旧 PATH。'
    )
}

foreach ($directory in @(
    $destinationRoot,
    $destinationWindows,
    $destinationRef,
    $reportsDirectory,
    $shimRoot
)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
}

foreach ($fileName in @('LICENSE', 'ip.sh')) {
    $sourcePath = Join-Path $sourceRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "源文件缺失：$sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationRoot -Force
}

foreach ($fileName in @('Uninstall.ps1', 'Uninstall.cmd')) {
    $sourcePath = Join-Path $sourceRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "卸载入口缺失：$sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationRoot -Force
}

$sourceRefFiles = @(
    Get-ChildItem -LiteralPath (
    Join-Path $sourceRoot 'ref'
) -File
)
foreach ($sourceFile in $sourceRefFiles) {
    Copy-Item -LiteralPath $sourceFile.FullName `
        -Destination $destinationRef `
        -Force
}

$runtimeFiles = @(
    'IPQuality.ps1',
    'IPQuality.psm1',
    'Start-IPQuality.ps1',
    'Start-IPQuality.cmd',
    'Prompt-Node.ps1',
    'Test-Node.ps1',
    'Start-NodeCheck.cmd',
    'Install-SingBox.ps1',
    'Compare-IPQuality.ps1',
    'compatibility-baseline.json',
    'Install-IPQuality.ps1',
    'Uninstall-IPQuality.ps1',
    'README.md',
    'README_EN.md',
    'MAINTENANCE.md'
)
foreach ($fileName in $runtimeFiles) {
    $sourcePath = Join-Path $sourceWindows $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "运行文件缺失：$sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath `
        -Destination $destinationWindows `
        -Force
}

$sourceFingerprintPaths = [Collections.Generic.List[string]]::new()
foreach ($relativePath in @(
    'Install.cmd',
    'Install.ps1',
    'Uninstall.cmd',
    'Uninstall.ps1',
    'LICENSE',
    'ip.sh'
)) {
    $sourceFingerprintPaths.Add($relativePath)
}
foreach ($fileName in $sourceRefFiles.Name) {
    $sourceFingerprintPaths.Add("ref\$fileName")
}
foreach ($fileName in $runtimeFiles) {
    $sourceFingerprintPaths.Add("windows\$fileName")
}
$sourceFingerprint = Get-IPQSourceFingerprint `
    -Root $sourceRoot `
    -RelativePaths $sourceFingerprintPaths.ToArray()

$launcherPath = ConvertTo-IPQCmdPath (
    Join-Path $destinationWindows 'Start-IPQuality.ps1'
)
$shim = @"
@echo off
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  where.exe pwsh.exe >nul 2>nul
  if errorlevel 1 (
    echo [IPQuality] PowerShell 7.2 or newer is required.
    echo Download: https://aka.ms/powershell-release?tag=stable
    exit /b 1
  )
  set "PWSH=pwsh.exe"
)
start "IPQuality" "%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "$launcherPath" %*
endlocal
"@
$shimEncoding = if ($shim -match '[^\x00-\x7F]') {
    [Text.UTF8Encoding]::new($true)
}
else {
    [Text.ASCIIEncoding]::new()
}
[IO.File]::WriteAllText(
    $shimPath,
    ($shim -replace "`n", "`r`n"),
    $shimEncoding
)

$pathAdded = $false
$oldPathRemoved = $false
$oldShimRemoved = $false
if (-not $NoPath) {
    $pathAdded = Add-IPQUserPathEntry -Path $shimRoot
    if ($shimChanged -and $previousPathStillPresent) {
        $oldPathRemoved = Remove-IPQUserPathEntry -Path $previousShimRoot
    }
    if (
        $shimChanged -and
        $previousShimPath.Equals(
            (Join-Path $previousShimRoot 'ipq.cmd'),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Test-Path -LiteralPath $previousShimPath -PathType Leaf)
    ) {
        $previousShimContent = Get-Content -Raw -LiteralPath $previousShimPath
        if (
            $previousShimContent -match 'Start-IPQuality\.ps1' -and
            $previousShimContent -match 'IPQuality'
        ) {
            Remove-Item -LiteralPath $previousShimPath -Force
            $oldShimRemoved = $true
        }
    }
    if ($pathAdded -or $oldPathRemoved) {
        Send-IPQEnvironmentChanged
    }
}

$sourceCommit = ''
try {
    $commitOutput = (
        & git -C $sourceRoot rev-parse HEAD 2>$null |
            Select-Object -First 1
    )
    if ($commitOutput) {
        $sourceCommit = "$commitOutput".Trim()
    }
}
catch {
}
$manifest = [pscustomobject][ordered]@{
    SchemaVersion = 4
    Product = 'IPQuality-Windows'
    Installed = $true
    InstalledUtc = [DateTime]::UtcNow.ToString('o')
    Destination = $destinationRoot
    ShimDirectory = $shimRoot
    ShimPath = $shimPath
    PathManaged = (
        $pathAdded -or
        (
            -not $shimChanged -and
            $previousPathManaged -and
            $previousPathStillPresent
        )
    )
    RuntimeFiles = @($runtimeFiles)
    RefFiles = @($sourceRefFiles.Name)
    SourceCommit = $sourceCommit
    SourceFingerprintAlgorithm = $sourceFingerprint.Algorithm
    SourceFingerprint = $sourceFingerprint.Value
    SourceFileCount = $sourceFingerprint.FileCount
}
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)

$shimOnUserPath = Test-IPQUserPathEntry -Path $shimRoot

[pscustomobject][ordered]@{
    Installed = $true
    Upgraded = $wasInstalled
    Destination = $destinationRoot
    Command = 'ipq'
    Shim = $shimPath
    Uninstaller = (Join-Path $destinationRoot 'Uninstall.cmd')
    PathAdded = $pathAdded
    OldPathRemoved = $oldPathRemoved
    OldShimRemoved = $oldShimRemoved
    ShimOnUserPath = $shimOnUserPath
    Reports = $reportsDirectory
    RestartTerminalRecommended = $pathAdded
    SourceCommit = $sourceCommit
    SourceFingerprint = $sourceFingerprint.Value
}
