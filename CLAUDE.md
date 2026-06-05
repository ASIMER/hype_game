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
5. Debug hooks for QA: `spawn <grunt|tick|heavy|wasp|bastion|boss>`, `tp`, `godmode`, `restart`, `ui open_workshop`; `state.meta` exposes currency/difficulty/loadout. Profile lives at `%APPDATA%\Godot\app_userdata\Hype Raiders\profile.cfg`.
6. Full protocol + `state` schema: **`docs/TESTING.md`**.

---

## Architecture at a glance
Systems are **decoupled through autoloads** — they emit/listen on the `Events` bus and read shared data, never referencing each other directly:
- **`Events`** — global signal bus (combat, weapons, loot, extraction, waves, net).
- **`Settings`** — all tunables (player/camera/ADS, enemy `ENEMY_STATS` table, waves, gadgets, `difficulty_mods()`).
- **`AssetRegistry`** — logical id → CC0 model *or* tinted primitive fallback (game always runnable).
- **`GameState`** — match phase, wave, peer roster, win/lose resolution, `difficulty` (Easy/Normal/Hard).
- **`MetaProgression`** — persistent between-run profile (`user://profile.cfg`): currency (earned at extraction), weapon unlocks, permanent upgrades, deploy loadout. `player_mods()` (health/reload/stamina/damage) is read by player.gd + weapon_controller at match start. Surfaced by the **Workshop** hub (`scenes/ui/Workshop.tscn`, shown SINGLE PLAYER → DEPLOY).
- **`NetworkManager`** — listen-server host/join, lobby handshake, match-end broadcast.
- **`AudioManager`** — SFX off the Events bus. **`AgentBridge`** — the self-play control server.

Authority/offline model: single-player uses an **`OfflineMultiplayerPeer`** (NOT a null peer) so `is_multiplayer_authority()`/`is_server()` pass locally; the same authority-gated code runs in single-player and co-op. Player authority is derived from the node name (`str(peer_id)`) in `_enter_tree`.

File map: `autoload/` (9 singletons) · `scenes/` (boot, world, player, enemies, combat, items, fx, ui) · `scripts/` (mirrors scenes by system) · `resources/` (`weapons/*.tres`, `items/*.tres`) · `assets/` (CC0 models/audio, optional) · `tools/agent/` (play.py + MCP).

## Top conventions & gotchas
1. **Single-player needs `OfflineMultiplayerPeer`** — without it, authority checks return false and the player/AI freeze.
2. **Camera body-yaw coupling**: each frame `rotation.y += camera_pivot.rotation.y; camera_pivot.rotation.y = 0` (CameraPivot is a child of the body, so its yaw is local — assigning directly would double-count).
3. **Weapons fire via a converged two-stage raycast**: ray from the *camera* finds the crosshair point, then the shot fires from the *chest* toward it (bullets follow the crosshair; the spring-arm camera never shoots the player's own legs).
4. **Weapon view-model is reparented** from under the camera to `Player/WeaponMount` (hand height) so it's held in third-person, not stuck at the lens.
5. **AssetRegistry primitive fallback** + per-asset `model_scale`/`model_rot_deg`/`model_offset` — never hardcode models in scenes; collision/hitboxes are tied to capsule sizes, not art.
6. **`Settings.NET_DEBUG`** gates the `[net]/[arena]` diagnostic prints (off by default).
7. **One scene = one owner.** `.tscn` files merge poorly. `project.godot` and `Arena.tscn` are single-owner.
8. **Before parallel work**, add new input actions / `Events` signals / `Settings` constants / `AssetRegistry` ids FIRST, so agents code against stable interfaces. See `docs/AGENT_TEAMS.md`.

## Parallel work with agent teams
Big features were built by a team named **`arc-raiders`**: the **lead owns the shared "spine"** (project.godot, autoloads, player.gd, Player.tscn, HUD, integration, the harness) and integrates; each agent owns **one isolated lane** (new files + at most one existing script) so no two agents touch the same file. Pattern: **frozen foundation → parallel isolated workstreams → integrate at single wiring points → play-test via the harness → optional read-only review pass.** Full role list, file lanes, and spawn recipe: **`docs/AGENT_TEAMS.md`**.
