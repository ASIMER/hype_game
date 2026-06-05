<#
.SYNOPSIS
  Launch N Hype Raiders game instances for parallel self-play testing — one per
  agent. Each instance opens its own control server on port 24700 + i and writes
  screenshots to its own user://agent/<port>/ dir (see Settings.user_path).

.DESCRIPTION
  Drive each instance with:  python tools/agent/play.py --port <port> <cmd>
  Screenshots land in:       %APPDATA%\Godot\app_userdata\Hype Raiders\agent\<port>\
  Profile/settings per inst: %APPDATA%\...\Hype Raiders\profile_<port>.cfg / settings_<port>.cfg

.PARAMETER Count
  How many instances to launch (1-4). Default 2.

.PARAMETER BasePort
  First control port. Default 24700. Instance i uses BasePort + i.

.PARAMETER Path
  Project (or git worktree) path to run. Default the repo this script lives in.

.PARAMETER Godot
  Godot executable. Default the known Windows build.

.EXAMPLE
  ./tools/agent/launch_agents.ps1 -Count 3
  python tools/agent/play.py --port 24701 ping
#>
param(
  [int]$Count = 2,
  [int]$BasePort = 24700,
  [string]$Path = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
  [string]$Godot = "C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe"
)

if ($Count -lt 1 -or $Count -gt 4) { throw "Count must be 1-4 (got $Count)." }
if (-not (Test-Path $Godot)) { throw "Godot not found at $Godot" }

Write-Host "Launching $Count instance(s) from '$Path'..."
for ($i = 0; $i -lt $Count; $i++) {
  $port = $BasePort + $i
  $argList = "--path `"$Path`" -- --agent --agent-port $port"
  $p = Start-Process -FilePath $Godot -ArgumentList $argList -PassThru
  Write-Host ("  instance {0}: PID {1}  control port {2}  ->  python tools/agent/play.py --port {2} state" -f $i, $p.Id, $port)
}
Write-Host "Done. Give them ~8s to boot, then drive each by its --port."
