extends Control
## WorkshopTab — Hub tab that shows weapon unlocks, permanent upgrades, and a
## data-driven crafting panel (driven by the Crafting autoload). It is a
## full-rect Control shown/hidden by the Hub; it does NOT manage deploy/back
## buttons (those live in the Hub chrome).
##
## Refresh happens on _ready and whenever Events.currency_changed,
## Events.stash_changed, or Events.blueprint_learned fires, so affordability
## and blueprint unlock state stay live without any explicit caller update.

# Weapon display names and canonical id order (same as old workshop.gd).
const WEAPON_DISPLAY := {
	"rifle": "RIFLE",
	"pistol": "PISTOL",
	"smg": "SMG",
	"shotgun": "SHOTGUN",
	"dmr": "DMR",
}
const WEAPON_ORDER: Array[String] = ["rifle", "pistol", "smg", "shotgun", "dmr"]

# Colours matching the project theme.
const COL_AMBER := UIStyle.AMBER  # amber accent
const COL_TEAL := UIStyle.TEAL  # teal accent
const COL_DIM := UIStyle.DIM  # muted label
const COL_WHITE := UIStyle.WHITE  # body text
const COL_RED := UIStyle.RED  # locked / unaffordable hint

# ── Node refs (assigned in _build_layout, not @onready — tree is built in code) ─
var _currency_label: Label = null
var _weapon_rows: VBoxContainer = null
var _upgrade_rows: VBoxContainer = null
var _craft_rows: VBoxContainer = null

# Runtime state ---------------------------------------------------------------
## weapon id -> { cost_lbl: Label, unlock_btn: Button }
var _weapon_ui: Dictionary = {}
## upgrade key -> { level_lbl: Label, cost_lbl: Label, btn: Button }
var _upgrade_ui: Dictionary = {}
## craft recipe id -> { lbl: Label, btn: Button }
## The label shows the recipe text and gets tinted red on missing inputs.
var _craft_ui: Dictionary = {}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	Events.currency_changed.connect(_on_currency_changed)
	Events.stash_changed.connect(_on_stash_changed)
	Events.blueprint_learned.connect(_on_blueprint_learned)
	_refresh()


func _exit_tree() -> void:
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)
	if Events.stash_changed.is_connected(_on_stash_changed):
		Events.stash_changed.disconnect(_on_stash_changed)
	if Events.blueprint_learned.is_connected(_on_blueprint_learned):
		Events.blueprint_learned.disconnect(_on_blueprint_learned)


# ── Layout construction ───────────────────────────────────────────────────────


