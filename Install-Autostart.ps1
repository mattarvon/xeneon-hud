# Adds (or with -Remove, deletes) a Startup-folder shortcut that brings the HUD up at login
# and sets the Edge backlight. No admin rights needed; undo = delete the shortcut.
#   .\Install-Autostart.ps1 -Brightness 60
#   .\Install-Autostart.ps1 -Remove
param([ValidateRange(0, 100)][int]$Brightness = 60, [switch]$Remove)
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Xeneon HUD.lnk'
if ($Remove) {
    if (Test-Path $lnk) { Remove-Item $lnk -Confirm:$false; "Removed $lnk" } else { 'No autostart shortcut present.' }
    return
}
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath       = $pwsh
$s.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\Start-Hud-AtLogin.ps1`" -Brightness $Brightness"
$s.WorkingDirectory = $PSScriptRoot
$s.WindowStyle      = 7   # minimized, so the console barely flashes
$s.Description      = 'Xeneon Edge telemetry HUD'
$s.Save()
"Installed $lnk (brightness $Brightness)"
