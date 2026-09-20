# Saves a screenshot of whatever is really on the Xeneon Edge to shots\live.png (gitignored:
# the live HUD shows internal IPs, hostnames, and process names). The Edge is found by its
# native 2560x720 mode because its desktop position changes whenever another display comes or goes.
#   .\Capture-Edge.ps1                          full strip
#   .\Capture-Edge.ps1 -Crop 1390,46,760,640    also saves shots\crop.png (x,y,w,h within the Edge)
param([int[]]$Crop)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class CapDpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
[void][CapDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))   # true pixels, or 2560x720 will not match
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$edge = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 720 } | Select-Object -First 1
if (-not $edge) { throw 'Xeneon Edge (2560x720) is not an active display.' }
$b = $edge.Bounds
$dir = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $dir | Out-Null
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size); $g.Dispose()
$bmp.Save((Join-Path $dir 'live.png'), [System.Drawing.Imaging.ImageFormat]::Png)
if ($Crop -and $Crop.Count -eq 4) {
    $c = $bmp.Clone((New-Object System.Drawing.Rectangle $Crop[0], $Crop[1], $Crop[2], $Crop[3]), $bmp.PixelFormat)
    $c.Save((Join-Path $dir 'crop.png'), [System.Drawing.Imaging.ImageFormat]::Png); $c.Dispose()
}
$bmp.Dispose()
"Captured Edge at $($b.X),$($b.Y)"
