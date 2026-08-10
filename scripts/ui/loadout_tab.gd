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
	"rifle": "RIFLE",
	"pistol": "PISTOL",
	"smg": "SMG",
	"shotgun": "SHOTGUN",
	"dmr": "DMR",
}
const WEAPON_ORDER: Array[String] = ["rifle", "pistol", "smg", "shotgun", "dmr"]

# Project theme colours (matching workshop.gd / main menu).
const COL_AMBER := UIStyle.AMBER  # amber accent
const COL_TEAL := UIStyle.TEAL  # teal accent / selected
const COL_DIM := UIStyle.DIM  # muted label
const COL_WHITE := UIStyle.WHITE  # body text
const COL_RED := UIStyle.RED  # locked / warning
const COL_GREEN := UIStyle.GREEN  # equipped / ready
const COL_WARN := Color(0.95, 0.70, 0.20, 1.0)  # at-risk callout

# Equipped gear slots (display order); mirrors Settings.GEAR_SLOTS.
const GEAR_SLOT_LABELS: Dictionary = {
	"helmet": "HELMET",
	"vest": "VEST",
	"backpack": "BACKPACK",
}
# Responsive owned-armor grid: a single card never stretches full-width on ultrawide.
const _ARMOR_CELL_W := 240.0  # target owned-armor card width (px)
const _ARMOR_MAX_COLS := 5

# ---------------------------------------------------------------- node refs
# Populated in _build_layout (called once from _ready).
var _weapon_rows: VBoxContainer
var _consumable_rows: VBoxContainer
var _empty_consumables_label: Label
# Equipment section refs.
var _gear_slots_row: HBoxContainer  # the 3 equipped-slot cells
var _gear_actions_box: VBoxContainer  # per-equipped-piece REPAIR/INSURE rows
var _owned_armor_grid: GridContainer  # owned-armor responsive grid
var _empty_armor_label: Label
var _insurance_box: VBoxContainer  # pending-insurance list
## Pending-insurance countdown rows: index -> { id: String, return_at: int, label: Label }
var _insurance_rows: Array[Dictionary] = []
## 1s accumulator driving the pending-insurance countdown (NOT a create_timer).
var _insurance_tick: float = 0.0

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
	# Equipment refresh hooks (the gear/armor/insurance lane fires these).
	if Events.has_signal("gear_changed"):
		Events.gear_changed.connect(_on_gear_changed)
	if Events.has_signal("armor_changed"):
		Events.armor_changed.connect(_on_armor_changed)
	if Events.has_signal("insurance_changed"):
		Events.insurance_changed.connect(_on_gear_changed)
	# Reflow the owned-armor grid columns when the tab (and thus the window) resizes.
	resized.connect(_apply_armor_columns)
	_refresh()


func _exit_tree() -> void:
	if Events.stash_changed.is_connected(_on_stash_changed):
		Events.stash_changed.disconnect(_on_stash_changed)
	if Events.has_signal("gear_changed") and Events.gear_changed.is_connected(_on_gear_changed):
		Events.gear_changed.disconnect(_on_gear_changed)
	if Events.has_signal("armor_changed") and Events.armor_changed.is_connected(_on_armor_changed):
		Events.armor_changed.disconnect(_on_armor_changed)
	if (
		Events.has_signal("insurance_changed")
		and Events.insurance_changed.is_connected(_on_gear_changed)
	):
		Events.insurance_changed.disconnect(_on_gear_changed)


## Ticks the pending-insurance countdown labels once per second (a frame accumulator,
## not a create_timer). Idle when there is nothing pending.
func _process(delta: float) -> void:
	if _insurance_rows.is_empty():
		return
	_insurance_tick += delta
	if _insurance_tick < 1.0:
		return
	_insurance_tick = 0.0
	_update_insurance_countdowns()


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

	# ── EQUIPMENT section (armor / packs — AT RISK) ──────────────────────────
	_build_equipment_section(inner)

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


