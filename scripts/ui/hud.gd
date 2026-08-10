extends CanvasLayer
class_name HUD
## In-match heads-up display for the local client. Self-contained: listens on the
## global Events bus for everything it shows, so it never references gameplay nodes
## directly. Binds to the local player (for the health bar) via
## Events.local_player_spawned.
##
## Shows: health bar, wave label, extraction progress bar (hidden unless extracting),
## a centre crosshair dot, and a centred banner for match won / lost.

@onready var health_bar: ProgressBar = $Root/Health/HealthBar
@onready var health_label: Label = $Root/Health/HealthLabel
@onready var wave_label: Label = $Root/WaveLabel
@onready var extract_panel: Control = $Root/Extraction
@onready var extract_bar: ProgressBar = $Root/Extraction/ExtractBar
@onready var banner: Label = $Root/Banner

var _local_player: Node = null
static var _view_tip_shown: bool = false  # one-shot per session: V-toggle / appearance tip


func _ready() -> void:
	Events.local_player_spawned.connect(_on_local_player_spawned)
	Events.player_health_changed.connect(_on_player_health_changed)

	Events.wave_started.connect(_on_wave_started)
	Events.wave_cleared.connect(_on_wave_cleared)

	Events.extraction_started.connect(_on_extraction_started)
	Events.extraction_progress.connect(_on_extraction_progress)
	Events.extraction_completed.connect(_on_extraction_completed)
	Events.extraction_cancelled.connect(_on_extraction_cancelled)

	Events.match_won.connect(_on_match_won)
	Events.match_lost.connect(_on_match_lost)
	Events.run_rewards.connect(_on_run_rewards)

	Events.damage_dealt.connect(_on_damage_dealt)

	Events.weapon_switched.connect(_on_weapon_switched)
	Events.ammo_changed.connect(_on_ammo_changed)
	Events.reload_started.connect(func(_id): _set_reload(true))
	Events.reload_finished.connect(func(_id): _set_reload(false))

	Events.match_timer_changed.connect(_on_match_timer_changed)
	Events.final_wave_started.connect(_on_final_wave_started)

	# Co-op DOWNED / REVIVE feedback.
	Events.player_downed.connect(_on_player_downed)
	Events.player_revived.connect(_on_player_revived)
	Events.player_bleedout.connect(_on_player_bleedout)

	# World events + environmental surge.
	Events.world_event_started.connect(_on_world_event_started)
	Events.environmental_surge_changed.connect(_on_surge_changed)

	# Machine Nemesis — the rival's story beats (born / returns / defeated).
	Events.nemesis_born.connect(_on_nemesis_born)
	Events.nemesis_returned.connect(_on_nemesis_returned)
	Events.nemesis_defeated.connect(_on_nemesis_defeated)

	# Power-Core Beacon (Phase 4) — reuses the red banner widget.
	Events.power_core_spawned.connect(_on_power_core_spawned)
	Events.power_core_extracted.connect(_on_power_core_extracted)

	# Raid mutator chip (batch C) — set before deploy, re-synced at match start.
	Events.raid_mutator_changed.connect(_on_mutator_changed)

	# Status-effect chips (batch B: bleed / fracture / painkiller, local player only).
	Events.status_changed.connect(_on_status_changed)

	extract_panel.visible = false
	# Nudge the extraction progress panel LOWER so it never overlaps the bottom-centre
	# interaction prompt (interaction_prompt.gd sits at offset_top=-158..bottom=-120).
	# Authored at -110..-84; lowering to -96..-70 leaves a ~24px gap above the prompt.
	extract_panel.offset_top = -96.0
	extract_panel.offset_bottom = -70.0
	banner.visible = false
	# Glass theme variations for the progress bars.
	health_bar.theme_type_variation = "FillAmber"
	extract_bar.add_theme_stylebox_override("fill", UIStyle.glow_fill(UIStyle.TEAL))
	_set_health(Settings.PLAYER_MAX_HEALTH, Settings.PLAYER_MAX_HEALTH)
	_update_wave_label(GameState.current_wave)
	_build_feedback_overlays()
	_build_hud_widgets()


# --- Crosshair / minimap / key-hints / ammo (built in code) ----------------

var _crosshair: Control
var _minimap: Control
var _ammo_label: Label
var _grenade_label: Label  # selected grenade chip (batch A; Events.grenade_selection_changed)
var _weapon_label: Label
var _reloading: bool = false
var _current_weapon_name: String = "RIFLE"
var _timer_label: Label
var _mutator_label: Label  # raid-mutator chip under the match timer (batch C)
var _status_row: HBoxContainer  # status-effect chips (batch B), above the health bar
var _status_chips: Dictionary = {}  # effect name -> the chip Label
var _storm_banner: Label
var _storm_banner_t: float = 0.0
# World-event banner — stacked 44px below the storm banner (offset_top -76 vs -120).
var _event_banner: Label
var _event_banner_t: float = 0.0

var _nemesis_banner: Label  # Machine Nemesis born/returns/defeated (red, above the others)
var _nemesis_banner_t: float = 0.0
# Surge vignette — a subtle colour-rect pulse while a sensor-blackout surge is active.
var _surge_vignette: ColorRect
var _surge_active: bool = false
var _surge_pulse: float = 0.0

# Edge-anchored widgets that re-inset toward center for ultrawide comfort, each paired
# with its cached AUTHORED offsets so the inset is idempotent (recomputed from base,
# never accumulated). { node: Control, edge: String("rb"|"lb"), l/t/r/b: float }
var _inset_widgets: Array = []


