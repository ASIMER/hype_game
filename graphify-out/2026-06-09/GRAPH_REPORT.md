# Graph Report - hype game  (2026-06-09)

## Corpus Check
- 24 files · ~2,014,516 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 495 nodes · 645 edges · 76 communities (41 shown, 35 thin omitted)
- Extraction: 89% EXTRACTED · 11% INFERRED · 0% AMBIGUOUS · INFERRED: 71 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f63fde8f`
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
- [[_COMMUNITY_Community 72|Community 72]]

## God Nodes (most connected - your core abstractions)
1. `float` - 32 edges
2. `_fade()` - 22 edges
3. `_adsr()` - 18 edges
4. `_noise()` - 15 edges
5. `_mix()` - 15 edges
6. `handle_request()` - 12 edges
7. `_sine()` - 12 edges
8. `gen_footstep()` - 12 edges
9. `AgentBridge._handle_line (command dispatch)` - 12 edges
10. `_lowpass()` - 11 edges

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

## Communities (76 total, 35 thin omitted)

### Community 0 - "SFX Audio Synthesizer"
Cohesion: 0.09
Nodes (65): _add_tracks(), _adsr(), _concat(), _fade(), gen_ambient(), gen_explosion(), gen_extract_beep(), gen_extract_cancel() (+57 more)

### Community 1 - "AgentBridge QA Commands"
Cohesion: 0.18
Nodes (11): AgentBridge._debug_spawn, Guarded-fallback resolution (glb to procedural to primitive), AudioManager (Events-driven SFX), AudioManager._play / _play_at, Events (global signal bus), ExtractionDirector (timed evac windows), RemoteShotFX, GameState.is_local_authority_server (+3 more)

### Community 2 - "Core Autoload Singletons"
Cohesion: 0.08
Nodes (41): AssetRegistry, Events bus, GameState, MetaProgression, NetworkManager, Settings, Stash, Export PCK DirAccess fallback to ResourceIndex (+33 more)

### Community 3 - "Combat & Damage Pipeline"
Cohesion: 0.07
Nodes (31): Health component, Health.take_damage, Hurtbox.apply_hit, Hurtbox, WeaponController.try_fire, Weapon.fire_with, Weapon._shoot, Stepped ballistic bullet drop (+23 more)

### Community 4 - "Asset Registry & Fallbacks"
Cohesion: 0.12
Nodes (22): AssetRegistry.CATALOG (logical id table), AssetRegistry.get_icon, AssetRegistry.get_model, AssetRegistry._make_primitive (tinted fallback), Events Bus, Server-Authoritative Inventory Owner-Mirror, ExtractionZone, CameraFX (+14 more)

### Community 5 - "HUD Widgets"
Cohesion: 0.19
Nodes (16): Cached extraction-window state pattern, Local-player binding via Events.local_player_spawned, Compass, DynamicCrosshair, DamageIndicator, HitMarker, HUD._build_hud_widgets, HUD (+8 more)

### Community 6 - "Harness Control Client"
Cohesion: 0.53
Nodes (5): mcp_server.py (MCP bridge), play.py (control client), raw.py (raw JSON sender), Agent harness README, Newline-delimited JSON control protocol

### Community 7 - "Hub Lobby & Quests"
Cohesion: 0.13
Nodes (15): QuestData, QuestData.reward_items, HaulManager, HaulManager._on_recycle, HaulManager._on_sell, Hub (Lobby shell), Hub._on_deploy_pressed, Hub._refresh_squad (+7 more)

### Community 8 - "Visual FX & Ranged Enemies"
Cohesion: 0.08
Nodes (35): _build_prog(), _build_raw(), _error(), handle_request(), _instance_info(), log(), main(), _probe_port() (+27 more)

### Community 9 - "Weapon Data & Attachments"
Cohesion: 0.13
Nodes (14): 1. How `--agent` mode works, 2. Command protocol, 3. `state` JSON schema, 4. Driving it, 5. Validation commands (run after every change), 6. QA workflow (test matrix), 7. Co-op multi-instance testing (instances playing together), 8. Parallel testing (2–4 instances at once) (+6 more)

### Community 10 - "MCP Server Bridge"
Cohesion: 0.20
Nodes (11): AttachmentData.apply_to, WeaponController._apply_attachments, WeaponController._load_weapons, WeaponData resource, CraftRecipe resource, Version-safe ConfigFile saves, ResourceIndex (generated paths), SettingsManager._cmp_version (+3 more)

### Community 11 - "Community 11"
Cohesion: 0.20
Nodes (10): AgentBridge.activate, AgentBridge (self-play control server), Agent-teams parallel work pattern, Decoupled-autoloads-via-Events-bus pattern, OfflineMultiplayerPeer authority model, Hype Raiders Project Guide (CLAUDE.md), Self-play test harness (--agent + play.py), hype-game MCP Server config (+2 more)

### Community 12 - "Server-Auth Co-op Netcode"
Cohesion: 0.20
Nodes (10): Server-authoritative co-op (hit/score/transfer routing), GameState.peers (peer roster), GameState.record_kill / record_death, GameState.reset_match, InventoryUI._give_item, NetworkManager._on_entity_died (kill attribution), NetworkManager.request_hit (server-auth damage), NetworkManager.request_start (leader START) (+2 more)

### Community 13 - "Procedural Buildings"
Cohesion: 0.15
Nodes (12): 10. Server browser & LAN discovery (`autoload/ServerBrowser.gd`), 1. Autoloads (registered in `project.godot [autoload]`, in this order — 17 total), 2. Events bus (`autoload/Events.gd`) — full signatures, 3. Settings (`autoload/Settings.gd`) — values, 4. Input map (`project.godot [input]`), 5. Physics layers (`[layer_names]`), 6. Key scene trees (abbreviated), 7. Gameplay systems (traces) (+4 more)

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
Cohesion: 0.20
Nodes (12): Local Visual-Only FX, RobotGunner._fire_hitscan, RobotGunner._spawn_tracer, RobotGunner._strike, CameraFX._on_hit_stop, Explosion, Impact, MuzzleFlash (+4 more)

### Community 57 - "Community 57"
Cohesion: 0.12
Nodes (16): `game_broadcast` — fan-out to N instances, `game_instances` — discover live instances, `game_raw` — generic forwarder, How the game exposes control, hype-game agent harness, Importable, MCP server, N-instance co-op recipe (+8 more)

### Community 58 - "Community 58"
Cohesion: 0.20
Nodes (9): Agent Teams — Expected Structure & Ownership, Build-phase pattern (how a feature push runs), Canonical roles (workstreams) and their file lanes, Coordination & cross-deps, How to spawn, Team, The core rule: spine vs lanes (no two agents edit the same file), Worked examples (the co-op batches built this way) (+1 more)

### Community 59 - "Community 59"
Cohesion: 0.17
Nodes (11): Architecture at a glance, graphify, Hype Raiders — Project Guide (read me first), Localization (en base + ru; scalable), Parallel work with agent teams, Release / packaging (portable Windows build), Release / packaging (portable Windows + macOS builds), Run / test / validate (most important for a new session) (+3 more)

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
Cohesion: 0.20
Nodes (12): AgentBridge._aim_at (converging camera aim), AgentBridge._handle_line (command dispatch), AgentBridge._snapshot (state JSON), AgentBridge._ui_action (menu open/close), Crafting.craft, MetaProgression (persistent profile), MetaProgression.stash_capacity, Quests._advance / event hooks (+4 more)

### Community 72 - "Community 72"
Cohesion: 0.67
Nodes (3): ExtractionDirector._apply_windows, ServerBrowser.scan_lan, Settings (tunable constants)

## Ambiguous Edges - Review These
- `Stash.total_weight` → `WeaponData resource`  [AMBIGUOUS]
  autoload/Stash.gd · relation: shares_data_with
- `WeaponController._load_weapons` → `Version-safe ConfigFile saves`  [AMBIGUOUS]
  scripts/combat/weapon_controller.gd · relation: references

## Knowledge Gaps
- **180 isolated node(s):** `PreToolUse`, `allow`, `python`, `AGENT_HOST`, `AGENT_PORT` (+175 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **35 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Stash.total_weight` and `WeaponData resource`?**
  _Edge tagged AMBIGUOUS (relation: shares_data_with) - confidence is low._
- **What is the exact relationship between `WeaponController._load_weapons` and `Version-safe ConfigFile saves`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **Why does `AgentBridge._handle_line (command dispatch)` connect `Community 71` to `AgentBridge QA Commands`, `Asset Registry & Fallbacks`, `Community 69`, `Community 68`, `Community 72`, `Server-Auth Co-op Netcode`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._
- **Why does `ItemCatalog (id to ItemData)` connect `Core Autoload Singletons` to `Server-Auth Co-op Netcode`, `Community 68`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Why does `Events Bus` connect `Asset Registry & Fallbacks` to `Community 56`, `AgentBridge QA Commands`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **What connects `PreToolUse`, `allow`, `python` to the rest of the system?**
  _238 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `SFX Audio Synthesizer` be split into smaller, more focused modules?**
  _Cohesion score 0.09044289044289044 - nodes in this community are weakly interconnected._