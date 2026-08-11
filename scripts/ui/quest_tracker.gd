extends Control
## Compact in-raid CONTRACT TRACKER, top-right under the minimap (roadmap M4.6): up to
## MAX_ROWS active contracts as "title  current/target" so the player can see what a raid
## still owes them without opening the Hub.
##
## Read-only view over the `Quests` autoload — accepted standing contracts first, then the
## day's auto-active dailies; only quests in state "active" that aren't finished yet are
## tracked. Rows refresh off Events.quest_progress; a row that just COMPLETED flashes
## green and lingers DONE_HOLD seconds (the payoff beat) before dropping out. With nothing
## to track the whole widget collapses (visible = false) rather than showing an empty box.
##
## Self-positions with anchors+offsets (the minimap/killfeed discipline — a FULL_RECT
## wrapper collapses to zero size) and applies the same ultrawide HUD inset.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>` — every Dictionary/Array
## read gets an explicit type.

const MAX_ROWS := 3
const WIDTH := 236.0
const RIGHT := 16.0  # gap from the right screen edge
const TOP := 250.0  # sits BELOW the minimap block (radar + its event labels)
const ROW_H := 18.0
const FONT_SIZE := UIStyle.FONT_CAPTION
const DONE_HOLD := 3.0  # seconds a completed row stays up, flashing green
const TITLE_MIN_W := 130.0

# Each row: { "id": String, "row": HBoxContainer, "title": Label, "prog": Label,
#             "done_left": float }  — done_left > 0 means "completed, still on screen".
var _rows: Array = []
var _panel: PanelContainer = null
var _box: VBoxContainer = null
# The fullscreen tactical map supersedes the HUD corners — hide while it's open.
var _map_open: bool = false

# Authored (base) offsets, cached once so the ultrawide inset is idempotent.
var _base_off_l: float = 0.0
var _base_off_t: float = 0.0
var _base_off_r: float = 0.0
var _base_off_b: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A dedicated server has no screen — stay completely inert (no nodes, no signals).
	if DisplayServer.get_name() == "headless":
		return
	# Fixed-width box pinned to the top-right corner, growing DOWN with its content.
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -(WIDTH + RIGHT)
	offset_right = -RIGHT
	offset_top = TOP
	offset_bottom = TOP
	_base_off_l = offset_left
	_base_off_t = offset_top
	_base_off_r = offset_right
	_base_off_b = offset_bottom
	_apply_hud_inset()
	if not Events.ui_layout_changed.is_connected(_apply_hud_inset):
		Events.ui_layout_changed.connect(_apply_hud_inset)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_hud_inset):
		vp.size_changed.connect(_apply_hud_inset)
	_build_panel()
	Events.quest_progress.connect(_on_quest_progress)
	Events.match_started.connect(_rebuild)
	Events.map_toggled.connect(_on_map_toggled)
	set_process(false)  # only ticks while a completed row is holding
	_rebuild()


## Pull the tracker in from the top-right corner toward center (ultrawide comfort).
## Recomputed from the cached BASE offsets so repeated calls never accumulate.
func _apply_hud_inset() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var ex: float = UILayout.edge_px(vp.x)
	var ty: float = UILayout.top_px(vp.y)
	# RIGHT edge → shift LEFT by ex; TOP edge → shift DOWN by ty.
	offset_left = _base_off_l - ex
	offset_right = _base_off_r - ex
	offset_top = _base_off_t + ty
	offset_bottom = _base_off_b + ty


## Glass panel + header, built once. Rows are added/removed under the same VBox; the
## PanelContainer sizes itself to whatever the box currently holds.
func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.offset_left = 0.0
	_panel.offset_top = 0.0
	_panel.offset_right = 0.0
	_panel.offset_bottom = 0.0
	# A HUD readout wants tighter padding than the Hub-sized default glass panel.
	var sb := UIStyle.glass_panel(0.45)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	_box = VBoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override("separation", 3)
	_panel.add_child(_box)
	var header := UIStyle.micro_header(tr("CONTRACTS"), UIStyle.DIM, UIStyle.FONT_MIN)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(header)


# ---------------------------------------------------------------- event hooks
func _on_quest_progress(quest_id: String, current: int, target: int) -> void:
	var idx: int = _row_index(quest_id)
	if idx < 0:
		# Not tracked: a quest that just started moving deserves a free slot, if any.
		if _rows.size() < MAX_ROWS:
			_rebuild()
		return
	var entry: Dictionary = _rows[idx]
	_refresh_row(entry)
	if current >= target and float(entry["done_left"]) <= 0.0:
		_mark_done(entry)