## Builds the EQUIPMENT section skeleton (equipped slots + actions + owned grid +
## pending insurance). The dynamic contents are filled by _rebuild_equipment().
func _build_equipment_section(inner: VBoxContainer) -> void:
	inner.add_child(_make_section_header("EQUIPMENT"))

	# Equipped-slot cells (HELMET / VEST / BACKPACK) in a glass panel.
	var slots_panel := _make_panel()
	inner.add_child(slots_panel)

	_gear_slots_row = HBoxContainer.new()
	_gear_slots_row.name = "GearSlotsRow"
	_gear_slots_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gear_slots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_gear_slots_row.add_theme_constant_override("separation", 18)
	slots_panel.add_child(_gear_slots_row)

	# Per-equipped-piece REPAIR / INSURE action rows.
	_gear_actions_box = VBoxContainer.new()
	_gear_actions_box.name = "GearActionsBox"
	_gear_actions_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gear_actions_box.add_theme_constant_override("separation", 8)
	inner.add_child(_gear_actions_box)

	# Owned-armor grid header + panel.
	inner.add_child(_make_section_header("OWNED ARMOR"))

	var armor_panel := _make_panel()
	inner.add_child(armor_panel)

	var armor_vbox := VBoxContainer.new()
	armor_vbox.name = "ArmorVBox"
	armor_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	armor_vbox.add_theme_constant_override("separation", 8)
	armor_panel.add_child(armor_vbox)

	_empty_armor_label = Label.new()
	_empty_armor_label.name = "EmptyArmorLabel"
	_empty_armor_label.text = "No armor in stash — find or buy some."
	_empty_armor_label.add_theme_color_override("font_color", COL_DIM)
	_empty_armor_label.add_theme_font_size_override("font_size", 14)
	_empty_armor_label.visible = false
	armor_vbox.add_child(_empty_armor_label)

	_owned_armor_grid = GridContainer.new()
	_owned_armor_grid.name = "OwnedArmorGrid"
	_owned_armor_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_owned_armor_grid.add_theme_constant_override("h_separation", 12)
	_owned_armor_grid.add_theme_constant_override("v_separation", 12)
	_owned_armor_grid.columns = _armor_columns_now()
	armor_vbox.add_child(_owned_armor_grid)

	# Pending-insurance list (hidden until there is something pending).
	_insurance_box = VBoxContainer.new()
	_insurance_box.name = "InsuranceBox"
	_insurance_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_insurance_box.add_theme_constant_override("separation", 8)
	_insurance_box.visible = false
	inner.add_child(_insurance_box)


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
	pc.add_theme_stylebox_override("panel", UIStyle.section_bar(UIStyle.TEAL))
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
		badge.add_theme_font_size_override("font_size", 13)
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
			"row": row,
			"check": check,
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
		max_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(max_lbl)

		_consumable_rows.add_child(row)
		_consume_ui[id] = {
			"minus_btn": minus_btn,
			"count_lbl": count_lbl,
			"plus_btn": plus_btn,
			"max_lbl": max_lbl,
		}


# ---------------------------------------------------------------- equipment
## True only when the parallel gear/armor lane's MetaProgression API is present.
## The whole EQUIPMENT section degrades to empty placeholders until then.
func _gear_api_ready() -> bool:
	return (
		MetaProgression.has_method("get_equipped_gear")
		and MetaProgression.has_method("set_equipped_gear")
	)


## Columns that fit the current tab width (minus panel padding + scrollbar).
func _armor_columns_now() -> int:
	return UILayout.columns_for(size.x - 64.0, _ARMOR_CELL_W, 12.0, _ARMOR_MAX_COLS)


## Re-apply the responsive owned-armor column count (on resize).
func _apply_armor_columns() -> void:
	if _owned_armor_grid != null:
		_owned_armor_grid.columns = _armor_columns_now()


## Rebuilds the whole EQUIPMENT section from MetaProgression + Stash. Degrades to
## empty placeholders if the gear/armor lane's API is not yet present.
func _rebuild_equipment() -> void:
	if not _gear_api_ready():
		return
	_rebuild_gear_slots()
	_rebuild_gear_actions()
	_rebuild_owned_armor()
	_rebuild_insurance()


## Builds the three equipped-slot cells (HELMET / VEST / BACKPACK), each with an icon,
## name, and a durability bar (hidden for indestructible backpacks). Click → unequip.
func _rebuild_gear_slots() -> void:
	if _gear_slots_row == null:
		return
	for c in _gear_slots_row.get_children():
		c.queue_free()

	var equipped: Dictionary = MetaProgression.get_equipped_gear()
	for slot_id in Settings.GEAR_SLOTS:
		_gear_slots_row.add_child(_make_gear_slot_cell(String(slot_id), equipped))


