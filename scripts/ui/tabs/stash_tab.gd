extends Control
class_name StashTab
## The STASH tab in the Hub. Shows the player's persistent extracted items and
## allows selling, recycling, or bulk-managing them.
##
## Data sources:
##   Stash.items          -> Array[{ id: String, count: int }]
##   ItemCatalog.get_item -> ItemData (display_name, value, rarity, description, …)
##   MetaProgression.earn -> deposit currency from a sell
##   Crafting.recycle     -> per-item material yield (real data-driven recipes)
##
## Actions per slot (popup):
##   SELL 1    – remove 1 from stash, earn ItemData.value
##   SELL ALL  – remove the whole stack, earn value * count
##   RECYCLE 1 – remove 1, grant its Crafting.recycle() material yield
##
## Bulk QoL actions (footer buttons):
##   SORT          – re-render grid sorted by item value desc (display-only reorder)
##   SELL ALL JUNK – sell every COMMON-rarity MATERIAL stack
##   RECYCLE ALL   – recycle every MATERIAL that has a Crafting.RECYCLE entry or a
##                   non-zero value; leaves CONSUMABLE and WEAPON stacks untouched

# ------------------------------------------------------------------ scene nodes
@onready var _header_value_label: Label = %HeaderValueLabel
@onready var _grid: GridContainer = %ItemGrid
@onready var _empty_label: Label = %EmptyLabel
# Action popup (created programmatically, reused across slots)
var _popup: PopupMenu = null
# Track which slot's item the popup refers to.
var _popup_item_id: String = ""
var _popup_item_count: int = 0
# Capacity bar — built once in _ready, refreshed in _refresh().
var _cap_bar: ProgressBar = null
var _cap_label: Label = null

const SLOT_SIZE := Vector2(64, 64)
const GRID_COLS := 6

# PopupMenu item ids
const _ACT_SELL_ONE := 0
const _ACT_SELL_ALL := 1
const _ACT_RECYCLE := 2

# Sort state — when true the grid is sorted by value desc instead of stash order.
var _sorted: bool = false


func _ready() -> void:
	_grid.columns = GRID_COLS
	_build_popup()
	_build_capacity_bar()
	_build_footer()
	Events.stash_changed.connect(_refresh)
	Events.currency_changed.connect(_on_currency_changed)
	# Apply Russo One to the scene-defined header value label.
	if _header_value_label != null:
		UIStyle.make_header(_header_value_label, UIStyle.AMBER, 18, 2)
	_refresh()


# ------------------------------------------------------------------ popup setup
func _build_popup() -> void:
	_popup = PopupMenu.new()
	add_child(_popup)
	_popup.add_item(tr("Sell 1"), _ACT_SELL_ONE)
	_popup.add_item(tr("Sell All"), _ACT_SELL_ALL)
	_popup.add_item(tr("Recycle 1"), _ACT_RECYCLE)
	_popup.id_pressed.connect(_on_popup_action)


# ------------------------------------------------------------------ capacity bar
## Inserts a weight/capacity bar + label between the separator and the scroll view.
## Layout VBox order after this call: Header, HSeparator, CapacityRow, ScrollContainer, EmptyLabel.
func _build_capacity_bar() -> void:
	var layout: VBoxContainer = get_node_or_null("Layout") as VBoxContainer
	if layout == null:
		return

	# Container row: bar + kg label side-by-side.
	var cap_row := HBoxContainer.new()
	cap_row.name = "CapacityRow"
	cap_row.add_theme_constant_override("separation", 8)

	_cap_bar = ProgressBar.new()
	_cap_bar.name = "CapacityBar"
	_cap_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cap_bar.custom_minimum_size = Vector2(0, 10)
	_cap_bar.min_value = 0.0
	_cap_bar.max_value = 200.0  # 200 = 100% of cap (doubled for overflow display)
	_cap_bar.value = 0.0
	_cap_bar.show_percentage = false
	_cap_bar.theme_type_variation = "FillAmber"
	cap_row.add_child(_cap_bar)

	_cap_label = Label.new()
	_cap_label.name = "CapacityLabel"
	_cap_label.custom_minimum_size = Vector2(120, 0)
	_cap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cap_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cap_label.add_theme_font_size_override("font_size", 13)
	cap_row.add_child(_cap_label)

	# Insert just after the HSeparator (index 2 in the Layout VBox: Header=0, Sep=1).
	var sep := layout.get_node_or_null("HSeparator")
	var insert_at := (sep.get_index() + 1) if sep != null else layout.get_child_count()
	layout.add_child(cap_row)
	layout.move_child(cap_row, insert_at)


