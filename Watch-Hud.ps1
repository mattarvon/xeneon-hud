# Keeps the HUD visible on the Xeneon Edge. Runs forever, hidden, one instance.
# Needed because a login-time launch is not enough: every resume from sleep, iCUE raises its own
# fullscreen TOPMOST window back over the HUD, and the Edge's desktop position moves whenever
# another display comes or goes. Every few seconds this checks three things and repairs them:
#   HUD window gone              -> run Start-Hud.ps1
#   HUD not exactly on the Edge  -> move it there
#   another window covers it     -> put it back on top
param([int]$IntervalSeconds = 10)
$root = $PSScriptRoot
$log  = "$root\watch.log"
function Note($m) { "[$(Get-Date -Format s)] $m" | Out-File $log -Append }

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\XeneonHudWatch', [ref]$created)
if (-not $created) { return }   # another watchdog already owns the job

Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public class HudWatch {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    struct RECT { public int L, T, R, B; }

    // Returns "missing", "ok", or what was repaired. EnumWindows walks top-down, so any visible window
    // overlapping the Edge that is met before the HUD is sitting on top of it.
    public static string Check(int x, int y, int w, int h) {
        IntPtr hud = IntPtr.Zero; bool covered = false; string coveredBy = "";
        EnumWindows((hw, l) => {
            if (!IsWindowVisible(hw) || IsIconic(hw)) return true;
            var t = new StringBuilder(200); GetWindowText(hw, t, 200);
            var c = new StringBuilder(100); GetClassName(hw, c, 100);
            if (c.ToString() == "Chrome_WidgetWin_1" && t.ToString().StartsWith("TAC-NET")) { hud = hw; return false; }
            RECT r; GetWindowRect(hw, out r);
            int ow = Math.Min(r.R, x + w) - Math.Max(r.L, x), oh = Math.Min(r.B, y + h) - Math.Max(r.T, y);
            if (ow > w / 4 && oh > h / 4) { covered = true; coveredBy = t.ToString(); }   // ignore slivers and tooltips
            return true; }, IntPtr.Zero);
        if (hud == IntPtr.Zero) return "missing";
        RECT hr; GetWindowRect(hud, out hr);
        bool misplaced = hr.L != x || hr.T != y || hr.R - hr.L != w || hr.B - hr.T != h;
        if (!covered && !misplaced) return "ok";
        SetWindowPos(hud, (IntPtr)(-1), x, y, w, h, 0x0050);   // HWND_TOPMOST, SHOWWINDOW | NOACTIVATE
        return misplaced ? "moved HUD back onto the Edge" : "raised HUD above '" + coveredBy + "'";
    }
}
'@
[void][HudWatch]::SetProcessDpiAwarenessContext([IntPtr](-4))   # true pixels, or 2560x720 will not match
Add-Type -AssemblyName System.Windows.Forms
Note 'watchdog started'

# Start-Hud.ps1 starts us just before it opens the window; treat that as a launch in progress
# so the first checks do not fire a second, competing launch.
$lastLaunch = Get-Date
Start-Sleep -Seconds 15
while ($true) {
    try {
        $edge = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 720 } | Select-Object -First 1
        if ($edge) {
            $b = $edge.Bounds
            $r = [HudWatch]::Check($b.X, $b.Y, $b.Width, $b.Height)
            if ($r -eq 'missing') {
                # relaunching takes a few seconds; do not stack launches
                if (((Get-Date) - $lastLaunch).TotalSeconds -gt 60) {
                    $lastLaunch = Get-Date
                    Note 'HUD window missing; launching'
                    & "$root\Start-Hud.ps1" -NoWatchdog | Out-Null
                }
            } elseif ($r -ne 'ok') { Note $r }
        }
    } catch { Note "error: $($_.Exception.Message)" }
    Start-Sleep -Seconds $IntervalSeconds
}
