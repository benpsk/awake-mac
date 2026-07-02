# awake.ps1 - Windows app-control experiment
#
# Windows sibling to awake.sh:
#   - Randomly rotates focus across visible windows every 30-60s
#   - Prevents normal system/display sleep while running
#   - In ENABLE_ALL=true mode, moves the mouse with SendInput each tick
#
# Stop with Ctrl+C.

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Config - tune with environment variables
# ---------------------------------------------------------------------------
function Get-EnvInt {
    param(
        [string]$Name,
        [int]$Default
    )
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-EnvBool {
    param(
        [string]$Name,
        [bool]$Default
    )
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw -match '^(1|true|yes|on)$'
}

$script:MIN_SLEEP = Get-EnvInt "MIN_SLEEP" 30
$script:MAX_SLEEP = Get-EnvInt "MAX_SLEEP" 60
$script:ENABLE_ALL = Get-EnvBool "ENABLE_ALL" $false
$script:MOUSE_JIGGLE_PX = Get-EnvInt "MOUSE_JIGGLE_PX" 1
$script:LOG_FILE = [Environment]::GetEnvironmentVariable("AWAKE_LOG_FILE")
$script:EXCLUDE_APPS = @("powershell", "pwsh", "cmd", "WindowsTerminal", "conhost")

$extraExcludes = [Environment]::GetEnvironmentVariable("AWAKE_EXCLUDE_APPS")
if (-not [string]::IsNullOrWhiteSpace($extraExcludes)) {
    foreach ($item in $extraExcludes -split ',') {
        $trimmed = $item.Trim()
        if ($trimmed.Length -gt 0) { $script:EXCLUDE_APPS += $trimmed }
    }
}

if ($script:MAX_SLEEP -lt $script:MIN_SLEEP) {
    $tmp = $script:MIN_SLEEP
    $script:MIN_SLEEP = $script:MAX_SLEEP
    $script:MAX_SLEEP = $tmp
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-AwakeLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($script:LOG_FILE)) {
        Add-Content -Path $script:LOG_FILE -Value $line
    }
}

# ---------------------------------------------------------------------------
# Win32 helpers
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class AwakeWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    public class WindowInfo
    {
        public IntPtr Handle;
        public string Title;
        public string ProcessName;
        public int ProcessId;
        public bool Minimized;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    private const int SW_RESTORE = 9;
    private const uint INPUT_MOUSE = 0;
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    public static WindowInfo[] GetVisibleWindows()
    {
        List<WindowInfo> windows = new List<WindowInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            int length = GetWindowTextLength(hWnd);
            if (length <= 0) return true;

            StringBuilder titleBuilder = new StringBuilder(length + 1);
            GetWindowText(hWnd, titleBuilder, titleBuilder.Capacity);
            string title = titleBuilder.ToString().Trim();
            if (title.Length == 0) return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            string processName = "";
            try
            {
                processName = Process.GetProcessById((int)pid).ProcessName;
            }
            catch
            {
                return true;
            }

            windows.Add(new WindowInfo {
                Handle = hWnd,
                Title = title,
                ProcessName = processName,
                ProcessId = (int)pid,
                Minimized = IsIconic(hWnd)
            });
            return true;
        }, IntPtr.Zero);

        return windows.ToArray();
    }

    public static bool FocusWindow(IntPtr hWnd)
    {
        ShowWindow(hWnd, SW_RESTORE);
        return SetForegroundWindow(hWnd);
    }

    public static bool GetCursor(out POINT point)
    {
        return GetCursorPos(out point);
    }

    public static RECT GetVirtualScreen()
    {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        return new RECT { Left = x, Top = y, Right = x + w, Bottom = y + h };
    }

    public static bool MoveMouseRelative(int dx, int dy)
    {
        INPUT[] input = new INPUT[1];
        input[0].type = INPUT_MOUSE;
        input[0].mi.dx = dx;
        input[0].mi.dy = dy;
        input[0].mi.dwFlags = MOUSEEVENTF_MOVE;
        return SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static bool MoveMouseAbsolute(int x, int y)
    {
        RECT screen = GetVirtualScreen();
        int width = Math.Max(1, screen.Right - screen.Left - 1);
        int height = Math.Max(1, screen.Bottom - screen.Top - 1);
        int absoluteX = (int)Math.Round(((double)(x - screen.Left) * 65535.0) / width);
        int absoluteY = (int)Math.Round(((double)(y - screen.Top) * 65535.0) / height);

        INPUT[] input = new INPUT[1];
        input[0].type = INPUT_MOUSE;
        input[0].mi.dx = absoluteX;
        input[0].mi.dy = absoluteY;
        input[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        return SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) == 1;
    }
}
"@

