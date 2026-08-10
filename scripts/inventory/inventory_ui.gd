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
@onready var _header: HBoxContainer = $Panel/Margin/VBox/Header
@onready var _sort_option: OptionButton = $Panel/Margin/VBox/Header/SortOption
@onready var _filter_all: Button = $Panel/Margin/VBox/Filters/FilterAll
@onready var _filter_weapons: Button = $Panel/Margin/VBox/Filters/FilterWeapons
@onready var _filter_materials: Button = $Panel/Margin/VBox/Filters/FilterMaterials
@onready var _filter_consumables: Button = $Panel/Margin/VBox/Filters/FilterConsumables
@onready var _weight_bar: ProgressBar = $Panel/Margin/VBox/Footer/WeightBar
@onready var _weight_label: Label = $Panel/Margin/VBox/Footer/WeightBar/WeightLabel
@onready var _value_label: Label = $Panel/Margin/VBox/Footer/ValueLabel

const SLOT_SIZE := Vector2(64, 64)
# Minimum visible cells — items + dim placeholders pad up to this count (and to a
# full row) so the grid reads as a CONTAINER, not items floating in a void.
const PLACEHOLDER_MIN_CELLS := 24

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

# Secure-pouch header counter ("SECURE n/2"): a chip Label built at _ready and
# inserted into the Header HBox. Updated on every refresh.
var _secure_chip: Label = null

# Item ids wanted elsewhere in the meta loop — rebuilt each _refresh (tiny data).
# _craft_needed: input of an UNLOCKED recipe, or a schematic that learns one.
# _quest_needed: obj_target of an accepted (or daily) item-objective quest.
var _craft_needed: Dictionary = {}
var _quest_needed: Dictionary = {}

# Empty-state caption under the grid ("pockets empty" / "no items of this type").
var _empty_label: Label = null


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

	# Glass panel stylebox on the root Panel node.
	var root_panel: Panel = get_node_or_null("Panel") as Panel
	if root_panel != null:
		root_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.AMBER, 0.92))

	# Weight bar: amber glow fill to match the glass look.
	_weight_bar.theme_type_variation = "FillAmber"

	_setup_sort_option()
	_setup_filters()
	_setup_context_menu()
	_setup_secure_chip()
	_setup_empty_label()

	Events.local_player_spawned.connect(_on_local_player_spawned)
	Events.inventory_changed.connect(_on_inventory_changed)
	Events.secure_changed.connect(_on_secure_changed)

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
	_filter_materials.pressed.connect(
		_on_filter_pressed.bind(ItemData.Kind.MATERIAL, _filter_materials)
	)
	_filter_consumables.pressed.connect(
		_on_filter_pressed.bind(ItemData.Kind.CONSUMABLE, _filter_consumables)
	)


func _setup_context_menu() -> void:
	_context_menu = PopupMenu.new()
	add_child(_context_menu)
	_context_menu.id_pressed.connect(_on_context_id_pressed)


## Builds the "SECURE n/2" header chip (micro_header face inside a glass chip) and
## inserts it into the Header HBox right after the Title, before the sort controls.
func _setup_secure_chip() -> void:
	if _header == null:
		return
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UIStyle.chip(UIStyle.AMBER))
	wrap.tooltip_text = tr("Secured items survive death (deposited with no bonus)")
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_secure_chip = UIStyle.micro_header(_secure_chip_text(0), UIStyle.AMBER, 12)
	_secure_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wrap.add_child(_secure_chip)
	_header.add_child(wrap)
	# Place the chip just after the Title (index 0), before SortLabel/SortOption.
	_header.move_child(wrap, 1)


func _on_secure_changed(_secure: Dictionary) -> void:
	_refresh()


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
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
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
	_rebuild_needed_sets()
	var stacks: Array = _visible_stacks()
	var shown: int = 0
	for s in stacks:
		var item: ItemData = s.get("item", null)
		var cnt: int = int(s.get("count", 0))
		if item == null:
			continue
		_grid.add_child(_make_slot(item, cnt))
		shown += 1
	# Pad with dim placeholders to a full row and at least PLACEHOLDER_MIN_CELLS.
	var cols: int = maxi(1, _grid.columns)
	var target: int = int(ceil(float(maxi(PLACEHOLDER_MIN_CELLS, shown)) / cols)) * cols
	for _i in range(target - shown):
		_grid.add_child(_make_placeholder_slot())
	_update_empty_label(shown)
	_update_footer()
	_update_secure_chip()


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

	if _secured_count(item.id) > 0:
		slot.add_child(_secure_badge())
	# "Wanted elsewhere" corner markers (Phase 4): quest wins over craft when both.
	if _quest_needed.has(item.id):
		slot.add_child(_corner_marker(UIStyle.AMBER))
	elif _craft_needed.has(item.id):
		slot.add_child(_corner_marker(UIStyle.TEAL))
	return slot


