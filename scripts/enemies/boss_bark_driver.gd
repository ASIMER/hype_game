class_name BossBarkDriver
extends Node
## Talking-boss DRIVER (v1) — attach as a child of a boss enemy; the lead wires it.
##
## The anti-"scripted" half of the bark system: it never fires a line on a timer alone, it
## OBSERVES what actually happened (the boss's own HP curve, the Events bus, and a 1 Hz poll
## of the real nearest player) and translates that into a context key. BossBarks then decides
## whether that context may speak (cooldowns + no-repeat ring), so this file stays a pure
## state-watcher: every trigger here is a fact about the match.
##
## The parent is DUCK-TYPED — nothing here needs the RobotBoss class. It reads the standard
## "Health" child (current / max_health / is_dead) and the replicated `current_state` int if
## the parent has one; both are optional and their absence just disables the checks that
## need them. Every Events connect goes through _link(), which is has_signal-guarded AND
## connects by NAME, so a signal this build doesn't carry is skipped instead of crashing.
##
## It creates its own BossBarks engine child on _ready unless one was already provided, so
## attaching this single node is all the wiring the boss needs.
##
## CO-OP NOTE: barks travel on Events.notify, a LOCAL HUD channel, so this driver is NOT
## authority-gated — a client would otherwise stay silent (weak_point_hit / entity_died are
## server-only signals). Each peer therefore narrates from what it can see locally and may
## pick a different line; if the squad should hear ONE synchronised line, the lead can route
## BossBarks output through an RPC instead.

const POLL_INTERVAL: float = 1.0  # nearest-player observation tick
const HP_POLL: float = 0.5  # boss health-ratio sampling tick
const PHASE2_RATIO: float = 0.66
const PHASE3_RATIO: float = 0.33
const DYING_RATIO: float = 0.1
const RUSH_DIST: float = 6.0  # player this close = charging us
const MINION_RADIUS: float = 30.0  # an ally destroyed within this counts as ours
const REACT_RADIUS: float = 60.0  # world events (wall break) must happen this close
const NEAR_PLAYER_DIST: float = 40.0  # "a player is around" for the hiding check
const CAMP_TIME: float = 10.0  # seconds of near-zero movement = camping
const CAMP_MOVE: float = 1.5  # metres of drift still counted as "static"
const HIDE_TIME: float = 8.0  # seconds un-engaged with a player nearby = hiding
const LOW_HP_FRAC: float = 0.3
const LOW_HP_CD: float = 30.0  # own cooldown, on top of the engine's per-context one
const NEMESIS_CD: float = 45.0
# robot_enemy / EnemyStateMachine State enum: PATROL, CHASE, ATTACK, INVESTIGATE.
const STATE_CHASE: int = 1
const STATE_ATTACK: int = 2

var _boss: Node3D = null
var _health: Node = null
var _barks: BossBarks = null

var _hp_t: float = HP_POLL
var _poll_t: float = POLL_INTERVAL
var _stage: int = 0  # 0 fresh, 1 phase2 said, 2 enrage said, 3 dying said

var _camp_id: int = 0  # instance id of the player we're tracking for camping
var _camp_pos: Vector3 = Vector3.ZERO
var _static_t: float = 0.0
var _hide_t: float = 0.0
var _last_player_dist: float = INF

var _low_hp_ms: int = 0
var _nemesis_ms: int = 0
var _serial: String = ""  # the returning rival's serial, for the %s bark slots


func _ready() -> void:
	_boss = get_parent() as Node3D
	if _boss == null:
		set_process(false)
		return
	_health = _boss.get_node_or_null(Groups.NODE_HEALTH)
	_barks = _ensure_engine()
	_connect_events()
	_serial = _lookup_serial()
	_barks.say("intro")


func _process(delta: float) -> void:
	if _boss == null or not is_instance_valid(_boss):
		set_process(false)
		return
	if _is_dead():
		set_process(false)
		return
	_hp_t -= delta
	if _hp_t <= 0.0:
		_hp_t = HP_POLL
		_check_phases()
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = POLL_INTERVAL
		_poll_players()


