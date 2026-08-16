extends Node
## Machine Nemesis director (autoload name: NemesisDirector) — the SIGNATURE mechanic.
##
## A robot that SURVIVES a fight with the squad (you fled / only crippled it) is promoted
## into a persistent rival: it's saved (host-only nemesis.cfg), ADAPTS to how it was fought
## (learned-counter traits), wears scars, and RETURNS in later raids to hunt the squad.
## Death stops being a fail screen and becomes the opening line of a rivalry.
##
## Server-authoritative (mirrors AIDirector): every mutation gates on
## GameState.is_local_authority_server(). The rival's tier/traits/scars ride the spawned
## node NAME (NemesisProfile token), so co-op clients rebuild the IDENTICAL body for free —
## the director never sends a bespoke RPC, and clients never own/save a profile.
##
## FIVE learned counters via a damage-type histogram + argmax (emp_hard / weakpoint_armored
## / blast_hard / keen / chemistry_resist — the last is Phase 6), tier-leveling that adds
## one new counter + scars per survival.
##
## Registered in project.godot as autoload "NemesisDirector". The WaveManager registers
## itself here on _ready (parallel to AIDirector). (No class_name — the singleton name would
## collide.)

const CFG_SECTION := "active"
const _INJECT_RETRY := 3.0  # s between injection retries when the alive-cap is full
const _MAX_INJECT_ATTEMPTS := 10
## D6.5 entrance staging: how often EVERY peer (incl. co-op clients, which never see
## Events.nemesis_returned — it is emitted server-side) re-scans Groups.NEMESIS for a rival
## body that has appeared locally. The group holds 0 or 1 node, so the scan is free.
const _ENTRANCE_POLL := 0.2

## WaveManager reference (set by WaveManager._ready / cleared on _exit_tree).
var _wave_mgr = null

## The saved rival loaded for THIS raid (null = no rival exists yet).
var _profile: NemesisProfile = null

## The node we're accumulating survival telemetry for this raid — a fresh candidate OR the
## returned rival (_active). At raid end, if it's still alive, it births/levels the profile.
var _tracked: Node = null
var _tracked_dmg: Dictionary = {}  # peer_id -> cumulative damage (grudge attribution)
# Damage-type histogram for THIS raid → argmax picks the next learned counter at birth/level.
var _tracked_emp: int = 0  # EMP stuns landed → emp_hard
var _tracked_weakpoint: int = 0  # weak-point hits → weakpoint_armored
var _tracked_blast: int = 0  # grenade detonations near it → blast_hard
var _tracked_stealth: float = 0.0  # s it stayed UN-chased (snuck past) → keen
var _tracked_chemistry: int = 0  # chemistry statuses applied to it → chemistry_resist (Phase 6)

## The rival node injected this raid (if any) — death of it = DEFEAT.
var _active: Node = null

var _inject_timer: float = -1.0
var _inject_attempts: int = 0
var _injected: bool = false
var _birth_done: bool = false
var _last_err: String = ""  # QA: why the last injection produced no node
# Phase 3: at-risk gear the squad LOST this raid (pushed by dying peers) → snapshot into the
# rival's profile at birth/level → dropped on its defeat. _history = retired rivals for codex.
var _lost_this_raid: Array[String] = []
var _history: Array = []  # Array of NemesisProfile.to_dict(), newest first (cap NEMESIS_HISTORY_CAP)
# D6.5 entrance staging (render-only, LOCAL on every peer — never gated on authority).
var _entrance_seen: int = 0  # instance id of the rival we already staged an entrance for
var _entrance_poll: float = 0.0


