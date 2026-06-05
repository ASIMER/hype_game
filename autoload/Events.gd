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

# --- Player ---
signal local_player_spawned(player: Node)
signal player_health_changed(player: Node, current: float, max_health: float)

# --- Loot / Inventory ---
signal loot_spawned(loot: Node)
signal item_picked_up(player: Node, item_id: String, count: int)
signal inventory_changed(inventory: Node)
signal pickup_requested(player: Node, pickup: Node)   # client -> server intent

# --- Extraction ---
signal extraction_started(player: Node, zone: Node)
signal extraction_progress(player: Node, ratio: float)
signal extraction_completed(player: Node)
signal extraction_cancelled(player: Node)

# --- Waves / Match flow ---
signal wave_started(wave_number: int, enemy_count: int)
signal wave_cleared(wave_number: int)
signal enemy_spawned(enemy: Node)
signal match_won()
signal match_lost()

# --- UI / UX ---
## A nearby interactable (loot / extraction) — HUD shows "[E] <prompt>".
signal interaction_available(prompt: String, target: Node)
signal interaction_cleared()
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

# --- Networking / lobby ---
signal peer_registered(peer_id: int, info: Dictionary)
signal peer_unregistered(peer_id: int)
signal all_players_ready()
signal match_started()
