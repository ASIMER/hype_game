# Graph Report - hype game  (2026-08-10)

## Corpus Check
- 40 files · ~4,315,991 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 705 nodes · 934 edges · 98 communities (64 shown, 34 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 73 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `84cb86de`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_SFX Audio Synthesizer|SFX Audio Synthesizer]]
- [[_COMMUNITY_AgentBridge QA Commands|AgentBridge QA Commands]]
- [[_COMMUNITY_Core Autoload Singletons|Core Autoload Singletons]]
- [[_COMMUNITY_Combat & Damage Pipeline|Combat & Damage Pipeline]]
- [[_COMMUNITY_Asset Registry & Fallbacks|Asset Registry & Fallbacks]]
- [[_COMMUNITY_HUD Widgets|HUD Widgets]]
- [[_COMMUNITY_Harness Control Client|Harness Control Client]]
- [[_COMMUNITY_Hub Lobby & Quests|Hub Lobby & Quests]]
- [[_COMMUNITY_Visual FX & Ranged Enemies|Visual FX & Ranged Enemies]]
- [[_COMMUNITY_Weapon Data & Attachments|Weapon Data & Attachments]]
- [[_COMMUNITY_MCP Server Bridge|MCP Server Bridge]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Server-Auth Co-op Netcode|Server-Auth Co-op Netcode]]
- [[_COMMUNITY_Procedural Buildings|Procedural Buildings]]
- [[_COMMUNITY_Claude Settings Hooks|Claude Settings Hooks]]
- [[_COMMUNITY_Storm Final Wave|Storm Final Wave]]
- [[_COMMUNITY_Inventory Owner Mirror|Inventory Owner Mirror]]
- [[_COMMUNITY_Loot Drops|Loot Drops]]
- [[_COMMUNITY_MCP Config|MCP Config]]
- [[_COMMUNITY_Trade System|Trade System]]
- [[_COMMUNITY_Weathered Materials|Weathered Materials]]
- [[_COMMUNITY_Extraction Windows|Extraction Windows]]
- [[_COMMUNITY_Hit-Flash Materials|Hit-Flash Materials]]
- [[_COMMUNITY_Team Workflow Pattern|Team Workflow Pattern]]
- [[_COMMUNITY_Test Isolation|Test Isolation]]
- [[_COMMUNITY_Enemy FSM|Enemy FSM]]
- [[_COMMUNITY_Camera FX Hook|Camera FX Hook]]
- [[_COMMUNITY_Grenade|Grenade]]
- [[_COMMUNITY_Settings Apply|Settings Apply]]
- [[_COMMUNITY_Stash Capacity|Stash Capacity]]
- [[_COMMUNITY_Server Browser UI|Server Browser UI]]
- [[_COMMUNITY_Settings Menu|Settings Menu]]
- [[_COMMUNITY_Asset Indirection|Asset Indirection]]
- [[_COMMUNITY_Audio Synth Doc|Audio Synth Doc]]
- [[_COMMUNITY_Attachment Data|Attachment Data]]
- [[_COMMUNITY_Weapon Controller|Weapon Controller]]
- [[_COMMUNITY_Weapon Node|Weapon Node]]
- [[_COMMUNITY_Extraction Tick|Extraction Tick]]
- [[_COMMUNITY_Camera Fire FX|Camera Fire FX]]
- [[_COMMUNITY_World Atmosphere|World Atmosphere]]
- [[_COMMUNITY_Icon Renderer|Icon Renderer]]
- [[_COMMUNITY_Inventory Split|Inventory Split]]
- [[_COMMUNITY_Attachment Reconcile|Attachment Reconcile]]
- [[_COMMUNITY_Player Loadout|Player Loadout]]
- [[_COMMUNITY_Player Death|Player Death]]
- [[_COMMUNITY_Raid Manager|Raid Manager]]
- [[_COMMUNITY_Stash Stacks|Stash Stacks]]
- [[_COMMUNITY_Crosshair Enemy Tint|Crosshair Enemy Tint]]
- [[_COMMUNITY_Pause Menu|Pause Menu]]
- [[_COMMUNITY_Procedural Weapons|Procedural Weapons]]
- [[_COMMUNITY_Wave Spawn Loop|Wave Spawn Loop]]
- [[_COMMUNITY_Navmesh Bake|Navmesh Bake]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 58|Community 58]]
- [[_COMMUNITY_Community 59|Community 59]]
- [[_COMMUNITY_Community 60|Community 60]]
- [[_COMMUNITY_Community 61|Community 61]]
- [[_COMMUNITY_Community 62|Community 62]]
- [[_COMMUNITY_Community 63|Community 63]]
- [[_COMMUNITY_Community 64|Community 64]]
- [[_COMMUNITY_Community 65|Community 65]]
- [[_COMMUNITY_Community 67|Community 67]]
- [[_COMMUNITY_Community 68|Community 68]]
- [[_COMMUNITY_Community 69|Community 69]]
- [[_COMMUNITY_Community 70|Community 70]]
- [[_COMMUNITY_Community 71|Community 71]]
- [[_COMMUNITY_Community 76|Community 76]]
- [[_COMMUNITY_Community 78|Community 78]]
- [[_COMMUNITY_Community 79|Community 79]]
- [[_COMMUNITY_Community 80|Community 80]]
- [[_COMMUNITY_Community 81|Community 81]]
- [[_COMMUNITY_Community 82|Community 82]]
- [[_COMMUNITY_Community 83|Community 83]]
- [[_COMMUNITY_Community 84|Community 84]]
- [[_COMMUNITY_Community 85|Community 85]]
- [[_COMMUNITY_Community 87|Community 87]]
- [[_COMMUNITY_Community 88|Community 88]]
- [[_COMMUNITY_Community 89|Community 89]]
- [[_COMMUNITY_Community 90|Community 90]]
- [[_COMMUNITY_Community 91|Community 91]]
- [[_COMMUNITY_Community 92|Community 92]]
- [[_COMMUNITY_Community 93|Community 93]]
- [[_COMMUNITY_Community 94|Community 94]]
- [[_COMMUNITY_Community 95|Community 95]]
- [[_COMMUNITY_Community 96|Community 96]]
- [[_COMMUNITY_Community 97|Community 97]]