# ------------------------------------------------------------------------------ setup
## Reuse a BossBarks that was authored into the scene (our child, or a sibling under the
## boss); otherwise build one. Added during _ready so its bank is loaded before "intro".
func _ensure_engine() -> BossBarks:
	for child in get_children():
		if child is BossBarks:
			return child as BossBarks
	var sibling: Node = _boss.get_node_or_null("BossBarks")
	if sibling is BossBarks:
		return sibling as BossBarks
	var made: BossBarks = BossBarks.new()
	made.name = "BossBarks"
	add_child(made)
	return made


func _connect_events() -> void:
	_link("weak_point_hit", _on_weak_point_hit)
	_link("entity_died", _on_entity_died)
	_link("skill_cast", _on_skill_cast)
	_link("chunk_broken", _on_chunk_broken)
	_link("player_downed", _on_player_downed)
	_link("final_wave_started", _on_final_wave_started)
	_link("match_lost", _on_match_lost)
	_link("nemesis_returned", _on_nemesis_returned)


## Connect by NAME behind a has_signal check: a build without the signal simply skips it
## (Events.<name>.connect would be a parse error instead of a graceful no-op).
func _link(sig: String, cb: Callable) -> void:
	if Events.has_signal(sig) and not Events.is_connected(sig, cb):
		Events.connect(sig, cb)


# --------------------------------------------------------------------- event reactions
func _on_weak_point_hit(enemy: Node, _damage: float) -> void:
	if enemy == _boss:
		_barks.say("boss_hit_weakpoint")


## One of our machines was destroyed near us — not the boss itself, not a player.
func _on_entity_died(entity: Node, _killer: Node) -> void:
	if entity == null or entity == _boss or not is_instance_valid(entity):
		return
	if not entity.is_in_group(Groups.ENEMIES):
		return
	if _dist_to(entity) <= MINION_RADIUS:
		_barks.say("minion_died")


func _on_skill_cast(_skill_id: String, _level: int) -> void:
	# No caster in the payload, so gate on "a player was near us at the last poll".
	if _last_player_dist <= REACT_RADIUS:
		_barks.say("player_skill_used")


func _on_chunk_broken(chunk: Node) -> void:
	if _dist_to(chunk) <= REACT_RADIUS:
		_barks.say("player_wall_break")


func _on_player_downed(player: Node, _by: Node) -> void:
	if _dist_to(player) <= REACT_RADIUS:
		_barks.say("player_downed")


func _on_final_wave_started() -> void:
	_barks.say("storm")


func _on_match_lost() -> void:
	_barks.say("boss_defeated_you")


func _on_nemesis_returned(serial: String, _title: String, _node: Node) -> void:
	if serial == "":
		return
	_serial = serial
	_barks.say("nemesis_return", [serial])


# ----------------------------------------------------------------------- state watching
## Announce only the DEEPEST threshold newly crossed, so a single huge hit that skips a
## phase can't make the boss narrate the phases out of order afterwards.
func _check_phases() -> void:
	var ratio: float = _hp_ratio()
	var stage: int = 0
	if ratio <= DYING_RATIO:
		stage = 3
	elif ratio <= PHASE3_RATIO:
		stage = 2
	elif ratio <= PHASE2_RATIO:
		stage = 1
	if stage <= _stage:
		return
	_stage = stage
	match stage:
		1:
			_barks.say("phase2")
		2:
			_barks.say("phase3_enrage")
		3:
			_barks.say("boss_dying")


## The 1 Hz observation tick: who is the nearest live player, and what are they doing?
## Reactive contexts are tested before the filler ones so the engine's global gap lets a
## real reaction win over an idle taunt on the same tick.
func _poll_players() -> void:
	var nearest: Node3D = _nearest_player()
	if nearest == null:
		_last_player_dist = INF
		_static_t = 0.0
		_hide_t = 0.0
		return
	var dist: float = _boss.global_position.distance_to(nearest.global_position)
	_last_player_dist = dist
	if dist <= RUSH_DIST:
		_barks.say("player_rushing")
	_check_camping(nearest)
	_check_hiding(dist)
	_check_low_hp(nearest)
	_check_nemesis()
	if _hp_ratio() > PHASE2_RATIO and _boss_engaged():
		_barks.say("boss_healthy_taunt")
	if _boss_engaged():
		_barks.say("generic_combat")


