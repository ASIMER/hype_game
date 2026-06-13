class_name EnemyStatus
extends Node
## Machine Chemistry (Phase 5) — the per-enemy status-effect component, the enemy-side
## mirror of PlayerStatus. Instantiated IN CODE by robot_enemy._ready() (add_child — no
## scene edit). Holds the 4 machine statuses: SHOCK / BURN / SLOW / BRITTLE.
##
## AUTHORITY-LOCAL, exactly like the EMP stun: the server decides + ticks every effect;
## the RESULT replicates implicitly (HP via Health.current, the slowed/stunned body via
## position). The per-status VISUAL is the one thing clients can't derive, so robot_enemy
## broadcasts the active-flag set via an @rpc on every change (drives flames/frost/arc).
##
## Climate amplification + cross-enemy reactions (chain discharge, freeze→shatter) live in
## MachineChemistry; this node is a dumb state-setter that receives ALREADY-resolved values.

var _e: Node3D = null  # the owning enemy (robot_enemy)
var _health: Node = null

# --- BURN (a damage-over-time, authority-local; mirrors PlayerStatus bleed) ---
var _burn_left: float = 0.0
var _burn_dps: float = 0.0
var _burn_accum: float = 0.0  # accumulates delta between DoT ticks
## True ONLY for the single take_damage call our burn tick makes, so the enemy's
## chemistry damage filter skips the brittle amplifier (burn must not compound itself).
var _dot_active: bool = false

# --- SLOW (cryo movement penalty) ---
var _slow_left: float = 0.0
var _slow_mult: float = 1.0

# --- BRITTLE (incoming-damage amplifier) ---
var _brittle_left: float = 0.0
var _brittle_mult: float = 1.0

# --- SHOCK visual window (the stun itself reuses the enemy's _stunned_until_ms clock) ---
var _shock_fx_left: float = 0.0

var _last_flags: int = 0  # last broadcast active-flag set (edge detection)


func setup(enemy: Node3D) -> void:
	_e = enemy
	_health = enemy.get_node_or_null(Groups.NODE_HEALTH)


## Per-frame status ticking (authority-local). Burn deals its DoT on an interval; slow /
## brittle / shock-fx count down. Frozen outside a live match + on a dead body, exactly
## like PlayerStatus. Pause-safe: pure delta accumulation, never create_timer.
func _physics_process(delta: float) -> void:
	if _e == null or not _e.is_multiplayer_authority():
		return
	if GameState.phase != GameState.Phase.IN_MATCH:
		return
	if _health != null and bool(_health.get("is_dead")):
		if _last_flags != 0:
			clear_all()
		return

	if _burn_left > 0.0:
		_burn_left = maxf(0.0, _burn_left - delta)
		_burn_accum += delta
		while _burn_accum >= Settings.CHEM_BURN_TICK and _burn_left >= 0.0 and _burn_dps > 0.0:
			_burn_accum -= Settings.CHEM_BURN_TICK
			_apply_burn_tick()
	if _slow_left > 0.0:
		_slow_left = maxf(0.0, _slow_left - delta)
		if _slow_left <= 0.0:
			_slow_mult = 1.0
	if _brittle_left > 0.0:
		_brittle_left = maxf(0.0, _brittle_left - delta)
		if _brittle_left <= 0.0:
			_brittle_mult = 1.0
	if _shock_fx_left > 0.0:
		_shock_fx_left = maxf(0.0, _shock_fx_left - delta)
	_sync()


