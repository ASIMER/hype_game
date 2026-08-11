extends CanvasLayer
class_name MapUI
## Full-screen tactical MAP overlay (toggled with the 'M' key). Unlike the minimap
## (top-right, player-relative, heading-up), this is a NORTH-UP, world-aligned
## top-down view of the whole 320x320 arena. Renders:
##   - the map frame + a reference grid,
##   - named POIs (zones of interest) at their world centres (from arena.get_poi_points),
##   - every extraction zone (group "extraction") as OPEN (green, pulsing) vs CLOSED
##     (grey) with a live countdown (window state cached from Events.extraction_window_changed,
##     queried defensively from the zone otherwise),
##   - the local player as a heading arrow,
##   - enemies (group "enemies") as small red dots,
##   - a legend + the match timer (mm:ss) and a FINAL WAVE / STORM banner.
##
## Self-contained: reads only the Events bus + GameState + group lookups, never
## referencing gameplay nodes by path. Stays in PROCESS_MODE_ALWAYS so QA can open it
## in any state. Root node is named "MapUI" and exposes set_open(bool) so the
## AgentBridge QA hook can drive it.

# World bounds: WorldBounds.* (scripts/core/world_bounds.gd) is the ONE source. The
# map projection is (coord - WorldBounds.X_MIN) / WorldBounds.SPAN (square world).
# Panel inset from the screen edges (px).
const PANEL_MARGIN := 64.0
# POI display names in the order arena.get_poi_points() returns them (POIMarkers
# children order, per CLAUDE.md / arena docs). First 6 = original NW quadrant; next 6 = the
# new far-quadrant POIs (NE snow, SW desert, SE rain).
const POI_NAMES := [
	"North Tower",
	"East Warehouse",
	"Plaza",
	"SW House",
	"South Yard",
	"East Yard",
	"Snow Lodge",
	"Snow Depot",
	"Desert Ruins",
	"Ruin Columns",
	"Temple",
	"Shrine House",
]

# Cached per-zone extraction-window state from Events.extraction_window_changed:
#   zone(Node) -> { "open": bool, "remaining": float }
var _zone_windows: Dictionary = {}
var _player: Node3D = null
var _arena: Node = null
var _draw: MapDraw = null
var _is_open: bool = false
# Drives the OPEN-zone pulse animation.
var _pulse: float = 0.0

# --- World-event cache (from Events signals; also read live from the group) ---
# kind (int) -> { "label": String, "pos": Vector3, "active": bool, "ratio": float }
var _event_cache: Dictionary = {}

# --- Raid-mutator cache (from Events.raid_mutator_changed; "" = none) ---
# Drawn as a compact header label; refreshed live + re-read when the map opens.
var _mutator: String = ""

# Mutator id → tr-able Title Case display name (ids per Settings.RAID_MUTATORS).
const MUTATOR_NAMES := {
	"fog": "Fog",
	"double_loot": "Double Loot",
	"elite_patrols": "Elite Patrols",
	"night_raid": "Night Raid",
}


func _ready() -> void:
	layer = 80  # above the HUD, below pause menus
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	# A single full-rect CanvasItem child does all the drawing.
	_draw = MapDraw.new()
	_draw.owner_ui = self
	_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_draw)

	Events.local_player_spawned.connect(func(p: Node) -> void: _player = p as Node3D)
	Events.extraction_window_changed.connect(_on_window_changed)
	# Honour external toggles (AgentBridge also emits map_toggled).
	Events.map_toggled.connect(_on_map_toggled)
	# World events — cache signal state so _draw is cheap even between group updates.
	Events.world_event_started.connect(_on_world_event_started)
	Events.world_event_ended.connect(_on_world_event_ended)
	Events.world_event_progress.connect(_on_world_event_progress)
	# Raid mutator — cache the active id; read live now (covers a roll before this UI).
	Events.raid_mutator_changed.connect(_on_raid_mutator_changed)
	_mutator = GameState.raid_mutator

	_bind_existing_player()


func _bind_existing_player() -> void:
	for p in get_tree().get_nodes_in_group(Groups.PLAYERS):
		if p is Node3D and _is_local(p):
			_player = p as Node3D
			return


func _is_local(player: Node) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	if not player.has_method("get_multiplayer_authority"):
		return true
	return player.get_multiplayer_authority() == multiplayer.get_unique_id()


# --- Toggle / open state ----------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("map"):
		set_open(not _is_open)
		get_viewport().set_input_as_handled()
	elif _is_open and event.is_action_pressed("ui_cancel"):
		set_open(false)
		get_viewport().set_input_as_handled()
	elif _is_open and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		# M7.7 zoom: wheel scales the projection about the player (1×..3×).
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 1.25, 1.0, 3.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom / 1.25, 1.0, 3.0)
		else:
			return
		if _draw:
			_draw.queue_redraw()
		get_viewport().set_input_as_handled()


## Shows/hides the map, frees/recaptures the mouse, and announces on the Events bus.
## Public so AgentBridge QA can open the map without a key event.
func set_open(open: bool) -> void:
	if open == _is_open:
		# Still keep visibility/mouse in sync (idempotent), but don't re-broadcast.
		visible = open
		return
	_is_open = open
	visible = open
	AudioManager.ui_panel(open)
	if open:
		_mutator = GameState.raid_mutator
		zoom = 1.0  # M7.7: every open starts at full-map view
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if _draw:
			UIStyle.pop_in(_draw, UIStyle.Dir.DOWN, 0.0, 0.15)
	else:
		# Restore capture so the player can keep playing — unless something else
		# (a pause menu) owns the cursor.
		if not get_tree().paused:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Events.map_toggled.emit(open)
	if _draw:
		_draw.queue_redraw()


