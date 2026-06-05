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

	extract_panel.visible = false
	banner.visible = false
	_set_health(Settings.PLAYER_MAX_HEALTH, Settings.PLAYER_MAX_HEALTH)
	_update_wave_label(GameState.current_wave)
	_build_feedback_overlays()
	_build_hud_widgets()

# --- Crosshair / minimap / key-hints / ammo (built in code) ----------------

var _crosshair: Control
var _minimap: Control
var _ammo_label: Label
var _weapon_label: Label
var _reloading: bool = false
var _current_weapon_name: String = "RIFLE"
var _timer_label: Label
var _storm_banner: Label
var _storm_banner_t: float = 0.0

func _build_hud_widgets() -> void:
	# Replace the static dot with the dynamic spread crosshair.
	var static_cross := $Root.get_node_or_null("Crosshair")
	if static_cross:
		static_cross.visible = false
	_crosshair = (load("res://scripts/ui/crosshair.gd") as Script).new()
	$Root.add_child(_crosshair)
	_minimap = (load("res://scripts/ui/minimap.gd") as Script).new()
	$Root.add_child(_minimap)

	# Match-timer readout (mm:ss), top-centre just under the wave label. Goes red as
	# the storm approaches. Polls GameState as a fallback so it shows even before the
	# first Events.match_timer_changed push.
	_timer_label = Label.new()
	_timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timer_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_timer_label.offset_top = 34.0
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_label.add_theme_font_size_override("font_size", 22)
	_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_timer_label.add_theme_constant_override("outline_size", 4)
	_timer_label.text = ""
	$Root.add_child(_timer_label)

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
	_storm_banner.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
	_storm_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_storm_banner.add_theme_constant_override("outline_size", 5)
	_storm_banner.text = "⚠ STORM INCOMING — EXTRACT"
	_storm_banner.visible = false
	$Root.add_child(_storm_banner)

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

	# Key hints (bottom-right, above the ammo box, dim, right-aligned, grow up-left).
	var hints := Label.new()
	hints.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hints.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hints.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hints.offset_right = -16.0
	hints.offset_bottom = -86.0
	hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.add_theme_font_size_override("font_size", 12)
	hints.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9, 0.7))
	hints.text = "WASD Move   Shift Sprint   Space Jump\nLMB Fire   RMB Aim   Q Swap shoulder\n1-5 / Wheel Weapon   R Reload\nG Grenade   H Heal   E Loot   I Inventory   M Map"
	$Root.add_child(hints)

func _on_weapon_switched(weapon_id: String, ammo: int, reserve: int) -> void:
	_current_weapon_name = weapon_id.to_upper()
	_reloading = false
	_refresh_weapon_label()
	_set_ammo(ammo, reserve)

func _refresh_weapon_label() -> void:
	if _weapon_label:
		_weapon_label.text = _current_weapon_name + ("  (RELOADING)" if _reloading else "")

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

# --- Feedback overlays (built in code so HUD.tscn stays simple) -------------

var _hurt_flash: ColorRect
var _hit_marker: Label
var _hit_marker_t: float = 0.0
var _last_health: float = -1.0

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
	# Fade the storm banner out after its flash.
	if _storm_banner and _storm_banner.visible:
		_storm_banner_t -= delta
		_storm_banner.modulate.a = clampf(_storm_banner_t / 1.0, 0.0, 1.0) if _storm_banner_t < 1.0 else 1.0
		# Keep a steady pulse while it lingers, then hide.
		if _storm_banner_t <= 0.0:
			_storm_banner.visible = false

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
		_timer_label.text = "⚠ FINAL WAVE"
		_timer_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))
		return
	var l: float = maxf(0.0, left)
	var s: int = int(ceil(l))
	_timer_label.text = "%d:%02d" % [s / 60, s % 60]
	if l <= Settings.FINAL_WAVE_WARN:
		_timer_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	else:
		_timer_label.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))

func _on_final_wave_started() -> void:
	if _storm_banner:
		_storm_banner.visible = true
		_storm_banner.modulate.a = 1.0
		_storm_banner_t = 4.0   # lingers ~4s, then fades in the final second
	if _timer_label:
		_timer_label.text = "⚠ FINAL WAVE"
		_timer_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.35))

## Tints the screen on local-player damage and pops a hit marker when the local
## player damages an enemy. damage_dealt(target, amount, source).
func _on_damage_dealt(target: Node, _amount: float, source: Node) -> void:
	if _is_local(target) and target == _local_player:
		# A light wash only — the DIRECTIONAL blood arc (damage_indicator.gd) is the
		# primary "where am I being hit from" cue, so keep this from drowning it in red.
		if _hurt_flash:
			_hurt_flash.color.a = maxf(_hurt_flash.color.a, 0.22)
	elif source != null and source == _local_player and target != null and target.is_in_group("enemies"):
		if _hit_marker:
			_hit_marker.visible = true
			_hit_marker_t = 0.12

# --- Player / health -------------------------------------------------------

func _on_local_player_spawned(player: Node) -> void:
	_local_player = player
	# Seed the bar from the player's current health if it exposes one.
	var hp: Node = player.get_node_or_null("Health")
	if hp and "current" in hp and "max_health" in hp:
		_set_health(hp.current, hp.max_health)

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
	wave_label.text = "WAVE %d CLEARED" % wave_number

func _update_wave_label(wave_number: int) -> void:
	if wave_number <= 0:
		wave_label.text = "PREPARING…"
	else:
		wave_label.text = "WAVE %d" % wave_number

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
	_reward_line = "+%d SCRAP  (loot %d · survival %d)" % [currency, loot, survival]

func _on_match_won() -> void:
	var msg := "EXTRACTED — YOU WIN"
	if _reward_line != "":
		msg += "\n" + _reward_line
	_show_banner(msg, Color(0.4, 1.0, 0.6))

func _on_match_lost() -> void:
	_show_banner("KIA — gear lost", Color(1.0, 0.35, 0.35))

func _show_banner(text: String, color: Color) -> void:
	# The RaidSummary screen owns the post-raid UI when present; only fall back to this
	# inline banner if that scene isn't in the build.
	if ResourceLoader.exists("res://scenes/ui/RaidSummary.tscn"):
		return
	banner.text = "%s\n\nPress ENTER to restart" % text
	banner.add_theme_color_override("font_color", color)
	banner.visible = true

# --- Helpers ---------------------------------------------------------------

## A nil local player means we haven't bound yet — treat events as local so the
## single-player HUD still works before local_player_spawned fires.
func _is_local(player: Node) -> bool:
	return _local_player == null or player == _local_player
