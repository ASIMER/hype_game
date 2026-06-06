# Architecture Reference — Hype Raiders

Accurate to the current code. Paths are under `res://` (project root `C:\personal\hype game`).

## 1. Autoloads (registered in `project.godot [autoload]`, in this order — 17 total)

| Autoload | File | Responsibility |
|---|---|---|
| `Events` | `autoload/Events.gd` | Global signal bus — every system emits/listens here, never references another directly. |
| `AudioManager` | `autoload/AudioManager.gd` | Plays CC0 SFX in reaction to Events. Local/client-side only. |
| `Settings` | `autoload/Settings.gd` | All tunable constants + the `ENEMY_STATS` archetype table + `difficulty_mods()` + `user_path()`. |
| `AssetRegistry` | `autoload/AssetRegistry.gd` | Logical id → CC0 model / `ProceduralModels` builder / tinted primitive fallback. |
| `IconRenderer` | `autoload/IconRenderer.gd` | Off-screen SubViewport model→texture renderer (inventory icons + model-QA hero shots). |
| `ItemCatalog` | `autoload/ItemCatalog.gd` | Scans `resources/items/*.tres` → `id → ItemData` (shared by loot/stash/loadout/craft). |
| `GameState` | `autoload/GameState.gd` | Match phase, wave, peer roster, kills/deaths, match timer, win/lose resolution. |
| `MetaProgression` | `autoload/MetaProgression.gd` | Persistent profile (`profile.cfg`): currency, unlocks, upgrades, loadout, attachments, perks, dailies. |
| `Stash` | `autoload/Stash.gd` | Persistent item stash (`stash.cfg`) with a hard weight cap; the at-risk economy. |
| `Crafting` | `autoload/Crafting.gd` | Data-driven recipes (`resources/recipes/*.tres`): craft / recycle / buy blueprint. |
| `Quests` | `autoload/Quests.gd` | Data-driven contracts (`resources/quests/*.tres`) + daily rotation. |
| `NetworkManager` | `autoload/NetworkManager.gd` | Host/join, lobby handshake, server-authoritative combat/item/score sync, match-end broadcast. |
| `RaidManager` | `autoload/RaidManager.gd` | Per-player raid economy: `deploy()` commits bring-list+attachments; `grant_extraction()` deposits the haul. |
| `ExtractionDirector` | `autoload/ExtractionDirector.gd` | Rotates per-zone timed extraction windows. |
| `AgentBridge` | `autoload/AgentBridge.gd` | Self-play TCP control server (`--agent`). See `docs/TESTING.md`. |
| `SettingsManager` | `autoload/SettingsManager.gd` | Loads/applies/persists graphics/audio/controls settings (`settings.cfg`). |
| `ServerBrowser` | `autoload/ServerBrowser.gd` | Local server list (favorites + recents, `favorites.cfg`) + LAN UDP discovery. |