## God Nodes (most connected - your core abstractions)
1. `float` - 45 edges
2. `_fade()` - 34 edges
3. `_noise()` - 28 edges
4. `_adsr()` - 27 edges
5. `_lowpass()` - 21 edges
6. `_highpass()` - 21 edges
7. `_mix()` - 20 edges
8. `_sine()` - 15 edges
9. `gen_footstep()` - 14 edges
10. `handle_request()` - 13 edges

## Surprising Connections (you probably didn't know these)
- `.claude/settings.json graphify PreToolUse hooks` --conceptually_related_to--> `Hype Raiders Project Guide (CLAUDE.md)`  [INFERRED]
  .claude/settings.json → CLAUDE.md
- `gen_icons.gd (icon generator)` --semantically_similar_to--> `ProceduralModels`  [INFERRED] [semantically similar]
  tools/gen_icons.gd → scripts/visual/procedural_models.gd
- `hype-game MCP Server config` --conceptually_related_to--> `Self-play test harness (--agent + play.py)`  [INFERRED]
  .mcp.json → CLAUDE.md
- `Stash.total_weight` --shares_data_with--> `WeaponData resource`  [AMBIGUOUS]
  autoload/Stash.gd → scripts/combat/weapon_data.gd
- `Decoupled-autoloads-via-Events-bus pattern` --references--> `Events (global signal bus)`  [EXTRACTED]
  CLAUDE.md → autoload/Events.gd

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Zero-asset visual fallback (model + icon)** — assetregistry_get_model, assetregistry_get_icon, iconrenderer_render_now, assetregistry_fallback_chain [EXTRACTED 0.90]
- **Co-op lobby load-gate to match-start handshake** — networkmanager_request_start, networkmanager_notify_loaded, networkmanager_begin_match, gamestate_reset_match, raidmanager_deploy [EXTRACTED 0.85]
- **Raid economy: deploy commit to extract deposit** — raidmanager_deploy, raidmanager_grant_extraction, raidmanager_deposit, metaprogression_metaprogression, crafting_learn_items [EXTRACTED 0.85]
- **Weapon-to-enemy damage chain** — combat_weapon_shoot, combat_hurtbox_apply_hit, combat_health_take_damage, docs_architecture_server_auth_combat [EXTRACTED 0.90]
- **Weapon stat layering pipeline** — combat_weapon_controller_load_weapons, combat_attachment_data_apply_to, combat_weapon_data_weapondata [EXTRACTED 0.90]
- **Synchronized co-op deploy flow** — main_on_hub_deploy, main_do_deploy, main_load_arena, docs_architecture_lobby_handshake [INFERRED 0.85]
- **Combat Shot FX Pipeline** — fx_remote_shot_fx_on_remote_shot, fx_muzzle_flash_muzzleflash, fx_tracer_tracer, fx_impact_impact [EXTRACTED 0.85]
- **Server-Auth Inventory Owner-Mirror Flow** — inventory_inventory_notify, inventory_inventory_push_to_owner, inventory_inventory_apply_remote, concept_inventory_owner_mirror [INFERRED 0.85]
- **Extraction Completion Payout Flow** — extraction_extraction_zone_complete, extraction_extraction_zone_grant_extraction, raidmanager_grant_extraction, networkmanager_broadcast_match_won [EXTRACTED 0.85]
- **HUD spawns self-contained Events-driven overlay components** — ui_hud_hud, ui_crosshair_dynamiccrosshair, ui_minimap_minimap, ui_compass_compass, ui_killfeed_killfeed, ui_damage_indicator_damageindicator, ui_stamina_bar_staminabar, ui_interaction_prompt_interactionprompt [EXTRACTED 0.95]
- **Map/minimap consume cached extraction-window state** — ui_map_ui_mapui, ui_minimap_minimap, concept_extraction_window_cache [INFERRED 0.85]
- **Two-sided trade: request, offer-sync, host-arbitrated finalize** — ui_trade_ui_on_trade_pressed, ui_trade_ui_rpc_finalize, ui_trade_ui_tradeui [EXTRACTED 0.85]
- **Procedural visual generation stack** — visual_proc_materials_procmaterials, visual_procedural_models_proceduralmodels, visual_procedural_buildings_proceduralbuildings, visual_procedural_weapons_proceduralweapons, autoload_assetregistry [INFERRED 0.85]
- **Hub economy tabs over shared autoloads** — ui_workshop_tab_workshoptab, tabs_gunsmith_tab_gunsmithtab, tabs_shop_tab_shoptab, tabs_stash_tab_stashtab, tabs_quests_tab_queststab [INFERRED 0.80]
- **Self-play control harness** — agent_play_play, agent_raw_raw, agent_mcp_server_mcpserver, concept_wire_protocol [INFERRED 0.80]