## A dim empty slot (same footprint as _make_slot) — the container-grid feel.
func _make_placeholder_slot() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = SLOT_SIZE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.025)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.06)
	sb.set_corner_radius_all(4)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## Caption under the grid, hidden while there are items to show.
func _setup_empty_label() -> void:
	var vbox: Node = _grid.get_parent()
	if vbox == null:
		return
	_empty_label = UIStyle.caption("")
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.visible = false
	vbox.add_child(_empty_label)
	vbox.move_child(_empty_label, _grid.get_index() + 1)


func _update_empty_label(shown: int) -> void:
	if _empty_label == null:
		return
	_empty_label.visible = shown == 0
	if shown > 0:
		return
	var has_any: bool = _inventory != null and not _inventory.stacks.is_empty()
	if has_any and _filter_kind >= 0:
		_empty_label.text = tr("No items of this type carried.")
	else:
		_empty_label.text = tr(
			"Pockets empty — everything you loot rides here, at risk until you extract."
		)  # gdlint: ignore=max-line-length


## A small corner triangle (top-right) flagging the item as wanted by a quest
## (amber) or an unlocked craft recipe (teal). Drawn — no glyph-font dependency.
func _corner_marker(col: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(14, 14)
	c.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	c.position = Vector2(-16, 2)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(
		func() -> void:
			var pts := PackedVector2Array([Vector2(14, 0), Vector2(14, 12), Vector2(2, 0)])
			c.draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.95))
	)
	return c


## Rebuilds the "wanted elsewhere" id sets. Craft: inputs of every UNLOCKED recipe
## plus schematics that would learn one (don't drop/recycle those). Quest: item
## objectives (extract_item / pickup) of accepted + daily contracts still short of
## their count.
func _rebuild_needed_sets() -> void:
	_craft_needed.clear()
	_quest_needed.clear()
	for r: CraftRecipe in Crafting.all_recipes():
		if Crafting.recipe_unlocked(r):
			for id in r.input_ids:
				_craft_needed[String(id)] = true
		elif r.learn_item != "":
			_craft_needed[r.learn_item] = true
	var wanted: Array = Quests.accepted() + Quests.daily_unclaimed()
	for q: QuestData in wanted:
		if q.obj_type != "extract_item" and q.obj_type != "pickup":
			continue
		if q.obj_target == "" or Quests.is_complete(q):
			continue
		_quest_needed[q.obj_target] = true


## A small amber padlock marker for the top-left of a secured slot. Drawn as a
## shackle + body rect (no glyph-font dependency) so it renders on any platform.
func _secure_badge() -> Control:
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(14, 16)
	pad.position = Vector2(4, 3)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.draw.connect(_draw_padlock.bind(pad))
	return pad


## Renders a tiny padlock into `c` (called from its draw signal): a hollow shackle
## arc above a filled amber body. Kept self-contained so the glyph can't go tofu.
func _draw_padlock(c: Control) -> void:
	var amber: Color = UIStyle.AMBER
	# Body: rounded amber rect in the lower portion.
	c.draw_rect(Rect2(Vector2(1, 7), Vector2(12, 9)), amber, true)
	# Keyhole notch (darker) so it reads as a lock.
	c.draw_rect(Rect2(Vector2(6, 10), Vector2(2, 4)), UIStyle.GLASS_BG, true)
	# Shackle: an arc of amber above the body.
	c.draw_arc(Vector2(7, 7), 4.0, PI, TAU, 10, amber, 2.0, true)


## A dark slot fill with a rarity-colored border. Secured slots get an amber
## border tint + a faintly warmer fill so the lock badge reads as "death-proof".
func _slot_stylebox(item: ItemData) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var secured: bool = _secured_count(item.id) > 0
	if secured:
		sb.bg_color = Color(0.12, 0.094, 0.05, 0.94)
	else:
		sb.bg_color = Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = UIStyle.AMBER if secured else item.rarity_color()
	sb.set_corner_radius_all(4)
	return sb


