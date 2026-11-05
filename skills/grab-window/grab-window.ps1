<#
.SYNOPSIS
    Capture a PNG of a single window (or a screen region) on Windows.

.DESCRIPTION
    Self-contained: no modules, no admin rights, no external binaries.
    Runs on Windows PowerShell 5.1 and PowerShell 7+.

    Modes
      (default)    Capture one window chosen by -Title, -ProcessId or -Hwnd.
      -Window      Capture the current foreground window.
      -Region      Capture -Bounds "x,y,w,h", or the whole virtual desktop.
      -List        List capturable windows (hwnd, pid, process, title, size).

    Capture strategy (-Method)
      Auto         PrintWindow with PW_RENDERFULLCONTENT, then PrintWindow(0),
                   then a screen crop of the window rectangle. Default.
      PrintWindow  Per-window rendering. Can capture a window that is not in
                   front, but some GPU/DWM-composited apps return blank frames.
      Screen       CopyFromScreen crop. Exact displayed pixels, but captures
                   whatever overlaps the window and cannot see a minimized one.

    Notes
      - Sets per-monitor DPI awareness so window rectangles and pixels agree on
        scaled displays. A process that already fixed its DPI mode is unchanged.
      - Skips DWM-cloaked and untitled windows during discovery.
      - PrintWindow bitmaps use the full window rectangle, including the
        invisible resize border, so content sits a few pixels inside the edge.

.PARAMETER Title
    Window title. Tried as exact match (case-insensitive), then as a -like
    wildcard, then as a substring. Ambiguous matches fail and list the
    candidates so you can pick -Hwnd.

.PARAMETER ProcessId
    Owning process id. Alias: -Pid.

.PARAMETER Hwnd
    Raw window handle. Unambiguous; use this when titles repeat.

.PARAMETER Window
    Capture the foreground window, with no other arguments.

.PARAMETER Region
    Capture a desktop rectangle instead of a window.

.PARAMETER Bounds
    Region as x,y,width,height in virtual-desktop pixels. Defaults to every
    monitor combined. Negative x/y are valid on a monitor left of the primary.

.PARAMETER Method
    Auto (default), PrintWindow, or Screen.

.PARAMETER Path
    Output .png path. Defaults to capture-<timestamp>.png in the current
    directory. Missing parent directories are created.

.PARAMETER List
    Print the capturable window list and exit.

.OUTPUTS
    System.Management.Automation.PSCustomObject with Path, Method, Width,
    Height, Hwnd, Title, ProcessId, ProcessName, Minimized, Blank, Note, Bytes.

.EXAMPLE
    .\grab-window.ps1 -List

.EXAMPLE
    .\grab-window.ps1 -Title '*Visual Studio Code*' -Path shots\code.png

.EXAMPLE
    .\grab-window.ps1 -Pid 12345 -Method PrintWindow

.EXAMPLE
    .\grab-window.ps1 -Window

.EXAMPLE
    .\grab-window.ps1 -Region -Bounds 0,0,1280,720 -Path shots\corner.png

.EXAMPLE
    .\grab-window.ps1 -Region -Path shots\all-monitors.png
