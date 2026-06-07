extends Control
class_name InventoryUI
## Grid inventory overlay for the LOCAL player. Renders Inventory.stacks into a
## GridContainer (Settings.INVENTORY_COLS wide), each slot showing the item's
## icon (AssetRegistry.get_icon) or a tinted box fallback plus a count badge and
## a rarity-colored border. Shows a weight bar (total_weight /
## INVENTORY_MAX_WEIGHT) and total value.
##
## Header: SORT OptionButton (Name/Weight/Value/Rarity -> Inventory.sort_stacks)
## and FILTER tabs (All/Weapons/Materials/Consumables) that restrict the grid by
## ItemData.kind. Each slot has a rich tooltip and a right-click context menu
## (Use for consumables, Drop for anything) wired through Events / LootPickup.
##
## Binding: listens to Events.local_player_spawned to find its player, then
## refreshes on Events.inventory_changed. Starts hidden; "toggle_inventory"
## shows/hides it. While open the mouse is freed so slots are clickable. Self-
## installs at the scene-tree root if not already parented by a HUD.

@onready var _grid: GridContainer = $Panel/Margin/VBox/Grid
@onready var _sort_option: OptionButton = $Panel/Margin/VBox/Header/SortOption
@onready var _filter_all: Button = $Panel/Margin/VBox/Filters/FilterAll
@onready var _filter_weapons: Button = $Panel/Margin/VBox/Filters/FilterWeapons
@onready var _filter_materials: Button = $Panel/Margin/VBox/Filters/FilterMaterials
@onready var _filter_consumables: Button = $Panel/Margin/VBox/Filters/FilterConsumables
@onready var _weight_bar: ProgressBar = $Panel/Margin/VBox/Footer/WeightBar
@onready var _weight_label: Label = $Panel/Margin/VBox/Footer/WeightBar/WeightLabel
@onready var _value_label: Label = $Panel/Margin/VBox/Footer/ValueLabel

const SLOT_SIZE := Vector2(64, 64)

# Sort modes for the OptionButton, in display order. Index -> Inventory.sort_stacks mode.
const SORT_MODES := ["name", "weight", "value", "rarity"]
const SORT_LABELS := ["Name", "Weight", "Value", "Rarity"]

var _player: Node = null
var _inventory: Inventory = null

# Active kind filter: -1 = all, else an ItemData.Kind value.
var _filter_kind: int = -1

# Right-click context menu (reused across slots) + the stack it targets.
var _context_menu: PopupMenu = null
var _context_item: ItemData = null
var _context_count: int = 0

func _ready() -> void:
	visible = false
	_grid.columns = Settings.INVENTORY_COLS
	_weight_bar.min_value = 0.0
	_weight_bar.max_value = Settings.INVENTORY_MAX_WEIGHT
	# Center the weight label over the bar and hide the % text so they don't overlap.
	_weight_bar.show_percentage = false
	_weight_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_weight_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_weight_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_weight_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_setup_sort_option()
	_setup_filters()
	_setup_context_menu()

	Events.local_player_spawned.connect(_on_local_player_spawned)
	Events.inventory_changed.connect(_on_inventory_changed)

	# A player may already exist (UI added after spawn) — try to bind now.
	if _player == null:
		_bind_to_existing_player()
	_refresh()

func _setup_sort_option() -> void:
	_sort_option.clear()
	for label in SORT_LABELS:
		_sort_option.add_item(label)
	_sort_option.item_selected.connect(_on_sort_selected)

func _setup_filters() -> void:
	# Manual radio behavior so exactly one filter is active at a time.
	_filter_all.pressed.connect(_on_filter_pressed.bind(-1, _filter_all))
	_filter_weapons.pressed.connect(_on_filter_pressed.bind(ItemData.Kind.WEAPON, _filter_weapons))
	_filter_materials.pressed.connect(_on_filter_pressed.bind(ItemData.Kind.MATERIAL, _filter_materials))
	_filter_consumables.pressed.connect(_on_filter_pressed.bind(ItemData.Kind.CONSUMABLE, _filter_consumables))

func _setup_context_menu() -> void:
	_context_menu = PopupMenu.new()
	add_child(_context_menu)
	_context_menu.id_pressed.connect(_on_context_id_pressed)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory"):
		_set_open(not visible)
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("ui_cancel"):
		_set_open(false)
		get_viewport().set_input_as_handled()

