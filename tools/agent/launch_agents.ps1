<#
.SYNOPSIS
  Launch N Hype Raiders game instances for parallel self-play testing — one per
  agent, designed for git-worktree parallelism. Each instance is fully isolated:
  its own control port, user:// saves, screenshots, AND (per worktree) its own
  network ports + a window-title identifier so nothing collides.

.DESCRIPTION
  Per-instance differentiation:
    --agent-port N : control port (BasePort + i) + user:// suffix _N + screenshots agent/N/
    --net-port P   : ENet game port (P) + LAN discovery (P+1). ALL instances in one
                     launch share -NetPort (they're one co-op group); a DIFFERENT
                     worktree must pass a DIFFERENT -NetPort so two groups can host
                     at once on the same machine.
    --label L      : folded into the window title ("Hype Raiders_<L> [a:.. n:..]")
                     so instances are tellable apart in the OS task manager.

  Also writes tools/agent/.agent_port (gitignored) = the primary control port, so THIS
  worktree's MCP server (hype-game) auto-targets this worktree's primary instance. To
  point the MCP at a different instance, set $env:HYPE_AGENT_PORT before starting Claude.

  Drive each instance:  python tools/agent/play.py --port <port> <cmd>
                        python tools/agent/raw.py '<json>' <port>
  Screenshots land in:  %APPDATA%\Godot\app_userdata\Hype Raiders\agent\<port>\
  Per-instance saves:   %APPDATA%\...\Hype Raiders\profile_<port>.cfg / settings_<port>.cfg

.PARAMETER Count     How many instances (1-8). Default 2.
.PARAMETER BasePort  First control port. Default 24700. Instance i uses BasePort + i.
.PARAMETER NetPort   ENet game port for this group/worktree. Default 24565 (discovery = +1).
.PARAMETER Label     Window-title identifier. Default = the git branch checked out at -Path.
.PARAMETER Menu      Boot to the menu (for co-op host/join tests) instead of straight into a raid.
.PARAMETER Path      Project (or git worktree) path to run. Default the repo this script lives in.
.PARAMETER Godot     Godot executable. Default the known Windows build.

.EXAMPLE
  # Worktree on branch feat/foo — two menu instances for a co-op test:
  ./tools/agent/launch_agents.ps1 -Count 2 -Menu
  python tools/agent/raw.py '{"cmd":"net","action":"host"}' 24700
  python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"127.0.0.1"}' 24701

.EXAMPLE
  # A SECOND worktree, concurrently — distinct control AND net ports so they never clash:
  ./tools/agent/launch_agents.ps1 -Count 2 -BasePort 24710 -NetPort 24665 -Path C:\wt\bar
#>
param(
  [int]$Count = 2,
  [int]$BasePort = 24700,
  [int]$NetPort = 24565,
  [string]$Label = "",
  [switch]$Menu,
  [bool]$NoSave = $true,
  [string]$Path = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
  [string]$Godot = "C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe"
)

if ($Count -lt 1 -or $Count -gt 8) { throw "Count must be 1-8 (got $Count)." }
if (-not (Test-Path $Godot)) { throw "Godot not found at $Godot" }

# Default the label to the worktree's current git branch (so the window title says
# "Hype Raiders_<branch>"). Falls back to the leaf folder name if git can't resolve it.
if ([string]::IsNullOrWhiteSpace($Label)) {
  $branch = (& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
  if ($LASTEXITCODE -eq 0 -and $branch) { $Label = $branch.Trim() }
  else { $Label = Split-Path $Path -Leaf }
}
# Sanitize for a window title / CLI arg (no spaces/slashes).
$Label = ($Label -replace '[\\/\s]', '-')

$menuArg = if ($Menu) { " --menu" } else { "" }
# Ephemeral by default: test runs do NOT persist progression and never touch the real
# user://profile.cfg (pass -NoSave:$false only for a deliberate persistence test).
$noSaveArg = if ($NoSave) { " --no-save" } else { "" }

Write-Host "Launching $Count instance(s) from '$Path'  [label=$Label  net-port=$NetPort  no-save=$NoSave]..."
for ($i = 0; $i -lt $Count; $i++) {
  $port = $BasePort + $i
  $argList = "--path `"$Path`" -- --agent$menuArg$noSaveArg --agent-port $port --net-port $NetPort --label $Label"
  $p = Start-Process -FilePath $Godot -ArgumentList $argList -PassThru
  Write-Host ("  instance {0}: PID {1}  control {2}  net {3}  ->  python tools/agent/play.py --port {2} state" -f $i, $p.Id, $port, $NetPort)
}

# Pin THIS worktree's MCP server (hype-game) to the primary instance's control port.
$pinFile = Join-Path $PSScriptRoot ".agent_port"
"$BasePort" | Out-File -FilePath $pinFile -Encoding ascii -NoNewline
Write-Host ""
Write-Host "MCP: wrote $pinFile = $BasePort  (the hype-game MCP tools will target port $BasePort)."
Write-Host "     To target another instance instead: set `$env:HYPE_AGENT_PORT before launching Claude."
Write-Host "Done. Give them ~8s to boot, then drive each by its --port."
