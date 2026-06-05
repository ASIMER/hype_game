# Testing & Self-Play Harness — Hype Raiders

The game ships a **self-play harness** so Claude (or any script) can drive the game, read state, and capture screenshots — the primary way to verify gameplay. Implemented in `autoload/AgentBridge.gd`; driven by `tools/agent/play.py`.

## 1. How `--agent` mode works
Launch the game with `--agent`:
```
"C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe" --path "C:\personal\hype game" -- --agent
```
`main.gd._start_agent()` then: starts single-player (`NetworkManager.start_offline()` → `OfflineMultiplayerPeer`), loads the arena, calls `AgentBridge.activate()`, and **parks the window off-screen** (≈ −4000,−4000), borderless, no-focus, 640×360 — so it renders (for screenshots) but never disrupts the desktop. Run it in the background; it persists across turns.

`AgentBridge` opens a TCP server on `127.0.0.1:Settings.AGENT_PORT` (**24700**), newline-delimited JSON: send one object + `\n`, read one object + `\n`, close. Pass **`--agent-port N`** to bind a different port (for running several instances at once — see §6).

## 2. Command protocol
| Command | Params | Blocking? | Effect |
|---|---|---|---|
| `ping` | — | no | `{ok:true,agent:true}` |
| `state` | — | no | full snapshot (§3) |
| `move` | `x`[-1..1], `y`[-1..1], `duration` | **yes** (holds, then auto-stops) | x=strafe(right+), y=forward(+)/back(−) |
| `look` | `dx`,`dy` (radians) | no | accumulate camera yaw/pitch delta |
| `aim` | `target`="nearest"\|enemy name | no | exact engine-side aim at the enemy's torso (camera + body yaw + spring pitch) |
| `fire` | `duration` | **yes** | hold fire for duration |
| `sprint` | `on`:bool | no | toggle sprint |
| `ads` | `on`:bool | no | toggle aim-down-sights |
| `goto` | `x`,`z` (world), `duration` | **yes** | face the point and walk forward (straight-line; not pathfound — buildings can block) |
| `act` | `action`=jump\|interact\|reload\|toggle_inventory\|shoulder_swap\|grenade\|heal\|weapon_1..5\|weapon_next\|weapon_prev | no | injects a one-shot `InputEventAction` |
| `spawn` | `id`=grunt\|tick\|heavy\|wasp\|bastion\|boss, `dist` | no | **debug**: spawn an enemy archetype ahead of the player |
| `tp` | `x`,`y`,`z` | no | **debug**: teleport the player (reach far test spots) |
| `godmode` | `on`:bool | no | **debug**: toggle player invulnerability (`Health.invulnerable`) |
| `screenshot` | `name` | no (async reply) | render a frame, save PNG, return `{ok,path}` |
| `restart` | — | no | reload the match (`Main.restart_match()`) |
| `quit` | — | no | exit the game |

`move`/`fire`/`goto` reply only after `duration` elapses — so measure velocity/effects *during*, or check position deltas across calls, not after the blocking call returns.

## 3. `state` JSON schema
```jsonc
{
  "ok": true,
  "phase": 3,                 // GameState.Phase: 0 MENU,1 LOBBY,2 LOADING,3 IN_MATCH,4 RESULTS
  "wave": 2,
  "fps": 240,
  "result": "",               // "" | "won" | "lost"  (resets on restart/match_started)
  "extraction": {"active": false, "ratio": 0.0},
  "players_count": 1,
  "player": {
    "pos": [x,y,z], "rot_y": 0.0, "velocity": [x,y,z], "on_floor": true,
    "health": 100.0, "max_health": 100.0, "alive": true,
    "cam_yaw": 0.0, "cam_pitch": 0.0,
    "weapon": "rifle", "ammo": 30, "reserve": 180, "reloading": false,
    "ads": false, "shoulder": 1.0, "medkits": 2, "grenades": 3
  },
  "inventory": [{"id":"loot_scrap","count":4,"weight":0.5}],
  "inv_weight": 2.0, "inv_value": 20,
  "enemies": [{"name":"RobotEnemy","id":"robot_wasp","pos":[x,y,z],"health":22.0,"state":1,"dist":25.3}],
  // enemy.state: 0 PATROL, 1 CHASE, 2 ATTACK
  "loot": [{"id":"loot_cell","count":1,"pos":[x,y,z],"dist":12.1}]
}
```
Screenshots save to `%APPDATA%\Godot\app_userdata\Hype Raiders\agent\<name>.png` → **Read** the PNG to view it. Under `--agent-port N` they go to `agent\<N>\<name>.png` (per-instance — see §6).