func _ready() -> void:
	Events.match_started.connect(_on_match_started)
	Events.nemesis_returned.connect(_on_nemesis_returned)  # host fast path (exact frame)
	Events.damage_dealt.connect(_on_damage_dealt)
	Events.enemy_stunned.connect(_on_enemy_stunned)
	Events.enemy_chemistry_applied.connect(_on_enemy_chemistry_applied)
	Events.weak_point_hit.connect(_on_weak_point_hit)
	Events.grenade_exploded.connect(_on_grenade_exploded)
	Events.entity_died.connect(_on_entity_died)
	Events.extraction_started.connect(_on_extraction_started)
	Events.extraction_completed.connect(_on_raid_over.unbind(1))
	Events.match_lost.connect(_on_raid_over)
	Events.match_won.connect(_on_raid_over)
	_history = _load_history()


func _process(delta: float) -> void:
	# Render-only, BEFORE the authority gate: a co-op client runs this director too, and the
	# entrance must play on its screen as well (its rival body arrives via the spawner).
	_tick_entrance(delta)
	if not GameState.is_local_authority_server():
		return
	# "keen" telemetry: accumulate time the candidate stays UN-chased (the squad sneaks past).
	if is_instance_valid(_tracked) and "current_state" in _tracked:
		var st: int = int(_tracked.current_state)
		if st == 0 or st == 3:  # PATROL / INVESTIGATE (not CHASE=1 / ATTACK=2)
			_tracked_stealth += delta
	if _inject_timer <= 0.0:
		return
	_inject_timer -= delta
	if _inject_timer <= 0.0 and not _injected:
		_try_inject()


## Registered by WaveManager (parallel to AIDirector).
func set_wave_manager(wm) -> void:
	_wave_mgr = wm


# ----------------------------------------------------------------- raid lifecycle
func _on_match_started() -> void:
	# Reset per-raid state, then load the saved rival (server-side only).
	_tracked = null
	_reset_telemetry()
	_lost_this_raid = []
	_active = null
	_injected = false
	_inject_attempts = 0
	_birth_done = false
	_inject_timer = -1.0
	_profile = null
	_entrance_seen = 0  # local staging state — reset on EVERY peer, before the authority gate
	_entrance_poll = 0.0
	if not GameState.is_local_authority_server():
		return
	_profile = _load()
	if _profile != null:
		_inject_timer = Settings.NEMESIS_RETURN_DELAY  # schedule the rival's return
	_sync_codex()  # catch-up so a late-joining client's Hub codex isn't empty


func _try_inject() -> void:
	_injected = true
	if _profile == null:
		_last_err = "no profile"
		return
	if not is_instance_valid(_wave_mgr):
		_last_err = "no wave_mgr"
		return
	# Ambush bias: spawn at the squad's FAVORITE extraction zone if known ("it was waiting at
	# your evac"), else near the grudge target.
	var node: Node = _wave_mgr.spawn_nemesis(_profile, _ambush_pos())
	if node == null:
		_last_err = "spawn null (cap=%d)" % int(_wave_mgr.call("reinforcement_capacity"))
		# Alive-cap full — retry shortly (capped so it can't spin forever).
		_inject_attempts += 1
		if _inject_attempts < _MAX_INJECT_ATTEMPTS:
			_injected = false
			_inject_timer = _INJECT_RETRY
		return
	_active = node
	_tracked = node  # fighting the returned rival can LEVEL it if it survives again
	_reset_telemetry()
	Events.nemesis_returned.emit(_profile.serial, _profile.title, node)
	Events.notify.emit(tr("%s has found you.") % _nemesis_name(_profile), 2)


# ------------------------------------------------------------- D6.5 entrance staging (local)
## The rival's ARRIVAL is a staged event, not another spawn: red signature flash + expanding
## rings at the exit point, a heartbeat pulse on its chassis glow + a screen vignette, a
## silhouette read-through for those seconds, and dust/sparks at its feet.
##
## Everything is render-only and built LOCALLY by NemesisEntrance on the peer that runs this
## (no new RPC, no new signal): the HOST enters through Events.nemesis_returned on the exact
## injection frame, every peer (host included, deduped) through the Groups.NEMESIS watch tick
## below — which is the ONLY path a co-op client has, since nemesis_returned is server-side.
func _on_nemesis_returned(_serial: String, _title: String, node: Node) -> void:
	_stage_entrance(node)


