extends CanvasLayer
class_name TradeUI
## Two-sided player-to-player trade session for co-op (Arc Raiders style).
##
## FLOW: Player A presses the "trade" input near a teammate -> A sends a trade
## request RPC to the nearest teammate (B). Both peers open this window. Each side
## edits ONLY its own offer (click an inventory item to add one, the "-" button or
## right-click to remove one); every offer change is mirrored to the partner via
## _rpc_offer so both panes stay in sync, and BOTH confirms reset on any change.
## Each side presses CONFIRM; when both confirms are set, the HOST (peer 1) is the
## arbiter: the final offers are routed to peer 1 via _rpc_finalize, which validates
## + executes BOTH directions of the swap with the server-authoritative
## NetworkManager.transfer_item, then tells both peers to close.
##
## SELF-CONTAINED: all session messaging lives here as @rpc methods. main.gd
## instances this scene once per peer at the SAME tree path (root node "TradeUI"),
## so rpc_id / rpc route correctly between the two participants. We never mutate
## inventories ourselves — only the host's transfer_item performs the actual move.

const THEME_PATH := "res://assets/ui/theme.tres"

# --------------------------------------------------------------- session state
var _partner: int = 0
var _active: bool = false
var _my_offer: Dictionary = {}  # item_id(String) -> count(int)
var _their_offer: Dictionary = {}  # item_id(String) -> count(int)
var _my_confirm: bool = false
var _their_confirm: bool = false

# --------------------------------------------------------------- ui references
var _root: Control = null
var _title: Label = null
var _inv_list: VBoxContainer = null
var _my_offer_list: VBoxContainer = null
var _their_offer_list: VBoxContainer = null
var _my_offer_title: Label = null
var _their_offer_title: Label = null
var _status: Label = null
var _confirm_btn: Button = null
var _cancel_btn: Button = null

# Cached local player + inventory (re-resolved lazily each time we open).
var _player: Node = null
var _inventory: Node = null


func _ready() -> void:
	name = "TradeUI"
	layer = 50
	_build_ui()
	_root.visible = false
	visible = true
	Events.peer_unregistered.connect(_on_peer_unregistered)


# -------------------------------------------------------------------- ui build
func _build_ui() -> void:
	var theme: Theme = load(THEME_PATH) as Theme

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	if theme != null:
		_root.theme = theme
	add_child(_root)

	# GlassBackdrop replaces the plain dim ColorRect.
	var bg := GlassBackdrop.new()
	_root.add_child(bg)
	_root.move_child(bg, 0)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL, 0.92))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(680, 460)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -340.0
	panel.offset_top = -230.0
	panel.offset_right = 340.0
	panel.offset_bottom = 230.0
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_title = Label.new()
	_title.text = "TRADE"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.make_header(_title, UIStyle.TEAL, 24, 4)
	vbox.add_child(_title)

	# Three columns: your inventory | your offer | their offer.
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(cols)

	_inv_list = _make_column(cols, "YOUR ITEMS")
	var my_col := _make_column_with_title(cols, "YOUR OFFER")
	_my_offer_title = my_col[0]
	_my_offer_list = my_col[1]
	var their_col := _make_column_with_title(cols, "THEIR OFFER")
	_their_offer_title = their_col[0]
	_their_offer_list = their_col[1]

	_status = Label.new()
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	vbox.add_child(buttons)

	_confirm_btn = Button.new()
	_confirm_btn.text = "CONFIRM"
	_confirm_btn.custom_minimum_size = Vector2(160, 40)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	UIStyle.hover_lift(_confirm_btn)
	buttons.add_child(_confirm_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "CANCEL"
	_cancel_btn.custom_minimum_size = Vector2(160, 40)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	UIStyle.hover_lift(_cancel_btn)
	buttons.add_child(_cancel_btn)


## A titled, scrollable VBox column. Returns the inner VBox to fill with rows.
func _make_column(parent: Node, title: String) -> VBoxContainer:
	return _make_column_with_title(parent, title)[1]


## Returns [title_label, inner_vbox] so callers that need the live title (offer
## panes show a weight) can keep a handle on it.
func _make_column_with_title(parent: Node, title: String) -> Array:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.custom_minimum_size = Vector2(200, 0)
	parent.add_child(col)

	var lbl := Label.new()
	lbl.text = title
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIStyle.make_header(lbl, UIStyle.DIM, 13, 3)
	col.add_child(lbl)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 4)
	scroll.add_child(inner)

	return [lbl, inner]