### Key public APIs
- **GameState**: `phase:int` (enum `MENU/LOBBY/LOADING/IN_MATCH/RESULTS`), `current_wave:int`, `difficulty:int` (`EASY/NORMAL/HARD`), `peers:Dictionary` (peer_id→{name,ready,alive,extracted}); kill-board fields `kills:Dictionary`, `deaths:Dictionary`, `mobs_killed:int`; match-timer fields `match_duration`/`match_time_left:float`, `final_wave:bool`. Methods: `register_peer(id,name)`, `unregister_peer(id)`, `set_phase(p)`, `reset_match()`, `mark_dead(id)`, `set_peer_ready(id,ready)`, `record_kill(peer)`, `record_death(peer)`, `is_local_authority_server()->bool` (no peer OR is_server), `local_peer_id()->int` (1 offline/host), `is_leader()->bool` (== authority-server), `squad_all_ready()->bool` (all non-host peers ready), `all_players_resolved()`, `all_players_dead()`, `match_timer_ratio()`, `difficulty_name()`.
- **NetworkManager**: `is_offline:bool`, `local_player_name:String`; `host_game(port?)`, `join_game(ip?,port?)`, `start_offline()` (uses `OfflineMultiplayerPeer`), `disconnect_game()`. Lobby RPCs: `set_ready(ready)`, `request_start()->bool` (leader, gated on `squad_all_ready`), `_begin_deploy()` (→ `Events.begin_deploy`), `notify_loaded()`, `begin_match()`. State mirrors: `sync_wave(wave,count)`, `sync_wave_cleared(wave)`, `sync_match_timer(left,total,final_wave)`. Combat/items: `request_hit(path,amount,peer)`, `broadcast_shot(muzzle,hit,arc,enemy_hit,normal)`, `transfer_item(from,to,id,count)->int`, `request_split(peer,id,amount)`, `nearest_teammate(peer)->int`. Match-end: `broadcast_match_won()/broadcast_match_lost()` (idempotent — no-op if phase already `RESULTS`).
- **AssetRegistry**: `get_model(id)->Node3D`, `get_icon(id)->Texture2D`, `get_color(id)->Color`, `has_id(id)->bool`. CATALOG entry: `model`, `icon`, `prim`, `size`, `color`, optional `model_scale`/`model_rot_deg`/`model_offset`/`model_albedo`.
- **AudioManager**: `_play(id)`, `_play_at(id,node)`, `enabled:bool`, `master_db:float`.

## 2. Events bus (`autoload/Events.gd`) — full signatures

**Combat**: `damage_dealt(target,amount,source)` · `entity_died(entity,killer)` · `weapon_fired(shooter,weapon_id)` · `damage_number(world_pos,amount,is_crit)`
**Weapons/loadout**: `weapon_switched(weapon_id,ammo,reserve)` · `ammo_changed(ammo,reserve)` · `reload_started(weapon_id)` · `reload_finished(weapon_id)` · `ads_changed(player,active)`
**Gadgets/survival**: `grenade_thrown(player,from_pos,dir)` · `grenade_exploded(world_pos,damage,radius)` · `player_healed(player,amount)`
**Player**: `local_player_spawned(player)` · `player_health_changed(player,current,max_health)`
**Loot/Inventory**: `loot_spawned(loot)` · `item_picked_up(player,item_id,count)` · `inventory_changed(inventory)` · `pickup_requested(player,pickup)` (client→server intent)
**Extraction**: `extraction_started(player,zone)` · `extraction_progress(player,ratio)` · `extraction_completed(player)` · `extraction_cancelled(player)`
**Waves/Match flow**: `wave_started(wave_number,enemy_count)` · `wave_cleared(wave_number)` · `enemy_spawned(enemy)` · `match_won()` · `match_lost()` · `match_timer_changed(left,total)` · `final_wave_started()`
**Extraction windows**: `extraction_window_changed(zone,open,remaining)`
**Map UI**: `map_toggled(open)`
**Co-op combat/scoreboard**: `remote_shot(muzzle,hit_point,arc,enemy_hit,normal)` · `scoreboard_changed()`
**Co-op item interactions**: `item_received(from_peer,item_id,count)`
**Server browser/favorites**: `favorites_changed()` · `lan_scan_started()` · `lan_servers_found(servers:Array)`
**UI/UX**: `interaction_available(prompt,target)` · `interaction_cleared()` · `notify(text,kind)` (kind 0 info/1 good/2 bad/3 wave) · `stamina_changed(current,max_stamina)` · `item_use_requested(item_id)` · `game_paused(paused)`
**Meta-progression/game feel**: `currency_changed(amount)` · `run_rewards(currency,breakdown)` · `hit_stop(duration)` · `screen_shake(amount)` · `footstep(player,sprinting)`
**Stash/raid economy**: `stash_changed()` · `raid_loot_granted(payload,bonus)`
**Crafting/quests**: `blueprint_learned(blueprint)` · `quest_progress(quest_id,current,target)` · `quest_completed(quest_id)` · `dailies_rotated()`
**Gunsmith/haul**: `attachment_changed(weapon_id)` · `weapon_perk_changed(weapon_id)` · `haul_overflow(incoming,over_by)`
**Networking/lobby**: `peer_registered(peer_id,info)` · `peer_unregistered(peer_id)` · `all_players_ready()` · `match_started()` · `squad_changed()` · `begin_deploy()`