## Communities (98 total, 34 thin omitted)

### Community 0 - "SFX Audio Synthesizer"
Cohesion: 0.16
Nodes (23): _concat(), gen_heartbeat(), gen_lose(), gen_reload(), gen_robot_alert(), gen_wave_alert(), gen_win(), _mul() (+15 more)

### Community 1 - "AgentBridge QA Commands"
Cohesion: 0.25
Nodes (8): AgentBridge._debug_spawn, Events (global signal bus), ExtractionDirector (timed evac windows), RemoteShotFX, GameState.is_local_authority_server, NetworkManager.begin_match, NetworkManager.broadcast_shot, NetworkManager.notify_loaded (load gate)

### Community 2 - "Core Autoload Singletons"
Cohesion: 0.08
Nodes (41): AssetRegistry, Events bus, GameState, MetaProgression, NetworkManager, Settings, Stash, Export PCK DirAccess fallback to ResourceIndex (+33 more)

### Community 3 - "Combat & Damage Pipeline"
Cohesion: 0.05
Nodes (42): AttachmentData.apply_to, Health component, Health.take_damage, Hurtbox.apply_hit, Hurtbox, WeaponController._apply_attachments, WeaponController._load_weapons, WeaponController.try_fire (+34 more)

### Community 4 - "Asset Registry & Fallbacks"
Cohesion: 0.67
Nodes (3): Lighting QA suite: screenshots at fixed spots x fixed in-game hours (+ storm)., send(), wait_drivable()

