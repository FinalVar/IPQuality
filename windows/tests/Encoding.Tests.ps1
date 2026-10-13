#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'IPQuality.psm1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$module = Get-Module IPQuality
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ipq-encoding-' + [Guid]::NewGuid().ToString('N') + '.json')
$originalEncoding = [Console]::OutputEncoding
# Use real curl bytes, rather than a mocked .NET string that is already decoded.
$payload = '{"country":"香港","continent":"亚洲","organization":"München 東京 🌏","ascii":"AS134972"}'
try {
    [IO.File]::WriteAllText($fixture, $payload, [Text.UTF8Encoding]::new($false))
    $uri = [Uri]::new($fixture).AbsoluteUri
    foreach ($codePage in @(936, 65001)) {
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding($codePage)
        $response = & $module {
            param($FixtureUri)
            $context = New-IPQContext -AddressFamily 4 -TimeoutSeconds 2
            Invoke-IPQRequest -Context $context -Uri $FixtureUri
        } $uri
        if (-not $response.Success -or $response.ExitCode -ne 0) {
            throw "Local curl fixture failed: $($response.Error)"
        }
        if ($response.Body -cne $payload) {
            throw "UTF-8 response was corrupted under console code page $codePage"
        }
        $data = $response.Body | ConvertFrom-Json
        if ($data.country -cne '香港' -or $data.continent -cne '亚洲') {
            throw "Region JSON was corrupted under console code page $codePage"
        }
        if ([Console]::OutputEncoding.CodePage -ne $codePage) {
            throw 'HTTP decoding must not change the caller console encoding'
        }
    }
} finally {
    [Console]::OutputEncoding = $originalEncoding
    if (Test-Path -LiteralPath $fixture -PathType Leaf) {
        Remove-Item -LiteralPath $fixture
    }
}
Write-Host 'PASS: UTF-8 curl decoding under GBK and UTF-8 console code pages'
