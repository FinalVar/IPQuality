#Requires -Version 7.2
[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
function Invoke-Git {
    param([string[]]$GitArguments)
    $output = & git -C $repo @GitArguments
    if ($LASTEXITCODE -ne 0) { throw "git failed: $($GitArguments -join ' ')" }
    return $output
}
if (@(Invoke-Git -GitArguments @('status', '--porcelain', '--untracked-files=normal')).Count) {
    throw 'Commit changes before packaging. The source tree must be clean.'
}
$commit = Invoke-Git -GitArguments @('rev-parse', 'HEAD')
$tree = Invoke-Git -GitArguments @('rev-parse', 'HEAD^{tree}')
$version = (Get-Content -LiteralPath (Join-Path $repo 'windows/compatibility-baseline.json') -Raw |
    ConvertFrom-Json).WindowsVersion
$tag = "windows-v$version-preview.1"
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $repo) "artifacts/$tag"
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) {
    throw "Output directory already exists; choose a new one: $outputRoot"
}
$null = New-Item -ItemType Directory -Path $outputRoot
$zipPath = Join-Path $outputRoot 'latest.zip'
Invoke-Git -GitArguments @('archive', '--format=zip', '--prefix=IPQuality-Windows/', "--output=$zipPath", 'HEAD') | Out-Null
$members = [Collections.Generic.List[object]]::new()
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        $stream = $entry.Open()
        try {
            $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        }
        finally { $stream.Dispose() }
        $members.Add([ordered]@{path=$entry.FullName; size=$entry.Length; sha256=$sha})
    }
}
finally { $zip.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    schema_version = 1
    repository = 'https://github.com/FinalVar/IPQuality'
    version = $version
    tag = $tag
    prerelease = $true
    commit = $commit
    tree = $tree
    source_commit_time = (Invoke-Git -GitArguments @('show', '-s', '--format=%cI', 'HEAD'))
    archive = 'latest.zip'
    sha256 = $zipHash
    files = @($members.ToArray() | Sort-Object path)
}
[IO.File]::WriteAllText((Join-Path $outputRoot 'latest.json'), ($manifest | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $outputRoot 'latest.sha256'), "$zipHash  latest.zip`n", [Text.UTF8Encoding]::new($false))
Write-Output "Built $tag from $commit ($($members.Count) source files)."
Write-Output $outputRoot
