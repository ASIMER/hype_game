extends Area3D
class_name ExtractionZone
## Server-authoritative extraction point. While a player (group "players") stays
## inside the zone, a per-player timer fills toward Settings.EXTRACTION_TIME; on
## completion the peer is marked extracted and, once every peer is resolved
## (dead or extracted), the match is won. Leaving the zone cancels and resets that
## player's progress.
##
## Attach to the Arena's ExtractionZone Area3D (collision layer extraction=16,
## mask player=2). Only the local authority server advances timers; progress is
## broadcast over Events so the HUD can render it. Clients simply listen.

# player node -> elapsed seconds inside the zone
var _timers: Dictionary = {}
# players that have already finished extracting (avoid double-completion)
var _completed: Dictionary = {}
var _is_server: bool = false

# --- Procedural beacon (visual only; built in _ready, animated in _process) ---
# A bright emissive core + a tall additive light pillar + an OmniLight3D for local
# glow + a couple of expanding/fading rings, so the zone reads as a landmark from
# across the 160x160 map. Tinted by open/closed state. Skipped on a headless server.
var _beacon: Node3D = null
var _beacon_core: MeshInstance3D = null
var _beacon_pillar: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _beacon_rings: Array[MeshInstance3D] = []
var _beacon_spin_ring: MeshInstance3D = null  # slowly-rotating glowing ground ring
var _beacon_decal: Decal = null  # soft radial ground glow (recoloured on flip)
var _beacon_mats: Array[StandardMaterial3D] = []  # all tinted mats (recolour on flip)
var _beacon_time: float = 0.0
var _beacon_pulse_base: float = 1.0  # 1.0 open / dimmer when closed
# PERF gate: animate the beacon only when the camera is near (2 Hz distance check).
var _beacon_gate_accum: float = 1.0  # start past the threshold → first frame evaluates
var _beacon_anim_on: bool = true
const _OPEN_TINT := Color(0.25, 1.0, 0.6)  # green/teal
const _CLOSED_TINT := Color(0.95, 0.6, 0.15)  # dim amber

# --- Timed open/close window (driven server-auth by ExtractionDirector) ---
# Zones rotate between OPEN (extraction works) and CLOSED (fill is paused/ignored).
# Defaults to OPEN so the zone is usable even before a director attaches and on
# pure clients (which mirror state via Events.extraction_window_changed).
var _open: bool = true
var _window_remaining: float = 0.0

# --- Typed extraction zones (batch C) ---------------------------------------------
# Some zones are SPECIAL (resolved from this node's OWN name via
# Settings.EXTRACTION_ZONE_TYPES — zero Arena.tscn edits):
#   "paid"   — stays closed; a player pays Settings.PAID_EXTRACT_COST to call evac.
#   "signal" — stays closed; a player burns a Signal Flare to call evac, which also
#              rings the dinner bell (noise + a guaranteed reinforcement wave).
#   ""       — the classic rotating-window zone (all behavior below is inert).
# A typed zone is EXEMPT from the director's rotation (rotation_exempt) and is opened
# only by a force_open countdown (override_active) — except the final storm, which
# forces every zone open via set_window(true, 0) and we honor that.
var zone_type: String = ""
# Server-side force-open countdown (seconds the bought/flared window stays open).
var _override_left: float = 0.0
# Local-player interaction state (runs on the HOLDER's own peer — input is local).
# The purchase/flare gesture is a sustained hold of "interact" while inside the zone.
var _local_inside: Node = null  # this peer's own player standing in the zone (or null)
var _hold_elapsed_interact: float = 0.0  # seconds the local player has held "interact"
var _last_typed_prompt: String = ""  # de-dupe Events.interaction_available spam
var _request_cooldown: float = 0.0  # suppress hold re-fire during the server round-trip
const _TYPED_HOLD_TIME: float = 1.6  # seconds to hold "interact" to buy/flare
# Beacon idle/closed identity hues per type (open still reads green for ALL types —
# we only retint the CLOSED/idle colour so the map/world read "this one is special").
const _PAID_TINT := Color(0.95, 0.78, 0.18)  # gold/amber — "costs credits"
const _SIGNAL_TINT := Color(0.7, 0.4, 1.0)  # violet — "needs a flare"


## True while this zone accepts extraction progress.
func is_open() -> bool:
	return _open


