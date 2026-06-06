extends Control
## ServerBrowser — main-menu overlay for connecting to co-op servers.
##
## A centered "SERVERS" panel with: direct-connect by IP, LAN discovery, a
## favorites list, and a recent-connections list. This node owns NO networking;
## selecting a server emits `connect_requested(ip, port)` and the main menu does
## the actual ENet join. Data comes from the frozen `ServerBrowser` autoload and
## the `Events` bus; this is purely the view + interaction layer.
##
## Public contract (the menu depends on these):
##   func open()  -> void              show + rebuild lists
##   func close() -> void              hide
##   signal closed()
##   signal connect_requested(ip, port)
##
## Refreshes its lists on open(), Events.favorites_changed, and
## Events.lan_servers_found.

signal closed
signal connect_requested(ip: String, port: int)

# Project theme colours (shared across the UI — matches shop_tab.gd etc.).
const COL_AMBER := Color(0.91, 0.64, 0.24)
const COL_TEAL  := Color(0.247, 0.71, 0.79)
const COL_DIM   := Color(0.45, 0.50, 0.55)
const COL_WHITE := Color(0.88, 0.90, 0.92)
const COL_RED   := Color(0.85, 0.30, 0.25)

# ── Node refs (built in code; no .tscn sub-tree) ──────────────────────────────
var _direct_field: LineEdit  = null
var _scan_btn: Button        = null
var _scanning_label: Label   = null
var _lan_rows: VBoxContainer  = null
var _fav_rows: VBoxContainer   = null
var _recent_rows: VBoxContainer = null

var _scanning: bool = false


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	theme = load("res://assets/ui/theme.tres")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_layout()
	Events.favorites_changed.connect(_on_favorites_changed)
	Events.lan_scan_started.connect(_on_lan_scan_started)
	Events.lan_servers_found.connect(_on_lan_servers_found)
	hide()


func _exit_tree() -> void:
	if Events.favorites_changed.is_connected(_on_favorites_changed):
		Events.favorites_changed.disconnect(_on_favorites_changed)
	if Events.lan_scan_started.is_connected(_on_lan_scan_started):
		Events.lan_scan_started.disconnect(_on_lan_scan_started)
	if Events.lan_servers_found.is_connected(_on_lan_servers_found):
		Events.lan_servers_found.disconnect(_on_lan_servers_found)


# ── Public API ────────────────────────────────────────────────────────────────
func open() -> void:
	show()
	move_to_front()
	_refresh()


func close() -> void:
	hide()
	closed.emit()


