extends Control
class_name GunsmithTab
## GUNSMITH hub tab. Lets the player equip AT-RISK weapon attachments (from the Stash)
## and buy PERMANENT per-weapon perks (never lost) for each weapon in the loadout.
##
## Data flow:
##   MetaProgression.get_loadout()                   -> which weapons to show
##   MetaProgression.get_equipped(weapon_id)         -> currently-slotted attachments
##   MetaProgression.equip_attachment(w, slot, id)   -> equip an attachment
##   MetaProgression.unequip_attachment(w, slot)     -> clear a slot
##   MetaProgression.WEAPON_PERKS                    -> perk catalog
##   MetaProgression.weapon_perk_level(w, key)       -> current perk level
##   MetaProgression.weapon_perk_cost(w, key)        -> next-level cost (-1 if maxed)
##   MetaProgression.buy_weapon_perk(w, key)         -> purchase next perk level
##   ItemCatalog.ids_of_kind(Kind.ATTACHMENT)        -> all known attachment ids
##   ItemCatalog.get_item(id)                        -> AttachmentData (cast explicitly)
##   Stash.count_of(id)                              -> owned count
##   AssetRegistry.get_icon(id)                      -> icon / colored-box fallback
##
## Refreshed automatically on:
##   Events.attachment_changed, Events.weapon_perk_changed,
##   Events.currency_changed,   Events.stash_changed

# Project theme colours (mirrors shop_tab.gd).
const COL_AMBER := UIStyle.AMBER
const COL_TEAL := UIStyle.TEAL
const COL_DIM := UIStyle.DIM
const COL_WHITE := UIStyle.WHITE
const COL_RED := UIStyle.RED
const COL_ORANGE := Color(0.93, 0.55, 0.15, 1.0)
const COL_GREEN := UIStyle.GREEN

## The four canonical attachment slots in display order.
const SLOTS: Array[String] = ["optic", "mag", "barrel", "grip"]
## Slot display names.
const SLOT_LABELS: Dictionary = {
	"optic": "OPTIC",
	"mag": "MAG",
	"barrel": "BARREL",
	"grip": "GRIP",
}

# ── Node refs (built in _build_layout; no @onready) ──────────────────────────
var _currency_label: Label = null
var _weapon_bar: HBoxContainer = null  # weapon selector buttons
var _content_scroll: ScrollContainer = null
var _content_body: VBoxContainer = null  # rebuilt on weapon switch

## Which weapon is currently displayed.
var _selected_weapon: String = ""

## Weapon selector button refs: weapon_id -> Button
var _weapon_btns: Dictionary = {}

# Responsive columns: the attachment-slot rows + perk rows go into GridContainers whose column
# count is computed from the tab width, so a single slot/perk never stretches full-width on a
# wide/ultrawide monitor. Recomputed on `resized`. (See UILayout.columns_for.)
const _CELL_W := 520.0  # target slot/perk cell width (px)
const _MAX_COLS := 3
var _grids: Array[GridContainer] = []  # slot + perk grids (for resize recompute)


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	# Reflow the slot/perk grids whenever the tab (and thus the window) resizes.
	resized.connect(_apply_columns)
	Events.attachment_changed.connect(_on_data_changed)
	Events.weapon_perk_changed.connect(_on_data_changed)
	Events.currency_changed.connect(_on_currency_changed)
	Events.stash_changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	if Events.attachment_changed.is_connected(_on_data_changed):
		Events.attachment_changed.disconnect(_on_data_changed)
	if Events.weapon_perk_changed.is_connected(_on_data_changed):
		Events.weapon_perk_changed.disconnect(_on_data_changed)
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)
	if Events.stash_changed.is_connected(_refresh):
		Events.stash_changed.disconnect(_refresh)


# ── Layout construction ───────────────────────────────────────────────────────