# ------------------------------------------------------------------- open/close
func _unhandled_input(event: InputEvent) -> void:
	if not is_inside_tree():
		return
	if event.is_action_pressed("trade"):
		_on_trade_pressed()
		get_viewport().set_input_as_handled()
	elif _active and event.is_action_pressed("ui_cancel"):
		_cancel_local(tr("Trade cancelled"))
		get_viewport().set_input_as_handled()


func _on_trade_pressed() -> void:
	if _active:
		# Pressing trade again while open is a no-op (use CANCEL to close).
		return
	var me: int = GameState.local_peer_id()
	var partner: int = NetworkManager.nearest_teammate(me)
	if partner == 0:
		Events.notify.emit(tr("No teammate nearby to trade"), 2)
		return
	_partner = partner
	_open(true)
	_set_status(tr("Waiting for %s...") % _peer_name(partner))
	# Ask the partner to open their side.
	_rpc_request.rpc_id(partner, me)


## Opens the window and binds to the local inventory. `initiator` distinguishes the
## sender (waiting state) from the receiver (ready state); both can edit freely.
func _open(initiator: bool) -> void:
	_active = true
	_my_offer.clear()
	_their_offer.clear()
	_my_confirm = false
	_their_confirm = false
	_bind_local_inventory()
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_title.text = tr("TRADE — with %s") % _peer_name(_partner)
	if not initiator:
		_set_status(tr("Trading with %s") % _peer_name(_partner))
	_refresh_all()
	# Pop the panel in when it becomes visible.
	var panel: Control = _root.get_child(1) if _root.get_child_count() > 1 else null
	if panel != null:
		UIStyle.pop_in(panel, UIStyle.Dir.DOWN, 14.0, 0.16)


## Closes the window locally and clears all session state. Does NOT message the
## partner (callers that need to tell the partner do so first).
func _close_local() -> void:
	_active = false
	_partner = 0
	_my_offer.clear()
	_their_offer.clear()
	_my_confirm = false
	_their_confirm = false
	_player = null
	_inventory = null
	if _root != null:
		_root.visible = false
	# Recapture the cursor unless paused / another UI owns it.
	if is_inside_tree() and not get_tree().paused:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Cancel from this side: tell the partner, close, notify.
func _cancel_local(reason: String) -> void:
	var partner: int = _partner
	if partner != 0:
		_rpc_cancel.rpc_id(partner)
	_close_local()
	Events.notify.emit(reason, 2)


func _on_cancel_pressed() -> void:
	_cancel_local(tr("Trade cancelled"))


# ------------------------------------------------------------------- offer edits
func _on_confirm_pressed() -> void:
	if not _active:
		return
	_my_confirm = true
	_rpc_confirm.rpc_id(_partner, true)
	_refresh_all()
	_try_finalize()


## Adds one of `item_id` to my offer, capped at what the inventory actually holds.
func _add_to_offer(item_id: String) -> void:
	if not _active:
		return
	var held: int = _held_count(item_id)
	if held <= 0:
		return
	var cur: int = int(_my_offer.get(item_id, 0))
	if cur >= held:
		return
	_my_offer[item_id] = cur + 1
	_on_my_offer_changed()