## Refreshes the capacity bar colours and text to reflect the live stash weight.
## Called from _refresh() so it stays in sync with every stash_changed signal.
func _refresh_capacity() -> void:
	if _cap_bar == null or _cap_label == null:
		return
	var w := Stash.total_weight()
	var cap := Stash.capacity()
	var ratio := clampf(w / cap, 0.0, 2.0) if cap > 0.0 else 1.0
	_cap_bar.value = ratio * 100.0
	var over := w > cap
	var fill_col: Color = UIStyle.RED if over else UIStyle.GREEN
	_cap_bar.add_theme_stylebox_override("fill", UIStyle.glow_fill(fill_col))
	_cap_label.text = tr("%.1f / %.1f kg") % [w, cap]
	_cap_label.add_theme_color_override(
		"font_color", Color(0.90, 0.20, 0.20) if over else Color(0.55, 0.75, 0.55)
	)


# ------------------------------------------------------------------ footer QoL buttons
## Appends a footer HBox with SORT, SELL ALL JUNK, and RECYCLE ALL buttons to
## the Layout VBox that owns this tab's scene content.
func _build_footer() -> void:
	# Find the "Layout" VBoxContainer — parent of the scene-defined nodes.
	var layout: VBoxContainer = get_node_or_null("Layout") as VBoxContainer
	if layout == null:
		return

	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 4)
	layout.add_child(sep)

	var footer := HBoxContainer.new()
	footer.name = "FooterActions"
	footer.add_theme_constant_override("separation", 8)
	layout.add_child(footer)

	# Spacer pushes buttons to the right.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var sort_btn := Button.new()
	sort_btn.name = "SortBtn"
	sort_btn.text = tr("SORT")
	sort_btn.custom_minimum_size = Vector2(80, 28)
	sort_btn.tooltip_text = tr("Toggle sort by value (high → low)")
	sort_btn.pressed.connect(_on_sort_pressed)
	UIStyle.hover_lift(sort_btn)
	footer.add_child(sort_btn)

	var sell_junk_btn := Button.new()
	sell_junk_btn.name = "SellJunkBtn"
	sell_junk_btn.text = tr("SELL ALL JUNK")
	sell_junk_btn.custom_minimum_size = Vector2(120, 28)
	sell_junk_btn.tooltip_text = tr("Sell every Common-rarity Material stack")
	sell_junk_btn.pressed.connect(_on_sell_all_junk_pressed)
	UIStyle.hover_lift(sell_junk_btn)
	UIStyle.danger(sell_junk_btn)
	footer.add_child(sell_junk_btn)

	var recycle_all_btn := Button.new()
	recycle_all_btn.name = "RecycleAllBtn"
	recycle_all_btn.text = tr("RECYCLE ALL")
	recycle_all_btn.custom_minimum_size = Vector2(110, 28)
	recycle_all_btn.tooltip_text = tr("Recycle every Material stack (leaves consumables & weapons)")
	recycle_all_btn.pressed.connect(_on_recycle_all_pressed)
	UIStyle.hover_lift(recycle_all_btn)
	UIStyle.danger(recycle_all_btn)
	footer.add_child(recycle_all_btn)


# ------------------------------------------------------------------ signal handlers
func _on_currency_changed(_amount: int) -> void:
	## Refresh the header value when currency changes (sell ripple).
	_refresh_header()


func _refresh() -> void:
	if not is_inside_tree():
		return
	_clear_grid()
	_refresh_header()
	_refresh_capacity()

	if Stash.is_empty():
		_empty_label.visible = true
		_grid.visible = false
		return

	_empty_label.visible = false
	_grid.visible = true

	# Build a working copy of items so sorting does not mutate Stash.items order.
	var display_items: Array = Stash.items.duplicate()
	if _sorted:
		display_items.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return ItemCatalog.value_of(String(a["id"])) > ItemCatalog.value_of(String(b["id"]))
		)

	for entry in display_items:
		var id: String = String(entry["id"])
		var cnt: int = int(entry["count"])
		var item: ItemData = ItemCatalog.get_item(id)  # may be null for unknown ids
		_grid.add_child(_make_slot(id, cnt, item))


# ------------------------------------------------------------------ header
func _refresh_header() -> void:
	_header_value_label.text = tr("Total value: %d") % Stash.total_value()


# ------------------------------------------------------------------ grid helpers
func _clear_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()


