# awake.ps1 - Windows app-control experiment
#
# Windows sibling to awake.sh:
#   - Randomly rotates focus across visible windows every 30-60s
#   - Maximizes one window or tiles two windows on the primary work area
#   - Prevents normal system/display sleep while running
#   - In ENABLE_ALL=true mode, drives safe app shortcuts and mouse movement
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
$script:TILE_PROBABILITY = Get-EnvInt "TILE_PROBABILITY" 25
$script:ENABLE_ALL = Get-EnvBool "ENABLE_ALL" $false
$script:VSCODE_OPEN_FILE_PROBABILITY = Get-EnvInt "VSCODE_OPEN_FILE_PROBABILITY" 30
$script:VSCODE_RANDOM_FILE_CYCLE_SIZE = Get-EnvInt "VSCODE_RANDOM_FILE_CYCLE_SIZE" 20
$script:MOUSE_JIGGLE_PX = Get-EnvInt "MOUSE_JIGGLE_PX" 1
$script:LOG_FILE = [Environment]::GetEnvironmentVariable("AWAKE_LOG_FILE")
$script:EXCLUDE_APPS = @("Program Manager", "Microsoft Text Input Application", "TextInputHost")

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
$script:TILE_PROBABILITY = [Math]::Max(0, [Math]::Min(100, $script:TILE_PROBABILITY))
$script:VSCODE_OPEN_FILE_PROBABILITY = [Math]::Max(0, [Math]::Min(100, $script:VSCODE_OPEN_FILE_PROBABILITY))
$script:VSCODE_RANDOM_FILE_CYCLE_SIZE = [Math]::Max(1, $script:VSCODE_RANDOM_FILE_CYCLE_SIZE)
$script:VSCODE_FILE_CYCLES = @{}

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
        public INPUTUNION data;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
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

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
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
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

    [DllImport("user32.dll")]
    private static extern bool SystemParametersInfo(uint action, uint param, out RECT rect, uint update);

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
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint SPI_GETWORKAREA = 0x0030;
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

    public static bool IsForegroundWindow(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero && GetForegroundWindow() == hWnd;
    }

    public static bool SetWindowBounds(IntPtr hWnd, int x, int y, int width, int height)
    {
        ShowWindow(hWnd, SW_RESTORE);
        return MoveWindow(hWnd, x, y, Math.Max(1, width), Math.Max(1, height), true);
    }

    public static RECT GetPrimaryWorkArea()
    {
        RECT area;
        if (SystemParametersInfo(SPI_GETWORKAREA, 0, out area, 0)) return area;
        return new RECT { Left = 0, Top = 0, Right = GetSystemMetrics(0), Bottom = GetSystemMetrics(1) };
    }

    public static bool SendKey(ushort key)
    {
        INPUT[] input = new INPUT[2];
        input[0].type = 1;
        input[0].data.ki.wVk = key;
        input[1].type = 1;
        input[1].data.ki.wVk = key;
        input[1].data.ki.dwFlags = KEYEVENTF_KEYUP;
        return SendInput(2, input, Marshal.SizeOf(typeof(INPUT))) == 2;
    }

    public static bool SendKeyChord(ushort modifier, ushort key)
    {
        INPUT[] input = new INPUT[4];
        input[0].type = 1; input[0].data.ki.wVk = modifier;
        input[1].type = 1; input[1].data.ki.wVk = key;
        input[2].type = 1; input[2].data.ki.wVk = key; input[2].data.ki.dwFlags = KEYEVENTF_KEYUP;
        input[3].type = 1; input[3].data.ki.wVk = modifier; input[3].data.ki.dwFlags = KEYEVENTF_KEYUP;
        return SendInput(4, input, Marshal.SizeOf(typeof(INPUT))) == 4;
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
        input[0].data.mi.dx = dx;
        input[0].data.mi.dy = dy;
        input[0].data.mi.dwFlags = MOUSEEVENTF_MOVE;
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
        input[0].data.mi.dx = absoluteX;
        input[0].data.mi.dy = absoluteY;
        input[0].data.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        return SendInput(1, input, Marshal.SizeOf(typeof(INPUT))) == 1;
    }
}
"@

