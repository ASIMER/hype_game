extends CanvasLayer
## In-raid KILLS leaderboard shown while the player HOLDS TAB ("scoreboard" input action).
##
## Renders the server-authoritative + synced squad scoring data (GameState.kills /
## .deaths / .mobs_killed / .peers) — it does NOT compute or mutate anything. Every
## peer sees an identical, synchronized board: rows are rebuilt from GameState whenever
## the board is shown and whenever Events.scoreboard_changed fires.
##
## Layout: a centered semi-transparent panel — title "SQUAD — KILLS", a header row
## (PLAYER | KILLS | DEATHS), one row per squad member sorted by kills desc (tie-break
## by name asc), the local player's row highlighted, and a footer total row.
##
## main.gd instances this (res://scenes/ui/Scoreboard.tscn) into the in-raid UI layer.
## It is hold-to-view only: mouse_filter = IGNORE everywhere so it never steals input,
## and it starts hidden so it never shows in menus/hub.

# Project palette (matches assets/ui/theme.tres + hub.gd; not imported, just mirrored).
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)
const COL_TEXT  := Color(0.85, 0.88, 0.90, 1.0)
const COL_DIM   := Color(0.55, 0.60, 0.66, 1.0)
const COL_PANEL := Color(0.07, 0.09, 0.11, 0.92)
const COL_ROW_HL := Color(0.247, 0.71, 0.79, 0.16)  # local player's row tint

const HEADER_FONT_SIZE := 14
const ROW_FONT_SIZE := 16
const TITLE_FONT_SIZE := 22

# Built once in _ready, repopulated on each rebuild.
var _rows_box: VBoxContainer = null
var _total_label: Label = null
var _theme: Theme = null

func _ready() -> void:
	# Always process so hold-to-view polling works even if the world tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 50  # above the gameplay HUD

	if ResourceLoader.exists("res://assets/ui/theme.tres"):
		_theme = load("res://assets/ui/theme.tres") as Theme

	_build_ui()
	visible = false

	if Events.has_signal("scoreboard_changed"):
		Events.scoreboard_changed.connect(_on_scoreboard_changed)

func _process(_delta: float) -> void:
	# Poll the hold-to-view state every frame — robust against missed press/release.
	var want: bool = Input.is_action_pressed("scoreboard")
	if want != visible:
		visible = want
		if want:
			_rebuild()

func _on_scoreboard_changed() -> void:
	# Only refresh while visible; otherwise the next show() rebuilds fresh.
	if visible:
		_rebuild()

# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _theme:
		root.theme = _theme
	add_child(root)

	# Dim the screen slightly behind the panel.
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)

	# Centered panel.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(520, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.border_color = Color(0.235, 0.30, 0.36, 1.0)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Title.
	var title := Label.new()
	title.text = "SQUAD — KILLS"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", COL_AMBER)
	vbox.add_child(title)

	vbox.add_child(_make_separator())

	# Header row.
	var header := _make_row_grid()
	_make_cell(header, "PLAYER", COL_DIM, HEADER_FONT_SIZE, HORIZONTAL_ALIGNMENT_LEFT, true)
	_make_cell(header, "KILLS", COL_DIM, HEADER_FONT_SIZE, HORIZONTAL_ALIGNMENT_RIGHT, false)
	_make_cell(header, "DEATHS", COL_DIM, HEADER_FONT_SIZE, HORIZONTAL_ALIGNMENT_RIGHT, false)
	vbox.add_child(header)

	# Container for the per-peer rows (rebuilt each refresh).
	_rows_box = VBoxContainer.new()
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows_box.add_theme_constant_override("separation", 2)
	vbox.add_child(_rows_box)

	vbox.add_child(_make_separator())

	# Footer: team total.
	_total_label = Label.new()
	_total_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_total_label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	_total_label.add_theme_color_override("font_color", COL_TEAL)
	_total_label.text = "TEAM MOBS KILLED: 0"
	vbox.add_child(_total_label)

func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sep

## A 3-column grid used for header + every data row (kept consistent column widths).
func _make_row_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 18)
	return grid

func _make_cell(parent: Control, text: String, color: Color, fsize: int, align: int, expand: bool) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = align
	lbl.add_theme_font_size_override("font_size", fsize)
	lbl.add_theme_color_override("font_color", color)
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.custom_minimum_size = Vector2(220, 0)
	else:
		lbl.custom_minimum_size = Vector2(80, 0)
	parent.add_child(lbl)
	return lbl

# ── Data rebuild ─────────────────────────────────────────────────────────────

func _rebuild() -> void:
	if _rows_box == null:
		return

	for c in _rows_box.get_children():
		c.queue_free()

	var local_id: int = GameState.local_peer_id()

	# Build a sortable list from the full peer roster (so 0-kill members still show).
	var entries: Array = []
	for pid_key in GameState.peers.keys():
		var pid: int = int(pid_key)
		var info: Dictionary = GameState.peers[pid_key]
		var pname: String = String(info.get("name", "Player %d" % pid))
		var k: int = int(GameState.kills.get(pid, 0))
		var d: int = int(GameState.deaths.get(pid, 0))
		entries.append({ "pid": pid, "name": pname, "kills": k, "deaths": d })

	entries.sort_custom(_sort_entries)

	for e in entries:
		_add_row(e, e["pid"] == local_id)

	_total_label.text = "TEAM MOBS KILLED: %d" % GameState.mobs_killed

## Sort by kills desc, tie-break by name asc (case-insensitive).
func _sort_entries(a: Dictionary, b: Dictionary) -> bool:
	var ak: int = int(a["kills"])
	var bk: int = int(b["kills"])
	if ak != bk:
		return ak > bk
	return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0

func _add_row(e: Dictionary, is_local: bool) -> void:
	# Wrap the grid in a PanelContainer so the local player's row can be tinted.
	var wrap := PanelContainer.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_local:
		var hl := StyleBoxFlat.new()
		hl.bg_color = COL_ROW_HL
		hl.set_corner_radius_all(4)
		hl.content_margin_left = 6.0
		hl.content_margin_right = 6.0
		hl.content_margin_top = 2.0
		hl.content_margin_bottom = 2.0
		wrap.add_theme_stylebox_override("panel", hl)
	else:
		var pad := StyleBoxEmpty.new()
		pad.content_margin_left = 6.0
		pad.content_margin_right = 6.0
		pad.content_margin_top = 2.0
		pad.content_margin_bottom = 2.0
		wrap.add_theme_stylebox_override("panel", pad)

	var name_col: Color = COL_TEAL if is_local else COL_TEXT
	var num_col: Color = COL_AMBER if is_local else COL_TEXT

	var grid := _make_row_grid()
	var display_name: String = String(e["name"])
	if is_local:
		display_name += "  (you)"
	_make_cell(grid, display_name, name_col, ROW_FONT_SIZE, HORIZONTAL_ALIGNMENT_LEFT, true)
	_make_cell(grid, str(int(e["kills"])), num_col, ROW_FONT_SIZE, HORIZONTAL_ALIGNMENT_RIGHT, false)
	_make_cell(grid, str(int(e["deaths"])), num_col, ROW_FONT_SIZE, HORIZONTAL_ALIGNMENT_RIGHT, false)

	wrap.add_child(grid)
	_rows_box.add_child(wrap)
