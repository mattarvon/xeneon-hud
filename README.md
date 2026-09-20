# xeneon-hud

Read-only telemetry HUD for the Corsair Xeneon Edge (2560x720). Colonial Marines hardware
recovered from the Labyrinth: ALIENS (1986) crossed with HELLRAISER (1987).

| Panel | Feed |
| --- | --- |
| Primary Vitals (far left, the prime spot) | six big 7-segment counters with gauge bars: GPU load, GPU temp, power, VRAM, CPU load, RAM |
| Targets | what is eating the rig: top 5 process names by CPU and by RAM, plus process count (`procs.ps1`) |
| M314 Tracker (compact, Lament Configuration face) | K3s nodes as contacts; busier node = closer |
| Pin Grid | one nail per CPU thread, plus fan, clock, net, disks |
| Node Vitals | real data per K3s node, scraped straight from each node-exporter (`:9100`) every 5 s: live 5-minute CPU trace, per-core bars, CPU and temp counters, load, memory, disk, net, disk I/O, pods. NotReady = flatline |
| Bishop | Ollama: loaded models, VRAM held, armory |
| Casualty Report | K3s trouble board: Argo CD synced count, pods down, Warning events in the last hour, most-restarted pods |
| ISS Piss Tank (header) | NASA ISS live telemetry over Lightstreamer, item `NODE3000005`; port of `E:\projects\iss-piss-o-meter`. Preview states with `?iss=87` |

## Run

    .\Start-Hud.ps1    # server + borderless window on the Edge (safe to re-run)
    .\Stop-Hud.ps1
    .\Set-EdgeBrightness.ps1 -Percent 60   # hardware backlight over DDC/CI; no argument = show current
    .\Install-Autostart.ps1 -Brightness 60 # start at login (Startup-folder shortcut); -Remove to undo
    .\Capture-Edge.ps1                     # screenshot what is really on the Edge -> shots\live.png (gitignored)

At login `Start-Hud-AtLogin.ps1` waits for the Edge to enumerate and for iCUE to start, launches the HUD,
sets the backlight, then re-asserts topmost at +30 s, +90 s and +210 s in case iCUE comes up late.
It logs to `login.log`. `Start-Hud.ps1 -TopmostOnly` puts a buried HUD back on top without relaunching it.

`server.js` is dependency-free Node, binds 127.0.0.1:1986 only, and pushes one JSON snapshot a
second over SSE (`/api/stream`; `/api/telemetry` for a one-shot). `index.html` is the whole front end.
Open `http://127.0.0.1:1986/` in any browser for a letterboxed preview; add `?poll` for headless screenshots.

## Config

Optional `config.local.json` (gitignored); see `config.example.json`. No credentials are needed or stored.
Hosts are always shown by their real hostnames, never nicknames. All temperatures display in Fahrenheit
(feeds report Celsius; `toF()` in `index.html` converts).

## Gotchas

- iCUE owns a fullscreen TOPMOST window on the Edge. `Start-Hud.ps1` makes the HUD topmost so it wins.
  Without that the HUD is at the right coordinates but invisible underneath.
- The Edge hangs off the 9800X3D iGPU via the motherboard USB-C. If the display is missing, check the iGPU first.
- No CPU temperature: Windows exposes none for AM5 without a kernel driver (LibreHardwareMonitor would add it).
- Removed on purpose: the Pi-hole panel (just log in to Pi-hole) and the GPU history graph (unclear, not worth the space).
