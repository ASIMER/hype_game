extends CanvasLayer
class_name HitMarker
## Self-contained screen-center HIT MARKER overlay. Flashes a small white 4-tick
## "X" when the LOCAL player damages an enemy, and a bigger RED "X" on a kill
## credited to the local player. Purely visual/local — never networked.
##
## Keys off the existing Events bus (no new global signals needed):
##   Events.damage_dealt(target, amount, source)  -> white hit tick
##   Events.entity_died(entity, killer)            -> red kill tick (+ tiny shake)
##   Events.local_player_spawned(player)           -> learns who "local" is, so it
##                                                    can filter source/killer.
##
## INSTANCING: the lead instances HitMarker.tscn (root = this script) once under
## the arena UI / main scene. It needs no configuration and is safe in headless
## (it guards on a missing viewport and simply never draws).
##
## If the local player isn't known yet (no local_player_spawned seen), it falls
## back to showing on ANY damage_dealt/entity_died — robust over silent.

# How long each marker stays fully visible before fading out (seconds).
const HIT_TIME: float = 0.12
const KILL_TIME: float = 0.22

# Sizing of the X (gap from center to inner tip, and tick length), in pixels.
const HIT_GAP: float = 5.0
const HIT_LEN: float = 9.0
const HIT_WIDTH: float = 2.0
const KILL_GAP: float = 7.0
const KILL_LEN: float = 16.0
const KILL_WIDTH: float = 3.0

var _local_player: Node = null

var _hit_t: float = 0.0       # white hit-tick timer
var _kill_t: float = 0.0      # red kill-tick timer

var _draw_ctrl: Control = null

func _ready() -> void:
	# Build a full-rect Control that does the drawing, centered marks via get_size.
	_draw_ctrl = Control.new()
	_draw_ctrl.name = "Draw"
	_draw_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_draw_ctrl.draw.connect(_on_draw)
	add_child(_draw_ctrl)

	# Sit above the world; below pause menus is fine.
	layer = 5

	if not Events.damage_dealt.is_connected(_on_damage_dealt):
		Events.damage_dealt.connect(_on_damage_dealt)
	if not Events.entity_died.is_connected(_on_entity_died):
		Events.entity_died.connect(_on_entity_died)
	if not Events.local_player_spawned.is_connected(_on_local_player_spawned):
		Events.local_player_spawned.connect(_on_local_player_spawned)

func _on_local_player_spawned(player: Node) -> void:
	_local_player = player

## True if `node` is (or belongs to) the local player. When we don't yet know the
## local player, returns true so the marker still shows — robust over silent.
func _is_local_source(node: Node) -> bool:
	if _local_player == null or not is_instance_valid(_local_player):
		return true
	var n := node
	while n != null:
		if n == _local_player:
			return true
		n = n.get_parent()
	return false

func _is_enemy(node: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group("enemies"):
			return true
		n = n.get_parent()
	return false

func _on_damage_dealt(target: Node, _amount: float, source: Node) -> void:
	# Only react to the LOCAL player hurting an ENEMY (ignore enemy-on-player, etc).
	if not _is_enemy(target):
		return
	if not _is_local_source(source):
		return
	_hit_t = HIT_TIME
	if _draw_ctrl:
		_draw_ctrl.queue_redraw()

func _on_entity_died(entity: Node, killer: Node) -> void:
	if not _is_enemy(entity):
		return
	if not _is_local_source(killer):
		return
	_kill_t = KILL_TIME
	if _draw_ctrl:
		_draw_ctrl.queue_redraw()
	# A touch of punch on a confirmed kill (existing global signal; cheap, local).
	Events.screen_shake.emit(0.12)

func _process(delta: float) -> void:
	if _hit_t <= 0.0 and _kill_t <= 0.0:
		return
	var redraw := false
	if _hit_t > 0.0:
		_hit_t = maxf(0.0, _hit_t - delta)
		redraw = true
	if _kill_t > 0.0:
		_kill_t = maxf(0.0, _kill_t - delta)
		redraw = true
	if redraw and _draw_ctrl:
		_draw_ctrl.queue_redraw()

func _on_draw() -> void:
	if _draw_ctrl == null:
		return
	var center := _draw_ctrl.size * 0.5
	# White hit tick (drawn first, under the kill tick).
	if _hit_t > 0.0:
		var a := clampf(_hit_t / HIT_TIME, 0.0, 1.0)
		_draw_x(center, HIT_GAP, HIT_LEN, HIT_WIDTH, Color(1, 1, 1, a))
	# Red kill tick (bigger, on top).
	if _kill_t > 0.0:
		var ka := clampf(_kill_t / KILL_TIME, 0.0, 1.0)
		_draw_x(center, KILL_GAP, KILL_LEN, KILL_WIDTH, Color(1.0, 0.2, 0.15, ka))

## Draws a 4-tick "X": four short diagonal strokes leaving a gap at the center.
func _draw_x(center: Vector2, gap: float, length: float, width: float, col: Color) -> void:
	var diag := Vector2(0.7071, 0.7071)   # 45° unit
	var dirs := [
		Vector2(diag.x, diag.y),
		Vector2(-diag.x, diag.y),
		Vector2(diag.x, -diag.y),
		Vector2(-diag.x, -diag.y),
	]
	for d in dirs:
		var p0: Vector2 = center + d * gap
		var p1: Vector2 = center + d * (gap + length)
		_draw_ctrl.draw_line(p0, p1, col, width, true)
