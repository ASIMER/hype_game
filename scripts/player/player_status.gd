class_name PlayerStatus
extends Node
## Status-effect component of the PLAYER (the "Status" child node in Player.tscn):
## BLEED / FRACTURE / PAINKILLER + the H-key smart-heal triage (batch B, medicine 2.0).
##
## FOUNDATION STUB — the public surface below is FROZEN (player.gd / HUD / harness
## code against it); the medicine lane fills the bodies. Everything here must stay
## authority-local (the same discipline as the player's `_buffs`): effects are
## decided and ticked ONLY on the owning peer — the Hurtbox forwards damage to the
## owner, so the hit hooks already run there. No replication, no netcode.
##
## Counters live ON the player (`_bandages/_splints/_painkillers`, replicated for
## extraction accounting like medkits); this node only implements behavior.

var _p: Node3D  # the owning player

# --- BLEED (a damage-over-time, authority-local) ---
var _bleeding: bool = false
var _bleed_left: float = 0.0  # seconds of bleed remaining (frozen while downed)
var _bleed_tick_accum: float = 0.0  # accumulates delta between DoT ticks
## True ONLY for the single Health.take_damage call our bleed tick makes, so the
## player's damage filter recognizes it (skip armor + effect re-rolls). See is_dot_tick.
var _dot_active: bool = false

# --- FRACTURE (permanent until a splint, authority-local) ---
var _fractured: bool = false

# --- PAINKILLER (a timed mask over the fracture penalty, delta-accumulated) ---
var _painkiller_left: float = 0.0  # seconds the mask is still active (0 = inactive)


func _ready() -> void:
	_p = get_parent() as Node3D


## Per-frame status ticking (authority-local). Bleed deals its DoT on an interval and
## self-clears at duration; the painkiller mask counts down. The whole loop FREEZES while
## the player is downed (a down is its own crisis — the bleed timer must not advance or
## expire), exactly like the buff/bleedout discipline. Pause-safe: pure delta accumulation,
## never get_tree().create_timer.
func _physics_process(delta: float) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	# DOWNED: freeze every status timer (don't tick the DoT, don't expire bleed/painkiller).
	if bool(_p.get("downed")):
		return

	# Painkiller mask countdown → natural expiry (the fracture itself persists past it).
	if _painkiller_left > 0.0:
		_painkiller_left = maxf(0.0, _painkiller_left - delta)
		if _painkiller_left <= 0.0:
			Events.status_changed.emit(_p, "painkiller", false)

	# Bleed DoT: tick on the interval, end at the duration.
	if _bleeding:
		_bleed_left = maxf(0.0, _bleed_left - delta)
		_bleed_tick_accum += delta
		while _bleed_tick_accum >= Settings.BLEED_TICK_INTERVAL and _bleeding:
			_bleed_tick_accum -= Settings.BLEED_TICK_INTERVAL
			_apply_bleed_tick()
		if _bleed_left <= 0.0:
			_end_bleed()


## Hook: the player's damage filter tail calls this AFTER armor/overshield with the
## FINAL applied amount. May roll BLEED (enemy hits >= BLEED_HIT_THRESHOLD) and
## FRACTURE (hits >= FRACTURE_HIT_THRESHOLD).
func apply_hit_effects(amount: float, from_enemy: bool) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	# BLEED: only enemy hits above the threshold, on a chance roll; a re-roll refreshes.
	if from_enemy and amount >= Settings.BLEED_HIT_THRESHOLD and randf() < Settings.BLEED_CHANCE:
		_start_bleed()
	# FRACTURE: any big enough single hit (enemy or otherwise) breaks a leg.
	if amount >= Settings.FRACTURE_HIT_THRESHOLD:
		_start_fracture()


## Hook: called once on landing with the peak downward speed of the fall.
## FRACTURE rolls when it exceeds Settings.FRACTURE_FALL_SPEED.
func on_landed(fall_peak: float) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	if fall_peak > Settings.FRACTURE_FALL_SPEED:
		_start_fracture()


## Movement-speed multiplier from active statuses (fracture 0.7, painkiller masks
## the penalty). Multiplied into the player's speed block every frame.
func speed_mult() -> float:
	if _fractured and not _painkiller_active():
		return Settings.FRACTURE_SPEED_MULT
	return 1.0


## False while a fracture (unmasked by painkiller) forbids sprinting.
func can_sprint() -> bool:
	if _fractured and not _painkiller_active():
		return false
	return true


## True while `effect` ("bleed"/"fracture"/"painkiller") is active.
func has_effect(effect: String) -> bool:
	match effect:
		"bleed":
			return _bleeding
		"fracture":
			return _fractured
		"painkiller":
			return _painkiller_active()
	return false