## Builds the static skeleton in code. The weapon-detail body is rebuilt by
## _rebuild_content() whenever the selected weapon changes.
func _build_layout() -> void:
	# ── Outer scroll ──────────────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	scroll.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 16)
	margin.add_child(root_vbox)

	# ── Header row: "GUNSMITH" title + currency ───────────────────────────────
	var hdr := HBoxContainer.new()
	hdr.name = "HeaderRow"
	hdr.add_theme_constant_override("separation", 12)
	root_vbox.add_child(hdr)

	var title_lbl := Label.new()
	title_lbl.name = "TitleLabel"
	title_lbl.text = "GUNSMITH"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.make_header(title_lbl, UIStyle.AMBER, 42, 3)
	hdr.add_child(title_lbl)

	_currency_label = Label.new()
	_currency_label.name = "CurrencyLabel"
	_currency_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_currency_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UIStyle.make_header(_currency_label, UIStyle.AMBER, 20, 2)
	hdr.add_child(_currency_label)

	# ── Weapon selector bar ───────────────────────────────────────────────────
	root_vbox.add_child(_make_section_header("SELECT WEAPON"))

	_weapon_bar = HBoxContainer.new()
	_weapon_bar.name = "WeaponBar"
	_weapon_bar.add_theme_constant_override("separation", 8)
	_weapon_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_weapon_bar)

	# ── Content body (rebuilt on weapon change) ───────────────────────────────
	_content_body = VBoxContainer.new()
	_content_body.name = "ContentBody"
	_content_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_body.add_theme_constant_override("separation", 16)
	root_vbox.add_child(_content_body)


# ── Weapon selector ───────────────────────────────────────────────────────────


## Rebuilds the weapon selector buttons from the current loadout.
func _rebuild_weapon_bar() -> void:
	for c in _weapon_bar.get_children():
		c.queue_free()
	_weapon_btns.clear()

	var weapons: Array = MetaProgression.get_loadout()
	if weapons.is_empty():
		return

	# Default selection: keep existing if still in loadout, else first entry.
	if _selected_weapon not in weapons:
		_selected_weapon = String(weapons[0])

	for raw_id in weapons:
		var wid: String = String(raw_id)
		var btn := Button.new()
		btn.name = "WBtn_" + wid
		btn.text = tr(wid.to_upper())
		btn.custom_minimum_size = Vector2(100, 36)
		btn.focus_mode = Control.FOCUS_NONE
		# Highlight active weapon.
		if wid == _selected_weapon:
			btn.add_theme_color_override("font_color", COL_AMBER)
		btn.pressed.connect(func() -> void: _on_weapon_selected(wid))
		_weapon_bar.add_child(btn)
		_weapon_btns[wid] = btn


# ── Content body ──────────────────────────────────────────────────────────────


## Clears and rebuilds the preview + attachment + perk panels for _selected_weapon.
func _rebuild_content() -> void:
	for c in _content_body.get_children():
		c.queue_free()
	_grids.clear()
	_wp_pivot = null

	if _selected_weapon.is_empty():
		return

	_build_weapon_preview()
	_build_attachments_section()
	_build_perks_section()
	# Apply responsive columns once the tree has laid out (size.x is valid).
	_apply_columns.call_deferred()


# ── Live weapon preview (Phase 3: the genre-staple render the tab was missing) ──

var _wp_pivot: Node3D = null


func _process(delta: float) -> void:
	if _wp_pivot != null and _wp_pivot.is_inside_tree():
		_wp_pivot.rotation.y += 0.6 * delta


## A slowly rotating 3D render of the selected weapon in its own lit stage —
## mirrors the CHARACTER tab's SubViewport preview (headless → skipped).
func _build_weapon_preview() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var panel := PanelContainer.new()
	panel.name = "WeaponPreview"
	panel.custom_minimum_size = Vector2(0, 150)
	panel.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	_content_body.add_child(panel)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(svc)
	var vp := SubViewport.new()
	vp.size = Vector2i(560, 150)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(vp)
	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.085, 0.105, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.68)
	env.ambient_light_energy = 0.9
	world.environment = env
	vp.world_3d = world
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, -120, 0)
	key.light_energy = 1.5
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 70, 0)
	fill.light_energy = 0.5
	vp.add_child(fill)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.05, 0.62)
	cam.fov = 35.0
	vp.add_child(cam)
	_wp_pivot = Node3D.new()
	vp.add_child(_wp_pivot)
	var model: Node3D = AssetRegistry.get_model(_selected_weapon)
	if model != null:
		_wp_pivot.add_child(model)