func _on_map_toggled(open: bool) -> void:
	_map_open = open
	_update_visibility()


func _process(delta: float) -> void:
	var expired := false
	for r in _rows:
		var entry: Dictionary = r
		var left: float = float(entry["done_left"])
		if left <= 0.0:
			continue
		left -= delta
		entry["done_left"] = left
		if left <= 0.0:
			expired = true
	if expired:
		_rebuild()  # drops the finished rows and pulls the next contracts up
	set_process(_holding_count() > 0)


# ---------------------------------------------------------------- rows
## Reconcile the visible rows with what SHOULD be tracked right now. Rows still holding
## their completion flash are kept regardless so the payoff isn't cut short.
func _rebuild() -> void:
	if _box == null:
		return
	var want: Array = _track_ids()
	var keep: Array = []
	for r in _rows:
		var entry: Dictionary = r
		if String(entry["id"]) in want or float(entry["done_left"]) > 0.0:
			_refresh_row(entry)
			keep.append(entry)
		else:
			_free_row(entry)
	_rows = keep
	for id: String in want:
		if _row_index(id) < 0:
			_add_row(id)
	_update_visibility()


## Contract ids worth tracking: accepted standing contracts first (the player opted into
## those), then today's dailies. Capped so held completion rows keep their slot.
func _track_ids() -> Array:
	var out: Array = []
	var limit: int = MAX_ROWS - _holding_count()
	if limit <= 0:
		return out
	var pool: Array = []
	pool.append_array(Quests.accepted())
	pool.append_array(Quests.get_daily_quests())
	for item in pool:
		if out.size() >= limit:
			break
		var q: QuestData = item as QuestData
		if q == null or q.id in out:
			continue
		if Quests.state_of(q.id) == "active" and not Quests.is_complete(q):
			out.append(q.id)
	return out


func _add_row(id: String) -> void:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0.0, ROW_H)
	row.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# clip_text drops the label's text-driven minimum width — without it a long contract
	# title would push the whole panel wider than its anchored box.
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.custom_minimum_size = Vector2(TITLE_MIN_W, 0.0)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", FONT_SIZE)
	title.add_theme_color_override("font_color", UIStyle.WHITE)
	row.add_child(title)
	var prog := Label.new()
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	prog.add_theme_font_size_override("font_size", FONT_SIZE)
	prog.add_theme_color_override("font_color", UIStyle.AMBER)
	row.add_child(prog)
	_box.add_child(row)
	var entry: Dictionary = {"id": id, "row": row, "title": title, "prog": prog, "done_left": 0.0}
	_rows.append(entry)
	_refresh_row(entry)


func _refresh_row(entry: Dictionary) -> void:
	var q: QuestData = Quests.quest_by_id(String(entry["id"]))
	if q == null:
		return
	var title: Label = entry["title"]
	var prog: Label = entry["prog"]
	if title == null or not is_instance_valid(title):
		return
	title.text = tr(q.title)
	prog.text = "%d/%d" % [mini(Quests.progress(q.id), q.obj_count), q.obj_count]


## The completion beat: recolour the row green and hold it for DONE_HOLD seconds.
func _mark_done(entry: Dictionary) -> void:
	entry["done_left"] = DONE_HOLD
	var title: Label = entry["title"]
	var prog: Label = entry["prog"]
	if title != null and is_instance_valid(title):
		title.add_theme_color_override("font_color", UIStyle.GREEN)
	if prog != null and is_instance_valid(prog):
		prog.add_theme_color_override("font_color", UIStyle.GREEN)
	var row: HBoxContainer = entry["row"]
	if row != null and is_instance_valid(row):
		var tw := row.create_tween()
		tw.tween_property(row, "modulate", Color(1.7, 1.7, 1.7, 1.0), 0.12)
		tw.tween_property(row, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.35)
	set_process(true)


func _free_row(entry: Dictionary) -> void:
	var row: HBoxContainer = entry["row"]
	if row != null and is_instance_valid(row):
		row.queue_free()


func _row_index(id: String) -> int:
	for i in _rows.size():
		var entry: Dictionary = _rows[i]
		if String(entry["id"]) == id:
			return i
	return -1


func _holding_count() -> int:
	var n := 0
	for r in _rows:
		var entry: Dictionary = r
		if float(entry["done_left"]) > 0.0:
			n += 1
	return n


## An empty tracker is dead weight on the HUD — collapse it entirely (also while the
## fullscreen tactical map is open).
func _update_visibility() -> void:
	visible = not _rows.is_empty() and not _map_open