## Removes one of `item_id` from my offer.
func _remove_from_offer(item_id: String) -> void:
	if not _active:
		return
	var cur: int = int(_my_offer.get(item_id, 0))
	if cur <= 0:
		return
	if cur <= 1:
		_my_offer.erase(item_id)
	else:
		_my_offer[item_id] = cur - 1
	_on_my_offer_changed()


## Any change to my offer resets both confirms and re-syncs to the partner.
func _on_my_offer_changed() -> void:
	_my_confirm = false
	_their_confirm = false
	_rpc_offer.rpc_id(_partner, _my_offer.duplicate())
	_refresh_all()


# --------------------------------------------------------------------- finalize
## When both sides have confirmed, route the swap to the server (peer 1) to arbitrate.
func _try_finalize() -> void:
	if not (_my_confirm and _their_confirm):
		return
	# The two participants are the local peer and the partner. The host (peer 1)
	# executes; whichever side is peer 1 calls directly, otherwise we RPC peer 1.
	var me: int = GameState.local_peer_id()
	# Only ONE side should drive finalize to avoid a double swap. The lower peer id
	# of the two participants is the designated driver.
	if me > _partner:
		return
	_rpc_finalize.rpc_id(1, me, _partner, _my_offer.duplicate(), _their_offer.duplicate())


# -------------------------------------------------------------------- rpc methods
## RECEIVER side: a teammate wants to trade. Auto-accept the session; the real gate
## is the dual CONFIRM on the actual items.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request(from_peer: int) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != from_peer:
		return
	if _active:
		# Already trading — refuse politely.
		_rpc_cancel.rpc_id(from_peer)
		return
	_partner = from_peer
	_open(false)


## The partner updated their offer. Only our actual partner may change their pane.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_offer(offer: Dictionary) -> void:
	if not _active:
		return
	if multiplayer.get_remote_sender_id() != _partner:
		return
	_their_offer = offer.duplicate()
	# Their change also invalidates confirms on both sides (we mirror locally).
	_my_confirm = false
	_their_confirm = false
	_refresh_all()


## The partner pressed (or un-pressed) CONFIRM.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_confirm(value: bool) -> void:
	if not _active:
		return
	if multiplayer.get_remote_sender_id() != _partner:
		return
	_their_confirm = value
	_refresh_all()
	_try_finalize()


## The partner cancelled / disconnected.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_cancel() -> void:
	if not _active:
		return
	if multiplayer.get_remote_sender_id() != _partner and multiplayer.get_remote_sender_id() != 1:
		return
	_close_local()
	Events.notify.emit(tr("Partner cancelled the trade"), 2)


## SERVER ONLY: execute the atomic swap. `a` = the driver peer, `b` = its partner.
## transfer_item validates each side still has the items (and that they fit), so a
## stale/cheated offer simply moves less. Then close both windows.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_finalize(a_peer: int, b_peer: int, a_offer: Dictionary, b_offer: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	# Sender must be one of the two participants (the designated driver).
	var sender: int = multiplayer.get_remote_sender_id()
	if sender != a_peer and sender != b_peer:
		return
	for id in a_offer.keys():
		var cnt: int = int(a_offer[id])
		if cnt > 0:
			NetworkManager.transfer_item(a_peer, b_peer, String(id), cnt)
	for id in b_offer.keys():
		var cnt2: int = int(b_offer[id])
		if cnt2 > 0:
			NetworkManager.transfer_item(b_peer, a_peer, String(id), cnt2)
	# Tell both participants the trade is done. The server may itself be a or b.
	_rpc_complete.rpc_id(a_peer)
	_rpc_complete.rpc_id(b_peer)


## Either participant: the swap is done, close + toast. Only the server triggers this.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_complete() -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if not _active:
		return
	_close_local()
	Events.notify.emit(tr("Trade complete"), 1)


