extends Control
class_name CharacterTab
## CHARACTER hub tab — cosmetic constructor.
##
## Layout (built entirely in code):
##   Left pane  : category selector (Head/Torso/Arms/Legs/Paint) + scrollable variant grid.
##   Right pane : live SubViewport showing the assembled player body, slowly rotating.
##
## Data flow:
##   ProceduralPlayer.CATEGORIES / variants_of(cat)  -> catalog
##   MetaProgression.is_cosmetic_unlocked(id)         -> owned check
##   MetaProgression.unlock_cosmetic(id)              -> spend + unlock
##   MetaProgression.set_equipped_cosmetic(id)        -> equip
##   MetaProgression.get_equipped_cosmetic(cat)       -> current equip per category
##   MetaProgression.get_cosmetics()                  -> full dict for build_player
##   MetaProgression.currency                         -> affordability
##   IconRenderer.render_cosmetic(cat,id,paint)       -> async thumbnail (cached)
##   ProceduralPlayer.build_player(cosmetics)         -> live 3D preview node
##
## Refreshed automatically on Events.cosmetics_changed + Events.currency_changed.

# ── Palette ──────────────────────────────────────────────────────────────────
const COL_AMBER := UIStyle.AMBER
const COL_TEAL := UIStyle.TEAL
const COL_DIM := UIStyle.DIM
const COL_WHITE := UIStyle.WHITE
const COL_RED := UIStyle.RED
const COL_GREEN := UIStyle.GREEN

# Display label for each category (tr()-wrapped at use-time).
const CAT_LABELS: Dictionary = {
	"head": "HEAD",
	"torso": "TORSO",
	"arms": "ARMS",
	"legs": "LEGS",
	"paint": "PAINT",
}

# Cell size for variant thumbnails.
const THUMB_SIZE := 72

# Viewport size for the live 3D preview.
const PREVIEW_SIZE := Vector2i(320, 480)

# Slow body-rotation speed (radians/second).
const ROTATE_SPEED := 0.55

# ── Node refs (built in _ready; no @onready) ─────────────────────────────────
var _currency_label: Label = null
var _cat_buttons: Dictionary = {}  # category -> Button
var _variant_grid: GridContainer = null
var _preview_vp: SubViewport = null
var _preview_body: Node3D = null
var _preview_pivot: Node3D = null  # rotated each frame

var _selected_cat: String = "head"

# ── Lifecycle ─────────────────────────────────────────────────────────────────


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	Events.cosmetics_changed.connect(_on_cosmetics_changed)
	Events.currency_changed.connect(_on_currency_changed)
	_select_category("head")
	_rebuild_preview()


func _exit_tree() -> void:
	if Events.cosmetics_changed.is_connected(_on_cosmetics_changed):
		Events.cosmetics_changed.disconnect(_on_cosmetics_changed)
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)


func _process(delta: float) -> void:
	# Slowly rotate the preview body around Y.
	if _preview_pivot != null and _preview_pivot.is_inside_tree():
		_preview_pivot.rotation.y += ROTATE_SPEED * delta


# ── Layout construction ───────────────────────────────────────────────────────


