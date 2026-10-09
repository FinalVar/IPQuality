#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ArtifactDirectory)
$manifest = Get-Content -LiteralPath (Join-Path $root 'latest.json') -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.archive -ne 'latest.zip' -or
    $manifest.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid release manifest.' }
$archivePath = Join-Path $root 'latest.zip'
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -cne $manifest.sha256) { throw 'Archive checksum mismatch.' }
$checksumFile = (Get-Content -LiteralPath (Join-Path $root 'latest.sha256') -Raw).Trim()
if ($checksumFile -cne "$actualHash  latest.zip") { throw 'Checksum file mismatch.' }
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
$expected = @{}
foreach ($file in $manifest.files) {
    if ($expected.ContainsKey($file.path)) { throw 'Duplicate manifest entry.' }
    $expected[$file.path] = $file
}
$seen = @{}
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        if (-not $entry.FullName.StartsWith('IPQuality-Windows/') -or
            $entry.FullName.Contains('\') -or $entry.FullName -match '(^|/)\.\.(/|$)' -or
            $entry.FullName.Contains(':')) { throw "Unsafe ZIP member: $($entry.FullName)" }
        if ($seen.ContainsKey($entry.FullName) -or -not $expected.ContainsKey($entry.FullName)) {
            throw 'Unexpected or duplicate archive entry.'
        }
        $seen[$entry.FullName] = $true
        $stream = $entry.Open()
        try {
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        }
        finally { $stream.Dispose() }
        $file = $expected[$entry.FullName]
        if ($hash -cne $file.sha256 -or $entry.Length -ne $file.size) { throw "File hash mismatch: $($entry.FullName)" }
    }
}
finally { $zip.Dispose() }
if ($seen.Count -ne $expected.Count) { throw 'Archive membership mismatch.' }
foreach ($path in @('LICENSE', 'Install.cmd', 'Install.ps1', 'ip.sh',
    'windows/IPQuality.psm1', 'windows/Show-Demo.ps1', 'windows/examples/latest.json',
    'scripts/Build-Release.ps1', 'scripts/Test-Release.ps1')) {
    if (-not $seen.ContainsKey("IPQuality-Windows/$path")) { throw "Missing source: $path" }
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase "ipquality-release-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
try {
    $extractRoot = Join-Path $testRoot 'source'
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractRoot)
    $source = Join-Path $extractRoot 'IPQuality-Windows'
    $sample = & (Join-Path $source 'windows/Show-Demo.ps1') -Json | ConvertFrom-Json
    if ($sample.Head.Demo -ne $true -or $sample.Head.Address -notmatch '\*') { throw 'Demo privacy markers missing.' }
    $demoOutput = & (Join-Path $source 'windows/Show-Demo.ps1') 6>&1 | Out-String
    if ($demoOutput -notmatch 'OFFLINE DEMO' -or $demoOutput -notmatch 'FinalVar/IPQuality') {
        throw 'Offline renderer failed.'
    }
    $installRoot = Join-Path $testRoot 'installed'
    $shimRoot = Join-Path $testRoot 'bin'
    & (Join-Path $source 'Install.ps1') -Destination $installRoot -ShimDirectory $shimRoot -NoPath | Out-Null
    $installedModule = Join-Path $installRoot 'windows/IPQuality.psm1'
    if (-not (Test-Path -LiteralPath $installedModule)) { throw 'Archive installation failed.' }
    $installedHash = (Get-FileHash -LiteralPath $installedModule -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -cne $expected['IPQuality-Windows/windows/IPQuality.psm1'].sha256) {
        throw 'Installed module differs from release source.'
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $userPathBefore) {
        throw '-NoPath installation modified user PATH.'
    }
    Write-Output "PASS: release checksum, $($seen.Count) source files, offline demo and clean archive installation."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^ipquality-release-[0-9a-f]{32}$') {
        throw 'Refusing cleanup outside the dedicated test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
