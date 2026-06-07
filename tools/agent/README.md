# hype-game agent harness

Tools for driving the Godot game programmatically so an LLM (or a script) can
play it via self-play. Two entry points share one wire protocol:

- `play.py` — a stdlib CLI / importable client for one-off commands.
- `mcp_server.py` — a stdlib MCP server exposing the same actions as MCP tools.

Everything is stdlib-only (no `pip install`).

> **Authoritative command + `state` reference:** the full, current list of wire
> commands and the complete `state` JSON schema live in **`docs/TESTING.md`
> §2–§3**. This file documents the transport and the core verbs; consult
> TESTING.md for the rest (debug hooks like `spawn`/`tp`/`godmode`/`render`, the
> `ui`/`stash`/`net`/`ready`/`deploy` co-op JSON commands driven via
> `tools/agent/raw.py`, multi-instance `--agent-port N`, etc.) so this README
> can't drift.

## How the game exposes control

When the game runs in **agent mode** it starts an in-game TCP control server on
`127.0.0.1:24700` (`Settings.AGENT_PORT`). Launch it like:

```
godot --path "C:\personal\hype game" -- --agent
```

(The `--agent` flag is read by the game's `main.py` / control bridge. Without
it, the control server does not start and these tools will report a connection
refused error.)

## Wire protocol

Newline-delimited JSON over TCP. The client opens a socket, sends **one** JSON
object followed by `\n`, reads **one** JSON object terminated by `\n`, then
closes. Every response includes `"ok": <bool>`.

| Request | Response |
| --- | --- |
| `{"cmd":"ping"}` | `{"ok":true,"agent":true}` |
| `{"cmd":"state"}` | `{"ok":true,"phase":int,"wave":int,"player":{...},"inventory":[...],"inv_weight":float,"inv_value":int,"enemies":[...],"extraction":{active,ratio},"fps":float,"players_count":int}` |
| `{"cmd":"move","x":f,"y":f,"duration":f}` | replies **after** `duration` (server holds then auto-stops). `x`=strafe, `y`=forward(+)/back(-), both `-1..1` |
| `{"cmd":"look","dx":f,"dy":f}` | `{"ok":true}` — yaw delta `dx`, pitch delta `dy`, in radians |
| `{"cmd":"fire","duration":f}` | replies **after** `duration` |
| `{"cmd":"sprint","on":bool}` | `{"ok":true}` |
| `{"cmd":"aim","target":"nearest"\|<name>\|"weakpoint"\|"point","x":f,"y":f,"z":f}` | `{"ok":bool}` — points the camera at an enemy, its weak spot, or a world XYZ point |
| `{"cmd":"goto","x":f,"z":f,"duration":f}` | replies **after** `duration` — faces world XZ point and walks forward toward it |
| `{"cmd":"act","action":"jump\|interact\|reload\|toggle_inventory"}` | `{"ok":true}` |
| `{"cmd":"hold","action":"crouch\|interact\|carry\|jump\|fire\|sprint\|ads","on":bool}` | `{"ok":true}` — sustain an input until released |
| `{"cmd":"screenshot","name":"str"}` | `{"ok":true,"path":"<absolute png path>"}` |
| `{"cmd":"crosshair"}` | `{"ok":bool,"hit":bool,"entity":str,"enemy_id":str,"is_weakpoint":bool,"point":[x,y,z],"dist":f}` |
| `{"cmd":"down","on":bool}` | `{"ok":bool,"downed":bool}` — down (true) or revive (false) local player |
| `{"cmd":"hurt","target":"self\|nearest\|<name>","amount":f,"weak":bool}` | `{"ok":bool,"target":str,"health":f}` |
| `{"cmd":"kill","target":"self\|nearest\|<name>"}` | `{"ok":bool}` |
| `{"cmd":"heal","amount":f}` | `{"ok":bool}` |
| `{"cmd":"sethp","value":f}` | `{"ok":bool}` |
| `{"cmd":"prog","action":"add_xp\|set_xp\|set_level\|add_rep\|set_rep\|add_mastery\|set_mastery\|skill_points\|buy_skill\|credit_kill",...}` | `{"ok":bool,"meta":{...}}` |
| `{"cmd":"event","kind":0-3,"end":bool}` | `{"ok":bool}` |
| `{"cmd":"quit"}` | `{"ok":true}` |