## Watch tick: notice a rival body that has appeared in Groups.NEMESIS on THIS peer and stage
## its entrance once. Throttled; the group holds 0 or 1 node for the whole raid.
func _tick_entrance(delta: float) -> void:
	_entrance_poll -= delta
	if _entrance_poll > 0.0:
		return
	_entrance_poll = _ENTRANCE_POLL
	for n in get_tree().get_nodes_in_group(Groups.NEMESIS):
		if n.get_instance_id() != _entrance_seen:
			_stage_entrance(n)
			return


## Stage once per rival body. On a CLIENT the spawner hands us the node a frame or two before
## its first position sync, so an un-synced body (still at the scene origin) is skipped and
## re-tried on the next tick — otherwise the whole burst would fire at world (0,0,0).
func _stage_entrance(node: Node) -> void:
	if not (node is Node3D) or not is_instance_valid(node):
		return
	var body := node as Node3D
	if not body.is_inside_tree() or body.global_position.is_zero_approx():
		return
	_entrance_seen = body.get_instance_id()
	NemesisEntrance.stage(body)


## Raid ended (extraction / loss / win). If the tracked rival survived, it births or levels.
func _on_raid_over() -> void:
	if not GameState.is_local_authority_server() or _birth_done:
		return
	_birth_done = true
	if _tracked == null or not _node_alive(_tracked):
		return
	_birth_or_level(_tracked)