## True while the damage currently flowing through the player's filter is OUR OWN
## status DoT tick (bleed) — the filter then skips armor mitigation + effect re-rolls.
## The lane sets a guard flag around its tick's take_damage call.
func is_dot_tick() -> bool:
	return _dot_active


## Active effects (for the HUD icons + the harness state).
func active_effects() -> Array:
	var out: Array = []
	if _bleeding:
		out.append("bleed")
	if _fractured:
		out.append("fracture")
	if _painkiller_active():
		out.append("painkiller")
	return out


## The H-key smart-heal: triage what the player needs most and consume it —
## medkit (missing HP) → bandage (bleeding) → splint (fracture) → painkiller.
## Returns true if something was used.
func smart_heal() -> bool:
	# 1) Medkit when HP is missing (the pre-batch-B heal path, unchanged).
	if _use_medkit():
		return true
	# 2) Bandage to stop a bleed.
	if _bleeding and use_bandage():
		return true
	# 3) Splint to mend a fracture.
	if _fractured and use_splint():
		return true
	# 4) Painkiller to mask injuries (only worth it while actually injured).
	if (_bleeding or _fractured) and use_painkiller():
		return true
	return false


## Consume one medkit from the player (the pre-batch-B heal path, kept as the
## triage's first leg). Lives here so player.gd stays a thin delegate.
func _use_medkit() -> bool:
	var hp: Node = _p.get_node_or_null("Health")
	if hp == null or int(_p.get("_medkits")) <= 0:
		return false
	if bool(hp.get("is_dead")) or float(hp.get("current")) >= float(hp.get("max_health")):
		return false
	_p.set("_medkits", int(_p.get("_medkits")) - 1)
	hp.call("heal", Settings.HEAL_AMOUNT)
	Events.player_healed.emit(_p, Settings.HEAL_AMOUNT)
	return true


## Consume one bandage to stop bleeding. Single-purpose (the lead may wire it to an
## inventory Use button). Returns true only when a bandage was actually spent.
func use_bandage() -> bool:
	if not _bleeding or int(_p.get("_bandages")) <= 0:
		return false
	_p.set("_bandages", int(_p.get("_bandages")) - 1)
	_end_bleed()
	return true


## Consume one splint to mend a fracture. Returns true only when one was spent.
func use_splint() -> bool:
	if not _fractured or int(_p.get("_splints")) <= 0:
		return false
	_p.set("_splints", int(_p.get("_splints")) - 1)
	_fractured = false
	Events.status_changed.emit(_p, "fracture", false)
	return true


## Consume one painkiller to start the injury-penalty mask. The fracture itself persists;
## the mask only hides its movement penalty for PAINKILLER_DURATION. Note: a painkiller
## does NOT stop the bleed DoT (bleed has no movement penalty to mask — a bandage clears it).
func use_painkiller() -> bool:
	if int(_p.get("_painkillers")) <= 0:
		return false
	_p.set("_painkillers", int(_p.get("_painkillers")) - 1)
	var was_active := _painkiller_active()
	_painkiller_left = Settings.PAINKILLER_DURATION
	if not was_active:
		Events.status_changed.emit(_p, "painkiller", true)
	return true


## True while the painkiller mask is up.
func _painkiller_active() -> bool:
	return _painkiller_left > 0.0


## Start (or refresh) a bleed: full duration, reset the tick accumulator on a fresh start.
func _start_bleed() -> void:
	var was_bleeding := _bleeding
	_bleeding = true
	_bleed_left = Settings.BLEED_DURATION
	if not was_bleeding:
		_bleed_tick_accum = 0.0
		Events.status_changed.emit(_p, "bleed", true)


## End a bleed (natural expiry OR a bandage). Idempotent.
func _end_bleed() -> void:
	if not _bleeding:
		return
	_bleeding = false
	_bleed_left = 0.0
	_bleed_tick_accum = 0.0
	Events.status_changed.emit(_p, "bleed", false)


## Deal one bleed tick through the player's Health, wrapped in the DoT guard so the
## damage filter skips armor + effect re-rolls (and re-routes nothing). Authority-local.
func _apply_bleed_tick() -> void:
	var hp: Node = _p.get_node_or_null("Health")
	if hp == null or bool(hp.get("is_dead")):
		_end_bleed()
		return
	_dot_active = true
	hp.call("take_damage", Settings.BLEED_DPS_TICK, _p)
	_dot_active = false


## Start a fracture (permanent until a splint). Idempotent — re-fracturing is a no-op
## (it can't get "more" broken), so no duplicate signal is emitted.
func _start_fracture() -> void:
	if _fractured:
		return
	_fractured = true
	Events.status_changed.emit(_p, "fracture", true)
