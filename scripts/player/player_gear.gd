class_name PlayerGear
extends Node
## Grenade-selection + deployable-gadget component of the PLAYER (created in
## player._ready as the "Gear" child). Split out of player.gd purely for size
## discipline (the god file sits at the gdlint max-file-lines ceiling) — state
## stays ON the player (the replicated `_grenade_counts`/`_gadget_counts` dicts
## and `_grenade_sel`); this node only implements the verbs the input layer calls.
## Authority-only by construction: player._unhandled_input is authority-gated.

## Node path of the player's WeaponController (it lives under the Camera3D; its
## ModelHolder is reparented to WeaponMount by player._ready — see the FP-arms block).
const WEAPON_CONTROLLER_PATH := "CameraPivot/SpringArm3D/Camera3D/WeaponController"

var _p: Node3D  # the owning player (duck-typed: counts/sel/stance/camera live there)


func _ready() -> void:
	_p = get_parent() as Node3D
	# First-person arms are a LOCAL view-model — only the owning peer polls for them,
	# so a remote avatar's copy of this component never even processes (see _process).
	set_process(_p != null and _p.is_multiplayer_authority())


## Inventory-Use dispatch (moved from player.gd verbatim — the god file hit the
## 1800-line ceiling). Authority-gated like the original; state stays ON the player.
func on_item_use(item_id: String) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	match item_id:
		"loot_medkit", "medkit":
			_p._try_heal()
		"loot_ammo":
			# The Ammo Box existed but its Use was silently a no-op (item wasted).
			grant_ammo(1.0)
		"loot_grenade", "grenade":
			# Inventory-Use throws a FRAG specifically (the G key throws the selection).
			_p._grenade_sel = "frag"
			if int(_p._grenade_counts.get("frag", 0)) <= 0:
				_p._grenade_counts["frag"] = 1
			throw_selected()
		Settings.SELF_REVIVE_ITEM, "self_revive":
			if _p.downed:
				_p._self_revive()
		_:
			# Any utility grenade id (smoke/emp/decoy/incendiary/cryo) selects + throws its type.
			if item_id.begins_with("loot_grenade_"):
				_p._grenade_sel = item_id.trim_prefix("loot_grenade_")
				if int(_p._grenade_counts.get(_p._grenade_sel, 0)) <= 0:
					_p._grenade_counts[_p._grenade_sel] = 1
				throw_selected()


## Server → owner: resupply reserve ammo (`frac` of every weapon's reserve_max).
## Fired by an ammo-shard pickup (0.35) or an Ammo Box inventory use (1.0). RPC so
## the server-side pickup handler can grant it to a co-op CLIENT's own machine
## (ammo lives in the owner's WeaponController, like keys/flares).
@rpc("any_peer", "call_local", "reliable")
func grant_ammo(frac: float) -> void:
	if _p == null or not _p.is_multiplayer_authority():
		return
	var wc := _p.get_node_or_null(WEAPON_CONTROLLER_PATH)
	if wc != null and wc.has_method("add_reserve_frac"):
		wc.add_reserve_frac(frac)
	Events.notify.emit(tr("+ AMMO"), 0)


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
	# Batch B: worn-gear aggregates from the LOCAL profile (replicated so the server
	# validates pickups against carry capacity + remotes see the speed effect).
	_p.carry_bonus = MetaProgression.gear_carry_bonus()
	_p.gear_speed_mult = MetaProgression.gear_speed_mult()
	# Mutant Harvest: fresh skill set + visible limbs each raid.
	var sk := _p.get_node_or_null("Skills")
	if sk != null and sk.has_method("reset"):
		sk.reset()


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


