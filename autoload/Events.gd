extends Node
## Global signal bus. Decouples systems so workstreams never reference each other
## directly — they emit/listen here. Add signals as systems need them.

# --- Combat ---
signal damage_dealt(target: Node, amount: float, source: Node)
signal entity_died(entity: Node, killer: Node)
signal weapon_fired(shooter: Node, weapon_id: String)
## Floating damage feedback (world position of the hit). is_crit styles it.
signal damage_number(world_pos: Vector3, amount: float, is_crit: bool)

# --- Weapons / loadout ---
signal weapon_switched(weapon_id: String, ammo: int, reserve: int)
signal ammo_changed(ammo: int, reserve: int)
signal reload_started(weapon_id: String)
signal reload_finished(weapon_id: String)
signal ads_changed(player: Node, active: bool)

# --- Gadgets / survival ---
signal grenade_thrown(player: Node, from_pos: Vector3, dir: Vector3)
signal grenade_exploded(world_pos: Vector3, damage: float, radius: float)
signal player_healed(player: Node, amount: float)
## The local player's selected grenade type changed (B cycles) — drives the HUD chip.
signal grenade_selection_changed(type: String, count: int)
## A deployable gadget was placed / ran out (HUD + SFX; world nodes replicate anyway).
signal gadget_placed(player: Node, type: String, world_pos: Vector3)
signal gadget_expired(type: String, world_pos: Vector3)
## A robot was EMP-stunned for `duration` seconds (FX/SFX hook; server-side gameplay).
signal enemy_stunned(enemy: Node, duration: float)

# --- Movement (batch A) ---
signal player_rolled(player: Node)
signal player_mantled(player: Node)
signal zipline_ride_started(player: Node, zipline: Node)

# --- World & raid (batch C) ---
## A locked annex door was opened (fires on EVERY peer via the door's call_local RPC —
## UI/SFX hook; the door panel itself animates locally).
signal door_opened(door: Node)
## The raid mutator for THIS match ("" = none). Re-emitted on every sync so late HUD
## instances catch it; drives the HUD banner + map label.
signal raid_mutator_changed(mutator: String)
## An extraction zone was force-opened (paid charge / signal flare) for `seconds`.
signal extraction_force_opened(zone: Node, seconds: float)

# --- Power caches / timed buffs (Vampire-Survivors-style) ---
## A power cache was opened by `player`. The opener's HUD plays the non-blocking side reveal.
signal power_cache_opened(player: Node, cache: Node)
## Drive the LOCAL reveal reel: spin then land on `power_id`. Fires on the opener only.
signal power_reveal_started(power_id: String)
## A timed buff became active / expired on `player` (HUD active-buff strip + FX).
signal buff_applied(player: Node, power_id: String, duration: float)
signal buff_expired(player: Node, power_id: String)

# --- Player ---
signal local_player_spawned(player: Node)
signal player_health_changed(player: Node, current: float, max_health: float)
## Co-op downed/revive loop. A player entered the DOWNED state (bleedout, crawl, awaiting
## revive) — `by` is the killer/source. Revived = brought back up (by a teammate or self).
## bleedout = the downed timer expired → true death. All server-authoritative; HUD + AI listen.
signal player_downed(player: Node, by: Node)
signal player_revived(player: Node, by: Node)
signal player_bleedout(player: Node)
## Local reviver's hold-to-revive channel progress (HUD only, fires on the reviver). frac
## 0..1 while holding E to revive `target`; frac < 0 (target null) = channel cleared/ended.
signal revive_channel(frac: float, target: Node)
## A squad ping was placed (comms). kind: 0 generic/go-here, 1 enemy, 2 loot, 3 extraction,
## 4 help/danger, 5 thanks, 6 regroup. world_pos = marker location; target_path = pinged node (optional).
signal ping_placed(peer_id: int, kind: int, world_pos: Vector3, target_path: NodePath)

## The LOCAL player's water submersion state changed (cosmetic, authority-only — emitted
## only by the authority player so a remote peer wading never tints YOUR screen).
## state: 0 DRY, 1 WADING (feet/legs in water, head above), 2 SUBMERGED (camera underwater).
## world_pos is the player's position at the transition (splash/ripple origin).
signal water_state_changed(state: int, world_pos: Vector3)

# --- Loot / Inventory ---
signal loot_spawned(loot: Node)
signal item_picked_up(player: Node, item_id: String, count: int)
signal inventory_changed(inventory: Node)
signal pickup_requested(player: Node, pickup: Node)  # client -> server intent

# --- Extraction ---
signal extraction_started(player: Node, zone: Node)
signal extraction_progress(player: Node, ratio: float)
signal extraction_completed(player: Node)
signal extraction_cancelled(player: Node)