## Opens/closes the panel and toggles the mouse mode so slots are clickable while
## open. Frees the cursor on open; recaptures on close unless the game is paused
## (the pause menu owns the cursor in that case).
func _set_open(open: bool) -> void:
	visible = open
	if open:
		_refresh()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if _context_menu != null:
			_context_menu.hide()
		if not get_tree().paused:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_sort_selected(index: int) -> void:
	if _inventory == null or index < 0 or index >= SORT_MODES.size():
		return
	# sort_stacks emits inventory_changed, which triggers _refresh().
	_inventory.sort_stacks(SORT_MODES[index])

func _on_filter_pressed(kind: int, btn: Button) -> void:
	_filter_kind = kind
	# Enforce single-selection: this button on, the rest off.
	for b in [_filter_all, _filter_weapons, _filter_materials, _filter_consumables]:
		b.button_pressed = (b == btn)
	_refresh()

func _on_local_player_spawned(player: Node) -> void:
	_bind(player)

func _bind_to_existing_player() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if _is_local(p):
			_bind(p)
			return

func _bind(player: Node) -> void:
	if not is_instance_valid(player):
		return
	_player = player
	_inventory = _find_inventory(player)
	_refresh()

func _on_inventory_changed(inv: Node) -> void:
	# Only react to our own player's inventory; bind lazily if we have none yet.
	if _inventory == null and _player != null:
		_inventory = _find_inventory(_player)
	if inv == _inventory:
		_refresh()

func _refresh() -> void:
	if not is_inside_tree():
		return
	_clear_grid()
	var stacks: Array = _visible_stacks()
	for s in stacks:
		var item: ItemData = s.get("item", null)
		var cnt: int = int(s.get("count", 0))
		if item == null:
			continue
		_grid.add_child(_make_slot(item, cnt))
	_update_footer()

## The stacks to render given the active kind filter. Footer totals always use
## the full inventory, not the filtered view.
func _visible_stacks() -> Array:
	if _inventory == null:
		return []
	if _filter_kind < 0:
		return _inventory.stacks
	return _inventory.filter_by_kind(_filter_kind)

func _update_footer() -> void:
	var weight := _inventory.total_weight() if _inventory != null else 0.0
	var value := _inventory.total_value() if _inventory != null else 0
	_weight_bar.value = weight
	_weight_label.text = tr("%.1f / %.0f kg") % [weight, Settings.INVENTORY_MAX_WEIGHT]
	_value_label.text = tr("Value: %d") % value

func _clear_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()

