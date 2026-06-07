extends CanvasLayer
class_name HaulManager
## Manage-Your-Haul screen — shown when an extraction deposits loot that puts the
## stash over its weight capacity. The player must sell, recycle, or drop items
## until the stash is back under cap, then confirm to dismiss the screen.
##
## Lifecycle:
##   • The lead instantiates this once in main.gd's load_arena and adds it to the
##     scene tree; it starts HIDDEN.
##   • Events.haul_overflow(incoming, over_by) shows it automatically.
##   • After the player confirms (weight <= cap), `haul_resolved` is emitted and
##     the screen hides itself. The lead may also connect that signal.

signal haul_resolved()

# ------------------------------------------------------------------ scene refs
@onready var _root: Control        = $Root
@onready var _scrim: Panel         = $Root/Scrim
@onready var _weight_bar: ProgressBar = $Root/Panel/VBox/WeightBar
@onready var _weight_label: Label  = $Root/Panel/VBox/WeightLabel
@onready var _item_list: VBoxContainer = $Root/Panel/VBox/Scroll/ItemList
@onready var _confirm_btn: Button  = $Root/Panel/VBox/ConfirmBtn

const SLOT_ICON_SIZE := Vector2(40, 40)
const _COL_RED  := Color(0.90, 0.20, 0.20)
const _COL_OK   := Color(0.20, 0.75, 0.35)

func _ready() -> void:
	Events.haul_overflow.connect(_on_haul_overflow)
	Events.stash_changed.connect(_refresh)
	_confirm_btn.pressed.connect(_on_confirm_pressed)
	_root.visible = false
	_apply_glass_style()

## Apply military-glass look: backdrop, panel stylebox, title, hover on confirm.
func _apply_glass_style() -> void:
	# GlassBackdrop behind everything in _root.
	var bg := GlassBackdrop.new()
	_root.add_child(bg)
	_root.move_child(bg, 0)

	# Panel glass stylebox with amber accent header bar.
	var panel: PanelContainer = $Root/Panel
	if panel != null:
		panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.AMBER, 0.92))

	# Title label: find the first Label child of the panel VBox and make it a header.
	var vbox: VBoxContainer = $Root/Panel/VBox
	if vbox != null:
		for child in vbox.get_children():
			if child is Label:
				UIStyle.make_header(child as Label, UIStyle.AMBER, 22, 3)
				break

	# Confirm button hover lift.
	UIStyle.hover_lift(_confirm_btn)

# ------------------------------------------------------------------ show/hide
func _on_haul_overflow(_incoming: Array, _over_by: float) -> void:
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()
	var panel: Panel = $Root/Panel
	if panel != null:
		UIStyle.pop_in(panel, UIStyle.Dir.DOWN, 14.0, 0.16)

func _on_confirm_pressed() -> void:
	_root.visible = false
	haul_resolved.emit()

# ------------------------------------------------------------------ refresh
func _refresh() -> void:
	if not is_inside_tree() or not _root.visible:
		return
	_refresh_weight()
	_rebuild_list()
	_confirm_btn.disabled = Stash.total_weight() > Stash.capacity()

func _refresh_weight() -> void:
	var w   := Stash.total_weight()
	var cap := Stash.capacity()
	var ratio := clampf(w / cap, 0.0, 2.0) if cap > 0.0 else 1.0
	_weight_bar.value = ratio * 100.0
	_weight_label.text = tr("%.1f / %.1f kg") % [w, cap]
	var over := w > cap
	_weight_label.add_theme_color_override("font_color", _COL_RED if over else _COL_OK)
	# Tint the fill colour of the ProgressBar via a StyleBoxFlat on "fill".
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = _COL_RED if over else _COL_OK
	fill_sb.set_corner_radius_all(3)
	_weight_bar.add_theme_stylebox_override("fill", fill_sb)

## Rebuilds the item rows. Called on every stash_changed so buttons always
## reflect the live stash contents.
func _rebuild_list() -> void:
	for c in _item_list.get_children():
		c.queue_free()

	for entry in Stash.items:
		var id:  String   = String(entry["id"])
		var cnt: int      = int(entry["count"])
		var item: ItemData = ItemCatalog.get_item(id)
		_item_list.add_child(_make_row(id, cnt, item))

# ------------------------------------------------------------------ row builder
## One row in the list: icon | name + ×count + weight | SELL | RECYCLE | DROP
func _make_row(id: String, cnt: int, item: ItemData) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	# --- icon box (matches stash_tab._make_slot style, shrunk to 40×40) ---
	var icon_panel := Panel.new()
	icon_panel.custom_minimum_size = SLOT_ICON_SIZE
	icon_panel.add_theme_stylebox_override("panel", _slot_stylebox(item))
	icon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon: Texture2D = AssetRegistry.get_icon(id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture      = icon
		tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left   = 4
		tex.offset_top    = 4
		tex.offset_right  = -4
		tex.offset_bottom = -4
		tex.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		icon_panel.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left   = 5
		box.offset_top    = 5
		box.offset_right  = -5
		box.offset_bottom = -5
		box.mouse_filter  = Control.MOUSE_FILTER_IGNORE
		icon_panel.add_child(box)

	row.add_child(icon_panel)

	# --- name / count / weight label ---
	var name_lbl := Label.new()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var display := (item.display_name if item else id)
	var wt_each := (item.weight if item else 0.0)
	name_lbl.text = tr("%s  ×%d  (%.1f kg)") % [display, cnt, wt_each * cnt]
	name_lbl.add_theme_color_override("font_color",
		item.rarity_color() if item != null else Color(0.75, 0.75, 0.8))
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	# --- action buttons ---
	var can_sell := item != null

	var sell_btn := Button.new()
	sell_btn.text = "SELL"
	sell_btn.custom_minimum_size = Vector2(60, 28)
	sell_btn.disabled = not can_sell
	sell_btn.tooltip_text = (tr("Sell 1 for %d CR") % item.value) if can_sell else tr("No value")
	sell_btn.pressed.connect(_on_sell.bind(id, item))
	row.add_child(sell_btn)

	var recycle_btn := Button.new()
	recycle_btn.text = "RECYCLE"
	recycle_btn.custom_minimum_size = Vector2(80, 28)
	recycle_btn.tooltip_text = tr("Recycle 1 into materials")
	recycle_btn.pressed.connect(_on_recycle.bind(id))
	row.add_child(recycle_btn)

	var drop_btn := Button.new()
	drop_btn.text = "DROP"
	drop_btn.custom_minimum_size = Vector2(60, 28)
	drop_btn.tooltip_text = tr("Discard 1 (no payout)")
	drop_btn.pressed.connect(_on_drop.bind(id))
	row.add_child(drop_btn)

	return row

## Dark slot fill with a rarity-colored border — mirrors stash_tab._slot_stylebox.
func _slot_stylebox(item: ItemData) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = item.rarity_color() if item != null else Color(0.62, 0.62, 0.66)
	sb.set_corner_radius_all(4)
	return sb

# ------------------------------------------------------------------ actions
func _on_sell(id: String, item: ItemData) -> void:
	if item == null:
		return
	var removed: int = Stash.remove(id, 1)
	if removed > 0:
		MetaProgression.earn(item.value * removed)
	# stash_changed fires from Stash.remove -> _refresh runs automatically.

func _on_recycle(id: String) -> void:
	Crafting.recycle(id)
	# stash_changed fires from inside Crafting.recycle(); _refresh runs automatically.

func _on_drop(id: String) -> void:
	Stash.remove(id, 1)
	# stash_changed fires; _refresh runs automatically.