## Column count that fits the current tab width (minus the panel padding + scrollbar).
func _columns_now() -> int:
	return UILayout.columns_for(size.x - 64.0, _CELL_W, 12.0, _MAX_COLS)


## Re-apply the responsive column count to the slot + perk grids (on resize / after a rebuild).
func _apply_columns() -> void:
	var cols: int = _columns_now()
	for g in _grids:
		if is_instance_valid(g):
			g.columns = cols


## Builds the ATTACHMENT SLOTS panel for _selected_weapon.
func _build_attachments_section() -> void:
	_content_body.add_child(_make_section_header("ATTACHMENT SLOTS"))

	# AT-RISK warning note.
	var note := Label.new()
	note.name = "AtRiskNote"
	note.text = tr("  WARNING — AT RISK: attachments are LOST if you do not extract.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", COL_ORANGE)
	note.add_theme_font_size_override("font_size", 13)
	_content_body.add_child(note)

	var slots_panel := _make_panel()
	_content_body.add_child(slots_panel)

	var slots_grid := GridContainer.new()
	slots_grid.name = "SlotsGrid"
	slots_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots_grid.add_theme_constant_override("h_separation", 12)
	slots_grid.add_theme_constant_override("v_separation", 12)
	slots_grid.columns = _columns_now()
	slots_panel.add_child(slots_grid)
	_grids.append(slots_grid)

	# Collect all owned attachments once (saves repeated catalog iterations).
	var owned_atts: Array[String] = _owned_attachments_for(_selected_weapon)

	var equipped: Dictionary = MetaProgression.get_equipped(_selected_weapon)

	for slot_id in SLOTS:
		slots_grid.add_child(_build_slot_row(slot_id, equipped, owned_atts))