# ── Layout construction ───────────────────────────────────────────────────────
##   Scrim (full-rect dim)
##   CenterContainer (full-rect) → PanelContainer (centered "SERVERS" card)
##     VBox body
##       Title "SERVERS"
##       DIRECT CONNECT row: field + CONNECT + ☆ Save
##       SCAN LAN button + "Scanning…" label
##       ScrollContainer → VBox
##         section "LAN"       → _lan_rows
##         section "FAVORITES" → _fav_rows
##         section "RECENT"    → _recent_rows
##       CLOSE button
func _build_layout() -> void:
	# Dim scrim behind the card.
	var scrim := Panel.new()
	scrim.name = "Scrim"
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	var scrim_sb := StyleBoxFlat.new()
	scrim_sb.bg_color = Color(0, 0, 0, 0.6)
	scrim.add_theme_stylebox_override("panel", scrim_sb)
	add_child(scrim)

	# Full-rect center wrapper → centers the card horizontally & vertically over
	# the scrim, regardless of viewport size. This mirrors SettingsMenu's centered
	# panel (which centers a PanelContainer at the screen midpoint).
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	# Centered card (fixed width; height = its content up to a sensible min, with
	# the list scrolling inside). A CenterContainer sizes the card to its minimum,
	# so the card never overflows toward a screen edge.
	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(560, 600)
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var card_sb := StyleBoxFlat.new()
	card_sb.bg_color = Color(0.086, 0.106, 0.125, 0.98)
	card_sb.border_width_left = 1
	card_sb.border_width_top = 1
	card_sb.border_width_right = 1
	card_sb.border_width_bottom = 1
	card_sb.border_color = Color(0.235, 0.3, 0.36, 1)
	card_sb.corner_radius_top_left = 10
	card_sb.corner_radius_top_right = 10
	card_sb.corner_radius_bottom_right = 10
	card_sb.corner_radius_bottom_left = 10
	card_sb.shadow_color = Color(0, 0, 0, 0.5)
	card_sb.shadow_size = 18
	card_sb.content_margin_left = 22.0
	card_sb.content_margin_top = 18.0
	card_sb.content_margin_right = 22.0
	card_sb.content_margin_bottom = 18.0
	card.add_theme_stylebox_override("panel", card_sb)
	center.add_child(card)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 14)
	card.add_child(body)

	# ── Title ─────────────────────────────────────────────────────────────────
	var title := Label.new()
	title.name = "Title"
	title.text = "SERVERS"
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", COL_AMBER)
	body.add_child(title)

	# ── DIRECT CONNECT ─────────────────────────────────────────────────────────
	body.add_child(_make_section_header("DIRECT CONNECT"))

	var dc_row := HBoxContainer.new()
	dc_row.name = "DirectRow"
	dc_row.add_theme_constant_override("separation", 8)
	dc_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(dc_row)

	_direct_field = LineEdit.new()
	_direct_field.name = "DirectField"
	_direct_field.placeholder_text = "ip  or  ip:port"
	_direct_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_direct_field.text_submitted.connect(func(_t: String) -> void: _on_direct_connect())
	dc_row.add_child(_direct_field)

	var connect_btn := Button.new()
	connect_btn.name = "ConnectBtn"
	connect_btn.text = "CONNECT"
	connect_btn.custom_minimum_size = Vector2(90, 32)
	connect_btn.focus_mode = Control.FOCUS_NONE
	connect_btn.pressed.connect(_on_direct_connect)
	dc_row.add_child(connect_btn)

	var save_btn := Button.new()
	save_btn.name = "SaveBtn"
	save_btn.text = "☆ Save"
	save_btn.custom_minimum_size = Vector2(70, 32)
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.pressed.connect(_on_direct_save)
	dc_row.add_child(save_btn)

	# ── SCAN LAN ───────────────────────────────────────────────────────────────
	var scan_row := HBoxContainer.new()
	scan_row.name = "ScanRow"
	scan_row.add_theme_constant_override("separation", 12)
	body.add_child(scan_row)

	_scan_btn = Button.new()
	_scan_btn.name = "ScanBtn"
	_scan_btn.text = "SCAN LAN"
	_scan_btn.custom_minimum_size = Vector2(120, 32)
	_scan_btn.focus_mode = Control.FOCUS_NONE
	_scan_btn.pressed.connect(_on_scan_lan)
	scan_row.add_child(_scan_btn)

	_scanning_label = Label.new()
	_scanning_label.name = "ScanningLabel"
	_scanning_label.text = "Scanning…"
	_scanning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scanning_label.add_theme_color_override("font_color", COL_TEAL)
	_scanning_label.add_theme_font_size_override("font_size", 14)
	_scanning_label.visible = false
	scan_row.add_child(_scanning_label)

	# ── Scroll wrapper for the lists ───────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	var list_body := VBoxContainer.new()
	list_body.name = "ListBody"
	list_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_body.add_theme_constant_override("separation", 12)
	scroll.add_child(list_body)

	# LAN
	list_body.add_child(_make_section_header("LAN"))
	var lan_panel := _make_panel()
	list_body.add_child(lan_panel)
	_lan_rows = VBoxContainer.new()
	_lan_rows.name = "LanRows"
	_lan_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_rows.add_theme_constant_override("separation", 6)
	lan_panel.add_child(_lan_rows)

	# FAVORITES
	list_body.add_child(_make_section_header("FAVORITES"))
	var fav_panel := _make_panel()
	list_body.add_child(fav_panel)
	_fav_rows = VBoxContainer.new()
	_fav_rows.name = "FavRows"
	_fav_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fav_rows.add_theme_constant_override("separation", 6)
	fav_panel.add_child(_fav_rows)

	# RECENT
	list_body.add_child(_make_section_header("RECENT"))
	var recent_panel := _make_panel()
	list_body.add_child(recent_panel)
	_recent_rows = VBoxContainer.new()
	_recent_rows.name = "RecentRows"
	_recent_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent_rows.add_theme_constant_override("separation", 6)
	recent_panel.add_child(_recent_rows)

	# ── CLOSE ──────────────────────────────────────────────────────────────────
	var close_btn := Button.new()
	close_btn.name = "CloseBtn"
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(0, 36)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(_on_close)
	body.add_child(close_btn)