## 3. Settings (`autoload/Settings.gd`) — values

- **Network**: `DEFAULT_PORT=24565`, `MAX_PLAYERS=8` (ENet listen-server cap), `DEFAULT_IP="127.0.0.1"`, `DISCOVERY_PORT=24566` (LAN-discovery UDP, separate from the game port), `GAME_VERSION="0.1.0"` (stamped into saves), `AGENT_PORT=24700`, `NET_DEBUG=false`
- **Multi-instance** (parallel agent testing): runtime `agent_port`/`instance_tag` parsed from `--agent-port N` in `_ready()`; `user_path(base,ext)` → `user://<base>.<ext>` (single) or `user://<base>_N.<ext>` (per-instance)
- **Player**: `PLAYER_MAX_HEALTH=100`, `PLAYER_MOVE_SPEED=5.5`, `PLAYER_SPRINT_SPEED=8.5`, `PLAYER_JUMP_VELOCITY=7.0`, `MOUSE_SENSITIVITY=0.0025`, `CAMERA_PITCH_MIN=-1.2`, `CAMERA_PITCH_MAX=0.6`
- **Camera/ADS/peek**: `DEFAULT_FOV=60`, `ADS_FOV=42`, `ADS_SENS_SCALE=0.5`, `ADS_SPRING_LENGTH=2.0`, `DEFAULT_SPRING_LENGTH=4.0`, `SHOULDER_OFFSET=0.5`, `AIM_TWEEN_SPEED=10.0`, `PEEK_PROBE=1.4`, `PEEK_SHIFT=0.7`
- **Combat/weapons**: `WEAPON_NET_REPLICATION_HZ=30`, `WEAPON_SWITCH_TIME=0.35`
- **Ballistics (bullet drop)**: `BULLET_GRAVITY=9.8`, `BULLET_MUZZLE_VELOCITY=120.0`, `BULLET_STEP=2.5` (per-weapon `muzzle_velocity` may override)
- **Enemy (grunt defaults)**: `ENEMY_MAX_HEALTH=40`, `ENEMY_DETECT_RADIUS=18`, `ENEMY_ATTACK_RANGE=2.2`, `ENEMY_MOVE_SPEED=4.0`, `ENEMY_DAMAGE=8`, `ENEMY_ATTACK_COOLDOWN=1.2`
- **Inventory**: `INVENTORY_COLS=6`, `INVENTORY_ROWS=5`, `INVENTORY_MAX_WEIGHT=50`
- **Extraction**: `EXTRACTION_TIME=8.0`; timed windows `EXTRACT_OPEN_DURATION=75`, `EXTRACT_COOLDOWN=35`, `EXTRACT_WINDOW_STAGGER=28`
- **Match timer / storm**: `MATCH_DURATION=540` (9 min), `FINAL_WAVE_WARN=30`, `FINAL_WAVE_COUNT_MULT=3.5`, `FINAL_WAVE_CONCURRENT=18`, `FINAL_WAVE_SPAWN_INTERVAL=0.5`
- **Atmosphere**: `ATMOSPHERE_DUST=90`, `ATMOSPHERE_EMBERS=40`, `STORM_TWEEN_TIME=6.0`
- **Waves**: `WAVE_BASE_ENEMIES=3`, `WAVE_ENEMY_GROWTH=2`, `WAVE_INTERMISSION=6.0`, `WAVE_MAX_CONCURRENT=6`, `WAVE_SPAWN_INTERVAL=1.2`
- **Gadgets**: `HEAL_AMOUNT=45`, `HEAL_TIME=1.4`, `GRENADE_DAMAGE=70`, `GRENADE_RADIUS=5.5`, `GRENADE_FUSE=1.6`, `GRENADE_THROW_FORCE=15`
- **Stamina/interaction**: `MAX_STAMINA=100`, `STAMINA_DRAIN=28`, `STAMINA_REGEN=22`, `STAMINA_SPRINT_MIN=10`, `INTERACT_RANGE=3.5`
- **Difficulty**: `DIFFICULTY_MODS` (EASY/NORMAL/HARD → enemy_health/enemy_damage/enemy_count/player_damage mults); `difficulty_mods(d=-1)` falls back to Normal.
- **Runtime-mutable** (driven by SettingsManager): `mouse_sensitivity`, `fov`, `sfx_volume`, `invert_y`, `ads_toggle`
- **`ENEMY_STATS` dict** (per archetype: health/speed/damage/detect/attack_range/cooldown/score, plus flags flying/hover/ranged/burst):

