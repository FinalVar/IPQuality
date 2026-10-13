#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('4')][switch]$IPv4,
    [Alias('6')][switch]$IPv6,
    [Alias('x')][string]$Proxy,
    [Alias('i')][string]$Interface,
    [Alias('f')][switch]$FullIP,
    [Alias('j')][switch]$Json,
    [Alias('o')][string]$Output,
    [Alias('l')][ValidateSet('cn','en','jp','es','de','fr','ru','pt')][string]$Language = 'cn',
    [Alias('E')][switch]$English,
    [Alias('p')][switch]$Privacy,
    [switch]$AllowOnlineReport,
    [switch]$UpstreamJson,
    [Alias('h')][switch]$Help,
    [Alias('M')][switch]$Menu,
    [switch]$ShowSponsors,
    [switch]$CountRun,
    [Alias('n')][switch]$NoDependencyCheck,
    [Alias('y')][switch]$InstallDependencies,
    [switch]$Force,
    [switch]$Lite,
    [switch]$NoRisk,
    [switch]$NoMedia,
    [switch]$NoMail,
    [switch]$NoDnsbl,
    [ValidateRange(2, 60)]
    [int]$TimeoutSeconds = 10,
    [ValidateRange(1, 100)]
    [int]$DnsblConcurrency = 40,
    [ValidateRange(8, 32)]
    [int]$ConsoleFontSize = 18
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'IPQuality.psm1'
Import-Module $modulePath -Force
if ($Help) {
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CLI-HELP.txt')
    return
}
if ($Menu) {
    & (Join-Path $PSScriptRoot 'Show-IPQualityMenu.ps1')
    return
}
if ($ShowSponsors) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../ref') -File | Where-Object Name -Match '^(sponsor|ad[0-9]+)\.ans$' | Sort-Object Name)) {
        Get-Content -LiteralPath $file.FullName -Raw
    }
    return
}
if ($Privacy -and $AllowOnlineReport) { throw '-Privacy 与 -AllowOnlineReport 不能同时使用。' }
if ($English) { $Language = 'en' }
if ($UpstreamJson) { $Json = $true }
# -n/-y retain the upstream CLI surface. Platform installation belongs to
# Install.ps1; PowerShell/curl are the only native runtime dependencies.
if (-not $NoDependencyCheck) { Get-Command curl.exe -ErrorAction Stop | Out-Null }
if ($Json) { $InformationPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue' }
$script:IPQSelectedConsoleFontSize = $null

function Set-IPQConsoleLayout {
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsOutputRedirected) {
        return
    }

    try {
        if (-not ('IPQuality.NativeConsole' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace IPQuality {
    public static class NativeConsole {
        [StructLayout(LayoutKind.Sequential)]
        public struct Coord {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct FontInfo {
            public uint Size;
            public uint Font;
            public Coord FontSize;
            public int FontFamily;
            public int FontWeight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string FaceName;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool SetCurrentConsoleFontEx(
            IntPtr output,
            bool maximumWindow,
            ref FontInfo info
        );

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr window, int command);

        public static void RestoreWindow() {
            var window = GetConsoleWindow();
            if (window != IntPtr.Zero) {
                ShowWindow(window, 9);
            }
        }

        public static bool SetFont(short height) {
            var info = new FontInfo {
                Size = (uint)Marshal.SizeOf<FontInfo>(),
                FontSize = new Coord { X = 0, Y = height },
                FontFamily = 54,
                FontWeight = 400,
                FaceName = "Consolas"
            };
            return SetCurrentConsoleFontEx(GetStdHandle(-11), false, ref info);
        }
    }
}
'@
        }
        [IPQuality.NativeConsole]::RestoreWindow()

        if ($null -eq $script:IPQSelectedConsoleFontSize) {
            for (
                $candidate = $ConsoleFontSize;
                $candidate -ge 8;
                $candidate--
            ) {
                if (
                    -not [IPQuality.NativeConsole]::SetFont(
                        [int16]$candidate
                    )
                ) {
                    continue
                }
                $candidateMaximum = $Host.UI.RawUI.MaxPhysicalWindowSize
                if (
                    $candidateMaximum.Width -ge 74 -and
                    $candidateMaximum.Height -ge 47
                ) {
                    $script:IPQSelectedConsoleFontSize = $candidate
                    break
                }
            }
            if ($null -eq $script:IPQSelectedConsoleFontSize) {
                $script:IPQSelectedConsoleFontSize = 8
            }
        }
        [IPQuality.NativeConsole]::SetFont(
            [int16]$script:IPQSelectedConsoleFontSize
        ) | Out-Null

        $maximum = $Host.UI.RawUI.MaxPhysicalWindowSize
        $targetWidth = [Math]::Min(74, $maximum.Width)
        $targetHeight = [Math]::Min(47, $maximum.Height)
        $buffer = $Host.UI.RawUI.BufferSize
        $buffer.Width = [Math]::Max($buffer.Width, $targetWidth)
        $buffer.Height = [Math]::Max($buffer.Height, $targetHeight)
        $Host.UI.RawUI.BufferSize = $buffer
        $window = $Host.UI.RawUI.WindowSize
        $window.Width = $targetWidth
        $window.Height = $targetHeight
        $Host.UI.RawUI.WindowSize = $window
        $buffer = $Host.UI.RawUI.BufferSize
        $buffer.Width = $Host.UI.RawUI.WindowSize.Width
        $buffer.Height = $Host.UI.RawUI.WindowSize.Height
        $Host.UI.RawUI.BufferSize = $buffer
    }
    catch {
    }
}
Set-IPQConsoleLayout
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    try {
        $Host.UI.RawUI.WindowTitle = if ($Lite) { 'IPQuality Lite - 正在检测' } else { 'IPQuality Full - 正在检测' }
    }
    catch {
    }
}

if ($IPv4 -and -not $IPv6) {
    $families = @(4)
}
elseif ($IPv6 -and -not $IPv4) {
    $families = @(6)
}
else {
    $families = @(4, 6)
}

try {
    $results = @(Invoke-IPQualityCheck `
        -AddressFamily $families `
        -Proxy $Proxy `
        -Interface $Interface `
        -Language $Language `
        -FullIP:$FullIP `
        -Lite:$Lite `
        -SkipRisk:$NoRisk `
        -SkipMedia:$NoMedia `
        -SkipMail:$NoMail `
        -SkipDnsbl:$NoDnsbl `
        -TimeoutSeconds $TimeoutSeconds `
        -DnsblConcurrency $DnsblConcurrency -WarningAction $(if ($Json) { 'SilentlyContinue' } else { 'Continue' }) 6>$null)

    if ($results.Count -eq 0) {
        throw '没有发现可用的 IPv4 或 IPv6 出口。请检查网络、代理地址或协议选项。'
    }

    if ($AllowOnlineReport) {
        foreach ($result in $results) {
            try {
                $link = Publish-IPQualityReport -Result $result -Proxy $Proxy -Interface $Interface -TimeoutSeconds $TimeoutSeconds
                $result.Head | Add-Member -NotePropertyName ReportLink -NotePropertyValue $link
            } catch {
                $result.Warnings += "Online report: $($_.Exception.Message)"
                if ($Json) { [Console]::Error.WriteLine($result.Warnings[-1]) } else { Write-Warning $result.Warnings[-1] }
            }
        }
    }
    if ($CountRun) {
        foreach ($result in $results) {
            $counter = & (Get-Module IPQuality) {
                param($family,$proxy,$interface,$timeout)
                $context = New-IPQContext -AddressFamily $family -Proxy $proxy -Interface $interface -TimeoutSeconds $timeout
                $response = Invoke-IPQRequest -Context $context -Uri 'https://hits.xykt.de/ip?action=hit'
                ConvertFrom-IPQJson $response.Body
            } $(if ($result.Head.AddressFamily -eq 'IPv6') { 6 } else { 4 }) $Proxy $Interface $TimeoutSeconds
            $result.Head | Add-Member RunCounter $counter
        }
    }
    $outputResults = if ($UpstreamJson) { @($results | ForEach-Object { ConvertTo-IPQualityUpstreamReport $_ }) } else { $results }
    if ($Json) {
        $rendered = if (@($outputResults).Count -eq 1) {
            @($outputResults)[0] | ConvertTo-Json -Depth 16
        }
        else {
            $outputResults | ConvertTo-Json -Depth 16
        }
        $rendered
    }
    else {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
            Clear-Host
        }
        foreach ($result in $results) {
            Format-IPQualityReport -Result $result
        }
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
            try {
                $Host.UI.RawUI.WindowTitle = if ($Lite) { 'IPQuality Lite - 检测结果' } else { 'IPQuality Full - 检测结果' }
            }
            catch {
            }
        }
    }

    if ($Output) {
        if ($UpstreamJson -and [IO.Path]::GetExtension($Output) -ieq '.json') {
            $target = [IO.Path]::GetFullPath($Output)
            if ((Test-Path -LiteralPath $target) -and -not $Force) { throw "文件已存在：$target" }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            [IO.File]::WriteAllText($target, $rendered, [Text.UTF8Encoding]::new($false))
        } else {
            Export-IPQualityReport -Result $results -Path $Output -Force:$Force
        }
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
            try {
                $Host.UI.RawUI.WindowTitle = if ($Lite) {
                    'IPQuality Lite - 检测结果（已保存）'
                }
                else {
                    'IPQuality Full - 检测结果（已保存）'
                }
            }
            catch {
            }
        }
    }
    Set-IPQConsoleLayout
}
catch {
    throw
}
