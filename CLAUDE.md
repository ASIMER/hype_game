# Hype Raiders — Project Guide (read me first)

**Hype Raiders** is an Arc Raiders-style **co-op third-person extraction shooter** vertical slice built in **Godot 4.6.3 stable**. Scavenge a hostile 160×160 urban-ruins map full of AI robots, survive escalating waves (incl. a boss), and reach an extraction zone alive — solo or in up-to-4 co-op. It runs **with zero art assets** (every model falls back to a tinted primitive via `AssetRegistry`).

This file is the always-loaded index. Depth lives in `docs/`:
- **`docs/ARCHITECTURE.md`** — autoloads, Events bus, Settings, physics layers, scene trees, every gameplay system.
- **`docs/TESTING.md`** — the self-play test harness (how Claude plays/screenshots the game) + QA workflow.
- **`docs/AGENT_TEAMS.md`** — the expected `agent_teams` team structure & ownership model for parallel work.

---

## Run / test / validate (most important for a new session)

Godot exe (Windows): `C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64.exe`
Console/headless variant: `C:\Users\illya\Desktop\godot\Godot_v4.6.3-stable_win64_console.exe`
Project dir: `C:\personal\hype game`

Launch modes (pass flags after `--`):
```
# Play with the menu (Single Player / Host / Join):
& "...win64.exe" --path "C:\personal\hype game"
# Dedicated/host headless server:        ... --headless -- --server
# Client joining a host:                 ... -- --client 127.0.0.1
# SELF-PLAY (Claude drives it, off-screen): ... -- --agent      (see docs/TESTING.md)
```

Validate after any change (always do this):
```
# 1) Import / parse check — MUST be clean (ignore "Unreferenced static string" / "Thread object" / "UVs are required" shutdown noise):
"...win64_console.exe" --headless --path "C:\personal\hype game" --import 2>&1 | grep -iE "error|parse|script error"
# 2) Server smoke (no script errors during a real match):
timeout 12 "...win64_console.exe" --headless -- --server
# 3) Two-process co-op smoke (one --server, one --client 127.0.0.1) — no script/RPC errors on either side.
```