### Community 5 - "HUD Widgets"
Cohesion: 0.19
Nodes (16): Cached extraction-window state pattern, Local-player binding via Events.local_player_spawned, Compass, DynamicCrosshair, DamageIndicator, HitMarker, HUD._build_hud_widgets, HUD (+8 more)

### Community 6 - "Harness Control Client"
Cohesion: 0.11
Nodes (23): mcp_server.py (MCP bridge), AgentError, _cast_num(), _emit(), main(), play.py (control client), Raised when the control server cannot be reached or replies badly., Send one command dict and return the parsed response dict.      move/fire are (+15 more)

### Community 7 - "Hub Lobby & Quests"
Cohesion: 0.13
Nodes (15): QuestData, QuestData.reward_items, HaulManager, HaulManager._on_recycle, HaulManager._on_sell, Hub (Lobby shell), Hub._on_deploy_pressed, Hub._refresh_squad (+7 more)

### Community 8 - "Visual FX & Ranged Enemies"
Cohesion: 0.08
Nodes (31): _build_prog(), _build_raw(), _error(), handle_request(), _instance_info(), log(), main(), _probe_port() (+23 more)

### Community 9 - "Weapon Data & Attachments"
Cohesion: 0.13
Nodes (14): 1. How `--agent` mode works, 2. Command protocol, 3. `state` JSON schema, 4. Driving it, 5. Validation commands (run after every change), 6. QA workflow (test matrix), 7. Co-op multi-instance testing (instances playing together), 8. Parallel testing (2–4 instances at once) (+6 more)

### Community 10 - "MCP Server Bridge"
Cohesion: 0.06
Nodes (33): 1.1 What the engine is genuinely good at (lean on these), 1.2 Hard limitations & the workaround we shipped (the part you came for), 1.3 GDScript / tooling traps (each one cost real time), 1.4 Physics & project conventions worth copying, 2.1 Autoloads + a global `Events` signal bus = the only inter-system coupling, 2.2 `OfflineMultiplayerPeer` → one code path for solo and co-op, 2.3 Server-authoritative everything; intent RPCs; chosen reliability, 2.4 Replicate-by-name: the free-replication trick (+25 more)

### Community 11 - "Community 11"
Cohesion: 0.20
Nodes (10): AgentBridge.activate, AgentBridge (self-play control server), Agent-teams parallel work pattern, Decoupled-autoloads-via-Events-bus pattern, OfflineMultiplayerPeer authority model, Hype Raiders Project Guide (CLAUDE.md), Self-play test harness (--agent + play.py), hype-game MCP Server config (+2 more)

### Community 12 - "Server-Auth Co-op Netcode"
Cohesion: 0.14
Nodes (23): _amb_wind(), _chord_pad(), gen_amb_desert(), gen_amb_rain(), gen_amb_snow(), gen_amb_urban(), gen_footstep(), gen_music_long() (+15 more)

### Community 13 - "Procedural Buildings"
Cohesion: 0.14
Nodes (13): 10. Server browser & LAN discovery (`autoload/ServerBrowser.gd`), 11. Quality gates & `scripts/core/` (the audit pass — full report: `docs/AUDIT.md`), 1. Autoloads (registered in `project.godot [autoload]`, in this order — 17 total), 2. Events bus (`autoload/Events.gd`) — full signatures, 3. Settings (`autoload/Settings.gd`) — values, 4. Input map (`project.godot [input]`), 5. Physics layers (`[layer_names]`), 6. Key scene trees (abbreviated) (+5 more)

### Community 14 - "Claude Settings Hooks"
Cohesion: 0.22
Nodes (8): enabledPlugins, disciplines@awesome-gamedev-agent-skills, example-skills@anthropic-agent-skills, godot@awesome-gamedev-agent-skills, godot-prompter@godot-prompter-marketplace, hooks, PostToolUse, PreToolUse