# Capture the launching terminal only when the foreground handle actually belongs
# to a terminal (or this PowerShell process). This avoids protecting an unrelated
# app when the script is started by a scheduler or background launcher.
$runnerCandidate = [AwakeWin32]::GetForegroundWindow()
$runnerInfo = @([AwakeWin32]::GetVisibleWindows() | Where-Object { $_.Handle -eq $runnerCandidate })
$script:RUNNER_WINDOW_HANDLE = [IntPtr]::Zero
if ($runnerInfo.Count -gt 0 -and
    ($runnerInfo[0].ProcessId -eq $PID -or
     $runnerInfo[0].ProcessName -imatch '^(cmd|powershell|pwsh|WindowsTerminal|conhost)$')) {
    $script:RUNNER_WINDOW_HANDLE = $runnerCandidate
}
$script:RUNNER_PROCESS_ID = $PID

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
    if ($Window.ProcessId -eq $script:RUNNER_PROCESS_ID) { return $true }
    if ($script:RUNNER_WINDOW_HANDLE -ne [IntPtr]::Zero -and
        $Window.Handle -eq $script:RUNNER_WINDOW_HANDLE) { return $true }
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

function Set-AwakeForeground {
    param($Window)
    [void][AwakeWin32]::FocusWindow($Window.Handle)
    Start-Sleep -Milliseconds 150
    return [AwakeWin32]::IsForegroundWindow($Window.Handle)
}

function Set-AwakeWindowBounds {
    param($Window, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    $ok = [AwakeWin32]::SetWindowBounds($Window.Handle, $X, $Y, $Width, $Height)
    if (-not $ok) {
        Write-AwakeLog ("  {0}: geometry set failed" -f $Window.ProcessName)
    }
    return $ok
}

function Invoke-MaximizeWindow {
    param($Window)
    $area = [AwakeWin32]::GetPrimaryWorkArea()
    [void](Set-AwakeWindowBounds $Window $area.Left $area.Top ($area.Right - $area.Left) ($area.Bottom - $area.Top))
    $focused = Set-AwakeForeground $Window
    Write-AwakeLog ("action: full window -> {0} | {1}" -f $Window.ProcessName, $Window.Title)
    if (-not $focused) {
        Write-AwakeLog "  foreground confirmation failed; active shortcuts skipped"
    }
    return $focused
}

function Invoke-TileWindows {
    param($LeftWindow, $RightWindow)
    $area = [AwakeWin32]::GetPrimaryWorkArea()
    $width = $area.Right - $area.Left
    $height = $area.Bottom - $area.Top
    $leftWidth = [Math]::Floor($width / 2)
    [void](Set-AwakeWindowBounds $LeftWindow $area.Left $area.Top $leftWidth $height)
    [void](Set-AwakeWindowBounds $RightWindow ($area.Left + $leftWidth) $area.Top ($width - $leftWidth) $height)
    [void](Set-AwakeForeground $LeftWindow)
    Write-AwakeLog ("action: tile -> {0} (left) | {1} (right)" -f $LeftWindow.ProcessName, $RightWindow.ProcessName)
}

function Test-TerminalWindow {
    param($Window)
    return $Window.ProcessName -imatch '^(cmd|powershell|pwsh|WindowsTerminal|conhost)$'
}

function Test-TargetForeground {
    param($Window)
    if ([AwakeWin32]::IsForegroundWindow($Window.Handle)) { return $true }
    Write-AwakeLog ("  {0}: foreground changed; shortcut skipped" -f $Window.ProcessName)
    return $false
}

function Send-AwakeKey {
    param($Window, [int]$Key, [string]$Label)
    if (-not (Test-TargetForeground $Window)) { return $false }
    $ok = [AwakeWin32]::SendKey([uint16]$Key)
    if ($ok) { Write-AwakeLog ("  {0}: {1} (synthetic)" -f $Window.ProcessName, $Label) }
    else { Write-AwakeLog ("  {0}: {1} failed" -f $Window.ProcessName, $Label) }
    return $ok
}

function Send-AwakeChord {
    param($Window, [int]$Modifier, [int]$Key, [string]$Label)
    if (-not (Test-TargetForeground $Window)) { return $false }
    $ok = [AwakeWin32]::SendKeyChord([uint16]$Modifier, [uint16]$Key)
    if ($ok) { Write-AwakeLog ("  {0}: {1} (synthetic)" -f $Window.ProcessName, $Label) }
    else { Write-AwakeLog ("  {0}: {1} failed" -f $Window.ProcessName, $Label) }
    return $ok
}

function Invoke-RandomScroll {
    param($Window)
    if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) {
        [void](Send-AwakeKey $Window 0x22 "scrolled PageDown")
    } else {
        [void](Send-AwakeKey $Window 0x21 "scrolled PageUp")
    }
}