## Builds one 64×64 slot Panel. Mirrors the style from inventory_ui.gd _make_slot().
## `item` may be null for unrecognised ids — the slot degrades gracefully.
func _make_slot(id: String, cnt: int, item: ItemData) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.add_theme_stylebox_override("panel", _slot_stylebox(item))
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

	# Tooltip: name / rarity / value / description (plain text; no BBCode in tooltips).
	slot.tooltip_text = _tooltip_for(id, item)

	# Left-click opens the action popup.
	slot.gui_input.connect(_on_slot_input.bind(id, cnt))

	# Icon or colored-box fallback.
	var icon: Texture2D = AssetRegistry.get_icon(id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = 6
		tex.offset_top = 6
		tex.offset_right = -6
		tex.offset_bottom = -6
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 8
		box.offset_top = 8
		box.offset_right = -8
		box.offset_bottom = -8
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(box)

	# Count badge bottom-right (always shown so the player sees stack size).
	var badge := Label.new()
	badge.text = "x%d" % cnt
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_preset(Control.PRESET_FULL_RECT)
	badge.add_theme_color_override("font_color", Color.WHITE)
	badge.add_theme_color_override("font_outline_color", Color.BLACK)
	badge.add_theme_constant_override("outline_size", 4)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(badge)

	return slot


## Dark slot fill with a rarity-colored border (matches inventory_ui.gd style).
func _slot_stylebox(item: ItemData) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = item.rarity_color() if item != null else Color(0.62, 0.62, 0.66)
	sb.set_corner_radius_all(4)
	return sb


## Rich tooltip: name + rarity + value + description. Degrades when ItemData is null.
func _tooltip_for(id: String, item: ItemData) -> String:
	if item == null:
		return tr("%s\n[Unknown item]") % id
	return (
		tr("%s\n[%s]\nValue: %d\n\n%s")
		% [
			tr(item.display_name),
			tr(item.rarity_name()),
			item.value,
			tr(item.description),
		]
	)


# ------------------------------------------------------------------ slot input
func _on_slot_input(event: InputEvent, id: String, cnt: int) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_popup_item_id = id
			_popup_item_count = cnt
			# Grey out SELL actions when ItemData is missing (no value known).
			var item: ItemData = ItemCatalog.get_item(id)
			_popup.set_item_disabled(_popup.get_item_index(_ACT_SELL_ONE), item == null)
			_popup.set_item_disabled(_popup.get_item_index(_ACT_SELL_ALL), item == null)
			_popup.reset_size()
			_popup.position = Vector2i(get_viewport().get_mouse_position())
			_popup.popup()
			accept_event()


# ------------------------------------------------------------------ actions
func _on_popup_action(action_id: int) -> void:
	var id: String = _popup_item_id
	var cnt: int = _popup_item_count
	if id.is_empty():
		return
	var item: ItemData = ItemCatalog.get_item(id)

	match action_id:
		_ACT_SELL_ONE:
			_sell(id, 1, item)
		_ACT_SELL_ALL:
			_sell(id, cnt, item)
		_ACT_RECYCLE:
			_recycle_one(id)

	_popup_item_id = ""
	_popup_item_count = 0


## Remove `n` of `id`, deposit value into MetaProgression currency.
func _sell(id: String, n: int, item: ItemData) -> void:
	if item == null:
		return
	var removed: int = Stash.remove(id, n)
	if removed > 0:
		MetaProgression.earn(item.value * removed)
	# stash_changed + currency_changed signals fire automatically via Stash/MetaProgression.


## Remove 1 of `id` and grant its Crafting.recycle() material yield.
## The Crafting autoload handles the material grants and Stash mutations;
## stash_changed fires automatically so the UI refreshes.
func _recycle_one(id: String) -> void:
	Crafting.recycle(id)
	# stash_changed fires from inside Crafting.recycle(); UI refreshes.


# ------------------------------------------------------------------ QoL actions


## Toggle the sort-by-value-desc display order and re-render the grid.
func _on_sort_pressed() -> void:
	_sorted = not _sorted
	_refresh()


## Sell every COMMON-rarity MATERIAL stack in the stash.
## Other rarities (Uncommon+ materials, consumables, weapons) are left alone.
func _on_sell_all_junk_pressed() -> void:
	# Snapshot the ids to sell before mutating the stash.
	var to_sell: Array[String] = []
	for entry in Stash.items:
		var id: String = String(entry["id"])
		var item: ItemData = ItemCatalog.get_item(id)
		if item == null:
			continue
		# Rule: COMMON-rarity MATERIAL stacks qualify as "junk".
		if item.kind == ItemData.Kind.MATERIAL and item.rarity == ItemData.Rarity.COMMON:
			to_sell.append(id)

	for id in to_sell:
		var cnt: int = Stash.count_of(id)
		if cnt <= 0:
			continue
		var item: ItemData = ItemCatalog.get_item(id)
		_sell(id, cnt, item)


## Recycle every MATERIAL stack that either has an explicit Crafting.RECYCLE
## entry or carries a non-zero sale value (so it produces scrap via the
## fallback formula). Consumables, Weapons, and Key items are left untouched.
func _on_recycle_all_pressed() -> void:
	# Snapshot ids before the stash changes.
	var to_recycle: Array[String] = []
	for entry in Stash.items:
		var id: String = String(entry["id"])
		var item: ItemData = ItemCatalog.get_item(id)
		# Rule: only MATERIAL kind; skip consumables/weapons/keys.
		if item == null or item.kind != ItemData.Kind.MATERIAL:
			continue
		# Accept any material — those without a RECYCLE entry fall back to
		# scrap (Crafting.recycle fallback formula), which is still useful.
		to_recycle.append(id)

	for id in to_recycle:
		# Recycle the whole stack one unit at a time (recycle() removes 1 per call).
		var cnt: int = Stash.count_of(id)
		for _i in cnt:
			Crafting.recycle(id)