## The player's FULL incoming-damage chain, delegated here from
## player._filter_incoming_damage for size discipline (state stays ON the player):
## roll i-frames → shield-dome gadgets → buff armor → overshield → worn armor
## (batch B) → status-effect rolls. Runs authority-local (the Hurtbox forwards
## hits to the owner).
func filter_incoming_damage(amount: float, source: Node) -> float:
	# Hijack & Pilot: while piloting, the HULL is the armor — the hit is routed into the
	# machine's Health (server-side via HijackDirector) and the pilot takes nothing.
	var hj: Node = _p.get_node_or_null(Groups.NODE_HIJACK)
	if hj != null and bool(hj.call("is_piloting")):
		HijackDirector.redirect_damage(amount)
		return 0.0
	# Dodge-roll i-frames: brief immunity vs ENEMY damage only. Self-damage and the
	# harness `hurt` QA path carry a non-enemy source, so they still land.
	var from_enemy := (
		source != null and is_instance_valid(source) and source.is_in_group(Groups.ENEMIES)
	)
	if from_enemy and Time.get_ticks_msec() < int(_p._iframes_until_ms):
		return 0.0
	# Shield-dome gadget: standing inside any active dome halves incoming damage.
	for dome in get_tree().get_nodes_in_group(Groups.DOMES):
		if not (dome is Node3D):
			continue
		var r := float(dome.get("radius")) if dome.get("radius") != null else 0.0
		if r > 0.0 and _p.global_position.distance_to((dome as Node3D).global_position) <= r:
			amount *= Settings.DOME_DAMAGE_MULT
			break
	var armor: float = clampf(float(_p.call("_buff_sum", "armor")), 0.0, 0.9)
	amount *= (1.0 - armor)
	# Mutant-Harvest limb TOUGHNESS passive (shield/mobility limbs + defense set bonus).
	var sk: Node = _p.get_node_or_null("Skills")
	if sk != null and sk.has_method("passive_toughness"):
		amount *= 1.0 - float(sk.passive_toughness())
	var shield: float = float(_p._overshield)
	if shield > 0.0:
		var absorbed: float = minf(shield, amount)
		_p._overshield = shield - absorbed
		amount -= absorbed
		# Frozen-bullet FX + absorbed counter on the energy dome (owner-local).
		if absorbed > 0.0:
			Events.shield_absorbed.emit(absorbed)
	# Status DoT ticks (bleed) bypass worn armor and never re-roll effects.
	var st: Node = _p.get_node_or_null("Status")
	if st != null and bool(st.call("is_dot_tick")):
		return amount
	# Worn-armor mitigation (batch B) — after overshield; drains gear durability.
	amount = mitigate_damage(amount)
	# Status rolls (bleed/fracture chance) see the FINAL applied amount.
	if st != null and amount > 0.0:
		st.call("apply_hit_effects", amount, from_enemy)
	return amount


## Worn-armor damage mitigation (batch B): intact equipped pieces' mitigation is
## summed (capped at ARMOR_MITIGATION_CAP) and the ABSORBED damage drains each
## intact piece's durability proportionally to its mitigation share. Runs on the
## authority (the filter chain does), so MetaProgression is the OWNER's profile —
## correctly per-peer in co-op. Broken pieces (durability 0) contribute nothing
## until repaired in the Hub.
func mitigate_damage(amount: float) -> float:
	if amount <= 0.0:
		return amount
	var pieces: Array = MetaProgression.equipped_armor_pieces()
	var mit_total: float = 0.0
	var intact: Array = []
	for p in pieces:
		var d: Dictionary = p
		if bool(d.get("broken", false)) or float(d.get("mitigation", 0.0)) <= 0.0:
			continue
		mit_total += float(d["mitigation"])
		intact.append(d)
	if intact.is_empty():
		return amount
	mit_total = minf(mit_total, Settings.ARMOR_MITIGATION_CAP)
	var absorbed: float = amount * mit_total
	# Drain durability proportionally to each piece's share of the total mitigation.
	var share_base: float = 0.0
	for d in intact:
		share_base += float(d["mitigation"])
	for d in intact:
		var share: float = float(d["mitigation"]) / maxf(share_base, 0.001)
		MetaProgression.drain_armor(String(d["id"]), absorbed * share)
	return amount - absorbed


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


# Deferred gadget placement: the keypress (an INPUT-context event) only queues the
# request; the ground-snap raycast runs in the next physics tick — space-state
# queries are only thread-safe inside the physics step (run_on_separate_thread).
var _pending_place: int = -1


