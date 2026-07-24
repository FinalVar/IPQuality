#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$TargetProcessId,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('IPQuality.ConsoleInspection' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace IPQuality {
    public static class ConsoleInspection {
        [StructLayout(LayoutKind.Sequential)]
        public struct Coord {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SmallRect {
            public short Left;
            public short Top;
            public short Right;
            public short Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ScreenBufferInfo {
            public Coord Size;
            public Coord CursorPosition;
            public short Attributes;
            public SmallRect Window;
            public Coord MaximumWindowSize;
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
        public static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AttachConsole(uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleScreenBufferInfo(
            IntPtr output,
            out ScreenBufferInfo info
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool ReadConsoleOutputCharacter(
            IntPtr output,
            StringBuilder characters,
            uint length,
            Coord readCoordinate,
            out uint charactersRead
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool GetCurrentConsoleFontEx(
            IntPtr output,
            bool maximumWindow,
            ref FontInfo info
        );
    }
}
'@
}

[IPQuality.ConsoleInspection]::FreeConsole() | Out-Null
if (-not [IPQuality.ConsoleInspection]::AttachConsole([uint32]$TargetProcessId)) {
    throw "无法附加目标控制台，Win32 错误：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$outputHandle = [IPQuality.ConsoleInspection]::CreateFile(
    'CONOUT$',
    [uint32]3221225472,
    [uint32]3,
    [IntPtr]::Zero,
    [uint32]3,
    [uint32]0,
    [IntPtr]::Zero
)
if ($outputHandle -eq [IntPtr](-1)) {
    throw "无法打开目标控制台输出，Win32 错误：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
$screen = [IPQuality.ConsoleInspection+ScreenBufferInfo]::new()
if (-not [IPQuality.ConsoleInspection]::GetConsoleScreenBufferInfo($outputHandle, [ref]$screen)) {
    throw "无法读取控制台缓冲区，Win32 错误：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
$font = [IPQuality.ConsoleInspection+FontInfo]::new()
$font.Size = [uint32][Runtime.InteropServices.Marshal]::SizeOf(
    $font
)
if (-not [IPQuality.ConsoleInspection]::GetCurrentConsoleFontEx($outputHandle, $false, [ref]$font)) {
    throw "无法读取控制台字体，Win32 错误：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$windowWidth = [int]$screen.Window.Right - [int]$screen.Window.Left + 1
$windowHeight = [int]$screen.Window.Bottom - [int]$screen.Window.Top + 1
$visibleLines = [Collections.Generic.List[string]]::new()
for ($row = [int]$screen.Window.Top; $row -le [int]$screen.Window.Bottom; $row++) {
    $characters = [Text.StringBuilder]::new([int]$screen.Size.X)
    $readCoordinate = [IPQuality.ConsoleInspection+Coord]::new()
    $readCoordinate.X = 0
    $readCoordinate.Y = [int16]$row
    $charactersRead = [uint32]0
    if (
        [IPQuality.ConsoleInspection]::ReadConsoleOutputCharacter(
            $outputHandle,
            $characters,
            [uint32]$screen.Size.X,
            $readCoordinate,
            [ref]$charactersRead
        )
    ) {
        $visibleLines.Add($characters.ToString().TrimEnd())
    }
}
$state = [pscustomobject][ordered]@{
    ProcessId = $TargetProcessId
    WindowWidth = $windowWidth
    WindowHeight = $windowHeight
    BufferWidth = [int]$screen.Size.X
    BufferHeight = [int]$screen.Size.Y
    HorizontalScrollbar = [int]$screen.Size.X -gt $windowWidth
    VerticalScrollbar = [int]$screen.Size.Y -gt $windowHeight
    FontFace = $font.FaceName
    FontHeight = [int]$font.FontSize.Y
    VisibleLines = $visibleLines.ToArray()
}

[IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($OutputPath),
    ($state | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false)
)
[IPQuality.ConsoleInspection]::CloseHandle($outputHandle) | Out-Null
[IPQuality.ConsoleInspection]::FreeConsole() | Out-Null
