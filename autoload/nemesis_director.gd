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
## MVP scope: ONE learned trait end-to-end (emp_hard), birth on extraction, one return with
## scars + tier health. No extraction ambush / lost-gear-core drop / codex yet (Phases 2-3).
##
## Registered in project.godot as autoload "NemesisDirector". The WaveManager registers
## itself here on _ready (parallel to AIDirector). (No class_name — the singleton name would
## collide.)

const CFG_SECTION := "active"
const _INJECT_RETRY := 3.0  # s between injection retries when the alive-cap is full
const _MAX_INJECT_ATTEMPTS := 10

## WaveManager reference (set by WaveManager._ready / cleared on _exit_tree).
var _wave_mgr = null

## The saved rival loaded for THIS raid (null = no rival exists yet).
var _profile: NemesisProfile = null

## The node we're accumulating survival telemetry for this raid — a fresh candidate OR the
## returned rival (_active). At raid end, if it's still alive, it births/levels the profile.
var _tracked: Node = null
var _tracked_emp: int = 0
var _tracked_dmg: Dictionary = {}  # peer_id -> cumulative damage (grudge attribution)

## The rival node injected this raid (if any) — death of it = DEFEAT.
var _active: Node = null

var _inject_timer: float = -1.0
var _inject_attempts: int = 0
var _injected: bool = false
var _birth_done: bool = false
var _last_err: String = ""  # QA: why the last injection produced no node


func _ready() -> void:
	Events.match_started.connect(_on_match_started)
	Events.damage_dealt.connect(_on_damage_dealt)
	Events.enemy_stunned.connect(_on_enemy_stunned)
	Events.entity_died.connect(_on_entity_died)
	Events.extraction_completed.connect(_on_raid_over.unbind(1))
	Events.match_lost.connect(_on_raid_over)
	Events.match_won.connect(_on_raid_over)


func _process(delta: float) -> void:
	if not GameState.is_local_authority_server():
		return
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
	_tracked_emp = 0
	_tracked_dmg = {}
	_active = null
	_injected = false
	_inject_attempts = 0
	_birth_done = false
	_inject_timer = -1.0
	_profile = null
	if not GameState.is_local_authority_server():
		return
	_profile = _load()
	if _profile != null:
		_inject_timer = Settings.NEMESIS_RETURN_DELAY  # schedule the rival's return


func _try_inject() -> void:
	_injected = true
	if _profile == null:
		_last_err = "no profile"
		return
	if not is_instance_valid(_wave_mgr):
		_last_err = "no wave_mgr"
		return
	var node: Node = _wave_mgr.spawn_nemesis(_profile, _grudge_pos())
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
	_tracked_emp = 0
	_tracked_dmg = {}
	Events.nemesis_returned.emit(_profile.serial, _profile.title, node)
	Events.notify.emit(tr("%s has found you.") % _nemesis_name(_profile), 2)


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
		_tracked_emp = 0
		_tracked_dmg = {}
	if target != _tracked:
		return
	var peer: int = NetworkManager._peer_of(source)
	if peer > 0:
		_tracked_dmg[peer] = float(_tracked_dmg.get(peer, 0.0)) + amount


func _on_enemy_stunned(enemy: Node, _duration: float) -> void:
	if GameState.is_local_authority_server() and enemy == _tracked:
		_tracked_emp += 1  # the squad keeps EMP-locking it → it learns "emp_hard"


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if not GameState.is_local_authority_server():
		return
	if entity == _active:
		# DEFEAT — the rivalry is settled. Retire the profile; a new candidate can be born.
		var serial: String = _profile.serial if _profile != null else ""
		Events.nemesis_defeated.emit(serial)
		Events.notify.emit(tr("%s is scrap.") % serial, 1)
		_profile = null
		_active = null
		_tracked = null
		_save()  # writes no "active" section → cleared
	elif entity == _tracked:
		# The candidate died (you finished it) — no grudge born from it.
		_tracked = null
		_tracked_emp = 0
		_tracked_dmg = {}


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
	if _tracked_emp > 0 and "emp_hard" not in p.traits:
		p.traits.append("emp_hard")  # learned counter (MVP: EMP)
	p.title = NemesisProfile.make_title(p.tier)
	p.grudge_peer = _top_damager()
	_profile = p
	_save()
	Events.nemesis_born.emit(p.serial, p.title)
	Events.notify.emit(tr("%s escaped. It will remember.") % _nemesis_name(p), 2)


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
	cfg.save(_cfg_path())


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
		"birth_done": _birth_done,
		"wave_mgr": is_instance_valid(_wave_mgr),
		"last_err": _last_err,
	}
	if _profile != null:
		out["serial"] = _profile.serial
		out["title"] = _profile.title
		out["archetype"] = _profile.archetype
		out["tier"] = _profile.tier
		out["traits"] = _profile.traits
		out["scar_seed"] = _profile.scar_seed
		out["name_token"] = _profile.to_name_token()
	if is_instance_valid(_active):
		out["active_name"] = str(_active.name)
	return out
