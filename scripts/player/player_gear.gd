class_name PlayerGear
extends Node
## Grenade-selection + deployable-gadget component of the PLAYER (created in
## player._ready as the "Gear" child). Split out of player.gd purely for size
## discipline (the god file sits at the gdlint max-file-lines ceiling) — state
## stays ON the player (the replicated `_grenade_counts`/`_gadget_counts` dicts
## and `_grenade_sel`); this node only implements the verbs the input layer calls.
## Authority-only by construction: player._unhandled_input is authority-gated.

var _p: Node3D  # the owning player (duck-typed: counts/sel/stance/camera live there)


func _ready() -> void:
	_p = get_parent() as Node3D


## Throw the SELECTED grenade type from the chest along the aim direction. All throws
## route through the server (NetworkManager.request_throw_grenade → the Net/Gadgets
## spawner) so server-side effects (EMP stun / decoy noise / smoke AI) exist exactly
## once and every peer sees the same projectile. Decrements the replicated count.
func throw_selected() -> void:
	if int(_p.stance) == 3:  # Stance.ROLL — no throwing mid-tumble
		return
	var sel := String(_p._grenade_sel)
	var cnt := int(_p._grenade_counts.get(sel, 0))
	if cnt <= 0:
		# Auto-switch to any type that still has ammo (quality of life).
		cycle()
		sel = String(_p._grenade_sel)
		cnt = int(_p._grenade_counts.get(sel, 0))
		if cnt <= 0:
			return
	var cam: Camera3D = _p.get_node("CameraPivot/SpringArm3D/Camera3D")
	var from: Vector3 = _p.global_position + Vector3.UP * 1.4
	var dir: Vector3 = -cam.global_transform.basis.z
	_p._grenade_counts[sel] = cnt - 1
	NetworkManager.request_throw_grenade(sel, from, dir)
	Events.grenade_thrown.emit(_p, from, dir)
	Events.grenade_selection_changed.emit(sel, cnt - 1)


## Cycle the selected grenade type to the next one with ammo (B key / HUD chip).
func cycle() -> void:
	var types: Array = Settings.GRENADE_TYPES
	var sel := String(_p._grenade_sel)
	var start := types.find(sel)
	for i in range(1, types.size() + 1):
		var t := String(types[(start + i) % types.size()])
		if int(_p._grenade_counts.get(t, 0)) > 0:
			_p._grenade_sel = t
			break
	var now_sel := String(_p._grenade_sel)
	Events.grenade_selection_changed.emit(now_sel, int(_p._grenade_counts.get(now_sel, 0)))


## Place the deployable gadget in quick-slot `idx` (keys 6/7/8 → GADGET_TYPES order)
## at the player's feet-forward point snapped to the ground. Server-spawned.
func place(idx: int) -> void:
	if _p.is_downed() or int(_p.stance) == 3 or _p._zipline != null:
		return
	var types: Array = Settings.GADGET_TYPES
	if idx < 0 or idx >= types.size():
		return
	var t := String(types[idx])
	var cnt := int(_p._gadget_counts.get(t, 0))
	if cnt <= 0:
		return
	var facing: Vector3 = -_p.global_transform.basis.z
	facing.y = 0.0
	if facing.length_squared() < 0.0001:
		return
	var pos: Vector3 = _p.global_position + facing.normalized() * 1.5
	# Snap to the ground (reject placements over a void/drop).
	var space := _p.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 1.0, pos + Vector3.DOWN * 3.0)
	q.collision_mask = 1
	q.exclude = [_p.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var ground: Vector3 = hit["position"]
	_p._gadget_counts[t] = cnt - 1
	NetworkManager.request_place_gadget(t, ground, _p.rotation.y)
	Events.gadget_placed.emit(_p, t, ground)