function Enable-AwakeExecutionState {
    [void][AwakeWin32]::SetThreadExecutionState(
        [AwakeWin32]::ES_CONTINUOUS -bor
        [AwakeWin32]::ES_SYSTEM_REQUIRED -bor
        [AwakeWin32]::ES_DISPLAY_REQUIRED
    )
}

function Clear-AwakeExecutionState {
    [void][AwakeWin32]::SetThreadExecutionState([AwakeWin32]::ES_CONTINUOUS)
}

function Test-ExcludedWindow {
    param($Window)
    foreach ($excluded in $script:EXCLUDE_APPS) {
        if ($Window.ProcessName -ieq $excluded) { return $true }
        if ($Window.Title -ieq $excluded) { return $true }
    }
    return $false
}

function Get-AwakeWindows {
    $windows = [AwakeWin32]::GetVisibleWindows()
    $filtered = @()
    foreach ($window in $windows) {
        if (Test-ExcludedWindow $window) { continue }
        $filtered += $window
    }
    return $filtered
}

function Invoke-RandomWindowFocus {
    $windows = @(Get-AwakeWindows)
    if ($windows.Count -eq 0) {
        Write-AwakeLog "no visible windows found after excludes"
        return
    }

    $window = $windows | Get-Random
    $ok = [AwakeWin32]::FocusWindow($window.Handle)
    if ($ok) {
        Write-AwakeLog ("action: focus -> {0} | {1}" -f $window.ProcessName, $window.Title)
    } else {
        Write-AwakeLog ("action: focus attempted -> {0} | {1} (Windows may deny foreground steal)" -f $window.ProcessName, $window.Title)
    }
}

function Invoke-MouseJiggle {
    $point = New-Object AwakeWin32+POINT
    if (-not [AwakeWin32]::GetCursor([ref]$point)) {
        Write-AwakeLog "mouse-jiggle: could not read cursor position"
        return $false
    }

    $px = [Math]::Max(1, $script:MOUSE_JIGGLE_PX)
    $ok1 = [AwakeWin32]::MoveMouseRelative($px, 0)
    Start-Sleep -Milliseconds 40
    $ok2 = [AwakeWin32]::MoveMouseRelative(-$px, 0)
    if ($ok1 -and $ok2) {
        Write-AwakeLog ("mouse-jiggle: {0},{1} -> +{2}px -> restored (SendInput)" -f $point.X, $point.Y, $px)
        return $true
    }

    Write-AwakeLog "mouse-jiggle: SendInput move failed"
    return $false
}

function Invoke-RandomMouseMove {
    $screen = [AwakeWin32]::GetVirtualScreen()
    $width = $screen.Right - $screen.Left
    $height = $screen.Bottom - $screen.Top
    if ($width -le 0 -or $height -le 0) {
        Write-AwakeLog "mouse-move: could not read virtual screen bounds; jiggling instead"
        return (Invoke-MouseJiggle)
    }

    $x = Get-Random -Minimum $screen.Left -Maximum $screen.Right
    $y = Get-Random -Minimum $screen.Top -Maximum $screen.Bottom
    if ([AwakeWin32]::MoveMouseAbsolute($x, $y)) {
        Write-AwakeLog ("mouse-move: cursor -> {0},{1} (SendInput; idle reset)" -f $x, $y)
        return $true
    }

    Write-AwakeLog "mouse-move: SendInput absolute move failed; jiggling instead"
    return (Invoke-MouseJiggle)
}