# --- Waves / Match flow ---
signal wave_started(wave_number: int, enemy_count: int)
signal wave_cleared(wave_number: int)
signal enemy_spawned(enemy: Node)
signal match_won
signal match_lost
## Match countdown (server-auth, replicated). `left`/`total` in seconds.
signal match_timer_changed(left: float, total: float)
## The match timer expired → the final overwhelming "storm" wave begins.
signal final_wave_started

# --- AI perception / stealth (Batch 2 "Living threat") ---
## A noise was made in the world that nearby enemies can HEAR (server-authoritative —
## clients route loud events via NetworkManager.report_noise so the SERVER's AI hears
## them). `loudness` is the audible RADIUS in metres; `kind` 0 footstep, 1 gunfire,
## 2 grenade. Non-hunter enemies within `loudness` of `world_pos` go INVESTIGATE (or
## CHASE if a confirmed-close spike). Footsteps are NOT reported here — the server derives
## them per-frame from each player's synced velocity+stance (see robot_enemy perception).
signal noise_emitted(world_pos: Vector3, loudness: float, kind: int)
## A caller/alarm fired (the Snitch archetype, or a loud alarm) — the AIDirector may
## summon reinforcements toward `world_pos`. `level` scales the response (1.0 = normal).
signal enemy_alerted(world_pos: Vector3, level: float)

# --- Dynamic world events (Batch 3 "Live raid") ---
## A mid-raid world event began (server-auth, synced). `kind`: 0 supply_cache,
## 1 miniboss, 2 contested_poi, 3 surge. `world_pos` = marker location; `label` = HUD text.
## The map/minimap draw nodes in the "world_events" group; the HUD shows a banner.
signal world_event_started(kind: int, world_pos: Vector3, label: String)
## A world event resolved. `success` = the squad completed it (cracked the cache / killed
## the mini-boss) vs it expired/failed.
signal world_event_ended(kind: int, success: bool)
## A world event's fill/countdown progressed (cache hold, contested timer). ratio 0..1.
signal world_event_progress(kind: int, ratio: float)
## An environmental surge toggled. `kind`: 0 enemy-surge (extra spawns), 1 sensor-blackout
## (the minimap is disabled). The HUD/minimap read this; server-auth + synced.
signal environmental_surge_changed(active: bool, kind: int)

# --- Progression: Raider Level / Reputation / Weapon Mastery (Batch 3) ---
## XP was awarded (per-peer LOCAL — drives the Raider Level). `source`: "kill"/"extract"/
## "event"/"loot" etc. (for the RaidSummary breakdown).
signal xp_gained(amount: int, source: String)
## The Raider Level increased. `skill_points` = the total unspent points now available.
signal raider_level_up(new_level: int, skill_points: int)
## Vendor reputation changed (and possibly crossed a tier). `tier` = the new tier index.
signal reputation_changed(rep: int, tier: int)
## A weapon's mastery level increased (per-weapon, use-driven).
signal weapon_mastery_changed(weapon_id: String, level: int)

# --- Extraction windows ---
## A zone opened/closed its timed extraction window. `remaining` = seconds in the
## current state. Map + minimap + HUD read this. (Per-zone, server-auth.)
signal extraction_window_changed(zone: Node, open: bool, remaining: float)

# --- Map UI ---
## The full-screen map was toggled (M key).
signal map_toggled(open: bool)

# --- Co-op combat / scoreboard ---
## A teammate's shot, broadcast so everyone sees the tracer/muzzle/impact.
signal remote_shot(
	muzzle: Vector3, hit_point: Vector3, arc: PackedVector3Array, enemy_hit: bool, normal: Vector3
)
## Per-player kill counts changed (synced) — the TAB leaderboard refreshes.
signal scoreboard_changed

# --- Co-op item interactions ---
## A teammate gave you an item (HUD toast). count of item_id.
signal item_received(from_peer: int, item_id: String, count: int)

# --- Server browser / favorites ---
## The local favorites/recents list changed — the server-browser UI refreshes.
signal favorites_changed
## A LAN scan began (the UI shows a "scanning…" state).
signal lan_scan_started
## A LAN scan finished. `servers` = Array of { name, ip, port, players, max }.
signal lan_servers_found(servers: Array)