func _build_layout() -> void:
	# ── Outer margin ──────────────────────────────────────────────────────────
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	# ── Root VBox ─────────────────────────────────────────────────────────────
	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 16)
	margin.add_child(root_vbox)

	# ── Header row: title + currency ──────────────────────────────────────────
	var hdr := HBoxContainer.new()
	hdr.name = "HeaderRow"
	hdr.add_theme_constant_override("separation", 12)
	root_vbox.add_child(hdr)

	var title_lbl := Label.new()
	title_lbl.name = "TitleLabel"
	title_lbl.text = tr("CHARACTER")
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.make_header(title_lbl, UIStyle.AMBER, 42, 3)
	hdr.add_child(title_lbl)

	_currency_label = Label.new()
	_currency_label.name = "CurrencyLabel"
	_currency_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_currency_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UIStyle.make_header(_currency_label, UIStyle.AMBER, 20, 2)
	hdr.add_child(_currency_label)

	# ── Body: left (selector + grid) | right (3D preview) ────────────────────
	var body_hbox := HBoxContainer.new()
	body_hbox.name = "BodyHBox"
	body_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_hbox.add_theme_constant_override("separation", 20)
	root_vbox.add_child(body_hbox)

	# ── LEFT column ───────────────────────────────────────────────────────────
	var left_vbox := VBoxContainer.new()
	left_vbox.name = "LeftVBox"
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 12)
	body_hbox.add_child(left_vbox)

	# Category selector bar.
	left_vbox.add_child(_make_section_header("SELECT CATEGORY"))

	var cat_bar := HBoxContainer.new()
	cat_bar.name = "CatBar"
	cat_bar.add_theme_constant_override("separation", 6)
	left_vbox.add_child(cat_bar)

	for raw_cat in ProceduralPlayer.CATEGORIES:
		var cat: String = String(raw_cat)
		var btn := Button.new()
		btn.name = "CatBtn_" + cat
		btn.text = tr(CAT_LABELS.get(cat, cat.to_upper()))
		btn.custom_minimum_size = Vector2(80, 34)
		btn.focus_mode = Control.FOCUS_NONE
		UIStyle.hover_lift(btn)
		btn.pressed.connect(func() -> void: _select_category(cat))
		cat_bar.add_child(btn)
		_cat_buttons[cat] = btn

	# Variant section header.
	left_vbox.add_child(_make_section_header("VARIANTS"))

	# Scrollable variant grid.
	var scroll := ScrollContainer.new()
	scroll.name = "VariantScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_vbox.add_child(scroll)

	var grid_margin := MarginContainer.new()
	grid_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_margin.add_theme_constant_override("margin_right", 4)
	scroll.add_child(grid_margin)

	_variant_grid = GridContainer.new()
	_variant_grid.name = "VariantGrid"
	_variant_grid.columns = 4
	_variant_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_variant_grid.add_theme_constant_override("h_separation", 10)
	_variant_grid.add_theme_constant_override("v_separation", 10)
	grid_margin.add_child(_variant_grid)

	# ── RIGHT column: live 3D preview ─────────────────────────────────────────
	var right_vbox := VBoxContainer.new()
	right_vbox.name = "RightVBox"
	right_vbox.custom_minimum_size = Vector2(float(PREVIEW_SIZE.x) + 8.0, 0.0)
	right_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 12)
	body_hbox.add_child(right_vbox)

	right_vbox.add_child(_make_section_header("PREVIEW"))

	var preview_panel := PanelContainer.new()
	preview_panel.name = "PreviewPanel"
	preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_panel.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	right_vbox.add_child(preview_panel)

	_build_preview_viewport(preview_panel)

	# ── Initial currency ──────────────────────────────────────────────────────
	_refresh_currency()


func _build_preview_viewport(parent: Control) -> void:
	# Guard: no SubViewport rendering in headless.
	if DisplayServer.get_name() == "headless":
		var lbl := Label.new()
		lbl.text = tr("(preview N/A)")
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", COL_DIM)
		parent.add_child(lbl)
		return

	# SubViewportContainer stretches to fill the panel.
	var svc := SubViewportContainer.new()
	svc.name = "PreviewSVC"
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(svc)

	_preview_vp = SubViewport.new()
	_preview_vp.name = "PreviewVP"
	_preview_vp.size = PREVIEW_SIZE
	# Phase 3: an opaque lit STAGE instead of transparent-over-dark-glass — the dark
	# default paint read as a "black mannequin on black" (audit).
	_preview_vp.transparent_bg = false
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_vp.msaa_3d = Viewport.MSAA_4X
	svc.add_child(_preview_vp)

	# Own World3D so the body renders in isolation.
	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.085, 0.105, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.68)
	env.ambient_light_energy = 0.9
	world.environment = env
	_preview_vp.world_3d = world

	# Key + fill lights (mirrors IconRenderer setup).
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, -128, 0)
	key.light_energy = 1.4
	_preview_vp.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 60, 0)
	fill.light_energy = 0.38
	_preview_vp.add_child(fill)

	# Camera — perspective, framed on the full body (~1.8 m tall).
	var cam := Camera3D.new()
	cam.name = "PreviewCam"
	# Position slightly above center, pulled back enough to see the full figure.
	cam.position = Vector3(0.0, 0.9, 2.6)
	cam.look_at(Vector3(0.0, 0.9, 0.0), Vector3.UP)
	cam.fov = 42.0
	cam.near = 0.1
	cam.far = 30.0
	_preview_vp.add_child(cam)
	cam.current = true
	cam.make_current()

	# Pivot node — rotated each _process tick.
	_preview_pivot = Node3D.new()
	_preview_pivot.name = "PreviewPivot"
	_preview_vp.add_child(_preview_pivot)


# ── Category selection ────────────────────────────────────────────────────────