# ----------------------------------------------------------------- telemetry
func _on_damage_dealt(target: Node, amount: float, source: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	# Flag a fresh candidate only when no rival is in play this raid (one nemesis per squad).
	if _tracked == null and _profile == null and _active == null and _qualifies(target):
		_tracked = target
		_reset_telemetry()
	if target != _tracked:
		return
	var peer: int = NetworkManager._peer_of(source)
	if peer > 0:
		_tracked_dmg[peer] = float(_tracked_dmg.get(peer, 0.0)) + amount


func _on_enemy_stunned(enemy: Node, _duration: float) -> void:
	if GameState.is_local_authority_server() and enemy == _tracked:
		_tracked_emp += 1  # the squad keeps EMP-locking it → it learns "emp_hard"


## Machine Chemistry: count each status turned ON on the tracked candidate — feeds the
## "chemistry_resist" learned counter (Phase 6) in _pick_learned_trait's argmax.
func _on_enemy_chemistry_applied(enemy: Node, _kind: String, active: bool) -> void:
	if active and GameState.is_local_authority_server() and enemy == _tracked:
		_tracked_chemistry += 1


func _on_weak_point_hit(enemy: Node, _damage: float) -> void:
	if GameState.is_local_authority_server() and enemy == _tracked:
		_tracked_weakpoint += 1  # the squad snipes its weak spot → it learns "weakpoint_armored"


func _on_grenade_exploded(world_pos: Vector3, _damage: float, radius: float) -> void:
	if not GameState.is_local_authority_server() or not is_instance_valid(_tracked):
		return
	if (_tracked as Node3D).global_position.distance_to(world_pos) <= radius:
		_tracked_blast += 1  # the squad grenades it → it learns "blast_hard"


## Zero the per-raid damage-type histogram (called wherever the tracked candidate changes).
func _reset_telemetry() -> void:
	_tracked_emp = 0
	_tracked_weakpoint = 0
	_tracked_blast = 0
	_tracked_stealth = 0.0
	_tracked_chemistry = 0
	_tracked_dmg = {}


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if entity == _active:
		# DEFEAT — the rivalry is settled. Payoff, retire to history, free a new candidate.
		var serial: String = _profile.serial if _profile != null else ""
		var death_pos: Vector3 = (
			(entity as Node3D).global_position if entity is Node3D else Vector3.ZERO
		)
		_payoff_on_defeat(death_pos, _killer)
		Events.nemesis_defeated.emit(serial)
		Events.notify.emit(tr("%s is scrap.") % serial, 1)
		if _profile != null:
			_history.push_front(_profile.to_dict())
			while _history.size() > Settings.NEMESIS_HISTORY_CAP:
				_history.pop_back()
		# A nearby lieutenant inherits a WEAKENED grudge (the rivalry never fully ends);
		# else the slot clears for a fresh candidate. Reads _profile BEFORE we reassign it.
		var heir: NemesisProfile = _seed_successor(death_pos)
		_active = null
		_tracked = null
		_profile = heir  # null when no heir → cleared
		_save()
		_sync_codex()
	elif entity == _tracked:
		# The candidate died (you finished it) — no grudge born from it.
		_tracked = null
		_reset_telemetry()


## On a rival's defeat, promote the nearest living qualifying enemy into a SUCCESSOR profile
## (one tier lower, minus its last-learned trait) so it returns next raid. Returns null if
## disabled / no profile / no heir in range. Reuses the same birth machinery + name-token.
func _seed_successor(death_pos: Vector3) -> NemesisProfile:
	if not Settings.NEMESIS_SUCCESSOR_ENABLED or _profile == null:
		return null
	var heir: Node = _pick_heir(death_pos)
	if heir == null:
		return null
	var p := NemesisProfile.new()
	p.archetype = String(heir.get("enemy_id")) if "enemy_id" in heir else "robot_grunt"
	p.scene_path = heir.scene_file_path
	p.tier = maxi(1, _profile.tier - 1)
	p.created_version = Settings.GAME_VERSION
	p.scar_seed = _scar_seed_for(heir)
	p.serial = NemesisProfile.make_serial(p.scar_seed)
	var inherited: Array[String] = []
	for i in maxi(0, _profile.traits.size() - 1):
		inherited.append(_profile.traits[i])
	p.traits = inherited
	p.title = NemesisProfile.make_title(p.tier)
	Events.notify.emit(tr("Another machine takes up the grudge."), 2)
	return p


## Nearest living, qualifying enemy within NEMESIS_HEIR_RADIUS of the death (not the rival).
func _pick_heir(death_pos: Vector3) -> Node:
	var best: Node = null
	var best_d: float = Settings.NEMESIS_HEIR_RADIUS
	for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
		if e == _active or not _qualifies(e) or not _node_alive(e):
			continue
		var d: float = (e as Node3D).global_position.distance_to(death_pos)
		if d <= best_d:
			best_d = d
			best = e
	return best


## Push the codex (active + history) to co-op clients for the Hub "Rivals" tab.
func _sync_codex() -> void:
	var active: Dictionary = _profile.to_dict() if _profile != null else {}
	NetworkManager.sync_nemesis_codex(active, _history)


## Drop the trophy core + the squad's reclaimed lost gear at `death_pos`, and grant the
## killer the bounty (currency + rep + XP, co-op-routed to that peer's own machine).
func _payoff_on_defeat(death_pos: Vector3, killer: Node) -> void:
	var container: Node = _loot_container()
	if container != null:
		LootPickup.spawn_at(container, death_pos, "loot_nemesis_core", 1)
		if _profile != null:
			for gid in _profile.lost_gear:
				LootPickup.spawn_at(container, death_pos, String(gid), 1)
	NetworkManager.grant_nemesis_bounty(NetworkManager._peer_of(killer))


## The Net/Loot container the enemy loot spawns into (reuse robot_enemy's resolver, else
## walk the arena). Server-only spawns replicate via the MultiplayerSpawner.
func _loot_container() -> Node:
	if is_instance_valid(_active) and _active.has_method("_loot_container"):
		return _active.call("_loot_container")
	var arena: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	return arena.get_node_or_null("Net/Loot") if arena != null else null


# ----------------------------------------------------------------- birth / level
func _birth_or_level(node: Node) -> void:
	var leveling: bool = _profile != null and node == _active
	var p: NemesisProfile = _profile if leveling else NemesisProfile.new()
	if not leveling:
		p.archetype = String(node.get("enemy_id")) if "enemy_id" in node else "robot_grunt"
		p.scene_path = node.scene_file_path
		p.tier = 1
		p.created_version = Settings.GAME_VERSION
		p.scar_seed = _scar_seed_for(node)
		p.serial = NemesisProfile.make_serial(p.scar_seed)
	else:
		p.tier = mini(p.tier + 1, Settings.NEMESIS_MAX_TIER)
		p.scar_seed = absi(p.scar_seed * 1103515245 + 12345) & 0x7fffffff  # new scar per level
	# Learn ONE new counter this survival — the argmax of how the squad fought it this raid.
	var learned: String = _pick_learned_trait(p.traits)
	if learned != "":
		p.traits.append(learned)
	# Claim the at-risk gear the squad lost this raid ("it wears the armor it killed you in"),
	# appended + deduped + capped so a leveling rival hoards across raids.
	for gid in _lost_this_raid:
		if gid not in p.lost_gear and p.lost_gear.size() < Settings.NEMESIS_LOST_GEAR_CAP:
			p.lost_gear.append(gid)
	p.title = NemesisProfile.make_title(p.tier)
	p.grudge_peer = _top_damager()
	_profile = p
	_save()
	_sync_codex()
	Events.nemesis_born.emit(p.serial, p.title)
	Events.notify.emit(tr("%s escaped. It will remember.") % _nemesis_name(p), 2)


## Argmax over this raid's damage-type histogram → the dominant tactic's counter trait, if
## not already owned. Keen's seconds are normalized by the threshold so they're comparable to
## the hit COUNTS (a single hit-type ≈ score 1; keen only out-scores it if the squad avoided
## the rival for well past the threshold). Returns "" if nothing new to learn.
func _pick_learned_trait(owned: Array) -> String:
	var scored: Array = []
	if _tracked_emp > 0:
		scored.append(["emp_hard", float(_tracked_emp)])
	if _tracked_weakpoint > 0:
		scored.append(["weakpoint_armored", float(_tracked_weakpoint)])
	if _tracked_blast > 0:
		scored.append(["blast_hard", float(_tracked_blast)])
	if _tracked_stealth >= Settings.NEMESIS_KEEN_THRESHOLD:
		scored.append(["keen", _tracked_stealth / Settings.NEMESIS_KEEN_THRESHOLD])
	# Phase 6: each status EDGE ≈ one tactic use, so the raw count is argmax-comparable.
	if _tracked_chemistry > 0:
		scored.append(["chemistry_resist", float(_tracked_chemistry)])
	scored.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	for entry in scored:
		if String(entry[0]) not in owned:
			return String(entry[0])
	return ""


func _scar_seed_for(node: Node) -> int:
	var dmg_total: float = 0.0
	for v in _tracked_dmg.values():
		dmg_total += float(v)
	return absi(int(dmg_total) * 48271 + str(node.name).hash()) & 0x7fffffff


func _top_damager() -> int:
	var best_peer: int = 0
	var best: float = -1.0
	for peer in _tracked_dmg:
		var v: float = float(_tracked_dmg[peer])
		if v > best:
			best = v
			best_peer = int(peer)
	return best_peer


# ----------------------------------------------------------------- helpers
func _qualifies(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if not node.is_in_group(Groups.ENEMIES) or not ("enemy_id" in node):
		return false
	var eid: String = String(node.get("enemy_id"))
	var stats: Dictionary = Settings.ENEMY_STATS.get(eid, {})
	if int(stats.get("score", 0)) < Settings.NEMESIS_MIN_SCORE:
		return false
	# The boss IS the elite; the caller is a non-fighting snitch — neither makes a good rival.
	if eid == "robot_boss" or bool(stats.get("caller", false)):
		return false
	return true


func _node_alive(node: Node) -> bool:
	if not is_instance_valid(node):
		return false
	if bool(node.get("_dying")):
		return false
	var hp: Node = node.get_node_or_null(Groups.NODE_HEALTH)
	return hp != null and float(hp.get("current")) > 0.0


func _grudge_pos() -> Vector3:
	var fallback: Vector3 = Vector3.ZERO
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if pl is Node3D:
			fallback = (pl as Node3D).global_position
			if _profile != null and str(pl.name).to_int() == _profile.grudge_peer:
				return (pl as Node3D).global_position
	return fallback


# ----------------------------------------------------------------- extraction ambush
## A dying peer pushes its at-risk gear (NetworkManager routes it here on the host) so the
## surviving rival can wear + drop it on defeat. Capped; dedup happens at the birth snapshot.
func record_lost_gear(ids: Array) -> void:
	if not GameState.is_local_authority_server():
		return
	for id in ids:
		var sid: String = String(id)
		if (
			sid != ""
			and sid not in _lost_this_raid
			and _lost_this_raid.size() < Settings.NEMESIS_LOST_GEAR_CAP
		):
			_lost_this_raid.append(sid)


## Track where the squad extracts so the rival learns to ambush their favorite evac. If the
## rival is alive, not yet injected, and the squad starts extracting at that favorite zone,
## force the injection NOW at the zone — "it was waiting at your evac."
func _on_extraction_started(_player: Node, zone: Node) -> void:
	if not GameState.is_local_authority_server() or _profile == null or zone == null:
		return
	var zname: String = str(zone.name)
	_profile.zone_counts[zname] = int(_profile.zone_counts.get(zname, 0)) + 1
	_save()
	if _active == null and not _injected and zname == _favorite_zone():
		_inject_timer = 0.0
		_injected = false
		_try_inject()


## The squad's most-used extraction zone name (needs >= NEMESIS_FAVORITE_MIN visits), else "".
func _favorite_zone() -> String:
	if _profile == null:
		return ""
	var best: String = ""
	var best_n: int = 0
	for zname in _profile.zone_counts:
		var n: int = int(_profile.zone_counts[zname])
		if n > best_n:
			best_n = n
			best = String(zname)
	return best if best_n >= Settings.NEMESIS_FAVORITE_MIN else ""


## Injection placement: the favorite extraction zone (if established) else the grudge target.
func _ambush_pos() -> Vector3:
	var fav: String = _favorite_zone()
	if fav != "":
		for z in get_tree().get_nodes_in_group(Groups.EXTRACTION):
			if z is Node3D and str(z.name) == fav:
				return (z as Node3D).global_position
	return _grudge_pos()


func _nemesis_name(p: NemesisProfile) -> String:
	if p.title == "":
		return p.serial
	return "%s, %s" % [p.serial, p.title]


# ----------------------------------------------------------------- persistence
func _cfg_path() -> String:
	return Settings.user_path("nemesis", "cfg")


func _save() -> void:
	if Settings.ephemeral_save:
		return  # --no-save test run
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", Settings.GAME_VERSION)
	if _profile != null:
		_profile.to_cfg(cfg, CFG_SECTION)
	cfg.set_value("history", "rivals", _history)  # retired rivals for the Hub codex
	cfg.save(_cfg_path())


## Retired-rivals history (Array of NemesisProfile.to_dict(), newest first) for the codex.
func _load_history() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(_cfg_path()) != OK:
		return []
	var raw: Variant = cfg.get_value("history", "rivals", [])
	return raw if raw is Array else []


func _load() -> NemesisProfile:
	var cfg := ConfigFile.new()
	if cfg.load(_cfg_path()) != OK:
		return null
	return NemesisProfile.from_cfg(cfg, CFG_SECTION)


# ----------------------------------------------------------------- QA hooks (NemesisQA)
## Build + save a rival WITHOUT a live fight (harness force_birth). Returns the profile dict.
func debug_force_birth(archetype: String, scene_path: String, traits: Array) -> Dictionary:
	var p := NemesisProfile.new()
	p.archetype = archetype
	p.scene_path = scene_path
	p.tier = 1
	p.created_version = Settings.GAME_VERSION
	p.scar_seed = absi(int(archetype.hash())) & 0x7fffffff
	p.serial = NemesisProfile.make_serial(p.scar_seed)
	p.title = NemesisProfile.make_title(1)
	for t in traits:
		if String(t) not in p.traits:
			p.traits.append(String(t))
	_profile = p
	_save()
	Events.nemesis_born.emit(p.serial, p.title)
	return debug_state()


## Inject the damage-type histogram directly (harness) so the learning/argmax/leveling logic
## is testable without depending on landing live grenades on a moving target. Targets the
## current _tracked candidate's counters. Returns the state dict.
func debug_set_telemetry(
	emp: int, weakpoint: int, blast: int, stealth: float, chem: int = 0
) -> Dictionary:
	_tracked_emp = emp
	_tracked_weakpoint = weakpoint
	_tracked_blast = blast
	_tracked_stealth = stealth
	_tracked_chemistry = chem
	return debug_state()


## Simulate raid-end (harness): births/levels from the live tracked candidate, exactly the
## organic extraction path — so the candidate→telemetry→birth chain is testable without
## scripting a full extraction hold. Returns the state dict.
func debug_raid_over() -> Dictionary:
	_birth_done = false  # allow a fresh birth even if a real raid-over already fired
	_on_raid_over()
	return debug_state()


## Inject the saved rival immediately (harness). Returns the state dict.
func debug_inject() -> Dictionary:
	_injected = false
	_inject_attempts = 0
	if _profile == null:
		_profile = _load()
	_try_inject()
	return debug_state()


func debug_state() -> Dictionary:
	var out := {
		"has_profile": _profile != null,
		"injected": _injected,
		"active_alive": _node_alive(_active),
		"tracked": is_instance_valid(_tracked),
		"tracked_name": str(_tracked.name) if is_instance_valid(_tracked) else "",
		"tracked_emp": _tracked_emp,
		"tracked_weakpoint": _tracked_weakpoint,
		"tracked_blast": _tracked_blast,
		"tracked_stealth": _tracked_stealth,
		"tracked_chemistry": _tracked_chemistry,
		"birth_done": _birth_done,
		"wave_mgr": is_instance_valid(_wave_mgr),
		"last_err": _last_err,
	}
	out["lost_this_raid"] = _lost_this_raid
	out["favorite_zone"] = _favorite_zone()
	out["history"] = _history.size()
	if _profile != null:
		out["serial"] = _profile.serial
		out["title"] = _profile.title
		out["archetype"] = _profile.archetype
		out["tier"] = _profile.tier
		out["traits"] = _profile.traits
		out["scar_seed"] = _profile.scar_seed
		out["name_token"] = _profile.to_name_token()
		out["lost_gear"] = _profile.lost_gear
		out["zone_counts"] = _profile.zone_counts
	if is_instance_valid(_active):
		out["active_name"] = str(_active.name)
	return out


## Codex feed for the Hub "Rivals" tab — the active rival (if any) + retired history, each as
## a NemesisProfile.to_dict(). Read on the HOST (clients never save a profile).
func codex_data() -> Dictionary:
	var active: Variant = _profile.to_dict() if _profile != null else null
	if active == null:
		# Hub may open between raids when _profile isn't loaded — read the saved active slot.
		var cfg := ConfigFile.new()
		if cfg.load(_cfg_path()) == OK:
			var saved: NemesisProfile = NemesisProfile.from_cfg(cfg, CFG_SECTION)
			if saved != null:
				active = saved.to_dict()
	return {"active": active, "history": _history if not _history.is_empty() else _load_history()}


## QA: directly set this raid's lost-gear list (deterministic reclaim test).
func debug_set_lost(ids: Array) -> Dictionary:
	_lost_this_raid = []
	record_lost_gear(ids)
	return debug_state()


## QA: credit an extraction zone N times so it becomes the favorite (ambush test).
func debug_set_zone(zone_name: String, count: int) -> Dictionary:
	if _profile != null:
		_profile.zone_counts[zone_name] = count
		_save()
	return debug_state()
