# Architecture Reference — Hype Raiders

Accurate to the current code. Paths are under `res://` (project root `C:\personal\hype game`).

## 1. Autoloads (registered in `project.godot [autoload]`, in this order)

| Autoload | File | Responsibility |
|---|---|---|
| `Events` | `autoload/Events.gd` | Global signal bus — every system emits/listens here, never references another directly. |
| `AudioManager` | `autoload/AudioManager.gd` | Plays CC0 SFX in reaction to Events. Local/client-side only. |
| `Settings` | `autoload/Settings.gd` | All tunable constants + the `ENEMY_STATS` archetype table. |
| `AssetRegistry` | `autoload/AssetRegistry.gd` | Logical id → CC0 model (with fit transform) or tinted primitive fallback. |
| `GameState` | `autoload/GameState.gd` | Match phase, current wave, peer roster, win/lose resolution. |
| `NetworkManager` | `autoload/NetworkManager.gd` | Listen-server host/join, lobby handshake, match-end broadcast. |
| `AgentBridge` | `autoload/AgentBridge.gd` | Self-play TCP control server (`--agent`). See `docs/TESTING.md`. |

### Key public APIs
- **GameState**: `phase:int` (enum `MENU/LOBBY/LOADING/IN_MATCH/RESULTS`), `current_wave:int`, `peers:Dictionary` (peer_id→{name,ready,alive,extracted}); `register_peer(id,name)`, `mark_dead(id)`, `set_phase(p)`, `reset_match()`, `is_local_authority_server()->bool` (true if no peer OR is_server), `all_players_resolved()->bool`, `all_players_dead()->bool`.
- **NetworkManager**: `is_offline:bool`, `local_player_name:String`; `host_game(port?)`, `join_game(ip?,port?)`, `start_offline()` (uses `OfflineMultiplayerPeer`), `disconnect_game()`; RPCs `notify_loaded()`, `begin_match()`; `broadcast_match_won()/broadcast_match_lost()` (idempotent — no-op if phase already `RESULTS`).
- **AssetRegistry**: `get_model(id)->Node3D`, `get_icon(id)->Texture2D`, `get_color(id)->Color`, `has_id(id)->bool`. CATALOG entry fields: `model` (res-path or ""), `icon`, `prim` (CAPSULE/BOX/SPHERE/CYLINDER), `size`, `color`, optional `model_scale`/`model_rot_deg`/`model_offset`/`model_albedo`.
- **AudioManager**: `_play(id)`, `_play_at(id, node)`, `enabled:bool`, `master_db:float`. Sound ids: shot, hit, explosion, player_death, extract_beep, extract_done, extract_cancel, wave_alert, win, lose.

## 2. Events bus (`autoload/Events.gd`) — full signatures

**Combat**: `damage_dealt(target,amount,source)` · `entity_died(entity,killer)` · `weapon_fired(shooter,weapon_id)` · `damage_number(world_pos,amount,is_crit)`
**Weapons**: `weapon_switched(weapon_id,ammo,reserve)` · `ammo_changed(ammo,reserve)` · `reload_started(weapon_id)` · `reload_finished(weapon_id)` · `ads_changed(player,active)`
**Gadgets**: `grenade_thrown(player,from_pos,dir)` · `grenade_exploded(world_pos,damage,radius)` · `player_healed(player,amount)`
**Player**: `local_player_spawned(player)` · `player_health_changed(player,current,max_health)`
**Loot/Inventory**: `loot_spawned(loot)` · `item_picked_up(player,item_id,count)` · `inventory_changed(inventory)` · `pickup_requested(player,pickup)` (client→server intent)
**Extraction**: `extraction_started(player,zone)` · `extraction_progress(player,ratio)` · `extraction_completed(player)` · `extraction_cancelled(player)`
**Waves/Match**: `wave_started(wave_number,enemy_count)` · `wave_cleared(wave_number)` · `enemy_spawned(enemy)` · `match_won()` · `match_lost()`
**Net/Lobby**: `peer_registered(peer_id,info)` · `peer_unregistered(peer_id)` · `all_players_ready()` · `match_started()`

## 3. Settings (`autoload/Settings.gd`) — values

