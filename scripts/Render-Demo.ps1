#Requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'windows/IPQuality.psm1') -Force
$sample = Get-Content -LiteralPath (Join-Path $repo 'windows/examples/latest.json') -Raw | ConvertFrom-Json
if ($sample.Head.Demo -ne $true) { throw 'Only synthetic samples may be rendered.' }
$module = Get-Module IPQuality
$raw = & $module { param($data) Write-IPQPrettyReport -Result $data } $sample 6>&1
$lines = [Collections.Generic.List[string]]::new()
$segments = [Collections.Generic.List[object]]::new()
$column = 0
$line = [Text.StringBuilder]::new()
foreach ($record in $raw) {
    $part = $record.MessageData
    $cells = & $module { param($text) Get-IPQDisplayWidth $text } $part.Message
    if ($cells) {
        $segments.Add(@{row=$lines.Count; column=$column; cells=$cells; text=$part.Message;
            foreground=[string]$part.ForegroundColor; background=[string]$part.BackgroundColor})
    }
    $column += $cells
    [void]$line.Append($part.Message)
    if (-not $part.NoNewLine) {
        $lines.Add($line.ToString())
        [void]$line.Clear()
        $column = 0
    }
}
if ($line.Length) { $lines.Add($line.ToString()) }
$directory = Join-Path $repo 'docs/demo'
$null = New-Item -ItemType Directory -Path $directory -Force
$height = 106 + $lines.Count * 20
$svg = [Text.StringBuilder]::new()
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"784`" height=`"$height`" viewBox=`"0 0 784 $height`" role=`"img`" aria-labelledby=`"title desc`">")
[void]$svg.AppendLine('<title id="title">IPQuality for Windows — offline synthetic demo</title>')
[void]$svg.AppendLine('<desc id="desc">Generated with the actual console formatter from synthetic data. This is not a screenshot or a live IP test.</desc>')
[void]$svg.AppendLine("<rect width=`"784`" height=`"$height`" rx=`"14`" fill=`"#101827`"/>")
[void]$svg.AppendLine('<text x="32" y="36" fill="#fbbf24" font-family="Segoe UI, sans-serif" font-size="18">OFFLINE DEMO · SYNTHETIC DATA · 合成数据演示</text>')
[void]$svg.AppendLine('<text x="32" y="60" fill="#9ca3af" font-family="Segoe UI, sans-serif" font-size="14">Actual formatter output · No network requests · Not a real IP measurement</text>')
$palette = @{Black='#101827'; DarkBlue='#1e3a8a'; DarkGreen='#166534'; DarkCyan='#0e7490';
    DarkRed='#991b1b'; DarkMagenta='#86198f'; DarkYellow='#92400e'; Gray='#d1d5db';
    DarkGray='#6b7280'; Blue='#60a5fa'; Green='#86efac'; Cyan='#67e8f9'; Red='#fca5a5';
    Magenta='#f0abfc'; Yellow='#fde68a'; White='#ffffff'}
$foregroundPalette = $palette.Clone()
$foregroundPalette.DarkCyan = '#22d3ee'
$foregroundPalette.DarkGreen = '#4ade80'
$foregroundPalette.DarkYellow = '#fbbf24'
$foregroundPalette.DarkRed = '#f87171'
$foregroundPalette.DarkGray = '#94a3b8'
foreach ($part in $segments) {
    $text = [Security.SecurityElement]::Escape($part.text)
    $color = if ($foregroundPalette.ContainsKey($part.foreground)) { $foregroundPalette[$part.foreground] } else { '#e5e7eb' }
    $x = 32 + $part.column * 10
    $y = 96 + $part.row * 20
    $width = $part.cells * 10
    if ($palette.ContainsKey($part.background)) {
        [void]$svg.AppendLine("<rect x=`"$x`" y=`"$($y-16)`" width=`"$width`" height=`"20`" fill=`"$($palette[$part.background])`"/>")
    }
    [void]$svg.AppendLine("<text x=`"$x`" y=`"$y`" fill=`"$color`" font-family=`"Consolas, 'Microsoft YaHei', monospace`" font-size=`"16`" textLength=`"$width`" lengthAdjust=`"spacingAndGlyphs`" xml:space=`"preserve`">$text</text>")
}
[void]$svg.AppendLine('</svg>')
[IO.File]::WriteAllText((Join-Path $directory 'latest.svg'), $svg.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $directory 'latest.txt'), "OFFLINE DEMO / SYNTHETIC DATA`n" + (($lines | ForEach-Object { $_.TrimEnd() }) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Output "Rendered $($lines.Count) lines from the real console formatter."