## React to an externally-emitted toggle (e.g. AgentBridge) without re-emitting.
func _on_map_toggled(open: bool) -> void:
	if open == _is_open:
		return
	_is_open = open
	visible = open
	if open:
		_mutator = GameState.raid_mutator
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if _draw:
			UIStyle.pop_in(_draw, UIStyle.Dir.DOWN, 0.0, 0.15)
	elif not get_tree().paused:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _draw:
		_draw.queue_redraw()


func is_open() -> bool:
	return _is_open


# --- Window-state cache -----------------------------------------------------


func _on_window_changed(zone: Node, open: bool, remaining: float) -> void:
	if zone == null:
		return
	_zone_windows[zone] = {"open": open, "remaining": remaining}


## Returns { open: bool, remaining: float } for a zone, preferring the cached
## Events state, then defensive zone queries, then a sane default (open, 0).
func _window_for(zone: Node) -> Dictionary:
	var cached: Variant = _zone_windows.get(zone, null)
	if cached != null:
		return cached as Dictionary
	var is_open_val: bool = true
	var remaining_val: float = 0.0
	if zone != null and zone.has_method("is_open"):
		is_open_val = bool(zone.call("is_open"))
	if zone != null and zone.has_method("window_remaining"):
		remaining_val = float(zone.call("window_remaining"))
	return {"open": is_open_val, "remaining": remaining_val}


# --- Per-frame update -------------------------------------------------------


func _process(delta: float) -> void:
	if not _is_open:
		return
	_pulse += delta
	# Count cached open-window timers down locally so the readout stays live between
	# the (server-throttled) extraction_window_changed pushes.
	for zone in _zone_windows.keys():
		var w: Dictionary = _zone_windows[zone]
		w["remaining"] = maxf(0.0, float(w.get("remaining", 0.0)) - delta)
		_zone_windows[zone] = w
	if not is_instance_valid(_arena):
		_arena = _find_arena()
	if _draw:
		_draw.queue_redraw()


func _find_arena() -> Node:
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("get_poi_points"):
		return scene
	# Fallback: a node in the tree that exposes the POI accessor.
	for n in get_tree().get_nodes_in_group(Groups.ARENA):
		if n.has_method("get_poi_points"):
			return n
	return null


# --- World-event signal handlers -------------------------------------------


func _on_world_event_started(kind: int, world_pos: Vector3, label: String) -> void:
	_event_cache[kind] = {"label": label, "pos": world_pos, "active": true, "ratio": -1.0}


func _on_world_event_ended(kind: int, _success: bool) -> void:
	if _event_cache.has(kind):
		(_event_cache[kind] as Dictionary)["active"] = false


func _on_world_event_progress(kind: int, ratio: float) -> void:
	if _event_cache.has(kind):
		(_event_cache[kind] as Dictionary)["ratio"] = ratio


# --- Raid-mutator signal handler -------------------------------------------


func _on_raid_mutator_changed(mutator: String) -> void:
	_mutator = mutator
	if _is_open and _draw:
		_draw.queue_redraw()


## Localized Title Case display name for the active mutator id, or "" if none.
## Routes through MUTATOR_NAMES then tr() so the label is translatable; an unknown
## id falls back to a tr() of the raw id (still beats showing nothing).
func mutator_label() -> String:
	if _mutator == "":
		return ""
	var key: String = MUTATOR_NAMES.get(_mutator, _mutator)
	return tr(key)


# --- Drawing helpers (used by the inner MapDraw) ----------------------------


## Returns 0..1 fill ratio for a world-event node, or -1 if not available.
## Tries node.event_ratio() first, then the _director_ref meta path.
func _event_ratio(node: Node) -> float:
	if node.has_method("event_ratio"):
		return float(node.call("event_ratio"))
	if node.has_meta("_director_ref"):
		var d: Variant = node.get_meta("_director_ref")
		if (
			d != null
			and is_instance_valid(d as Object)
			and (d as Object).has_method("marker_event_ratio")
		):
			return float((d as Object).call("marker_event_ratio", node))
	return -1.0