### Community 15 - "Storm Final Wave"
Cohesion: 0.67
Nodes (3): Storm / final forced-extraction wave, WaveManager._tick_match_timer, WaveManager._trigger_storm

### Community 16 - "Inventory Owner Mirror"
Cohesion: 0.67
Nodes (3): Inventory._apply_remote, Inventory._notify, Inventory._push_to_owner

### Community 17 - "Loot Drops"
Cohesion: 0.67
Nodes (3): InventoryUI._drop_item, LootPickup.spawn_at, LootSpawner

### Community 18 - "MCP Config"
Cohesion: 0.40
Nodes (4): AGENT_HOST, AGENT_PORT, python, hype-game

### Community 19 - "Trade System"
Cohesion: 1.00
Nodes (3): TradeUI._on_trade_pressed, TradeUI._rpc_finalize, TradeUI

### Community 20 - "Weathered Materials"
Cohesion: 0.67
Nodes (3): ProcMaterials.grime_texture, ProcMaterials.streaked, ProcMaterials.weathered

### Community 56 - "Community 56"
Cohesion: 0.09
Nodes (22): (1) How buildings are currently built, 1. Verdict, (2) How breakable GLASS works — and whether it extends to walls, 2. Ranked Options, 3.1 Why it uniquely passes the HARD "must look identical" gate, 3.2 How it hooks into the existing precedent (concrete wiring), 3.3 Co-op replication, 3.4 Golden determinism (+14 more)

### Community 57 - "Community 57"
Cohesion: 0.12
Nodes (16): `game_broadcast` — fan-out to N instances, `game_instances` — discover live instances, `game_raw` — generic forwarder, How the game exposes control, hype-game agent harness, Importable, MCP server, N-instance co-op recipe (+8 more)

### Community 58 - "Community 58"
Cohesion: 0.20
Nodes (9): Agent Teams — Expected Structure & Ownership, Build-phase pattern (how a feature push runs), Canonical roles (workstreams) and their file lanes, Coordination & cross-deps, How to spawn, Team, The core rule: spine vs lanes (no two agents edit the same file), Worked examples (the co-op batches built this way) (+1 more)

### Community 59 - "Community 59"
Cohesion: 0.15
Nodes (12): Architecture at a glance, graphify, Hype Raiders — Project Guide (read me first), Localization (en base + ru; scalable), Parallel work with agent teams, Quality gates (linters, hooks, golden snapshot — docs/AUDIT.md is the full audit), Release / packaging (portable Windows build), Release / packaging (portable Windows + macOS builds) (+4 more)

### Community 60 - "Community 60"
Cohesion: 0.25
Nodes (7): Asset Catalog & Credits — Hype Raiders, Credits, Deferred (planned, not this batch), Integrated this batch (`feat/asset-integration`), License posture, Other vetted sources (for future searches), Rejected

### Community 61 - "Community 61"
Cohesion: 0.40
Nodes (4): Build a portable Windows .exe, Docs, Hype Raiders, Run

### Community 62 - "Community 62"
Cohesion: 0.50
Nodes (3): Attribution, License, Relevant FAQs

### Community 67 - "Community 67"
Cohesion: 0.25
Nodes (8): ExtractionZone._complete, ExtractionZone._grant_extraction, GameState (match-level shared state), NetworkManager (host/join + lobby + sync), NetworkManager.sync_match_timer / sync_wave, RaidManager.grant_extraction, Settings.difficulty_mods / DIFFICULTY_MODS, Settings.ENEMY_STATS (per-archetype table)

### Community 68 - "Community 68"
Cohesion: 0.40
Nodes (5): Crafting.buy_blueprint, Crafting.learn_items (item to blueprint map), MetaProgression.learn_blueprint, Quests.claim (grant reward once), RaidManager._deposit

### Community 69 - "Community 69"
Cohesion: 0.60
Nodes (5): AgentBridge._screenshot, MetaProgression.save_profile / load_profile, ServerBrowser.load_config (version-safe save), Settings.user_path (per-instance saves), Version-stamped resilient ConfigFile saves

### Community 70 - "Community 70"
Cohesion: 0.67
Nodes (3): main(), trim(), str

