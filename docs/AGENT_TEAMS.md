# Agent Teams — Expected Structure & Ownership

How to parallelize substantial work on this project with `agent_teams` without merge conflicts. This is the model that actually built the game across multiple sessions.

## Team
- **Team name**: `arc-raiders` (created with `TeamCreate({team_name:"arc-raiders"})`). One shared task list.
- **Lead**: `team-lead` (you, the main loop) — owns the shared **spine** and integrates everyone's work.

## The core rule: spine vs lanes (no two agents edit the same file)
Many features touch the same hub files, so:
- **Lead owns the "spine"** and is the only one who edits it: `project.godot` (input map), all `autoload/*.gd` (`Events`, `Settings`, `AssetRegistry`, `GameState`, `NetworkManager`, `AudioManager` autoload line, `AgentBridge`), `scripts/player/player.gd`, `scenes/player/Player.tscn`, `scripts/ui/hud.gd` + `scenes/ui/HUD.tscn`, `scripts/boot/main.gd`, and the integration glue in `scripts/world/arena.gd`.
- **Each agent owns ONE lane** = its new files/scenes + **at most one existing script**. No overlap.
- **Lead adds shared interfaces FIRST** (a "frozen foundation"): new **input actions**, **`Events` signals**, **`Settings` constants/tables**, and **`AssetRegistry` ids** (with primitive fallbacks) — so agents code against stable contracts and never need to touch those hub files.
- **One scene = one owner.** `.tscn` files merge poorly. `project.godot` and `scenes/world/Arena.tscn` are strictly single-owner.

## Canonical roles (workstreams) and their file lanes
| Agent | Owns (edits/creates) | Responsibility |
|---|---|---|
| `team-lead` | spine (above) | input/Events/Settings/Asset ids, camera/aim, HUD, integration, **play-testing via the harness** |
| `map-dev` | `scenes/world/Arena.tscn`, `scripts/world/arena.gd` | the map (geometry, POIs, spawn markers, Net/ spawners, extraction zones, navmesh) |
| `weapons-dev` | `scripts/combat/weapon*.gd`, `scenes/combat/WeaponController.tscn`, `resources/weapons/*.tres`, `assets/models/weapons/*` | weapon arsenal, ammo/reload/switch |
| `enemies-dev` | `scripts/enemies/*`, `scripts/waves/wave_manager.gd`, new `scenes/enemies/*` | enemy archetypes, AI, separation, HP bars, wave mix |
| `fx-dev` | `scenes/fx/*`, `scripts/fx/*`, `scenes/items/Grenade.tscn` + `scripts/items/grenade.gd` | hit/blood/impact FX, ragdoll/debris, grenade, damage numbers |
| `audio-dev` | `autoload/AudioManager.gd`, `assets/audio/*`, ONE `project.godot` autoload line | SFX off the Events bus |
| `harness-dev` | `tools/agent/*`, `.mcp.json` | the Python CLI + MCP wrapper for the self-play server |
| `ui-review` | — (READ ONLY) | static audit of all UI/HUD code → report findings + fixes |
| `logic-review` | — (READ ONLY) | static audit of gameplay logic → report findings + fixes |

Historical P1 lanes (when the core loop was first built): `player-dev` (controller/camera), `enemy-dev` (AI), `loot-dev` (loot + inventory UI), `waves-dev` (waves/extraction/HUD), `net-dev` (co-op netcode), `asset-dev` (CC0 assets + AssetRegistry). Folded into the roles above as the project matured.

## Build-phase pattern (how a feature push runs)
1. **Foundation (lead, solo)** — add the new input actions, `Events` signals, `Settings` constants, `AssetRegistry` ids; freeze `project.godot`/shared autoloads. Validate `--headless --import` clean.
2. **Parallel isolated workstreams** — spawn the lane agents `run_in_background`. Each builds against the foundation, creates its own files, edits only its one owned script, and validates `--headless --import` clean before reporting.
3. **Integrate at single wiring points (lead)** — e.g. instance `WeaponController.tscn` under `Player.tscn` + one call in `player.gd`; add new enemy scenes to `Arena.tscn`'s `EnemySpawner._spawnable_scenes`; instance `DamageNumbersLayer` once in `main.gd`.
4. **Play-test (lead, harness)** — drive the game (`--agent`), screenshot, fix integration bugs (this is where the camera/movement/weapon bugs were caught).
5. **Optional read-only review** — spawn `ui-review` + `logic-review` to audit for latent bugs; lead fixes what they find.

