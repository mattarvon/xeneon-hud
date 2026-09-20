# Reads or sets the Xeneon Edge's hardware backlight over DDC/CI (VCP code 0x10).
#   .\Set-EdgeBrightness.ps1            show current brightness
#   .\Set-EdgeBrightness.ps1 -Percent 60
# The Edge is found by its native 2560x720 mode, so display rearrangement does not matter.
param([ValidateRange(0, 100)][int]$Percent = -1)

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class EdgeDdc {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
    public delegate bool MonProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonProc cb, IntPtr d);
    [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll")] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] a);

    // Returns "before,after,max"; pass percent < 0 to only read.
    public static string Brightness(int width, int height, int percent) {
        string result = null;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hm, IntPtr hdc, ref RECT r, IntPtr d) => {
            if (r.R - r.L != width || r.B - r.T != height) return true;
            uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return true;
            var a = new PHYSICAL_MONITOR[n]; GetPhysicalMonitorsFromHMONITOR(hm, n, a);
            uint t, cur, max;
            if (GetVCPFeatureAndVCPFeatureReply(a[0].h, 0x10, out t, out cur, out max)) {
                uint before = cur;
                if (percent >= 0) {
                    SetVCPFeature(a[0].h, 0x10, (uint)Math.Round(max * percent / 100.0));
                    System.Threading.Thread.Sleep(250); // monitors need a beat before they report the new value
                    GetVCPFeatureAndVCPFeatureReply(a[0].h, 0x10, out t, out cur, out max);
                }
                result = before + "," + cur + "," + max;
            }
            DestroyPhysicalMonitors(n, a); return false; }, IntPtr.Zero);
        return result; }
}
'@
[void][EdgeDdc]::SetProcessDpiAwarenessContext([IntPtr](-4))   # true pixel sizes, or 2560x720 will not match
$r = [EdgeDdc]::Brightness(2560, 720, $Percent)
if (-not $r) { throw 'Xeneon Edge (2560x720) not found, or it did not answer DDC/CI.' }
$before, $after, $max = $r -split ','
if ($Percent -lt 0) { "Edge brightness: $before / $max" } else { "Edge brightness: $before -> $after / $max" }
