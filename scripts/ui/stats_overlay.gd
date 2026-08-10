extends CanvasLayer
## Corner-docked, semi-transparent, non-blocking diagnostics overlay.
##
## Two independent pieces, both pure-local + cosmetic (reads stats, sends nothing):
##   (a) a minimal FPS counter (single translucent Label, top-left), and
##   (b) a detailed perf+network panel that renders either as a NUMERIC table or as
##       live ROLLING GRAPHS.
##
## Driven entirely by the frozen `Events.stats_overlay_changed(show_fps, show_detailed,
## mode)` signal (mode 0=Numeric, 1=Graphs, 2=Graphs+Numbers); initial state read from
## SettingsManager.
## NOTHING captures input: every Control uses MOUSE_FILTER_IGNORE. Network metrics only
## appear when the active peer is an ENetMultiplayerPeer (single-player uses an
## OfflineMultiplayerPeer — must be hard-guarded).

const SAMPLE_INTERVAL := 0.16  # ~6 Hz sampling/redraw throttle
const FPS_HISTORY_CAP := 120  # rolling samples for 1%-low / min FPS + the graph
const FRAME_HISTORY_CAP := 120
const PING_HISTORY_CAP := 120
const GRAPH_W := 220.0
const GRAPH_H := 60.0
# Authored top-left anchor for the three corner widgets; the ultrawide inset shifts them
# right/down from here. Fallback graph stack height (mode 2) when the live size is 0.
const BASE_X := 10.0
const BASE_Y := 8.0
const GRAPH_STACK_H_FALLBACK := 200.0

# --- Config state (mirrors the persisted SettingsManager values).
var _show_fps: bool = false
var _show_detailed: bool = false
var _mode: int = 0  # 0 Numeric, 1 Graphs, 2 Graphs+Numbers

# --- Sampling throttle.
var _accum: float = 0.0

# --- Latest sampled metrics (shared by numeric + graph renderers).
var _fps: float = 0.0
var _frame_ms: float = 0.0
var _phys_ms: float = 0.0
var _draw_calls: int = 0
var _primitives: int = 0
var _video_mem_mb: float = 0.0
var _static_mem_mb: float = 0.0
var _node_count: int = 0
var _fps_1low: float = 0.0
var _fps_min: float = 0.0

# --- Rolling histories.
var _fps_hist: PackedFloat32Array = PackedFloat32Array()
var _frame_hist: PackedFloat32Array = PackedFloat32Array()
# peer_id(int) -> { "name": String, "ping": float, "loss": float,
#                   "hist": PackedFloat32Array }
var _net_peers: Dictionary = {}
var _net_active: bool = false
var _net_role: String = ""

# --- UI nodes (all built in _ready()).
var _root: Control = null
var _fps_label: Label = null
var _numeric_panel: PanelContainer = null
var _numeric_label: RichTextLabel = null
var _graph_ctrl: GraphDraw = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128
	_build_ui()
	_apply_hud_inset()
	if not Events.ui_layout_changed.is_connected(_apply_hud_inset):
		Events.ui_layout_changed.connect(_apply_hud_inset)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_hud_inset):
		vp.size_changed.connect(_apply_hud_inset)
	Events.stats_overlay_changed.connect(_on_config)
	# Initial state from the persisted settings.
	var sf: bool = bool(SettingsManager.get_value("show_fps"))
	var sd: bool = bool(SettingsManager.get_value("show_detailed_stats"))
	var md: int = int(SettingsManager.get_value("stats_display_mode"))
	set_config(sf, sd, md)


# --- UI construction -------------------------------------------------------


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	# Minimal FPS counter (top-left).
	_fps_label = Label.new()
	_fps_label.name = "FpsLabel"
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.position = Vector2(BASE_X, BASE_Y)
	_fps_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.75, 0.95))
	_fps_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_fps_label.add_theme_constant_override("shadow_offset_x", 1)
	_fps_label.add_theme_constant_override("shadow_offset_y", 1)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.text = "FPS --"
	_fps_label.visible = false
	_root.add_child(_fps_label)

	# Detailed NUMERIC panel (top-left, under the FPS line).
	_numeric_panel = PanelContainer.new()
	_numeric_panel.name = "NumericPanel"
	_numeric_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_numeric_panel.position = Vector2(BASE_X, BASE_Y)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.03, 0.05, 0.45)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	_numeric_panel.add_theme_stylebox_override("panel", sb)
	_numeric_panel.visible = false
	_root.add_child(_numeric_panel)

	_numeric_label = RichTextLabel.new()
	_numeric_label.name = "NumericLabel"
	_numeric_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_numeric_label.bbcode_enabled = true
	_numeric_label.fit_content = true
	_numeric_label.scroll_active = false
	_numeric_label.custom_minimum_size = Vector2(230, 0)
	_numeric_label.add_theme_color_override("default_color", Color(0.86, 0.92, 0.98, 0.95))
	_numeric_label.add_theme_font_size_override("normal_font_size", 13)
	_numeric_label.add_theme_font_size_override("bold_font_size", 13)
	_numeric_panel.add_child(_numeric_label)

	# Detailed GRAPHS control (custom-drawn, top-left).
	_graph_ctrl = GraphDraw.new()
	_graph_ctrl.name = "GraphPanel"
	_graph_ctrl.owner_overlay = self
	_graph_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_graph_ctrl.position = Vector2(BASE_X, BASE_Y)
	_graph_ctrl.custom_minimum_size = Vector2(GRAPH_W + 16.0, 0.0)
	_graph_ctrl.visible = false
	_root.add_child(_graph_ctrl)