## Returns the risk tier (1/2/3) for a POI by index, preferring arena.get_poi_tier,
## then the Settings table keyed by the POI's display name.
func _poi_tier(index: int) -> int:
	var arena: Node = get_arena()
	if arena != null and arena.has_method("get_poi_tier"):
		return int(arena.call("get_poi_tier", index))
	var name_key: String = POI_NAMES[index] if index < POI_NAMES.size() else ""
	# Settings.POI_RISK_TIERS uses internal marker names — map display names as fallback.
	var tier: int = 1
	match name_key:
		"North Tower":
			tier = int(Settings.POI_RISK_TIERS.get("POI_NorthTower", 1))
		"East Warehouse":
			tier = int(Settings.POI_RISK_TIERS.get("POI_EastWarehouse", 1))
		"Plaza":
			tier = int(Settings.POI_RISK_TIERS.get("POI_Plaza", 1))
		"SW House":
			tier = int(Settings.POI_RISK_TIERS.get("POI_SWHouse", 1))
		"South Yard":
			tier = int(Settings.POI_RISK_TIERS.get("POI_SouthYard", 1))
		"East Yard":
			tier = int(Settings.POI_RISK_TIERS.get("POI_EastYard", 1))
		"Snow Lodge":
			tier = int(Settings.POI_RISK_TIERS.get("POI_SnowLodge", 1))
		"Snow Depot":
			tier = int(Settings.POI_RISK_TIERS.get("POI_SnowDepot", 1))
		"Desert Ruins":
			tier = int(Settings.POI_RISK_TIERS.get("POI_DesertRuins", 1))
		"Ruin Columns":
			tier = int(Settings.POI_RISK_TIERS.get("POI_RuinColumns", 1))
		"Temple":
			tier = int(Settings.POI_RISK_TIERS.get("POI_Temple", 1))
		"Shrine House":
			tier = int(Settings.POI_RISK_TIERS.get("POI_ShrineHouse", 1))
	return clampi(tier, 1, 3)


## World (x,z) → panel-local pixel coords. NORTH-UP, world-aligned (no yaw):
## +x → right, +z (south) → down. Maps the 320×320 world rectangle onto the panel rect.
## M7.7 map zoom: mouse wheel scales the projection about the PLAYER (1×..3×).
var zoom: float = 1.0