## 4. Driving it
- **CLI**: `python tools/agent/play.py <subcommand>` — `ping`, `state [--raw]`, `move x y [dur]`, `look dx dy`, `aim [target]`, `fire [dur]`, `sprint on|off`, `ads on|off` (if exposed), `goto x z [dur]`, `act <action>`, `shot <name>` (prints PNG path), `quit`. (Debug `spawn/tp/godmode` are sent via the importable `send()` — `from play import send; send({"cmd":"spawn","id":"boss"})`.)
- **Importable**: `import sys; sys.path.insert(0,"tools/agent"); from play import send; send({"cmd":"state"})`.
- **MCP wrapper**: `tools/agent/mcp_server.py` + `.mcp.json` expose `game_state/game_move/game_aim/game_fire/game_goto/game_screenshot` as MCP tools — **requires a Claude Code restart** to load; the CLI works without one.

## 5. Validation commands (run after every change)
```
CONSOLE="C:/Users/illya/Desktop/godot/Godot_v4.6.3-stable_win64_console.exe"
# Import/parse — must be clean (ignore "Unreferenced static string"/"Thread object"/"UVs are required" shutdown noise):
"$CONSOLE" --headless --path "C:\personal\hype game" --import 2>&1 | grep -iE "error|parse|script error"
# Server smoke (full match, no script errors):
timeout 12 "$CONSOLE" --headless -- --server 2>&1 | grep -iE "script error|null instance"
# Two-process co-op: run one "--server" + one "--client 127.0.0.1"; neither log should show script/RPC errors.
```

## 6. QA workflow (test matrix)
Drive the harness through these categories, asserting on `state` and reading screenshots; fix bugs as found, re-verify, then a final co-op smoke:
1. **Movement/camera** — WASD (not inverted), sprint/jump, ADS zoom + per-weapon FOV, shoulder-swap (state.player.shoulder flips), peek/lean at a building edge.
2. **Weapons** — switch 1-5 (state.weapon/ammo), semi-vs-auto, manual + auto reload, switch resets cooldown.
3. **Enemies** — `spawn` each archetype; Wasp hovers (pos.y>2), separation (distinct positions), hunter aggro (distances shrink while idle), ranged enemies lethal (no shooting through walls).
4. **Feedback** — damage numbers, HP bars, hit-flash, ragdoll debris.
5. **Loot/inventory** — kill → loot drops → interact → inventory grows; inventory UI renders.
6. **Extraction/waves/flow** — `tp` onto a zone → ratio→1.0 → WIN; death → `result:"lost"` → `restart`.
7. **Gadgets** — grenade (count drops, explosion), heal (HP up, medkit count down).
8. **HUD** — ammo/key-hints on-screen at 640×360 AND 1280×720, crosshair/minimap/banners.
9. **Menu** loads clean; **co-op** two-process smoke clean; **stability** (fps + zero errors over a run).

Debug hooks (`spawn`, `tp`, `godmode`, `restart`, `refill`) exist purely for QA — they let you verify any archetype, reach far zones, and survive while inspecting.

## 7. Parallel testing (2–4 instances at once)
Each agent can drive its **own** game instance — the control port and every shared `user://` write are namespaced per instance (via `Settings.user_path` / `Settings.instance_tag`, set from `--agent-port`).

Launch N instances (ports **24700 + i**):
```
# helper (Windows): launches Count instances, prints each PID + port
pwsh tools/agent/launch_agents.ps1 -Count 3
# or by hand, one per instance:
"...win64.exe" --path "<proj-or-worktree>" -- --agent --agent-port 24701
```
Drive a specific instance by its port (`play.py` already supports `--port`):
```
python tools/agent/play.py --port 24701 state
python tools/agent/play.py --port 24701 shot frameA      # → agent\24701\frameA.png
```
Per-instance isolation:
- control server → `127.0.0.1:<port>`
- screenshots → `user://agent/<port>/`
- profile / settings → `user://profile_<port>.cfg` / `settings_<port>.cfg`

Notes:
- **No `--agent-port` flag → unchanged single-instance behaviour** (port 24700, plain `user://agent/`, `profile.cfg`).
- The MCP wrapper targets `127.0.0.1:$AGENT_PORT` (env var, default 24700) — set `AGENT_PORT` per MCP instance.
- Several instances from the **same folder** is fine for test-only (runtime is read-only on the `.godot` cache). Agents that **edit code** concurrently should each get their own **git worktree** (separate checkout + `.godot`) — see `docs/AGENT_TEAMS.md`.