func _select_category(cat: String) -> void:
	_selected_cat = cat
	_update_cat_button_highlights()
	_rebuild_variant_grid()


func _update_cat_button_highlights() -> void:
	for cat in _cat_buttons:
		var btn: Button = _cat_buttons[cat]
		if cat == _selected_cat:
			btn.add_theme_color_override("font_color", COL_AMBER)
		else:
			btn.remove_theme_color_override("font_color")


# ── Variant grid ──────────────────────────────────────────────────────────────


## Clears and repopulates the variant grid for the currently-selected category.
## Thumbnails are loaded asynchronously after the cells are built.
func _rebuild_variant_grid() -> void:
	for c in _variant_grid.get_children():
		c.queue_free()

	var equipped_paint: String = MetaProgression.get_equipped_cosmetic("paint")
	var equipped_here: String = MetaProgression.get_equipped_cosmetic(_selected_cat)
	var variants: Array = ProceduralPlayer.variants_of(_selected_cat)

	for raw_v in variants:
		var v: Dictionary = raw_v as Dictionary
		var vid: String = String(v["id"])
		var vname: String = String(v["name"])
		var vcost: int = int(v["cost"])

		var is_equipped: bool = vid == equipped_here
		var is_unlocked: bool = MetaProgression.is_cosmetic_unlocked(vid)
		var can_afford: bool = MetaProgression.currency >= vcost

		var cell := _make_variant_cell(vid, vname, vcost, is_equipped, is_unlocked, can_afford)
		_variant_grid.add_child(cell)

		# Kick off async thumbnail load; captures cell ref for fill-in.
		_load_thumbnail_async(cell, _selected_cat, vid, equipped_paint)


## Builds one variant cell: thumbnail placeholder + name + equip/buy button.
func _make_variant_cell(
	vid: String, vname: String, vcost: int, is_equipped: bool, is_unlocked: bool, can_afford: bool
) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.name = "VCell_" + vid
	pc.size_flags_horizontal = Control.SIZE_FILL

	# Highlight equipped variant with amber border.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.13, 0.90)
	sb.set_border_width_all(2)
	sb.border_color = COL_AMBER if is_equipped else Color(0.20, 0.24, 0.28, 1.0)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	pc.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	pc.add_child(vbox)

	# ── Thumbnail placeholder (filled asynchronously) ─────────────────────────
	var thumb_panel := Panel.new()
	thumb_panel.name = "ThumbPanel"
	thumb_panel.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	thumb_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var thumb_sb := StyleBoxFlat.new()
	thumb_sb.bg_color = Color(0.12, 0.14, 0.18, 1.0)
	thumb_sb.set_border_width_all(1)
	thumb_sb.border_color = Color(0.20, 0.24, 0.28, 0.8)
	thumb_sb.set_corner_radius_all(3)
	thumb_panel.add_theme_stylebox_override("panel", thumb_sb)
	# Colored fallback box (shown until / if the async render fills in).
	var fallback := ColorRect.new()
	fallback.name = "Fallback"
	fallback.color = _variant_fallback_color(vid)
	fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
	fallback.offset_left = 8
	fallback.offset_top = 8
	fallback.offset_right = -8
	fallback.offset_bottom = -8
	fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_panel.add_child(fallback)
	vbox.add_child(thumb_panel)

	# ── Name label ────────────────────────────────────────────────────────────
	var name_lbl := Label.new()
	name_lbl.name = "NameLbl"
	name_lbl.text = tr(vname)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.custom_minimum_size = Vector2(float(THUMB_SIZE), 0.0)
	name_lbl.add_theme_color_override("font_color", COL_WHITE)
	name_lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(name_lbl)

	# ── Action button ─────────────────────────────────────────────────────────
	var action_btn := Button.new()
	action_btn.name = "ActionBtn"
	action_btn.focus_mode = Control.FOCUS_NONE
	action_btn.custom_minimum_size = Vector2(float(THUMB_SIZE), 26.0)
	UIStyle.hover_lift(action_btn)

	if is_equipped:
		action_btn.text = tr("EQUIPPED")
		action_btn.disabled = true
		action_btn.add_theme_color_override("font_color", COL_AMBER)
	elif is_unlocked:
		action_btn.text = tr("EQUIP")
		action_btn.disabled = false
		var vid_cap: String = vid
		action_btn.pressed.connect(func() -> void: _on_equip(vid_cap))
	elif vcost < 0:
		# Quest-exclusive — not for sale, only granted by a quest reward.
		action_btn.text = tr("★ QUEST REWARD")
		action_btn.disabled = true
		action_btn.add_theme_color_override("font_color", COL_AMBER)
	else:
		# Locked — show BUY with cost.
		action_btn.text = tr("BUY (CR %d)") % vcost
		action_btn.disabled = not can_afford
		if not can_afford:
			action_btn.add_theme_color_override("font_color", COL_RED)
		var vid_cap: String = vid
		action_btn.pressed.connect(func() -> void: _on_buy(vid_cap))

	vbox.add_child(action_btn)

	return pc