func world_to_panel(wpos: Vector3, panel: Rect2) -> Vector2:
	var nx: float = clampf((wpos.x - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0)
	var nz: float = clampf((wpos.z - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0)
	var p := Vector2(nx, nz)
	if zoom > 1.001 and _player != null and is_instance_valid(_player):
		var cx: float = clampf(
			(_player.global_position.x - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0
		)
		var cz: float = clampf(
			(_player.global_position.z - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0
		)
		p = Vector2(cx, cz) + (p - Vector2(cx, cz)) * zoom
	var out := panel.position + Vector2(p.x * panel.size.x, p.y * panel.size.y)
	# Zoomed projections can leave the panel — pin markers to the frame edge so
	# they read as off-view indicators instead of spilling over the gutters.
	out.x = clampf(out.x, panel.position.x, panel.position.x + panel.size.x)
	out.y = clampf(out.y, panel.position.y, panel.position.y + panel.size.y)
	return out


func get_player() -> Node3D:
	return _player


# --- M7.3 ortho terrain underlay ---------------------------------------------
# Baked ONCE (lazy, first map open) straight from the same functions the terrain
# builds with (height_at / water_surface_at / biome_at) — no viewport capture,
# deterministic, and it can never disagree with the real ground.
var _underlay: ImageTexture = null


func underlay() -> Texture2D:
	if _underlay == null:
		_bake_underlay()
	return _underlay


func _bake_underlay() -> void:
	var n: int = 176
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for iz in n:
		for ix in n:
			var wx: float = WorldBounds.X_MIN + WorldBounds.SPAN * (float(ix) + 0.5) / float(n)
			var wz: float = WorldBounds.Z_MIN + WorldBounds.SPAN * (float(iz) + 0.5) / float(n)
			img.set_pixel(ix, iz, _underlay_color(wx, wz))
	_underlay = ImageTexture.create_from_image(img)


func _underlay_color(wx: float, wz: float) -> Color:
	var h: float = ProceduralTerrain.height_at(wx, wz)
	var ws: float = ProceduralTerrain.water_surface_at(wx, wz)
	if not is_nan(ws) and ws > h:
		return Color(0.12, 0.2, 0.26)
	var base := Color(0.17, 0.19, 0.18)
	match WorldBounds.biome_at(wx, wz):
		"snow":
			base = Color(0.3, 0.33, 0.38)
		"desert":
			base = Color(0.31, 0.26, 0.18)
		"rain":
			base = Color(0.15, 0.21, 0.19)
	var shade: float = clampf(0.78 + h * 0.05, 0.55, 1.3)
	return base * shade


func get_arena() -> Node:
	return _arena


func get_pulse() -> float:
	return _pulse


# ===========================================================================
## Inner CanvasItem that owns all of the map's _draw() rendering. Kept as a nested
## class so the whole feature lives in one self-instantiable file.
class MapDraw:
	extends Control
	var owner_ui: MapUI = null
	# Anti-collision ledger for text labels (Phase 4): placed rects this frame; a
	# colliding label steps down until free (audit: POI/extract names fused into
	# unreadable clots).
	var _placed_labels: Array[Rect2] = []

	func _draw() -> void:
		if owner_ui == null:
			return
		_placed_labels.clear()
		# The project theme's body font — not the engine fallback.
		var font := get_theme_default_font()
		# --- Backdrop dim over the gameplay view (glass tone).
		draw_rect(
			Rect2(Vector2.ZERO, size),
			Color(UIStyle.GLASS_BG.r, UIStyle.GLASS_BG.g, UIStyle.GLASS_BG.b, 0.82),
			true
		)

		# --- Square map panel, centred, inset by the margin.
		var avail := size - Vector2(owner_ui.PANEL_MARGIN, owner_ui.PANEL_MARGIN) * 2.0
		var side: float = maxf(64.0, minf(avail.x, avail.y))
		var origin := (size - Vector2(side, side)) * 0.5
		var panel := Rect2(origin, Vector2(side, side))

		draw_rect(
			panel, Color(UIStyle.PANEL_BG.r, UIStyle.PANEL_BG.g, UIStyle.PANEL_BG.b, 0.92), true
		)
		# M7.3 ortho terrain underlay (zoom-aware texture region about the player).
		var terrain_tex: Texture2D = owner_ui.underlay()
		if terrain_tex != null:
			var ts: Vector2 = terrain_tex.get_size()
			var region := Rect2(Vector2.ZERO, ts)
			var pl: Node3D = owner_ui.get_player()
			if owner_ui.zoom > 1.001 and pl != null and is_instance_valid(pl):
				var cxn: float = clampf(
					(pl.global_position.x - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0
				)
				var czn: float = clampf(
					(pl.global_position.z - WorldBounds.X_MIN) / WorldBounds.SPAN, 0.0, 1.0
				)
				var half: float = 0.5 / owner_ui.zoom
				region = Rect2(
					Vector2(cxn - half, czn - half) * ts, Vector2(half * 2.0, half * 2.0) * ts
				)
			draw_texture_rect_region(terrain_tex, panel, region, Color(1, 1, 1, 0.55))
		# Amber accent border with thin inner light edge (glass frame).
		draw_rect(panel, Color(UIStyle.AMBER.r, UIStyle.AMBER.g, UIStyle.AMBER.b, 0.55), false, 2.0)
		var inset: float = 2.0
		draw_rect(
			Rect2(
				panel.position + Vector2(inset, inset),
				panel.size - Vector2(inset * 2.0, inset * 2.0)
			),
			UIStyle.BORDER_LT,
			false,
			1.0
		)
		_draw_grid(font, panel)
		_draw_compass(font, panel)

		# --- POIs (zones of interest).
		_draw_pois(font, panel)
		# --- Extraction zones (with window state + countdown).
		_draw_extractions(font, panel)
		# --- World events (supply cache / miniboss / contested POI / surge).
		_draw_world_events(font, panel)
		# --- Enemies. (M7.6: hi-contrast markers grow + outline every dot.)
		var hi_c: bool = bool(SettingsManager.get_value("hi_contrast_markers"))
		var er: float = 4.5 if hi_c else 3.0
		for e in owner_ui.get_tree().get_nodes_in_group(Groups.ENEMIES):
			if e is Node3D:
				var ep := owner_ui.world_to_panel((e as Node3D).global_position, panel)
				if hi_c:
					draw_circle(ep, er + 1.5, Color(0, 0, 0, 0.85))
				draw_circle(ep, er, Color(1.0, 0.32, 0.32, 0.95))
		# --- Machine Nemesis (the rival): a bigger blood-red ring + core so it stands out.
		for n in owner_ui.get_tree().get_nodes_in_group(Groups.NEMESIS):
			if n is Node3D:
				var npos := owner_ui.world_to_panel((n as Node3D).global_position, panel)
				draw_arc(npos, 7.0, 0.0, TAU, 24, Color(0.95, 0.12, 0.12, 0.95), 2.0)
				draw_circle(npos, 4.0, Color(0.95, 0.12, 0.12, 0.95))
		# --- Power-Core Beacon: an amber diamond/core (the prize to carry out).
		for pc in owner_ui.get_tree().get_nodes_in_group(Groups.POWER_CORE):
			if pc is Node3D:
				var cpos := owner_ui.world_to_panel((pc as Node3D).global_position, panel)
				draw_arc(cpos, 6.0, 0.0, TAU, 20, Color(1.0, 0.62, 0.12, 0.95), 2.0)
				draw_circle(cpos, 3.5, Color(1.0, 0.72, 0.2, 0.95))
		# --- Player arrow.
		_draw_player(panel)
		# --- Title + match timer + legend.
		_draw_overlay_text(font, panel)
		# --- Side gutters (Phase 4): the letterbox becomes functional — legend
		# column on the left, live extraction board on the right.
		_draw_side_panels(font, panel)

	func _draw_grid(font: Font, panel: Rect2) -> void:
		var col := Color(1, 1, 1, 0.06)
		# 8 cells = one line every 40 world metres.
		var cells := 8
		for i in range(1, cells):
			var fx: float = panel.position.x + panel.size.x * float(i) / float(cells)
			draw_line(
				Vector2(fx, panel.position.y),
				Vector2(fx, panel.position.y + panel.size.y),
				col,
				1.0
			)
			var fy: float = panel.position.y + panel.size.y * float(i) / float(cells)
			draw_line(
				Vector2(panel.position.x, fy),
				Vector2(panel.position.x + panel.size.x, fy),
				col,
				1.0
			)
		# Coordinate refs (Phase 4): A–H across the top, 1–8 down the left — callouts
		# like "evac at C5" become possible over voice.
		var ref_col := Color(1, 1, 1, 0.28)
		for i in range(cells):
			var cx: float = panel.position.x + panel.size.x * (float(i) + 0.5) / float(cells)
			draw_string(
				font,
				Vector2(cx - 4.0, panel.position.y + 14.0),
				char(65 + i),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				ref_col
			)
			var cy: float = panel.position.y + panel.size.y * (float(i) + 0.5) / float(cells)
			draw_string(
				font,
				Vector2(panel.position.x + 5.0, cy + 4.0),
				str(i + 1),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				ref_col
			)
		# Centre crosshair (origin = Plaza).
		var ctr := owner_ui.world_to_panel(Vector3.ZERO, panel)
		draw_line(
			Vector2(ctr.x, panel.position.y),
			Vector2(ctr.x, panel.position.y + panel.size.y),
			Color(1, 1, 1, 0.10),
			1.0
		)
		draw_line(
			Vector2(panel.position.x, ctr.y),
			Vector2(panel.position.x + panel.size.x, ctr.y),
			Color(1, 1, 1, 0.10),
			1.0
		)

	func _draw_compass(font: Font, panel: Rect2) -> void:
		# North is -z (up), world-aligned.
		draw_string(
			font,
			Vector2(panel.position.x + panel.size.x * 0.5 - 6.0, panel.position.y + 16.0),
			"N",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(UIStyle.TEXT.r, UIStyle.TEXT.g, UIStyle.TEXT.b, 0.85)
		)
		draw_string(
			font,
			Vector2(
				panel.position.x + panel.size.x * 0.5 - 6.0, panel.position.y + panel.size.y - 6.0
			),
			"S",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			Color(UIStyle.DIM.r, UIStyle.DIM.g, UIStyle.DIM.b, 0.6)
		)

	func _draw_pois(font: Font, panel: Rect2) -> void:
		var arena: Node = owner_ui.get_arena()
		var points: Array = []
		if arena != null and arena.has_method("get_poi_points"):
			points = arena.call("get_poi_points")
		for i in range(points.size()):
			var wp: Vector3 = points[i]
			var p := owner_ui.world_to_panel(wp, panel)
			# Tier-tinted diamond marker.
			var tier: int = owner_ui._poi_tier(i)
			var tier_col: Color = (
				Settings.RISK_TIER_COLORS.get(tier, Color(0.85, 0.78, 0.4)) as Color
			)
			var d := 5.0
			var pts := PackedVector2Array(
				[
					p + Vector2(0, -d),
					p + Vector2(d, 0),
					p + Vector2(0, d),
					p + Vector2(-d, 0),
				]
			)
			draw_colored_polygon(pts, Color(tier_col.r, tier_col.g, tier_col.b, 0.92))
			# Small tier-number pip inside the diamond.
			var tier_str: String = str(tier)
			draw_string(
				font,
				p + Vector2(-3.0, 4.0),
				tier_str,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(0.0, 0.0, 0.0, 0.72)
			)
			var label: String = (
				tr(owner_ui.POI_NAMES[i]) if i < owner_ui.POI_NAMES.size() else tr("POI %d") % i
			)
			_place_label(
				font, p + Vector2(8, 4), label, 12, Color(tier_col.r, tier_col.g, tier_col.b, 0.95)
			)

	# Typed extraction-zone hues (batch C): the bright (open) and dim (closed) tone
	# per zone_type. "" (classic) keeps the established green/grey.
	const ZONE_HUE_OPEN := {
		"": Color(0.25, 1.0, 0.45),  # classic — green
		"paid": Color(1.0, 0.78, 0.25),  # amber/gold
		"signal": Color(0.72, 0.45, 1.0),  # violet
	}
	# CLOSED zones are ONE neutral grey regardless of type (a per-type tint read as
	# "alive/go here" at a glance — critic-panel finding; the type stays in the tag
	# TEXT: "PAID"/"SIGNAL").
	const ZONE_HUE_CLOSED := {
		"": Color(0.52, 0.56, 0.59),
		"paid": Color(0.52, 0.56, 0.59),
		"signal": Color(0.52, 0.56, 0.59),
	}

	func _draw_extractions(font: Font, panel: Rect2) -> void:
		for z in owner_ui.get_tree().get_nodes_in_group(Groups.EXTRACTION):
			if not (z is Node3D):
				continue
			var zp := owner_ui.world_to_panel((z as Node3D).global_position, panel)
			var w: Dictionary = owner_ui._window_for(z)
			var is_open_z: bool = bool(w.get("open", true))
			# A typed zone may force itself active (e.g. a held signal) — reflect that.
			if z.has_method("override_active") and bool(z.call("override_active")):
				is_open_z = true
			var remaining: float = float(w.get("remaining", 0.0))
			# Duck-typed zone class: "paid" / "signal" / "" (classic). Default "".
			var ztype: String = ""
			if "zone_type" in z:
				ztype = String(z.get("zone_type"))
			var col: Color
			var r: float = 7.0
			if is_open_z:
				# Pulsing in the type's hue.
				var t: float = 0.5 + 0.5 * sin(owner_ui.get_pulse() * 4.0)
				var hue: Color = ZONE_HUE_OPEN.get(ztype, ZONE_HUE_OPEN[""]) as Color
				col = Color(hue.r, hue.g, hue.b, 0.55 + 0.45 * t)
				r = 7.0 + 2.0 * t
			else:
				var hue_c: Color = ZONE_HUE_CLOSED.get(ztype, ZONE_HUE_CLOSED[""]) as Color
				col = Color(hue_c.r, hue_c.g, hue_c.b, 0.7)  # dim when closed
			# Outer ring + filled core.
			draw_arc(zp, r + 3.0, 0.0, TAU, 24, col, 2.0)
			draw_circle(zp, r, Color(col.r, col.g, col.b, 0.4))
			# Typed-zone glyph centred on the marker (paid "$" / signal lightning).
			_draw_zone_glyph(font, zp, ztype, col)
			# "EXTRACT" tag + countdown.
			var tag := tr("EXTRACT")
			if remaining > 0.0:
				tag += "  %ds" % int(ceil(remaining))
			elif not is_open_z:
				tag += "  " + tr("(closed)")
			_place_label(font, zp + Vector2(10, 4), tag, 12, col)

	# Small typed glyph drawn centred on an extraction marker: a "$" for paid zones
	# and a stylized lightning zigzag for signal zones (font-glyph-free so it renders
	# crisply at any size); classic zones get nothing.
	func _draw_zone_glyph(font: Font, center: Vector2, ztype: String, col: Color) -> void:
		var glyph_col := Color(col.r, col.g, col.b, 0.98)
		match ztype:
			"paid":
				# Centred "$" — font glyph is fine here (always present in the base font).
				draw_string(
					font,
					center + Vector2(-3.0, 4.0),
					"$",
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					12,
					glyph_col
				)
			"signal":
				# Stylized lightning zigzag (a 4-point polyline) — avoids "⚡" font misses.
				var pts := PackedVector2Array(
					[
						center + Vector2(1.5, -6.0),
						center + Vector2(-2.5, 0.5),
						center + Vector2(2.0, 0.0),
						center + Vector2(-1.5, 6.0),
					]
				)
				for i in range(pts.size() - 1):
					draw_line(pts[i], pts[i + 1], glyph_col, 1.8)

	# Event kind → Color accent (distinct per type).
	const EVENT_COLORS := [
		Color(0.95, 0.75, 0.25, 0.95),  # 0 supply_cache  — amber/gold
		Color(0.95, 0.30, 0.95, 0.95),  # 1 miniboss      — magenta
		Color(0.30, 0.80, 0.95, 0.95),  # 2 contested_poi — cyan
		Color(1.00, 0.45, 0.10, 0.95),  # 3 surge         — orange
		Color(0.95, 0.20, 0.20, 0.95),  # 4 siege         — red
	]

	func _draw_world_events(font: Font, panel: Rect2) -> void:
		# Collect live nodes; fall back to cached signal data for any active kind not
		# present as a node yet (or while the node is mid-spawn).
		var drawn_kinds: Dictionary = {}  # kind(int) -> true

		for node in owner_ui.get_tree().get_nodes_in_group(Groups.WORLD_EVENTS):
			if not node.has_meta("event_kind"):
				continue
			var kind: int = int(node.get_meta("event_kind"))
			var label: String = node.get_meta("event_label") if node.has_meta("event_label") else ""
			var wpos: Vector3
			if node is Node3D:
				wpos = (node as Node3D).global_position
			elif node.has_meta("event_pos"):
				wpos = node.get_meta("event_pos") as Vector3
			else:
				continue
			var ratio: float = owner_ui._event_ratio(node)
			# Fall back to the cached signal ratio for this kind.
			if ratio < 0.0:
				var cached: Variant = owner_ui._event_cache.get(kind, null)
				if cached != null:
					ratio = float((cached as Dictionary).get("ratio", -1.0))
			_draw_event_marker(font, panel, kind, wpos, label, ratio)
			drawn_kinds[kind] = true

		# Draw any active events that have no live node yet (signal-only).
		for kind_key in owner_ui._event_cache.keys():
			var kind: int = int(kind_key)
			if drawn_kinds.has(kind):
				continue
			var cached: Dictionary = owner_ui._event_cache[kind] as Dictionary
			if not bool(cached.get("active", false)):
				continue
			var wpos: Vector3 = cached.get("pos", Vector3.ZERO) as Vector3
			var label: String = cached.get("label", "") as String
			var ratio: float = float(cached.get("ratio", -1.0))
			_draw_event_marker(font, panel, kind, wpos, label, ratio)

	func _draw_event_marker(
		font: Font, panel: Rect2, kind: int, wpos: Vector3, label: String, ratio: float
	) -> void:
		var p := owner_ui.world_to_panel(wpos, panel)
		var col: Color = EVENT_COLORS[clampi(kind, 0, EVENT_COLORS.size() - 1)]
		var pulse: float = owner_ui.get_pulse()

		# Outer pulsing ring.
		var ring_r: float = 9.0 + 2.0 * (0.5 + 0.5 * sin(pulse * 3.0))
		draw_arc(p, ring_r, 0.0, TAU, 24, col, 2.0)

		# Fill arc (ratio 0..1 = clockwise countdown sweep). Drawn inside the ring.
		if ratio >= 0.0:
			var start_a: float = -PI * 0.5
			var end_a: float = start_a + TAU * clampf(ratio, 0.0, 1.0)
			draw_arc(p, ring_r - 3.5, start_a, end_a, 20, Color(col.r, col.g, col.b, 0.55), 3.5)

		# Icon in the centre — a distinct shape per kind.
		match kind:
			0:  # supply_cache: filled square
				var hs: float = 4.5
				draw_rect(Rect2(p - Vector2(hs, hs), Vector2(hs * 2.0, hs * 2.0)), col, true)
			1:  # miniboss: upward triangle (skull surrogate)
				var tri := PackedVector2Array(
					[
						p + Vector2(0, -6.0),
						p + Vector2(5.5, 5.0),
						p + Vector2(-5.5, 5.0),
					]
				)
				draw_colored_polygon(tri, col)
			2:  # contested_poi: double concentric rings (contested marker)
				draw_circle(p, 3.0, col)
				draw_arc(p, 6.5, 0.0, TAU, 16, col, 1.5)
			3:  # surge: four-point star (lightning-bolt surrogate)
				draw_circle(p, 5.0, col)
				draw_circle(p, 2.5, Color(0.06, 0.06, 0.1, 1.0))
			4:  # siege: crossed-swords surrogate — an X over a dot
				draw_circle(p, 2.2, col)
				draw_line(p + Vector2(-4.5, -4.5), p + Vector2(4.5, 4.5), col, 2.0)
				draw_line(p + Vector2(-4.5, 4.5), p + Vector2(4.5, -4.5), col, 2.0)

		# Label text to the right of the marker.
		if label != "":
			draw_string(
				font, p + Vector2(ring_r + 4.0, 4.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col
			)

	func _draw_player(panel: Rect2) -> void:
		var pl: Node3D = owner_ui.get_player()
		if not is_instance_valid(pl):
			return
		var pp := owner_ui.world_to_panel(pl.global_position, panel)
		# Heading: yaw 0 faces -z (north/up). Forward vector in world space.
		var yaw: float = pl.rotation.y
		var fwd := Vector2(-sin(yaw), -cos(yaw))  # +screen-down = +z
		var side := Vector2(-fwd.y, fwd.x)
		# Bigger arrow + dark outline (audit: "player marker vanishes among POI dots").
		var tip := pp + fwd * 15.0
		var bl := pp - fwd * 8.0 + side * 8.0
		var br := pp - fwd * 8.0 - side * 8.0
		var pts := PackedVector2Array([tip, bl, br])
		draw_colored_polygon(pts, Color(0.4, 0.85, 1.0, 0.95))
		draw_polyline(PackedVector2Array([tip, bl, br, tip]), Color(0.03, 0.08, 0.12, 0.9), 1.5)
		draw_circle(pp, 2.5, Color(0.9, 0.97, 1.0))

	func _draw_overlay_text(font: Font, panel: Rect2) -> void:
		# Title above the panel — amber header.
		draw_string(
			font,
			Vector2(panel.position.x, panel.position.y - 30.0),
			tr("TACTICAL MAP"),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			20,
			Color(UIStyle.AMBER.r, UIStyle.AMBER.g, UIStyle.AMBER.b, 0.95)
		)

		# Active raid mutator — compact label beside the title in the header strip.
		var mut_name: String = owner_ui.mutator_label()
		if mut_name != "":
			var title_w: float = font.get_string_size(tr("TACTICAL MAP"), 0, -1, 20).x
			draw_string(
				font,
				Vector2(panel.position.x + title_w + 18.0, panel.position.y - 32.0),
				tr("MUTATOR: %s") % mut_name,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				13,
				Color(UIStyle.TEAL.r, UIStyle.TEAL.g, UIStyle.TEAL.b, 0.95)
			)

		# Match timer (mm:ss), top-right of the panel header.
		var left: float = maxf(0.0, GameState.match_time_left)
		var timer_col := Color(UIStyle.TEXT.r, UIStyle.TEXT.g, UIStyle.TEXT.b, 0.95)
		var timer_txt: String
		if GameState.final_wave:
			timer_txt = tr("FINAL WAVE — STORM")
			timer_col = Color(UIStyle.RED.r, UIStyle.RED.g, UIStyle.RED.b, 0.95)
		else:
			timer_txt = tr("TIME  %s") % _fmt_time(left)
			if left <= Settings.FINAL_WAVE_WARN and GameState.match_duration > 0.0:
				timer_col = Color(UIStyle.RED.r, UIStyle.RED.g, UIStyle.RED.b, 0.95)
		draw_string(
			font,
			Vector2(panel.position.x + panel.size.x - 230.0, panel.position.y - 30.0),
			timer_txt,
			HORIZONTAL_ALIGNMENT_LEFT,
			220.0,
			18,
			timer_col
		)

		# Wave readout under the timer.
		draw_string(
			font,
			Vector2(panel.position.x + panel.size.x - 230.0, panel.position.y - 8.0),
			tr("WAVE  %d") % GameState.current_wave,
			HORIZONTAL_ALIGNMENT_LEFT,
			220.0,
			14,
			Color(UIStyle.DIM.r, UIStyle.DIM.g, UIStyle.DIM.b, 0.85)
		)

		# "[M] close" hint under the panel.
		draw_string(
			font,
			Vector2(
				panel.position.x + panel.size.x - 120.0, panel.position.y + panel.size.y + 18.0
			),
			tr("[M] close"),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			Color(UIStyle.DIM.r, UIStyle.DIM.g, UIStyle.DIM.b, 0.7)
		)

	# ── Side gutters (Phase 4): legend column left, live extraction board right ──

	## The old letterbox strips become functional space: a vertical LEGEND on the
	## left and the EXTRACTIONS board (state + countdown per zone, open first) on the
	## right — squad coordination reads from one glance. Falls back gracefully when a
	## gutter is too narrow (very square windows): the legend rows just clip out.
	func _draw_side_panels(font: Font, panel: Rect2) -> void:
		var gutter_l: float = panel.position.x
		var gutter_r: float = size.x - (panel.position.x + panel.size.x)
		# LEFT: legend column.
		if gutter_l >= 130.0:
			var lx: float = 16.0
			var ly: float = panel.position.y + 8.0
			draw_string(
				font,
				Vector2(lx, ly),
				tr("LEGEND"),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				14,
				Color(UIStyle.AMBER.r, UIStyle.AMBER.g, UIStyle.AMBER.b, 0.9)
			)
			ly += 12.0
			var rows: Array = [
				[Color(0.4, 0.85, 1.0), tr("You")],
				[Color(0.25, 1.0, 0.45), tr("Evac (open)")],
				[Color(0.55, 0.6, 0.62), tr("Evac (closed)")],
				[Color(0.85, 0.78, 0.4), tr("POI")],
				[Color(1.0, 0.32, 0.32), tr("Enemy")],
				[Color(0.95, 0.75, 0.25), tr("Supply Cache")],
				[Color(0.95, 0.30, 0.95), tr("Mini-boss")],
				[Color(0.30, 0.80, 0.95), tr("Contested")],
				[Color(1.00, 0.45, 0.10), tr("Surge")],
				[Settings.RISK_TIER_COLORS.get(1, Color.WHITE) as Color, tr("Tier 1")],
				[Settings.RISK_TIER_COLORS.get(2, Color.WHITE) as Color, tr("Tier 2")],
				[Settings.RISK_TIER_COLORS.get(3, Color.WHITE) as Color, tr("Tier 3")],
			]
			for row: Array in rows:
				ly += 21.0
				_legend_swatch(font, lx + 5.0, ly, row[0] as Color, String(row[1]))
		# RIGHT: extraction board.
		if gutter_r >= 150.0:
			var rx: float = panel.position.x + panel.size.x + 16.0
			var ry: float = panel.position.y + 8.0
			draw_string(
				font,
				Vector2(rx, ry),
				tr("EXTRACTIONS"),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				14,
				Color(UIStyle.AMBER.r, UIStyle.AMBER.g, UIStyle.AMBER.b, 0.9)
			)
			ry += 12.0
			for e: Dictionary in _extraction_rows():
				ry += 21.0
				if ry > panel.position.y + panel.size.y:
					break
				var col: Color = e["col"]
				draw_circle(Vector2(rx + 5.0, ry - 4.0), 4.0, col)
				draw_string(
					font,
					Vector2(rx + 15.0, ry),
					String(e["text"]),
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					13,
					Color(col.r, col.g, col.b, 0.95)
				)

	## Sorted board rows: open zones first (by soonest close), then closed (by soonest
	## open). Text: "EVAC 4 · PAID · 38s" / "EVAC 7 · closed 17s".
	func _extraction_rows() -> Array:
		var rows: Array = []
		for z in owner_ui.get_tree().get_nodes_in_group(Groups.EXTRACTION):
			if not (z is Node3D):
				continue
			var w: Dictionary = owner_ui._window_for(z)
			var is_open_z: bool = bool(w.get("open", true))
			if z.has_method("override_active") and bool(z.call("override_active")):
				is_open_z = true
			var remaining: float = float(w.get("remaining", 0.0))
			var ztype: String = String(z.get("zone_type")) if "zone_type" in z else ""
			var num: String = String(z.name).trim_prefix("ExtractionZone")
			if num == "":
				num = "1"
			var label: String = tr("EVAC %s") % num
			if ztype == "paid":
				label += " · " + tr("PAID")
			elif ztype == "signal":
				label += " · " + tr("SIGNAL")
			if is_open_z and remaining > 0.0:
				label += " · %ds" % int(ceil(remaining))
			elif not is_open_z:
				label += " · " + tr("closed")
				if remaining > 0.0:
					label += " %ds" % int(ceil(remaining))
			var hue: Color = (
				(
					ZONE_HUE_OPEN.get(ztype, ZONE_HUE_OPEN[""]) as Color
					if is_open_z
					else ZONE_HUE_CLOSED.get(ztype, ZONE_HUE_CLOSED[""])
				)
				as Color
			)
			rows.append({"text": label, "col": hue, "open": is_open_z, "t": remaining})
		rows.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				if bool(a["open"]) != bool(b["open"]):
					return bool(a["open"])
				return float(a["t"]) < float(b["t"])
		)
		return rows

	## Place a label, stepping DOWN past already-placed labels so names never fuse.
	func _place_label(font: Font, at: Vector2, text: String, fsize: int, col: Color) -> void:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		var r := Rect2(at + Vector2(0.0, -float(fsize)), Vector2(w, float(fsize) + 4.0))
		for _attempt in range(4):
			var hit := false
			for pr: Rect2 in _placed_labels:
				if pr.intersects(r):
					hit = true
					break
			if not hit:
				break
			r.position.y += float(fsize) + 3.0
		_placed_labels.append(r)
		draw_string(
			font,
			r.position + Vector2(0.0, float(fsize)),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			fsize,
			col
		)

	func _legend_swatch(font: Font, x: float, y: float, col: Color, label: String) -> void:
		draw_circle(Vector2(x, y), 4.0, col)
		draw_string(
			font,
			Vector2(x + 10.0, y + 5.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			Color(UIStyle.TEXT.r, UIStyle.TEXT.g, UIStyle.TEXT.b, 0.9)
		)

	func _fmt_time(secs: float) -> String:
		var s: int = int(ceil(secs))
		return "%d:%02d" % [s / 60, s % 60]