function ConvertFrom-VSCodeFileUri {
    param([string]$UriText)
    try {
        $uri = [Uri]$UriText
        if (-not $uri.IsFile) { return $null }
        if (-not [string]::IsNullOrWhiteSpace($uri.Host)) {
            $uncPath = "\\{0}{1}" -f $uri.Host, ([Uri]::UnescapeDataString($uri.AbsolutePath).Replace('/', '\'))
            return [IO.Path]::GetFullPath($uncPath)
        }
        $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
        if ($path -match '^/[A-Za-z]:/') { $path = $path.Substring(1) }
        $path = $path.Replace('/', [IO.Path]::DirectorySeparatorChar)
        return [IO.Path]::GetFullPath($path)
    } catch {
        return $null
    }
}

function Get-VSCodeWorkspaceCatalog {
    $storageRoot = Join-Path $env:APPDATA "Code\User\workspaceStorage"
    if (-not (Test-Path -LiteralPath $storageRoot)) { return @() }

    $catalog = @()
    $metadataFiles = @(Get-ChildItem -LiteralPath $storageRoot -Filter "workspace.json" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($metadataFile in $metadataFiles) {
        try {
            $metadata = Get-Content -LiteralPath $metadataFile.FullName -Raw | ConvertFrom-Json
        } catch { continue }

        $roots = @()
        $label = ""
        if ($metadata.folder) {
            $folder = ConvertFrom-VSCodeFileUri ([string]$metadata.folder)
            if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
                $roots = @($folder)
                $label = Split-Path -Leaf $folder
            }
        } elseif ($metadata.workspace) {
            $workspaceFile = ConvertFrom-VSCodeFileUri ([string]$metadata.workspace)
            if (-not $workspaceFile -or -not (Test-Path -LiteralPath $workspaceFile -PathType Leaf)) { continue }
            $label = [IO.Path]::GetFileNameWithoutExtension($workspaceFile)
            try {
                $workspaceText = Get-Content -LiteralPath $workspaceFile -Raw
                $workspaceText = [regex]::Replace($workspaceText, '(?s)/\*.*?\*/', '')
                $workspaceText = [regex]::Replace($workspaceText, '(?m)^\s*//.*$', '')
                $workspace = $workspaceText | ConvertFrom-Json
                foreach ($folderEntry in @($workspace.folders)) {
                    if ($folderEntry.path) {
                        $candidate = [string]$folderEntry.path
                        if (-not [IO.Path]::IsPathRooted($candidate)) {
                            $candidate = Join-Path (Split-Path -Parent $workspaceFile) $candidate
                        }
                        $candidate = [IO.Path]::GetFullPath($candidate)
                        if (Test-Path -LiteralPath $candidate -PathType Container) { $roots += $candidate }
                    } elseif ($folderEntry.uri) {
                        $candidate = ConvertFrom-VSCodeFileUri ([string]$folderEntry.uri)
                        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { $roots += $candidate }
                    }
                }
            } catch { continue }
        }

        $roots = @($roots | Select-Object -Unique)
        if ($roots.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($label)) {
            $catalog += [PSCustomObject]@{ Label = $label; Roots = $roots; MetadataPath = $metadataFile.FullName }
        }
    }
    return $catalog
}

function Resolve-VSCodeWorkspace {
    param($Window)
    $catalog = @(Get-VSCodeWorkspaceCatalog)
    $matches = @($catalog | Where-Object {
        $Window.Title -match ("(?i)(^| - ){0}( - Visual Studio Code)?$" -f [regex]::Escape($_.Label))
    })
    if ($matches.Count -eq 0) {
        Write-AwakeLog ("  Code: no local workspace metadata matched window '{0}'" -f $Window.Title)
        return $null
    }
    if ($matches.Count -gt 1) {
        Write-AwakeLog ("  Code: multiple workspace records matched '{0}'; using most recent" -f $matches[0].Label)
    }
    return $matches[0]
}

function Test-VSCodeEligibleFile {
    param([string]$Path)
    $excludedDirectoryPattern = '[\\/](\.git|\.svn|\.hg|node_modules|vendor|dist|build|out|target|coverage|\.next|\.nuxt|\.cache|tmp|temp)[\\/]'
    if ($Path -match $excludedDirectoryPattern) { return $false }

    $fileName = [IO.Path]::GetFileName($Path)
    $extension = [IO.Path]::GetExtension($Path)
    $allowedNames = @('Dockerfile', 'Makefile', 'Rakefile', 'Gemfile', 'Procfile', '.gitignore', '.gitattributes', '.editorconfig', '.env.example')
    $allowedExtensions = @(
        '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.fish', '.cmd', '.bat',
        '.py', '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx', '.java', '.kt', '.kts',
        '.cs', '.fs', '.fsx', '.go', '.rs', '.c', '.cc', '.cpp', '.cxx', '.h', '.hpp',
        '.php', '.rb', '.swift', '.scala', '.lua', '.r', '.sql', '.graphql', '.gql',
        '.html', '.htm', '.css', '.scss', '.sass', '.less', '.vue', '.svelte',
        '.xml', '.json', '.jsonc', '.yaml', '.yml', '.toml', '.ini', '.conf', '.config',
        '.properties', '.md', '.markdown', '.txt', '.rst'
    )
    return ($allowedNames -contains $fileName) -or ($allowedExtensions -contains $extension)
}

function Get-FallbackWorkspaceFiles {
    param([string]$Root)
    $files = @()
    $pending = New-Object System.Collections.Stack
    $pending.Push((Get-Item -LiteralPath $Root))
    $excludedNames = @('.git', '.svn', '.hg', 'node_modules', 'vendor', 'dist', 'build', 'out', 'target', 'coverage', '.next', '.nuxt', '.cache', 'tmp', 'temp')
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -ErrorAction SilentlyContinue)) {
            if (Test-VSCodeEligibleFile $file.FullName) { $files += $file.FullName }
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($excludedNames -notcontains $child.Name) { $pending.Push($child) }
        }
    }
    return $files
}