# --- Config ----------------------------------------------------------------


func set_config(show_fps: bool, show_detailed: bool, mode: int) -> void:
	_show_fps = show_fps
	_show_detailed = show_detailed
	_mode = mode
	_apply_config()


func _on_config(a: bool, b: bool, c: int) -> void:
	set_config(a, b, c)


func _apply_config() -> void:
	# The minimal FPS line shows only when fps is on AND we're NOT showing the detailed
	# panel (the detailed panel carries its own FPS row first).
	if _fps_label != null:
		_fps_label.visible = _show_fps and not _show_detailed
	# Mode 0 → numeric only; 1 → graphs only; 2 → BOTH (graphs on top, numbers stacked
	# directly below so they never overlap).
	if _numeric_panel != null:
		_numeric_panel.visible = _show_detailed and (_mode == 0 or _mode == 2)
	if _graph_ctrl != null:
		_graph_ctrl.visible = _show_detailed and (_mode == 1 or _mode == 2)
	# Re-inset (also positions the numeric panel under the graph in mode 2).
	_apply_hud_inset()
	# Force an immediate refresh so a freshly-toggled view isn't blank until the next
	# throttle tick.
	if _is_anything_visible():
		_sample()
		_refresh_views()


## Pull the three top-left widgets in toward center (ultrawide comfort) from their
## authored (BASE_X, BASE_Y) anchor, and — in mode 2 — stack the numeric panel directly
## below the graph control. Recomputed from base every call so it's idempotent; at
## margin 0 (ex=ty=0) positions are byte-identical to the authored (10, 8).
func _apply_hud_inset() -> void:
	var sz: Vector2 = get_viewport().get_visible_rect().size
	var ex: float = UILayout.edge_px(sz.x)
	var ty: float = UILayout.top_px(sz.y)
	var bx: float = BASE_X + ex
	var by: float = BASE_Y + ty
	if _fps_label != null:
		_fps_label.position = Vector2(bx, by)
	if _graph_ctrl != null:
		_graph_ctrl.position = Vector2(bx, by)
	if _numeric_panel != null:
		if _mode == 2:
			# Stack the numbers directly under the graph stack (use its live height, or a
			# sensible fallback before it has been laid out).
			var gh: float = _graph_ctrl.size.y if _graph_ctrl != null else 0.0
			if gh <= 0.0:
				gh = GRAPH_STACK_H_FALLBACK
			_numeric_panel.position = Vector2(bx, by + gh + 8.0)
		else:
			_numeric_panel.position = Vector2(bx, by)


func _is_anything_visible() -> bool:
	return (
		(_fps_label != null and _fps_label.visible)
		or (_numeric_panel != null and _numeric_panel.visible)
		or (_graph_ctrl != null and _graph_ctrl.visible)
	)


# --- Sampling loop ---------------------------------------------------------


func _process(delta: float) -> void:
	if not _is_anything_visible():
		return
	_accum += delta
	if _accum < SAMPLE_INTERVAL:
		return
	_accum = 0.0
	_sample()
	_refresh_views()


func _sample() -> void:
	_fps = float(Engine.get_frames_per_second())
	var fpt: float = float(Performance.get_monitor(Performance.TIME_PROCESS))
	_frame_ms = fpt * 1000.0
	var ppt: float = float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	_phys_ms = ppt * 1000.0
	_draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_primitives = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vmem: float = float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	_video_mem_mb = vmem / 1048576.0
	var smem: float = float(Performance.get_monitor(Performance.MEMORY_STATIC))
	_static_mem_mb = smem / 1048576.0
	_node_count = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))

	# Rolling FPS history → 1% low + min.
	_push_capped(_fps_hist, _fps, FPS_HISTORY_CAP)
	_push_capped(_frame_hist, _frame_ms, FRAME_HISTORY_CAP)
	_compute_fps_lows()

	_sample_network()


func _push_capped(arr: PackedFloat32Array, v: float, cap: int) -> void:
	arr.push_back(v)
	while arr.size() > cap:
		arr.remove_at(0)


