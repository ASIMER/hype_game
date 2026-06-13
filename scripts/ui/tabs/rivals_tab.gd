extends Control
## RivalsTab — the 9th Hub tab (TAB_RIVALS = 8). The Machine Nemesis CODEX: the squad's
## ACTIVE rival (if one is alive out there) + the DEFEATED history, each shown with its
## serial / title / tier / learned counters and a SCARRED 3D portrait (rendered off the same
## ProceduralModels.apply_nemesis_scars the in-world rival uses, via IconRenderer.render_node).
##
## Data comes from NemesisDirector.codex_data() (host-only nemesis.cfg). On a pure client the
## host owns the persistent state, so the codex reads empty — that's expected.
## All nodes are built procedurally in _ready (mirrors progression_tab.gd). Refreshes on the
## nemesis Events so a kill / new rival updates the list live.

const COL_RED := Color(0.95, 0.16, 0.16)
const _TRAIT_LABELS := {
	"emp_hard": "EMP-HARDENED",
	"weakpoint_armored": "ARMORED CORE",
	"blast_hard": "BLAST-PLATED",
	"keen": "KEEN SENSORS",
}

var _list: VBoxContainer = null


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	_refresh()
	if not Events.nemesis_born.is_connected(_on_changed):
		Events.nemesis_born.connect(_on_changed)
	if not Events.nemesis_defeated.is_connected(_on_defeated):
		Events.nemesis_defeated.connect(_on_defeated)
	if not Events.nemesis_codex_synced.is_connected(_refresh):
		Events.nemesis_codex_synced.connect(_refresh)  # client mirror updated


func _exit_tree() -> void:
	if Events.nemesis_born.is_connected(_on_changed):
		Events.nemesis_born.disconnect(_on_changed)
	if Events.nemesis_defeated.is_connected(_on_defeated):
		Events.nemesis_defeated.disconnect(_on_defeated)
	if Events.nemesis_codex_synced.is_connected(_refresh):
		Events.nemesis_codex_synced.disconnect(_refresh)


func _on_changed(_serial: String, _title: String) -> void:
	_refresh()


func _on_defeated(_serial: String) -> void:
	_refresh()


# ── Layout ────────────────────────────────────────────────────────────────────
func _build_layout() -> void:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	scroll.add_child(margin)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 14)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_list)


func _refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()

	var title := Label.new()
	title.text = tr("RIVALS")
	UIStyle.make_header(title, COL_RED, 34, 3)
	_list.add_child(title)
	var intro := UIStyle.micro_header(
		tr("Machines that survived you — and remember."), UIStyle.DIM, 13
	)
	_list.add_child(intro)

	# Host reads the director directly; a co-op CLIENT reads the synced GameState mirror
	# (nemesis.cfg is host-only — pushed via NetworkManager.sync_nemesis_codex).
	var active: Variant = null
	var history: Array = []
	if GameState.is_local_authority_server():
		var dir: Node = get_node_or_null("/root/NemesisDirector")
		var data: Dictionary = dir.call("codex_data") if dir != null else {}
		active = data.get("active")
		history = data.get("history", []) if data.get("history") is Array else []
	else:
		active = GameState.nemesis_active if not GameState.nemesis_active.is_empty() else null
		history = GameState.nemesis_history

	# Active rival.
	_list.add_child(UIStyle.micro_header(tr("ACTIVE RIVAL"), COL_RED, 15))
	if active is Dictionary:
		_list.add_child(_make_card(active as Dictionary, true))
	else:
		var none := UIStyle.micro_header(
			tr("No active rival — the machines don't fear you yet."), UIStyle.DIM, 13
		)
		_list.add_child(none)

	# Defeated history.
	if not history.is_empty():
		_list.add_child(UIStyle.micro_header(tr("DEFEATED"), UIStyle.AMBER, 15))
		var grid := GridContainer.new()
		var avail: float = size.x if size.x > 0 else 900.0
		grid.columns = UILayout.columns_for(avail - 48.0, 300.0, 14, 3)
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 14)
		_list.add_child(grid)
		for d in history:
			if d is Dictionary:
				grid.add_child(_make_card(d as Dictionary, false))


# ── Card ────────────────────────────────────────────────────────────────────
func _make_card(d: Dictionary, is_active: bool) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override(
		"panel", UIStyle.header_panel(COL_RED if is_active else UIStyle.DIM, 0.82)
	)
	card.custom_minimum_size = Vector2(300, 120)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)

	# Scarred portrait (async; a red placeholder shows until/if the render lands).
	var port := PanelContainer.new()
	port.custom_minimum_size = Vector2(96, 96)
	var fb := ColorRect.new()
	fb.color = Color(0.12, 0.06, 0.06, 0.9)
	fb.custom_minimum_size = Vector2(96, 96)
	fb.name = "Fallback"
	port.add_child(fb)
	row.add_child(port)
	_load_portrait_async(port, d)

	# Identity + traits.
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var serial := Label.new()
	serial.text = String(d.get("serial", "?"))
	UIStyle.make_header(serial, COL_RED if is_active else UIStyle.WHITE, 20, 2)
	info.add_child(serial)
	var title_lbl := Label.new()
	title_lbl.text = String(d.get("title", ""))
	title_lbl.add_theme_color_override("font_color", UIStyle.DIM)
	info.add_child(title_lbl)
	var tier_lbl := Label.new()
	tier_lbl.text = tr("TIER %d") % int(d.get("tier", 1))
	tier_lbl.add_theme_color_override("font_color", UIStyle.AMBER)
	info.add_child(tier_lbl)
	info.add_child(_traits_row(d.get("traits", [])))
	return card


func _traits_row(traits: Variant) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	if traits is Array:
		for t in traits as Array:
			var chip := Label.new()
			chip.text = tr(String(_TRAIT_LABELS.get(String(t), String(t).to_upper())))
			chip.add_theme_font_size_override("font_size", 11)
			chip.add_theme_color_override("font_color", UIStyle.TEAL)
			box.add_child(chip)
	return box


## Build a scarred model for the rival's archetype and render it to the card's portrait.
func _load_portrait_async(port: PanelContainer, d: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var archetype := String(d.get("archetype", ""))
	if archetype == "":
		return
	var model: Node3D = AssetRegistry.get_model(archetype)
	if model == null:
		return
	ProceduralModels.apply_nemesis_scars(
		model, model, int(d.get("scar_seed", 0)), int(d.get("tier", 1))
	)
	var key := "nemesis:%s:%d" % [String(d.get("serial", "?")), int(d.get("tier", 1))]
	var tex: Texture2D = await IconRenderer.render_node(key, model)
	if not is_instance_valid(port) or tex == null:
		return
	var fb: ColorRect = port.get_node_or_null("Fallback")
	if fb != null:
		fb.visible = false
	var tr_rect := TextureRect.new()
	tr_rect.texture = tex
	tr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	port.add_child(tr_rect)