- **Network**: `DEFAULT_PORT=24565`, `MAX_PLAYERS=4`, `DEFAULT_IP="127.0.0.1"`, `AGENT_PORT=24700`, `NET_DEBUG=false`
- **Player**: `PLAYER_MAX_HEALTH=100`, `PLAYER_MOVE_SPEED=5.5`, `PLAYER_SPRINT_SPEED=8.5`, `PLAYER_JUMP_VELOCITY=7.0`, `MOUSE_SENSITIVITY=0.0025`
- **Camera/ADS/peek**: `CAMERA_PITCH_MIN=-1.2`, `CAMERA_PITCH_MAX=0.6`, `DEFAULT_FOV=60`, `ADS_FOV=42`, `ADS_SENS_SCALE=0.5`, `ADS_SPRING_LENGTH=2.0`, `DEFAULT_SPRING_LENGTH=4.0`, `SHOULDER_OFFSET=0.5`, `AIM_TWEEN_SPEED=10.0`, `PEEK_PROBE=1.4`, `PEEK_SHIFT=0.7`
- **Combat**: `WEAPON_NET_REPLICATION_HZ=30`, `WEAPON_SWITCH_TIME=0.35`
- **Enemy (grunt defaults)**: `ENEMY_MAX_HEALTH=40`, `ENEMY_DETECT_RADIUS=18`, `ENEMY_ATTACK_RANGE=2.2`, `ENEMY_MOVE_SPEED=4.0`, `ENEMY_DAMAGE=8`, `ENEMY_ATTACK_COOLDOWN=1.2`
- **Inventory**: `INVENTORY_COLS=6`, `INVENTORY_ROWS=5`, `INVENTORY_MAX_WEIGHT=50`
- **Extraction**: `EXTRACTION_TIME=8.0`
- **Waves**: `WAVE_BASE_ENEMIES=3`, `WAVE_ENEMY_GROWTH=2`, `WAVE_INTERMISSION=6.0`, `WAVE_MAX_CONCURRENT=6`, `WAVE_SPAWN_INTERVAL=1.2`
- **Gadgets**: `HEAL_AMOUNT=45`, `HEAL_TIME=1.4`, `GRENADE_DAMAGE=70`, `GRENADE_RADIUS=5.5`, `GRENADE_FUSE=1.6`, `GRENADE_THROW_FORCE=15`
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
`move_forward`=W · `move_back`=S · `move_left`=A · `move_right`=D · `jump`=Space · `sprint`=LShift · `fire`=LMB · `aim`=RMB · `reload`=R · `interact`=E · `toggle_inventory`=I · `ui_cancel`=Esc · `shoulder_swap`=Q · `grenade`=G · `heal`=H · `weapon_next`=WheelUp · `weapon_prev`=WheelDown · `weapon_1..5`=1..5

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
| Weapon raycast | — | `0b1000101` = world(1)+enemy(4)+hurtbox(64) | converged shot |

## 6. Key scene trees (abbreviated)
- **`scenes/player/Player.tscn`** (`player.gd`): CollisionShape(capsule) · ModelRoot(AssetRegistry "player") · **WeaponMount**(Marker3D, hand height 0.35,1.1,-0.35) · CameraPivot(y1.5) → SpringArm3D(len 4, x-offset) → Camera3D → **WeaponController**(scene; carries Weapon+Muzzle+ModelHolder) · Health · Inventory · Hurtbox(layer 7) · MultiplayerSynchronizer (pos, rotation, CameraPivot:rotation, Health:current).
- **`scenes/world/Arena.tscn`** (`arena.gd`): WorldEnvironment · DirectionalLight · NavigationRegion3D{Ground 160×160 + Geometry(POI_NorthTower/EastWarehouse/SWHouse/Plaza/SouthYard/EastYard + Scatter)} · Walls(4 perimeter) · PlayerSpawnMarkers(M0–M3) · EnemySpawnMarkers(E0–E10) · POIMarkers(6) · LootCacheMarkers(11) · **ExtractionZone/Zone2/Zone3** (Area3D, `extraction_zone.gd`, layer 5) · **Net**{Players,Enemies,Loot + PlayerSpawner/EnemySpawner/LootSpawner (MultiplayerSpawner)}. `arena.gd` exposes `get_enemy_spawn_point(i)`, `get_poi_points()`, `get_loot_cache_points()`.
  - **Co-op note**: `EnemySpawner._spawnable_scenes` MUST list every enemy scene (RobotEnemy + Tick/Heavy/Wasp/Bastion/Boss) or new archetypes won't replicate to clients.
