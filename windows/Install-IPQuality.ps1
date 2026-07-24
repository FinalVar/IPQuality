#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Destination = (
        Join-Path $env:USERPROFILE 'Documents\Codex\Tools\IPQuality-Windows'
    ),
    [string]$ShimDirectory = (
        Join-Path $env:USERPROFILE '.local\bin'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceWindows = [IO.Path]::GetFullPath($PSScriptRoot)
$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $sourceWindows))
$destinationRoot = [IO.Path]::GetFullPath($Destination)
$destinationWindows = Join-Path $destinationRoot 'windows'
$destinationRef = Join-Path $destinationRoot 'ref'
$reportsDirectory = Join-Path $destinationWindows 'reports'
$shimRoot = [IO.Path]::GetFullPath($ShimDirectory)
$shimPath = Join-Path $shimRoot 'ipq.cmd'

if ($destinationRoot.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装目录不能与源代码目录相同。'
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

foreach ($sourceFile in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'ref') -File) {
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationRef -Force
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
    'README.md'
)
foreach ($fileName in $runtimeFiles) {
    $sourcePath = Join-Path $sourceWindows $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "运行文件缺失：$sourcePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationWindows -Force
}

$escapedLauncher = (Join-Path $destinationWindows 'Start-IPQuality.ps1').Replace(
    '%',
    '%%'
)
$shim = @"
@echo off
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  echo [IPQuality] PowerShell 7.2 or newer is required.
  exit /b 1
)
start "IPQuality" "%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "$escapedLauncher" %*
endlocal
"@
[IO.File]::WriteAllText(
    $shimPath,
    ($shim -replace "`n", "`r`n"),
    [Text.ASCIIEncoding]::new()
)

$userPathEntries = @(
    [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        ForEach-Object { $_.TrimEnd('\') } |
        Where-Object { $_ }
)
$shimOnUserPath = $userPathEntries -contains $shimRoot.TrimEnd('\')

[pscustomobject][ordered]@{
    Installed = $true
    Destination = $destinationRoot
    Command = 'ipq'
    Shim = $shimPath
    ShimOnUserPath = $shimOnUserPath
    Reports = $reportsDirectory
}