### Community 71 - "Community 71"
Cohesion: 0.67
Nodes (3): ExtractionDirector._apply_windows, ServerBrowser.scan_lan, Settings (tunable constants)

### Community 76 - "Community 76"
Cohesion: 0.50
Nodes (3): main(), Claude Code PostToolUse hook: auto-lint the file just edited by Edit/Write.  R, int

### Community 78 - "Community 78"
Cohesion: 0.12
Nodes (15): containers, Flora, Geometry, ProceduralTerrain, hash, nodes, hash, nodes (+7 more)

### Community 79 - "Community 79"
Cohesion: 0.23
Nodes (12): clear_enemies(), climb_flight(), mantle_chain(), player_y(), Loot reachability audit: every pickup must SIT on a surface (no floaters), and t, True point-to-point movement: short re-faced hops, stop within tol. A bare     g, Walk toward (x,z) in short telemetry steps until the player has RISEN by     min, Kill every live enemy — they path upstairs now and a chasing body parked in a (+4 more)

### Community 80 - "Community 80"
Cohesion: 0.22
Nodes (8): 1. God files (size inventory), 2. Fragility findings (the "change A, B breaks" list), 3. Duplication (non-fragile, quality), 4. Dead code, 5. Lint baseline (gdlint, `gdlintrc` at repo root), 6. Golden determinism snapshot (the refactoring safety net), 7. Deferred (recorded so they aren't re-litigated), Hype Raiders — Architecture Audit (v0.3)

### Community 81 - "Community 81"
Cohesion: 0.17
Nodes (12): gen_music(), gen_robot_death(), gen_underwater(), _mix(), Sum multiple tracks (same length) with soft clipping., Sum multiple tracks (same length) with soft clipping., Muffled submerged ambience (loopable): low rumble + slow filtered-noise surge,, Muffled submerged ambience (loopable): low rumble + slow filtered-noise surge, (+4 more)

### Community 82 - "Community 82"
Cohesion: 0.67
Nodes (3): 4-player shootout perf: everyone holds fire at one spot; perf sampled on the HOS, send(), wait()

### Community 83 - "Community 83"
Cohesion: 0.67
Nodes (3): Perf baseline/AB: capture perf at 3 solo spots (open field, beacon, Temple)., send(), wait_drivable()

### Community 84 - "Community 84"
Cohesion: 0.25
Nodes (7): Characters / player, Destruction (in-world — walls break into ~0.8 m chunks + physics debris), Enemies (21 archetypes — every body is a distinct procedural silhouette), Hype Raiders — Visual Showcase, Locations (in-world — the 4 biomes + a landmark), Loot / items, UI

### Community 85 - "Community 85"
Cohesion: 0.07
Nodes (36): AssetRegistry.CATALOG (logical id table), Guarded-fallback resolution (glb to procedural to primitive), AssetRegistry.get_icon, AssetRegistry.get_model, AssetRegistry._make_primitive (tinted fallback), AudioManager (Events-driven SFX), AudioManager._play / _play_at, Events Bus (+28 more)

### Community 87 - "Community 87"
Cohesion: 0.22
Nodes (9): _fade(), gen_player_death(), gen_weapon_switch(), Apply a short linear fade-in/out to avoid clicks., Apply a short linear fade-in/out to avoid clicks., Descending minor tone — ominous., Descending minor tone — ominous., Short metallic shink — rising high freq click. (+1 more)

### Community 88 - "Community 88"
Cohesion: 0.17
Nodes (12): gen_chunk_stone(), gen_explosion(), gen_shot(), _highpass(), Simple single-pole IIR highpass., Simple single-pole IIR highpass., Short punchy laser crack: high transient + descending tone., Short punchy laser crack: high transient + descending tone. (+4 more)

### Community 89 - "Community 89"
Cohesion: 0.67
Nodes (3): gen_hit(), Short impact tick: snappy transient., Short impact tick: snappy transient.

### Community 90 - "Community 90"
Cohesion: 0.20
Nodes (10): Server-authoritative co-op (hit/score/transfer routing), GameState.peers (peer roster), GameState.record_kill / record_death, GameState.reset_match, InventoryUI._give_item, NetworkManager._on_entity_died (kill attribution), NetworkManager.request_hit (server-auth damage), NetworkManager.request_start (leader START) (+2 more)

### Community 91 - "Community 91"
Cohesion: 0.11
Nodes (22): _adsr(), gen_chunk_metal(), gen_extract_beep(), gen_extract_cancel(), gen_extract_done(), gen_glass_break(), gen_ui_click(), Clean short beep — extraction proximity cue. (+14 more)

### Community 92 - "Community 92"
Cohesion: 0.33
Nodes (6): gen_ambient(), gen_water_splash(), Entering-water splash: a bright filtered-noise burst with a quick wet decay,, Entering-water splash: a bright filtered-noise burst with a quick wet decay,, Quiet evolving low drone/wind bed (loopable).     Low filtered noise + slow sin, Quiet evolving low drone/wind bed (loopable).     Low filtered noise + slow sin

### Community 93 - "Community 93"
Cohesion: 0.18
Nodes (13): AgentBridge._aim_at (converging camera aim), AgentBridge._handle_line (command dispatch), AgentBridge._snapshot (state JSON), AgentBridge._ui_action (menu open/close), Crafting.craft, MetaProgression (persistent profile), MetaProgression.player_mods, MetaProgression.stash_capacity (+5 more)

### Community 94 - "Community 94"
Cohesion: 0.33
Nodes (5): P0 — ДЕФЕКТЫ (статус после Phase 0.5, 2026-08-10), P1 — Системные дизайн-проблемы (консенсус панели), UI Redesign — Phase 0 Audit (2026-08-10), План фаз (правки — после Phase 0), Силы — СОХРАНИТЬ (консенсус)

### Community 95 - "Community 95"
Cohesion: 0.40
Nodes (5): Normalise to PEAK_AMPLITUDE and write a mono 16-bit WAV., Normalise to PEAK_AMPLITUDE and write a mono 16-bit WAV., _write_wav(), str, str

### Community 96 - "Community 96"
Cohesion: 0.67
Nodes (3): _add_tracks(), Add two tracks, extending the shorter one with silence., Add two tracks, extending the shorter one with silence.

### Community 97 - "Community 97"
Cohesion: 0.67
Nodes (3): gen_chunk_concrete(), Concrete crumble: a low sub THUMP + a gritty muffled rubble gurgle (double-lowpa, Concrete crumble: a low sub THUMP + a gritty muffled rubble gurgle (double-lowpa

## Ambiguous Edges - Review These
- `Stash.total_weight` → `WeaponData resource`  [AMBIGUOUS]
  autoload/Stash.gd · relation: shares_data_with
- `WeaponController._load_weapons` → `Version-safe ConfigFile saves`  [AMBIGUOUS]
  scripts/combat/weapon_controller.gd · relation: references

## Knowledge Gaps
- **263 isolated node(s):** `PreToolUse`, `PostToolUse`, `godot-prompter@godot-prompter-marketplace`, `godot@awesome-gamedev-agent-skills`, `disciplines@awesome-gamedev-agent-skills` (+258 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **34 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Stash.total_weight` and `WeaponData resource`?**
  _Edge tagged AMBIGUOUS (relation: shares_data_with) - confidence is low._
- **What is the exact relationship between `WeaponController._load_weapons` and `Version-safe ConfigFile saves`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **Why does `AgentBridge._handle_line (command dispatch)` connect `Community 93` to `AgentBridge QA Commands`, `Community 68`, `Community 69`, `Community 71`, `Community 85`, `Community 90`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `ItemCatalog (id to ItemData)` connect `Core Autoload Singletons` to `Community 90`, `Community 68`?**
  _High betweenness centrality (0.010) - this node is a cross-community bridge._
- **Why does `Events Bus` connect `Community 85` to `AgentBridge QA Commands`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **What connects `PreToolUse`, `PostToolUse`, `godot-prompter@godot-prompter-marketplace` to the rest of the system?**
  _382 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Core Autoload Singletons` be split into smaller, more focused modules?**
  _Cohesion score 0.07926829268292683 - nodes in this community are weakly interconnected._