## How to spawn
```
TeamCreate({ team_name: "arc-raiders" })
TaskCreate(... one per workstream ...)
Agent({
  team_name: "arc-raiders", name: "weapons-dev",
  subagent_type: "general-purpose", run_in_background: true,
  prompt: "You are weapons-dev on team arc-raiders ... YOUR LANE — edit ONLY <files>.
           READ FIRST: autoload/Events.gd, Settings.gd, AssetRegistry.gd for the contracts.
           Build <X>. VALIDATE: cd \"C:\\personal\\hype game\" && \"<console exe>\" --headless --import
           must be clean. Mark your task complete and SendMessage the lead the exact wiring points.
           Work autonomously."
})
```
Reviewers use `general-purpose` with a strict **"READ-ONLY: do NOT edit any file; report findings + proposed fixes to team-lead"** prompt (or the `Explore` agent type for pure search).

## Coordination & cross-deps
- Agents report their **integration points** (node paths, method signatures, scene paths) to the lead via `SendMessage` when done; the lead wires them in.
- Known cross-deps to watch:
  - `enemies-dev` spawns `fx-dev`'s `res://scenes/fx/RobotDebris.tscn` on death (guard `ResourceLoader.exists`).
  - New enemy archetypes must be added to `Arena.tscn`'s `EnemySpawner._spawnable_scenes` (lead, in the map scene) or they won't replicate in co-op.
  - `weapons-dev`'s `weapon.gd` must keep emitting `fired`/`hit`/`Events.weapon_fired`/`Events.damage_number` per shot (VFX/audio/damage-numbers depend on them).
  - HUD is lead-only; agents emit on the `Events` bus and the HUD consumes — never edit the HUD from a lane.
- Each agent must run `--headless --import` clean before reporting; the lead runs the two-process co-op smoke after integrating.

## Worktree isolation + per-instance testing (running 2–4 in parallel)
For real concurrency — agents editing code AND play-testing at the same time — isolate at two levels:

**Code isolation: one git worktree per agent.** Spawn lane agents with the Agent tool's `isolation: "worktree"`. Each gets its own checkout **and its own `.godot` import cache**, so concurrent edits + reimports never race (the spine/lane rule still applies for the eventual merge). The lead merges each agent's branch, resolves at the single wiring points, then runs the full validation (import + co-op smoke + harness playtest) on the merged result.
```
Agent({ team_name:"arc-raiders", name:"enemies-dev", subagent_type:"general-purpose",
        isolation:"worktree", run_in_background:true,
        prompt:"... build in YOUR worktree; playtest on --agent-port 24701 ..." })
```

**Test isolation: one game instance per agent, on its own port.** The harness is per-instance: launch with `--agent-port N` (instance i → **24700 + i**), and the control port + every shared `user://` write are namespaced by it (`Settings.user_path` / `Settings.instance_tag`):
- control server → `127.0.0.1:<port>` · screenshots → `user://agent/<port>/` · saves → `user://profile_<port>.cfg` / `settings_<port>.cfg`
- drive with `python tools/agent/play.py --port <port> <cmd>`; MCP via the `AGENT_PORT` env var.
- helper: `pwsh tools/agent/launch_agents.ps1 -Count <N>`. Full reference: **`docs/TESTING.md` §7**.

Note: worktrees isolate code + `.godot` but **share** `user://` (it's keyed by app name, not project path) — which is exactly why the per-port `user://` namespacing above is required. For **test-only** parallelism (same code, several agents stress-testing) skip worktrees and just run N instances from the one folder on different `--agent-port`.