## Rich tooltip text: name + rarity tier + weight + value + description. The name
## line is BBCode-free (Control tooltips are plain), but we still surface rarity.
## Appends the "wanted elsewhere" lines matching the corner markers.
func _tooltip_for(item: ItemData) -> String:
	var text: String = (
		tr("%s\n[%s]\nWeight: %.1f kg\nValue: %d\n\n%s")
		% [
			item.display_name,
			item.rarity_name(),
			item.weight,
			item.value,
			item.description,
		]
	)
	if _quest_needed.has(item.id):
		text += "\n\n" + tr("▲ Wanted for a quest")
	if _craft_needed.has(item.id):
		text += "\n\n" + tr("▲ Needed for crafting")
	return text


## Per-slot input: right-click opens the context menu for that stack.
func _on_slot_gui_input(event: InputEvent, item: ItemData, cnt: int) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_RIGHT
	):
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
	_add_secure_entry(item)
	_context_menu.reset_size()
	_context_menu.position = Vector2i(get_viewport().get_mouse_position())
	_context_menu.popup()


## Appends the secure-pouch context entry for `item`. Only shown when the pouch
## core is present (inv.request_secure). Already-secured items get tr("Unsecure")
## (id 5); otherwise an eligible item gets tr("Secure") (id 4). Ineligible items
## get a DISABLED reason: tr("Too heavy to secure") (per-unit weight over the
## ceiling) or tr("Pouch full") (all distinct slots taken by other ids).
func _add_secure_entry(item: ItemData) -> void:
	if _inventory == null or not _inventory.has_method("request_secure"):
		return
	var idx: int = _context_menu.item_count
	if _secured_count(item.id) > 0:
		_context_menu.add_item(tr("Unsecure"), 5)
		return
	if not _light_enough(item):
		_context_menu.add_item(tr("Too heavy to secure"), 4)
		_context_menu.set_item_disabled(idx, true)
		return
	if _distinct_secured() >= Settings.SECURE_SLOTS:
		_context_menu.add_item(tr("Pouch full"), 4)
		_context_menu.set_item_disabled(idx, true)
		return
	_context_menu.add_item(tr("Secure"), 4)


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
		4:
			_set_secure(_context_item, true)
		5:
			_set_secure(_context_item, false)
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


## Flags/unflags an item id as secure via the owner-side request_secure entry point
## (works for host AND client). Do not touch inv.secure directly — the server
## clamps + re-mirrors and fires Events.secure_changed, which rebuilds the grid.
func _set_secure(item: ItemData, on: bool) -> void:
	if _inventory == null or not _inventory.has_method("request_secure"):
		return
	_inventory.request_secure(item.id, on)


# ----------------------------------------------------------------- secure pouch
## The secured-counts dict on the bound inventory, or an empty dict when the
## secure-pouch core (other lane) isn't merged yet. Read-only — never mutate here;
## securing goes through the server-authoritative inv.request_secure().
func _secure_map() -> Dictionary:
	if _inventory != null and "secure" in _inventory:
		var s: Variant = _inventory.secure
		if s is Dictionary:
			return s
	return {}


## Number of units of an id currently flagged secure (0 if none / unsupported).
func _secured_count(id: String) -> int:
	return int(_secure_map().get(id, 0))


## Distinct item ids with at least one secured unit — i.e. occupied pouch slots.
func _distinct_secured() -> int:
	var n: int = 0
	var m: Dictionary = _secure_map()
	for id: String in m:
		if int(m[id]) > 0:
			n += 1
	return n


## Whether `item` is light enough (per-unit weight) to ever go in the pouch.
func _light_enough(item: ItemData) -> bool:
	return item.weight <= Settings.SECURE_MAX_WEIGHT


## "SECURE n/2" label text for the header chip.
func _secure_chip_text(n: int) -> String:
	return tr("SECURE %d/%d") % [n, Settings.SECURE_SLOTS]


## Refreshes the header chip count; hidden entirely when the pouch core is absent
## so the UI shows nothing misleading until the other lane merges.
func _update_secure_chip() -> void:
	if _secure_chip == null:
		return
	var wrap: Node = _secure_chip.get_parent()
	var supported: bool = _inventory != null and "secure" in _inventory
	if wrap is CanvasItem:
		(wrap as CanvasItem).visible = supported
	if supported:
		_secure_chip.text = _secure_chip_text(_distinct_secured())


## Where dropped pickups live. Prefer the same parent existing pickups use
## (their group is "pickups"); fall back to the current scene root.
func _drop_parent() -> Node:
	for p in get_tree().get_nodes_in_group(Groups.PICKUPS):
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