function Invoke-ActiveMouse {
    if (-not $script:ENABLE_ALL) { return }
    [void](Invoke-RandomMouseMove)
}

function Sleep-Random {
    $seconds = Get-Random -Minimum $script:MIN_SLEEP -Maximum ($script:MAX_SLEEP + 1)
    Write-AwakeLog "sleeping ${seconds}s"
    Start-Sleep -Seconds $seconds
}

function Show-Probe {
    Enable-AwakeExecutionState
    Write-AwakeLog "=== awake Windows capability probe ==="
    Write-Host ("{0,-20} {1,-6} {2}" -f "PROCESS", "PID", "TITLE")
    Write-Host ("{0,-20} {1,-6} {2}" -f "---", "---", "---")
    foreach ($window in @(Get-AwakeWindows)) {
        Write-Host ("{0,-20} {1,-6} {2}" -f $window.ProcessName, $window.ProcessId, $window.Title)
    }
    Write-Host ""
    Write-AwakeLog "Win32: SetThreadExecutionState available; SendInput available; SetForegroundWindow available."
    Clear-AwakeExecutionState
}

function Invoke-JiggleTest {
    Enable-AwakeExecutionState
    Write-AwakeLog "=== mouse-jiggle test ==="
    Write-AwakeLog "Do not touch the mouse/keyboard during the short test."
    Start-Sleep -Seconds 1
    if (Invoke-MouseJiggle) {
        Write-AwakeLog "RESULT: SendInput mouse movement succeeded."
        Clear-AwakeExecutionState
        exit 0
    }

    Write-AwakeLog "RESULT: SendInput mouse movement failed."
    Clear-AwakeExecutionState
    exit 1
}

function Invoke-RunLoop {
    Write-AwakeLog "awake started (pid $PID). Ctrl+C to stop."
    Write-AwakeLog ("sleep {0}-{1}s | active-mode (ENABLE_ALL) {2}" -f $script:MIN_SLEEP, $script:MAX_SLEEP, $script:ENABLE_ALL)
    Write-AwakeLog ("excluding apps/windows: {0}" -f ($script:EXCLUDE_APPS -join ", "))

    try {
        Enable-AwakeExecutionState
        while ($true) {
            Enable-AwakeExecutionState
            Invoke-RandomWindowFocus
            Invoke-ActiveMouse
            Sleep-Random
        }
    }
    finally {
        Clear-AwakeExecutionState
        Write-AwakeLog "awake stopped."
    }
}

function Show-Usage {
@"
awake.ps1 - Windows app-control experiment

USAGE:
  powershell -ExecutionPolicy Bypass -File .\awake.ps1
  powershell -ExecutionPolicy Bypass -File .\awake.ps1 --probe
  powershell -ExecutionPolicy Bypass -File .\awake.ps1 --jiggle-test
  powershell -ExecutionPolicy Bypass -File .\awake.ps1 --help

TUNABLES (environment variables):
  MIN_SLEEP / MAX_SLEEP   random wait per action (default 30-60s)
  ENABLE_ALL              true = move mouse with SendInput each tick (default false)
  MOUSE_JIGGLE_PX         nudge size for --jiggle-test (default 1)
  AWAKE_EXCLUDE_APPS      comma-separated process/window names to skip
  AWAKE_LOG_FILE          also append logs to this file

EXAMPLES:
  `$env:ENABLE_ALL="true"; powershell -ExecutionPolicy Bypass -File .\awake.ps1
  `$env:MIN_SLEEP="3"; `$env:MAX_SLEEP="6"; powershell -ExecutionPolicy Bypass -File .\awake.ps1

NOTES:
  Windows uses Win32 SendInput for mouse activity; no extra install is required.
  The script prevents normal display/system sleep while it is running.
"@
}

$command = ""
if ($args.Count -gt 0) {
    $command = $args[0]
}

switch ($command) {
    "--probe" { Show-Probe }
    "--jiggle-test" { Invoke-JiggleTest }
    "--help" { Show-Usage }
    "-h" { Show-Usage }
    "" { Invoke-RunLoop }
    default {
        Show-Usage
        exit 2
    }
}