| id | health | speed | dmg | detect | atk_range | cd | flags |
|---|---|---|---|---|---|---|---|
| robot_grunt | 40 | 4.0 | 8 | 18 | 2.2 | 1.2 | — |
| robot_heavy | 95 | 2.8 | 14 | 18 | 2.6 | 1.6 | — |
| robot_tick | 14 | 6.6 | 5 | 22 | 1.6 | 0.8 | — |
| robot_wasp | 22 | 5.2 | 6 | 26 | 15 | 1.4 | flying, hover 4.5, ranged |
| robot_bastion | 170 | 2.2 | 10 | 28 | 20 | 0.25 | ranged, burst |
| robot_boss | 650 | 2.6 | 22 | 45 | 22 | 0.4 | ranged |

## 4. Input map (`project.godot [input]`)
`move_forward`=W · `move_back`=S · `move_left`=A · `move_right`=D · `jump`=Space · `sprint`=LShift · `fire`=LMB · `aim`=RMB · `reload`=R · `interact`=E · `toggle_inventory`=I · `map`=M · `ui_cancel`=Esc · `scoreboard`=TAB · `trade`=T · `shoulder_swap`=Q · `grenade`=G · `heal`=H · `weapon_next`=WheelUp · `weapon_prev`=WheelDown · `weapon_1..5`=1..5

## 5. Physics layers (`[layer_names]`)
1 `world` · 2 `player` · 3 `enemy` · 4 `loot` · 5 `extraction` · 6 `hitbox` (unused) · 7 `hurtbox`

| Node | layer | mask | notes |
|---|---|---|---|
| Player (CharacterBody3D) | 2 | 1 | walks world |
| Player/Enemy Hurtbox (Area3D) | 7 | 0 | hit receiver; weapon rays mask it |
| Enemy ground (CharacterBody3D) | 3 | 1\|2\|4 (world+player+enemy) | blocks player + each other |
| Enemy flyer (wasp) | 3 | 1 | world only; separation via steering |
| Loot (Area3D) | 4 (loot) | 2 (player) | overlap to pick up |
| Extraction zone (Area3D) | 5 (=16) | 2 (player) | timer trigger |
| Weapon raycast | — | `0b1000101` = world(1)+enemy(3)+hurtbox(7) | converged ballistic shot |

