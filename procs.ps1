# Emits one compact JSON line every 3 s: process count plus the top 5 process NAMES by CPU and by RAM.
# Same-named processes are summed (all of chrome.exe counts as one target). CPU is percent of the whole
# machine, like Task Manager. Started and owned by server.js; exits when its stdout pipe goes away.
$cores = [Environment]::ProcessorCount
$prev  = @{}
$sw    = [Diagnostics.Stopwatch]::StartNew()
$last  = 0.0
while ($true) {
    Start-Sleep -Seconds 3
    $t = $sw.Elapsed.TotalSeconds; $dt = $t - $last; $last = $t
    $cur = @{}; $cpu = @{}; $ram = @{}; $n = 0
    foreach ($p in [Diagnostics.Process]::GetProcesses()) {
        if ($p.Id -ne 0) {
            $n++
            $name = $p.ProcessName
            $tt = $null
            try { $tt = $p.TotalProcessorTime.TotalSeconds } catch { }   # protected processes deny this
            if ($null -ne $tt) {
                $cur[$p.Id] = $tt
                if ($prev.ContainsKey($p.Id)) { $d = $tt - $prev[$p.Id]; if ($d -gt 0) { $cpu[$name] = [double]$cpu[$name] + $d } }
            }
            $ram[$name] = [long]$ram[$name] + $p.WorkingSet64
        }
        $p.Dispose()
    }
    $prev = $cur
    $topCpu = @($cpu.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 |
        ForEach-Object { @{ name = $_.Key; pct = [math]::Round(100 * $_.Value / $dt / $cores, 1) } })
    $topRam = @($ram.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 |
        ForEach-Object { @{ name = $_.Key; bytes = $_.Value } })
    $line = @{ n = $n; cpu = $topCpu; ram = $topRam } | ConvertTo-Json -Compress -Depth 4
    try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { exit }
}
