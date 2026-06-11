class_name AgentGearDebug
extends RefCounted
## QA drivers for the batch B survival systems (AgentBridge "gear" / "secure" /
## "status" / "insure" commands), extracted from AgentBridge for file-size
## discipline — the bridge sits at the gdlint max-file-lines ceiling.


## Worn armor: {action:"state"|"equip"|"repair"|"drain", slot?, id?, amount?}.
static func gear(json: Dictionary) -> Dictionary:
	var action := str(json.get("action", "state"))
	match action:
		"equip":
			MetaProgression.set_equipped_gear(str(json.get("slot", "")), str(json.get("id", "")))
		"repair":
			var rid := str(json.get("id", ""))
			return {
				"ok": MetaProgression.repair_armor(rid),
				"durability": MetaProgression.durability_of(rid),
				"currency": MetaProgression.currency,
			}
		"drain":
			MetaProgression.drain_armor(str(json.get("id", "")), float(json.get("amount", 10.0)))
	return {
		"ok": true,
		"equipped": MetaProgression.get_equipped_gear(),
		"pieces": MetaProgression.equipped_armor_pieces(),
		"durability": MetaProgression.armor_durability,
		"carry_bonus": MetaProgression.gear_carry_bonus(),
		"speed_mult": MetaProgression.gear_speed_mult(),
	}


## Secure pouch: {id, on} flags a stack; no args = report. Owner-routed.
static func secure(json: Dictionary, tree: SceneTree) -> Dictionary:
	var p: Node = _authority_player(tree)
	if p == null:
		return {"ok": false, "error": "no player"}
	var inv: Node = p.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("request_secure"):
		return {"ok": false, "error": "no secure-pouch inventory"}
	if json.has("id"):
		inv.call("request_secure", str(json.get("id", "")), bool(json.get("on", true)))
	return {"ok": true, "secure": inv.get("secure"), "stacks": inv.call("secure_stacks")}


## Status effects: {action:"apply"|"clear"|"use"|"list", effect?, item?}.
static func status(json: Dictionary, tree: SceneTree) -> Dictionary:
	var p: Node = _authority_player(tree)
	var st: Node = p.get_node_or_null("Status") if p != null else null
	if st == null:
		return {"ok": false, "error": "no Status node"}
	var action := str(json.get("action", "list"))
	var effect := str(json.get("effect", ""))
	match action:
		"apply":
			match effect:
				"bleed":
					st.call("_start_bleed")
				"fracture":
					st.call("_start_fracture")
				"painkiller":
					p.set("_painkillers", maxi(1, int(p.get("_painkillers"))))
					st.call("use_painkiller")
		"clear":
			match effect:
				"bleed":
					st.call("_end_bleed")
				"fracture":
					p.set("_splints", maxi(1, int(p.get("_splints"))))
					st.call("use_splint")
		"use":
			var item := str(json.get("item", "smart"))
			var used := false
			match item:
				"bandage":
					used = bool(st.call("use_bandage"))
				"splint":
					used = bool(st.call("use_splint"))
				"painkiller":
					used = bool(st.call("use_painkiller"))
				_:
					used = bool(st.call("smart_heal"))
			return {"ok": true, "used": used, "effects": st.call("active_effects")}
	return {
		"ok": true,
		"effects": st.call("active_effects"),
		"speed_mult": st.call("speed_mult"),
		"can_sprint": st.call("can_sprint"),
	}


## Insurance: {id} insures · {action:"mature"} rewinds pending · {action:"state"}.
static func insure(json: Dictionary) -> Dictionary:
	if json.has("id"):
		var iid := str(json.get("id", ""))
		return {
			"ok": MetaProgression.insure_item(iid),
			"insured": MetaProgression.insured_current,
			"currency": MetaProgression.currency,
		}
	if str(json.get("action", "")) == "mature":
		# Rewind every pending return to NOW so the Hub poll can claim immediately.
		var now := int(Time.get_unix_time_from_system())
		for e in MetaProgression.insured_pending:
			e["return_at"] = now
		MetaProgression.save_profile()
	return {
		"ok": true,
		"insured": MetaProgression.insured_current,
		"pending": MetaProgression.insured_pending,
	}


static func _authority_player(tree: SceneTree) -> Node:
	var players := tree.get_nodes_in_group(Groups.PLAYERS)
	for p in players:
		if p.is_multiplayer_authority():
			return p
	return players[0] if players.size() > 0 else null