func _build_hud_widgets() -> void:
	# Replace the static dot with the dynamic spread crosshair.
	var static_cross := $Root.get_node_or_null("Crosshair")
	if static_cross:
		static_cross.visible = false
	_crosshair = (load("res://scripts/ui/crosshair.gd") as Script).new()
	$Root.add_child(_crosshair)
	_minimap = (load("res://scripts/ui/minimap.gd") as Script).new()
	$Root.add_child(_minimap)
	# Skill hotbar (Mutant Harvest) — bottom-center, fills as the player harvests skills.
	$Root.add_child((load("res://scripts/ui/skill_hotbar.gd") as Script).new())

	# Match-timer readout (mm:ss), top-centre just under the wave label. Goes red as
	# the storm approaches. Polls GameState as a fallback so it shows even before the
	# first Events.match_timer_changed push.
	_timer_label = Label.new()
	_timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# Sit clear of the top-centre compass strip (its bottom edge is ~y=38).
	_timer_label.offset_top = 80.0
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_label.add_theme_font_size_override("font_size", 22)
	_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_timer_label.add_theme_constant_override("outline_size", 4)
	_timer_label.text = ""
	$Root.add_child(_timer_label)

	# Raid-mutator chip just under the match timer (visible only when a mutator is
	# active this raid). Violet to read as "world rule", not a warning.
	_mutator_label = Label.new()
	_mutator_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_mutator_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_mutator_label.offset_top = 106.0
	_mutator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mutator_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mutator_label.add_theme_font_size_override("font_size", 15)
	_mutator_label.add_theme_color_override("font_color", Color(0.78, 0.55, 0.95))
	_mutator_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_mutator_label.add_theme_constant_override("outline_size", 4)
	_mutator_label.visible = false
	$Root.add_child(_mutator_label)
	_on_mutator_changed(GameState.raid_mutator)

	# Status-effect chip row (batch B), bottom-left above the health bar: small
	# colored capsules that appear while bleed/fracture/painkiller are active.
	_status_row = HBoxContainer.new()
	_status_row.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_status_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_status_row.offset_left = 24.0
	_status_row.offset_top = -96.0
	_status_row.offset_bottom = -76.0
	_status_row.add_theme_constant_override("separation", 6)
	_status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Root.add_child(_status_row)
	for effect in [
		["bleed", "BLEEDING", UIStyle.RED],
		["fracture", "FRACTURE", Color(1.0, 0.6, 0.2)],
		["painkiller", "PAINKILLER", UIStyle.TEAL]
	]:  # gdlint: ignore=max-line-length
		var chip := Label.new()
		chip.text = tr(String(effect[1]))
		chip.visible = false
		chip.add_theme_font_size_override("font_size", 13)
		chip.add_theme_color_override("font_color", effect[2])
		chip.add_theme_stylebox_override("normal", UIStyle.chip(effect[2]))
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_status_row.add_child(chip)
		_status_chips[String(effect[0])] = chip

	# Make the wave counter PROMINENT — it was a small grey label tucked behind the
	# compass strip (easy to miss). Russo One amber, clear of the compass, above the timer.
	wave_label.offset_top = 44.0
	wave_label.offset_bottom = 78.0
	UIStyle.make_header(wave_label, UIStyle.AMBER, 26, 3)
	wave_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	wave_label.add_theme_constant_override("outline_size", 5)

	# Final-wave warning banner ("STORM INCOMING"), centred a little above middle.
	# Hidden until Events.final_wave_started; then flashes briefly.
	_storm_banner = Label.new()
	_storm_banner.set_anchors_preset(Control.PRESET_CENTER)
	_storm_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_storm_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_storm_banner.offset_top = -120.0
	_storm_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_storm_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_storm_banner.add_theme_font_size_override("font_size", 30)
	_storm_banner.add_theme_color_override("font_color", UIStyle.RED)
	_storm_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_storm_banner.add_theme_constant_override("outline_size", 5)
	_storm_banner.text = tr("⚠ STORM INCOMING — EXTRACT")
	_storm_banner.visible = false
	$Root.add_child(_storm_banner)

	# World-event banner — placed 44px below the storm banner so the two never overlap.
	# Storm banner sits at offset_top -120; event banner at -76, giving a clear gap.
	# Both are centred horizontally so they don't fight the killfeed (top-left) or the
	# wave/timer labels (top-centre above y=46). The banner auto-fades after ~4s.
	_event_banner = Label.new()
	_event_banner.set_anchors_preset(Control.PRESET_CENTER)
	_event_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_event_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_event_banner.offset_top = -76.0
	_event_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_event_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_event_banner.add_theme_font_size_override("font_size", 24)
	_event_banner.add_theme_color_override("font_color", UIStyle.AMBER)
	_event_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_event_banner.add_theme_constant_override("outline_size", 4)
	_event_banner.text = ""
	_event_banner.visible = false
	$Root.add_child(_event_banner)

	# Machine Nemesis banner — highest of the three (offset_top -160 so it never overlaps the
	# storm/event banners), blood-red to match the rival's signature ring.
	_nemesis_banner = Label.new()
	_nemesis_banner.set_anchors_preset(Control.PRESET_CENTER)
	_nemesis_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_nemesis_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_nemesis_banner.offset_top = -160.0
	_nemesis_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_nemesis_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_nemesis_banner.add_theme_font_size_override("font_size", 26)
	_nemesis_banner.add_theme_color_override("font_color", Color(0.95, 0.16, 0.16))
	_nemesis_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_nemesis_banner.add_theme_constant_override("outline_size", 5)
	_nemesis_banner.text = ""
	_nemesis_banner.visible = false
	$Root.add_child(_nemesis_banner)

	# Sensor-surge vignette — a very faint orange/green tint at the screen edges while
	# the blackout is active. Kept subtle (max alpha 0.12) so it reads as ambience
	# rather than damage. Uses MOUSE_FILTER_IGNORE so it never eats input.
	_surge_vignette = ColorRect.new()
	_surge_vignette.color = Color(0.05, 0.3, 0.05, 0.0)
	_surge_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_surge_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surge_vignette.visible = false
	add_child(_surge_vignette)

	# UX overlay components (authored by hud-dev). Guarded so the HUD works whether
	# or not they exist yet; each is a self-contained Control that listens to Events.
	for comp in ["interaction_prompt", "stamina_bar", "compass", "killfeed", "damage_indicator"]:
		var comp_path := "res://scripts/ui/%s.gd" % comp
		if ResourceLoader.exists(comp_path):
			$Root.add_child((load(comp_path) as Script).new())

	# Ammo + weapon readout, pinned to the bottom-right corner and GROWING up-left
	# (grow BEGIN) so multi-line content never clips off-screen at any resolution.
	var ammo_box := VBoxContainer.new()
	ammo_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ammo_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ammo_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ammo_box.offset_right = -16.0
	ammo_box.offset_bottom = -16.0
	ammo_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Root.add_child(ammo_box)
	_weapon_label = Label.new()
	_weapon_label.add_theme_font_size_override("font_size", 16)
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_weapon_label.text = "RIFLE"
	ammo_box.add_child(_weapon_label)
	_ammo_label = Label.new()
	_ammo_label.add_theme_font_size_override("font_size", 26)
	_ammo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ammo_label.text = "-- / --"
	ammo_box.add_child(_ammo_label)
	# Selected grenade type + count (B cycles; hidden until something is brought).
	_grenade_label = Label.new()
	_grenade_label.add_theme_font_size_override("font_size", 13)
	_grenade_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_grenade_label.add_theme_color_override("font_color", UIStyle.AMBER)
	_grenade_label.visible = false
	ammo_box.add_child(_grenade_label)
	Events.grenade_selection_changed.connect(_on_grenade_selection_changed)

	# Key hints (bottom-right, above the ammo box, dim, right-aligned, grow up-left).
	var hints := Label.new()
	hints.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hints.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hints.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hints.offset_right = -16.0
	hints.offset_bottom = -86.0
	hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.add_theme_font_size_override("font_size", 13)
	hints.add_theme_color_override(
		"font_color", Color(UIStyle.DIM.r, UIStyle.DIM.g, UIStyle.DIM.b, 0.7)
	)
	# This long string is a LOCALIZATION KEY (locale/ui.csv) — splitting it would break
	# the translation lookup, so it stays one line.
	hints.text = tr(
		"WASD Move   Shift Sprint   Space Jump\nLMB Fire   RMB Aim   V Camera Zoom\n1-5 / Wheel Weapon   R Reload\nG Grenade   H Heal   E Loot   I Inventory   M Map"  # gdlint: ignore=max-line-length
	)
	$Root.add_child(hints)

	# --- Ultrawide-comfort inset: pull edge-anchored widgets toward center -----
	# ammo box + key hints are RIGHT+BOTTOM ("rb"); the health bar (HUD.tscn) is
	# LEFT+BOTTOM ("lb"). Cache each node's authored offsets ONCE.
	var health: Control = $Root.get_node_or_null(Groups.NODE_HEALTH)
	_register_inset(ammo_box, "rb")
	_register_inset(hints, "rb")
	if health != null:
		_register_inset(health, "lb")
	_apply_hud_inset()
	if not Events.ui_layout_changed.is_connected(_apply_hud_inset):
		Events.ui_layout_changed.connect(_apply_hud_inset)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_hud_inset):
		vp.size_changed.connect(_apply_hud_inset)