# --- Graphics / diagnostics ---
## A graphics quality preset (or an individual quality lever) changed. level: 0 Low,
## 1 Medium, 2 High, 3 Ultra. Scene-side render levers (env SDFGI/SSAO/glow, sky clouds)
## listen and apply immediately; rebuild-bound levers (grass/water) read at next arena build.
signal graphics_quality_changed(level: int)
## The stats/diagnostics overlay config changed (settings menu → StatsOverlay). Carries the
## full config in one signal: show a minimal FPS counter, show the detailed perf/net panel,
## and the detailed-panel display mode (0 Numeric, 1 Graphs).
signal stats_overlay_changed(show_fps: bool, show_detailed: bool, mode: int)
## Arena build progress for the loading screen. frac 0..1, label = current phase name.
signal arena_build_progress(frac: float, label: String)
## The HUD layout settings changed (ui_edge_margin / ui_top_margin) — edge-anchored UI
## re-insets toward center. Used for ultrawide comfort. Read Settings.ui_edge_margin/ui_top_margin.
signal ui_layout_changed
## Camera settings changed (distance/shoulder/default-view) — the player rig re-reads
## Settings.camera_distance_scale / camera_shoulder_scale.
signal camera_settings_changed
## The "military glass" UI FX toggle changed (settings → FXOverlay + GlassBackdrops):
## scanline/grain/vignette overlay + frosted-glass blur behind modals. enabled=false →
## plain dim (cheap fallback). Read Settings.ui_fx_enabled.
signal ui_fx_changed(enabled: bool)

# --- UI / UX ---
## A nearby interactable (loot / extraction) — HUD shows "[E] <prompt>".
signal interaction_available(prompt: String, target: Node)
signal interaction_cleared
## Transient HUD notification / killfeed line. kind: 0 info, 1 good, 2 bad, 3 wave.
signal notify(text: String, kind: int)
## Sprint stamina for the stamina bar.
signal stamina_changed(current: float, max_stamina: float)
## Inventory UI -> player: use an item (medkit/grenade/...).
signal item_use_requested(item_id: String)
## Pause state toggled (pause menu).
signal game_paused(paused: bool)

# --- Meta-progression / game feel ---
## Currency total changed (after earn/spend) — Workshop + HUD read this.
signal currency_changed(amount: int)
## Run ended via extraction with rewards: currency earned this run + a breakdown dict.
signal run_rewards(currency: int, breakdown: Dictionary)
## Game-feel hooks (feel-dev's CameraFX listens). hit_stop briefly dips time_scale;
## screen_shake adds camera trauma. Emitted by combat code on notable hits.
signal hit_stop(duration: float)
signal screen_shake(amount: float)
## A player footstep landed (audio-dev plays a footstep). Carries the player + whether sprinting.
signal footstep(player: Node, sprinting: bool)

# --- Stash / raid economy ---
## Persistent stash contents changed (deposit/remove/sell) — the Lobby stash tab reads this.
signal stash_changed
## This peer extracted: loot deposited to its stash + currency bonus earned.
signal raid_loot_granted(payload: Array, bonus: int)

# --- Crafting / quests ---
## A crafting blueprint was learned (extract / buy / quest). Craft + shop UIs refresh.
signal blueprint_learned(blueprint: String)
## A quest objective advanced / completed (Quests autoload). The Quests tab reads these.
signal quest_progress(quest_id: String, current: int, target: int)
signal quest_completed(quest_id: String)
## Daily contracts rotated to a new day's picks.
signal dailies_rotated
## A LOCKED quest's unlock conditions were met → it's now OFFERED (AVAILABLE to accept).
signal quest_unlocked(quest_id: String)
## The player manually ACCEPTED an available quest into their active log.
signal quest_accepted(quest_id: String)
## A player killed an enemy of archetype `enemy_id` — fires PER-PEER on the killer's own
## machine (the co-op-correct kill feed, routed via NetworkManager kill attribution). Drives
## personal kill quests + the QuestDirector's decision-based offering.
signal player_kill(enemy_id: String)
## A claimed quest's full reward bundle was granted (Iter 3) — drives the reward popup.
## `rewards` = { currency, items:[{id,count}], blueprints:[], xp, rep, skill_points,
## giver, giver_rep, cosmetics:[], questline_complete:bool, line_title }.
signal quest_reward_granted(quest_id: String, rewards: Dictionary)
## Per-giver reputation changed (Iter 3). `giver` = NPC name, `rep` = new total, `tier` = new tier.
signal giver_rep_changed(giver: String, rep: int, tier: int)

# --- Gunsmith / haul ---
## An attachment was equipped/unequipped on a weapon (Gunsmith reads this).
signal attachment_changed(weapon_id: String)
## A permanent weapon perk was bought.
signal weapon_perk_changed(weapon_id: String)
## A character cosmetic was unlocked or equipped (the CHARACTER tab refreshes off this).
signal cosmetics_changed
## An extraction haul would exceed the stash capacity — show the Manage-Your-Haul beat.
## `incoming` is the haul stacks; `over_by` is the excess weight.
signal haul_overflow(incoming: Array, over_by: float)

# --- Networking / lobby ---
signal peer_registered(peer_id: int, info: Dictionary)
signal peer_unregistered(peer_id: int)
signal all_players_ready
signal match_started
## The squad roster or a member's ready state changed — the Hub lobby UI refreshes.
signal squad_changed
## The leader started the raid — EVERY peer runs its local deploy (commit bring-list +
## load the arena) on this signal, so the whole squad deploys on the same tick.
signal begin_deploy