## Builds one attachment slot row: label | current att name + stat delta | dropdown | CLEAR.
func _build_slot_row(
	slot_id: String, equipped: Dictionary, owned_atts: Array[String]
) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "SlotRow_" + slot_id
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	# Slot label.
	var slot_lbl := Label.new()
	slot_lbl.name = "SlotLbl"
	slot_lbl.text = SLOT_LABELS.get(slot_id, slot_id.to_upper())
	slot_lbl.custom_minimum_size = Vector2(60, 0)
	slot_lbl.add_theme_color_override("font_color", COL_TEAL)
	slot_lbl.add_theme_font_size_override("font_size", 14)
	slot_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(slot_lbl)

	# Currently-equipped attachment icon cell (empty placeholder when none).
	var cur_id: String = String(equipped.get(slot_id, ""))
	var icon_cell := _icon_cell(cur_id, 44)
	icon_cell.name = "SlotIcon"
	icon_cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon_cell)

	# Currently-equipped name + stat delta.
	var cur_lbl := Label.new()
	cur_lbl.name = "CurLbl"
	cur_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cur_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cur_lbl.add_theme_font_size_override("font_size", 13)

	if cur_id.is_empty():
		cur_lbl.text = tr("— empty —")
		cur_lbl.add_theme_color_override("font_color", COL_DIM)
	else:
		var att_item: ItemData = ItemCatalog.get_item(cur_id)
		if att_item != null:
			var att_data: AttachmentData = att_item as AttachmentData
			if att_data != null:
				cur_lbl.text = tr(att_data.display_name) + "  " + _stat_delta_text(att_data)
			else:
				cur_lbl.text = tr(att_item.display_name)
		else:
			cur_lbl.text = cur_id
		cur_lbl.add_theme_color_override("font_color", COL_WHITE)
	row.add_child(cur_lbl)

	# Filter owned attachments to this slot.
	var candidates: Array[String] = []
	for att_id in owned_atts:
		var raw_item: ItemData = ItemCatalog.get_item(att_id)
		if raw_item == null:
			continue
		var att: AttachmentData = raw_item as AttachmentData
		if att == null:
			continue
		if att.slot == slot_id:
			candidates.append(att_id)

	# OptionButton to pick an attachment.
	var opt := OptionButton.new()
	opt.name = "AttOpt_" + slot_id
	opt.custom_minimum_size = Vector2(180, 32)
	opt.focus_mode = Control.FOCUS_NONE

	# First entry is always "— pick —".
	opt.add_item(tr("— pick —"), -1)
	opt.set_item_metadata(0, "")

	for i: int in candidates.size():
		var att_id: String = candidates[i]
		var raw_it: ItemData = ItemCatalog.get_item(att_id)
		var display_name: String = att_id
		if raw_it != null:
			display_name = tr(raw_it.display_name)
		var opt_icon: Texture2D = AssetRegistry.get_icon(att_id)
		if opt_icon != null:
			opt.add_icon_item(opt_icon, display_name, i)
		else:
			opt.add_item(display_name, i)
		opt.set_item_metadata(i + 1, att_id)

	# Pre-select the currently equipped one.
	if not cur_id.is_empty():
		for k: int in opt.item_count:
			if String(opt.get_item_metadata(k)) == cur_id:
				opt.select(k)
				break

	var wid_cap: String = _selected_weapon  # capture for closure
	opt.item_selected.connect(
		func(idx: int) -> void:
			_on_att_selected(wid_cap, slot_id, String(opt.get_item_metadata(idx)))
	)
	row.add_child(opt)

	# CLEAR button — only enabled when something is equipped.
	var clear_btn := Button.new()
	clear_btn.name = "ClearBtn"
	clear_btn.text = tr("CLEAR")
	clear_btn.custom_minimum_size = Vector2(64, 32)
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.disabled = cur_id.is_empty()
	clear_btn.pressed.connect(func() -> void: _on_clear_slot(wid_cap, slot_id))
	UIStyle.hover_lift(clear_btn)
	row.add_child(clear_btn)

	return row


## Builds the PERKS panel for _selected_weapon.
func _build_perks_section() -> void:
	_content_body.add_child(_make_section_header("PERMANENT PERKS"))

	var perks_panel := _make_panel()
	_content_body.add_child(perks_panel)

	var perks_grid := GridContainer.new()
	perks_grid.name = "PerksGrid"
	perks_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	perks_grid.add_theme_constant_override("h_separation", 12)
	perks_grid.add_theme_constant_override("v_separation", 10)
	perks_grid.columns = _columns_now()
	perks_panel.add_child(perks_grid)
	_grids.append(perks_grid)

	for raw_key in MetaProgression.WEAPON_PERKS:
		var key: String = String(raw_key)
		perks_grid.add_child(_build_perk_row(key))