## Cache a widget's authored offsets + its edge classification for the inset pass.
func _register_inset(node: Control, edge: String) -> void:
	if node == null:
		return
	(
		_inset_widgets
		. append(
			{
				"node": node,
				"edge": edge,
				"l": node.offset_left,
				"t": node.offset_top,
				"r": node.offset_right,
				"b": node.offset_bottom,
			}
		)
	)


## Re-inset every registered edge widget from its cached BASE offsets (idempotent;
## at margin 0 → ex=ty=0 → offsets unchanged). Whole box shifts on each inset axis so
## its size is preserved.
func _apply_hud_inset() -> void:
	var sz: Vector2 = get_viewport().get_visible_rect().size
	var ex: float = UILayout.edge_px(sz.x)
	var ty: float = UILayout.top_px(sz.y)
	for w in _inset_widgets:
		var node: Control = w["node"]
		if not is_instance_valid(node):
			continue
		var bl: float = w["l"]
		var bt: float = w["t"]
		var br: float = w["r"]
		var bb: float = w["b"]
		var edge: String = w["edge"]
		# Horizontal: RIGHT edge → shift LEFT by ex; LEFT edge → shift RIGHT by ex.
		var dx: float = -ex if edge.begins_with("r") else ex
		# Vertical: both classes are BOTTOM edge → shift UP by ty.
		var dy: float = -ty
		node.offset_left = bl + dx
		node.offset_right = br + dx
		node.offset_top = bt + dy
		node.offset_bottom = bb + dy


