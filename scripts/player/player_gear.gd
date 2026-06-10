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


## Fill the player's consumable counts from the committed bring-list (moved here from
## player.gd verbatim for size discipline — state stays ON the player; see header).
func apply_loadout() -> void:
	var brought := MetaProgression.get_bring()
	_p._medkits = int(brought.get("loot_medkit", 0))
	_p._self_revives = int(brought.get(Settings.SELF_REVIVE_ITEM, 0))
	_p._shields = int(brought.get(Settings.KNOCKDOWN_SHIELD_ITEM, 0))
	# Per-type grenade counts from the bring-list (GRENADE_ITEM_IDS maps type → item id);
	# select the first type with ammo so G works immediately.
	_p._grenade_counts = {}
	for t in Settings.GRENADE_TYPES:
		var iid := String(Settings.GRENADE_ITEM_IDS[t])
		var c := int(brought.get(iid, 0))
		if c > 0:
			_p._grenade_counts[String(t)] = c
	_p._grenade_sel = "frag"
	if int(_p._grenade_counts.get("frag", 0)) <= 0:
		cycle()
	# Deployable gadgets (item id == type id).
	_p._gadget_counts = {}
	for t in Settings.GADGET_TYPES:
		var c2 := int(brought.get(String(t), 0))
		if c2 > 0:
			_p._gadget_counts[String(t)] = c2
	# Batch C: annex keys (ids frozen in Settings.LOCKED_ROOM_POIS) + signal flares.
	_p._keys = {}
	for poi in Settings.LOCKED_ROOM_POIS:
		var kid := String(Settings.LOCKED_ROOM_POIS[poi]["key"])
		var kc := int(brought.get(kid, 0))
		if kc > 0:
			_p._keys[kid] = kc
	_p._flares = int(brought.get("loot_flare", 0))
	# Batch B: medicine 2.0 consumables (counters replicate like _medkits).
	_p._bandages = int(brought.get("loot_bandage", 0))
	_p._splints = int(brought.get("loot_splint", 0))
	_p._painkillers = int(brought.get("loot_painkiller", 0))


## Surviving brought consumables as stash stacks — added to the extraction deposit so
## unused medkits/grenades/gadgets/keys/flares come back out with you (lost on death).
func extracted_consumables() -> Array:
	var out: Array = []
	if int(_p._medkits) > 0:
		out.append({"id": "loot_medkit", "count": int(_p._medkits)})
	for t in _p._grenade_counts:
		var c := int(_p._grenade_counts[t])
		if c > 0:
			out.append({"id": String(Settings.GRENADE_ITEM_IDS[t]), "count": c})
	for t in _p._gadget_counts:
		var c2 := int(_p._gadget_counts[t])
		if c2 > 0:
			out.append({"id": String(t), "count": c2})
	for kid in _p._keys:
		var kc := int(_p._keys[kid])
		if kc > 0:
			out.append({"id": String(kid), "count": kc})
	if int(_p._flares) > 0:
		out.append({"id": "loot_flare", "count": int(_p._flares)})
	for med in [
		["loot_bandage", "_bandages"],
		["loot_splint", "_splints"],
		["loot_painkiller", "_painkillers"]
	]:  # gdlint: ignore=max-line-length
		var mc := int(_p.get(String(med[1])))
		if mc > 0:
			out.append({"id": String(med[0]), "count": mc})
	return out


## Worn-armor damage mitigation (batch B): intact pieces' mitigation is summed
## (capped) and the absorbed damage drains per-item-ID durability via the gear
## profile. FOUNDATION STUB — the gear-data lane lands the MetaProgression API;
## the lead fills this at integration. Stub: pass-through.
func mitigate_damage(amount: float) -> float:
	return amount


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