#>
[CmdletBinding(DefaultParameterSetName = 'Window')]
param(
    [Parameter(ParameterSetName = 'Window', Position = 0)]
    [string] $Title,

    [Parameter(ParameterSetName = 'Window')]
    [Alias('Pid')]
    [int] $ProcessId,

    [Parameter(ParameterSetName = 'Window')]
    [long] $Hwnd,

    [Parameter(ParameterSetName = 'Foreground')]
    [switch] $Window,

    [Parameter(ParameterSetName = 'Region')]
    [switch] $Region,

    [Parameter(ParameterSetName = 'Region')]
    [int[]] $Bounds,

    [ValidateSet('Auto', 'PrintWindow', 'Screen')]
    [string] $Method = 'Auto',

    [string] $Path,

    [switch] $List
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Interop
# --------------------------------------------------------------------------

Add-Type -AssemblyName System.Drawing

if (-not ('DshWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public struct DshRect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class DshWindow
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLengthW(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out DshRect rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out DshRect value, int size);
}
'@
}

# Per-monitor DPI awareness: window rectangles and screen pixels must agree.
$script:DpiMode = 'inherited'
try {
    if ([DshWindow]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $script:DpiMode = 'per-monitor-v2' }
} catch {
    # Older Windows: fall back to system DPI awareness.
}
if ($script:DpiMode -eq 'inherited') {
    try {
        if ([DshWindow]::SetProcessDPIAware()) { $script:DpiMode = 'system' }
    } catch {
        # Leave the inherited mode; coordinates still work when scaling is 100%.
    }
}

# --------------------------------------------------------------------------
# Bitmap helpers
# --------------------------------------------------------------------------

function New-DshBitmap {
    param([int] $Width, [int] $Height)

    if ($Width -le 0 -or $Height -le 0) { throw "Refusing a zero-area capture ($Width x $Height)." }
    return New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
}

function New-DshPrintWindowBitmap {
    param([long] $Handle, [int] $Width, [int] $Height)

    $bitmap = New-DshBitmap -Width $Width -Height $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    try {
        # PW_RENDERFULLCONTENT = 0x2; required by many DWM-composited windows.
        $rendered = [DshWindow]::PrintWindow([IntPtr]$Handle, $hdc, [uint32]2)
        if (-not $rendered) {
            $rendered = [DshWindow]::PrintWindow([IntPtr]$Handle, $hdc, [uint32]0)
        }
    } finally {
        $graphics.ReleaseHdc($hdc)
        $graphics.Dispose()
    }
    return $bitmap
}

function New-DshScreenBitmap {
    param([int] $X, [int] $Y, [int] $Width, [int] $Height)

    $bitmap = New-DshBitmap -Width $Width -Height $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($Width, $Height)), [System.Drawing.CopyPixelOperation]::SourceCopy)
    } finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Test-DshBitmapUniform {
    # A single-color result almost always means the app refused to render.
    param([System.Drawing.Bitmap] $Bitmap)

    $width = $Bitmap.Width
    $height = $Bitmap.Height
    $step = [Math]::Max(1, [int]([Math]::Min($width, $height) / 24))
    $first = 0
    $seen = $false

    for ($x = 0; $x -lt $width; $x += $step) {
        for ($y = 0; $y -lt $height; $y += $step) {
            $argb = $Bitmap.GetPixel($x, $y).ToArgb()
            if (-not $seen) { $first = $argb; $seen = $true }
            elseif ($argb -ne $first) { return $false }
        }
    }
    return $true
}

# --------------------------------------------------------------------------
# Window discovery
# --------------------------------------------------------------------------

function Get-DshWindowInfo {
    param([long] $Handle)

    $native = [IntPtr]$Handle
    $rect = New-Object DshRect
    if (-not [DshWindow]::GetWindowRect($native, [ref]$rect)) {
        throw "GetWindowRect failed for window handle $Handle."
    }

    $length = [DshWindow]::GetWindowTextLengthW($native)
    $text = ''
    if ($length -gt 0) {
        $buffer = New-Object System.Text.StringBuilder($length + 2)
        [void][DshWindow]::GetWindowTextW($native, $buffer, $buffer.Capacity)
        $text = $buffer.ToString()
    }

    $ownerId = 0
    [void][DshWindow]::GetWindowThreadProcessId($native, [ref]$ownerId)
    $processName = ''
    # Cosmetic only: some sandboxes deny process enumeration while window
    # enumeration still works, so an unknown name must not fail the capture.
    try { $processName = (Get-Process -Id ([int]$ownerId) -ErrorAction Stop).ProcessName } catch { $processName = '' }
    if ([string]::IsNullOrEmpty($processName)) {
        try { $processName = [System.Diagnostics.Process]::GetProcessById([int]$ownerId).ProcessName } catch { $processName = '' }
    }
    if ([string]::IsNullOrEmpty($processName)) { $processName = 'unknown' }

    # DWMWA_EXTENDED_FRAME_BOUNDS (9) excludes the invisible resize border.
    $extended = New-Object DshRect
    $hasExtended = $false
    try {
        if ([DshWindow]::DwmGetWindowAttribute($native, 9, [ref]$extended, 16) -eq 0) { $hasExtended = $true }
    } catch {
        $hasExtended = $false
    }
    if (-not $hasExtended) {
        $extended = $rect
    }

    return [pscustomobject]@{
        Hwnd          = $Handle
        ProcessId     = [int]$ownerId
        ProcessName   = $processName
        Title         = $text
        Left          = $rect.Left
        Top           = $rect.Top
        Width         = $rect.Right - $rect.Left
        Height        = $rect.Bottom - $rect.Top
        ScreenLeft    = $extended.Left
        ScreenTop     = $extended.Top
        ScreenWidth   = $extended.Right - $extended.Left
        ScreenHeight  = $extended.Bottom - $extended.Top
        Minimized     = [DshWindow]::IsIconic($native)
    }
}

