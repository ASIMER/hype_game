extends Control
## LoadoutTab — the LOADOUT hub tab. Shown/hidden by the Hub; scripted entirely here
## (no static content in the .tscn except the full-rect root). Refreshes on _ready
## and whenever the stash changes (Events.stash_changed).
##
## Responsibilities:
##   • Weapons (permanent unlocks): toggle up to MAX_LOADOUT=3 into the deploy loadout.
##     Locked weapons show a "Unlock in Workshop" hint. Writes MetaProgression.set_loadout.
##   • Consumables to bring (at-risk): stepper rows for each consumable the player owns
##     in the stash. Writes MetaProgression.set_bring. Starter-loadout clears the bring.

# Weapon display names + canonical order.
const WEAPON_DISPLAY := {
	"rifle":   "RIFLE",
	"pistol":  "PISTOL",
	"smg":     "SMG",
	"shotgun": "SHOTGUN",
	"dmr":     "DMR",
}
const WEAPON_ORDER: Array[String] = ["rifle", "pistol", "smg", "shotgun", "dmr"]

# Project theme colours (matching workshop.gd / main menu).
const COL_AMBER := Color(0.91, 0.64, 0.24, 1.0)   # amber accent
const COL_TEAL  := Color(0.247, 0.71, 0.79, 1.0)  # teal accent / selected
const COL_DIM   := Color(0.45, 0.50, 0.55, 1.0)   # muted label
const COL_WHITE := Color(0.88, 0.90, 0.92, 1.0)   # body text
const COL_RED   := Color(0.85, 0.30, 0.25, 1.0)   # locked / warning
const COL_WARN  := Color(0.95, 0.70, 0.20, 1.0)   # at-risk callout


# ---------------------------------------------------------------- node refs
# Populated in _build_layout (called once from _ready).
var _weapon_rows: VBoxContainer
var _consumable_rows: VBoxContainer
var _empty_consumables_label: Label

# Runtime state -------------------------------------------------------
## Weapon rows: id -> { check: CheckButton, locked_lbl: Label }
var _weapon_ui: Dictionary = {}
## Consumable rows: id -> { minus_btn: Button, count_lbl: Label, plus_btn: Button, max_lbl: Label }
var _consume_ui: Dictionary = {}
## Current selected weapons (mirrors MetaProgression).
var _selected: Array[String] = []
## Current bring-counts (mirrors MetaProgression).
var _bring: Dictionary = {}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	Events.stash_changed.connect(_on_stash_changed)
	_refresh()


func _exit_tree() -> void:
	if Events.stash_changed.is_connected(_on_stash_changed):
		Events.stash_changed.disconnect(_on_stash_changed)