## Builds the full node tree in code (no .tscn sub-resources needed).
## Structure:
##   ScrollContainer (fills tab)
##     VBox (root_vbox)
##       header label "WORKSHOP" + currency
##       HBox columns
##         Left VBox: weapon unlocks
##         Right VBox: permanent upgrades
##       craft section
func _build_layout() -> void:
	# Outer scroll so the whole tab scrolls on small screens.
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 16)
	scroll.add_child(root_vbox)

	# ── Header row: title + currency ─────────────────────────────────────────
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 16)
	root_vbox.add_child(hdr)

	var title_lbl := Label.new()
	title_lbl.text = "WORKSHOP"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.make_header(title_lbl, UIStyle.AMBER, 42, 3)
	hdr.add_child(title_lbl)

	_currency_label = Label.new()
	_currency_label.name = "CurrencyLabel"
	_currency_label.text = "CR 0"
	_currency_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_currency_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UIStyle.make_header(_currency_label, UIStyle.AMBER, 22, 2)
	hdr.add_child(_currency_label)

	# ── Two-column body: unlocks (left) + upgrades (right) ───────────────────
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	root_vbox.add_child(cols)

	# LEFT — Weapon Unlocks
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_theme_constant_override("separation", 8)
	cols.add_child(left_col)

	var unlk_hdr_panel := PanelContainer.new()
	unlk_hdr_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	left_col.add_child(unlk_hdr_panel)
	unlk_hdr_panel.add_child(UIStyle.micro_header("WEAPON UNLOCKS", UIStyle.TEAL, 15))

	var unlk_panel := PanelContainer.new()
	unlk_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	unlk_panel.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	left_col.add_child(unlk_panel)

	var unlk_margin := MarginContainer.new()
	unlk_margin.add_theme_constant_override("margin_left", 12)
	unlk_margin.add_theme_constant_override("margin_top", 10)
	unlk_margin.add_theme_constant_override("margin_right", 12)
	unlk_margin.add_theme_constant_override("margin_bottom", 10)
	unlk_panel.add_child(unlk_margin)

	_weapon_rows = VBoxContainer.new()
	_weapon_rows.name = "WeaponRows"
	_weapon_rows.add_theme_constant_override("separation", 10)
	unlk_margin.add_child(_weapon_rows)

	# RIGHT — Permanent Upgrades
	var right_col := VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_col.add_theme_constant_override("separation", 8)
	cols.add_child(right_col)

	var upg_hdr_panel := PanelContainer.new()
	upg_hdr_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	right_col.add_child(upg_hdr_panel)
	upg_hdr_panel.add_child(UIStyle.micro_header("PERMANENT UPGRADES", UIStyle.TEAL, 15))

	var upg_panel := PanelContainer.new()
	upg_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	upg_panel.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	right_col.add_child(upg_panel)

	var upg_margin := MarginContainer.new()
	upg_margin.add_theme_constant_override("margin_left", 12)
	upg_margin.add_theme_constant_override("margin_top", 10)
	upg_margin.add_theme_constant_override("margin_right", 12)
	upg_margin.add_theme_constant_override("margin_bottom", 10)
	upg_panel.add_child(upg_margin)

	_upgrade_rows = VBoxContainer.new()
	_upgrade_rows.name = "UpgradeRows"
	_upgrade_rows.add_theme_constant_override("separation", 12)
	upg_margin.add_child(_upgrade_rows)

	# ── CRAFT section (below the two columns) ─────────────────────────────────
	var craft_hdr_panel := PanelContainer.new()
	craft_hdr_panel.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	root_vbox.add_child(craft_hdr_panel)
	craft_hdr_panel.add_child(UIStyle.micro_header("CRAFT", UIStyle.TEAL, 15))

	var craft_panel := PanelContainer.new()
	craft_panel.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	root_vbox.add_child(craft_panel)

	var craft_margin := MarginContainer.new()
	craft_margin.add_theme_constant_override("margin_left", 12)
	craft_margin.add_theme_constant_override("margin_top", 10)
	craft_margin.add_theme_constant_override("margin_right", 12)
	craft_margin.add_theme_constant_override("margin_bottom", 10)
	craft_panel.add_child(craft_margin)

	_craft_rows = VBoxContainer.new()
	_craft_rows.name = "CraftRows"
	_craft_rows.add_theme_constant_override("separation", 10)
	craft_margin.add_child(_craft_rows)

	# Populate the permanent row containers.
	_build_weapon_rows()
	_build_upgrade_rows()
	_build_craft_rows()


# ── Row construction (called once after the containers exist) ─────────────────


## One row per weapon in WEAPON_ORDER. Owned/free weapons show "OWNED"/"FREE";
## locked weapons show their cost and an UNLOCK button (disabled if unaffordable).
## The loadout CheckButton from the old workshop is dropped — loadout lives elsewhere.
func _build_weapon_rows() -> void:
	for id in WEAPON_ORDER:
		var row := HBoxContainer.new()
		row.name = "Row_" + id
		row.add_theme_constant_override("separation", 10)

		# Small weapon icon cell.
		var icon := _icon_cell(id, 0, 40)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)

		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.custom_minimum_size = Vector2(90, 0)
		name_lbl.text = WEAPON_DISPLAY.get(id, id.to_upper())
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		row.add_child(name_lbl)

		var cost_lbl := Label.new()
		cost_lbl.name = "CostLbl"
		cost_lbl.custom_minimum_size = Vector2(110, 0)
		cost_lbl.add_theme_color_override("font_color", COL_DIM)
		cost_lbl.add_theme_font_size_override("font_size", 13)
		row.add_child(cost_lbl)

		# Spacer so the unlock button is right-aligned.
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)

		var unlock_btn := Button.new()
		unlock_btn.name = "UnlockBtn"
		unlock_btn.custom_minimum_size = Vector2(90, 32)
		unlock_btn.text = "UNLOCK"
		unlock_btn.pressed.connect(func() -> void: _on_unlock_pressed(id))
		UIStyle.hover_lift(unlock_btn)
		row.add_child(unlock_btn)

		_weapon_rows.add_child(row)
		_weapon_ui[id] = {
			"cost_lbl": cost_lbl,
			"unlock_btn": unlock_btn,
		}


