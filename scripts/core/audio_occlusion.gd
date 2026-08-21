class_name AudioOcclusion
extends Node
## Audio occlusion (D5.2) — a firefight BEHIND a wall must SOUND like it is behind a wall.
## Code-instanced child of AudioManager (the EnemyStatus / PlayerHijack component pattern:
## the host file only registers emitters, all the logic lives here).
##
## Purely LOCAL + render-only: nothing is replicated and no gameplay code reads the factor,
## so two peers hearing the same shot differently is BY DESIGN (they stand in different
## places). Headless never builds this node at all — AudioManager skips it there.
##
## THE MUFFLE. AudioStreamPlayer3D already carries a per-emitter high-shelf filter
## (`attenuation_filter_cutoff_hz` + `attenuation_filter_db`). The engine scales that
## shelf's GAIN by the emitter's distance attenuation (set_playback_highshelf_params), so
## dropping the cutoff ALONE is nearly inaudible up close — we drive both ends of the shelf
## and layer a small, distance-independent volume trim on top. Together they read as
## "through concrete" instead of "quieter".
##
## PERF. Never a ray per frame: emitters are visited round-robin in small batches
## (AUDIO_OCCLUSION_RAYS_PER_TICK every AUDIO_OCCLUSION_TICK s) and the per-frame work is
## just the smoothing of a cached factor. A brand-new emitter gets ONE immediate seed ray
## (own small budget) because a 0.3 s gunshot would END before any fade-in reached it.

## Node-meta state (the EnemyDance / chem-ICD pattern): it dies WITH the self-freeing
## emitter, so a one-shot pool can never leak entries into a side table.
const _META_BASE_DB := "occ_base_db"  # volume_db the emitter was spawned with
const _META_OCC := "occ"  # smoothed 0..1 occlusion factor (what is applied)
const _META_TARGET := "occ_target"  # last raycast verdict (0/1) — the smoothing target

## Spatial-coherence cache: consecutive one-shots of ONE firefight (full-auto cracks, hit
## thuds) resolve against the same wall, so a fresh emitter within _CACHE_RADIUS of a recent
## sample reuses its verdict for free. Kills both the extra rays AND the shot-to-shot
## flicker a purely per-emitter test produces when the shooter hugs a wall edge.
const _CACHE_MAX := 6
const _CACHE_TTL := 0.4  # s a sample stays trustworthy
const _CACHE_RADIUS := 3.0  # m around a sample it may be reused

var _tracked: Array[AudioStreamPlayer3D] = []
var _cursor: int = 0  # round-robin position inside _tracked
var _poll: float = 0.0  # countdown to the next refresh batch
var _seed_budget: int = 0  # seed rays left in this tick window
var _cam: Camera3D = null  # the local listener (refreshed every frame)
var _cache: Array[Dictionary] = []  # {pos: Vector3, occ: float, t: float}
var _log_open: float = 0.0  # log() of the open/blocked cutoffs — the sweep is
var _log_blocked: float = 0.0  # interpolated in LOG space so it sounds linear


func _ready() -> void:
	_log_open = log(maxf(Settings.AUDIO_OCCLUSION_CUTOFF_OPEN_HZ, 1.0))
	_log_blocked = log(maxf(Settings.AUDIO_OCCLUSION_CUTOFF_BLOCKED_HZ, 1.0))
	_seed_budget = Settings.AUDIO_OCCLUSION_SEED_RAYS_PER_TICK


## Register a freshly spawned positional one-shot. Call it AFTER volume_db + global_position
## are set and BEFORE play() — the seed ray needs the real position, and the base volume is
## captured here so the trim can never accumulate on itself.
func track(p: AudioStreamPlayer3D) -> void:
	if p == null or not p.is_inside_tree():
		return
	if _tracked.size() >= Settings.AUDIO_OCCLUSION_MAX_TRACKED:
		return  # pathological burst — extra emitters simply play unoccluded
	var occ: float = _seed_factor(p)
	p.set_meta(_META_BASE_DB, p.volume_db)
	p.set_meta(_META_OCC, occ)
	p.set_meta(_META_TARGET, occ)
	_apply(p, occ)
	_tracked.append(p)


func _process(delta: float) -> void:
	_expire_cache(delta)
	if _tracked.is_empty():
		return
	_prune()
	_cam = _listener()
	if _cam == null:
		return  # no local camera (menu / teardown) → leave every emitter as it is
	_poll -= delta
	if _poll <= 0.0:
		_poll = Settings.AUDIO_OCCLUSION_TICK
		_seed_budget = Settings.AUDIO_OCCLUSION_SEED_RAYS_PER_TICK
		_refresh_batch()
	# Exponential approach — framerate-independent, so sprinting past a doorway sweeps
	# instead of clicking.
	var alpha: float = 1.0 - exp(-delta / maxf(Settings.AUDIO_OCCLUSION_SMOOTH, 0.01))
	for p in _tracked:
		var occ: float = lerpf(
			float(p.get_meta(_META_OCC, 0.0)), float(p.get_meta(_META_TARGET, 0.0)), alpha
		)
		p.set_meta(_META_OCC, occ)
		_apply(p, occ)


