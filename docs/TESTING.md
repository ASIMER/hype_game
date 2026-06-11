# Testing & Self-Play Harness — Hype Raiders

The game ships a **self-play harness** so Claude (or any script) can drive the game, read state, and capture screenshots — the primary way to verify gameplay. Implemented in `autoload/AgentBridge.gd`; driven by `tools/agent/play.py`.

## 1. How `--agent` mode works
Launch the game with `--agent`:
```
"C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe" --path "C:\personal\hype game" -- --agent
```
`main.gd._start_agent()` then: starts single-player (`NetworkManager.start_offline()` → `OfflineMultiplayerPeer`), loads the arena, calls `AgentBridge.activate()`, and **parks the window off-screen** (≈ −4000,−4000), borderless, no-focus, 640×360 — so it renders (for screenshots) but never disrupts the desktop. Run it in the background; it persists across turns.

`AgentBridge` opens a TCP server on `127.0.0.1:Settings.AGENT_PORT` (**24700**), newline-delimited JSON: send one object + `\n`, read one object + `\n`, close. Pass **`--agent-port N`** to bind a different port (for running several instances at once — see §7/§8).

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
| `render` | `id`, `name`=id | no (async reply) | **debug**: render a logical id's model in isolation → clean 3/4 hero-shot PNG (procedural-model + icon QA). Returns `{ok,path,debug}`; PNG → `agent\[<port>\]<name>.png` |
| `refill` | — | no | **debug**: top all of the local player's weapons back to full ammo |
| `grenade` | `type`=frag\|smoke\|emp\|decoy | no | **debug**: select + throw a grenade type via the REAL PlayerGear/server path (grants 1 if none carried). Returns `{ok,type,left}` |
| `gadget` | `type`=gadget_turret\|gadget_dome\|gadget_sensor | no | **debug**: force-place a deployable at the feet-forward ground point (grants 1 if none). Returns `{ok,type,left}` |
| `noise` | `loudness`=NOISE_GRENADE, `kind`=2 | no | **debug**: inject an AI-audible noise at the player — isolates noise→INVESTIGATE plumbing from weapon/grenade emission (kind 3 = decoy semantics: always investigate the point) |
| `clock` | `action`=set\|skip, `left` (sec, for set) | no | **debug**: drive the match timer. `set` → `match_time_left=left`; `skip` (default) → clamp to ≤2s (triggers the final storm wave). Returns `{ok,left,total}` |
| `navdbg` | — | no | **debug**: NavigationServer dump (`NavDebug.capture`) — nav maps (regions/agents/iteration), the arena region's bake state (`polygons`), `player_snap` (= `map_get_closest_point` at the player; the **origin means the map is empty** → ground enemies freeze at spawn), per-enemy agent `{reachable,path_len,finished}`. First check when enemies won't path |
| `mutator` | `id`=fog\|double_loot\|elite_patrols\|night_raid\|"" (optional), `clear`:bool | no | **debug** (batch C): force the raid mutator — `id` sets `NetworkManager.forced_mutator` (used by every FOLLOWING deploy) AND applies it immediately (fog/elite_patrols react live; double_loot/night_raid need a redeploy); `clear:true` returns to natural 35% rolls; no args = report. `state.meta.mutator` mirrors the active one |
| `door` | `action`=list\|give_key\|open, `id` (key id), `count`, `name` (door/annex filter) | no | **debug** (batch C): locked annex doors — `list` → `{doors:[{name,annex,key,opened,pos}]}`; `give_key` grants `id`×`count` to the LOCAL player's replicated `_keys`; `open` server-force-opens matching doors (no key). Day-night QA needs no verb: `clock set` drives the hour (`state.world{hour,night,mutator}`; start 10:00, +12h over the match; night ≥19.5 or <5.5 → enemy detect ×0.75). Players expose `flashlight`/`keys`/`flares`; zones expose `type`("paid"/"signal")+`override` in `state.extraction_zones[]` |
| `gear` | `action`=state\|equip\|repair\|drain, `slot`, `id`, `amount` | no | **debug** (batch B): worn armor — `equip` sets a profile slot (`""` unequips), `repair` spends credits, `drain` burns durability without combat; reply carries `{equipped,pieces,durability,carry_bonus,speed_mult}`. `state.meta.gear/armor_durability` mirror it |
| `secure` | `id`, `on`:bool (omit both = report) | no | **debug** (batch B): flag/unflag an in-raid stack as SECURED (survives death; ≤2 distinct ids, per-unit weight ≤2 kg). Owner-routed — works from a co-op client. `state.players[].secure` mirrors it |
| `status` | `action`=list\|apply\|clear\|use, `effect`=bleed\|fracture\|painkiller, `item`=bandage\|splint\|painkiller\|smart | no | **debug** (batch B): status effects on the LOCAL player — `apply`/`clear` force them, `use` consumes meds (`smart` = the H-key triage). `state.players[].status` lists active effects; `.meds` the counters |
| `insure` | `id` (insures it) \| `action`=mature\|state | no | **debug** (batch B): insurance — `id` buys coverage (30% of value), `mature` rewinds every pending return to NOW (the Hub's 30s poll then deposits them), `state` reports `{insured,pending}`. Death converts insured→pending (10 real min); extraction clears coverage |
| `stash` | `action`=…, `id`, `count`, `price`, `weapon`, `slot`, `perk` | no | **debug**: raid-economy / stash QA — see sub-action table below. Returns `{ok,stash,bring,blueprints}` |
| `net` | `action`=host\|join, `ip`="127.0.0.1" | no | **debug** (needs `--agent --menu`): host or join a co-op match; opens this peer's Hub. `host`→`NetworkManager.host_game()`; `join`→`join_game(ip)` then opens the client Hub on connect |
| `ready` | `on`:bool=true | no | **debug**: a co-op CLIENT readies/unreadies in the lobby (`set_ready` RPC to host/peer 1). Returns `{ok,ready}` |
| `deploy` | — | no | **debug**: trigger the Hub DEPLOY / leader START (`current_scene._on_hub_deploy()` — solo deploy or co-op synchronized start) |
| `transfer` | `from`=my peer, `to`=1, `id`, `count` | no | **debug**: server-auth co-op item give — move `{id,count}` from peer `from` to peer `to`. Returns `{ok,moved}` |
| `favorites` | `action`=add\|remove\|connect\|list, `name`, `ip`, `port`=`Settings.DEFAULT_PORT` | no | **debug**: drive the local server list (browser QA). Returns `{ok,favorites,recents}` |
| `discover` | `timeout`=1.5 (sec) | no (returns immediately) | **debug**: trigger a LAN scan; results land in `state.lan` after ~`timeout`. Returns `{ok,scanning,timeout}` |
| `ui` | `action`=… | no | **debug**: open/close a menu overlay for screenshot QA — see action list below |
| `setting` | `key`, `value` (optional) | no | **debug**: get (omit `value`) or set a `SettingsManager` value (verify apply+persist). Returns `{ok,value}` |
| `restart` | — | no | reload the match (`current_scene.restart_match()`) |
| `quit` | — | no | reply `{ok}` then exit the game |

`move`/`fire`/`goto` reply only after `duration` elapses — so measure velocity/effects *during*, or check position deltas across calls, not after the blocking call returns.

**`stash` sub-actions** (`action` field; all reply `{ok,stash,bring,blueprints}`):

| `action` | Params | Effect |
|---|---|---|
| `add` | `id`,`count` | `Stash.add(id,count)` |
| `remove` | `id`,`count` | `Stash.remove(id,count)` |
| `clear` | — | `Stash.clear()` |
| `bring` | `id`,`count` | set the bring-list entry (`count>0` sets, `0` erases) |
| `deploy` | — | `RaidManager.deploy()` — commit the bring-list (remove from stash) |
| `craft` | `id` (recipe id) | `Crafting.craft(recipe_by_id(id))` |
| `recycle` | `id` | `Crafting.recycle(id)` → materials |
| `learn` | `id` | `MetaProgression.learn_blueprint(id)` (simulate schematic/quest) |
| `claim` | `id` (quest id) | `Quests.claim(id)` |
| `give` | `id`,`count` | add an item to the local player's MATCH inventory (simulate found loot) |
| `currency` | `count` | `MetaProgression.earn(count)` — grant currency |
| `buy` | `id`,`price` | `Crafting.buy_blueprint(id,price)` |
| `questprog` | `id`,`count` | force `quest_progress[id]=count` + save |
| `equip` | `weapon`,`slot`,`id` | `MetaProgression.equip_attachment(weapon,slot,id)` |
| `unequip` | `weapon`,`slot` | `MetaProgression.unequip_attachment(weapon,slot)` |
| `perk` | `weapon`,`perk` | `MetaProgression.buy_weapon_perk(weapon,perk)` |
| `daily` | — | `Quests.get_daily_quests()` — trigger the daily rotation |

**`ui` actions** (`action` field): `open_settings`/`close_settings`, `open_servers`/`close_servers`, `open_pause`/`close_pause`, `open_workshop`, `open_map`/`close_map` (in-raid M map), `hub_stash`/`hub_loadout`/`hub_workshop`/`hub_shop`/`hub_quests`/`hub_gunsmith` (switch the open Hub's tab: 0/1/2/3/4/5). Returns `{ok:bool}` (false if the target node/scene isn't present).

## 3. `state` JSON schema
```jsonc
{
  "ok": true,
  "phase": 3,                 // GameState.Phase: 0 MENU,1 LOBBY,2 LOADING,3 IN_MATCH,4 RESULTS
  "wave": 2,
  "fps": 240,
  "result": "",               // "" | "won" | "lost"  (resets on restart/match_started)
  "extraction": {"active": false, "ratio": 0.0},
  "match_timer": {"left": 240.0, "total": 300.0, "final_wave": false},  // GameState match clock; final_wave=storm started
  "extraction_zones": [        // every evac zone w/ timed-window state (ExtractionDirector)
    {"name":"Evac_North","pos":[x,y,z],"open":true,"window_left":42.0}
  ],
  "meta": {                    // between-run MetaProgression / GameState snapshot
    "currency": 1200, "difficulty": 1, "difficulty_name": "Normal",
    "loadout": ["rifle","pistol"],          // deploy weapons
    "bring": {"medkit":2}, "blueprints": ["bp_smg"],
    "quests": {"q_kill_10":7}, "completed_quests": ["q_first"],
    "attachments": {"rifle":{"optic":"red_dot"}},   // equipped_attachments (weapon→slot→id, at-risk)
    "weapon_perks": {"rifle":{"recoil":2}},          // permanent
    "dailies": ["q_daily_a"], "last_reward": 150
  },
  "stash": [{"id":"loot_scrap","count":4}],   // persistent stash items (Stash.items)
  "stash_weight": 12.5, "stash_cap": 40.0,    // total_weight() / capacity()
  "players_count": 1,
  "peer_id": 1,                // GameState.local_peer_id() (1 = host/offline)
  "peers": [1],                // GameState.peers.keys()
  "peers_count": 1,            // GameState.peers.size()
  "favorites": [], "recents": [],            // ServerBrowser server-list entries
  "lan": [],                   // ServerBrowser.last_found — LAN scan results (after `discover`)
  "scoreboard": {"kills": 0, "deaths": 0, "mobs_killed": 0},  // per-match attribution
  "player": {
    "pos": [x,y,z], "rot_y": 0.0, "velocity": [x,y,z], "on_floor": true,
    "health": 100.0, "max_health": 100.0, "alive": true,
    "cam_yaw": 0.0, "cam_pitch": 0.0,
    "weapon": "rifle", "ammo": 30, "reserve": 180, "reloading": false,
    "ads": false, "shoulder": 1.0, "medkits": 2, "grenades": 3
  },                          // null if no local player (e.g. in menu/lobby)
  "inventory": [{"id":"loot_scrap","count":4,"weight":0.5}],
  "inv_weight": 2.0, "inv_value": 20,
  "enemies": [{"name":"RobotEnemy","id":"robot_wasp","pos":[x,y,z],"health":22.0,"state":1,"dist":25.3}],
  // enemy.state: 0 PATROL, 1 CHASE, 2 ATTACK
  "loot": [{"id":"loot_cell","count":1,"pos":[x,y,z],"dist":12.1}]
}
```
Screenshots save to `%APPDATA%\Godot\app_userdata\Hype Raiders\agent\<name>.png` → **Read** the PNG to view it. Under `--agent-port N` they go to `agent\<N>\<name>.png` (per-instance — see §8).

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

## 7. Co-op multi-instance testing (instances playing together)
> §8 ("Parallel testing") is about single-player **isolation** — N independent instances that don't talk to each other. **This** section is co-op **coordination** — N instances joined into one match.

Launch one instance per player, each in **menu** mode (so `net` can host/join) on its own control port:
```
"...win64.exe" --path "C:\personal\hype game" -- --agent --menu --agent-port 24700   # host
"...win64.exe" --path "C:\personal\hype game" -- --agent --menu --agent-port 24701   # client
# (or: pwsh tools/agent/launch_agents.ps1 -Count 2 -Menu   if the helper supports --menu)
```
Drive each instance by its port. `play.py` only knows the **base** verbs (`state`/`move`/`fire`/…); the co-op JSON commands (`net`/`ready`/`deploy`/`transfer`) must go through **`raw.py`**:
```
python tools/agent/raw.py '{"cmd":"net","action":"host"}' 24700
python tools/agent/play.py --port 24701 state           # base verbs still work per-port
```

### Host → join → ready → deploy sequence
```
# 1) host (peer 1) on 24700:
python tools/agent/raw.py '{"cmd":"net","action":"host"}' 24700
# 2) each client joins the host's IP (loopback here):
python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"127.0.0.1"}' 24701
#    → wait, then check both: state.peers_count == 2 on each instance.
# 3) each CLIENT readies up in the lobby:
python tools/agent/raw.py '{"cmd":"ready","on":true}' 24701
# 4) the HOST (leader) starts the raid (gated on all clients ready):
python tools/agent/raw.py '{"cmd":"deploy"}' 24700
# 5) verify all spawned: each instance's state.players_count == N, with DISTINCT player.pos.
```

### Co-op checks worth running
Server-authoritative gameplay — the host (peer 1) is the simulation; clients are mirrored. Assert across instances:
- **Owner loot mirror** — a CLIENT walks onto loot + `act interact` → the item appears in **THAT client's** `state.inventory` (server→owner mirror), not the host's.
- **Authoritative damage** — a CLIENT `aim`+`fire`s an enemy → on the **HOST**, that enemy's `state.enemies[…].health` drops and it dies for **all** peers (no client-side desync HP).
- **Kill attribution** — after a client kill, `state.scoreboard` (`kills`/`mobs_killed`) is **identical on every instance** and credited correctly.
- **Item give / split / trade** — `python tools/agent/raw.py '{"cmd":"transfer","from":<peerA>,"to":<peerB>,"id":"loot_scrap","count":2}' <port>` → A's inventory shrinks, B's grows (server-auth `NetworkManager.transfer_item`). `from` defaults to the sending instance's peer, `to` defaults to 1.
- **Mid-raid disconnect** — `python tools/agent/play.py --port 24701 quit` one client mid-match → the host frees that body cleanly (no deadlock/stall); remaining instances keep running, `state.players_count` drops.

### LAN discovery test
```
python tools/agent/raw.py '{"cmd":"net","action":"host"}' 24700     # host advertises on the LAN
python tools/agent/raw.py '{"cmd":"discover","timeout":1.5}' 24701  # other instance scans (returns immediately)
# wait ~2s for the scan to finish, then:
python tools/agent/play.py --port 24701 state                       # read state.lan
# → should list the host: {name, ip, players, max}.
```

### WAN / hairpin test
Have a client `net join` the host's **external** IP instead of loopback:
```
python tools/agent/raw.py '{"cmd":"net","action":"join","ip":"<EXTERNAL_IP>"}' 24701
```
This exercises the same path a remote friend uses — it requires **port-forward UDP 24565** to the host + a firewall allow. Confirm `state.peers_count == 2` and a full `deploy`/spawn. **Caveat:** a successful *hairpin* (joining your own external IP from the same network) proves port-forward + firewall are OK, but NAT hairpinning is router-dependent — only a real external friend is 100% conclusive.

### Per-instance save isolation
Each port namespaces all `user://` writes (`Settings.user_path` / `instance_tag`): saves at
`%APPDATA%\Godot\app_userdata\Hype Raiders\{profile,stash,favorites}_<port>.cfg` (and `settings_<port>.cfg`), screenshots under `agent\<port>\`. So each co-op peer keeps its **own** stash/loadout/favorites — exactly the per-player economy the game ships.

## 8. Parallel testing (2–4 instances at once)
> Single-player **isolation** (independent instances). For instances playing **together**, see §7 (co-op).

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