## Same player parked within CAMP_MOVE metres for CAMP_TIME seconds. Switching target
## resets the clock so a squad shuffling positions doesn't read as camping.
func _check_camping(player: Node3D) -> void:
	var id: int = player.get_instance_id()
	if id != _camp_id:
		_camp_id = id
		_camp_pos = player.global_position
		_static_t = 0.0
		return
	if player.global_position.distance_to(_camp_pos) > CAMP_MOVE:
		_camp_pos = player.global_position
		_static_t = 0.0
		return
	_static_t += POLL_INTERVAL
	if _static_t >= CAMP_TIME:
		_static_t = 0.0
		_barks.say("player_camping")


## A player is close but we have not been chasing/attacking for HIDE_TIME — they're
## breaking line of sight. No raycast: the replicated FSM state already encodes it.
func _check_hiding(dist: float) -> void:
	if dist > NEAR_PLAYER_DIST or _boss_engaged():
		_hide_t = 0.0
		return
	_hide_t += POLL_INTERVAL
	if _hide_t >= HIDE_TIME:
		_hide_t = 0.0
		_barks.say("player_hiding")


func _check_low_hp(player: Node3D) -> void:
	var hp: Node = player.get_node_or_null(Groups.NODE_HEALTH)
	if hp == null:
		return
	var maxhp: float = _num(hp, "max_health", 0.0)
	if maxhp <= 0.0 or _num(hp, "current", maxhp) / maxhp >= LOW_HP_FRAC:
		return
	var now: int = Time.get_ticks_msec()
	if now < _low_hp_ms:
		return
	_low_hp_ms = now + int(LOW_HP_CD * 1000.0)
	_barks.say("player_low_hp")


## The rival only gets name-dropped while it is actually in the raid and we're fighting.
func _check_nemesis() -> void:
	if _serial == "":
		_serial = _lookup_serial()
	if _serial == "" or not _boss_engaged():
		return
	if get_tree().get_nodes_in_group(Groups.NEMESIS).is_empty():
		return
	var now: int = Time.get_ticks_msec()
	if now < _nemesis_ms:
		return
	_nemesis_ms = now + int(NEMESIS_CD * 1000.0)
	_barks.say("nemesis_killed_you_before", [_serial])


# ------------------------------------------------------------------------------ helpers
func _nearest_player() -> Node3D:
	var best: float = INF
	var found: Node3D = null
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		var pn: Node3D = p as Node3D
		if pn == null or not is_instance_valid(pn) or not pn.is_inside_tree():
			continue
		if pn.has_method("is_downed") and bool(pn.call("is_downed")):
			continue
		var d: float = _boss.global_position.distance_to(pn.global_position)
		if d < best:
			best = d
			found = pn
	return found


## Distance from the boss to any node, or INF when the node has no world position.
func _dist_to(node: Node) -> float:
	var n3: Node3D = node as Node3D
	if n3 == null or not is_instance_valid(n3) or not n3.is_inside_tree():
		return INF
	return _boss.global_position.distance_to(n3.global_position)


## True while the boss is chasing or attacking. Unknown state counts as ENGAGED so the
## hiding check never fires on a parent that doesn't expose an FSM.
func _boss_engaged() -> bool:
	var v: Variant = _boss.get("current_state")
	if typeof(v) != TYPE_INT:
		return true
	var st: int = int(v)
	return st == STATE_CHASE or st == STATE_ATTACK


func _hp_ratio() -> float:
	var maxhp: float = _num(_health, "max_health", 0.0)
	if maxhp <= 0.0:
		return 1.0
	return clampf(_num(_health, "current", maxhp) / maxhp, 0.0, 1.0)


func _is_dead() -> bool:
	if _health == null:
		return false
	var v: Variant = _health.get("is_dead")
	return v is bool and bool(v)


## The host knows the rival from the codex mirror; a client gets the same dict synced.
func _lookup_serial() -> String:
	var d: Dictionary = GameState.nemesis_active
	if d.is_empty():
		return ""
	return String(d.get("serial", ""))


## Read a numeric property off a duck-typed node, falling back when it is absent.
static func _num(node: Node, prop: String, fallback: float) -> float:
	if node == null or not is_instance_valid(node):
		return fallback
	var v: Variant = node.get(prop)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return fallback
