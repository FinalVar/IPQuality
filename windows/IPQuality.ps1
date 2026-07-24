#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$IPv4,
    [switch]$IPv6,
    [string]$Proxy,
    [string]$Interface,
    [switch]$FullIP,
    [switch]$Json,
    [string]$Output,
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
        -FullIP:$FullIP `
        -Lite:$Lite `
        -SkipRisk:$NoRisk `
        -SkipMedia:$NoMedia `
        -SkipMail:$NoMail `
        -SkipDnsbl:$NoDnsbl `
        -TimeoutSeconds $TimeoutSeconds `
        -DnsblConcurrency $DnsblConcurrency)

    if ($results.Count -eq 0) {
        throw '没有发现可用的 IPv4 或 IPv6 出口。请检查网络、代理地址或协议选项。'
    }

    if ($Json) {
        $rendered = if ($results.Count -eq 1) {
            $results[0] | ConvertTo-Json -Depth 12
        }
        else {
            $results | ConvertTo-Json -Depth 12
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
        Export-IPQualityReport -Result $results -Path $Output -Force:$Force
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