- **`scenes/enemies/RobotEnemy.tscn`** (`robot_enemy.gd`): CharacterBody3D + CollisionShape + NavigationAgent3D + LineOfSight(RayCast3D) + ModelRoot + Health + Hurtbox + MultiplayerSynchronizer (pos, rotation, Health:current, `current_state:int`). Archetype scenes (Tick/Heavy/Wasp/Bastion/Boss) set the exported `enemy_id` and use `robot_enemy.gd` or its subclasses (`robot_gunner.gd`, `robot_flyer.gd`, `robot_boss.gd`); they also embed `EnemyHealthBar.tscn`.
- **`scenes/combat/WeaponController.tscn`** (`weapon_controller.gd`): Weapon(`weapon.gd`)+Muzzle(Marker3D) · ModelHolder (reparented to Player/WeaponMount at runtime). Loads the 5 `resources/weapons/*.tres`.
- **`scenes/ui/HUD.tscn`** (`hud.gd`): health bar+label, wave label, extraction bar, banner; crosshair (`crosshair.gd`) + minimap (`minimap.gd`) + ammo/weapon readout + key-hints built in code. **`scenes/ui/InventoryUI.tscn`** (`inventory_ui.gd`).
- **`scenes/boot/Main.tscn`** (`main.gd`): UILayer + WorldRoot; parses `--server/--client/--agent`; `restart_match()`. **`scenes/boot/MainMenu.tscn`** (`main_menu.gd`): Single Player / Host / Join.

## 7. Gameplay systems (traces)
- **Player** (`scripts/player/player.gd`): camera-relative WASD + sprint/jump; over-the-shoulder SpringArm; **ADS** lerps FOV/spring-length/offset (per-weapon `current_ads_fov()`); **shoulder-swap** flips `_shoulder_sign`; **peek/lean** side-raycast shifts the camera at wall edges; fires via `_weapon_controller.try_fire(camera)`; `_try_heal()`/`_throw_grenade()`; death → `NetworkManager.broadcast_match_lost()` when all dead.
- **Weapons** (`weapon_controller.gd` + `weapon.gd` + `weapon_data.gd` + 5 `.tres`): per-weapon mag/reserve; semi (once per press, ~0.08s release latch) vs auto; reload (manual + auto-on-empty, fire blocked mid-reload/switch); switching (1-5/wheel, `WEAPON_SWITCH_TIME`, resets cooldown); `weapon.fire_with(camera,data)` does the converged raycast per pellet with spread, crit on weak-point hurtboxes (`damage_multiplier`), and emits `fired`/`hit`/`weapon_fired`/`damage_number`/`ammo_changed`/`weapon_switched`/`reload_*`.
- **Enemies** (`robot_enemy.gd` base; `robot_gunner.gd`→ranged hitscan; `robot_flyer.gd`→hover+strafe+ranged; `robot_boss.gd`→barrage): FSM PATROL/CHASE/ATTACK with hysteresis (`enemy_state_machine.gd`); **hunter** mode (wave-spawned) forces chase ignoring detect/LOS; **separation** steering + `NavigationAgent3D.avoidance_enabled` + body mask so they never blob; per-archetype stats from `ENEMY_STATS`; world-space HP bar; hit-flash; death lingers ~1s to play Death anim + explosion + drop loot + spawn `RobotDebris.tscn`. `Events.entity_died` fires exactly once (Health._die) for wave-clear accounting.
- **Waves** (`wave_manager.gd`, server-only): trickle spawner (≤`WAVE_MAX_CONCURRENT`, every `WAVE_SPAWN_INTERVAL`) from per-wave `WAVE_POOLS` (W1 grunts → W5 boss-once + support); clears when all spawned & dead; survive-all → `broadcast_match_won()`.
- **Loot/Inventory** (`loot_pickup.gd`, `inventory.gd`, `inventory_ui.gd`): server-authoritative pickup → inventory grid (weight cap) → despawn; UI grid with icons/weight bar/value.
- **Extraction** (`extraction_zone.gd`, 3 zones): per-player timer to `EXTRACTION_TIME`; complete → mark extracted; all resolved → win; leave → cancel/reset.
- **Gadgets**: grenade (`grenade.gd`, RigidBody, fuse→radial damage server-only with falloff); heal (instant, consumes a medkit).
- **VFX** (`scripts/fx/*`): muzzle flash, tracer, impact (sparks/oil + world decal), explosion, robot debris, world-space damage numbers (`DamageNumbersLayer` listens to `Events.damage_number`).
- **Networking**: listen-server (host = peer 1 + player); `MultiplayerSpawner` replicates server-spawned entities; player authority from node name in `_enter_tree`; `Hurtbox.apply_hit` routes damage to the owner's authority via RPC; match-end is broadcast idempotently.