## Apply (or refresh) one status with an ALREADY-resolved duration + magnitude. Server-gated.
## SHOCK routes through the enemy's apply_stun so it inherits EMP/boss/nemesis resistance and
## shares ONE stun clock; the others set their own deadline.
func apply(kind: String, dur: float, mag: float) -> void:
	if _e == null or not _e.is_multiplayer_authority():
		return
	match kind:
		"shock":
			_shock_fx_left = maxf(_shock_fx_left, Settings.CHEM_SHOCK_FX)
			if _e.has_method("apply_stun"):
				_e.apply_stun(maxf(mag, 0.0))
		"burn":
			_burn_left = maxf(_burn_left, dur)
			_burn_dps = maxf(_burn_dps, mag)
			if _burn_left <= dur:
				_burn_accum = 0.0
		"slow":
			_slow_left = maxf(_slow_left, dur)
			_slow_mult = clampf(minf(_slow_mult, mag), Settings.CHEM_SLOW_MIN_MULT, 1.0)
		"brittle":
			_brittle_left = maxf(_brittle_left, dur)
			_brittle_mult = maxf(_brittle_mult, mag)
	_sync()


## Movement-speed multiplier from an active slow (1.0 = none). Read in _apply_movement.
func speed_mult() -> float:
	return _slow_mult if _slow_left > 0.0 else 1.0


## Incoming-damage multiplier from an active brittle (1.0 = none). Read by the enemy's
## Health.damage_filter (the burn tick is exempted via is_dot_tick so it never compounds).
func incoming_damage_mult() -> float:
	return _brittle_mult if _brittle_left > 0.0 else 1.0


## Bit-packed set of currently-active statuses (drives the visual-sync RPC + QA).
func active_kinds() -> int:
	var f: int = 0
	if _shock_fx_left > 0.0:
		f |= Settings.CHEM_SHOCK
	if _burn_left > 0.0:
		f |= Settings.CHEM_BURN
	if _slow_left > 0.0:
		f |= Settings.CHEM_SLOW
	if _brittle_left > 0.0:
		f |= Settings.CHEM_BRITTLE
	return f


## True while the damage flowing through the enemy's filter is OUR burn tick (skip brittle).
func is_dot_tick() -> bool:
	return _dot_active


func has(kind: String) -> bool:
	return (active_kinds() & _bit_for(kind)) != 0


## Remaining seconds per active status (for the harness — state.enemies[].status).
func status_dict() -> Dictionary:
	var out: Dictionary = {}
	if _shock_fx_left > 0.0:
		out["shock"] = _shock_fx_left
	if _burn_left > 0.0:
		out["burn"] = _burn_left
	if _slow_left > 0.0:
		out["slow"] = _slow_left
	if _brittle_left > 0.0:
		out["brittle"] = _brittle_left
	return out


## Wipe every status (death / despawn) and broadcast the clear.
func clear_all() -> void:
	_burn_left = 0.0
	_burn_dps = 0.0
	_slow_left = 0.0
	_slow_mult = 1.0
	_brittle_left = 0.0
	_brittle_mult = 1.0
	_shock_fx_left = 0.0
	_sync()


## Deal one burn tick through Health, wrapped in the DoT guard so the brittle filter
## skips it. Authority-local; self-ends on a dead body.
func _apply_burn_tick() -> void:
	if _health == null or bool(_health.get("is_dead")):
		_burn_left = 0.0
		return
	_dot_active = true
	_health.call("take_damage", _burn_dps * Settings.CHEM_BURN_TICK, _e)
	_dot_active = false


## Broadcast the active-flag set on every EDGE: the visual-sync RPC (all peers) + a
## per-kind Events signal (server-side, for nemesis telemetry + HUD). No-op when unchanged.
func _sync() -> void:
	if _e == null or not _e.is_multiplayer_authority():
		return
	var flags: int = active_kinds()
	if flags == _last_flags:
		return
	var changed: int = flags ^ _last_flags
	_last_flags = flags
	# Broadcast the flag set to every peer (call_local also runs it here) → per-enemy FX.
	# Node.rpc() dispatches by name so this stays duck-typed from the child component.
	_e.rpc("sync_chemistry_flags", flags)
	for kind in ["shock", "burn", "slow", "brittle"]:
		var bit: int = _bit_for(kind)
		if (changed & bit) != 0:
			Events.enemy_chemistry_applied.emit(_e, kind, (flags & bit) != 0)


func _bit_for(kind: String) -> int:
	return MachineChemistry.bit_for(kind)