func _on_weapon_switched(weapon_id: String, ammo: int, reserve: int) -> void:
	_current_weapon_name = weapon_id.to_upper()
	_reloading = false
	_refresh_weapon_label()
	_set_ammo(ammo, reserve)


func _refresh_weapon_label() -> void:
	if _weapon_label:
		_weapon_label.text = _current_weapon_name + (tr("  (RELOADING)") if _reloading else "")


func _on_ammo_changed(ammo: int, reserve: int) -> void:
	_set_ammo(ammo, reserve)


func _set_ammo(ammo: int, reserve: int) -> void:
	if _ammo_label:
		var res := "∞" if reserve >= 9999 else str(reserve)
		_ammo_label.text = "%d / %s" % [ammo, res]
		_ammo_label.modulate = Color(1, 0.5, 0.4) if ammo <= 0 else Color(1, 1, 1)


func _set_reload(active: bool) -> void:
	_reloading = active
	_refresh_weapon_label()


## Selected-grenade chip: "[B] EMP GRENADE x2". Hidden when nothing is carried.
func _on_grenade_selection_changed(type: String, count: int) -> void:
	if _grenade_label == null:
		return
	if count <= 0:
		_grenade_label.visible = false
		return
	var names := {
		"frag": tr("Frag Grenade"),
		"smoke": tr("Smoke Grenade"),
		"emp": tr("EMP Grenade"),
		"decoy": tr("Noise Decoy"),
	}
	_grenade_label.text = "[B] %s x%d" % [String(names.get(type, type)).to_upper(), count]
	_grenade_label.visible = true


# --- Feedback overlays (built in code so HUD.tscn stays simple) -------------

var _hurt_flash: ColorRect
var _hit_marker: Label
var _hit_marker_t: float = 0.0
var _last_health: float = -1.0

# --- Co-op DOWNED / REVIVE feedback (built in code) ------------------------
# Local-player downed: a red pulsing fullscreen vignette + centred label + bleedout
# countdown ring, plus a directional arrow toward any downed TEAMMATE. Everything is
# drawn by a single full-rect overlay Control whose `draw` signal we drive.
const DOWN_RED := UIStyle.RED  # downed vignette / ring danger red
const TEAM_AMBER := UIStyle.AMBER  # teammate-down arrow
const REVIVE_BADGE_THRESHOLD := 3  # (mirrored note; badge lives in scoreboard.gd)

var _down_overlay: Control  # full-rect Control that paints the downed feedback
var _down_label: Label  # "DOWNED — bleeding out" + hint
var _team_label: Label  # small "Teammate down" caption
var _down_active: bool = false  # is the LOCAL player downed?
var _bleed_left: float = 0.0  # local countdown (s), driven from player_downed
var _bleed_total: float = Settings.BLEEDOUT_TIME
var _down_pulse: float = 0.0  # vignette pulse phase
# Teammate-down directional state, refreshed (throttled) in _process.
var _team_down_angle: float = 0.0  # screen radians toward the nearest downed teammate (0 = up)
var _team_down_shown: bool = false
var _team_poll_t: float = 0.0


func _build_feedback_overlays() -> void:
	# Full-screen red vignette pulse when the local player takes damage.
	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(0.8, 0.0, 0.0, 0.0)
	_hurt_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hurt_flash)
	# Center hit marker shown briefly when the local player damages an enemy.
	_hit_marker = Label.new()
	_hit_marker.text = "x"
	_hit_marker.add_theme_font_size_override("font_size", 26)
	_hit_marker.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hit_marker.set_anchors_preset(Control.PRESET_CENTER)
	_hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_marker.visible = false
	add_child(_hit_marker)
	_build_downed_overlay()


## Full-rect overlay that paints (a) the local-player downed vignette + bleedout ring and
## (b) the teammate-down directional arrow. We drive its `draw` signal so all the custom
## painting lives in one cheap place, only redrawn when its state changes.
func _build_downed_overlay() -> void:
	_down_overlay = Control.new()
	_down_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_down_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_down_overlay.visible = false
	_down_overlay.draw.connect(_draw_downed_overlay)
	add_child(_down_overlay)

	# Centred DOWNED label + hint (above the ring).
	_down_label = Label.new()
	_down_label.set_anchors_preset(Control.PRESET_CENTER)
	_down_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_down_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_down_label.offset_top = -150.0
	_down_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_down_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_down_label.add_theme_font_size_override("font_size", 30)
	_down_label.add_theme_color_override("font_color", UIStyle.RED)
	_down_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_down_label.add_theme_constant_override("outline_size", 5)
	_down_label.text = ""
	_down_label.visible = false
	$Root.add_child(_down_label)

	# Small "Teammate down" caption near the top-centre (under the timer area).
	_team_label = Label.new()
	_team_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_team_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_team_label.offset_top = 84.0
	_team_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_team_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_team_label.add_theme_font_size_override("font_size", 16)
	_team_label.add_theme_color_override("font_color", TEAM_AMBER)
	_team_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_team_label.add_theme_constant_override("outline_size", 4)
	_team_label.text = tr("⚑ TEAMMATE DOWN")
	_team_label.visible = false
	$Root.add_child(_team_label)


