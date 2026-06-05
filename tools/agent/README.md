# hype-game agent harness

Tools for driving the Godot game programmatically so an LLM (or a script) can
play it via self-play. Two entry points share one wire protocol:

- `play.py` — a stdlib CLI / importable client for one-off commands.
- `mcp_server.py` — a stdlib MCP server exposing the same actions as MCP tools.

Everything is stdlib-only (no `pip install`).

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
| `{"cmd":"aim","target":"nearest"\|<enemy_name>}` | `{"ok":bool}` — points the camera exactly at an enemy (engine-side math). Use before `fire` |
| `{"cmd":"goto","x":f,"z":f,"duration":f}` | replies **after** `duration` — faces world XZ point and walks forward toward it |
| `{"cmd":"act","action":"jump\|interact\|reload\|toggle_inventory"}` | `{"ok":true}` |
| `{"cmd":"screenshot","name":"str"}` | `{"ok":true,"path":"<absolute png path>"}` |
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

```
python tools/agent/play.py ping
python tools/agent/play.py state            # pretty JSON
python tools/agent/play.py state --raw      # compact JSON
python tools/agent/play.py move 1 0 0.5     # strafe right, 0.5s
python tools/agent/play.py move 0 1 0.8     # forward, 0.8s
python tools/agent/play.py look 0.1 -0.2    # yaw +0.1, pitch -0.2 (radians)
python tools/agent/play.py aim              # aim at nearest enemy (default)
python tools/agent/play.py aim Grunt_3      # aim at a named enemy
python tools/agent/play.py goto 24 0 1.0    # face world XZ (24,0) and walk 1.0s
python tools/agent/play.py fire 0.3
python tools/agent/play.py sprint on
python tools/agent/play.py sprint off
python tools/agent/play.py act jump
python tools/agent/play.py act interact
python tools/agent/play.py act reload
python tools/agent/play.py act toggle_inventory
python tools/agent/play.py shot myshot      # prints ONLY the absolute path
python tools/agent/play.py quit
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

```
$png = python tools/agent/play.py shot frame1
```

### Importable

```python
from play import send
resp = send({"cmd": "state"})          # dict in, dict out
resp = send({"cmd": "move", "x": 1, "y": 0, "duration": 0.5})
```

`send(cmd, host=..., port=..., timeout=...)` raises `AgentError` if the server
is unreachable or replies malformed; timeout auto-derives from `duration`.

## MCP server

`mcp_server.py` is a JSON-RPC 2.0 server over stdio implementing the MCP slice
needed by a client: `initialize` (protocolVersion `2024-11-05`), `tools/list`,
`tools/call`, and the `notifications/initialized` notification. It reuses
`play.py`'s `send()`, so it talks the same TCP protocol. Logs go to **stderr**;
stdout carries only JSON-RPC.

Tools exposed:

| Tool | Arguments |
| --- | --- |
| `game_state` | — |
| `game_move` | `x`, `y`, `duration` |
| `game_look` | `dx`, `dy` |
| `game_aim` | `target` (`"nearest"` or enemy name; defaults to `"nearest"`) |
| `game_goto` | `x`, `z`, `duration` (defaults to 0.5) |
| `game_fire` | `duration` |
| `game_sprint` | `on` (bool) |
| `game_act` | `action` (`jump`/`interact`/`reload`/`toggle_inventory`) |
| `game_screenshot` | `name` → returns the PNG path |

Each tool returns MCP content `[{"type":"text","text": <json-or-path>}]`. If the
game is not running, the call returns `isError:true` with an explanatory message
(it does not crash the server).

### Registration

`.mcp.json` at the project root registers it:

```json
{
  "mcpServers": {
    "hype-game": {
      "command": "python",
      "args": ["tools/agent/mcp_server.py"]
    }
  }
}
```

**Restart Claude Code** to load the MCP server (it reads `.mcp.json` at
startup). The `play.py` CLI works immediately without any restart.

> Launcher note: on this machine `python` resolves to Python 3.12. If only `py`
> is available on yours, change `command` to `py` in `.mcp.json`.

## Quick manual test (no game)

You can prove the wire format without the game by running a tiny mock server
that speaks the same protocol, then pointing `play.py ping` at it. See the
project task notes; the mock used during development was removed after
validation.