## 6. Key scene trees (abbreviated)
- **`scenes/player/Player.tscn`** (`player.gd`): CollisionShape(capsule) · ModelRoot(AssetRegistry "player") · **WeaponMount**(Marker3D, hand height) · CameraPivot(y1.5) → SpringArm3D(len 4, x-offset) → Camera3D → **WeaponController**(scene; carries Weapon+Muzzle+ModelHolder) · Health · Inventory · Hurtbox(layer 7) · MultiplayerSynchronizer. **The synchronizer replicates `position`, `rotation`, `CameraPivot:rotation`, `Health:current`, `_medkits`, `_grenades` — it does NOT replicate the Inventory `stacks`** (they hold `ItemData` refs), hence the server→owner inventory mirror (see §8).
- **`scenes/world/Arena.tscn`** (`arena.gd`): WorldEnvironment · DirectionalLight · NavigationRegion3D{Ground 160×160 + Geometry(procedural POI structures built before bake + Scatter rubble)} · Walls(4 perimeter) · PlayerSpawnMarkers(4) · EnemySpawnMarkers · POIMarkers · LootCacheMarkers · **ExtractionZone/Zone2/Zone3** (Area3D, `extraction_zone.gd`, layer 5) · **Net**{Players,Enemies,Loot + PlayerSpawner/EnemySpawner/LootSpawner (MultiplayerSpawner)}. `arena.gd` swaps cube POIs for `ProceduralBuildings` (themed per POI, courtyards around evac zones), enriches the ground, bakes the navmesh, then adds a `WaveManager`. Exposes `get_enemy_spawn_point(i)`, `snap_to_navmesh(pos)`, `get_poi_points()`, `get_loot_cache_points()`.
  - **Co-op note**: `EnemySpawner._spawnable_scenes` MUST list every enemy scene (RobotEnemy + Tick/Heavy/Wasp/Bastion/Boss) or new archetypes won't replicate to clients.
- **`scenes/enemies/RobotEnemy.tscn`** (`robot_enemy.gd`): CharacterBody3D + CollisionShape + NavigationAgent3D + LineOfSight(RayCast3D) + ModelRoot + Health + Hurtbox + MultiplayerSynchronizer (pos, rotation, Health:current, `current_state:int`). Archetype scenes set `enemy_id` + use `robot_enemy.gd` / `robot_gunner.gd` / `robot_flyer.gd` / `robot_boss.gd`; embed `EnemyHealthBar.tscn`.
- **`scenes/combat/WeaponController.tscn`** (`weapon_controller.gd`): Weapon(`weapon.gd`)+Muzzle(Marker3D) · ModelHolder (reparented to Player/WeaponMount at runtime). `_load_weapons()` duplicates each `WeaponData` then layers difficulty + `player_mods` → permanent perks → equipped attachments (read locally from `MetaProgression`, so co-op is per-peer).
- **`scenes/ui/HUD.tscn`** (`hud.gd`): health bar, wave label, extraction bar, banner, match timer + storm banner; crosshair (`crosshair.gd`) + minimap (`minimap.gd`, mirrors window state) + ammo/weapon readout. **`scenes/ui/InventoryUI.tscn`** (`inventory_ui.gd`): grid; right-click context menu = Use / Drop / Split / **Give** (to nearest teammate, co-op).
- **`scenes/ui/Hub.tscn`** (`hub.gd`): the between-match **LOBBY**. Tabs STASH / LOADOUT / WORKSHOP / SHOP / QUESTS / **GUNSMITH** (`scenes/ui/tabs/*Tab.tscn`, instanced in `_ready`; missing → "Coming soon" placeholder), a difficulty selector, BACK + a context-aware DEPLOY footer button (solo/host = START RAID; client = READY/UNREADY toggle). In co-op it builds a bottom **SQUAD roster strip** of `● nick` chips with colored status dots (amber=leader, green=ready, yellow=waiting), driven by `Events.squad_changed`/`peer_registered`/`peer_unregistered`. `_ready` calls `MetaProgression.reconcile_attachments()` (drops attachments lost on a failed raid).
- **`scenes/ui/Scoreboard.tscn`** (`scoreboard.gd`): in-raid TAB leaderboard (held). Renders the synced `GameState.kills/deaths/mobs_killed/peers` (sorted by kills desc, local row highlighted, team-total footer) — never computes anything; `mouse_filter=IGNORE`, starts hidden.
- **`scenes/ui/TradeUI.tscn`** (`trade_ui.gd`): two-sided player-to-player trade window (see §8). Instanced once per peer at the same tree path so RPCs route.
- **`scenes/ui/ServerBrowser.tscn`** (`server_browser.gd`): main-menu overlay — direct-connect by IP, SCAN LAN, FAVORITES + RECENT lists. Owns no networking; emits `connect_requested(ip,port)` / `closed`; reads through the `ServerBrowser` autoload + Events.
- **`scenes/boot/Main.tscn`** (`main.gd`): UILayer + WorldRoot; parses `--server/--client/--agent[--menu]`; owns the hub/deploy flow, pause menu, raid-summary, haul-manager, and `restart_match()`. Instances the in-raid UI + `RemoteShotFX.new()` (non-headless) in `load_arena()`. **`scenes/boot/MainMenu.tscn`** (`main_menu.gd`): Single Player / Host / Join / **SERVERS** (opens the server browser) / Settings / Quit. The `_join(ip,port)` flow is shared by the JOIN button and the browser, with explicit connection-FAILURE feedback.