func _process(delta: float) -> void:
	if _hurt_flash and _hurt_flash.color.a > 0.0:
		_hurt_flash.color.a = maxf(0.0, _hurt_flash.color.a - delta * 2.4)
	if _hit_marker and _hit_marker.visible:
		_hit_marker_t -= delta
		if _hit_marker_t <= 0.0:
			_hit_marker.visible = false
	# Poll the match timer each frame as a fallback (Events.match_timer_changed also
	# pushes it). Cheap; keeps the readout live even if the push is throttled.
	_refresh_match_timer(GameState.match_time_left, GameState.match_duration)
	# Co-op DOWNED: drive the local bleedout countdown + vignette pulse (locally; the real
	# resolution is server-authoritative — this is just the visual timer), redraw while down.
	if _down_active:
		_bleed_left = maxf(0.0, _bleed_left - delta)
		_down_pulse += delta
		if _down_overlay:
			_down_overlay.queue_redraw()
	# Throttled poll for a downed teammate (~6 Hz). Cheap; redraws only on state change.
	_team_poll_t -= delta
	if _team_poll_t <= 0.0:
		_team_poll_t = 0.16
		_update_teammate_down()
	# Keep the teammate arrow pulsing while shown (even when the local player is up).
	if _team_down_shown and not _down_active:
		_down_pulse += delta
		if _down_overlay:
			_down_overlay.queue_redraw()
	# Fade the storm banner out after its flash.
	if _storm_banner and _storm_banner.visible:
		_storm_banner_t -= delta
		_storm_banner.modulate.a = (
			clampf(_storm_banner_t / 1.0, 0.0, 1.0) if _storm_banner_t < 1.0 else 1.0
		)
		# Keep a steady pulse while it lingers, then hide.
		if _storm_banner_t <= 0.0:
			_storm_banner.visible = false
	# Fade the world-event banner.
	if _event_banner and _event_banner.visible:
		_event_banner_t -= delta
		_event_banner.modulate.a = (
			clampf(_event_banner_t / 1.0, 0.0, 1.0) if _event_banner_t < 1.0 else 1.0
		)
		if _event_banner_t <= 0.0:
			_event_banner.visible = false

	if _nemesis_banner and _nemesis_banner.visible:
		_nemesis_banner_t -= delta
		_nemesis_banner.modulate.a = (
			clampf(_nemesis_banner_t / 1.0, 0.0, 1.0) if _nemesis_banner_t < 1.0 else 1.0
		)
		if _nemesis_banner_t <= 0.0:
			_nemesis_banner.visible = false
	# Pulse the surge vignette while active.
	if _surge_active and _surge_vignette != null:
		_surge_pulse += delta
		var p: float = 0.5 + 0.5 * sin(_surge_pulse * 2.0)
		_surge_vignette.color.a = 0.04 + 0.08 * p  # 0.04..0.12 — subtle


# --- World events + environmental surge ------------------------------------


func _on_world_event_started(kind: int, _pos: Vector3, label: String) -> void:
	if _event_banner == null:
		return
	# Pick a colour per event kind matching the map accent colours.
	var col: Color
	match kind:
		0:
			col = UIStyle.AMBER  # supply_cache — amber
		1:
			col = Color(0.95, 0.30, 0.95)  # miniboss — magenta
		2:
			col = UIStyle.TEAL  # contested_poi — teal/cyan
		3:
			col = Color(1.00, 0.55, 0.15)  # surge — orange
		_:
			col = UIStyle.WHITE
	_event_banner.text = tr("⚠ %s") % label.to_upper()
	_event_banner.add_theme_color_override("font_color", col)
	_event_banner.visible = true
	_event_banner.modulate.a = 1.0
	_event_banner_t = 4.0


func _on_surge_changed(active: bool, kind: int) -> void:
	# Only the sensor-blackout surge (kind 1) triggers the vignette.
	if kind != 1:
		return
	_surge_active = active
	if _surge_vignette == null:
		return
	if active:
		_surge_vignette.visible = true
		_surge_pulse = 0.0
	else:
		_surge_vignette.visible = false
		_surge_vignette.color.a = 0.0


## Raid-mutator chip (batch C). The display names are tr-able CSV keys shared with
## the tactical map — keep both in sync when adding a mutator.
static func mutator_display(mutator: String) -> String:
	match mutator:
		"fog":
			return "Fog"
		"double_loot":
			return "Double Loot"
		"elite_patrols":
			return "Elite Patrols"
		"night_raid":
			return "Night Raid"
	return mutator.capitalize()


func _on_mutator_changed(mutator: String) -> void:
	if _mutator_label == null:
		return
	_mutator_label.visible = mutator != ""
	if mutator != "":
		_mutator_label.text = tr("MUTATOR: %s") % tr(mutator_display(mutator))


## Status-effect chips (batch B): toggle the matching capsule — LOCAL player only
## (statuses are authority-local, but co-op still routes every peer's signal here).
func _on_status_changed(player: Node, effect: String, active: bool) -> void:
	if player == null or not is_instance_valid(player) or not player.is_multiplayer_authority():
		return
	var chip: Label = _status_chips.get(effect)
	if chip != null:
		chip.visible = active