# ---------------------------------------------------------------- layout construction
## Builds the full UI tree programmatically. Called once.
func _build_layout() -> void:
	# ── Scroll root wrapping everything ──────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	scroll.add_child(body)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	body.add_child(margin)

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 20)
	margin.add_child(inner)

	# ── Page header ──────────────────────────────────────────────────────────
	var hdr := Label.new()
	hdr.name = "Header"
	hdr.text = "LOADOUT"
	UIStyle.make_header(hdr, UIStyle.AMBER, 42, 3)
	inner.add_child(hdr)

	# ── WEAPONS section ──────────────────────────────────────────────────────
	inner.add_child(_make_section_header("WEAPONS  (max %d)" % MetaProgression.MAX_LOADOUT))

	var weapon_panel := _make_panel()
	inner.add_child(weapon_panel)

	_weapon_rows = VBoxContainer.new()
	_weapon_rows.name = "WeaponRows"
	_weapon_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weapon_rows.add_theme_constant_override("separation", 10)
	weapon_panel.add_child(_weapon_rows)

	_build_weapon_rows()

	# ── CONSUMABLES TO BRING section ─────────────────────────────────────────
	inner.add_child(_make_section_header("CONSUMABLES TO BRING"))

	# At-risk warning banner.
	var warn_panel := PanelContainer.new()
	warn_panel.name = "WarnPanel"
	var warn_sb := StyleBoxFlat.new()
	warn_sb.bg_color = Color(0.30, 0.18, 0.05, 0.9)
	warn_sb.border_width_left = 3
	warn_sb.border_color = COL_WARN
	warn_sb.content_margin_left = 14.0
	warn_sb.content_margin_top = 10.0
	warn_sb.content_margin_right = 14.0
	warn_sb.content_margin_bottom = 10.0
	warn_sb.corner_radius_top_right = 6
	warn_sb.corner_radius_bottom_right = 6
	warn_panel.add_theme_stylebox_override("panel", warn_sb)
	inner.add_child(warn_panel)

	var warn_lbl := Label.new()
	warn_lbl.text = "AT RISK — items you bring are LOST if you die, but KEPT if you extract."
	warn_lbl.add_theme_color_override("font_color", COL_WARN)
	warn_lbl.add_theme_font_size_override("font_size", 13)
	warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn_panel.add_child(warn_lbl)

	# Consumable rows panel.
	var consume_panel := _make_panel()
	inner.add_child(consume_panel)

	var consume_vbox := VBoxContainer.new()
	consume_vbox.name = "ConsumeVBox"
	consume_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	consume_vbox.add_theme_constant_override("separation", 8)
	consume_panel.add_child(consume_vbox)

	_empty_consumables_label = Label.new()
	_empty_consumables_label.name = "EmptyLabel"
	_empty_consumables_label.text = "No consumables in stash — find or buy some."
	_empty_consumables_label.add_theme_color_override("font_color", COL_DIM)
	_empty_consumables_label.add_theme_font_size_override("font_size", 14)
	_empty_consumables_label.visible = false
	consume_vbox.add_child(_empty_consumables_label)

	_consumable_rows = VBoxContainer.new()
	_consumable_rows.name = "ConsumableRows"
	_consumable_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_consumable_rows.add_theme_constant_override("separation", 8)
	consume_vbox.add_child(_consumable_rows)

	# Starter loadout button (clears bring-list).
	var starter_btn := Button.new()
	starter_btn.name = "StarterBtn"
	starter_btn.text = "Starter loadout (no risk) — clear all"
	starter_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	starter_btn.add_theme_color_override("font_color", COL_TEAL)
	starter_btn.pressed.connect(_on_starter_pressed)
	inner.add_child(starter_btn)


## Returns a styled PanelContainer using the military-glass look.
func _make_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	return pc


## Returns a glass header-panel PanelContainer with a spaced-caps teal label inside.
func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	pc.add_child(UIStyle.micro_header(title, UIStyle.TEAL, 15))
	return pc


