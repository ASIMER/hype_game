extends StaticBody3D
class_name LockedDoor
## A key-gated door panel sealing a loot annex bolted onto a landmark (batch C).
##
## Built by ProceduralBuildings.locked_annex() into the annex doorway: a solid panel
## (collision layer 1 → blocks passage + bakes the navmesh shut until opened) plus a
## small emissive keypad beside it. The annex interior holds EPIC loot the lead spawns;
## the only way in is to hold-E here with the matching key in your pack.
##
## Mirrors the proven hold-to-interact discipline of supply_cache.gd / the revive
## channel: a prompt Area3D detects a nearby player, the INTERACTING player's own peer
## runs the hold channel (gated on its interact button — the only peer that can read
## that button), and on completion fires a request RPC. The SERVER then validates the
## key, decrements it on its replicated copy of the player (which replicates back), and
## broadcasts the visual open to every peer via an authority RPC. The door is a
## deterministic STATIC node present on every peer before match start, so its node path
## (and thus the RPC path) is identical across the session.
##
## Determinism: this script carries NO procedural variation — all annex geometry jitter
## lives in the builder via ProcHash. Server-side effects gate on the authority server;
## visuals run on every peer.

## Public: true once the door has been opened (collider disabled, passage clear).
var opened: bool = false

# ─── prompt / hold state ──────────────────────────────────────────────────────

var _area: Area3D = null  # proximity zone that detects a nearby local player
## The local (authority) player currently inside the prompt zone, or null. Only the
## peer that OWNS this player runs the hold channel (it alone can read its interact
## button), exactly like the co-op revive channel.
var _local_player: Node = null
var _hold_elapsed: float = 0.0  # seconds the local player has held interact in range
var _prompt_shown: bool = false  # whether our "[E]" prompt is currently up (anti-spam)
var _is_server: bool = false
## Cooldown (s) after firing an unlock request, so a still-held interact can't spam
## duplicate requests during the server round-trip (the door opens once `opened` flips).
var _request_cooldown: float = 0.0

# ─── keypad visual ────────────────────────────────────────────────────────────

var _keypad_mat: StandardMaterial3D = null  # recoloured green on open
var _panel_origin: Vector3 = Vector3.ZERO  # panel's start position (for the sink tween)

# Keypad emissive tints: amber while locked, green once opened.
const _LOCKED_TINT := Color(1.0, 0.55, 0.15)
const _OPEN_TINT := Color(0.25, 1.0, 0.45)

# ─── lifecycle ───────────────────────────────────────────────────────────────


func _ready() -> void:
	add_to_group(Groups.LOCKED_DOORS)
	_panel_origin = position
	_resolve_keypad()

	# Proximity prompt zone (radius ~2.5 m) — detects the player body (layer 2), like
	# supply_cache's Area3D. Monitoring only; it never collides with anything.
	_area = Area3D.new()
	_area.name = "PromptZone"
	_area.collision_layer = 0
	_area.collision_mask = 2  # player body layer
	_area.monitoring = true
	_area.monitorable = false
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 2.5
	col.shape = shape
	_area.add_child(col)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)

	_is_server = GameState.is_local_authority_server()


## Cache the keypad material the builder tagged (meta "keypad_mat") so we can flip it
## green on open. Built render-only, so a headless server simply has nothing to flip.
func _resolve_keypad() -> void:
	if has_meta("keypad_mat"):
		var m: Variant = get_meta("keypad_mat")
		if m is StandardMaterial3D:
			_keypad_mat = m


# ─── proximity tracking ───────────────────────────────────────────────────────


func _on_body_entered(body: Node) -> void:
	if opened or body == null or not body.is_in_group(Groups.PLAYERS):
		return
	# Only the LOCAL (authority-owned) player drives the prompt + hold — a remote player's
	# interact button isn't readable here. A downed player can't unlock (mirrors revive).
	if not _is_local_player(body):
		return
	_local_player = body


func _on_body_exited(body: Node) -> void:
	if body != null and body == _local_player:
		_local_player = null
		_hold_elapsed = 0.0
		_clear_prompt()


func _is_local_player(body: Node) -> bool:
	return (
		body.has_method("is_multiplayer_authority")
		and body.is_multiplayer_authority()
		and not _is_body_downed(body)
	)


func _is_body_downed(body: Node) -> bool:
	return body.has_method("is_downed") and body.is_downed()


# ─── hold channel (runs on the interacting player's peer) ─────────────────────
# Identical discipline to the revive channel in player.gd: accumulate while the local
# player holds interact within range; on completion, request the open from the server.


func _physics_process(delta: float) -> void:
	if opened:
		return
	var p: Node = _local_player
	# Drop the channel if the player left, went down, or stopped being ours.
	if p == null or not is_instance_valid(p) or not _is_local_player(p):
		if _prompt_shown:
			_clear_prompt()
		_hold_elapsed = 0.0
		_local_player = null
		return

	Events.interaction_available.emit(tr("Unlock [hold E]"), self)
	_prompt_shown = true

	# Tick down the post-request cooldown (a "needs key" refusal also lands here).
	if _request_cooldown > 0.0:
		_request_cooldown = maxf(0.0, _request_cooldown - delta)

	if not _player_holds_interact(p):
		_hold_elapsed = 0.0
		return

	if _request_cooldown > 0.0:
		return
	_hold_elapsed = minf(_hold_elapsed + delta, Settings.LOCKED_DOOR_HOLD_TIME)
	if _hold_elapsed >= Settings.LOCKED_DOOR_HOLD_TIME:
		_hold_elapsed = 0.0
		_request_cooldown = 1.0  # suppress re-fire until the server answers
		_request_unlock()


