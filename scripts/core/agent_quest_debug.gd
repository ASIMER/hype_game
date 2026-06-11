class_name AgentQuestDebug
extends RefCounted
## QA driver for the quest lifecycle (AgentBridge "quest" command + the state block's
## questline summary), extracted verbatim from AgentBridge for file-size discipline —
## the bridge sits at the gdlint max-file-lines ceiling. Logic unchanged.


static func questlines_meta() -> Dictionary:
	var out: Dictionary = {}
	for l in Quests.questlines():
		var ql := l as QuestLine
		var lp: Dictionary = Quests.line_progress(ql)
		out[ql.id] = {
			"done": lp.get("done", 0),
			"total": lp.get("total", 0),
			"current": lp.get("current_id", "")
		}
	return out


static func handle(json: Dictionary, tree: SceneTree) -> Dictionary:
	var action := str(json.get("action", "state"))
	var id := str(json.get("id", ""))
	match action:
		"offer":
			return {"ok": Quests.offer(id), "state": Quests.state_of(id)}
		"accept":
			return {"ok": Quests.accept(id), "state": Quests.state_of(id)}
		"claim":
			return {"ok": Quests.claim(id), "state": Quests.state_of(id)}
		"evaluate":
			if tree.root.has_node("QuestDirector"):
				tree.root.get_node("QuestDirector").evaluate_offers()
			return {"ok": true}
		"roll":
			# Force one per-raid weighted random offer (test the random board without raiding).
			if tree.root.has_node("QuestDirector"):
				tree.root.get_node("QuestDirector").roll_random_offer()
			return {"ok": true, "available": Quests.available_count()}
		"detail":
			# QA: open the rich detail modal for `id` (the harness can't click the ⓘ button).
			var sc := tree.current_scene
			var host: Node = null
			for n in sc.find_children("*", "CanvasLayer", true, false):
				host = n
				break
			if host == null:
				host = sc
			var modal: Node = (load("res://scripts/ui/quest_detail.gd") as GDScript).new()
			host.add_child(modal)
			modal.call("open", id)
			return {"ok": true}
		"lines":
			var lines: Array = []
			for l in Quests.questlines():
				var ql := l as QuestLine
				var lp: Dictionary = Quests.line_progress(ql)
				var steps: Array = []
				for s in Quests.line_steps(ql):
					steps.append(
						{"id": (s as QuestData).id, "state": Quests.state_of((s as QuestData).id)}
					)
				lines.append(
					{
						"id": ql.id,
						"title": ql.title,
						"giver": ql.giver,
						"done": lp.get("done", 0),
						"total": lp.get("total", 0),
						"current": lp.get("current_id", ""),
						"steps": steps
					}
				)
			return {"ok": true, "lines": lines}
		"grantkills":
			# Simulate n personal kills of an archetype: bumps kills_by_type + fires player_kill
			# (so kill quests advance + the director re-evaluates), exactly like real kills.
			var eid := str(json.get("eid", "robot_grunt"))
			var n := int(json.get("n", 1))
			for _i in range(maxi(0, n)):
				MetaProgression.record_kill_type(eid)
				Events.player_kill.emit(eid)
			MetaProgression.save_profile()
			return {"ok": true, "eid": eid, "kills": MetaProgression.kills_of(eid)}
		"stats":
			return {
				"ok": true,
				"kills_by_type": MetaProgression.kills_by_type,
				"extractions": MetaProgression.extractions_total,
				"quest_states": MetaProgression.quest_states
			}
		"grantrep":
			# QA: bump a giver's reputation to test tier unlocks + exclusive-contract offers.
			var giver := str(json.get("giver", ""))
			MetaProgression.grant_giver_rep(giver, int(json.get("n", 1)))
			if tree.root.has_node("QuestDirector"):
				tree.root.get_node("QuestDirector").evaluate_offers()
			return {
				"ok": true,
				"giver": giver,
				"rep": MetaProgression.giver_rep_of(giver),
				"tier": MetaProgression.giver_rep_tier(giver)
			}
		"sim":
			# QA: emit an objective event so non-kill quests advance without a full raid.
			var kind := str(json.get("kind", ""))
			var n := int(json.get("n", json.get("count", 1)))
			var sid2 := str(json.get("id", json.get("eid", "")))
			match kind:
				"extract":
					Events.raid_loot_granted.emit([], 0)
				"extract_item":
					Events.raid_loot_granted.emit([{"id": sid2, "count": n}], 0)
				"wave":
					Events.wave_cleared.emit(n)
				"pickup":
					Events.item_picked_up.emit(_authority_player(tree), sid2, n)
			return {"ok": true, "kind": kind}
		"reset":
			# QA: wipe quest lifecycle + decision stats + giver rep for a clean fixture.
			MetaProgression.quest_states = {}
			MetaProgression.quest_progress = {}
			MetaProgression.completed_quests.clear()
			MetaProgression.kills_by_type = {}
			MetaProgression.extractions_total = 0
			MetaProgression.giver_rep = {}
			MetaProgression.save_profile()
			if tree.root.has_node("QuestDirector"):
				tree.root.get_node("QuestDirector").evaluate_offers()
			return {"ok": true}
		"givers":
			var gv: Array = []
			var seen: Dictionary = {}
			for l in Quests.questlines():
				seen[(l as QuestLine).giver] = true
			for q in Quests.all():
				if (q as QuestData).giver != "":
					seen[(q as QuestData).giver] = true
			for g in seen:
				if String(g) == "":
					continue
				gv.append(
					{
						"giver": g,
						"rep": MetaProgression.giver_rep_of(g),
						"tier": MetaProgression.giver_rep_tier(g)
					}
				)
			return {"ok": true, "givers": gv}
		_:
			# "state": full board snapshot.
			var out: Array = []
			for q in Quests.all():
				var qd := q as QuestData
				(
					out
					. append(
						{
							"id": qd.id,
							"title": qd.title,
							"state": Quests.state_of(qd.id),
							"daily": qd.daily,
							"progress": Quests.progress(qd.id),
							"target": qd.obj_count,
							"obj_type": qd.obj_type,
							"obj_target": qd.obj_target,
							"questline": qd.questline,
							"offer_weight": qd.offer_weight,
							"unlocked": Quests.is_unlocked(qd),
							"hint": Quests.unlock_hint(qd),
						}
					)
				)
			return {"ok": true, "quests": out}


static func _authority_player(tree: SceneTree) -> Node:
	var players := tree.get_nodes_in_group(Groups.PLAYERS)
	for p in players:
		if p.is_multiplayer_authority():
			return p
	return players[0] if players.size() > 0 else null