# ── Refresh ───────────────────────────────────────────────────────────────────
func _refresh() -> void:
	if not is_inside_tree():
		return
	_rebuild_lan()
	_rebuild_favorites()
	_rebuild_recents()


func _rebuild_lan() -> void:
	_clear(_lan_rows)
	var servers: Array = ServerBrowser.last_found
	if _scanning:
		_lan_rows.add_child(_empty_label("Scanning the local network…"))
		return
	if servers.is_empty():
		_lan_rows.add_child(_empty_label("No LAN servers found. Press SCAN LAN."))
		return
	for srv in servers:
		var d: Dictionary = srv
		var name_s: String = String(d.get("name", ""))
		var ip: String = String(d.get("ip", ""))
		var port: int = int(d.get("port", Settings.DEFAULT_PORT))
		var players: int = int(d.get("players", 0))
		var maxp: int = int(d.get("max", 0))
		_lan_rows.add_child(_make_server_row(name_s, ip, port, players, maxp, "fav"))


func _rebuild_favorites() -> void:
	_clear(_fav_rows)
	var favs: Array = ServerBrowser.get_favorites()
	if favs.is_empty():
		_fav_rows.add_child(_empty_label("No favorites yet. Save a server with ☆."))
		return
	for srv in favs:
		var d: Dictionary = srv
		var name_s: String = String(d.get("name", ""))
		var ip: String = String(d.get("ip", ""))
		var port: int = int(d.get("port", Settings.DEFAULT_PORT))
		_fav_rows.add_child(_make_server_row(name_s, ip, port, -1, -1, "remove"))


func _rebuild_recents() -> void:
	_clear(_recent_rows)
	var recents: Array = ServerBrowser.get_recents()
	if recents.is_empty():
		_recent_rows.add_child(_empty_label("No recent connections."))
		return
	for srv in recents:
		var d: Dictionary = srv
		var name_s: String = String(d.get("name", ""))
		var ip: String = String(d.get("ip", ""))
		var port: int = int(d.get("port", Settings.DEFAULT_PORT))
		_recent_rows.add_child(_make_server_row(name_s, ip, port, -1, -1, "fav"))


# ── Row builders ──────────────────────────────────────────────────────────────