function Get-VSCodeWorkspaceFiles {
    param($Workspace)
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($Workspace.Roots)) {
        $gitRoot = & git -C $root rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            foreach ($relativePath in @(& git -C $root ls-files --cached -- . 2>$null)) {
                $path = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Test-VSCodeEligibleFile $path)) {
                    [void]$unique.Add($path)
                }
            }
        } else {
            foreach ($path in @(Get-FallbackWorkspaceFiles $root)) { [void]$unique.Add($path) }
        }
    }
    return @($unique)
}

function New-VSCodeFileCycle {
    param($Workspace, [string]$Key, [int]$PreviousCycle)
    $files = @(Get-VSCodeWorkspaceFiles $Workspace)
    if ($files.Count -eq 0) { return $null }
    $take = [Math]::Min($script:VSCODE_RANDOM_FILE_CYCLE_SIZE, $files.Count)
    $queue = @($files | Get-Random -Count $take)
    $state = [PSCustomObject]@{ Queue = $queue; Index = 0; Cycle = ($PreviousCycle + 1); Workspace = $Workspace }
    $script:VSCODE_FILE_CYCLES[$Key] = $state
    Write-AwakeLog ("  Code: workspace {0} cycle {1} reset ({2} unique files)" -f $Workspace.Label, $state.Cycle, $queue.Count)
    return $state
}

