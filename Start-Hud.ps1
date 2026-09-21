# Starts the TAC-NET telemetry server (if not already up) and opens the HUD
# borderless on the Xeneon Edge. Safe to re-run: it replaces the old HUD window.
#   -TopmostOnly   leave the running HUD alone and just put it back on top of iCUE
#   -NoWatchdog    do not start Watch-Hud.ps1 (the watchdog passes this when it calls us)
param([switch]$TopmostOnly, [switch]$NoWatchdog)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- watchdog: keeps the HUD on top through sleep/wake, display changes, and iCUE restarts
if (-not $NoWatchdog -and -not (Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'Watch-Hud\.ps1' })) {
    Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\Watch-Hud.ps1`""
}
$cfg  = Get-Content "$root\config.local.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
$port = if ($cfg.port) { $cfg.port } else { 1986 }

# --- server
if (-not $TopmostOnly -and -not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
    Start-Process node -ArgumentList 'server.js' -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput "$root\server.log" -RedirectStandardError "$root\server.err.log"
    foreach ($i in 1..20) {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 500
    }
}

# --- find the Edge by its native mode, in true pixels (this process must be DPI aware for that)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class HudWin {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int L, T, R, B; }
}
'@
[void][HudWin]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Windows.Forms
$edge = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 720 } | Select-Object -First 1
if (-not $edge) { throw 'Xeneon Edge (2560x720) is not an active display. Check the iGPU first: Get-PnpDevice -Class Display' }
$b = $edge.Bounds

# --- browser
$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Neither Chrome nor Edge found.' }
$profileDir = "$root\.chrome-profile"

if (-not $TopmostOnly) {
    # close a previous HUD window (matched by its dedicated profile dir, so normal browsing is untouched)
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($profileDir) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800

    Start-Process $browser -ArgumentList @(
        "--app=http://127.0.0.1:$port/", "--user-data-dir=`"$profileDir`"",
        "--window-position=$($b.X),$($b.Y)", "--window-size=$($b.Width),$($b.Height)", '--kiosk',
        '--no-first-run', '--no-default-browser-check', '--disable-session-crashed-bubble',
        '--disable-features=Translate,msEdgeSidebarV2', '--disable-pinch', '--overscroll-history-navigation=0'
    )
    Start-Sleep -Seconds 4
}

# --- verify it landed on the Edge; Chrome's own placement can miss on mixed-DPI desktops
$pids = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($profileDir) } | ForEach-Object { [uint32]$_.ProcessId })
$script:hud = [IntPtr]::Zero
$cb = [HudWin+EnumProc] {
    param($h, $l)
    $procId = [uint32]0
    [void][HudWin]::GetWindowThreadProcessId($h, [ref]$procId)
    if ($pids -contains $procId -and [HudWin]::IsWindowVisible($h)) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][HudWin]::GetWindowText($h, $sb, 256)
        if ($sb.ToString() -match 'TAC-NET') { $script:hud = $h; return $false }
    }
    return $true
}
[void][HudWin]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:hud -eq [IntPtr]::Zero) { Write-Warning 'HUD window not found to verify placement.'; return }
$r = New-Object HudWin+RECT
[void][HudWin]::GetWindowRect($script:hud, [ref]$r)
# iCUE keeps a fullscreen TOPMOST window on the Edge for its widgets, so the HUD must be topmost too
# or it sits invisibly underneath. HWND_TOPMOST (-1), SHOWWINDOW | NOACTIVATE.
[void][HudWin]::SetWindowPos($script:hud, [IntPtr](-1), $b.X, $b.Y, $b.Width, $b.Height, 0x0050)
[void][HudWin]::GetWindowRect($script:hud, [ref]$r)
"HUD window: $($r.R - $r.L)x$($r.B - $r.T) at $($r.L),$($r.T)  (Edge is $($b.Width)x$($b.Height) at $($b.X),$($b.Y))"