## Arc-style icon cell: a fixed-size Panel with a rarity-colored border holding an
## icon TextureRect (or colored-box fallback) + an optional count badge.
## Modeled on inventory_ui.gd::_make_slot. `id` may be an ItemData id (border uses
## rarity_color) or any other id (border uses a neutral teal).
func _icon_cell(id: String, count: int, cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	var item: ItemData = ItemCatalog.get_item(id)
	sb.border_color = item.rarity_color() if item != null else COL_TEAL
	sb.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", sb)
	if item != null:
		slot.tooltip_text = item.display_name

	var icon := AssetRegistry.get_icon(id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = 5
		tex.offset_top = 5
		tex.offset_right = -5
		tex.offset_bottom = -5
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 7
		box.offset_top = 7
		box.offset_right = -7
		box.offset_bottom = -7
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(box)

	if count > 1:
		var badge := Label.new()
		badge.text = "x%d" % count
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		badge.set_anchors_preset(Control.PRESET_FULL_RECT)
		badge.offset_right = -3
		badge.offset_bottom = -1
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.add_theme_color_override("font_outline_color", Color.BLACK)
		badge.add_theme_constant_override("outline_size", 4)
		badge.add_theme_font_size_override("font_size", 12)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(badge)
	return slot


# ---------------------------------------------------------------- weapon rows
## Creates one static row per weapon in WEAPON_ORDER inside _weapon_rows.
func _build_weapon_rows() -> void:
	if not _weapon_rows:
		return
	for id in WEAPON_ORDER:
		var row := HBoxContainer.new()
		row.name = "Row_" + id
		row.add_theme_constant_override("separation", 12)

		# Icon cell (40px, Arc-style rarity-bordered).
		row.add_child(_icon_cell(id, 0, 40))

		# Weapon name.
		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.custom_minimum_size = Vector2(90, 0)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text = WEAPON_DISPLAY.get(id, id.to_upper())
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		row.add_child(name_lbl)

		# Check toggle (visible when unlocked).
		var check := CheckButton.new()
		check.name = "Check"
		check.text = "IN LOADOUT"
		check.focus_mode = Control.FOCUS_NONE
		check.visible = false
		check.toggled.connect(func(pressed: bool) -> void: _on_weapon_toggled(id, pressed))
		row.add_child(check)

		# Locked label (visible when not unlocked).
		var locked_lbl := Label.new()
		locked_lbl.name = "LockedLbl"
		locked_lbl.text = "Locked — unlock in Workshop"
		locked_lbl.add_theme_color_override("font_color", COL_DIM)
		locked_lbl.add_theme_font_size_override("font_size", 13)
		locked_lbl.visible = false
		row.add_child(locked_lbl)

		_weapon_rows.add_child(row)
		_weapon_ui[id] = {
			"row":        row,
			"check":      check,
			"locked_lbl": locked_lbl,
		}


# ---------------------------------------------------------------- consumable rows
## Rebuilds consumable stepper rows based on current stash contents. Called on
## every refresh (stash can change between sessions).
func _rebuild_consumable_rows() -> void:
	if not _consumable_rows:
		return

	# Clear old rows (keep _empty_consumables_label which lives in the parent vbox).
	for child in _consumable_rows.get_children():
		child.queue_free()
	_consume_ui.clear()

	# Gather all consumable ids that are currently in the stash.
	var consumable_ids: Array = ItemCatalog.ids_of_kind(ItemData.Kind.CONSUMABLE)
	var owned_ids: Array = []
	for id in consumable_ids:
		if Stash.count_of(id) > 0:
			owned_ids.append(id)

	if owned_ids.is_empty():
		_empty_consumables_label.visible = true
		_consumable_rows.visible = false
		return

	_empty_consumables_label.visible = false
	_consumable_rows.visible = true

	# Sort for stable display order.
	owned_ids.sort()

	for id in owned_ids:
		var item: ItemData = ItemCatalog.get_item(id)
		var display: String = item.display_name if item else id

		var row := HBoxContainer.new()
		row.name = "Row_" + id
		row.add_theme_constant_override("separation", 10)

		# Icon cell (40px, badged with the count owned in stash).
		row.add_child(_icon_cell(id, Stash.count_of(id), 40))

		# Display name.
		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.custom_minimum_size = Vector2(110, 0)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text = display
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		row.add_child(name_lbl)

		# Minus button.
		var minus_btn := Button.new()
		minus_btn.name = "MinusBtn"
		minus_btn.text = "−"
		minus_btn.custom_minimum_size = Vector2(32, 32)
		minus_btn.focus_mode = Control.FOCUS_NONE
		minus_btn.pressed.connect(func() -> void: _on_consume_step(id, -1))
		row.add_child(minus_btn)

		# Count label.
		var count_lbl := Label.new()
		count_lbl.name = "CountLbl"
		count_lbl.custom_minimum_size = Vector2(28, 0)
		count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_lbl.add_theme_color_override("font_color", COL_AMBER)
		count_lbl.add_theme_font_size_override("font_size", 16)
		count_lbl.text = "0"
		row.add_child(count_lbl)

		# Plus button.
		var plus_btn := Button.new()
		plus_btn.name = "PlusBtn"
		plus_btn.text = "+"
		plus_btn.custom_minimum_size = Vector2(32, 32)
		plus_btn.focus_mode = Control.FOCUS_NONE
		plus_btn.pressed.connect(func() -> void: _on_consume_step(id, 1))
		row.add_child(plus_btn)

		# Max in stash label.
		var max_lbl := Label.new()
		max_lbl.name = "MaxLbl"
		max_lbl.add_theme_color_override("font_color", COL_DIM)
		max_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(max_lbl)

		_consumable_rows.add_child(row)
		_consume_ui[id] = {
			"minus_btn": minus_btn,
			"count_lbl": count_lbl,
			"plus_btn":  plus_btn,
			"max_lbl":   max_lbl,
		}


# ---------------------------------------------------------------- refresh
## Full state sync from MetaProgression + Stash. Called on _ready + stash_changed.
func _refresh() -> void:
	_selected = Array(MetaProgression.get_loadout(), TYPE_STRING, "", null)
	_bring = MetaProgression.get_bring()
	_refresh_weapon_rows()
	_rebuild_consumable_rows()
	_refresh_consume_rows()


## Syncs weapon toggle states and lock visibility without rebuilding nodes.
func _refresh_weapon_rows() -> void:
	var sel_count := _selected.size()
	for id in WEAPON_ORDER:
		var ui: Dictionary = _weapon_ui.get(id, {})
		if ui.is_empty():
			continue
		var owned: bool = MetaProgression.is_unlocked(id)
		var check: CheckButton = ui["check"]
		var locked_lbl: Label = ui["locked_lbl"]

		if owned:
			check.visible = true
			locked_lbl.visible = false
			var in_load: bool = id in _selected
			var would_exceed: bool = sel_count >= MetaProgression.MAX_LOADOUT and not in_load
			check.disabled = would_exceed
			check.set_block_signals(true)
			check.button_pressed = in_load
			check.set_block_signals(false)
		else:
			check.visible = false
			locked_lbl.visible = true


## Syncs the +/- count display and button states from _bring + current stash counts.
func _refresh_consume_rows() -> void:
	for id in _consume_ui:
		var ui: Dictionary = _consume_ui[id]
		if ui.is_empty():
			continue
		var stash_count: int = Stash.count_of(id)
		var bring_count: int = int(_bring.get(id, 0))
		bring_count = clampi(bring_count, 0, stash_count)

		var count_lbl: Label = ui["count_lbl"]
		var minus_btn: Button = ui["minus_btn"]
		var plus_btn: Button = ui["plus_btn"]
		var max_lbl: Label = ui["max_lbl"]

		count_lbl.text = str(bring_count)
		minus_btn.disabled = bring_count <= 0
		plus_btn.disabled = bring_count >= stash_count
		max_lbl.text = "/ %d in stash" % stash_count


# ---------------------------------------------------------------- event handlers
func _on_stash_changed() -> void:
	# Stash changed — rebuild consumable rows and re-clamp bring counts.
	_bring = MetaProgression.get_bring()
	_rebuild_consumable_rows()
	_refresh_consume_rows()


func _on_weapon_toggled(id: String, pressed: bool) -> void:
	if pressed:
		if id not in _selected and _selected.size() < MetaProgression.MAX_LOADOUT:
			_selected.append(id)
	else:
		_selected.erase(id)
	MetaProgression.set_loadout(_selected)
	_selected = Array(MetaProgression.get_loadout(), TYPE_STRING, "", null)
	_refresh_weapon_rows()


func _on_consume_step(id: String, delta: int) -> void:
	var stash_count: int = Stash.count_of(id)
	var current: int = int(_bring.get(id, 0))
	var next: int = clampi(current + delta, 0, stash_count)
	if next == 0:
		_bring.erase(id)
	else:
		_bring[id] = next
	MetaProgression.set_bring(_bring)
	_bring = MetaProgression.get_bring()
	_refresh_consume_rows()


func _on_starter_pressed() -> void:
	MetaProgression.set_bring({})
	_bring = MetaProgression.get_bring()
	_refresh_consume_rows()