## Builds one slot: icon texture if present, else a color box; a rarity-colored
## border; a count badge for stacks > 1; a rich tooltip; and a right-click
## context menu (Use / Drop).
func _make_slot(item: ItemData, cnt: int) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.tooltip_text = _tooltip_for(item)
	slot.add_theme_stylebox_override("panel", _slot_stylebox(item))
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_slot_gui_input.bind(item, cnt))

	var icon := AssetRegistry.get_icon(item.id)
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
		box.color = AssetRegistry.get_color(item.id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 8
		box.offset_top = 8
		box.offset_right = -8
		box.offset_bottom = -8
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(box)

	if cnt > 1:
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

## A dark slot fill with a rarity-colored border.
func _slot_stylebox(item: ItemData) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = item.rarity_color()
	sb.set_corner_radius_all(4)
	return sb

## Rich tooltip text: name + rarity tier + weight + value + description. The name
## line is BBCode-free (Control tooltips are plain), but we still surface rarity.
func _tooltip_for(item: ItemData) -> String:
	return tr("%s\n[%s]\nWeight: %.1f kg\nValue: %d\n\n%s") % [
		item.display_name,
		item.rarity_name(),
		item.weight,
		item.value,
		item.description,
	]

## Per-slot input: right-click opens the context menu for that stack.
func _on_slot_gui_input(event: InputEvent, item: ItemData, cnt: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_open_context_menu(item, cnt)
		accept_event()

func _open_context_menu(item: ItemData, cnt: int) -> void:
	_context_item = item
	_context_count = cnt
	_context_menu.clear()
	# id 0 = Use (consumables only), id 1 = Drop, id 2 = Split, id 3 = Give.
	if item.kind == ItemData.Kind.CONSUMABLE:
		_context_menu.add_item(tr("Use"), 0)
	_context_menu.add_item(tr("Drop"), 1)
	# Split: only meaningful when there's more than one to split off.
	if cnt >= 2:
		_context_menu.add_item(tr("Split"), 2)
	# Give the whole stack to the nearest teammate; disabled (or omitted) when alone.
	var to: int = NetworkManager.nearest_teammate(GameState.local_peer_id())
	if to != 0:
		var mate: Dictionary = GameState.peers.get(to, {})
		var mate_name: String = mate.get("name", "Raider")
		_context_menu.add_item(tr("Give to %s") % mate_name, 3)
	_context_menu.reset_size()
	_context_menu.position = Vector2i(get_viewport().get_mouse_position())
	_context_menu.popup()

func _on_context_id_pressed(id: int) -> void:
	if _context_item == null:
		return
	match id:
		0:
			_use_item(_context_item)
		1:
			_drop_item(_context_item, _context_count)
		2:
			_split_item(_context_item, _context_count)
		3:
			_give_item(_context_item, _context_count)
	_context_item = null
	_context_count = 0

## Use one of a consumable: fire the item_use_requested intent so the player's
## systems apply the effect, then remove one from the inventory. Guarded to the
## authority (single-player is authority).
func _use_item(item: ItemData) -> void:
	if not GameState.is_local_authority_server():
		return
	Events.item_use_requested.emit(item.id)
	if _inventory != null:
		_inventory.remove_item(item.id, 1)

## Drop the whole stack as a world LootPickup near the player, then remove it from
## the inventory. Authority-guarded; needs a bound player for the spawn position.
func _drop_item(item: ItemData, count: int) -> void:
	if not GameState.is_local_authority_server():
		return
	if not is_instance_valid(_player):
		return
	var parent := _drop_parent()
	if parent == null:
		return
	var origin: Vector3 = _player.global_position if _player is Node3D else Vector3.ZERO
	# Small forward/offset so the pickup doesn't spawn exactly inside the player.
	var pos := origin + Vector3(0.0, 0.5, -1.0)
	LootPickup.spawn_at(parent, pos, item.id, count)
	if _inventory != null:
		_inventory.remove_item(item.id, count)

## Split half the stack off into a new separate stack via the server-authoritative
## NetworkManager.request_split (works in single-player too). Do not mutate
## inv.stacks directly — the owner-mirror fires inventory_changed and we rebuild.
func _split_item(item: ItemData, count: int) -> void:
	if count < 2:
		return
	var half: int = int(count / 2)
	if half < 1:
		return
	NetworkManager.request_split(GameState.local_peer_id(), item.id, half)

## Give the whole stack to the nearest teammate via the server-authoritative
## NetworkManager.transfer_item. The server moves the items and re-mirrors both
## inventories — do not mutate local stacks here.
func _give_item(item: ItemData, count: int) -> void:
	var to: int = NetworkManager.nearest_teammate(GameState.local_peer_id())
	if to == 0:
		return
	NetworkManager.transfer_item(GameState.local_peer_id(), to, item.id, count)

## Where dropped pickups live. Prefer the same parent existing pickups use
## (their group is "pickups"); fall back to the current scene root.
func _drop_parent() -> Node:
	for p in get_tree().get_nodes_in_group("pickups"):
		if is_instance_valid(p) and p.get_parent() != null:
			return p.get_parent()
	return get_tree().current_scene

func _is_local(player: Node) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return player.get_multiplayer_authority() == multiplayer.get_unique_id()

func _find_inventory(player: Node) -> Inventory:
	var named := player.get_node_or_null("Inventory")
	if named is Inventory:
		return named
	for c in player.get_children():
		if c is Inventory:
			return c
	return null

# ----------------------------------------------------------------- install helper
## Instantiates InventoryUI and adds it under `host` (e.g. the local player's HUD
## CanvasLayer, or the local player itself). Returns the new InventoryUI. The UI
## binds itself to the local player via Events.local_player_spawned, so it is safe
## to add before or after the player spawns.
static func install(host: Node) -> InventoryUI:
	if host == null:
		return null
	var packed := load("res://scenes/ui/InventoryUI.tscn") as PackedScene
	if packed == null:
		return null
	var ui := packed.instantiate() as InventoryUI
	host.add_child(ui)
	return ui