## Seconds left in the current open/closed window (informational; the director owns
## the authoritative countdown). 0 if unknown.
func window_remaining() -> float:
	return _window_remaining


## Server-auth: flip the open/closed state. Closing resets every in-progress fill
## (players must re-start when it reopens). Re-emits the window state for UIs.
## Single-player counts as server, so this drives offline play too.
func set_window(open: bool, remaining: float) -> void:
	_window_remaining = maxf(remaining, 0.0)
	if open == _open:
		# Same state — just refresh the countdown for listeners.
		Events.extraction_window_changed.emit(self, _open, _window_remaining)
		return
	_open = open
	_apply_beacon_tint()  # recolour the landmark beacon on a state flip (visual only)
	if not _open:
		# Closing: cancel anyone mid-extraction so they don't silently bank progress.
		for body in _timers.keys():
			if not _completed.has(body) and is_instance_valid(body):
				Events.extraction_cancelled.emit(body)
		_timers.clear()
	elif _is_server:
		# Reopening: pick up anyone already standing inside (body_entered won't re-fire).
		for body in get_overlapping_bodies():
			_on_body_entered(body)
	Events.extraction_window_changed.emit(self, _open, _window_remaining)


# ============================================================ TYPED-ZONE PUBLIC API
# Duck-typed by ExtractionDirector: it skips rotating any zone whose rotation_exempt()
# or override_active() is true, so a paid/signal zone never auto-opens/closes — only a
# force_open countdown (or the storm's blanket set_window) controls it.


## A typed zone opts OUT of the director's timed open/close rotation entirely.
func rotation_exempt() -> bool:
	return zone_type != ""


## True while a paid/signal force-open window is actively counting down (the director
## leaves the zone alone while this holds).
func override_active() -> bool:
	return _override_left > 0.0


## SERVER-auth: open this zone for `seconds` (a paid charge / signal flare). Starts the
## override countdown (ticked down in _physics_process) and announces it so HUDs/audio
## react. When it expires we re-close (unless the storm has since forced everything open).
func force_open(seconds: float) -> void:
	if not _is_server:
		return
	_override_left = maxf(seconds, 0.0)
	_apply_window_all(true, _override_left)
	Events.extraction_force_opened.emit(self, _override_left)


## Drive the window on EVERY peer: locally (server) plus a mirror RPC to the clients, so a
## paid/signal zone's beacon flips green + its map countdown updates on every machine (the
## director's rotation is server-only and doesn't touch typed zones). set_window is
## idempotent on same-state, so this is safe to call alongside any other window source.
func _apply_window_all(open: bool, remaining: float) -> void:
	set_window(open, remaining)
	if multiplayer.has_multiplayer_peer():
		_mirror_window.rpc(open, remaining)


## CLIENT-side window mirror (server → clients). Runs set_window locally so the open/closed
## beacon tint + the map/minimap countdown track the bought/flared window on every peer.
@rpc("authority", "call_remote", "reliable")
func _mirror_window(open: bool, remaining: float) -> void:
	set_window(open, remaining)


func _ready() -> void:
	add_to_group(Groups.EXTRACTION)  # so the minimap/compass can mark zones
	# Resolve our type from our OWN node name (paid / signal / classic) BEFORE building
	# the beacon so it picks the right idle hue, and so we can start typed zones closed.
	zone_type = String(Settings.EXTRACTION_ZONE_TYPES.get(String(name), ""))
	if zone_type != "":
		# Typed zones are NOT usable until paid-for / flared — start closed.
		_open = false
		_window_remaining = 0.0
	# Visual beacon (clients build it too so the landmark shows on every machine).
	_build_beacon()
	_is_server = GameState.is_local_authority_server()
	if _is_server:
		body_entered.connect(_on_body_entered)
		body_exited.connect(_on_body_exited)
		# Pick up any players already overlapping when we attach.
		for body in get_overlapping_bodies():
			_on_body_entered(body)
		return
	# --- Pure client ---
	if zone_type == "":
		# Classic zone: visual-only on a client (window mirrors via Events). No physics.
		set_physics_process(false)
		return
	# Typed zone on a client: the purchase/flare interaction is a LOCAL-player action
	# (input is local), so the client DOES track its own player + run the hold poll in
	# _physics_process — but it never advances the server-auth extraction fill.
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	for body in get_overlapping_bodies():
		_on_body_entered(body)