function Get-DshWindowHandles {
    $handles = New-Object 'System.Collections.Generic.List[long]'
    $callback = [DshWindow+EnumWindowsProc]{
        param([IntPtr] $hWnd, [IntPtr] $lParam)

        if (-not [DshWindow]::IsWindowVisible($hWnd)) { return $true }
        if ([DshWindow]::GetWindowTextLengthW($hWnd) -le 0) { return $true }

        # DWMWA_CLOAKED (14): skip UWP ghosts and windows on other virtual desktops.
        $cloaked = 0
        try { [void][DshWindow]::DwmGetWindowAttribute($hWnd, 14, [ref]$cloaked, 4) } catch { $cloaked = 0 }
        if ($cloaked -ne 0) { return $true }

        $handles.Add([long]$hWnd)
        return $true
    }
    [void][DshWindow]::EnumWindows($callback, [IntPtr]::Zero)
    return $handles
}

function Get-DshWindow {
    foreach ($handle in (Get-DshWindowHandles)) {
        try { Get-DshWindowInfo -Handle $handle } catch { continue }
    }
}

function Resolve-DshWindowHandle {
    param([string] $Title, [int] $ProcessId, [long] $Hwnd)

    if ($Hwnd -gt 0) { return $Hwnd }
    if ($ProcessId -gt 0) {
        $candidates = @(Get-DshWindow | Where-Object { $_.ProcessId -eq $ProcessId })
        if ($candidates.Count -eq 0) { throw "No visible window belongs to process id $ProcessId." }
        if ($candidates.Count -eq 1) { return [long]$candidates[0].Hwnd }
        $names = ($candidates | ForEach-Object { "  $($_.Hwnd)  $($_.Title)" }) -join [Environment]::NewLine
        throw "Process id $ProcessId owns $($candidates.Count) windows; pick one with -Hwnd:$([Environment]::NewLine)$names"
    }

    $all = @(Get-DshWindow)
    if ($all.Count -eq 0) { throw 'No capturable windows found.' }

    if ([string]::IsNullOrWhiteSpace($Title)) {
        throw "Specify -Title, -ProcessId or -Hwnd, or use -Window, -Region or -List. Run with -List to see candidates."
    }

    # 1) exact, 2) wildcard, 3) substring
    $matches = @($all | Where-Object { [string]::Equals($_.Title, $Title, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -eq 0 -and ($Title -match '[*?\[]')) {
        $matches = @($all | Where-Object { $_.Title -like $Title })
    }
    if ($matches.Count -eq 0) {
        $matches = @($all | Where-Object { $_.Title.IndexOf($Title, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }

    if ($matches.Count -eq 0) {
        $available = ($all | Sort-Object ProcessName | ForEach-Object { "  $($_.Hwnd)  $($_.ProcessName)  $($_.Title)" }) -join [Environment]::NewLine
        throw "No window title matches '$Title'. Available windows:$([Environment]::NewLine)$available"
    }
    if ($matches.Count -gt 1) {
        $list = ($matches | ForEach-Object { "  $($_.Hwnd)  $($_.ProcessName)  $($_.Title)" }) -join [Environment]::NewLine
        throw "'$Title' matches $($matches.Count) windows; pass -Hwnd to disambiguate:$([Environment]::NewLine)$list"
    }
    return [long]$matches[0].Hwnd
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if ($List) {
    Get-DshWindow |
        Sort-Object ProcessName, Title |
        Select-Object Hwnd, ProcessId, ProcessName, Title, @{ Name = 'Size'; Expression = { "$($_.Width)x$($_.Height)" } }, Minimized |
        Format-Table -AutoSize
    return
}

$destination = $Path
if ([string]::IsNullOrWhiteSpace($destination)) {
    $destination = 'capture-{0:yyyyMMdd-HHmmss}.png' -f (Get-Date)
}
if ([System.IO.Path]::GetExtension($destination) -eq '') {
    $destination = "$destination.png"
}
if ([System.IO.Path]::GetExtension($destination) -ne '.png') {
    throw "Only PNG output is supported; got '$destination'."
}
if ([System.IO.Path]::IsPathRooted($destination)) {
    $destination = [System.IO.Path]::GetFullPath($destination)
} else {
    $destination = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $destination))
}
$directory = [System.IO.Path]::GetDirectoryName($destination)
if (-not [System.IO.Directory]::Exists($directory)) {
    [void][System.IO.Directory]::CreateDirectory($directory)
}

$note = ''
$used = $Method
$target = $null
$bitmap = $null

try {
    if ($Region) {
        if ($Bounds -and $Bounds.Count -eq 4) {
            $x = $Bounds[0]; $y = $Bounds[1]; $width = $Bounds[2]; $height = $Bounds[3]
        } else {
            if ($Bounds -and $Bounds.Count -ne 4) { throw 'Bounds must be x,y,width,height (four integers).' }
            # SM_XVIRTUALSCREEN(76) SM_YVIRTUALSCREEN(77) SM_CXVIRTUALSCREEN(78) SM_CYVIRTUALSCREEN(79)
            $x = [DshWindow]::GetSystemMetrics(76)
            $y = [DshWindow]::GetSystemMetrics(77)
            $width = [DshWindow]::GetSystemMetrics(78)
            $height = [DshWindow]::GetSystemMetrics(79)
        }
        $bitmap = New-DshScreenBitmap -X $x -Y $y -Width $width -Height $height
        $used = 'Screen'
        $target = [pscustomobject]@{
            Hwnd = 0; ProcessId = 0; ProcessName = ''; Title = 'desktop region'
            Width = $width; Height = $height; Minimized = $false
        }
    } else {
        if ($Window) {
            $handle = [long][DshWindow]::GetForegroundWindow()
            if ($handle -eq 0) { throw 'There is no foreground window to capture.' }
        } else {
            $handle = Resolve-DshWindowHandle -Title $Title -ProcessId $ProcessId -Hwnd $Hwnd
        }

        $target = Get-DshWindowInfo -Handle $handle
        if ($target.Minimized -and $Method -eq 'Screen') {
            throw 'The target window is minimized; restore it or use -Method PrintWindow.'
        }

        if ($Method -eq 'Screen') {
            $bitmap = New-DshScreenBitmap -X $target.ScreenLeft -Y $target.ScreenTop -Width $target.ScreenWidth -Height $target.ScreenHeight
            $used = 'Screen'
            $note = 'Screen crop shows whatever is displayed there, including overlapping windows.'
        } else {
            $bitmap = New-DshPrintWindowBitmap -Handle $handle -Width $target.Width -Height $target.Height
            $used = 'PrintWindow'
            if (Test-DshBitmapUniform -Bitmap $bitmap) {
                if ($Method -eq 'Auto' -and -not $target.Minimized) {
                    $bitmap.Dispose()
                    $bitmap = New-DshScreenBitmap -X $target.ScreenLeft -Y $target.ScreenTop -Width $target.ScreenWidth -Height $target.ScreenHeight
                    $used = 'Screen'
                    $note = 'PrintWindow produced a blank frame for this app; fell back to a screen crop of the window.'
                } else {
                    $note = 'PrintWindow produced a blank frame for this app.'
                }
            }
            if ($target.Minimized) {
                $note = 'The target window is minimized; PrintWindow output may be blank or stale.'
            }
        }
    }

    $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $savedWidth = $bitmap.Width
    $savedHeight = $bitmap.Height
    $bytes = (New-Object System.IO.FileInfo($destination)).Length
    $blank = Test-DshBitmapUniform -Bitmap $bitmap
} finally {
    if ($null -ne $bitmap) { $bitmap.Dispose() }
}

[pscustomobject]@{
    Path        = $destination
    Method      = $used
    Width       = $savedWidth
    Height      = $savedHeight
    Hwnd        = $target.Hwnd
    Title       = $target.Title
    ProcessId   = $target.ProcessId
    ProcessName = $target.ProcessName
    Minimized   = $target.Minimized
    Blank       = $blank
    DpiMode     = $script:DpiMode
    Note        = $note
    Bytes       = $bytes
}