func _exit_tree() -> void:
	# Disconnect signals connected in _ready that are NOT connected via lambda (lambdas
	# are auto-freed with the node). Named callbacks need explicit disconnection to avoid
	# lingering references when the HUD is removed mid-session.
	if Events.world_event_started.is_connected(_on_world_event_started):
		Events.world_event_started.disconnect(_on_world_event_started)
	if Events.environmental_surge_changed.is_connected(_on_surge_changed):
		Events.environmental_surge_changed.disconnect(_on_surge_changed)
	if Events.nemesis_born.is_connected(_on_nemesis_born):
		Events.nemesis_born.disconnect(_on_nemesis_born)
	if Events.nemesis_returned.is_connected(_on_nemesis_returned):
		Events.nemesis_returned.disconnect(_on_nemesis_returned)
	if Events.nemesis_defeated.is_connected(_on_nemesis_defeated):
		Events.nemesis_defeated.disconnect(_on_nemesis_defeated)
	if Events.power_core_spawned.is_connected(_on_power_core_spawned):
		Events.power_core_spawned.disconnect(_on_power_core_spawned)
	if Events.power_core_extracted.is_connected(_on_power_core_extracted):
		Events.power_core_extracted.disconnect(_on_power_core_extracted)


# --- Match timer / storm warning -------------------------------------------


func _on_match_timer_changed(left: float, total: float) -> void:
	_refresh_match_timer(left, total)


func _refresh_match_timer(left: float, total: float) -> void:
	if _timer_label == null:
		return
	if total <= 0.0 and left <= 0.0:
		# No match timer configured / not started — keep the readout empty.
		_timer_label.text = ""
		return
	if GameState.final_wave:
		_timer_label.text = tr("⚠ FINAL WAVE")
		_timer_label.add_theme_color_override("font_color", UIStyle.RED)
		return
	var l: float = maxf(0.0, left)
	var s: int = int(ceil(l))
	_timer_label.text = "%d:%02d" % [s / 60, s % 60]
	if l <= Settings.FINAL_WAVE_WARN:
		_timer_label.add_theme_color_override("font_color", UIStyle.RED)
	else:
		_timer_label.add_theme_color_override("font_color", UIStyle.TEXT)


func _on_final_wave_started() -> void:
	if _storm_banner:
		_storm_banner.visible = true
		_storm_banner.modulate.a = 1.0
		_storm_banner_t = 4.0  # lingers ~4s, then fades in the final second


func _flash_nemesis_banner(text: String, secs: float) -> void:
	if _nemesis_banner == null:
		return
	_nemesis_banner.text = text
	_nemesis_banner.visible = true
	_nemesis_banner.modulate.a = 1.0
	_nemesis_banner_t = secs


func _on_nemesis_born(serial: String, _title: String) -> void:
	_flash_nemesis_banner(tr("%s ESCAPED — IT WILL REMEMBER") % serial, 4.0)


func _on_nemesis_returned(serial: String, title: String, _node: Node) -> void:
	var who: String = "%s, %s" % [serial, title] if title != "" else serial
	_flash_nemesis_banner(tr("%s — HUNTING YOU") % who.to_upper(), 5.0)


func _on_nemesis_defeated(serial: String) -> void:
	_flash_nemesis_banner(tr("%s IS SCRAP") % serial, 4.0)


func _on_power_core_spawned(_node: Node) -> void:
	_flash_nemesis_banner(tr("⚡ POWER CORE DROPPED — CARRY IT OUT"), 4.0)


func _on_power_core_extracted(_peer: int) -> void:
	Events.notify.emit(tr("Power Core extracted!"), 1)
	if _timer_label:
		_timer_label.text = tr("⚠ FINAL WAVE")
		_timer_label.add_theme_color_override("font_color", UIStyle.RED)


## Tints the screen on local-player damage and pops a hit marker when the local
## player damages an enemy. damage_dealt(target, amount, source).
func _on_damage_dealt(target: Node, _amount: float, source: Node) -> void:
	if _is_local(target) and target == _local_player:
		# A light wash only — the DIRECTIONAL blood arc (damage_indicator.gd) is the
		# primary "where am I being hit from" cue, so keep this from drowning it in red.
		if _hurt_flash:
			_hurt_flash.color.a = maxf(_hurt_flash.color.a, 0.22)
	elif (
		source != null
		and source == _local_player
		and target != null
		and target.is_in_group(Groups.ENEMIES)
	):
		if _hit_marker:
			_hit_marker.visible = true
			_hit_marker_t = 0.12


# --- Co-op DOWNED / REVIVE -------------------------------------------------


func _on_player_downed(player: Node, _by: Node) -> void:
	if _is_local(player) and player == _local_player:
		# LOCAL player went down — start the bleedout countdown + vignette.
		_down_active = true
		_bleed_left = Settings.BLEEDOUT_TIME
		_bleed_total = Settings.BLEEDOUT_TIME
		_down_pulse = 0.0
		_refresh_downed_label()
		if _down_label:
			_down_label.visible = true
		if _down_overlay:
			_down_overlay.visible = true
			_down_overlay.queue_redraw()


func _on_player_revived(player: Node, _by: Node) -> void:
	if _is_local(player) and player == _local_player:
		_hide_downed()


func _on_player_bleedout(player: Node) -> void:
	if _is_local(player) and player == _local_player:
		_hide_downed()


func _hide_downed() -> void:
	_down_active = false
	_bleed_left = 0.0
	if _down_label:
		_down_label.visible = false
	if _down_overlay:
		_down_overlay.visible = false
		_down_overlay.queue_redraw()