`state.player` fields: `pos:[x,y,z], rot_y, health, max_health, on_floor,
velocity:[x,y,z], cam_yaw, cam_pitch, weapon_cooldown, alive`.
`inventory[]` items: `{id, count, weight}`. `enemies[]`: `{name, pos:[x,y,z],
health, state, dist}`. `loot[]`: `{id, count, pos:[x,y,z], dist}` — world loot
pickups available to grab. `state` also carries `result` (e.g. `"won"`) once a
run resolves.

**Blocking commands:** `move`, `fire`, and `goto` reply only when the held
duration ends. The client sizes its socket timeout to `max(15, duration + 10)`
seconds so long holds don't trip a timeout.

## play.py (CLI)

All commands accept `--port <N>` to target a specific instance (default 24700).

```
python tools/agent/play.py ping
python tools/agent/play.py state            # pretty JSON
python tools/agent/play.py state --raw      # compact JSON
python tools/agent/play.py move 1 0 0.5     # strafe right, 0.5s
python tools/agent/play.py move 0 1 0.8     # forward, 0.8s
python tools/agent/play.py look 0.1 -0.2    # yaw +0.1, pitch -0.2 (radians)
python tools/agent/play.py aim              # aim at nearest enemy (default)
python tools/agent/play.py aim Grunt_3      # aim at a named enemy
python tools/agent/play.py aim weakpoint    # aim at nearest enemy's weak spot
python tools/agent/play.py aim point 10 1 20  # aim at world XYZ (10,1,20)
python tools/agent/play.py goto 24 0 1.0    # face world XZ (24,0) and walk 1.0s
python tools/agent/play.py fire 0.3
python tools/agent/play.py sprint on
python tools/agent/play.py sprint off
python tools/agent/play.py act jump
python tools/agent/play.py act interact
python tools/agent/play.py act reload
python tools/agent/play.py act toggle_inventory
python tools/agent/play.py hold crouch on   # hold crouch
python tools/agent/play.py hold crouch off  # release crouch
python tools/agent/play.py down on          # put local player into downed state
python tools/agent/play.py down off         # revive local player
python tools/agent/play.py hurt nearest 50  # deal 50 damage to nearest enemy
python tools/agent/play.py hurt Grunt_2 100 weak  # weak-point hit
python tools/agent/play.py kill nearest
python tools/agent/play.py kill self
python tools/agent/play.py heal 50
python tools/agent/play.py sethp 100
python tools/agent/play.py crosshair        # raycast from camera; returns hit info
python tools/agent/play.py prog add_xp amount=500
python tools/agent/play.py prog set_level level=10
python tools/agent/play.py prog add_mastery weapon=rifle amount=200
python tools/agent/play.py prog buy_skill key=reload_speed
python tools/agent/play.py shot myshot      # prints ONLY the absolute path
python tools/agent/play.py quit

# Target a specific instance:
python tools/agent/play.py --port 24702 state
```

Overrides: `--host 127.0.0.1 --port 24700`.

### Typical self-play loop

```
state                       # read player/enemies/loot/extraction/result
aim nearest                 # engine points camera at closest enemy
fire 0.3                    # shoot; repeat aim->fire until enemies clear
goto <loot.pos.x> <loot.z>  # walk to a loot pickup from state.loot
act interact                # grab it
goto 24 0                   # walk toward extraction (world XZ 24,0,0)
state                       # hold near extraction until state.result == "won"
```

Exit codes: `0` success (`ok:true`), `1` server replied `ok:false`, `2` could
not reach the control server (connection refused / timeout — message on stderr).

`shot` is special-cased to print only the absolute PNG path on stdout, so you
can capture it directly, e.g. in PowerShell:

```powershell
$png = python tools/agent/play.py shot frame1
```

### Importable

```python
from play import send
resp = send({"cmd": "state"})          # dict in, dict out
resp = send({"cmd": "move", "x": 1, "y": 0, "duration": 0.5})
# Target a specific instance:
resp = send({"cmd": "state"}, port=24702)
```

`send(cmd, host=..., port=..., timeout=...)` raises `AgentError` if the server
is unreachable or replies malformed; timeout auto-derives from `duration`.
Pass an explicit short `timeout` (e.g. `1.0`) when probing many ports.

## MCP server

