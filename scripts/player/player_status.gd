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


func _ready() -> void:
	_p = get_parent() as Node3D


## Hook: the player's damage filter tail calls this AFTER armor/overshield with the
## FINAL applied amount. May roll BLEED (enemy hits >= BLEED_HIT_THRESHOLD) and
## FRACTURE (hits >= FRACTURE_HIT_THRESHOLD). Stub: no-op.
func apply_hit_effects(_amount: float, _from_enemy: bool) -> void:
	pass


## Hook: called once on landing with the peak downward speed of the fall.
## FRACTURE rolls when it exceeds Settings.FRACTURE_FALL_SPEED. Stub: no-op.
func on_landed(_fall_peak: float) -> void:
	pass


## Movement-speed multiplier from active statuses (fracture 0.7, painkiller masks
## the penalty). Multiplied into the player's speed block every frame. Stub: 1.0.
func speed_mult() -> float:
	return 1.0


## False while a fracture (unmasked by painkiller) forbids sprinting. Stub: true.
func can_sprint() -> bool:
	return true


## True while `effect` ("bleed"/"fracture"/"painkiller") is active. Stub: false.
func has_effect(_effect: String) -> bool:
	return false


## True while the damage currently flowing through the player's filter is OUR OWN
## status DoT tick (bleed) — the filter then skips armor mitigation + effect re-rolls.
## The lane sets a guard flag around its tick's take_damage call. Stub: false.
func is_dot_tick() -> bool:
	return false


## Active effects (for the HUD icons + the harness state). Stub: [].
func active_effects() -> Array:
	return []


## The H-key smart-heal: triage what the player needs most and consume it —
## medkit (missing HP) → bandage (bleeding) → splint (fracture) → painkiller.
## Returns true if something was used. The stub falls back to the plain medkit
## heal so H keeps working before the medicine lane lands.
func smart_heal() -> bool:
	return _use_medkit()


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