## Drop finished/freed emitters (they self-free on `finished`, so this is just bookkeeping).
func _prune() -> void:
	for i in range(_tracked.size() - 1, -1, -1):
		var p: AudioStreamPlayer3D = _tracked[i]
		if not is_instance_valid(p) or not p.playing:
			_tracked.remove_at(i)
			if _cursor > i:
				_cursor -= 1


## Re-test up to AUDIO_OCCLUSION_RAYS_PER_TICK emitters, continuing where the last tick
## stopped — a long fight with 20 live sounds costs the same as one with 8.
func _refresh_batch() -> void:
	var lpos: Vector3 = _cam.global_position
	var n: int = mini(Settings.AUDIO_OCCLUSION_RAYS_PER_TICK, _tracked.size())
	for _i in n:
		if _cursor >= _tracked.size():
			_cursor = 0
		var p: AudioStreamPlayer3D = _tracked[_cursor]
		_cursor += 1
		var pos: Vector3 = p.global_position
		var d: float = pos.distance_to(lpos)
		if d < Settings.AUDIO_OCCLUSION_MIN_DIST or d > Settings.AUDIO_OCCLUSION_MAX_DIST:
			# Point-blank: nothing can be between us. Far: already rolled off to nothing.
			p.set_meta(_META_TARGET, 0.0)
			continue
		var occ: float = _cast(pos, lpos)
		p.set_meta(_META_TARGET, occ)
		_cache_store(pos, occ)


## The factor a brand-new emitter starts at (no fade-in — one-shots are shorter than any
## smoothing). Served from the coherence cache when possible, else one budgeted ray.
func _seed_factor(p: AudioStreamPlayer3D) -> float:
	var cam := _listener()
	if cam == null:
		return 0.0
	var pos: Vector3 = p.global_position
	var lpos: Vector3 = cam.global_position
	var d: float = pos.distance_to(lpos)
	if d < Settings.AUDIO_OCCLUSION_MIN_DIST or d > Settings.AUDIO_OCCLUSION_MAX_DIST:
		return 0.0
	var cached: float = _cache_lookup(pos)
	if cached >= 0.0:
		return cached
	if _seed_budget <= 0:
		return 0.0  # budget spent this tick — the refresh batch corrects it within a tick
	_seed_budget -= 1
	var occ: float = _cast(pos, lpos)
	_cache_store(pos, occ)
	return occ


## One emitter→listener ray on the WORLD layer only (bit 1, the `collision_mask = 1` contract
## used by the spring arm / player probes): players, enemies and hit/hurtboxes must NEVER
## occlude — a teammate standing in the line of fire is not a wall.
func _cast(from: Vector3, to: Vector3) -> float:
	if _cam == null or not _cam.is_inside_tree():
		return 0.0
	var world := _cam.get_world_3d()
	if world == null:
		return 0.0
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.collide_with_areas = false
	return 1.0 if not space.intersect_ray(q).is_empty() else 0.0


## Write the factor into the emitter: the built-in high-shelf (both cutoff AND depth, see
## the header) plus a small volume trim that works at any distance.
func _apply(p: AudioStreamPlayer3D, occ: float) -> void:
	if not p.has_meta(_META_BASE_DB):
		return  # never re-derive the base from the live volume — that would drift downwards
	p.attenuation_filter_cutoff_hz = exp(lerpf(_log_open, _log_blocked, occ))
	p.attenuation_filter_db = lerpf(
		Settings.AUDIO_OCCLUSION_FILTER_OPEN_DB, Settings.AUDIO_OCCLUSION_FILTER_BLOCKED_DB, occ
	)
	var base_db: float = float(p.get_meta(_META_BASE_DB))
	p.volume_db = base_db + occ * Settings.AUDIO_OCCLUSION_VOLUME_DB


## The local listener. This project places no AudioListener3D, so the CURRENT camera is what
## the engine mixes 3D audio against — occlusion must use the exact same reference point.
func _listener() -> Camera3D:
	if not is_inside_tree():
		return null
	var cam := get_viewport().get_camera_3d()
	if cam == null or not cam.is_inside_tree():
		return null
	_cam = cam
	return cam


## -1.0 when no recent sample covers `pos` (callers treat that as "must cast").
func _cache_lookup(pos: Vector3) -> float:
	for s in _cache:
		if (s["pos"] as Vector3).distance_to(pos) <= _CACHE_RADIUS:
			return float(s["occ"])
	return -1.0


func _cache_store(pos: Vector3, occ: float) -> void:
	_cache.append({"pos": pos, "occ": occ, "t": _CACHE_TTL})
	if _cache.size() > _CACHE_MAX:
		_cache.remove_at(0)


func _expire_cache(delta: float) -> void:
	for i in range(_cache.size() - 1, -1, -1):
		var s: Dictionary = _cache[i]
		var left: float = float(s["t"]) - delta
		s["t"] = left
		if left <= 0.0:
			_cache.remove_at(i)