func _compute_fps_lows() -> void:
	if _fps_hist.is_empty():
		_fps_1low = 0.0
		_fps_min = 0.0
		return
	# Sort a copy ascending; min is index 0, 1% low is the value at the 1st percentile.
	var sorted: Array = Array(_fps_hist)
	sorted.sort()
	_fps_min = float(sorted[0])
	var idx: int = int(floor(float(sorted.size()) * 0.01))
	idx = clampi(idx, 0, sorted.size() - 1)
	_fps_1low = float(sorted[idx])


func _sample_network() -> void:
	_net_active = false
	_net_role = ""
	# Hard guard: single-player uses an OfflineMultiplayerPeer.
	var mpeer: MultiplayerPeer = multiplayer.multiplayer_peer
	if not (mpeer is ENetMultiplayerPeer):
		_net_peers.clear()
		return
	_net_active = true
	_net_role = "HOST" if multiplayer.is_server() else "CLIENT"
	var mp: ENetMultiplayerPeer = mpeer as ENetMultiplayerPeer
	var my_id: int = multiplayer.get_unique_id()

	var seen: Dictionary = {}
	for pid_v in GameState.peers.keys():
		var pid: int = int(pid_v)
		if pid == my_id:
			continue
		var info: Dictionary = GameState.peers.get(pid, {})
		var pname: String = String(info.get("name", "peer %d" % pid))
		var ping: float = 0.0
		var loss: float = 0.0
		# get_peer can fail / return null for ids without a live ENet connection.
		var ep: ENetPacketPeer = null
		ep = mp.get_peer(pid)
		if ep != null:
			var rtt: float = float(ep.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
			ping = rtt
			var lossraw: float = float(ep.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS))
			loss = (lossraw / float(ENetPacketPeer.PACKET_LOSS_SCALE)) * 100.0
		var rec: Dictionary = _net_peers.get(pid, {})
		var hist: PackedFloat32Array = rec.get("hist", PackedFloat32Array())
		_push_capped(hist, ping, PING_HISTORY_CAP)
		_net_peers[pid] = {"name": pname, "ping": ping, "loss": loss, "hist": hist}
		seen[pid] = true
	# Drop peers that left.
	for pid_v in _net_peers.keys():
		if not seen.has(pid_v):
			_net_peers.erase(pid_v)


# --- View refresh ----------------------------------------------------------


func _refresh_views() -> void:
	if _fps_label != null and _fps_label.visible:
		_fps_label.text = "FPS %d  %.1fms" % [int(round(_fps)), _frame_ms]
	if _numeric_panel != null and _numeric_panel.visible:
		_update_numeric()
	if _graph_ctrl != null and _graph_ctrl.visible:
		_graph_ctrl.queue_redraw()


func _update_numeric() -> void:
	if _numeric_label == null:
		return
	var t := (
		"[b]FPS[/b] %d  ([color=#aaff99]1%%low %d  min %d[/color])\n"
		% [int(round(_fps)), int(round(_fps_1low)), int(round(_fps_min))]
	)
	t += "frame %.2fms   phys %.2fms\n" % [_frame_ms, _phys_ms]
	t += "draws %d   prims %s\n" % [_draw_calls, _fmt_count(_primitives)]
	t += "vram %.1f MB   mem %.1f MB\n" % [_video_mem_mb, _static_mem_mb]
	t += "nodes %d" % _node_count
	if _net_active:
		t += "\n[b]NET[/b] %s   peers %d" % [_net_role, GameState.peers.size()]
		for pid_v in _net_peers.keys():
			var rec: Dictionary = _net_peers[pid_v]
			t += (
				"\n  %s  %dms  %.1f%%"
				% [
					String(rec.get("name", "?")),
					int(round(float(rec.get("ping", 0.0)))),
					float(rec.get("loss", 0.0))
				]
			)
	_numeric_label.text = t


func _fmt_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)


# Accessors used by the inner GraphDraw class.
func get_fps_hist() -> PackedFloat32Array:
	return _fps_hist


func get_frame_hist() -> PackedFloat32Array:
	return _frame_hist


func get_fps() -> float:
	return _fps


func get_frame_ms() -> float:
	return _frame_ms


func get_net_active() -> bool:
	return _net_active


func get_net_peers() -> Dictionary:
	return _net_peers


