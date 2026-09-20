# Login entry point, run from a shortcut in the user's Startup folder (see Install-Autostart.ps1).
# At login nothing is ready yet: the Edge may not have enumerated and iCUE has not claimed it.
# iCUE puts a fullscreen TOPMOST window on the Edge when it starts, and a topmost window created
# later goes above earlier ones, so launching the HUD before iCUE would leave it buried.
param([ValidateRange(0, 100)][int]$Brightness = 60)
$root = $PSScriptRoot
$log  = "$root\login.log"
function Note($m) { "[$(Get-Date -Format s)] $m" | Out-File $log -Append }
"[$(Get-Date -Format s)] login start" | Out-File $log

Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class LoginDpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
[void][LoginDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Windows.Forms

# 1) wait for the Edge (2560x720) to be an active display, up to 3 minutes
$found = $false
foreach ($i in 1..90) {
    if ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Width -eq 2560 -and $_.Bounds.Height -eq 720 }) { $found = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $found) { Note 'Edge never appeared; giving up (check the iGPU: Get-PnpDevice -Class Display)'; return }
Note 'Edge present'

# 2) give iCUE up to 90 s to start, then a moment to put its window up
foreach ($i in 1..45) { if (Get-Process iCUE -ErrorAction SilentlyContinue) { break }; Start-Sleep -Seconds 2 }
Note ("iCUE running: " + [bool](Get-Process iCUE -ErrorAction SilentlyContinue))
Start-Sleep -Seconds 15

# 3) HUD up, backlight set
try { Note (& "$root\Start-Hud.ps1" | Out-String).Trim() } catch { Note "Start-Hud failed: $($_.Exception.Message)" }
try { Note (& "$root\Set-EdgeBrightness.ps1" -Percent $Brightness | Out-String).Trim() } catch { Note "brightness failed: $($_.Exception.Message)" }

# 4) iCUE may still come up late or re-raise itself: put the HUD back on top a few times
foreach ($wait in 30, 60, 120) {
    Start-Sleep -Seconds $wait
    try { [void](& "$root\Start-Hud.ps1" -TopmostOnly); Note "topmost re-asserted (+${wait}s)" } catch { Note "re-assert failed: $($_.Exception.Message)" }
}
Note 'login done'