## Builds a server row: label "name · ip:port[ · players/max]" + CONNECT +
## an action button. `action` ∈ {"fav", "remove"}:
##   "fav"    → ☆ toggle (add/remove favorite)
##   "remove" → ✕ remove favorite (used in the FAVORITES list)
func _make_server_row(name_s: String, ip: String, port: int, players: int, maxp: int, action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.clip_text = true
	var text := "%s:%d" % [ip, port]
	if name_s != "":
		text = "%s  ·  %s" % [name_s, text]
	if players >= 0 and maxp >= 0:
		text += "  ·  %d/%d" % [players, maxp]
	label.text = text
	label.add_theme_color_override("font_color", COL_WHITE)
	row.add_child(label)

	var connect_btn := Button.new()
	connect_btn.text = "CONNECT"
	connect_btn.custom_minimum_size = Vector2(90, 30)
	connect_btn.focus_mode = Control.FOCUS_NONE
	connect_btn.pressed.connect(func() -> void: connect_requested.emit(ip, port))
	row.add_child(connect_btn)

	var act_btn := Button.new()
	act_btn.custom_minimum_size = Vector2(40, 30)
	act_btn.focus_mode = Control.FOCUS_NONE
	if action == "remove":
		act_btn.text = "✕"
		act_btn.add_theme_color_override("font_color", COL_RED)
		act_btn.pressed.connect(func() -> void: ServerBrowser.remove_favorite(ip, port))
	else:
		var faved: bool = ServerBrowser.is_favorite(ip, port)
		act_btn.text = "★" if faved else "☆"
		act_btn.add_theme_color_override("font_color", COL_AMBER if faved else COL_DIM)
		act_btn.pressed.connect(func() -> void: _toggle_favorite(name_s, ip, port))
	row.add_child(act_btn)

	return row


func _empty_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", COL_DIM)
	lbl.add_theme_font_size_override("font_size", 13)
	return lbl


# ── Helpers ───────────────────────────────────────────────────────────────────
func _make_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.106, 0.133, 0.157, 0.97)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.235, 0.3, 0.36, 1)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_right = 8
	sb.corner_radius_bottom_left = 8
	sb.content_margin_left = 14.0
	sb.content_margin_top = 12.0
	sb.content_margin_right = 14.0
	sb.content_margin_bottom = 12.0
	pc.add_theme_stylebox_override("panel", sb)
	return pc


func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.165, 0.20, 1.0)
	sb.border_width_bottom = 1
	sb.border_color = Color(0.235, 0.3, 0.36, 0.8)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.content_margin_left = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_right = 14.0
	sb.content_margin_bottom = 8.0
	pc.add_theme_stylebox_override("panel", sb)

	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_color_override("font_color", COL_TEAL)
	lbl.add_theme_font_size_override("font_size", 15)
	pc.add_child(lbl)
	return pc


func _clear(container: Node) -> void:
	if container == null:
		return
	for c in container.get_children():
		c.queue_free()


# ── Actions ───────────────────────────────────────────────────────────────────
func _on_direct_connect() -> void:
	var a: Dictionary = ServerBrowser.parse_addr(_direct_field.text)
	var ip: String = String(a.get("ip", ""))
	var port: int = int(a.get("port", Settings.DEFAULT_PORT))
	connect_requested.emit(ip, port)


func _on_direct_save() -> void:
	var a: Dictionary = ServerBrowser.parse_addr(_direct_field.text)
	var ip: String = String(a.get("ip", ""))
	var port: int = int(a.get("port", Settings.DEFAULT_PORT))
	if ip == "":
		return
	ServerBrowser.add_favorite("", ip, port)


func _toggle_favorite(name_s: String, ip: String, port: int) -> void:
	if ServerBrowser.is_favorite(ip, port):
		ServerBrowser.remove_favorite(ip, port)
	else:
		ServerBrowser.add_favorite(name_s, ip, port)


func _on_scan_lan() -> void:
	ServerBrowser.scan_lan()


func _on_close() -> void:
	close()


# ── Signal handlers ───────────────────────────────────────────────────────────
func _on_favorites_changed() -> void:
	if not visible:
		return
	_refresh()


func _on_lan_scan_started() -> void:
	_scanning = true
	_scanning_label.visible = true
	if _scan_btn != null:
		_scan_btn.disabled = true
	_rebuild_lan()


func _on_lan_servers_found(_servers: Array) -> void:
	_scanning = false
	_scanning_label.visible = false
	if _scan_btn != null:
		_scan_btn.disabled = false
	_refresh()