## Read the player's HELD interact (agent-or-input). The player exposes _act_held via the
## same hook the revive/carry channels use; fall back to false if it's ever unavailable.
func _player_holds_interact(p: Node) -> bool:
	if p.has_method("_act_held"):
		return bool(p.call("_act_held", "interact"))
	return false


func _clear_prompt() -> void:
	if _prompt_shown:
		_prompt_shown = false
		Events.interaction_cleared.emit()


# ─── unlock request → server validate/consume → broadcast open ────────────────


## The interacting player's peer asks the server to open the door. Single-player counts
## as server (runs the validate path locally).
func _request_unlock() -> void:
	if _is_server:
		_server_try_open(_local_peer_id())
	else:
		_unlock_rpc.rpc_id(1, multiplayer.get_unique_id())


## SERVER entry: a peer requests the open. Validate + consume the key on the SERVER's copy
## of that peer's player, then broadcast the open to everyone (or refuse with a flash).
@rpc("any_peer", "call_local", "reliable")
func _unlock_rpc(requester_peer: int) -> void:
	if not multiplayer.is_server():
		return
	_server_try_open(requester_peer)


## SERVER-side validation: the requesting player must own the matching key. On success,
## decrement the key on the server copy (it replicates back to the owner) and open for all;
## on failure, flash a "needs key" hint to the requester only.
func _server_try_open(requester_peer: int) -> void:
	if opened:
		return
	var p: Node = _player_for_peer(requester_peer)
	if p == null:
		return
	var kid: String = key_id()
	var keys: Dictionary = {}
	if "_keys" in p:
		keys = p.get("_keys")
	if int(keys.get(kid, 0)) <= 0:
		# No key — refuse, naming the required key. Flash only to the requester.
		if requester_peer == _local_peer_id():
			_flash_needs_key()
		elif requester_peer > 0:
			_needs_key_rpc.rpc_id(requester_peer)
		return
	# Consume on the OWNER, not here: `_keys` replicates authority→peers (the player's
	# peer owns it), so a server-side decrement would be overwritten by the owner's
	# next sync tick. Same discipline as grenade/medkit counts. The server has already
	# validated ≥1; the host's own player IS local, so no RPC for requester==server.
	if requester_peer == _local_peer_id():
		_consume_key_local(p, kid)
	else:
		_consume_key_rpc.rpc_id(requester_peer, kid)
	_opened_rpc.rpc()


## OWNER-side: decrement our replicated key count (authority-owned property).
@rpc("authority", "call_remote", "reliable")
func _consume_key_rpc(kid: String) -> void:
	_consume_key_local(_player_for_peer(_local_peer_id()), kid)


func _consume_key_local(p: Node, kid: String) -> void:
	if p == null or not ("_keys" in p):
		return
	var keys: Dictionary = p.get("_keys")
	keys[kid] = maxi(0, int(keys.get(kid, 0)) - 1)
	p.set("_keys", keys)


## Tell a remote requester it lacks the key (server → that peer).
@rpc("authority", "call_remote", "reliable")
func _needs_key_rpc() -> void:
	_flash_needs_key()


## Surface the "requires <key>" message locally (the requester's HUD).
func _flash_needs_key() -> void:
	Events.notify.emit(tr("Requires %s") % _key_display_name(), 2)


## Open the door on EVERY peer: drop the collider (clears the navmesh blocker + lets
## players/bullets through), sink the panel, switch the keypad green, and announce it.
@rpc("authority", "call_local", "reliable")
func _opened_rpc() -> void:
	if opened:
		return
	opened = true
	_clear_prompt()
	_local_player = null

	# Disable the panel collider so passage is clear (deferred — physics may be mid-step).
	var panel_col := get_node_or_null("CollisionShape3D")
	if panel_col != null and panel_col is CollisionShape3D:
		(panel_col as CollisionShape3D).set_deferred("disabled", true)

	# Slide/sink the panel into the floor (visual only).
	var sink := _panel_origin + Vector3(0.0, -2.4, 0.0)
	var tween := create_tween()
	tween.tween_property(self, "position", sink, 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_IN
	)

	# Keypad flips to green.
	if _keypad_mat != null:
		_keypad_mat.albedo_color = _OPEN_TINT * 0.4
		_keypad_mat.emission = _OPEN_TINT

	Events.notify.emit(tr("Annex unlocked"), 1)
	Events.door_opened.emit(self)


# ─── public API (the lead / harness call these) ──────────────────────────────


## The key id this door requires (set by the builder via meta).
func key_id() -> String:
	return str(get_meta("key_id", ""))


## Harness: force the door open WITHOUT a key (server only — runs the same open path).
func debug_force_open() -> void:
	if not GameState.is_local_authority_server():
		return
	if opened:
		return
	_opened_rpc.rpc()


# ─── helpers ──────────────────────────────────────────────────────────────────


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


## Display name of the required key (for the "requires X" flash), via the item catalog;
## falls back to the raw id if the catalog hasn't got it.
func _key_display_name() -> String:
	var kid: String = key_id()
	var it: ItemData = ItemCatalog.get_item(kid)
	if it != null and it.display_name != "":
		return it.display_name
	return kid
