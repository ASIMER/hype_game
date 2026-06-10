extends Node
## The per-player raid economy across the network. Each peer self-configures its own
## player from its OWN local profile (MetaProgression loadout + bring-list) and its OWN
## Stash, so almost everything is local. The ONLY networked step is the extraction
## payout: the server (which authoritatively holds each player's found loot) grants the
## extracting peer its haul so that peer deposits it into its OWN local stash.
##
## Lifecycle:
##   DEPLOY  → deploy() commits the bring-list (removes those consumables from the LOCAL
##             stash — now at risk). The player then reads MetaProgression.get_bring()
##             at spawn for its starting _medkits/_grenades (see player.apply_loadout).
##   EXTRACT → server calls grant_extraction(peer, stacks, bonus); the owning peer
##             deposits stacks into its stash + earns the survival bonus.
##   DEATH   → nothing is deposited; the committed bring stays gone = lost.

## Attachment ids committed (pulled from the stash) for THIS raid — kept on extract,
## lost on death. Client-local; deposited back in _deposit().
var _committed_attachments: Array = []
## Worn-armor ids committed for THIS raid (batch B) — same at-risk economy as the
## attachments: pulled from the stash at deploy, returned on extract, lost on death
## (reconcile_gear then unequips the ghost next Hub open).
var _committed_gear: Array = []


## Called LOCALLY by each peer when it deploys (from the hub / single-player start).
## Pulls the brought consumables + equipped attachments out of this machine's stash so
## death actually loses them. Clamps to what the stash holds.
func deploy() -> void:
	var bring: Dictionary = MetaProgression.get_bring()
	var committed: Dictionary = {}
	for id in bring:
		var want := int(bring[id])
		if want <= 0:
			continue
		var took := Stash.remove(String(id), want)
		if took > 0:
			committed[String(id)] = took
	MetaProgression.set_bring(committed)
	# Commit the at-risk attachments of the loadout weapons (remove from the stash).
	_committed_attachments.clear()
	for wid in MetaProgression.get_loadout():
		var slots: Dictionary = MetaProgression.get_equipped(String(wid))
		for s in slots:
			var aid := String(slots[s])
			if Stash.remove(aid, 1) > 0:
				_committed_attachments.append(aid)
			else:
				# Not actually owned — unequip so it can't apply for free.
				MetaProgression.unequip_attachment(String(wid), String(s))
	# Commit the worn gear (batch B; guarded until the gear profile API lands).
	_committed_gear.clear()
	if MetaProgression.has_method("get_equipped_gear"):
		var gear: Dictionary = MetaProgression.get_equipped_gear()
		for slot in gear:
			var gid := String(gear[slot])
			if gid == "":
				continue
			if Stash.remove(gid, 1) > 0:
				_committed_gear.append(gid)
			else:
				# Not actually owned — unequip so it can't protect for free.
				MetaProgression.set_equipped_gear(String(slot), "")


# ---------------------------------------------------------------- extraction payout
## SERVER-side: hand `stacks` (found loot + surviving consumables, as {id,count} or
## {item,count}) plus a currency `bonus` to the peer that extracted, so IT deposits to
## its own stash. Host/offline deposits directly; a remote client gets it via RPC.
func grant_extraction(peer_id: int, stacks: Array, bonus: int) -> void:
	var payload: Array = []
	for s in stacks:
		var id := ""
		if s.has("id"):
			id = String(s["id"])
		elif s.has("item") and s["item"] != null:
			id = String((s["item"] as ItemData).id)
		var n := int(s.get("count", 0))
		if id != "" and n > 0:
			payload.append({"id": id, "count": n})
	if (
		NetworkManager.is_offline
		or not multiplayer.has_multiplayer_peer()
		or peer_id == multiplayer.get_unique_id()
	):
		_deposit(payload, bonus)
	else:
		_grant_loot.rpc_id(peer_id, payload, bonus)


@rpc("authority", "call_remote", "reliable")
func _grant_loot(payload: Array, bonus: int) -> void:
	_deposit(payload, bonus)


## Deposit the haul into THIS machine's stash + profile (runs on the owning peer).
func _deposit(payload: Array, bonus: int) -> void:
	# Scavenger skill (Batch 3): scale the currency reward by the local profile's loot_mult.
	var loot_mult: float = float(MetaProgression.player_mods().get("loot_mult", 1.0))
	bonus = int(round(bonus * loot_mult))
	# Surviving at-risk attachments come back out with you (kept on extract).
	for aid in _committed_attachments:
		payload.append({"id": aid, "count": 1})
	_committed_attachments.clear()
	# Surviving worn gear too (batch B — stays equipped, returns to the stash).
	for gid in _committed_gear:
		payload.append({"id": gid, "count": 1})
	_committed_gear.clear()
	# Survived → the insurance coverage on the equipped items is simply spent.
	if MetaProgression.has_method("clear_insurance_on_extract"):
		MetaProgression.clear_insurance_on_extract()
	Stash.add_stacks(payload)
	# Extracting a schematic item permanently learns its recipe's blueprint.
	var learn := Crafting.learn_items()  # learn_item id -> blueprint id
	for e in payload:
		var iid := String(e["id"])
		if learn.has(iid):
			MetaProgression.learn_blueprint(String(learn[iid]))
	var loot_value := 0
	for e in payload:
		loot_value += ItemCatalog.value_of(e["id"]) * int(e["count"])
	if bonus > 0:
		MetaProgression.earn(bonus)
	GameState.last_run_reward = bonus
	Events.raid_loot_granted.emit(payload, bonus)
	Events.run_rewards.emit(bonus, {"loot": loot_value, "survival": bonus, "items": payload.size()})
	# Stash over capacity → the Manage-Your-Haul beat (player trims it down).
	var over := Stash.total_weight() - Stash.capacity()
	if over > 0.0:
		Events.haul_overflow.emit(payload, over)


# ---------------------------------------------------------------- secure pouch (batch B)
## SERVER-side: a player DIED but its secured pouch items survive. Routed exactly like
## grant_extraction (the OWNING peer deposits into its own stash) but raw: no survival
## bonus, no committed-gear/attachment return, no blueprint learning — death still eats
## everything that wasn't in the pouch.
func grant_secure(peer_id: int, stacks: Array) -> void:
	var payload: Array = []
	for s in stacks:
		var id := String(s.get("id", ""))
		var n := int(s.get("count", 0))
		if id != "" and n > 0:
			payload.append({"id": id, "count": n})
	if payload.is_empty():
		return
	if (
		NetworkManager.is_offline
		or not multiplayer.has_multiplayer_peer()
		or peer_id == multiplayer.get_unique_id()
	):
		_deposit_secure(payload)
	else:
		_grant_secure_loot.rpc_id(peer_id, payload)


@rpc("authority", "call_remote", "reliable")
func _grant_secure_loot(payload: Array) -> void:
	_deposit_secure(payload)


## Owner-side: secured items land in the stash raw. Overflow still triggers the
## Manage-Your-Haul beat (the pouch can push a near-full stash over).
func _deposit_secure(payload: Array) -> void:
	Stash.add_stacks(payload)
	Events.secure_returned.emit(payload)
	Events.notify.emit(tr("Secured items recovered"), 1)
	var over := Stash.total_weight() - Stash.capacity()
	if over > 0.0:
		Events.haul_overflow.emit(payload, over)