function Invoke-VSCodeRandomFile {
    param($Window)
    if ((Get-Random -Minimum 0 -Maximum 100) -ge $script:VSCODE_OPEN_FILE_PROBABILITY) { return }
    if (-not (Test-TargetForeground $Window)) { return }

    $cli = Get-Command code -ErrorAction SilentlyContinue
    if (-not $cli) {
        Write-AwakeLog "  Code: random workspace file skipped (code CLI not found)"
        return
    }
    $workspace = Resolve-VSCodeWorkspace $Window
    if (-not $workspace) { return }
    $key = (@($workspace.Roots | ForEach-Object { [IO.Path]::GetFullPath($_).ToLowerInvariant() }) -join '|')
    $state = $script:VSCODE_FILE_CYCLES[$key]
    if (-not $state -or $state.Index -ge $state.Queue.Count) {
        $previousCycle = if ($state) { $state.Cycle } else { 0 }
        $state = New-VSCodeFileCycle $workspace $key $previousCycle
        if (-not $state) {
            Write-AwakeLog ("  Code: no eligible code/text files in workspace {0}" -f $workspace.Label)
            return
        }
    }

    while ($state.Index -lt $state.Queue.Count) {
        $path = [string]$state.Queue[$state.Index]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $state.Index++
            continue
        }
        if (-not (Test-TargetForeground $Window)) { return }
        try {
            $quotedPath = '"{0}"' -f $path.Replace('"', '\"')
            $helper = Start-Process -FilePath $cli.Source -ArgumentList @('--reuse-window', $quotedPath) -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            $helper = $null
        }
        if ($helper) {
            $state.Index++
            $root = @($workspace.Roots | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Length -Descending)[0]
            $relative = if ($root) { $path.Substring($root.Length).TrimStart('\', '/') } else { [IO.Path]::GetFileName($path) }
            Write-AwakeLog ("  Code: opened {0} (cycle {1}, {2}/{3}, unique)" -f $relative, $state.Cycle, $state.Index, $state.Queue.Count)
        } else {
            Write-AwakeLog ("  Code: CLI failed to open {0}" -f $path)
        }
        return
    }
}

function Invoke-DeepWindowAction {
    param($Window)
    if (-not $script:ENABLE_ALL) { return }
    if (Test-TerminalWindow $Window) {
        Write-AwakeLog ("  {0}: terminal focus only; shortcuts disabled" -f $Window.ProcessName)
        return
    }

    switch -Regex ($Window.ProcessName) {
        '^chrome$' {
            [void](Send-AwakeChord $Window 0x11 0x09 "cycled browser tab with Ctrl+Tab")
            Invoke-RandomScroll $Window
            break
        }
        '^Postman$' {
            [void](Send-AwakeChord $Window 0x11 0x09 "cycled request tab with Ctrl+Tab")
            Invoke-RandomScroll $Window
            break
        }
        '^Code$' {
            [void](Send-AwakeChord $Window 0x11 0x22 "cycled editor with Ctrl+PageDown")
            Invoke-RandomScroll $Window
            Invoke-VSCodeRandomFile $Window
            break
        }
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
    Write-Host ("{0,-20} {1,-6} {2,-10} {3,-25} {4}" -f "PROCESS", "PID", "BEHAVIOR", "DETAIL", "TITLE")
    Write-Host ("{0,-20} {1,-6} {2,-10} {3,-25} {4}" -f "---", "---", "---", "---", "---")
    foreach ($window in @(Get-AwakeWindows)) {
        $behavior = "window"
        $detail = "-"
        if (Test-TerminalWindow $window) { $behavior = "focus-only" }
        elseif ($window.ProcessName -imatch '^(chrome|Postman|Code)$') {
            $behavior = "active"
            if ($window.ProcessName -ieq 'Code') {
                $workspace = Resolve-VSCodeWorkspace $window
                $cliAvailable = [bool](Get-Command code -ErrorAction SilentlyContinue)
                if ($workspace) { $detail = "workspace={0}; cli={1}" -f $workspace.Label, $cliAvailable }
                else { $detail = "workspace=unresolved; cli={0}" -f $cliAvailable }
            }
        }
        Write-Host ("{0,-20} {1,-6} {2,-10} {3,-25} {4}" -f $window.ProcessName, $window.ProcessId, $behavior, $detail, $window.Title)
    }
    Write-Host ""
    Write-AwakeLog "Win32: sleep prevention, focus, geometry, keyboard/mouse SendInput available."
    Write-AwakeLog ("protected runner window handle: {0}" -f $script:RUNNER_WINDOW_HANDLE)
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
    Write-AwakeLog ("sleep {0}-{1}s | tile {2}% | active-mode (ENABLE_ALL) {3}" -f $script:MIN_SLEEP, $script:MAX_SLEEP, $script:TILE_PROBABILITY, $script:ENABLE_ALL)
    Write-AwakeLog ("excluding apps/windows: {0}" -f ($script:EXCLUDE_APPS -join ", "))
    Write-AwakeLog ("protecting runner window handle: {0}" -f $script:RUNNER_WINDOW_HANDLE)

    try {
        Enable-AwakeExecutionState
        while ($true) {
            Enable-AwakeExecutionState
            $windows = @(Get-AwakeWindows)
            if ($windows.Count -eq 0) {
                Write-AwakeLog "no visible windows found after excludes"
                Sleep-Random
                continue
            }

            $roll = Get-Random -Minimum 0 -Maximum 100
            if ($roll -lt $script:TILE_PROBABILITY -and $windows.Count -ge 2) {
                $left = $windows | Get-Random
                $rightCandidates = @($windows | Where-Object { $_.Handle -ne $left.Handle })
                $right = $rightCandidates | Get-Random
                Invoke-TileWindows $left $right
            } else {
                $window = $windows | Get-Random
                if (Invoke-MaximizeWindow $window) {
                    Invoke-DeepWindowAction $window
                }
            }
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
  TILE_PROBABILITY        chance to tile two windows instead of maximizing (default 25)
  ENABLE_ALL              true = app shortcuts + mouse movement (default false)
  VSCODE_OPEN_FILE_PROBABILITY  chance of Quick Open after VS Code focus (default 30)
  VSCODE_RANDOM_FILE_CYCLE_SIZE unique workspace files per cycle (default 20)
  MOUSE_JIGGLE_PX         nudge size for --jiggle-test (default 1)
  AWAKE_EXCLUDE_APPS      comma-separated process/window names to skip
  AWAKE_LOG_FILE          also append logs to this file

EXAMPLES:
  `$env:ENABLE_ALL="true"; powershell -ExecutionPolicy Bypass -File .\awake.ps1
  `$env:MIN_SLEEP="3"; `$env:MAX_SLEEP="6"; powershell -ExecutionPolicy Bypass -File .\awake.ps1

NOTES:
  Chrome and Postman cycle tabs and scroll. VS Code cycles editors, scrolls,
  and may open a unique random workspace file. These require ENABLE_ALL=true.
  Terminals are focus-only and never receive synthetic keystrokes.
  Windows uses Win32 SendInput; no extra install is required.
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