## Builds one perk row: name + desc | Lv N/max | cost | BUY button.
func _build_perk_row(key: String) -> HBoxContainer:
	var perk_dict: Dictionary = MetaProgression.WEAPON_PERKS[key] as Dictionary

	var lvl: int = MetaProgression.weapon_perk_level(_selected_weapon, key)
	var max_lvl: int = int(perk_dict.get("max_level", 1))
	var cost: int = MetaProgression.weapon_perk_cost(_selected_weapon, key)

	var row := HBoxContainer.new()
	row.name = "PerkRow_" + key
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	# Name + description (stacked).
	var info_vbox := VBoxContainer.new()
	info_vbox.name = "InfoVBox"
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vbox.add_theme_constant_override("separation", 2)
	row.add_child(info_vbox)

	var name_lbl := Label.new()
	name_lbl.name = "PerkName"
	name_lbl.text = tr(String(perk_dict.get("name", key)))
	name_lbl.add_theme_color_override("font_color", COL_WHITE)
	name_lbl.add_theme_font_size_override("font_size", 14)
	info_vbox.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.name = "PerkDesc"
	desc_lbl.text = tr(String(perk_dict.get("desc", "")))
	desc_lbl.add_theme_color_override("font_color", COL_DIM)
	desc_lbl.add_theme_font_size_override("font_size", 13)
	info_vbox.add_child(desc_lbl)

	# Level indicator.
	var lvl_lbl := Label.new()
	lvl_lbl.name = "LvlLbl"
	lvl_lbl.text = tr("Lv %d/%d") % [lvl, max_lvl]
	lvl_lbl.custom_minimum_size = Vector2(60, 0)
	lvl_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lvl_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if lvl >= max_lvl:
		lvl_lbl.add_theme_color_override("font_color", COL_GREEN)
	else:
		lvl_lbl.add_theme_color_override("font_color", COL_TEAL)
	lvl_lbl.add_theme_font_size_override("font_size", 13)
	row.add_child(lvl_lbl)

	# Cost label.
	var cost_lbl := Label.new()
	cost_lbl.name = "CostLbl"
	cost_lbl.custom_minimum_size = Vector2(70, 0)
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cost_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost_lbl.add_theme_font_size_override("font_size", 13)
	if lvl >= max_lvl:
		cost_lbl.text = tr("MAX")
		cost_lbl.add_theme_color_override("font_color", COL_GREEN)
	else:
		cost_lbl.text = tr("CR %d") % cost
		cost_lbl.add_theme_color_override("font_color", COL_AMBER)
	row.add_child(cost_lbl)

	# BUY button.
	var buy_btn := Button.new()
	buy_btn.name = "BuyBtn"
	buy_btn.custom_minimum_size = Vector2(64, 32)
	buy_btn.focus_mode = Control.FOCUS_NONE

	if lvl >= max_lvl:
		buy_btn.text = tr("MAX")
		buy_btn.disabled = true
	else:
		buy_btn.text = tr("BUY")
		buy_btn.disabled = MetaProgression.currency < cost
		var wid_cap: String = _selected_weapon
		buy_btn.pressed.connect(func() -> void: _on_buy_perk(wid_cap, key))
	UIStyle.hover_lift(buy_btn)
	row.add_child(buy_btn)

	return row


# ── Helpers ───────────────────────────────────────────────────────────────────


## Returns all attachment ids owned (Stash.count_of > 0) that fit _selected_weapon.
func _owned_attachments_for(weapon_id: String) -> Array[String]:
	var out: Array[String] = []
	for raw_id in ItemCatalog.ids_of_kind(ItemData.Kind.ATTACHMENT):
		var att_id: String = String(raw_id)
		if Stash.count_of(att_id) <= 0:
			continue
		var raw_item: ItemData = ItemCatalog.get_item(att_id)
		if raw_item == null:
			continue
		var att: AttachmentData = raw_item as AttachmentData
		if att == null:
			continue
		if att.fits(weapon_id):
			out.append(att_id)
	return out


## Short human-readable summary of an attachment's non-unity stat modifiers.
## Examples: "+12 mag", "-8% recoil", "+5% dmg".
func _stat_delta_text(att: AttachmentData) -> String:
	var parts: Array[String] = []
	if att.damage_mult != 1.0:
		parts.append("%+.0f%% dmg" % ((att.damage_mult - 1.0) * 100.0))
	if att.fire_rate_mult != 1.0:
		parts.append("%+.0f%% firerate" % ((att.fire_rate_mult - 1.0) * 100.0))
	if att.recoil_mult != 1.0:
		parts.append("%+.0f%% recoil" % ((att.recoil_mult - 1.0) * 100.0))
	if att.spread_mult != 1.0:
		parts.append("%+.0f%% spread" % ((att.spread_mult - 1.0) * 100.0))
	if att.reload_mult != 1.0:
		parts.append("%+.0f%% reload" % ((att.reload_mult - 1.0) * 100.0))
	if att.ads_fov_mult != 1.0:
		parts.append("%+.0f%% zoom" % ((att.ads_fov_mult - 1.0) * 100.0))
	if att.range_mult != 1.0:
		parts.append("%+.0f%% range" % ((att.range_mult - 1.0) * 100.0))
	if att.mag_add != 0:
		parts.append("%+d mag" % att.mag_add)
	if att.reserve_add != 0:
		parts.append("%+d reserve" % att.reserve_add)
	if att.crit_add != 0.0:
		parts.append("%+.0f%% crit" % (att.crit_add * 100.0))
	if parts.is_empty():
		return ""
	return "(" + ", ".join(parts) + ")"