## Builds the centred downed prompt, including a self-revive hint when the local player
## actually carries a Self-Revive Kit.
func _refresh_downed_label() -> void:
	if _down_label == null:
		return
	var opts := tr("teammate can revive you") + "   ·   " + tr("hold [X] to give up")
	if (
		_local_player != null
		and "_self_revives" in _local_player
		and int(_local_player._self_revives) > 0
	):
		opts = tr("[H] Self-Revive") + "   ·   " + opts
	_down_label.text = (
		tr("DOWNED — bleeding out")
		+ "\n"
		+ tr("Crawl (WASD) to cover or an OPEN evac to escape")
		+ "\n"
		+ opts
	)


## Throttled poll for the nearest DOWNED teammate (not the local player). Computes the
## on-screen bearing the same way damage_indicator.gd does (world→camera-relative yaw).
func _update_teammate_down() -> void:
	var local_id: int = GameState.local_peer_id()
	var nearest: Node3D = null
	var best_d: float = INF
	var origin := Vector3.ZERO
	var have_origin := false
	if is_instance_valid(_local_player) and _local_player is Node3D:
		origin = (_local_player as Node3D).global_position
		have_origin = true
	# Any peer flagged downed in GameState, excluding the local player.
	for pid_key in GameState.downed.keys():
		var pid: int = int(pid_key)
		if pid == local_id or not GameState.is_downed(pid):
			continue
		var node := _find_player_node(pid)
		if node == null:
			continue
		if have_origin:
			var d: float = origin.distance_squared_to(node.global_position)
			if d < best_d:
				best_d = d
				nearest = node
		elif nearest == null:
			nearest = node
	var want: bool = nearest != null
	var changed: bool = want != _team_down_shown
	if want and have_origin:
		var to_t: Vector3 = nearest.global_position - origin
		var world_bearing := atan2(to_t.x, -to_t.z)  # 0 = -Z (forward), CW
		var cam_yaw: float = (_local_player as Node3D).rotation.y
		var cam: Camera3D = _local_player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
		if is_instance_valid(cam):
			cam_yaw = cam.global_rotation.y
		var new_angle := wrapf(world_bearing - cam_yaw, -PI, PI)
		if absf(new_angle - _team_down_angle) > 0.01:
			changed = true
		_team_down_angle = new_angle
	_team_down_shown = want
	if _team_label:
		_team_label.visible = want
	if changed and _down_overlay:
		# Show the arrow even if the local player is up (overlay then only paints the arrow).
		_down_overlay.visible = _down_active or want
		_down_overlay.queue_redraw()


## Locate the spawned player node for a peer id (named str(peer_id), in group "players").
func _find_player_node(pid: int) -> Node3D:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p is Node3D and p.name == str(pid):
			return p
	return null