`mcp_server.py` is a JSON-RPC 2.0 server over stdio implementing the MCP slice
needed by a client: `initialize` (protocolVersion `2024-11-05`), `tools/list`,
`tools/call`, and the `notifications/initialized` notification. It reuses
`play.py`'s `send()`, so it talks the same TCP protocol. Logs go to **stderr**;
stdout carries only JSON-RPC.

### Per-call port targeting

Every MCP tool accepts an optional `port` argument. When omitted, the server
falls back to its resolved default (env `AGENT_PORT` → `.agent_port` pin →
24700). Set `port` to drive any running instance without restarting the server:

```json
{"name": "game_state", "arguments": {"port": 24702}}
```

### Tools exposed

| Tool | Key arguments |
| --- | --- |
| `game_state` | `port?` |
| `game_move` | `x`, `y`, `duration`, `port?` |
| `game_look` | `dx`, `dy`, `port?` |
| `game_aim` | `target` (`"nearest"` / enemy name / `"weakpoint"` / `"point"`), `x?`, `y?`, `z?`, `port?` |
| `game_goto` | `x`, `z`, `duration?`, `port?` |
| `game_fire` | `duration`, `port?` |
| `game_sprint` | `on` (bool), `port?` |
| `game_act` | `action` (`jump`/`interact`/`reload`/`toggle_inventory`), `port?` |
| `game_screenshot` | `name` → returns PNG path, `port?` |
| `game_raw` | `json` (string) **or** `cmd` (object), `port?` — forward any command verbatim |
| `game_instances` | `base?` (default 24700), `count?` (default 8) — probe N ports, return live instances |
| `game_broadcast` | `json`/`cmd`, `ports?` **or** `base`+`count?` — fan-out to multiple ports |
| `game_hold` | `action` (crouch/interact/carry/jump/fire/sprint/ads), `on` (bool), `port?` |
| `game_damage` | `target?` (default "nearest"), `amount?` (default 9999), `weak?`, `port?` |
| `game_kill` | `target?` (default "nearest"), `port?` |
| `game_down` | `on` (bool), `port?` |
| `game_crosshair` | `port?` |
| `game_set_progress` | `action`, `amount?`, `value?`, `weapon?`, `level?`, `key?`, `port?` |
| `game_event` | `kind?` (0-3, default 0), `end?` (bool, default false), `port?` |

Each tool returns MCP content `[{"type":"text","text": <json-or-path>}]`. If the
game is not running, the call returns `isError:true` with an explanatory message
(it does not crash the server).

#### `game_raw` — generic forwarder

Forwards any AgentBridge command dict without requiring a typed wrapper tool.
Use it for commands not yet in the typed list (e.g. `ui`, `stash`, `net`,
`spawn`, `tp`, `godmode`, `render`, `clock`, `transfer`, `favorites`, etc.):

```json
{"name": "game_raw", "arguments": {"json": "{\"cmd\":\"godmode\",\"on\":true}"}}
{"name": "game_raw", "arguments": {"cmd": {"cmd": "spawn", "type": "boss"}, "port": 24701}}
```

#### `game_instances` — discover live instances

Probes `base..base+count-1` with a 1-second timeout each. Returns a JSON list:

```json
[{"port": 24700, "peer_id": 1, "phase": 2, "players_count": 2},
 {"port": 24701, "peer_id": 2, "phase": 2, "players_count": 2}]
```

#### `game_broadcast` — fan-out to N instances

Sends the same command to every port in the target list. Dead ports record an
`"error"` key but do not abort the others:

```json
{"name": "game_broadcast", "arguments": {
  "cmd": {"cmd": "godmode", "on": true},
  "ports": [24700, 24701, 24702, 24703]
}}
```

### Registration

`.mcp.json` at the project root registers it:

```json
{
  "mcpServers": {
    "hype-game": {
      "command": "python",
      "args": ["tools/agent/mcp_server.py"],
      "env": {
        "AGENT_HOST": "127.0.0.1",
        "AGENT_PORT": "${HYPE_AGENT_PORT}"
      }
    }
  }
}
```

**Restart Claude Code** to load the MCP server (it reads `.mcp.json` at
startup). The `play.py` CLI works immediately without any restart.

The MCP server resolves which game instance to drive in this order: the
`AGENT_PORT` env (set above from `$HYPE_AGENT_PORT`), then a gitignored
`tools/agent/.agent_port` pin file (written by `launch_agents.ps1`), then the
`24700` default. So a worktree pins its MCP target with **zero env setup** just
by running its launcher.