## Glass card panel (military-glass look).
func _make_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	return pc


## Glass header-panel with a spaced-caps teal label (section heading strip).
func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.section_bar(UIStyle.TEAL))
	pc.add_child(UIStyle.micro_header(title, UIStyle.TEAL, 15))
	return pc


## Arc-style icon cell: a fixed-size Panel with a rarity-colored border holding an
## icon TextureRect (or colored-box fallback). Modeled on inventory_ui.gd::_make_slot.
## `id` may be empty (renders a dim empty-slot placeholder), an ItemData id (border =
## rarity_color), or any other id (border = neutral teal).
func _icon_cell(id: String, cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)

	if id.is_empty():
		# Empty slot: dim dashed-look placeholder.
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

	var item: ItemData = ItemCatalog.get_item(id)
	sb.border_color = item.rarity_color() if item != null else COL_TEAL
	slot.add_theme_stylebox_override("panel", sb)
	if item != null:
		slot.tooltip_text = tr(item.display_name)

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
	return slot


# ── Refresh ───────────────────────────────────────────────────────────────────


## Full refresh: rebuild weapon bar + content body.
func _refresh() -> void:
	if not is_inside_tree():
		return
	if _currency_label != null:
		_currency_label.text = tr("CR %d") % MetaProgression.currency
	_rebuild_weapon_bar()
	_rebuild_content()
	_update_weapon_btn_highlights()


# ── Signal handlers ───────────────────────────────────────────────────────────


func _on_data_changed(_weapon_id: String) -> void:
	## An attachment or perk changed on some weapon — full refresh.
	_refresh()


func _on_currency_changed(_amount: int) -> void:
	## Currency changed — refresh header and perk buy-button states.
	_refresh()


# ── Weapon selector ───────────────────────────────────────────────────────────


func _on_weapon_selected(weapon_id: String) -> void:
	if _selected_weapon == weapon_id:
		return
	_selected_weapon = weapon_id
	_update_weapon_btn_highlights()
	_rebuild_content()


## Update amber highlight on the active weapon button.
func _update_weapon_btn_highlights() -> void:
	for wid in _weapon_btns:
		var btn: Button = _weapon_btns[wid]
		if wid == _selected_weapon:
			btn.add_theme_color_override("font_color", COL_AMBER)
		else:
			btn.remove_theme_color_override("font_color")


# ── Attachment actions ────────────────────────────────────────────────────────


## Called when the player picks an attachment from a slot's OptionButton.
## Empty string means "— pick —" (no-op).
func _on_att_selected(weapon_id: String, slot_id: String, att_id: String) -> void:
	if att_id.is_empty():
		return
	MetaProgression.equip_attachment(weapon_id, slot_id, att_id)
	# attachment_changed fires from equip_attachment; _refresh() runs via _on_data_changed.


## Called when the player presses CLEAR for a slot.
func _on_clear_slot(weapon_id: String, slot_id: String) -> void:
	MetaProgression.unequip_attachment(weapon_id, slot_id)
	# attachment_changed fires automatically; _refresh() runs.


# ── Perk actions ──────────────────────────────────────────────────────────────


## Attempt to purchase the next level of a perk. MetaProgression handles
## affordability and spending; weapon_perk_changed fires on success.
func _on_buy_perk(weapon_id: String, perk_key: String) -> void:
	MetaProgression.buy_weapon_perk(weapon_id, perk_key)
	# weapon_perk_changed fires on success; _refresh() runs via _on_data_changed.