## Self-play harness in 6 lines (how to actually test gameplay)
1. Launch `--agent` in the background → boots single-player, parks the window off-screen/no-focus, opens a TCP control server on `127.0.0.1:24700`. Add `--agent-port N` to run **multiple instances at once** (per-port control + screenshots + saves — `docs/TESTING.md` §7; `tools/agent/launch_agents.ps1`).
2. Drive it with `python tools/agent/play.py <cmd>` — e.g. `state`, `move 0 1 0.5`, `aim`, `fire 0.3`, `goto <x> <z>`, `act reload`, `spawn boss`, `godmode on`, `tp <x> <z>`.
3. `python tools/agent/play.py screenshot foo` saves a PNG to `%APPDATA%\Godot\app_userdata\Hype Raiders\agent\foo.png` — then **Read** that PNG to see the game.
4. `play.py state` returns full JSON (player pos/health/weapon/ammo/ads, enemies w/ archetype+state, loot, extraction, wave, result).
5. Debug hooks for QA: `spawn`/`tp`/`godmode`/`restart`/`refill`/`render` (`{cmd:render, id, name}` → saves a clean isolated 3/4 render of any id's model to `agent/<name>.png` — the way to QA procedural models/icons, since the third-person camera makes in-world close-ups useless); `ui open_workshop|hub_stash|hub_loadout|hub_workshop|hub_shop|hub_quests|hub_gunsmith` (Lobby tabs); `stash {add|remove|bring|deploy|clear|craft|recycle|learn|buy|claim|give|currency|questprog | equip(weapon,slot,id)|unequip(weapon,slot)|perk(weapon,perk)|daily, id, count[, price]}`; `ui open_map|close_map` (the M-key Tactical Map); `clock {action:set,left:<s> | action:skip}` (drives the match timer — `skip` jumps to ~2s left to trigger the final storm wave); co-op from `--agent --menu`: `net {host|join, ip}` + `deploy`. `state.meta` exposes currency/difficulty/loadout/bring/blueprints/quests + `attachments`/`weapon_perks`/`dailies`; `state.stash` the persistent items; top-level `stash_weight`/`stash_cap`; `state.match_timer{left,total,final_wave}` + `state.extraction_zones[]{name,pos,open,window_left}`. play.py only knows the base verbs — drive the `ui`/`stash`/`net` JSON commands with **`python tools/agent/raw.py '{"cmd":...}'`**. Saves at `%APPDATA%\Godot\app_userdata\Hype Raiders\{profile,stash}[_<port>].cfg`.
6. Full protocol + `state` schema: **`docs/TESTING.md`**.

---

## Architecture at a glance
Systems are **decoupled through autoloads** — they emit/listen on the `Events` bus and read shared data, never referencing each other directly:
- **`Events`** — global signal bus (combat, weapons, loot, extraction, waves, net).
- **`Settings`** — all tunables (player/camera/ADS, enemy `ENEMY_STATS` table, waves, gadgets, `difficulty_mods()`).
- **`AssetRegistry`** — logical id → visual. Resolution order: real `.glb` → **`ProceduralModels.build(id)`** (rich multi-part meshes assembled in code: distinct enemy silhouettes + real item shapes, `scripts/visual/procedural_models.gd`) → CATALOG `parts` → tinted single primitive (game always runnable). `.glb` WINS over a builder — clear an id's `"model"` to use its procedural model. `get_icon` returns an authored PNG (weapons) else falls back to **`IconRenderer`**.
- **`IconRenderer`** — renders any id's 3D model to a transparent texture (off-screen SubViewport) for inventory icons; cache filled by a startup pre-warm so the UI `get_icon` is a sync cache hit (headless → null → UI colored box). Also the model-QA tool: AgentBridge `render` command saves a clean hero shot PNG (see harness). Procedural-model + SubViewport gotchas live in the `procedural-visual-harness` memory.
- **`GameState`** — match phase, wave, peer roster, win/lose resolution, `difficulty` (Easy/Normal/Hard).
- **`MetaProgression`** — persistent between-run profile (`user://profile.cfg`): currency, weapon unlocks, permanent upgrades (incl. **Stash Expansion** → `stash_capacity()`), deploy loadout (weapons) + `bring` (consumable bring-list), **`equipped_attachments`** (`weapon→{slot→att_id}`, at-risk) + **`weapon_perks`** (`weapon→{perk→level}`, permanent, `WEAPON_PERKS`) + daily-contract state (`last_daily_date`/`daily_quest_ids`). `player_mods()` read by player.gd + weapon_controller at match start; `reconcile_attachments()` unequips any attachment no longer in the stash (called on Hub open, after a loss eats it).
- **`ItemCatalog`** — scans `resources/items/*.tres` → `id → ItemData` (shared by loot / stash / loadout / craft).
- **`Stash`** — the **persistent item stash** (`user://stash.cfg`, per-instance via `Settings.user_path`): what you extract is kept here as real items; the at-risk economy (materials/consumables/valuables/**attachments** — weapons stay permanent unlocks). Has a **hard weight cap** (`total_weight()`/`capacity()` = `MetaProgression.stash_capacity()`); a deposit over cap fires `Events.haul_overflow` → the **Manage-Your-Haul** screen (`scenes/ui/HaulManager.tscn`, instanced by `main.gd`: sell/recycle/drop until under cap). Surfaced by the **Lobby/Hub** (`scenes/ui/Hub.tscn`: STASH / LOADOUT / WORKSHOP / SHOP / QUESTS / **GUNSMITH** tabs — GUNSMITH equips at-risk attachments + buys permanent perks).
- **World & match loop** — `scenes/world/Arena.tscn`+`arena.gd` swap the old cube POIs for **procedural modular buildings** (`scripts/visual/procedural_buildings.gd`, themed per POI, spawned at the POI markers *before* the runtime navmesh bake; courtyards left clear around the 3 extraction zones) over a textured ground + atmospheric sky (`resources/default_env.tres`). **Match timer**: `wave_manager.gd` counts `GameState.match_time_left` down from `Settings.MATCH_DURATION`; at 0 it sets `GameState.final_wave` and floods a **final "storm" wave** (interrupts the current wave, raises the alive-cap to `FINAL_WAVE_CONCURRENT`) forcing extraction. The 5 gradual waves are unchanged before it. **`ExtractionDirector`** autoload rotates per-zone **timed windows** (`extraction_zone.is_open()/window_remaining()/set_window()`; only an OPEN zone makes progress; all forced open during the storm). The **'M' Tactical Map** (`scenes/ui/MapUI.tscn`) shows POIs (zones of interest), every evac zone w/ open/closed + countdown, the player, enemies, and the match clock; the minimap mirrors window state; HUD shows the timer + storm banner. **Combat**: shots now have **bullet drop** (`weapon.gd` stepped ballistic raycast under `Settings.BULLET_GRAVITY`/`BULLET_MUZZLE_VELOCITY`, tracer follows the arc), punchier impact FX + enemy stagger, and a crosshair **hit-marker** (`scripts/ui/hit_marker.gd`). The **player model rotates smoothly** with the camera (body yaw is applied at render rate in `player.gd`, not deferred to the 60Hz physics tick).
- **`RaidManager`** — the per-player raid economy: `deploy()` commits the bring-list **and the loadout weapons' equipped attachments** (pulls them from the local stash, now at risk — `_committed_attachments`); `grant_extraction()` deposits a peer's haul + surviving attachments into ITS OWN stash on extract (host-local or via RPC to a client) + learns blueprints from extracted schematics, then fires `haul_overflow` if over the weight cap. **Death deposits nothing → gear + attachments lost. Extract → kept (attachments stay equipped).** Each co-op player keeps its own stash on its own machine.
- **`Crafting`** — data-driven recipes (scans `resources/recipes/*.tres` = `CraftRecipe`): `craft(r)` (inputs+currency → output), blueprint gating (`recipe_unlocked`), `recycle(id)` (item → materials), `buy_blueprint()`. Blueprints (`MetaProgression.unlocked_blueprints`) are learned 3 ways: extract a schematic (`learn_item`), buy in the SHOP, or a quest reward.
- **`Quests`** — data-driven contracts (scans `resources/quests/*.tres` = `QuestData`): advances `MetaProgression.quest_progress` from the Events bus (kill / extract / extract_item / reach_wave / pickup), `claim()` grants the reward once. **Daily contracts** (`QuestData.daily`): `get_daily_quests()` rotates a subset (`DAILY_COUNT`) once per real day keyed by `Time.get_date_dict_from_system()` (resets their progress, fires `dailies_rotated`); `standing()` = the non-daily contracts. The QUESTS tab shows a DAILY section above STANDING. A post-raid **`RaidSummary`** screen shows the haul + blueprints/quests and routes **Continue → back to the Hub** (→ Manage-Your-Haul if over cap).
- **`NetworkManager`** — listen-server host/join, lobby handshake (the **Hub IS the lobby**: DEPLOY = `notify_loaded`/ready), match-end broadcast.
- **`AudioManager`** — SFX off the Events bus. **`AgentBridge`** — the self-play control server.

Authority/offline model: single-player uses an **`OfflineMultiplayerPeer`** (NOT a null peer) so `is_multiplayer_authority()`/`is_server()` pass locally; the same authority-gated code runs in single-player and co-op. Player authority is derived from the node name (`str(peer_id)`) in `_enter_tree`.

File map: `autoload/` (16 singletons; visuals via `AssetRegistry`+`IconRenderer` + `scripts/visual/procedural_models.gd` (models) + `procedural_buildings.gd` (world structures); **`ExtractionDirector`** rotates timed evac windows) · `scenes/` (boot, world, player, enemies, combat, items, fx, ui incl. `ui/Hub.tscn` + `ui/tabs/*` + `ui/RaidSummary.tscn`) · `scripts/` (mirrors scenes by system; + `crafting/`, `quests/`) · `resources/` (`weapons/*.tres`, `items/*.tres`, `recipes/*.tres`, `quests/*.tres`, `attachments/*.tres` = `AttachmentData extends ItemData`) · `assets/` (CC0 models/audio, optional) · `tools/agent/` (play.py + `raw.py` raw-JSON sender + MCP).

## Top conventions & gotchas
1. **Single-player needs `OfflineMultiplayerPeer`** — without it, authority checks return false and the player/AI freeze.
2. **Camera body-yaw coupling**: each frame `rotation.y += camera_pivot.rotation.y; camera_pivot.rotation.y = 0` (CameraPivot is a child of the body, so its yaw is local — assigning directly would double-count).
3. **Weapons fire via a converged two-stage raycast**: ray from the *camera* finds the crosshair point, then the shot fires from the *chest* toward it (bullets follow the crosshair; the spring-arm camera never shoots the player's own legs).
4. **Weapon view-model is reparented** from under the camera to `Player/WeaponMount` (hand height) so it's held in third-person, not stuck at the lens.
5. **AssetRegistry primitive fallback** + per-asset `model_scale`/`model_rot_deg`/`model_offset` — never hardcode models in scenes; collision/hitboxes are tied to capsule sizes, not art.
6. **`Settings.NET_DEBUG`** gates the `[net]/[arena]` diagnostic prints (off by default).
7. **One scene = one owner.** `.tscn` files merge poorly. `project.godot` and `Arena.tscn` are single-owner.
8. **Before parallel work**, add new input actions / `Events` signals / `Settings` constants / `AssetRegistry` ids FIRST, so agents code against stable interfaces. See `docs/AGENT_TEAMS.md`.
9. **`weapon_controller._load_weapons()` is the one place weapon stats are computed**: it duplicates each `WeaponData` then layers, in order, difficulty + `player_mods` mults → permanent weapon **perks** → equipped **attachments** (read locally from `MetaProgression`, so co-op is correctly per-peer). Mods are multiplicative on the dup, never on the source `.tres`. Add new gun modifiers here.
10. **Warnings-are-errors parse trap**: `var x := <Variant>` (e.g. `dict.get(...)`, an untyped ternary) fails to parse with "inferred from Variant". Use an explicit type (`var x: int = ...`). `--headless --import` does **not** catch lazy parse errors inside tab scripts — runtime-smoke by opening the Hub (`ui open_workshop` + each `hub_*`) to surface them.

## Parallel work with agent teams
Big features were built by a team named **`arc-raiders`**: the **lead owns the shared "spine"** (project.godot, autoloads, player.gd, Player.tscn, HUD, integration, the harness) and integrates; each agent owns **one isolated lane** (new files + at most one existing script) so no two agents touch the same file. Pattern: **frozen foundation → parallel isolated workstreams → integrate at single wiring points → play-test via the harness → optional read-only review pass.** Full role list, file lanes, and spawn recipe: **`docs/AGENT_TEAMS.md`**.
