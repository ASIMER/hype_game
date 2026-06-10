extends Node
## Server-authoritative director for the map's timed extraction windows.
##
## The Arena places several ExtractionZone Area3Ds (group "extraction"). Rather than
## every zone always being usable, this director ROTATES their open/closed windows so
## the map always shows a few zones with different countdowns — the player must read
## the timers and route to whichever exit is open. Zones are phase-STAGGERED so they
## don't all open/close in lockstep (ideally at least one is open at any moment, with
## occasional overlap).
##
## Each zone follows a fixed cycle of length OPEN_DURATION + COOLDOWN. Zone i is offset
## by i * STAGGER seconds, so we can derive any zone's state from a single match clock
## (`_elapsed`) — robust to zones (un)registering and to clients, which never run this
## (they mirror state through Events.extraction_window_changed emitted by set_window).
##
## During the final/storm phase (GameState.final_wave) ALL zones are forced OPEN as a
## last-chance escape from the overwhelming storm wave.
##
## Registered as an autoload by project.godot (the lead wires this in). extends Node.

# Zones we're driving this match, in a stable order (phase offset = index * stagger).
var _zones: Array[Node] = []
var _active: bool = false        # rotating this match (server-auth only)
var _elapsed: float = 0.0        # seconds since the match started
var _emit_accum: float = 0.0     # throttle periodic re-emits to ~1x/sec
const EMIT_INTERVAL: float = 1.0
var _forced_open: bool = false   # latched once storm forces all zones open

func _ready() -> void:
	# Re-(arm) the rotation whenever a match starts. Offline arenas may emit
	# match_started before this autoload's _ready, so also try to start immediately
	# if we're already in a match.
	if not Events.match_started.is_connected(_on_match_started):
		Events.match_started.connect(_on_match_started)
	# Clean reset on match end so a new match starts fresh.
	if Events.has_signal("match_won") and not Events.match_won.is_connected(_on_match_over):
		Events.match_won.connect(_on_match_over)
	if Events.has_signal("match_lost") and not Events.match_lost.is_connected(_on_match_over):
		Events.match_lost.connect(_on_match_over)
	if GameState.phase == GameState.Phase.IN_MATCH:
		_on_match_started.call_deferred()

func _on_match_started() -> void:
	# Server (incl. offline host) only — clients mirror via Events.
	if not GameState.is_local_authority_server():
		return
	_gather_zones.call_deferred()

func _on_match_over() -> void:
	_active = false
	_zones.clear()
	_elapsed = 0.0
	_emit_accum = 0.0
	_forced_open = false

## Collect the arena's extraction zones (deferred so they've finished _ready and joined
## the group). Seed each zone's initial window from its phase offset.
func _gather_zones() -> void:
	if not GameState.is_local_authority_server():
		return
	_zones.clear()
	for z in get_tree().get_nodes_in_group(Groups.EXTRACTION):
		if is_instance_valid(z) and z.has_method("set_window"):
			_zones.append(z)
	if _zones.is_empty():
		_active = false
		return
	_elapsed = 0.0
	_emit_accum = 0.0
	_forced_open = false
	_active = true
	# Push the starting state immediately so UIs render correct countdowns at t=0.
	_apply_windows(true)

func _process(delta: float) -> void:
	if not _active or not GameState.is_local_authority_server():
		return
	# Stop once everyone is resolved (match effectively over even before the signal).
	if GameState.all_players_resolved():
		return
	_elapsed += delta

	# Storm: force every zone open exactly once (last-chance escape). Latched so we
	# don't re-emit every frame; the periodic re-emit below keeps countdowns fresh.
	if GameState.final_wave:
		if not _forced_open:
			_forced_open = true
			for z in _zones:
				if is_instance_valid(z):
					z.set_window(true, 0.0)
		# Still tick the periodic re-emit so HUDs keep a live (open) state.
		_emit_accum += delta
		if _emit_accum >= EMIT_INTERVAL:
			_emit_accum = 0.0
			for z in _zones:
				if is_instance_valid(z) and z.has_method("set_window"):
					z.set_window(true, 0.0)
		return

	# Normal rotation. Flip any zone whose state changed this tick; periodically
	# re-emit countdowns (~1x/sec) so HUD timers stay live without per-frame spam.
	_emit_accum += delta
	var periodic := _emit_accum >= EMIT_INTERVAL
	if periodic:
		_emit_accum = 0.0
	_apply_windows(periodic)

## Compute each zone's open/closed state + remaining time from the match clock and
## drive it via set_window(). set_window only emits on a real state change unless we
## pass it the same state (which it treats as a countdown refresh) — so `force` (or a
## genuine flip inside the zone) is what reaches the UI.
func _apply_windows(force: bool) -> void:
	var cycle: float = Settings.EXTRACT_OPEN_DURATION + Settings.EXTRACT_COOLDOWN
	if cycle <= 0.0:
		return
	for i in _zones.size():
		var z: Node = _zones[i]
		if not is_instance_valid(z) or not z.has_method("set_window"):
			continue
		var phase: float = _elapsed + float(i) * Settings.EXTRACT_WINDOW_STAGGER
		# Position within this zone's cycle.
		var t: float = fmod(phase, cycle)
		if t < 0.0:
			t += cycle
		var is_open: bool = t < Settings.EXTRACT_OPEN_DURATION
		var remaining: float
		if is_open:
			remaining = Settings.EXTRACT_OPEN_DURATION - t
		else:
			remaining = cycle - t
		# Always call when a flip is needed (set_window no-ops same-state unless we
		# want a refresh). To get periodic countdown refreshes we call on `force` too;
		# set_window emits a refresh for same-state and a full flip otherwise.
		var changed: bool = (z.has_method("is_open") and bool(z.is_open()) != is_open)
		if force or changed:
			z.set_window(is_open, maxf(remaining, 0.0))