## 7. Gameplay systems (traces)
- **Player** (`scripts/player/player.gd`): camera-relative WASD + sprint/jump; over-the-shoulder SpringArm; **ADS** lerps FOV/spring-length/offset (per-weapon `current_ads_fov()`); **shoulder-swap** flips `_shoulder_sign`; **peek/lean** side-raycast; body yaw applied at render rate; fires via `_weapon_controller.try_fire(camera)`; `_try_heal()`/`_throw_grenade()`; death → `broadcast_match_lost()` when all dead. `_net_place(pos)` is RPC'd by the server so a client spawns at its assigned marker.
- **Weapons** (`weapon_controller.gd` + `weapon.gd` + `weapon_data.gd` + 5 `.tres`): per-weapon mag/reserve; semi vs auto; reload (manual + auto-on-empty); switching (1-5/wheel, `WEAPON_SWITCH_TIME`). `weapon.fire_with(camera,data)` runs the converged two-stage raycast per pellet: a camera ray finds the crosshair aim point, then a **stepped ballistic raycast** marches a projectile from the chest toward it under `BULLET_GRAVITY` (segments of `BULLET_STEP`, capped at 40), so shots arc (bullet drop); the tracer follows the arc points. Crit on weak-point hurtboxes (`damage_multiplier`) adds screen-shake (+ hit-stop offline only). Emits `fired`/`fired_arc`/`hit`/`weapon_fired`/`damage_number`/`ammo_changed`/`weapon_switched`/`reload_*`. See §8 for the server-authoritative damage routing.
- **Enemies** (`robot_enemy.gd` base; `robot_gunner.gd`/`robot_flyer.gd`/`robot_boss.gd`): FSM PATROL/CHASE/ATTACK with hysteresis (`enemy_state_machine.gd`); **hunter** mode forces chase; **separation** steering + `NavigationAgent3D.avoidance_enabled`; per-archetype stats from `ENEMY_STATS`; world-space HP bar; hit-flash; death lingers ~1s (Death anim + explosion + drop loot + `RobotDebris.tscn`). `Events.entity_died` fires exactly once (Health._die) for wave-clear + kill accounting. Per-frame idle anim driven from `_process`.
- **Waves** (`wave_manager.gd`, server-only): trickle spawner (≤`WAVE_MAX_CONCURRENT`, every `WAVE_SPAWN_INTERVAL`) from per-wave pools; counts `GameState.match_time_left` down from `MATCH_DURATION` and at 0 sets `final_wave` + floods the **storm wave** (`FINAL_WAVE_*`), forcing extraction; mirrors wave + timer to clients via `sync_wave`/`sync_match_timer`. Survive-all → `broadcast_match_won()`.
- **Extraction** (`extraction_zone.gd`, 3 zones + `ExtractionDirector`): per-player timer to `EXTRACTION_TIME`; only an OPEN zone makes progress; the Director rotates timed windows (`is_open()/window_remaining()/set_window()`, staggered) and forces all open during the storm; complete → mark extracted; all resolved → win.
- **Loot/Inventory** (`loot_pickup.gd`, `inventory.gd`, `inventory_ui.gd`): server-authoritative pickup → inventory grid (weight cap) → despawn. The Inventory is server-auth but NOT auto-replicated, so after any server-side change it mirrors its serialized `{id,count}` stacks to the OWNING client (see §8). UI grid with icons/weight bar/value + sort + filter; right-click Use/Drop/Split/Give.
- **Gadgets**: grenade (`grenade.gd`, RigidBody, fuse→radial damage server-only with falloff); heal (instant, consumes a medkit).
- **VFX** (`scripts/fx/*`): muzzle flash, ballistic tracer chain, impact (sparks/oil + decal, oriented to the hit normal), explosion, robot debris, world-space damage numbers, hit-marker. `RemoteShotFX` renders teammates' shots.
- **The M Tactical Map** (`scenes/ui/MapUI.tscn`): POIs, every evac zone (open/closed + countdown), player, enemies, match clock; toggled via `Events.map_toggled`.