## Paints the local-player downed vignette + bleedout ring, and the teammate-down arrow.
func _draw_downed_overlay() -> void:
	if _down_overlay == null:
		return
	var vp: Vector2 = _down_overlay.get_viewport_rect().size
	var c: Vector2 = vp * 0.5
	# (a) LOCAL downed: pulsing red edge vignette + a depleting bleedout ring at centre.
	if _down_active:
		var pulse: float = 0.6 + 0.4 * sin(_down_pulse * 4.0)
		var base_a: float = 0.42 * pulse
		var band: float = 150.0
		var steps := 6
		for i in steps:
			var f: float = float(i) / float(steps)
			var a: float = base_a * (1.0 - f)
			var col := Color(DOWN_RED.r, DOWN_RED.g, DOWN_RED.b, a)
			var t: float = band * (1.0 - f)
			_down_overlay.draw_rect(Rect2(0, 0, vp.x, t), col, true)
			_down_overlay.draw_rect(Rect2(0, vp.y - t, vp.x, t), col, true)
			_down_overlay.draw_rect(Rect2(0, 0, t, vp.y), col, true)
			_down_overlay.draw_rect(Rect2(vp.x - t, 0, t, vp.y), col, true)
		# Bleedout ring — drains clockwise as the countdown runs out.
		var ratio: float = clampf(_bleed_left / maxf(_bleed_total, 0.001), 0.0, 1.0)
		var ring_r: float = 46.0
		var ring_c: Vector2 = c + Vector2(0, 6.0)
		# Track (dim full circle) then the live remaining arc on top.
		_down_overlay.draw_arc(ring_c, ring_r, 0.0, TAU, 48, Color(0, 0, 0, 0.55), 6.0, true)
		var start_a: float = -PI * 0.5  # 12 o'clock
		var end_a: float = start_a + TAU * ratio
		var ring_col := DOWN_RED if ratio > 0.33 else Color(1.0, 0.85, 0.2)
		_down_overlay.draw_arc(ring_c, ring_r, start_a, end_a, 48, ring_col, 6.0, true)
		# Seconds remaining inside the ring.
		var font: Font = _down_overlay.get_theme_default_font()
		if font != null:
			var secs: int = int(ceil(maxf(0.0, _bleed_left)))
			var txt: String = str(secs)
			var fs := 28
			var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_down_overlay.draw_string(
				font,
				ring_c + Vector2(-tw * 0.5, fs * 0.35),
				txt,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				fs,
				Color(1, 1, 1, 0.95)
			)
		# Give-up hold progress — an amber arc fills inside the ring while you hold [X].
		var gu: float = 0.0
		if _local_player != null and _local_player.has_method("give_up_ratio"):
			gu = float(_local_player.give_up_ratio())
		if gu > 0.001:
			_down_overlay.draw_arc(
				ring_c,
				ring_r - 12.0,
				start_a,
				start_a + TAU * gu,
				40,
				Color(0.95, 0.7, 0.2, 0.95),
				4.0,
				true
			)
			if font != null:
				var glbl := tr("GIVING UP…")
				var gw: float = font.get_string_size(glbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
				_down_overlay.draw_string(
					font,
					ring_c + Vector2(-gw * 0.5, ring_r + 26.0),
					glbl,
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					16,
					Color(0.95, 0.7, 0.2, 0.95)
				)
	# (b) TEAMMATE down arrow — points (camera-relative) toward the nearest downed mate.
	if _team_down_shown:
		var screen_ang: float = _team_down_angle - PI * 0.5  # 0 rad = up; draw measures from +X
		var rad: float = 120.0
		var tip: Vector2 = c + Vector2(cos(screen_ang), sin(screen_ang)) * rad
		var dir: Vector2 = Vector2(cos(screen_ang), sin(screen_ang))
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var p_tip: Vector2 = tip + dir * 18.0
		var p_a: Vector2 = tip - dir * 6.0 + perp * 12.0
		var p_b: Vector2 = tip - dir * 6.0 - perp * 12.0
		var apulse: float = 0.7 + 0.3 * sin(_down_pulse * 5.0)
		var acol := Color(TEAM_AMBER.r, TEAM_AMBER.g, TEAM_AMBER.b, apulse)
		_down_overlay.draw_colored_polygon(PackedVector2Array([p_tip, p_a, p_b]), acol)


# --- Player / health -------------------------------------------------------


func _on_local_player_spawned(player: Node) -> void:
	_local_player = player
	# Seed the bar from the player's current health if it exposes one.
	var hp: Node = player.get_node_or_null(Groups.NODE_HEALTH)
	if hp and "current" in hp and "max_health" in hp:
		_set_health(hp.current, hp.max_health)
	# One-shot tip: how to toggle the camera + where to change appearance (the user couldn't
	# find either). Static flag → shows once per session, not every raid.
	if not _view_tip_shown:
		_view_tip_shown = true
		Events.notify.emit(tr("V zooms the camera: close / medium / far / first-person"), 0)


func _on_player_health_changed(player: Node, current: float, max_health: float) -> void:
	# Only reflect the local player's health. Before binding, accept any update.
	if _local_player != null and player != _local_player:
		return
	_set_health(current, max_health)


func _set_health(current: float, max_health: float) -> void:
	health_bar.max_value = max_health
	health_bar.value = current
	health_label.text = "%d / %d" % [int(round(current)), int(round(max_health))]


# --- Waves -----------------------------------------------------------------


func _on_wave_started(wave_number: int, _enemy_count: int) -> void:
	_update_wave_label(wave_number)


func _on_wave_cleared(wave_number: int) -> void:
	wave_label.text = tr("WAVE %d CLEARED") % wave_number


func _update_wave_label(wave_number: int) -> void:
	if wave_number <= 0:
		wave_label.text = tr("PREPARING…")
	else:
		wave_label.text = tr("WAVE %d") % wave_number


# --- Extraction ------------------------------------------------------------


func _on_extraction_started(player: Node, _zone: Node) -> void:
	if not _is_local(player):
		return
	extract_panel.visible = true
	extract_bar.value = 0.0


func _on_extraction_progress(player: Node, ratio: float) -> void:
	if not _is_local(player):
		return
	extract_panel.visible = true
	extract_bar.value = clampf(ratio, 0.0, 1.0) * 100.0


func _on_extraction_completed(player: Node) -> void:
	if not _is_local(player):
		return
	extract_bar.value = 100.0
	extract_panel.visible = false


func _on_extraction_cancelled(player: Node) -> void:
	if not _is_local(player):
		return
	extract_panel.visible = false
	extract_bar.value = 0.0


# --- Match end -------------------------------------------------------------

## Captured from Events.run_rewards (fires just before match_won on extraction) so
## the victory banner can show the currency hauled out this run.
var _reward_line: String = ""


func _on_run_rewards(currency: int, breakdown: Dictionary) -> void:
	var loot: int = int(breakdown.get("loot", 0))
	var survival: int = int(breakdown.get("survival", 0))
	_reward_line = tr("+%d SCRAP  (loot %d · survival %d)") % [currency, loot, survival]


func _on_match_won() -> void:
	var msg := tr("EXTRACTED — YOU WIN")
	if _reward_line != "":
		msg += "\n" + _reward_line
	_show_banner(msg, Color(0.4, 1.0, 0.6))


func _on_match_lost() -> void:
	_show_banner(tr("KIA — gear lost"), Color(1.0, 0.35, 0.35))


func _show_banner(text: String, color: Color) -> void:
	# The RaidSummary screen owns the post-raid UI when present; only fall back to this
	# inline banner if that scene isn't in the build.
	if ResourceLoader.exists("res://scenes/ui/RaidSummary.tscn"):
		return
	banner.text = tr("%s\n\nPress ENTER to restart") % text
	banner.add_theme_color_override("font_color", color)
	banner.visible = true


# --- Helpers ---------------------------------------------------------------


## A nil local player means we haven't bound yet — treat events as local so the
## single-player HUD still works before local_player_spawned fires.
func _is_local(player: Node) -> bool:
	return _local_player == null or player == _local_player
