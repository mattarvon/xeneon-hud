# Closes the HUD window and stops the telemetry server. Touches nothing else.
$root = $PSScriptRoot
$cfg  = Get-Content "$root\config.local.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
$port = if ($cfg.port) { $cfg.port } else { 1986 }

# the HUD browser is matched by its dedicated profile dir, so normal browsing is untouched
$profileDir = [regex]::Escape("$root\.chrome-profile")
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match $profileDir } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'node') { Stop-Process -Id $p.Id -Force }
}
'HUD stopped.'