## Async: render the thumbnail for this variant cell, then fill in a TextureRect.
## If IconRenderer returns null (headless / failure), the ColorRect fallback stays.
func _load_thumbnail_async(cell: PanelContainer, cat: String, vid: String, paint: String) -> void:
	# We need to await, so this runs as a coroutine but we discard the return.
	_fill_thumbnail(cell, cat, vid, paint)


func _fill_thumbnail(cell: PanelContainer, cat: String, vid: String, paint: String) -> void:
	var tex: Texture2D = await IconRenderer.render_cosmetic(cat, vid, paint)
	# The cell may have been freed if the category changed while the render was in flight.
	if not is_instance_valid(cell):
		return
	if tex == null:
		return  # Fallback ColorRect stays.

	var tp: Panel = _find_child_of_type(cell, "ThumbPanel")
	if tp == null:
		return

	# Hide the fallback ColorRect and add a TextureRect.
	var fb: ColorRect = tp.get_node_or_null("Fallback")
	if fb != null:
		fb.visible = false

	var tex_rect := TextureRect.new()
	tex_rect.texture = tex
	tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex_rect.offset_left = 4
	tex_rect.offset_top = 4
	tex_rect.offset_right = -4
	tex_rect.offset_bottom = -4
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tp.add_child(tex_rect)


# ── Live 3D preview ───────────────────────────────────────────────────────────


func _rebuild_preview() -> void:
	if _preview_pivot == null or not _preview_pivot.is_inside_tree():
		return
	# Remove old body.
	for c in _preview_pivot.get_children():
		c.queue_free()
	_preview_body = ProceduralPlayer.build_player(MetaProgression.get_cosmetics())
	_preview_pivot.add_child(_preview_body)


# ── Signal handlers ───────────────────────────────────────────────────────────


func _on_cosmetics_changed() -> void:
	_refresh_currency()
	_rebuild_variant_grid()
	_rebuild_preview()


func _on_currency_changed(_amount: int) -> void:
	_refresh_currency()
	# Re-build grid to update affordability states.
	_rebuild_variant_grid()


# ── Actions ───────────────────────────────────────────────────────────────────


func _on_equip(vid: String) -> void:
	MetaProgression.set_equipped_cosmetic(vid)
	# cosmetics_changed fires → _on_cosmetics_changed → grid + preview refresh.


func _on_buy(vid: String) -> void:
	var newly_unlocked: bool = MetaProgression.unlock_cosmetic(vid)
	if newly_unlocked:
		MetaProgression.set_equipped_cosmetic(vid)
	# cosmetics_changed + currency_changed fire → full refresh.


# ── Helpers ───────────────────────────────────────────────────────────────────


func _refresh_currency() -> void:
	if _currency_label != null:
		_currency_label.text = tr("CR %d") % MetaProgression.currency


## Glass header-panel with spaced-caps label.
func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.section_bar(UIStyle.TEAL))
	pc.add_child(UIStyle.micro_header(tr(title), UIStyle.TEAL, 15))
	return pc


## A muted color representative of the variant category (used as fallback box tint).
func _variant_fallback_color(vid: String) -> Color:
	var cat: String = ProceduralPlayer.category_of(vid)
	match cat:
		"head":
			return Color(0.22, 0.28, 0.38, 1.0)
		"torso":
			return Color(0.20, 0.26, 0.32, 1.0)
		"arms":
			return Color(0.18, 0.24, 0.30, 1.0)
		"legs":
			return Color(0.16, 0.22, 0.28, 1.0)
		"paint":
			return Color(0.25, 0.20, 0.15, 1.0)
	return Color(0.18, 0.20, 0.24, 1.0)


## Breadth-first search for a named child node (name, not type) within `root`.
func _find_child_of_type(root: Node, child_name: String) -> Panel:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == child_name and n is Panel:
			return n as Panel
		for c in n.get_children():
			stack.append(c)
	return null