# ----------------------------------------------------------------- rendering
func _refresh_all() -> void:
	if not _active or _root == null:
		return
	_render_inventory()
	_render_offer(_my_offer_list, _my_offer, true)
	_render_offer(_their_offer_list, _their_offer, false)
	_my_offer_title.text = tr("YOUR OFFER (%d)") % _offer_total(_my_offer)
	_their_offer_title.text = tr("THEIR OFFER (%d)") % _offer_total(_their_offer)
	_update_status_and_buttons()


func _render_inventory() -> void:
	_clear(_inv_list)
	if _inventory == null:
		_bind_local_inventory()
	if _inventory == null:
		return
	var stacks: Array = _inventory.get("stacks")
	for s in stacks:
		var item = s.get("item", null)
		var cnt: int = int(s.get("count", 0))
		if item == null or cnt <= 0:
			continue
		var id: String = String(item.id)
		var offered: int = int(_my_offer.get(id, 0))
		var avail: int = cnt - offered
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var add_btn := Button.new()
		add_btn.text = "%s  (%d)" % [_display_name(id), avail]
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		add_btn.disabled = avail <= 0
		add_btn.tooltip_text = tr("Click to add one to your offer")
		add_btn.pressed.connect(_add_to_offer.bind(id))
		row.add_child(add_btn)

		_inv_list.add_child(row)


func _render_offer(list: VBoxContainer, offer: Dictionary, mine: bool) -> void:
	_clear(list)
	for id in offer.keys():
		var cnt: int = int(offer[id])
		if cnt <= 0:
			continue
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var lbl := Label.new()
		lbl.text = "%s x%d" % [_display_name(String(id)), cnt]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)

		if mine:
			var minus := Button.new()
			minus.text = "-"
			minus.custom_minimum_size = Vector2(28, 0)
			minus.tooltip_text = tr("Remove one from your offer")
			minus.pressed.connect(_remove_from_offer.bind(String(id)))
			row.add_child(minus)

		list.add_child(row)


func _update_status_and_buttons() -> void:
	# CONFIRM reflects our own confirm latch; disable once we've confirmed.
	_confirm_btn.disabled = _my_confirm
	_confirm_btn.text = tr("CONFIRMED") if _my_confirm else tr("CONFIRM")
	var mine: String = tr("ready") if _my_confirm else tr("editing")
	var theirs: String = tr("ready") if _their_confirm else tr("editing")
	_set_status(tr("You: %s   |   %s: %s") % [mine, _peer_name(_partner), theirs])


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ------------------------------------------------------------------- helpers
func _on_peer_unregistered(peer_id: int) -> void:
	if _active and peer_id == _partner:
		_close_local()
		Events.notify.emit(tr("Partner left — trade cancelled"), 2)


func _bind_local_inventory() -> void:
	var me_name := str(GameState.local_peer_id())
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if str(p.name) == me_name:
			_player = p
			var inv := p.get_node_or_null("Inventory")
			if inv != null:
				_inventory = inv
			return


func _held_count(item_id: String) -> int:
	if _inventory == null:
		_bind_local_inventory()
	if _inventory == null:
		return 0
	var total: int = 0
	var stacks: Array = _inventory.get("stacks")
	for s in stacks:
		var item = s.get("item", null)
		if item != null and String(item.id) == item_id:
			total += int(s.get("count", 0))
	return total


func _offer_total(offer: Dictionary) -> int:
	var n: int = 0
	for id in offer.keys():
		n += int(offer[id])
	return n


func _display_name(item_id: String) -> String:
	var item: ItemData = ItemCatalog.get_item(item_id)
	if item != null:
		return item.display_name
	return item_id


func _peer_name(peer_id: int) -> String:
	var info: Dictionary = GameState.peers.get(peer_id, {})
	var nm: String = String(info.get("name", ""))
	if nm != "":
		return nm
	return tr("Raider %d") % peer_id


func _clear(node: Node) -> void:
	if node == null:
		return
	for c in node.get_children():
		c.queue_free()
