# Handoff for the Next Game — Godot 4.6.3 Field Manual

> **Назначение (RU):** Этот документ — выжимка для другого агента, который будет делать **другую игру** на том же движке (Godot 4.6.3). Здесь задокументировано: что движок **умеет**, чего он **не умеет** (и как мы это обошли), какие **архитектурные паттерны сработали**, **как правильно тестировать игру через MCP-харнесс** (с обязательными скриншотами и порядком тестирования), и **что именно мы построили** в Hype Raiders — чтобы новый агент мог сравнить и сделать что-то другое, не наступая на те же грабли. Тело документа — на английском (так написана вся `docs/` и так точнее для AI-агента).

> **Purpose (EN):** A knowledge transfer from the **Hype Raiders** project (an Arc Raiders-style co-op third-person extraction shooter) to whatever you build next in **Godot 4.6.3 stable**. It is engine-focused, not game-focused: the limitations, capabilities, patterns, tooling, and testing discipline below apply to *any* Godot 4.6.3 project, especially one with co-op multiplayer and/or procedural generation. Where a claim points at code, the `file:line` is from this repo so you can read the real implementation.

**Source project at a glance:** Godot 4.6.3 stable, Forward+ renderer. ~189 `.gd` files / ~58,400 lines of GDScript, 76 `.tscn`, 110 `.tres`, **24 autoloads**, an ~80-signal global event bus. Runs with **zero downloaded art assets**. Solo + up-to-8-player co-op share one code path. Project version 0.4.4.

---

## Part 0 — TL;DR: the 16 lessons that matter most