## One row per upgrade key from MetaProgression.UPGRADES. Shows name + desc on
## the left, level indicator in the centre, cost + UPGRADE button on the right.
func _build_upgrade_rows() -> void:
	for key in MetaProgression.UPGRADES:
		var info: Dictionary = MetaProgression.UPGRADES[key]

		var row := HBoxContainer.new()
		row.name = "Row_" + key
		row.add_theme_constant_override("separation", 12)

		var acc: Color = info.get("color", COL_TEAL)

		# Icon cell (accent-bordered glass tile + the upgrade's game-icons texture, tinted by
		# its accent colour) on the LEFT — recognisable at a glance, no need to read the text.
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(46, 46)
		cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var csb := StyleBoxFlat.new()
		csb.bg_color = Color(0.09, 0.10, 0.13, 0.95)
		csb.set_border_width_all(2)
		csb.border_color = Color(acc, 0.85)
		csb.set_corner_radius_all(5)
		cell.add_theme_stylebox_override("panel", csb)
		var utex: Texture2D = MetaProgression.upgrade_icon(key)
		if utex != null:
			var itex := TextureRect.new()
			itex.texture = utex
			itex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			itex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			itex.set_anchors_preset(Control.PRESET_FULL_RECT)
			itex.offset_left = 7
			itex.offset_top = 7
			itex.offset_right = -7
			itex.offset_bottom = -7
			itex.modulate = acc
			itex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(itex)
		row.add_child(cell)

		var vname := VBoxContainer.new()
		vname.custom_minimum_size = Vector2(150, 0)
		vname.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var title_lbl := Label.new()
		title_lbl.text = info["name"]
		title_lbl.add_theme_color_override("font_color", acc)
		vname.add_child(title_lbl)

		var desc_lbl := Label.new()
		desc_lbl.text = info["desc"]
		desc_lbl.add_theme_color_override("font_color", COL_DIM)
		desc_lbl.add_theme_font_size_override("font_size", 12)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vname.add_child(desc_lbl)

		row.add_child(vname)

		var level_lbl := Label.new()
		level_lbl.name = "LevelLbl"
		level_lbl.custom_minimum_size = Vector2(60, 0)
		level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level_lbl.add_theme_color_override("font_color", COL_TEAL)
		row.add_child(level_lbl)

		var cost_lbl := Label.new()
		cost_lbl.name = "CostLbl"
		cost_lbl.custom_minimum_size = Vector2(80, 0)
		cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cost_lbl.add_theme_font_size_override("font_size", 13)
		cost_lbl.add_theme_color_override("font_color", COL_AMBER)
		row.add_child(cost_lbl)

		var btn := Button.new()
		btn.name = "UpgradeBtn"
		btn.custom_minimum_size = Vector2(90, 32)
		btn.text = "UPGRADE"
		btn.pressed.connect(func() -> void: _on_upgrade_pressed(key))
		UIStyle.hover_lift(btn)
		row.add_child(btn)

		_upgrade_rows.add_child(row)
		_upgrade_ui[key] = {
			"level_lbl": level_lbl,
			"cost_lbl": cost_lbl,
			"btn": btn,
		}