> Launcher note: on this machine `python` resolves to Python 3.12. If only `py`
> is available on yours, change `command` to `py` in `.mcp.json`.

## Parallel development across git worktrees

Each worktree is an independent checkout (own `.godot` import cache, own
`export/`, own `graphify-out/`), so **code editing in parallel needs nothing
special**. To also *run* instances from several worktrees at once without them
clashing, three things are made per-instance (all via `launch_agents.ps1`):

| Concern | Flag | Per-instance value |
| --- | --- | --- |
| Control port + `user://` saves + screenshots | `--agent-port N` | `N`, files suffixed `_N`, screenshots `agent/N/` |
| ENet game port + LAN discovery | `--net-port P` | game `P`, discovery `P+1` |
| Window-title identity | `--label L` | `Hype Raiders_<L> [a:N n:P]` |

The save dir is keyed by the project name (`Hype Raiders`) and so is **shared by
all worktrees** — the only separator is `--agent-port`, so give each worktree a
disjoint control-port range. The **net port can't be derived from the agent
port** (a co-op group's host + clients have different agent ports but must share
one net port), so it's a separate per-group/per-worktree flag.

Recommended convention (one row per worktree):

| Worktree / branch | `-BasePort` (control) | `-NetPort` | MCP targets |
| --- | --- | --- | --- |
| `v0.2` (main work) | `24700` (24700-24707) | `24565` | 24700 |
| `feat/foo` | `24710` (24710-24717) | `24665` | 24710 |
| `feat/bar` | `24720` (24720-24727) | `24765` | 24720 |

```powershell
# In worktree feat/foo:
./tools/agent/launch_agents.ps1 -Count 2 -Menu -BasePort 24710 -NetPort 24665
# -> windows titled "Hype Raiders_feat-foo ...", saves settings_24710.cfg etc.,
#    co-op hosts on 24665, and tools/agent/.agent_port pinned to 24710 so this
#    worktree's hype-game MCP drives instance 24710.
```

`-Label` defaults to the worktree's current git branch, so the window title
tells you which worktree/branch each running game belongs to.

## N-instance co-op recipe

This is the end-to-end flow for driving a full co-op lobby from MCP or play.py.
`-Count` accepts 1-8 (matches the game's `MAX_PLAYERS=8`).

```powershell
# 1. Launch N instances (menu mode so they boot to the lobby)
./tools/agent/launch_agents.ps1 -Count 4 -Menu -BasePort 24700 -NetPort 24565
# Wait ~8s for all instances to boot.

# 2. Discover which ports are alive and get their peer IDs
#    MCP: game_instances {base:24700, count:4}
python tools/agent/raw.py '{"cmd":"state"}' 24700   # check individually if needed

# 3. Host on the primary instance (port 24700)
python tools/agent/raw.py '{"cmd":"net","action":"host"}' 24700

# 4. Join on the remaining instances
python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"127.0.0.1"}' 24701
python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"127.0.0.1"}' 24702
python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"127.0.0.1"}' 24703

# 5. Ready up all clients (broadcast: host does not need to ready)
#    MCP: game_broadcast {cmd:{cmd:ready,on:true}, ports:[24701,24702,24703]}
python tools/agent/raw.py '{"cmd":"ready","on":true}' 24701
python tools/agent/raw.py '{"cmd":"ready","on":true}' 24702
python tools/agent/raw.py '{"cmd":"ready","on":true}' 24703

# 6. Leader deploys (triggers all peers simultaneously)
python tools/agent/raw.py '{"cmd":"deploy"}' 24700

# 7. Drive each instance independently by targeting its port
python tools/agent/play.py --port 24700 state
python tools/agent/play.py --port 24701 aim nearest
python tools/agent/play.py --port 24701 fire 0.3

# MCP equivalents (per-call port arg):
# game_state        {port: 24701}
# game_aim          {target: "nearest", port: 24702}
# game_broadcast    {cmd: {cmd: "godmode", on: true}, ports: [24700,24701,24702,24703]}
```

## Quick manual test (no game)

You can prove the wire format without the game by running a tiny mock server
that speaks the same protocol, then pointing `play.py ping` at it. See the
project task notes; the mock used during development was removed after
validation.