func _on_body_entered(body: Node) -> void:
	if not _is_player(body):
		return
	# Typed-zone local interaction: remember THIS peer's own player standing inside so the
	# purchase/flare hold poll (in _physics_process) has a subject. Runs on every peer
	# (the holder's input is local), BEFORE the _open gate (typed zones start closed).
	if zone_type != "" and _is_local_player(body):
		_local_inside = body
		_refresh_typed_prompt()
	# Only the server advances the extraction fill (clients of a typed zone fall through).
	if not _is_server:
		return
	if _completed.has(body):
		return
	if _timers.has(body):
		return
	# Closed zone: no fill accrues while standing inside (re-entry on reopen handled
	# by _physics_process, which only fills overlapping bodies once _open is true).
	if not _open:
		return
	_timers[body] = 0.0
	Events.extraction_started.emit(body, self)
	Events.extraction_progress.emit(body, 0.0)


func _on_body_exited(body: Node) -> void:
	# Typed-zone local interaction: our player left → drop the hold + clear its prompt.
	if body == _local_inside:
		_local_inside = null
		_hold_elapsed_interact = 0.0
		_request_cooldown = 0.0
		if _last_typed_prompt != "":
			_last_typed_prompt = ""
			Events.interaction_cleared.emit()
	if not _timers.has(body):
		return
	_timers.erase(body)
	# Don't fire a spurious cancel for a player who already finished.
	if not _completed.has(body):
		Events.extraction_cancelled.emit(body)


func _physics_process(delta: float) -> void:
	# (A) Server: tick the paid/signal force-open window down; re-close when it lapses.
	# During the storm every zone is force-open (set_window from the director) so the
	# override is moot — drop it and let the storm own the window, never fighting it.
	if _is_server and _override_left > 0.0:
		if _storm_active():
			_override_left = 0.0
		else:
			_override_left = maxf(_override_left - delta, 0.0)
			_window_remaining = _override_left
			if _override_left <= 0.0:
				_apply_window_all(false, 0.0)
	# (B) Local typed-zone interaction (paid charge / signal flare hold) — the holder's
	# own peer drives this; input is local. No-op for classic zones / when no local player.
	if zone_type != "":
		_update_typed_interaction(delta)
	# (C) Server-auth extraction fill (unchanged) — clients never reach here.
	if not _is_server:
		return
	# Closed window: no progress accrues (timers are cleared on close, but guard so a
	# late body_entered race can't sneak in a fill).
	if not _open:
		return
	if _timers.is_empty():
		return
	# Iterate a copy so completion can erase from _timers mid-loop.
	for body in _timers.keys():
		if not is_instance_valid(body):
			_timers.erase(body)
			continue
		var elapsed: float = _timers[body] + delta
		var ratio: float = clampf(elapsed / maxf(Settings.EXTRACTION_TIME, 0.001), 0.0, 1.0)
		_timers[body] = elapsed
		Events.extraction_progress.emit(body, ratio)
		if ratio >= 1.0:
			_complete(body)


func _complete(body: Node) -> void:
	_timers.erase(body)
	_completed[body] = true
	# A DOWNED player can crawl into an OPEN evac and self-extract — clear their downed
	# state first so the bleedout timer can't true-kill them as they extract.
	if (
		body.has_method("is_downed")
		and body.is_downed()
		and body.has_method("cancel_downed_for_extract")
	):
		body.cancel_downed_for_extract()
	Events.extraction_completed.emit(body)
	_mark_extracted(body)
	_grant_extraction(body)
	if GameState.all_players_resolved():
		NetworkManager.broadcast_match_won()


