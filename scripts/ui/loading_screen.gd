extends CanvasLayer
## Full-screen loading overlay with a progress bar. Shows visible progress during the
## (otherwise window-freezing) synchronous arena build and at game boot, instead of a
## frozen black window. Built entirely in code in _ready() (project idiom), layer=200
## so it sits above everything, PROCESS_MODE_ALWAYS so it animates while the rest of
## the tree pauses.
##
## Driven two ways:
##   - Passive: listens to Events.arena_build_progress(frac, label) — auto-shows on the
##     first event, advances the bar, auto-hides (deferred a frame) at frac >= 1.0.
##   - Active: the integrator calls `await LoadingScreen.prewarm()` at game boot to pace
##     the bar through a few graphics-prep phases.

const BG_COLOR := Color(0.04, 0.05, 0.07)

var _bg: ColorRect
var _title: Label
var _bar: ProgressBar
var _status: Label

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 200
	_build_ui()
	visible = false
	if not Events.arena_build_progress.is_connected(_on_arena_build_progress):
		Events.arena_build_progress.connect(_on_arena_build_progress)

func _build_ui() -> void:
	# Full-rect opaque dark backdrop.
	_bg = ColorRect.new()
	_bg.color = BG_COLOR
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bg)

	# Centered vertical stack (title / bar / status).
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	col.custom_minimum_size = Vector2(420, 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(col)

	_title = Label.new()
	_title.text = "HYPE RAIDERS"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 34)
	_title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	col.add_child(_title)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.value = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(420, 22)
	col.add_child(_bar)

	_status = Label.new()
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color(0.66, 0.72, 0.82))
	col.add_child(_status)

# ------------------------------------------------------------------- public API
## Shows the overlay with `title`, resets the bar to 0, and moves to front.
func show_screen(title: String = "Loading…") -> void:
	if _title:
		_title.text = title
	if _bar:
		_bar.value = 0.0
	if _status:
		_status.text = ""
	visible = true
	# Keep above any sibling CanvasLayers added after us.
	layer = 200

## Sets the bar (clamped 0..1) + status text. Callers should
## `await get_tree().process_frame` after this so the repaint is visible.
func set_progress(frac: float, label: String = "") -> void:
	if _bar:
		_bar.value = clampf(frac, 0.0, 1.0)
	if label != "" and _status:
		_status.text = label

## Hides the overlay.
func hide_screen() -> void:
	visible = false

# --------------------------------------------------------------- event-driven
func _on_arena_build_progress(frac: float, label: String) -> void:
	if not visible:
		show_screen("ENTERING RAID…")
	set_progress(frac, label)
	if frac >= 1.0:
		# Defer one frame so the full bar is visible briefly before it vanishes.
		_hide_next_frame()

func _hide_next_frame() -> void:
	await get_tree().process_frame
	hide_screen()

# ------------------------------------------------------------------- prewarm
## Game-boot graphics warm-up. Best-effort + headless-safe: paces the progress bar
## through a few phases (and, when a real renderer is present, force-compiles a couple
## of heavy materials in a tiny off-screen SubViewport so the first frame in-world
## isn't a shader-compile hitch). The integrator calls `await LoadingScreen.prewarm()`.
func prewarm(steps_label: String = "Preparing graphics…") -> void:
	var headless := DisplayServer.get_name() == "headless"
	show_screen(steps_label)
	if headless:
		# Nothing to render — just pass a couple of frames so callers' awaits resolve.
		await get_tree().process_frame
		await get_tree().process_frame
		hide_screen()
		return

	var phases := ["Shaders", "Materials", "Icons", "World"]
	var n := phases.size()
	for i in range(n):
		set_progress(float(i) / float(n), phases[i])
		if i == 0:
			# Best-effort real shader/material compile (guarded — a working bar matters
			# more than aggressive prewarm).
			await _compile_materials()
		else:
			await get_tree().create_timer(0.05).timeout
	set_progress(1.0, "Ready")
	await get_tree().process_frame
	hide_screen()

## Instantiates the shared procedural materials into a 1-mesh off-screen SubViewport
## and renders one frame, forcing their shaders to compile up front. Wrapped so any
## failure (missing autoload, headless edge) just returns without crashing boot.
func _compile_materials() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(16, 16)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)

	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	# Pull in the shared weathered material (ProcMaterials autoload) so its triplanar
	# shader variant compiles now rather than on the first in-world frame.
	var mat: Material = ProcMaterials.weathered(
		Color(0.16, 0.165, 0.175), 0.0, 0.95, 0.5, 7,
		Vector3(0.05, 0.05, 0.05), true)
	if mat != null:
		mesh.material_override = mat
	vp.add_child(mesh)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3)
	vp.add_child(cam)
	cam.make_current()

	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	vp.queue_free()