## Arc-style icon cell: a fixed-size Panel with a rarity-colored border holding an
## icon TextureRect (or colored-box fallback) + an optional count badge.
## Modeled on inventory_ui.gd::_make_slot. `id` may be an ItemData id (border uses
## rarity_color) or any other id (border uses a neutral teal).
func _icon_cell(id: String, count: int, cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

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


## One row per recipe from Crafting.all_recipes(). Renders the OUTPUT item as an
## icon cell, a "←" arrow, the INPUT ingredients as small icon cells (with counts),
## a status label (lock / cost / affordability), and a CRAFT button. Rows are
## rebuilt whenever the recipe list could change.
func _build_craft_rows() -> void:
	# Clear any previously built rows so a future hot-rebuild is safe.
	for c in _craft_rows.get_children():
		c.queue_free()
	_craft_ui.clear()

	for r in Crafting.all_recipes():
		var recipe: CraftRecipe = r as CraftRecipe
		if recipe == null or recipe.id == "":
			continue

		var out_item: ItemData = ItemCatalog.get_item(recipe.output_id)
		var out_name: String = out_item.display_name if out_item != null else recipe.output_id

		var row := HBoxContainer.new()
		row.name = "CraftRow_" + recipe.id
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		# ── OUTPUT icon cell (48px, badged with output_count) ────────────────
		var out_cell := _icon_cell(recipe.output_id, maxi(1, recipe.output_count), 48)
		out_cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		out_cell.tooltip_text = "%s ×%d" % [out_name, maxi(1, recipe.output_count)]
		row.add_child(out_cell)

		# ── "←" arrow ────────────────────────────────────────────────────────
		var arrow := Label.new()
		arrow.text = "←"
		arrow.add_theme_color_override("font_color", COL_TEAL)
		arrow.add_theme_font_size_override("font_size", 22)
		arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(arrow)

		# ── INPUT ingredient icon cells (36px, badged with count) ────────────
		var ingredients := HBoxContainer.new()
		ingredients.name = "Ingredients"
		ingredients.add_theme_constant_override("separation", 6)
		ingredients.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ingredients.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for inp in recipe.inputs():
			var in_id: String = String(inp["id"])
			var in_cnt: int = int(inp["count"])
			var in_item: ItemData = ItemCatalog.get_item(in_id)
			var in_name: String = in_item.display_name if in_item != null else in_id
			var in_cell := _icon_cell(in_id, in_cnt, 36)
			in_cell.tooltip_text = "%d× %s" % [in_cnt, in_name]
			ingredients.add_child(in_cell)
		row.add_child(ingredients)

		# ── Status label (lock / cost / affordability) ──────────────────────
		var status_lbl := Label.new()
		status_lbl.name = "StatusLbl"
		status_lbl.custom_minimum_size = Vector2(110, 0)
		status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		status_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(status_lbl)

		# ── CRAFT button ─────────────────────────────────────────────────────
		var craft_btn := Button.new()
		craft_btn.name = "CraftBtn"
		craft_btn.custom_minimum_size = Vector2(90, 36)
		craft_btn.text = "CRAFT"
		craft_btn.focus_mode = Control.FOCUS_NONE
		craft_btn.pressed.connect(func() -> void: _on_craft_pressed(recipe.id))
		UIStyle.hover_lift(craft_btn)
		row.add_child(craft_btn)

		_craft_rows.add_child(row)
		_craft_ui[recipe.id] = {"lbl": status_lbl, "btn": craft_btn}


# ── Refresh ───────────────────────────────────────────────────────────────────


## Full state sync from MetaProgression + Stash. Called on _ready and after each
## purchase or craft so the UI always reflects current data.
func _refresh() -> void:
	_refresh_currency()
	_refresh_weapon_rows()
	_refresh_upgrade_rows()
	_refresh_craft_rows()


func _refresh_currency() -> void:
	if not _currency_label:
		return
	_currency_label.text = "CR %d" % MetaProgression.currency


func _refresh_weapon_rows() -> void:
	for id in WEAPON_ORDER:
		var ui: Dictionary = _weapon_ui.get(id, {})
		if ui.is_empty():
			continue
		var owned: bool = MetaProgression.is_unlocked(id)
		var is_free: bool = id in MetaProgression.FREE_WEAPONS
		var cost: int = MetaProgression.weapon_cost(id)

		var cost_lbl: Label = ui["cost_lbl"]
		var unlock_btn: Button = ui["unlock_btn"]

		if owned:
			cost_lbl.text = "FREE" if is_free else "OWNED"
			cost_lbl.add_theme_color_override("font_color", COL_DIM)
			unlock_btn.visible = false
		else:
			cost_lbl.text = "CR %d" % cost
			var affordable: bool = MetaProgression.currency >= cost
			cost_lbl.add_theme_color_override("font_color", COL_AMBER if affordable else COL_RED)
			unlock_btn.visible = true
			unlock_btn.disabled = not affordable


func _refresh_upgrade_rows() -> void:
	for key in _upgrade_ui:
		var ui: Dictionary = _upgrade_ui[key]
		if ui.is_empty():
			continue
		var lvl: int = MetaProgression.upgrade_level(key)
		var maxl: int = MetaProgression.upgrade_max(key)
		var cost: int = MetaProgression.upgrade_cost(key)

		var level_lbl: Label = ui["level_lbl"]
		var cost_lbl: Label = ui["cost_lbl"]
		var btn: Button = ui["btn"]

		level_lbl.text = "Lv %d / %d" % [lvl, maxl]

		if cost < 0:
			cost_lbl.text = "MAX"
			cost_lbl.add_theme_color_override("font_color", COL_TEAL)
			btn.disabled = true
		else:
			cost_lbl.text = "CR %d" % cost
			var affordable: bool = MetaProgression.currency >= cost
			cost_lbl.add_theme_color_override("font_color", COL_AMBER if affordable else COL_RED)
			btn.disabled = not affordable


## Refresh craft row affordability + blueprint-gating from the live Crafting state.
## Blueprint-locked rows show a lock note + hide CRAFT; unlocked rows show the
## CR cost (or READY) tinted red when missing inputs / unaffordable.
func _refresh_craft_rows() -> void:
	for recipe_id in _craft_ui:
		var ui: Dictionary = _craft_ui[recipe_id]
		if ui.is_empty():
			continue
		var recipe: CraftRecipe = Crafting.recipe_by_id(recipe_id)
		if recipe == null:
			continue

		var lbl: Label = ui["lbl"] as Label
		var btn: Button = ui["btn"] as Button

		if not Crafting.recipe_unlocked(recipe):
			# Locked: annotate the status label, hide the CRAFT button.
			lbl.add_theme_color_override("font_color", COL_DIM)
			lbl.text = "Blueprint required\n(extract / buy / quest)"
			btn.disabled = true
			btn.visible = false
			continue

		# Blueprint known — restore button visibility then check ingredients.
		btn.visible = true

		# Per-ingredient availability check.
		var all_ok: bool = true
		for inp in recipe.inputs():
			if not Stash.has(String(inp["id"]), int(inp["count"])):
				all_ok = false
				break

		var currency_ok: bool = recipe.cost <= 0 or MetaProgression.currency >= recipe.cost
		var can_make: bool = all_ok and currency_ok

		if recipe.cost > 0:
			lbl.text = "CR %d" % recipe.cost
		else:
			lbl.text = "READY" if can_make else "MISSING"
		# Amber/READY when craftable, red when missing inputs or unaffordable.
		lbl.add_theme_color_override("font_color", COL_AMBER if can_make else COL_RED)

		btn.disabled = not can_make


# ── Event handlers ────────────────────────────────────────────────────────────


func _on_currency_changed(_amount: int) -> void:
	_refresh_currency()
	_refresh_weapon_rows()
	_refresh_upgrade_rows()
	_refresh_craft_rows()


func _on_stash_changed() -> void:
	_refresh_craft_rows()


## A newly-learned blueprint may unlock a previously-locked recipe: do a full
## craft-panel refresh so the row appears enabled immediately.
func _on_blueprint_learned(_bp: String) -> void:
	_refresh_craft_rows()


func _on_unlock_pressed(id: String) -> void:
	var ok: bool = MetaProgression.unlock_weapon(id)
	if ok:
		_refresh()


func _on_upgrade_pressed(key: String) -> void:
	var ok: bool = MetaProgression.buy_upgrade(key)
	if ok:
		_refresh_currency()
		_refresh_upgrade_rows()
		_refresh_weapon_rows()  # affordability may change for weapon unlocks too


## Delegate the craft to the Crafting autoload, which re-validates everything
## (blueprint, inputs, currency) atomically before consuming any resources.
## The resulting stash_changed and currency_changed signals will trigger a UI
## refresh automatically; we call _refresh_craft_rows directly as a belt-and-
## suspenders guard for the case where Stash contents changed between the
## button-enable check and the button press.
func _on_craft_pressed(recipe_id: String) -> void:
	var recipe: CraftRecipe = Crafting.recipe_by_id(recipe_id)
	if recipe == null:
		return
	var ok: bool = Crafting.craft(recipe)
	if not ok:
		# Inputs or blueprint no longer available — resync the row state.
		_refresh_craft_rows()