# ===========================================================================
## Inner custom-drawn Control: 2-3 stacked rolling graphs (FPS, frame-time, and a
## per-peer ping graph when networked). Mirrors the project's _draw()+queue_redraw()
## rolling-buffer idiom (see minimap.gd / map_ui.gd's MapDraw).
class GraphDraw:
	extends Control
	var owner_overlay = null

	func _draw() -> void:
		if owner_overlay == null:
			return
		var font := ThemeDB.fallback_font
		var w: float = owner_overlay.GRAPH_W
		var h: float = owner_overlay.GRAPH_H
		var gap: float = 8.0
		var y: float = 0.0

		# FPS graph (green polyline; auto-scaled, but at least 0..120).
		var fps_hist: PackedFloat32Array = owner_overlay.get_fps_hist()
		_graph(
			font,
			Rect2(0, y, w, h),
			fps_hist,
			"FPS  %d" % int(round(owner_overlay.get_fps())),
			Color(0.4, 1.0, 0.55, 0.95),
			120.0
		)
		y += h + gap

		# Frame-time graph (amber; ms, at least 0..33ms / ~30fps budget).
		var frame_hist: PackedFloat32Array = owner_overlay.get_frame_hist()
		_graph(
			font,
			Rect2(0, y, w, h),
			frame_hist,
			"frame  %.1fms" % owner_overlay.get_frame_ms(),
			Color(1.0, 0.75, 0.35, 0.95),
			33.0
		)
		y += h + gap

		# Per-peer ping graph (networked only).
		if owner_overlay.get_net_active():
			var peers: Dictionary = owner_overlay.get_net_peers()
			if not peers.is_empty():
				var rect := Rect2(0, y, w, h)
				_graph_bg(rect)
				var maxv: float = 50.0
				var i: int = 0
				var palette := [
					Color(0.5, 0.8, 1.0, 0.95),
					Color(1.0, 0.6, 0.9, 0.95),
					Color(0.9, 0.9, 0.5, 0.95),
					Color(0.6, 1.0, 0.8, 0.95)
				]
				# First pass: find the shared vertical scale.
				for pid_v in peers.keys():
					var rec0: Dictionary = peers[pid_v]
					var hh: PackedFloat32Array = rec0.get("hist", PackedFloat32Array())
					for v in hh:
						if v > maxv:
							maxv = v
				# Second pass: draw each peer's ping polyline + a small legend.
				var ly: float = rect.position.y + 12.0
				for pid_v in peers.keys():
					var rec: Dictionary = peers[pid_v]
					var col: Color = palette[i % palette.size()]
					var hist: PackedFloat32Array = rec.get("hist", PackedFloat32Array())
					_polyline(rect, hist, col, maxv)
					var lbl: String = (
						"%s %dms"
						% [String(rec.get("name", "?")), int(round(float(rec.get("ping", 0.0))))]
					)
					draw_string(
						font,
						Vector2(rect.position.x + 4.0, ly),
						lbl,
						HORIZONTAL_ALIGNMENT_LEFT,
						w - 8.0,
						11,
						col
					)
					ly += 13.0
					i += 1
				draw_string(
					font,
					Vector2(rect.position.x + 4.0, rect.position.y + rect.size.y - 4.0),
					"ping  max %dms" % int(round(maxv)),
					HORIZONTAL_ALIGNMENT_LEFT,
					w - 8.0,
					11,
					Color(0.8, 0.85, 0.9, 0.7)
				)
				custom_minimum_size = Vector2(w + 16.0, y + h + 4.0)
				return
		custom_minimum_size = Vector2(w + 16.0, y + 4.0)

	# One labelled rolling graph (translucent bg + green/amber polyline + value text).
	func _graph(
		font: Font,
		rect: Rect2,
		hist: PackedFloat32Array,
		label: String,
		col: Color,
		floor_max: float
	) -> void:
		_graph_bg(rect)
		var maxv: float = floor_max
		for v in hist:
			if v > maxv:
				maxv = v
		_polyline(rect, hist, col, maxv)
		draw_string(
			font,
			Vector2(rect.position.x + 4.0, rect.position.y + 13.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 8.0,
			12,
			col
		)

	func _graph_bg(rect: Rect2) -> void:
		draw_rect(rect, Color(0.02, 0.03, 0.05, 0.45), true)
		draw_rect(rect, Color(0.4, 0.55, 0.7, 0.5), false, 1.0)

	# Map a history buffer to a polyline filling the rect width, scaled by maxv.
	func _polyline(rect: Rect2, hist: PackedFloat32Array, col: Color, maxv: float) -> void:
		var n: int = hist.size()
		if n < 2 or maxv <= 0.0:
			return
		var pts := PackedVector2Array()
		var pad: float = 2.0
		var inner_w: float = rect.size.x - pad * 2.0
		var inner_h: float = rect.size.y - pad * 2.0
		for j in range(n):
			var fx: float = rect.position.x + pad + inner_w * (float(j) / float(n - 1))
			var frac: float = clampf(hist[j] / maxv, 0.0, 1.0)
			var fy: float = rect.position.y + pad + inner_h * (1.0 - frac)
			pts.push_back(Vector2(fx, fy))
		draw_polyline(pts, col, 1.5, true)