## Queue placing the deployable gadget in quick-slot `idx` (keys 6/7/8 → GADGET_TYPES
## order). Executed by physics_tick() on the next physics frame.
func place(idx: int) -> void:
	_pending_place = idx


## Called once per frame from player._physics_process: executes a queued placement
## at the player's feet-forward point snapped to the ground. Server-spawned.
func physics_tick() -> void:
	if _pending_place < 0:
		return
	var idx := _pending_place
	_pending_place = -1
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


# ── First-person arms (D4.2) ─────────────────────────────────────────────────────
# The first-person zoom step used to show a floating gun and nothing else — no body,
# no hands — so it read as a camera with a rifle taped to it. ProceduralArms builds a
# pair of forearms from the player's OWN cosmetics; this block owns their lifecycle.
#
# They are parented under the weapon's ModelHolder (which player._ready reparents to
# WeaponMount), NOT under the player: that way the weapon-controller's recoil kick and
# the FP/TP mount pose carry them for free and the fists never drift off the gun.
# Render-only + authority-local: nothing to replicate, nothing for a remote peer to run.
#
# The state is POLLED because there is no signal to hook — V just calls the player's
# _apply_view_visibility, and the ModelHolder silently frees ALL its children on every
# weapon switch (weapon_controller._refresh_model), which includes our arms. The poll is
# three cheap checks and everything past the first is skipped outside first person.
const ARMS_HOLDER_PATH := "WeaponMount/ModelHolder"

var _arms: Node3D = null
var _arms_weapon: String = ""  # weapon id the live arms were posed for
var _arms_cos: String = ""  # cosmetics signature the live arms were painted from


func _process(_delta: float) -> void:
	if _p == null or not is_instance_valid(_p):
		return
	if not _arms_wanted():
		if _arms != null and is_instance_valid(_arms) and _arms.visible:
			_arms.visible = false
		return
	var holder := _p.get_node_or_null(ARMS_HOLDER_PATH) as Node3D
	if holder == null:
		return  # reparented mid-_ready / no weapon controller — retry next frame
	var wid := _weapon_id()
	var cos_sig := str(_cosmetics())
	var stale := (
		_arms == null
		or not is_instance_valid(_arms)
		or _arms.is_queued_for_deletion()
		or _arms.get_parent() != holder
		or wid != _arms_weapon
		or cos_sig != _arms_cos
	)
	if stale:
		_rebuild_arms(holder, wid, cos_sig)
	if _arms != null and is_instance_valid(_arms) and not _arms.visible:
		_arms.visible = true


## Arms are drawn only in the first-person zoom step, and never while piloting a
## hijacked machine — the HijackDirector hides the pilot's body there, so a pair of
## arms floating over the hull would be the one thing left visible of him.
func _arms_wanted() -> bool:
	if not _p.has_method("_is_first_person") or not bool(_p.call("_is_first_person")):
		return false
	var hj: Node = _p.get_node_or_null(Groups.NODE_HIJACK)
	if hj != null and bool(hj.call("is_piloting")):
		return false
	return true


## Logical id of the equipped weapon — the arms are posed per weapon class.
func _weapon_id() -> String:
	var wc := _p.get_node_or_null(WEAPON_CONTROLLER_PATH)
	if wc != null and wc.has_method("current_weapon_id"):
		var id := String(wc.call("current_weapon_id"))
		if id != "":
			return id
	return ProceduralArms.DEFAULT_WEAPON


## The player's REPLICATED cosmetics dict (the same value the body is built from, so the
## arms repaint themselves the moment a customization change lands).
func _cosmetics() -> Dictionary:
	var out: Dictionary = {}
	var v: Variant = _p.get("cosmetics")
	if v is Dictionary:
		out = v
	return out


func _rebuild_arms(holder: Node3D, weapon_id: String, cos_sig: String) -> void:
	if _arms != null and is_instance_valid(_arms):
		_arms.queue_free()
	_arms = ProceduralArms.build(_cosmetics(), weapon_id)
	if _arms == null:
		return
	holder.add_child(_arms)
	_arms_weapon = weapon_id
	_arms_cos = cos_sig