## 8. Co-op netcode (`autoload/NetworkManager.gd` + per-system hooks)
Listen-server model: host = peer 1 AND a player. `MultiplayerSpawner` replicates server-spawned entities; player authority is derived from the node name (`str(peer_id)`) in `_enter_tree`. Single-player uses an `OfflineMultiplayerPeer` so the same authority-gated code runs offline.

- **Lobby / deploy handshake**: a client `_register_self` → server `_broadcast_roster`. Clients toggle `set_ready` (re-broadcasts roster + `squad_changed`). The leader's `request_start()` (server-only, gated on `LOBBY`-reset + `GameState.squad_all_ready()`) calls `reset_match()`, clears `_loaded`, and `_begin_deploy.rpc()` (`call_local` → `Events.begin_deploy` on EVERY peer). Each peer's `main._do_deploy` commits the bring-list then `load_arena()` → `notify_loaded.rpc_id(1)`; once `_all_loaded()` the server fires `begin_match.rpc()`. Players spawn ONLY in `arena._on_match_started`, which sweeps `GameState.peers` via the idempotent `_ensure_player_spawned`. A client's spawn position is sent with `player._net_place.rpc_id(peer_id, origin)` (the client owns its transform and ignores the server's spawn position).
- **Server-authoritative combat** (`weapon.gd._shoot`): the host (`GameState.is_local_authority_server()`) calls `hb.apply_hit(dealt, shooter)` directly; a CLIENT instead calls `NetworkManager.request_hit(hb.get_path(), dealt, peer)` → `_hit_rpc.rpc_id(1,...)` → `_do_hit`, so the SERVER applies damage to the authoritative enemy. A client's local `apply_hit` would only hit its own copy → the enemy would never die. **NO client-side hit prediction.**
- **Shot-FX sync**: every shot calls `NetworkManager.broadcast_shot(muzzle,hit_point,arc,enemy_hit,normal)` → `_shot_rpc` (unreliable) → `Events.remote_shot` → `scripts/fx/remote_shot_fx.gd` spawns muzzle/tracer/impact on the OTHER peers (the shooter already spawned its own locally via the `fired` signal).
- **Inventory mirror** (`inventory.gd`): server-auth. `_notify()` → `_push_to_owner()` (server only, skipped for the host's own inventory) → `_apply_remote.rpc_id(owner, serialized)` rebuilds the client's `stacks` from `ItemCatalog`. `split_stack(id,amount)` splits a stack in place (mirrored the same way).
- **Kill leaderboard** (`NetworkManager._on_entity_died` → `_peer_of` → `GameState.record_kill/record_death`): on the server, attributes each mob kill to the killer's peer (unattributed kills still count to `mobs_killed`), then `_sync_scores.rpc(kills,deaths,total)` to all + `Events.scoreboard_changed`. Player deaths increment `deaths`. Shown by `scripts/ui/scoreboard.gd` while TAB is held.
- **Item sharing**: `transfer_item(from,to,id,count)` is a server-auth atomic move (validates the source has it + the target has room; refunds leftovers; emits `item_received` + `_notify_received` toast). Clients route through `_transfer_rpc` (sender must be `from_peer`). `request_split` and `nearest_teammate(peer)` (nearest OTHER player by world distance) support the UI GIVE/SPLIT (`inventory_ui.gd`) and the two-sided `trade_ui.gd`, where the host (peer 1) arbitrates the final swap via `_rpc_finalize` → `transfer_item` both directions.
- **Scale & disconnect**: `MAX_PLAYERS=8`. With only 4 markers, `arena._ensure_player_spawned` offsets extras (`index ≥ marker_count`) around their marker on a golden-angle ring so 5–8 players don't stack. `_on_peer_disconnected` despawns the dropped player's body (freeing on the authority replicates the removal) and re-checks win/lose.
- **HUD parity**: `sync_wave`/`sync_wave_cleared`/`sync_match_timer` mirror server-only wave + timer state to clients (`_rpc_*` handlers re-emit the matching Events so co-op HUDs match; the timer RPC is `unreliable_ordered`).
- **Match end**: `broadcast_match_won()/_lost()` → `_rpc_match_*` (`call_local`, idempotent — no-op if already `RESULTS`). Offline/single-player emits locally.

## 9. Persistence & versioning
Four ConfigFile saves, each per-instance via `Settings.user_path(base,ext)` (the `--agent-port` suffix keeps concurrent instances from clobbering each other). Saves are **per-peer-LOCAL** — each co-op peer keeps its own stash; `RaidManager` deposits the haul on extract.

| File | Autoload | Contents |
|---|---|---|
| `profile.cfg` | `MetaProgression.gd` | currency, unlocked weapons, upgrades, loadout, bring-list, blueprints, quest progress, equipped attachments, weapon perks, dailies, difficulty |
| `stash.cfg` | `Stash.gd` | the persistent `{id,count}` item stash |
| `settings.cfg` | `SettingsManager.gd` | graphics/audio/controls (in a `settings` section) |
| `favorites.cfg` | `ServerBrowser.gd` | server favorites + MRU recents |

Versioning pattern (identical in all four): on save, write `save_version=Settings.GAME_VERSION` (in `meta` for profile/stash, a `_meta` section for settings/favorites). On load, read it, run `_cmp_version` (positional `.`-split int compare), and load EVERY field defensively (missing stamp = legacy = compatible; malformed/newer-shaped values default that field only, never aborting the load). If the save is from a NEWER build, `push_warning` + `Events.notify(..., 2)` ONCE per file per session (`_warned_newer`). `MetaProgression._migrate()` is a no-op compat hook for future field-shape changes; `_load_nested_dict` guards the weapon→{slot/perk→value} dicts.

## 10. Server browser & LAN discovery (`autoload/ServerBrowser.gd`)
Pure client-side convenience — it never touches the authoritative netcode.
- **Lists**: `favorites` (persisted) + MRU `recents` (capped at `RECENTS_CAP=8`), saved to `favorites.cfg`. API: `parse_addr("ip[:port]")` (blank → `DEFAULT_IP`/`DEFAULT_PORT`; no IPv6 brackets), `get_favorites()/get_recents()`, `is_favorite()`, `add_favorite(name,ip,port)`, `remove_favorite(ip,port)`, `record_connect(ip,port,name)` (called on a successful join). Each mutation emits `Events.favorites_changed`.
- **LAN discovery** (`_process`): a **host** auto-binds a UDP responder on `Settings.DISCOVERY_PORT=24566` (only while actually hosting and not offline) and answers `HYPE_DISCOVER?` pings with a JSON `{name,port,players,max}`. `scan_lan(timeout=1.5)` broadcasts the ping to `255.255.255.255` AND `127.0.0.1` (so same-machine multi-instance testing works), fires `Events.lan_scan_started`, collects deduped replies into `last_found` for the window, then emits `Events.lan_servers_found(servers)`.
- **UI**: `scenes/ui/ServerBrowser.tscn` + `scripts/ui/server_browser.gd` (centered overlay; `open()/close()`, `connect_requested(ip,port)`/`closed`). The menu's `main_menu._join(ip,port)` runs the actual ENet connect with success (open the client Hub + `record_connect`) and FAILURE feedback. The SERVERS button lives in `MainMenu.tscn`.