1. **Single-player MUST use `OfflineMultiplayerPeer`, not a null peer.** Otherwise `is_multiplayer_authority()`/`is_server()` return false and the player camera, input, and AI all freeze. With it, the *same* authority-gated code runs solo and in co-op. (`NetworkManager.gd:46-53`)
2. **Build a self-play TCP harness on day one and test through it — with screenshots.** An autoload that opens a localhost JSON socket, exposes a fat `state` snapshot + a `screenshot` command, and reads virtual input. It is the single highest-leverage thing in the project. See Part 3.
3. **You MUST look at screenshots.** `state` JSON cannot see z-fighting, floating props, wrong materials, unlit scenes, UI overlap, camera clipping, or a missing model. Take a screenshot, **`Read` the PNG**, judge it. Non-negotiable.
4. **Go server-authoritative with no client prediction.** Clients send *intent* RPCs (`request_hit`, `pickup_requested`); the server applies and mirrors back. A client applying damage locally only hits its own copy → the enemy never dies for anyone.
5. **Replicate spawn data for free by encoding it in the node name.** Append a token to the node name *before* `add_child(node, true)`; `MultiplayerSpawner` ships the name to every peer, who parse it and rebuild the body identically — zero new RPCs. (`nemesis_profile.gd`, `enemy_modifiers.gd`, `wave_manager.gd:822`)
6. **`MultiplayerSynchronizer` can replicate value props but NOT object-ref props** (e.g. an inventory holding `Resource` refs). Serialize to `{id,count}` and RPC-mirror to the owning client.
7. **`CharacterBody3D` has no stair-stepping** — a 0.3 m riser is a wall. Build collision as one smooth ramp ≤36° and put render-only treads on top. (`procedural_stairs.gd:7-12`)
8. **The threaded `NavigationRegion3D` bake can silently finish without committing its map** — ground agents then freeze at spawn. Guard every query with `map_get_iteration_id(map) != 0` and self-heal on `bake_finished`. (`arena.gd:421-465`)
9. **`DirAccess` cannot enumerate a `res://` directory inside an exported PCK.** Any "scan a folder of `.tres`" system reads empty in a build. Generate an explicit path-index file and load by path. (`ItemCatalog.gd:18-36`, `ResourceIndex`)
10. **No hardware ray tracing in 4.6.3** (that's 4.7-dev + a vendor fork). The "RT look" is raster: SSR + SSIL + SDFGI + reflection probes. And **Godot does not auto-scale to hardware** — quality presets are hand-built.
11. **GDScript runs warnings-as-errors here: `var x := <Variant>` fails to parse** ("inferred from Variant"). Always type locals assigned from `Dictionary.get()` / untyped ternaries: `var x: int = ...`.
12. **`--headless --import` does NOT catch lazy parse errors inside UI/tab scripts.** A wrong node-type assignment compiles until the scene loads. Runtime-smoke every screen via the harness.
13. **Never copy-paste a helper between systems.** Duplicated hash/bounds/coordinate helpers were the #1 source of co-op desync. One shared module, byte-identical. (`scripts/core/`)
14. **Reference classes by `class_name`, never `load("res://…path…")`.** A string path turns a file move into a silent empty-world no-op; a direct class reference makes it a compile error.
15. **Saves: version-stamped, defensively parsed, never wiped.** Read every field with a default, warn once on a newer-version file, never abort the load.
16. **Keep the toolchain pure GDScript — no GDExtension native binaries.** That single constraint keeps headless servers, cross-platform exports, and co-op simple. We rejected otherwise-great plugins (Terrain3D, TerraBrush) to hold this line.

---

## Part 1 — The engine: Godot 4.6.3 reality check

### 1.1 What the engine is genuinely good at (lean on these)

- **Forward+ raster lighting looks filmic** with SDFGI (GI + reflections), SSAO, SSIL, SSR, glow/bloom, volumetric fog (`FogVolume`), AgX/ACES tonemap, and DOF via `CameraAttributesPractical`. A stylized open map looks great with zero baked lightmaps.
- **Procedural geometry/material generation in code is fast and deterministic.** We assemble every enemy, item, building, weapon, the terrain mesh, grass (MultiMesh + custom shader), water (depth + screen refraction), and climate FX in GDScript. ~760 trees + map-wide grass run at 169–240 fps on the test machine.
- **The autoload + signal-bus pattern scales cleanly** to ~24 singletons without spaghetti, because systems only ever talk through the bus.
- **High-level multiplayer (`MultiplayerSpawner` / `MultiplayerSynchronizer` / `@rpc`) is productive** for a listen-server co-op game once you respect its constraints (1.4).
- **`MultiMesh` + a custom spatial shader** handles huge instance counts (grass, scattered flora) cheaply.
- **Runtime navmesh baking** of a large map works (with the caveat in 1.2).
- **Portable single-file export** (pck embedded) + cross-compiled macOS universal `.app` with ad-hoc signing, all from Windows, no Xcode.
- **CSV-based localization with auto-translate** at draw time is nearly free for static UI text.

### 1.2 Hard limitations & the workaround we shipped (the part you came for)

| # | Limitation (what you CANNOT do) | Workaround we used | Where |
|---|---|---|---|
| L1 | **Single-player with a null/absent multiplayer peer freezes everything** — authority checks fail. | Use `OfflineMultiplayerPeer.new()` for solo so `get_unique_id()==1`, `is_server()==true`, all authority code runs locally. | `NetworkManager.gd:46-53` |
| L2 | **No hardware ray tracing / path tracing** in 4.6.3. | Raster "RT-style" stack: SSR + SSIL + max SDFGI (6 cascades) + `ReflectionProbe`s. VoxelGI is experimental/manual only. | `world_atmosphere.gd`, `procedural_reflection_probes.gd` |
| L3 | **Godot does not auto-scale graphics to the GPU.** Out of the box everyone gets the authored (heavy) look. | Hand-built 5-tier quality presets (`QUALITY_PRESETS`) + per-lever overrides; cheap big win is `viewport.scaling_3d_scale` (render scale). | `SettingsManager.gd` |
| L4 | **`CharacterBody3D` cannot step stairs** — `move_and_slide` treats a 0.3 m riser as a wall. | Collision = one solid ramp box ≤36° (under `floor_max_angle` 45° and navmesh `agent_max_slope` 50°); render-only treads on top. | `procedural_stairs.gd:7-16` |
| L5 | **Threaded `NavigationRegion3D.bake_navigation_mesh()` sometimes finishes without syncing its map** — `map_get_closest_point` returns the origin, paths are unreachable, ground enemies freeze at spawn. | On `bake_finished`, verify the map answers a probe; if not, `NavigationServer3D.map_force_update` + re-register. Guard EVERY query with `map_get_iteration_id(map) != 0` and reject a `Vector3.ZERO` snap. | `arena.gd:421-465`, `robot_enemy.gd:1218-1226` |
| L6 | **Navmesh won't bake across a deep-water gap / produces disconnected regions.** Enemies on the wrong island never path to the player. | Add a real geometry bridge for AI crossing; spawn enemies on the player's side; bias spawns near a player (`NEAR_SPAWN_RADIUS`). | `procedural_terrain.gd`, `wave_manager._spawn_xform` |
| L7 | **`DirAccess` cannot list a `res://` directory inside a PCK** — runtime folder scans read empty in an exported build. | Generate `scripts/resource_index.gd` (`class_name ResourceIndex`) at build time; catalogs load by explicit path (Godot remaps those inside a PCK). | `ItemCatalog.gd:18-36`, `tools/build/export_windows.ps1` |
| L8 | **macOS / Apple-Silicon export REFUSES without ETC2/ASTC import.** | Set `rendering/textures/vram_compression/import_etc2_astc=true` (triggers a one-time texture reimport). | `project.godot:254` |
| L9 | **`export_filter` defaults exclude string-loaded assets** (anything not reachable via the scene dependency graph). | `export_filter="all_resources"` so `assets/*` + data `.tres` ship. | `export_presets.cfg` |
| L10 | **`MultiplayerSynchronizer` can't replicate object-reference properties** (it serializes values, not `Resource` refs). An inventory of item refs won't sync. | Keep it server-authoritative, serialize to `[{id,count}]`, RPC-mirror to the owning client, rebuild from a catalog. | `Inventory._push_to_owner` / `_apply_remote` |
| L11 | **`MultiplayerSpawner` only replicates scenes in its `_spawnable_scenes` list** — a new entity type silently never appears on clients. | Keep the list exhaustive; this bit us (Caller/Elite were missing → invisible in co-op). | `EnemySpawner` in `Arena.tscn` |
| L12 | **Per-instance replicated properties are awkward** when many scenes share one script but each `.tscn` carries its own `SceneReplicationConfig`. | Encode the data in the **node name** before `add_child(.,true)` (free, deterministic), or code-instantiate a child component whose effect replicates implicitly (via `Health.current`/position). | `nemesis_profile.gd`, `enemy_status.gd` |
| L13 | **A client cannot be authoritatively repositioned by the server for its own body** — the client owns its transform. | Server *sends* a spawn position; the client applies it via `_net_place.rpc_id(peer,…)`. | `player._net_place` |
| L14 | **RPCs only route if the node lives at the identical tree path on every peer.** | Instance shared UI (e.g. TradeUI) once per peer at the same path; keep spawned entities under a fixed `Net/...` subtree. | `Arena.tscn` `Net/`, `TradeUI` |
| L15 | **Variable fonts jitter** in Godot's dynamic rasterizer (per-glyph baseline wobble). | Bake a static weight instance (`fontTools.varLib.instancer wght=400`). | `assets/fonts/`, `docs/ASSETS.md` |
| L16 | **A `SubViewport` returns an empty image on the first frame**, and renders nothing under `--headless`. | `await` a frame before capture; on headless return `null` and let the UI draw a colored-box fallback. | `IconRenderer.gd` |
| L17 | **`frame_post_draw` is unreliable for an off-screen / unfocused window** (the harness window). | `RenderingServer.force_draw(false)` for a synchronous render before grabbing the viewport image. | `AgentBridge.gd:1329` |
| L18 | **`material_override` overrides the per-surface `surface_override` slot** — a naïve hit-flash that sets `material_override` silently wins over your real material and breaks. | Duplicate and swap the *original* material into the same slot it lives in (one dup per source material), not via `material_override`. | `procedural_models.gd` (`_part`), CLAUDE.md graphics notes |
| L19 | **Map-wide `MultiMesh` gets culled by `visibility_range`** if its AABB is small — distant tiles pop out. | Give the MMI an AABB spanning the whole map (the "grass lesson"); tile per ~64 m and never range-cull the map-wide pass. | `flora_mesh_lib.gd` (`emit_model_mm_tiled`) |
| L20 | **`FogVolume` banks beyond ~80 m get culled** by the default `volumetric_fog_length`. | Raise `volumetric_fog_length` (we use 220) so banks render across the map; keep global density 0 and place local ellipsoid volumes. | `world_atmosphere.gd`, `procedural_fog_zones.gd` |
| L21 | **No native GDExtension binary** if you want a clean headless/server/portable/co-op story. *(Self-imposed, but treat it as real.)* | Stay pure GDScript. We rejected Terrain3D & TerraBrush (C++ GDExtension) and 3.x-API assets to hold this line. | `docs/ASSETS.md` (rejected) |

### 1.3 GDScript / tooling traps (each one cost real time)

- **Warnings-as-errors parse trap:** `var x := dict.get("k", 0)` or `var x := cond ? a : b` fails with *"inferred from Variant"*. Use an explicit type: `var x: int = dict.get("k", 0)`. (CLAUDE.md gotcha #10)
- **`--headless --import` misses lazy parse errors in tab/UI scripts.** Assigning, say, an `HBoxContainer` to a `: VBoxContainer` field parses only when the scene instantiates. **Runtime-smoke every UI screen** through the harness (`ui open_workshop`, each `hub_*`).
- **`load("res://…")` by string defeats the compiler.** If a class has a `class_name`, reference it directly — a file move/rename becomes a compile error instead of a silently empty world. (Audit F6)
- **Magic strings as cross-system contracts** ("players", "Hurtbox", …) compile fine and silently skip damage/credit on a typo. Put them in a consts file (`Groups`) and use the consts in code. `.tscn` files can't reference consts, so freeze the *values* and make the `.gd` const the single source. (Audit F7)
- **Untyped dict `.get(key, default)` swallows typos** — a misspelled stat key silently serves the default. Add a debug-boot validator (required fields + unknown-key whitelist + asset-path existence). (Audit F8, `BootValidate`)
- **`get_tree().paused` must be released on EVERY exit path**, including when the pause *owner* gets freed while paused (e.g. a scene reload). We needed a 4-layer fix (unpause-on-start, teardown-refire gate, visibility watchdog, `_exit_tree` release). Expose `paused` in your debug `state` to name this class of bug instantly. (Audit F10)
- **`gdlint`/`gdformat` (gdtoolkit 4.x) + `ruff`** are enforced by a **PostToolUse hook that blocks on violation (exit 2)**; a pre-commit hook re-lints staged files. Keep the tree at zero violations. A `max-file-lines` ceiling (1800 here) stops god-files from growing.

### 1.4 Physics & project conventions worth copying

- **Physics layers are named** (`project.godot [layer_names]`): 1 world, 2 player, 3 enemy, 4 loot, 5 extraction, 6 hitbox, 7 hurtbox. Remember layer N = bit value `2^(N-1)` (extraction layer 5 = value 16). Hurtbox is a pure receiver (layer 7, mask 0); weapon rays mask `world|enemy|hurtbox` (`0b1000101`).
- **Global gravity 20.0**, default up `+Y`.
- **Camera body-yaw coupling:** each frame `body.rotation.y += camera_pivot.rotation.y; camera_pivot.rotation.y = 0` — the pivot is a child of the body, so its yaw is local; assigning directly would double-count. (Convention #2)
- **Two-stage shooting raycast:** ray from the *camera* to find the crosshair point, then fire from the *chest/muzzle* toward that point — bullets follow the reticle and the spring-arm camera never shoots the player's own legs. (Convention #3)
- **Weapon view-model is reparented** from under the camera to a hand-height `WeaponMount` at runtime so it's held in third-person. (Convention #4)
- **One scene = one owner.** `.tscn` files merge terribly; make `project.godot` and the main world scene strictly single-owner. After any world/coordinate resize, hunt every duplicated constant *including scene colliders* (they can't reference consts). (Audit F12)

---

## Part 2 — Architecture patterns that worked (copy these wholesale)

### 2.1 Autoloads + a global `Events` signal bus = the only inter-system coupling
Every system is an autoload that **emits/listens on `Events` and reads shared data, never holding a direct reference to another system.** UI panels listen and re-render; they compute nothing. Adding a feature = add a signal, emit it where the thing happens, listen where you react. ~80 signals here grouped by domain (combat, weapons, loot, extraction, waves, AI perception, progression, networking, UI, graphics). (`autoload/Events.gd`)

Registration order in `project.godot [autoload]` matters (earlier autoloads are available to later ones at `_ready`). Our order: `Events → AudioManager → Settings → AssetRegistry → IconRenderer → ItemCatalog → GameState → MetaProgression → Stash → Crafting → Quests → NetworkManager → RaidManager → …directors… → AgentBridge → SettingsManager → ServerBrowser`.

### 2.2 `OfflineMultiplayerPeer` → one code path for solo and co-op
The linchpin. Because solo uses a real (offline) peer, `GameState.is_local_authority_server()` ("no peer OR is_server") is true in single-player, so all your server-authoritative logic runs unchanged. You write the game once; co-op is "the same code with more peers."

### 2.3 Server-authoritative everything; intent RPCs; chosen reliability
- Host (authority) applies effects directly; a client routes intent: `request_hit(path, amount, peer)` → server `apply_hit` on the authoritative entity. **No client-side hit prediction.**
- Pick RPC reliability deliberately: hit application = reliable; shot FX = **unreliable**; match timer = **unreliable_ordered**; match-end = `call_local` + **idempotent** (no-op if already in `RESULTS`).
- Centralize death in exactly one place (`Health._die` → `Events.entity_died` fires once) so wave-clear and kill-credit never double-count.
- Despawn by **freeing the node on the authority** (the removal replicates).
- Kill attribution: route through the server (`_peer_of(killer)`), credit XP/mastery per-peer, sync the scoreboard — a local `is_multiplayer_authority()` check earns clients nothing.

### 2.4 Replicate-by-name: the free-replication trick
This is the most non-obvious win. To give a spawned entity per-instance data with **zero new netcode**: build a short token, append it to the node's name, then `add_child(node, true)`. `MultiplayerSpawner` replicates the name to every peer; each peer parses the token in `_enter_tree` and rebuilds the identical body. Tolerate the dedupe digits Godot appends (`_NEM…`, `_modAV2`). We ship two channels coexisting on one name (elite modifiers + a persistent "nemesis" rival's tier/traits/scars), verified byte-identical host vs client. (`nemesis_profile.gd` `to_name_token`/`parse_token`, `enemy_modifiers.gd` `parse_from_name`, `wave_manager.gd:822`)

When the per-instance state is *behavioral* rather than cosmetic, the sibling trick is to **code-instantiate a child component** in `_ready()` whose effects replicate implicitly through already-synced props (`Health.current`, position) — no scene edit, no per-`.tscn` ReplicationConfig churn. (`enemy_status.gd` for status effects.)

### 2.5 `Settings` autoload centralizes every tunable + data tables
All constants, the per-archetype stat table (`ENEMY_STATS` dict), `difficulty_mods()`, and `user_path()` live in one file. UPPERCASE = compile-time constant; lowercase = runtime-mutable (driven by the settings menu). Stat dicts let you add an enemy by adding a row, not a class. Validate the table at debug boot. (`autoload/Settings.gd`, `scripts/core/boot_validate.gd`)

### 2.6 `scripts/core/` shared helpers — never copy-paste
The audit's #1 fragility was copy-pasted helpers (especially the deterministic hash) drifting and desyncing co-op worlds. The fix was one home for cross-cutting helpers, each the single source: `ProcHash` (the determinism hash — all procedural variation flows through it), `WorldBounds` (map rect + `biome_at`), `CombatAoe` (the one radial-damage loop), `Steering` (orbit math), `Groups` (string/contract consts), `BootValidate`. Rule: **if two systems need the same helper, it goes here, byte-identical.** (Audit F1–F8)

### 2.7 Version-safe saves
Four `ConfigFile` saves (`profile`, `stash`, `settings`, `favorites`), each namespaced per-instance via `user_path()`. On save, stamp `save_version`. On load: positional `.`-split version compare, parse **every field defensively** (missing stamp = legacy = OK; malformed/newer-shaped value defaults that one field), **never abort the load**, and `push_warning` + notify once if the file is from a newer build. A no-op `_migrate()` hook is ready for future field-shape changes.

### 2.8 `AssetRegistry` fallback chain → runs with zero art
One indirection between every logical id and its visual, resolved: real `.glb` → procedural weapon builder → procedural composite model → **tinted primitive** (the always-runnable floor). A `.glb` *wins* over a builder (clear the `"model"` field to force procedural). Per-id fit transforms (`model_scale`/`rot`/`offset`/`albedo`) only touch the visual subtree — collision stays tied to the capsule. Only logical ids are networked, never model subtrees, so co-op replication stays trivial. **You can build and ship the whole game loop before any art exists; art is a non-blocking drop-in.** (`AssetRegistry.gd:645-666`)

### 2.9 Golden determinism snapshot for procedural worlds
If peers each build the world locally, any seed/hash/bounds/coordinate divergence makes them build *different worlds*. Single-source those (2.6) and gate them with a golden snapshot: capture terrain height probes + zone positions + per-container placement checksums (incl. MultiMesh instance buffers) to a JSON baseline, and byte-compare on every relevant change — across a **fresh process**, not just same-run. Re-baseline only for an *intended* world change. (`tools/lint/check_golden.py`, `tools/lint/golden_world.json`)

---

## Part 3 — Testing the game via MCP (the mandatory process & order)

> This is the part you were told to read twice. You **cannot** ship or verify a Godot game of any complexity by reading code alone. Build the harness, then test in the order below, **and look at the screenshots.**

### 3.1 The philosophy
The game exposes an in-process **control server** so an AI agent (you) can *play it off-screen*: drive movement/aim/fire, spawn enemies, teleport, read the entire game state as JSON, and capture screenshots. It is built once as an autoload, costs nothing in normal play (inert unless `--agent` is passed), and becomes your eyes and hands. Everything below is reconstructable for a different game in ~1 file.

### 3.2 How the harness works (so you can rebuild it)
- **An inert autoload** (`AgentBridge`) with `process_mode = PROCESS_MODE_ALWAYS` (so it answers even while the tree is paused) and `set_process(false)` until activated.
- **Boot path:** parse `--agent` from the command line → `NetworkManager.start_offline()` (the `OfflineMultiplayerPeer`!) → `load_arena()` (or `--agent --menu` to land in the menu for co-op net testing) → `AgentBridge.activate()` → park the window. (`main.gd:195-216`)
- **Off-screen window parking:** a real (NOT headless — you need a render target) 640×360 window, borderless + no-focus, positioned at `(-4000, -4000)` so it renders for screenshots but never steals focus or shows on the desktop. Offset multiple instances horizontally. (`main.gd:206-216`)
- **Transport:** `TCPServer` on `127.0.0.1:24700`, newline-delimited JSON — send one object + `\n`, read one object + `\n`, close.
- **Virtual input model:** the bridge holds public vars (`move:Vector2`, `fire:bool`, `sprint`, `ads`, accumulated look, a `_held` dict) that the player script reads in place of `Input.is_action_pressed` when the bridge is active. **Discrete** actions (jump/reload/interact) are replayed as real `InputEventAction` via `Input.parse_input_event` + auto-release ~0.06 s later, so existing input consumers need zero changes.
- **Blocking commands:** `move`/`fire`/`goto` hold the input for `duration` and only reply when it elapses — that makes scripted play synchronous. Measure effects with separate `state` polls *during*, or by position deltas across calls.

### 3.3 The MCP layer (how you actually drive it)
A stdlib-only **MCP server** (`tools/agent/mcp_server.py`, JSON-RPC over stdio) wraps the same socket. Tools available to you in this session are prefixed `mcp__hype-game__game_*`:

- `game_state` — the fat snapshot (poll constantly).
- `game_move {x,y,duration}`, `game_look {dx,dy}`, `game_sprint {on}`, `game_aim {target}`, `game_goto {x,z,duration}`, `game_fire {duration}`, `game_act {action}`, `game_hold {action,on}` — drive the character.
- **`game_screenshot {name}` → returns the absolute PNG path. Then `Read` that path.** (The whole point.)
- `game_crosshair` — raycast report (entity / is_weakpoint / dist) to verify aim *before* firing.
- `game_damage`/`game_kill`/`game_down`/`game_set_progress`/`game_event` — deterministic QA shortcuts.
- **`game_raw {json|cmd}`** — forward ANY bridge command not wrapped by a typed tool (`spawn`, `tp`, `godmode`, `render`, `ui`, `stash`, `net`, `clock`, …). This is your escape hatch.
- **`game_instances {base,count}`** and **`game_broadcast {cmd,ports}`** — discover and fan-out to N co-op instances.
- Every tool takes an optional `port` so one MCP server drives any running instance. Port resolves: `$AGENT_PORT` env → `tools/agent/.agent_port` pin file → 24700.

Equivalents without MCP: `python tools/agent/play.py <verb>` (base verbs) and `python tools/agent/raw.py '<json>' [port]` (everything else).

### 3.4 THE TESTING ORDER (do it in this sequence, every change)
Static and cheap first, dynamic and visual last. **Do not skip a step because the previous one passed** — they catch different classes of failure.

1. **Parse / import check (cheapest, do first).**
   `"<godot>_console.exe" --headless --path "<proj>" --import 2>&1 | grep -iE "error|parse|script error"`
   Must be clean. (Ignore shutdown noise: "Unreferenced static string", "Thread object", "UVs are required".) Catches syntax/parse errors.
2. **Headless server smoke** — a real match runs with no runtime/script/null errors:
   `timeout 12 "<godot>_console.exe" --headless -- --server 2>&1 | grep -iE "script error|null instance"`
3. **Two-process co-op smoke** — one `--server` + one `--client 127.0.0.1`; neither log shows script/RPC errors. Catches replication/RPC bugs that solo never hits.
4. **Golden determinism snapshot** *(only if you touched the procedural world pipeline)* — `python tools/lint/check_golden.py` against a running `--agent` instance. Any drift = a real world change; re-baseline only if intended.
5. **Self-play with screenshots (the real verification).** Launch `--agent` in the background, then:
   1. **Wait for boot** (a few seconds), then **poll `game_state` until `drivable == true`** — refs are briefly null post-spawn; scripting before that looks like "the client can't fire."
   2. Drive the scenario: `game_aim {target:"nearest"}` → `game_crosshair` (confirm the target) → `game_fire` → poll `state` to see HP drop / enemy die. Use `game_goto` to walk, `game_act {interact}` to loot, `tp`/`spawn`/`godmode`/`refill` (via `game_raw`) to set up situations fast.
   3. **`game_screenshot` → `Read` the PNG → judge it** (see 3.5).
   4. Iterate until the behavior AND the picture are right.
6. **Runtime UI smoke** — open each screen via `game_raw {cmd:"ui", action:"hub_stash"|"hub_loadout"|…}` (and `ui open_workshop`). This is the ONLY way to catch the lazy parse errors `--import` misses (1.3). Screenshot each.

For multiplayer features, also run the **co-op assertions**: loot lands in the *client's* `state.inventory` (owner mirror); a client `fire` drops the enemy's HP on the *host* and it dies for all; `state.scoreboard` is identical on every instance; a mid-raid disconnect frees the body cleanly.

### 3.5 MANDATORY: take screenshots and actually look at them
**`state` JSON is blind to everything visual.** It will happily report a healthy match while the screen shows a grey void, a model floating 3 m up, z-fighting, an unlit scene, a gun clipping through a wall, or two UI panels overlapping. So:

- **After any change that could affect what's on screen, `game_screenshot` and then `Read` the returned PNG.** Form an opinion: is it correct, is it ugly, is something missing?
- **Screenshot from several positions/angles**, and the HUD at **both 640×360 and 1280×720** (ultrawide/edge anchoring breaks at one size and not the other).
- **For model / icon QA use the `render` command, not an in-game screenshot.** `game_raw {cmd:"render", id:"robot_grunt", name:"grunt"}` saves a clean isolated 3/4 "hero shot" of any logical model id (and `IconRenderer`-rendered inventory icons). The third-person camera makes in-world close-ups useless, so this is how you verify a procedural model actually looks like what you intended.
- **Treat the screenshot as the source of truth over the JSON** when they disagree about anything visible. Many real bugs were caught *only* in the picture (the grey-cube extraction beacon, floating loot, the broken hit-flash, UI overlap).
- Screenshots save to `%APPDATA%\Godot\app_userdata\<Project>\agent\<name>.png` (or `agent/<port>/…` per instance). The command returns the absolute path; `Read` it directly.

### 3.6 The `state` snapshot — what to inspect
One `game_state` call returns: `phase`, `wave`, `fps`, **`paused`** (names a pause-leak instantly), `result` (""/"won"/"lost"), `extraction{active,ratio}`, `match_timer{left,total,final_wave}`, per-zone extraction windows, `world{hour,night,mutator}`, `meta{currency,xp,level,loadout,quests,gear,…}`, `stash[]` + weight/cap, `peer_id`/`peers`, `scoreboard{kills,deaths,mobs_killed}`, and:
- **`drivable`** — poll before scripting (camera+weapon refs ready + input enabled + bridge active).
- **`player`** — pose/health/velocity/cam, weapon/ammo/reload/ads, stance/water/noise_radius, downed/bleedout/revive, carrying, status effects, plus a `wdbg` weapon-controller debug block. `input_enabled:false` is the tell that a KIA player still shows `drivable:true` but won't fire.
- **`enemies[]`** — id, pos, health, `state` (0 PATROL/1 CHASE/2 ATTACK/3 INVESTIGATE), `hunter`, `target`, `dist`, plus duck-typed extras (stun window, status seconds, elite modifiers, nemesis fields).
- **`players[]`** (all peers incl. remotes, with replicated cosmetics — proves appearance sync), `loot[]`, `gadgets[]`, `world_events[]`, `smoke[]`.

### 3.7 Multi-instance & co-op testing
- **Per-instance isolation via `--agent-port N`**: control port = N, `instance_tag = N`, saves become `*_N.cfg`, screenshots go to `agent/N/`. Net port is separate (`--net-port P`, discovery `P+1`) because a co-op group shares one net port but each peer has its own agent port.
- **Launch N** with `tools/agent/launch_agents.ps1 -Count N -Menu -BasePort 24700 -NetPort 24565` (N≤8).
- **Co-op flow over the socket:** `net host` on 24700 → `net join {ip:127.0.0.1}` on the rest → wait for `state.peers_count==N` → `ready {on:true}` on clients → `deploy` on the leader → verify each `state.players_count==N` with distinct `player.pos`, then drive each by its port.
- **Git worktree parallelism:** each worktree has its own `.godot`/`export/`, so editing in parallel is free; to *run* several at once give each a disjoint agent-port range, a distinct net-port, and a `--label` (folded into the window title). `user://` is shared across worktrees (keyed by app name), which is exactly why per-port save namespacing exists.

### 3.8 Reusing the harness for a different game (the one-paragraph recipe)
Make an autoload that's inert until `activate()`. On `--agent`, boot single-player with an `OfflineMultiplayerPeer`, park a small borderless/no-focus window far off-screen, and open a localhost `TCPServer` speaking newline-delimited JSON. Hold continuous virtual input as public vars the player script reads when active; replay discrete actions as real `InputEventAction`s. Make `move`/`fire`/`goto` block until a deadline. Expose one fat `state` command that serializes everything and a `screenshot` command that calls `RenderingServer.force_draw(false)` then saves the viewport image to a `user://`-namespaced path and returns the absolute path. Namespace the control port + every `user://` write by `--agent-port N`. Wrap it with a tiny stdlib Python `send(cmd)` client and a stdlib MCP server that forwards commands (with a `raw` escape hatch + `instances`/`broadcast` fan-out). Then test in the order of 3.4, and **look at the screenshots.**

---

## Part 4 — Quality gates & the parallel-agent workflow

### 4.1 Linters as a blocking hook
`gdlint` + `gdformat` (gdtoolkit 4.x) for `.gd`, `ruff` for Python, wired as a **Claude Code PostToolUse hook that blocks the edit on any violation (exit 2)** plus a pre-commit hook on staged files. The repo is kept at **zero** violations. New/edited files must pass both. Long localization-key strings that can't be split carry an inline `# gdlint: ignore=max-line-length`. A `max-file-lines` ceiling (1800) stops god-files from growing — when a god-file (player, the agent bridge) is at the ceiling, push new debug/QA logic into helper classes (`scripts/core/agent_*_debug.gd`).

### 4.2 Golden snapshot — see 2.9. The refactoring safety net for anything procedural.

### 4.3 Agent teams: "spine vs lanes"
Big features were built by a team where **the lead owns the shared spine and integrates; each agent owns one isolated lane** (its new files + at most one existing script). The pattern:

**Frozen foundation → parallel isolated workstreams → integrate at single wiring points → playtest via the harness → optional read-only review.**

- The lead adds the shared interfaces **first** (input actions, `Events` signals, `Settings` constants, `AssetRegistry` ids with primitive fallbacks) so lanes code against stable contracts and never touch hub files.
- **One scene = one owner.** `project.godot` and the world scene are single-owner.
- Lanes report their integration points (node paths, method signatures) back; the lead wires them in and runs the import + co-op smoke + harness playtest on the merged result.
- For concurrent edit-and-playtest, give each agent a **git worktree** (own `.godot` import cache) AND a per-port game instance.
- Documentation passes parallelize one doc file per agent (this very document was produced that way), with the lead fact-checking named symbols against the code.

---

## Part 5 — What Hype Raiders actually built (for comparison / to differentiate from)

A vertical slice of an **Arc Raiders-style co-op third-person extraction shooter**. The point of listing it: so you can deliberately build something *different*, and know which systems already have a reference implementation here you could lift.

**Core loop:** deploy (solo or up-to-8 co-op) into a hostile **320×320** procedurally-detailed urban-ruins map (4 biomes: urban / snow / desert / rain, each with a themed landmark) → scavenge tiered loot → survive 5 escalating AI waves + a timed "storm" final wave + a boss → reach one of 12 extraction zones alive. Death loses your at-risk gear; extraction keeps it.

**Systems with reference implementations here:**
- **Combat:** third-person shooting with bullet drop (stepped ballistic raycast), stance-based spread (stand/crouch/slide + ADS), weak points (head/back hurtboxes with damage multipliers), hit-markers, stagger, screen shake / hit-stop.
- **Enemies:** ~18 machine archetypes incl. 9 **biome-exclusive** types (a burrowing sandworm, pouncers, mortar/slammer/blink units, kamikaze, recon drone), elite modifiers (armored/swift/volatile/regenerating, name-encoded), 3 biome minibosses, a boss. Server-side AI perception: enemies **hear** noise (crouch-walk to sneak past patrols), investigate, cascade alerts; a reactive `AIDirector` summons reinforcements / camp-punish flanks.
- **Movement:** dodge-roll (i-frames), mantle, ziplines, crouch/slide stances, swimming (a real deep river with depth/refraction water + underwater overlay), vertical traversal (ramp-stairs, breakable glass, climbable container stacks).
- **Signature mechanic — "Machine Nemesis":** a robot that survives a fight becomes a persistent, host-saved **rival** that adapts to how you fought it (a 4-tactic damage histogram → a learned counter-trait), levels up, wears procedural scars, and returns to hunt you — projected to co-op clients **for free via the node-name channel**. Plus a kill-bounty/trophy, gear-reclaim, extraction-ambush bias, a "Rivals" codex, and a weakened **successor** that re-seeds the grudge.
- **Machine Chemistry:** enemy status effects (shock/burn/slow/brittle) with emergent reactions (wet + shock = chain discharge; deep freeze = brittle = shatter), climate-amplified, fed by incendiary/cryo/EMP grenades.
- **Economy / meta:** at-risk-vs-secure loot, a weight-capped stash, crafting/recipes/blueprints, quests + daily contracts, three progression tracks (Raider level + skills, vendor reputation, weapon mastery), armor with durability, insurance, a full Hub/Lobby with ~9 tabs, procedural modular **character customization**.
- **Co-op:** listen-server, lobby ready-up handshake, server-authoritative combat/inventory/kills, item give + two-sided trade, downed/revive loop (carry, self-revive, comms wheel, pings), a server browser with LAN discovery, a synced scoreboard.
- **World:** day-night as a pure function of the match timer, dynamic mid-raid world events (supply cache / roaming miniboss / contested POI / surge / siege), per-zone timed extraction windows, raid mutators, a Power-Core carry-to-extract beacon.
- **Presentation:** 5-tier graphics presets + cinematic sliders (volumetric/local fog, god rays, DOF, POM terrain, draw distance), any-aspect display (ultrawide → 4:3), a "military glass" themed UI built in code, en/ru localization, a stats/diagnostics overlay.

**Tooling built:** the self-play harness + MCP (Part 3), the golden snapshot, the lint hooks, a graphify knowledge graph, Windows + macOS export from one command.

---

## Part 6 — Do / Don't for the next game

**Do (reuse these verbatim or near-verbatim):**
- The `OfflineMultiplayerPeer` solo-path, the `Events` bus, the `Settings`-centralizes-everything pattern, the `AssetRegistry` zero-art fallback chain, version-safe saves, `scripts/core/` shared helpers, the golden snapshot, and **the self-play harness + MCP** — these are game-agnostic and were the project's backbone.
- Server-authoritative netcode with intent RPCs, and the **replicate-by-name** trick whenever a spawned entity needs cheap per-instance data.
- The lint-hook + spine/lanes workflow if you also build with parallel agents.

**Don't (these cost us time — don't repeat them):**
- Don't ship a null multiplayer peer for solo (L1). Don't `load("res://…")` by string (1.3). Don't copy-paste a determinism helper (2.6). Don't trust `--import` to catch UI parse errors (1.3). Don't add a GDExtension binary if you value the headless/export/co-op simplicity (L21). Don't set per-instance replicated props on scenes that share a script (L12) — name-encode instead. Don't expect navmesh or `CharacterBody3D` to "just work" on stairs or after a threaded bake (L4/L5) — build the ramp and the self-heal up front. Don't verify by JSON alone — **screenshot and look** (3.5).

**Consider doing differently (open questions / where this project made a specific choice you needn't):**
- We kept **god-files** (player, the agent bridge) and only capped their growth; a fresh project could split responsibilities earlier.
- We deferred typed `Resource` catalogs in favor of validated untyped dicts (Audit F8); typed resources are safer if your data tables will grow large.
- We used **procedural-everything** for art so the game runs with zero assets — great for an agent-built project, but if you have an art pipeline, the `AssetRegistry` indirection still lets you drop real assets in later without code changes.
- The map is a single 320×320 arena built at load; a different game might want streamed/chunked worlds (which changes the navmesh and determinism story significantly).

---

## Appendix — quick reference

**Engine:** Godot 4.6.3 stable, Forward+. GUI exe `Godot_v4.6.3-stable_win64.exe`; headless/CI `…_win64_console.exe`.

**Launch flags (after `--`):** `--server` · `--client <ip>` · `--agent` · `--agent --menu` · `--agent-port N` · `--net-port P` · `--label <name>` · `--no-save`.

**Ports:** control TCP 24700 (`--agent-port N` → N); ENet game 24565; LAN discovery 24566 (`--net-port P` → discovery P+1).

**Validate:** `--headless --import` (parse) → `--headless --server` (smoke) → `--server`+`--client` (co-op smoke) → `check_golden.py` (determinism) → `--agent` self-play + screenshots → UI runtime smoke.

**Key files to read first in this repo:** `autoload/Events.gd` (the contracts), `autoload/Settings.gd` (tunables + data tables), `autoload/NetworkManager.gd` (netcode + offline peer), `autoload/AgentBridge.gd` (the harness), `scripts/world/arena.gd` (world build + navmesh self-heal), `scripts/core/*` (shared helpers), and the deep docs `docs/ARCHITECTURE.md` / `docs/TESTING.md` / `docs/AUDIT.md` / `docs/AGENT_TEAMS.md` / `docs/ASSETS.md`.

**Project conventions & gotchas:** the numbered list at the bottom of `CLAUDE.md` ("Top conventions & gotchas") is the always-loaded short version of Part 1 here.