## Server-authoritative payout: the extracting player KEEPS its haul. We build the
## deposit from the found-loot Inventory (server-side authoritative) + the surviving
## brought consumables (replicated), then hand it to RaidManager, which deposits it into
## THAT peer's own stash (locally for the host, via RPC for a remote client) plus a
## wave-scaled survival-bonus currency. Death deposits nothing — gear is lost.
func _grant_extraction(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	var stacks: Array = []
	var inv: Node = body.get_node_or_null("Inventory")
	if inv and "stacks" in inv:
		for s in inv.stacks:
			var it: ItemData = s.get("item", null)
			if it != null:
				stacks.append({"id": it.id, "count": int(s.get("count", 0))})
	if body.has_method("extracted_consumables"):
		stacks.append_array(body.extracted_consumables())
	var survival_bonus := 50 + GameState.current_wave * 25
	RaidManager.grant_extraction(peer_id, stacks, survival_bonus)


## Resolve the player node to a peer id and flag it extracted in GameState.
func _mark_extracted(body: Node) -> void:
	var peer_id := _peer_id_for(body)
	if peer_id != 0 and GameState.peers.has(peer_id):
		GameState.peers[peer_id]["extracted"] = true


func _peer_id_for(body: Node) -> int:
	# Player nodes are named after their peer id (see arena.gd _spawn_player).
	if body.name.is_valid_int():
		return body.name.to_int()
	if body.has_method("get_multiplayer_authority"):
		return body.get_multiplayer_authority()
	return 0


func _is_player(body: Node) -> bool:
	return body != null and body.is_in_group(Groups.PLAYERS)


# ============================================================ TYPED-ZONE INTERACTION
# A paid/signal zone is opened by a deliberate HOLD of "interact" while standing inside
# it. The hold channel runs on the INTERACTING player's own peer (only that peer can read
# its interact button — exactly the discipline of the revive channel + locked_door.gd).
# On completion it fires a request the SERVER validates: PAID charges the holder's own
# MetaProgression profile (currency is per-peer-local, so the spend MUST happen on the
# owner — the task's 3-leg _charge_request/_charge_confirm handshake), while SIGNAL
# consumes the holder's replicated `_flares` on the SERVER's copy (mirrors locked_door's
# key consume) then force-opens + rings the dinner bell (noise + a reinforcement wave).


## Per-frame hold channel for the local player standing in a typed zone. No-op for the
## classic zone, when no local player is inside, while the zone is already open, or during
## the storm (then the server-side proximity fill drives extraction like any open zone).
func _update_typed_interaction(delta: float) -> void:
	if _request_cooldown > 0.0:
		_request_cooldown = maxf(0.0, _request_cooldown - delta)
	var p: Node = _local_inside
	# Drop the channel if our player left, went down, or stopped being ours.
	if p == null or not is_instance_valid(p) or not _is_local_player(p):
		_local_inside = null
		_reset_typed_hold()
		return
	# Already open (force-opened) or storm: extraction proceeds via the proximity fill —
	# no buy/flare prompt. Clear any in-progress hold + its prompt.
	if _open or _storm_active():
		_reset_typed_hold()
		return
	_refresh_typed_prompt()
	# Hold gate (cooldown suppresses re-fire during the server round-trip).
	if _request_cooldown > 0.0:
		return
	if not _player_holds_interact(p):
		_hold_elapsed_interact = 0.0
		return
	_hold_elapsed_interact = minf(_hold_elapsed_interact + delta, _TYPED_HOLD_TIME)
	if _hold_elapsed_interact >= _TYPED_HOLD_TIME:
		_hold_elapsed_interact = 0.0
		_request_cooldown = 1.0  # suppress re-fire until the server answers
		if zone_type == "paid":
			_paid_hold_done()
		elif zone_type == "signal":
			_signal_hold_done()


## Show the contextual prompt for the local player (de-duped so an unchanged string isn't
## re-emitted every frame). The hold % is folded into the text as live progress feedback.
func _refresh_typed_prompt() -> void:
	if _local_inside == null or not is_instance_valid(_local_inside):
		return
	if _open or _storm_active():
		return
	var prompt: String = ""
	var holding: bool = _hold_elapsed_interact > 0.0
	var pct: int = int(round(clampf(_hold_elapsed_interact / _TYPED_HOLD_TIME, 0.0, 1.0) * 100.0))
	if zone_type == "paid":
		if holding:
			prompt = tr("Calling extraction… %d%%") % pct
		else:
			prompt = tr("Pay %d cr to call extraction [hold E]") % Settings.PAID_EXTRACT_COST
	elif zone_type == "signal":
		if _flares_of(_local_inside) <= 0:
			prompt = tr("Requires a Signal Flare")
		elif holding:
			prompt = tr("Firing signal flare… %d%%") % pct
		else:
			prompt = tr("Fire signal flare [hold E]")
	if prompt != "" and prompt != _last_typed_prompt:
		_last_typed_prompt = prompt
		Events.interaction_available.emit(prompt, self)


## Clear the in-progress hold + its on-screen prompt (no longer interacting).
func _reset_typed_hold() -> void:
	_hold_elapsed_interact = 0.0
	if _last_typed_prompt != "":
		_last_typed_prompt = ""
		Events.interaction_cleared.emit()


# ─── PAID: charge the holder's own profile (currency is per-peer-local) ───────────


## Holder finished the buy-hold. The host owns its own profile → spend + open directly; a
## client asks the server to start the charge handshake (server can't touch a client's
## currency, which lives in that client's MetaProgression autoload).
func _paid_hold_done() -> void:
	if _is_server:
		if _owner_charge(Settings.PAID_EXTRACT_COST):
			force_open(Settings.PAID_EXTRACT_WINDOW)
	else:
		_paid_request.rpc_id(1)


## SERVER: a client wants to pay-extract here. Validate it is standing in the zone, then
## ask THAT client (the owner of the currency) to charge itself.
@rpc("any_peer", "call_remote", "reliable")
func _paid_request() -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _peer_inside(sender):
		return
	_charge_request.rpc_id(sender, Settings.PAID_EXTRACT_COST)


## OWNER (a client): the server asked us to pay. Spend from our local profile and report
## the result back so the SERVER can force the window open (only it owns world state).
@rpc("authority", "call_remote", "reliable")
func _charge_request(cost: int) -> void:
	_charge_confirm.rpc_id(1, _owner_charge(cost))


## SERVER: the owner reports its charge result. On success, force the window open. We do
## NOT re-check proximity here — _paid_request already gated entry on being inside, and the
## owner has now SPENT, so the bought window is owed even if it stepped out mid-handshake.
@rpc("any_peer", "call_remote", "reliable")
func _charge_confirm(ok: bool) -> void:
	if not multiplayer.is_server():
		return
	if not ok:
		return
	force_open(Settings.PAID_EXTRACT_WINDOW)


## Spend the paid-extract cost from THIS peer's own MetaProgression (host or client owner).
## Notifies locally either way; persists the deduction on success. Returns the spend result.
func _owner_charge(cost: int) -> bool:
	if not MetaProgression.spend(cost):
		Events.notify.emit(tr("Not enough credits"), 2)
		return false
	MetaProgression.save_profile()
	Events.notify.emit(tr("Extraction called"), 1)
	return true


# ─── SIGNAL: consume the holder's replicated flare on the SERVER (dinner bell) ────


## Holder finished the flare-hold. Single-player counts as server; a client routes the
## request so the SERVER consumes the flare + rings the bell (mirrors locked_door's key).
func _signal_hold_done() -> void:
	if _is_server:
		_server_try_signal(_local_peer_id())
	else:
		_signal_request.rpc_id(1, multiplayer.get_unique_id())


## SERVER entry: a peer asks to fire a flare here.
@rpc("any_peer", "call_local", "reliable")
func _signal_request(requester_peer: int) -> void:
	if not multiplayer.is_server():
		return
	_server_try_signal(requester_peer)


## SERVER: validate the requester holds a flare, consume it on the server's copy of that
## player (replicates back to the owner), then force-open + report the noise + summon the
## guaranteed reinforcement wave. Refuses with a "needs flare" flash if they have none.
func _server_try_signal(requester_peer: int) -> void:
	if _open or _storm_active():
		return
	var p: Node = _player_for_peer(requester_peer)
	if p == null:
		return
	if _flares_of(p) <= 0:
		if requester_peer == _local_peer_id():
			_flash_needs_flare()
		elif requester_peer > 0:
			_needs_flare_rpc.rpc_id(requester_peer)
		return
	# Consume on the OWNER, not here: `_flares` replicates authority→peers (the
	# player's peer owns it), so a server-side decrement would be overwritten by the
	# owner's next sync tick — same discipline as grenade/medkit counts (and the
	# locked-door key consume). The server has already validated ≥1.
	if requester_peer == _local_peer_id():
		_consume_flare_local(p)
	else:
		_consume_flare_rpc.rpc_id(requester_peer)
	force_open(Settings.SIGNAL_EXTRACT_WINDOW)
	NetworkManager.report_noise(global_position, Settings.SIGNAL_FLARE_NOISE, 2)
	AIDirector.request_reinforcements(Settings.SIGNAL_REINFORCEMENTS, global_position)


## OWNER-side: decrement our replicated flare count (authority-owned property).
@rpc("authority", "call_remote", "reliable")
func _consume_flare_rpc() -> void:
	_consume_flare_local(_player_for_peer(_local_peer_id()))


func _consume_flare_local(p: Node) -> void:
	if p == null or not ("_flares" in p):
		return
	p.set("_flares", maxi(0, _flares_of(p) - 1))


## Tell a remote requester it lacks a flare (server → that peer).
@rpc("authority", "call_remote", "reliable")
func _needs_flare_rpc() -> void:
	_flash_needs_flare()


## Surface the "requires a Signal Flare" message locally (the requester's HUD).
func _flash_needs_flare() -> void:
	Events.notify.emit(tr("Requires a Signal Flare"), 2)


# ─── typed-zone helpers ───────────────────────────────────────────────────────


## True if `body` is THIS peer's own, non-downed player (only it can read its interact
## button + spend its profile — exactly the locked_door / revive discipline).
func _is_local_player(body: Node) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if body.has_method("is_downed") and body.is_downed():
		return false
	if not multiplayer.has_multiplayer_peer():
		return true  # single-player: the lone local player
	return body.get_multiplayer_authority() == multiplayer.get_unique_id()


## Read the player's HELD interact via the same hook the revive/carry channels use.
func _player_holds_interact(p: Node) -> bool:
	if p != null and p.has_method("_act_held"):
		return bool(p.call("_act_held", "interact"))
	return false


## The replicated flare count on a player node (0 if unavailable).
func _flares_of(p: Node) -> int:
	if p != null and is_instance_valid(p) and "_flares" in p:
		return int(p.get("_flares"))
	return 0


## True while the final storm is forcing every zone open.
func _storm_active() -> bool:
	return GameState.final_wave


## True if a player owned by `peer_id` is currently standing in this zone.
func _peer_inside(peer_id: int) -> bool:
	for b in get_overlapping_bodies():
		if _is_player(b) and _peer_id_for(b) == peer_id:
			return true
	return false


## Resolve a peer id to its player node (named after the peer id, per arena._spawn_player).
func _player_for_peer(peer_id: int) -> Node:
	if get_tree() == null:
		return null
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if str(p.name).is_valid_int() and str(p.name).to_int() == peer_id:
			return p
	return null


func _local_peer_id() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 1


## The CLOSED/idle beacon hue, tinted by zone type so the map/world read which evac is
## special: paid → gold, signal → violet, classic → the usual dim amber. (Open always
## reads green for every type — only the closed identity colour changes.)
func _closed_tint() -> Color:
	match zone_type:
		"paid":
			return _PAID_TINT
		"signal":
			return _SIGNAL_TINT
		_:
			return _CLOSED_TINT


# ============================================================ PROCEDURAL BEACON
# Visual landmark only — none of this touches the server-auth window/progress logic.


## Build the beacon assembly under the zone: hide the old translucent box, add a
## glowing core, a tall additive light pillar, an OmniLight3D, and animated rings.
## Cheap on headless (skips meshes/lights — pure server keeps zero visual cost).
func _build_beacon() -> void:
	# Hide BOTH placeholder boxes from Arena.tscn: the styled translucent "Beacon" AND the
	# plain unlit "Mesh" — the latter renders as a DEFAULT GREY CUBE (no material override) and
	# was the "ugly grey box" obscuring this beacon. Hiding it in code covers all 12 zones.
	for placeholder in ["Beacon", "Mesh"]:
		var old: Node = get_node_or_null(placeholder)
		if old is MeshInstance3D:
			(old as MeshInstance3D).visible = false

	if DisplayServer.get_name() == "headless":
		# Dedicated server: no visuals needed, and no _process animation.
		set_process(false)
		return

	_beacon = Node3D.new()
	_beacon.name = "ProcBeacon"
	add_child(_beacon)
	var tint := _OPEN_TINT if _open else _closed_tint()

	# Glowing core — a small bright sphere just above the ground.
	var core_mat := _emis(tint, 6.0)
	_beacon_core = MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.6
	core_mesh.height = 1.2
	core_mesh.radial_segments = 16
	core_mesh.rings = 8
	_beacon_core.mesh = core_mesh
	_beacon_core.material_override = core_mat
	_beacon_core.position = Vector3(0, 1.2, 0)
	_beacon.add_child(_beacon_core)

	# A short emissive plinth ring at the base so the footprint glows too.
	var base_ring := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.6
	base_mesh.bottom_radius = 2.8
	base_mesh.height = 0.2
	base_mesh.radial_segments = 24
	base_ring.mesh = base_mesh
	base_ring.material_override = _emis(tint, 3.0)
	base_ring.position = Vector3(0, 0.1, 0)
	_beacon.add_child(base_ring)

	# Tall additive light pillar — the see-it-from-across-the-map shaft.
	_beacon_pillar = MeshInstance3D.new()
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.35
	pillar_mesh.bottom_radius = 1.1
	pillar_mesh.height = 16.0
	pillar_mesh.radial_segments = 16
	_beacon_pillar.mesh = pillar_mesh
	_beacon_pillar.material_override = _additive(tint, 1.6)
	_beacon_pillar.position = Vector3(0, 8.0, 0)
	_beacon.add_child(_beacon_pillar)

	# Local glow light.
	_beacon_light = OmniLight3D.new()
	_beacon_light.light_color = tint
	_beacon_light.light_energy = 4.0
	_beacon_light.omni_range = 14.0
	_beacon_light.position = Vector3(0, 1.5, 0)
	_beacon.add_child(_beacon_light)

	# A couple of expanding/fading rings (flat thin cylinders) animated in _process.
	for i in range(2):
		var ring := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = 1.0
		rm.bottom_radius = 1.0
		rm.height = 0.06
		rm.radial_segments = 28
		ring.mesh = rm
		ring.material_override = _additive(tint, 2.0)
		ring.position = Vector3(0, 0.3, 0)
		_beacon.add_child(ring)
		_beacon_rings.append(ring)

	# ── "Divine light" upgrade ───────────────────────────────────────────────────
	# A wide god-ray CONE beaming DOWN from the sky onto the zone (wide at the top, narrowing
	# to the ground) — additive + soft so it reads as a shaft of light from above, not solid.
	var beam := MeshInstance3D.new()
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 6.0
	beam_mesh.bottom_radius = 1.3
	beam_mesh.height = 22.0
	beam_mesh.radial_segments = 24
	beam.mesh = beam_mesh
	beam.material_override = _additive(tint, 0.6)  # softer than the central pillar
	beam.position = Vector3(0, 11.0, 0)
	_beacon.add_child(beam)

	# A flat glowing RING flush on the ground that slowly SPINS — the "крутящийся круг".
	_beacon_spin_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 2.4
	torus.outer_radius = 3.0
	torus.rings = 32
	torus.ring_segments = 10
	_beacon_spin_ring.mesh = torus
	_beacon_spin_ring.material_override = _additive(tint, 2.8)
	_beacon_spin_ring.position = Vector3(0, 0.12, 0)
	_beacon.add_child(_beacon_spin_ring)

	# A soft radial ground glow so the circle reads on the terrain (reuses the climate-zone
	# radial mask). Pure emissive — modulate carries the green/amber tint, recoloured on flip.
	_beacon_decal = Decal.new()
	_beacon_decal.size = Vector3(9.0, 6.0, 9.0)
	var glow_tex: Texture2D = ProceduralClimateZones._radial_texture()
	_beacon_decal.texture_albedo = glow_tex
	_beacon_decal.texture_emission = glow_tex
	_beacon_decal.emission_energy = 1.8
	_beacon_decal.albedo_mix = 0.25
	_beacon_decal.modulate = tint
	_beacon_decal.upper_fade = 0.4
	_beacon_decal.lower_fade = 0.4
	_beacon_decal.position = Vector3(0, 1.0, 0)
	_beacon.add_child(_beacon_decal)

	_apply_beacon_tint()
	set_process(true)


## Emissive solid material (registered for recolour on state flip).
func _emis(tint: Color, energy: float) -> StandardMaterial3D:
	var m := ProcMaterials.emissive(tint, energy, tint * 0.4)
	_beacon_mats.append(m)
	return m


## Additive, transparent, unshaded material for the pillar/rings (so they read as
## light, not solid geometry). Registered for recolour on state flip.
func _additive(tint: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(tint.r, tint.g, tint.b, 0.35)
	m.emission_enabled = true
	m.emission = tint
	m.emission_energy_multiplier = energy
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beacon_mats.append(m)
	return m


## Recolour every beacon material + the light to match the current open/closed state.
func _apply_beacon_tint() -> void:
	if _beacon == null:
		return
	var tint := _OPEN_TINT if _open else _closed_tint()
	var energy_mul := 1.0 if _open else 0.55  # dim when closed
	for m in _beacon_mats:
		m.emission = tint
		# Preserve each material's relative alpha while restating the hue.
		var a: float = m.albedo_color.a
		m.albedo_color = Color(tint.r, tint.g, tint.b, a) if a < 1.0 else tint * 0.4
	if _beacon_light != null:
		_beacon_light.light_color = tint
		_beacon_light.light_energy = (5.0 if _open else 2.0)
	# A bigger, brighter pillar when open.
	if _beacon_pillar != null:
		_beacon_pillar.scale = Vector3(1.0, 1.0, 1.0) if _open else Vector3(0.7, 0.7, 0.7)
	# The ground glow decal carries its tint via modulate (not in _beacon_mats).
	if _beacon_decal != null:
		_beacon_decal.modulate = tint
	_beacon_pulse_base = energy_mul


## Animate the beacon: a gentle core pulse + expanding/fading rings + a slow pillar
## shimmer. Cheap; disabled entirely on headless (set_process(false) in _build).
## PERF: 12 zones × ~6 material + ~4 transform writes per frame add up — animate only
## when the camera is within ~130m (checked at 2 Hz). _beacon_time deliberately does
## NOT advance while gated, so the phase freezes and resumes without a pop; beyond
## 130m the ±shimmer is sub-pixel anyway (the pillar/beam stay lit from afar).
func _process(delta: float) -> void:
	if _beacon == null:
		return
	_beacon_gate_accum += delta
	if _beacon_gate_accum >= 0.5:
		_beacon_gate_accum = 0.0
		var cam := get_viewport().get_camera_3d()
		_beacon_anim_on = (
			cam != null and cam.global_position.distance_squared_to(global_position) < 130.0 * 130.0
		)
	if not _beacon_anim_on:
		return
	_beacon_time += delta
	# Core pulse (brightness breathes).
	if _beacon_core != null:
		var pulse := 1.0 + 0.35 * sin(_beacon_time * 3.0)
		var cm := _beacon_core.material_override as StandardMaterial3D
		if cm != null:
			cm.emission_energy_multiplier = (6.0 * _beacon_pulse_base) * pulse
		_beacon_core.scale = Vector3.ONE * (1.0 + 0.06 * sin(_beacon_time * 3.0))
	# Slowly spin the glowing ground ring (the "spinning glowing circle").
	if _beacon_spin_ring != null:
		_beacon_spin_ring.rotation.y += delta * 0.6
	# Pillar subtle vertical shimmer.
	if _beacon_pillar != null:
		var pm := _beacon_pillar.material_override as StandardMaterial3D
		if pm != null:
			pm.emission_energy_multiplier = (
				(1.6 * _beacon_pulse_base) * (1.0 + 0.2 * sin(_beacon_time * 1.5))
			)
	# Expanding/fading rings — each ring grows from ~1 to ~4.5 then resets, fading out.
	var n := _beacon_rings.size()
	for i in range(n):
		var ring := _beacon_rings[i]
		if ring == null:
			continue
		var phase: float = fmod(_beacon_time * 0.5 + float(i) / float(maxi(n, 1)), 1.0)
		var radius := 1.0 + phase * 3.5
		ring.scale = Vector3(radius, 1.0, radius)
		ring.position.y = 0.3 + phase * 1.2
		var rm := ring.material_override as StandardMaterial3D
		if rm != null:
			var fade := (1.0 - phase) * (0.6 if _open else 0.3)
			var tint := _OPEN_TINT if _open else _closed_tint()
			rm.albedo_color = Color(tint.r, tint.g, tint.b, fade * 0.5)
			rm.emission_energy_multiplier = 2.0 * fade * _beacon_pulse_base