## One equipped-slot cell: micro_header label + icon + name + durability bar.
func _make_gear_slot_cell(slot_id: String, equipped: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.name = "GearSlot_" + slot_id
	col.custom_minimum_size = Vector2(150, 0)
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	col.add_theme_constant_override("separation", 4)

	# Slot label (HELMET / VEST / BACKPACK).
	var lbl := UIStyle.micro_header(GEAR_SLOT_LABELS.get(slot_id, slot_id.to_upper()), COL_TEAL, 13)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(lbl)

	var equipped_id: String = String(equipped.get(slot_id, ""))

	# Icon cell — clickable to unequip when something is slotted, else an empty placeholder.
	if equipped_id.is_empty():
		var empty_cell := _empty_slot_cell(56)
		empty_cell.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(empty_cell)

		var none_lbl := Label.new()
		none_lbl.text = tr("— empty —")
		none_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		none_lbl.add_theme_color_override("font_color", COL_DIM)
		none_lbl.add_theme_font_size_override("font_size", 13)
		col.add_child(none_lbl)
		return col

	var broken: bool = (
		MetaProgression.is_armor_broken(equipped_id)
		if MetaProgression.has_method("is_armor_broken")
		else false
	)

	# Click-to-unequip icon button (rarity-bordered icon, broken → red tint).
	var cell := _icon_cell(equipped_id, 0, 56)
	cell.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	if broken:
		cell.modulate = Color(1.0, 0.55, 0.5, 1.0)
	var click_btn := Button.new()
	click_btn.name = "Unequip"
	click_btn.flat = true
	click_btn.focus_mode = Control.FOCUS_NONE
	click_btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_btn.tooltip_text = tr("Unequip")
	click_btn.pressed.connect(func() -> void: _on_unequip_gear(slot_id))
	cell.add_child(click_btn)
	col.add_child(cell)

	# Name.
	var item: ItemData = ItemCatalog.get_item(equipped_id)
	var name_lbl := Label.new()
	name_lbl.text = tr(item.display_name) if item != null else equipped_id
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", COL_RED if broken else COL_WHITE)
	name_lbl.add_theme_font_size_override("font_size", 13)
	col.add_child(name_lbl)

	# Durability bar — hidden for indestructible packs (durability_max 0).
	var armor: ArmorData = item as ArmorData
	var dura_max: float = armor.durability_max if armor != null else 0.0
	if dura_max > 0.0:
		var bar := ProgressBar.new()
		bar.theme_type_variation = "FillAmber"
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.min_value = 0.0
		bar.max_value = dura_max
		var dura: float = (
			MetaProgression.durability_of(equipped_id)
			if MetaProgression.has_method("durability_of")
			else dura_max
		)
		bar.value = clampf(dura, 0.0, dura_max)
		# Broken → tint the fill RED (the amber FillAmber variation re-tinted via modulate).
		if broken:
			bar.modulate = COL_RED
		col.add_child(bar)

		if broken:
			var broke_lbl := Label.new()
			broke_lbl.text = tr("BROKEN")
			broke_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			broke_lbl.add_theme_color_override("font_color", COL_RED)
			broke_lbl.add_theme_font_size_override("font_size", 12)
			col.add_child(broke_lbl)
	return col


## A dim empty-slot placeholder cell (dashed look), matching gunsmith_tab's empty cell.
func _empty_slot_cell(cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.border_color = COL_DIM
	slot.add_theme_stylebox_override("panel", sb)
	var dash := Label.new()
	dash.text = "—"
	dash.set_anchors_preset(Control.PRESET_FULL_RECT)
	dash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dash.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dash.add_theme_color_override("font_color", COL_DIM)
	dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(dash)
	return slot


## Builds the per-equipped-piece REPAIR / INSURE action rows (one per damageable
## equipped piece). Backpacks (durability_max 0) still get an INSURE option.
func _rebuild_gear_actions() -> void:
	if _gear_actions_box == null:
		return
	for c in _gear_actions_box.get_children():
		c.queue_free()

	var equipped: Dictionary = MetaProgression.get_equipped_gear()
	for slot_id in Settings.GEAR_SLOTS:
		var equipped_id: String = String(equipped.get(slot_id, ""))
		if equipped_id.is_empty():
			continue
		_gear_actions_box.add_child(_make_gear_action_row(equipped_id))


## One actions row for an equipped piece: name | REPAIR (CR n) | INSURE (CR n) / INSURED.
func _make_gear_action_row(equipped_id: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "ActionRow_" + equipped_id
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	var item: ItemData = ItemCatalog.get_item(equipped_id)
	var armor: ArmorData = item as ArmorData

	# Name.
	var name_lbl := Label.new()
	name_lbl.text = tr(item.display_name) if item != null else equipped_id
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_color_override("font_color", COL_WHITE)
	name_lbl.add_theme_font_size_override("font_size", 13)
	row.add_child(name_lbl)

	# REPAIR button (only for damageable pieces).
	var dura_max: float = armor.durability_max if armor != null else 0.0
	if dura_max > 0.0 and MetaProgression.has_method("repair_armor"):
		var cost: int = (
			MetaProgression.repair_cost(equipped_id)
			if MetaProgression.has_method("repair_cost")
			else 0
		)
		var dura: float = (
			MetaProgression.durability_of(equipped_id)
			if MetaProgression.has_method("durability_of")
			else dura_max
		)
		var repair_btn := Button.new()
		repair_btn.name = "RepairBtn"
		repair_btn.text = tr("REPAIR (CR %d)") % cost
		repair_btn.focus_mode = Control.FOCUS_NONE
		# Disabled at full durability or when unaffordable.
		repair_btn.disabled = dura >= dura_max or MetaProgression.currency < cost
		repair_btn.pressed.connect(func() -> void: _on_repair_gear(equipped_id))
		UIStyle.hover_lift(repair_btn)
		row.add_child(repair_btn)

	# INSURE button → INSURED chip when already insured.
	if MetaProgression.has_method("insure_item"):
		var insured: bool = (
			MetaProgression.is_insured(equipped_id)
			if MetaProgression.has_method("is_insured")
			else false
		)
		if insured:
			var chip := _make_chip(tr("INSURED"), COL_DIM)
			row.add_child(chip)
		else:
			var ins_cost: int = (
				MetaProgression.insurance_cost(equipped_id)
				if MetaProgression.has_method("insurance_cost")
				else 0
			)
			var insure_btn := Button.new()
			insure_btn.name = "InsureBtn"
			insure_btn.text = tr("INSURE (CR %d)") % ins_cost
			insure_btn.focus_mode = Control.FOCUS_NONE
			insure_btn.disabled = MetaProgression.currency < ins_cost
			insure_btn.pressed.connect(func() -> void: _on_insure_gear(equipped_id))
			UIStyle.hover_lift(insure_btn)
			row.add_child(insure_btn)
	return row


## Rebuilds the OWNED-ARMOR responsive grid: every stash item whose catalog entry is
## ArmorData. Clicking a card equips it into its slot; the equipped one gets an accent.
func _rebuild_owned_armor() -> void:
	if _owned_armor_grid == null:
		return
	for c in _owned_armor_grid.get_children():
		c.queue_free()
	_owned_armor_grid.columns = _armor_columns_now()

	var equipped: Dictionary = MetaProgression.get_equipped_gear()
	# Gather owned armor ids (catalog entry is ArmorData and Stash.count_of > 0).
	var owned: Array[String] = []
	for raw_id in ItemCatalog.ids_of_kind(ItemData.Kind.ARMOR):
		var id: String = String(raw_id)
		if Stash.count_of(id) <= 0:
			continue
		if ItemCatalog.get_item(id) is ArmorData:
			owned.append(id)
	owned.sort()

	if owned.is_empty():
		_empty_armor_label.visible = true
		_owned_armor_grid.visible = false
		return
	_empty_armor_label.visible = false
	_owned_armor_grid.visible = true

	for id in owned:
		_owned_armor_grid.add_child(_make_owned_armor_card(id, equipped))


## One owned-armor card: icon + name + slot tag + (EQUIPPED chip or click→equip).
func _make_owned_armor_card(id: String, equipped: Dictionary) -> PanelContainer:
	var item: ItemData = ItemCatalog.get_item(id)
	var armor: ArmorData = item as ArmorData
	var slot_id: String = armor.slot if armor != null else ""
	var is_equipped: bool = String(equipped.get(slot_id, "")) == id

	var card := PanelContainer.new()
	card.name = "ArmorCard_" + id
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := UIStyle.glass_panel()
	if is_equipped:
		# Accent border for the equipped piece.
		sb.border_color = COL_GREEN
		sb.set_border_width_all(2)
	card.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)

	row.add_child(_icon_cell(id, Stash.count_of(id), 44))

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)

	var name_lbl := Label.new()
	name_lbl.text = tr(item.display_name) if item != null else id
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.add_theme_color_override("font_color", COL_WHITE)
	name_lbl.add_theme_font_size_override("font_size", 13)
	info.add_child(name_lbl)

	var slot_lbl := Label.new()
	slot_lbl.text = tr(GEAR_SLOT_LABELS.get(slot_id, slot_id.to_upper()))
	slot_lbl.add_theme_color_override("font_color", COL_TEAL)
	slot_lbl.add_theme_font_size_override("font_size", 12)
	info.add_child(slot_lbl)

	if is_equipped:
		var chip := _make_chip(tr("EQUIPPED"), COL_GREEN)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(chip)
	else:
		# Whole card is click-to-equip (gui_input on the card, the stash_tab slot pattern).
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.tooltip_text = tr("Equip")
		card.gui_input.connect(
			func(ev: InputEvent) -> void:
				if (
					ev is InputEventMouseButton
					and ev.pressed
					and ev.button_index == MOUSE_BUTTON_LEFT
				):
					_on_equip_armor(slot_id, id)
		)
	return card


## Rebuilds the pending-insurance list (only shown when something is pending). Each
## row's countdown text is refreshed every second by _process (NOT a timer).
func _rebuild_insurance() -> void:
	if _insurance_box == null:
		return
	for c in _insurance_box.get_children():
		c.queue_free()
	_insurance_rows.clear()

	var pending: Array = []
	if "insured_pending" in MetaProgression:
		pending = MetaProgression.insured_pending
	if pending.is_empty():
		_insurance_box.visible = false
		return
	_insurance_box.visible = true

	_insurance_box.add_child(_make_section_header("PENDING INSURANCE"))
	var panel := _make_panel()
	_insurance_box.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	for entry in pending:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id: String = String(entry.get("id", ""))
		var return_at: int = int(entry.get("return_at", 0))
		var item: ItemData = ItemCatalog.get_item(id)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(_icon_cell(id, 0, 36))

		var name_lbl := Label.new()
		name_lbl.text = tr(item.display_name) if item != null else id
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		name_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(name_lbl)

		var time_lbl := Label.new()
		time_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		time_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(time_lbl)

		vbox.add_child(row)
		_insurance_rows.append({"id": id, "return_at": return_at, "label": time_lbl})

	_update_insurance_countdowns()


## Updates each pending-insurance row's countdown text. Called on rebuild + every 1s.
func _update_insurance_countdowns() -> void:
	var now: int = int(Time.get_unix_time_from_system())
	for r in _insurance_rows:
		var lbl: Label = r["label"]
		if lbl == null or not is_instance_valid(lbl):
			continue
		var remaining: int = int(r["return_at"]) - now
		if remaining <= 0:
			lbl.text = tr("ready — claim in Hub")
			lbl.add_theme_color_override("font_color", COL_GREEN)
		else:
			lbl.text = tr("returns in %s") % _fmt_mmss(remaining)
			lbl.add_theme_color_override("font_color", COL_AMBER)


## Formats seconds as mm:ss.
func _fmt_mmss(seconds: int) -> String:
	var s: int = maxi(seconds, 0)
	return "%d:%02d" % [s / 60, s % 60]


## A small inline status chip (EQUIPPED / INSURED / BROKEN tags).
func _make_chip(text: String, color: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UIStyle.chip(color))
	pc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", 13)
	pc.add_child(lbl)
	return pc


# ---------------------------------------------------------------- refresh
## Full state sync from MetaProgression + Stash. Called on _ready + stash_changed.
func _refresh() -> void:
	_selected = Array(MetaProgression.get_loadout(), TYPE_STRING, "", null)
	_bring = MetaProgression.get_bring()
	_refresh_weapon_rows()
	_rebuild_consumable_rows()
	_refresh_consume_rows()
	_rebuild_equipment()


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
	# Stash changed → owned-armor list may differ.
	_rebuild_equipment()


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


# ---------------------------------------------------------------- equipment handlers
## gear_changed / insurance_changed → rebuild the whole equipment section.
func _on_gear_changed() -> void:
	_rebuild_equipment()


## armor_changed(id, durability, broken) → durability/broken state changed; rebuild.
func _on_armor_changed(_id: String, _durability: float, _broken: bool) -> void:
	_rebuild_equipment()


## Equip an owned armor piece into its slot.
func _on_equip_armor(slot_id: String, id: String) -> void:
	if slot_id.is_empty() or not MetaProgression.has_method("set_equipped_gear"):
		return
	MetaProgression.set_equipped_gear(slot_id, id)
	# gear_changed fires from set_equipped_gear; _on_gear_changed rebuilds.


## Unequip the piece in a slot ("" clears it).
func _on_unequip_gear(slot_id: String) -> void:
	if not MetaProgression.has_method("set_equipped_gear"):
		return
	MetaProgression.set_equipped_gear(slot_id, "")


## Repair an equipped armor piece (MetaProgression handles affordability + spend).
func _on_repair_gear(id: String) -> void:
	if MetaProgression.has_method("repair_armor"):
		MetaProgression.repair_armor(id)
	# armor_changed fires on success; _on_armor_changed rebuilds.


## Insure an equipped piece (MetaProgression handles affordability + spend).
func _on_insure_gear(id: String) -> void:
	if MetaProgression.has_method("insure_item"):
		MetaProgression.insure_item(id)
	# insurance_changed fires on success; _on_gear_changed rebuilds.
