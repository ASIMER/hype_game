class_name ProceduralTerrainPolish
extends RefCounted
## D3.5 "TERRAFORMING POLISH" — the GROUND finally shows wear, in three passes:
##   1. EROSION — down-slope wash gullies wherever the ground is steeper than
##      _SLOPE_MIN_DEG: the perimeter berm, the river banks, the steepest hill faces.
##      Oriented by the HEIGHT GRADIENT, never by a world axis — runoff does not know
##      which way +X points.
##   2. STREET WEAR — gravel/mud strips along the D3.4 street graph: a worn rut down the
##      middle of the lane, wash blotches on the shoulders.
##   3. FORD STONES — flat stepping slabs at the genuinely SHALLOW reach of the river.
##      The ONLY pass with geometry + collision, and therefore the only one that reaches
##      the navmesh input and the golden snapshot.
##
## THE RELIEF IS NOT TOUCHED — this is an EXPLICIT REFUSAL, not an omission. Cutting real
## ruts/gullies into `ProceduralTerrain.height_at` would move EVERY consumer of that
## function at once: building pads, tree/rock scatter, loot snapping, extraction pads,
## enemy spawn points, the street props and the stair flights that were fitted to the
## current ground. A P2 polish pass is not worth a re-seated building or a wedged
## staircase, so the wear is PAINTED (Decal) and the only thing that adds volume is the
## ford, which sits in water nothing else samples.
##
## RENDER-ONLY + PER-PEER COSMETIC for passes 1-2 (the ProceduralClimateZones /
## ProceduralGrimeDecals discipline):
##   - NO collision, NO nav impact, NO netcode; the decals live under the ARENA ROOT
##     ("TerrainWear"), never under NavigationRegion3D, so they cannot move the golden
##     determinism snapshot. Headless skips them.
##   - DETERMINISTIC via ProcHash + the pure terrain functions (no randf/randi/Time), so
##     every co-op peer paints the identical map.
##   - Every decal carries a distance fade (perf).
##
## PASS 3 IS GAMEPLAY, so it runs BEFORE the headless early-out and builds on a dedicated
## server too — one code path, so a server and a client can never disagree about where
## the stones stand. Its bodies live under NavigationRegion3D/FordStones because the
## runtime bake parses ONLY that subtree (Arena.tscn: geometry_parsed_geometry_type=1,
## geometry_collision_mask=1) — which is exactly why pass 3 BREAKS the golden snapshot.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

const EROSION_ENABLED := true
const STREET_WEAR_ENABLED := true
const FORD_STONES_ENABLED := true
const _BUDGET := 130  # hard map-wide cap on the PAINTED decals (passes 1+2)

# --- pass 1: slope erosion ---------------------------------------------------------
const _SLOPE_MIN_DEG := 22.0  # below this the ground reads as walkable meadow, not a slope
const _SLOPE_STEP := 10.0  # scan grid pitch (m) — 32x32 probes over the 320 m rectangle
const _SLOPE_PROBE := 1.6  # central-difference arm for the gradient (m)
const _SLOPE_BUDGET := 60
const _SLOPE_EDGE_INSET := 3.0  # stay off the very lip of the perimeter wall
const _SLOPE_WATER_CLEAR := 0.30  # a gully starts this far ABOVE the waterline, never under it
const _SLOPE_POI_CLEAR := 15.0  # skip the pad falloff ring (pad margin 6 + fall 8, +1)
const _SLOPE_ZONE_CLEAR := 19.0  # extraction pad: radius 10 + fall 8, +1
const _SLOPE_SPAWN_CLEAR := 26.0  # deploy pad: radius 16 + fall 9, +1
const _STREAK_W := Vector2(1.0, 2.1)  # gully width range (m)
const _STREAK_L := Vector2(4.2, 7.6)  # gully length range, down-slope (m)
const _SLOPE_FADE := Vector2(55.0, 18.0)  # (begin, length)

# --- pass 2: street wear -----------------------------------------------------------
## Stations are spaced so consecutive strips leave a GAP: a continuous ribbon would need
## every strip to seam-match its neighbour, and two alpha-faded ends overlapping compose
## to a lighter band, not a joint. Discrete worn patches read as a dirt track and dodge
## the whole problem.
const _ROAD_STEP := 11.5  # metres between strip stations along a street
const _ROAD_END := 9.0  # strips stop this far from a link end (the POI apron owns it)
## STATIONS, not decals: a station is one rut strip plus, _ROAD_WASH_CHANCE of the time, a
## shoulder blotch. 40 stations is therefore <= 65 decals, which with _SLOPE_BUDGET keeps
## the pair inside _BUDGET by construction.
const _ROAD_STATION_BUDGET := 40
const _ROAD_STRIP := Vector2(6.6, 8.8)  # rut strip length range (m)
const _ROAD_WIDTH := Vector2(2.6, 3.4)  # rut strip width range (m)
const _ROAD_POI_CLEAR := 5.0  # added to the footprint half-extents: the box must miss the wall
const _ROAD_RIVER_CLEAR := 1.5  # added to RIVER_CHANNEL_HALF — no gravel painted on water
const _ROAD_EDGE_INSET := 8.0
const _ROAD_WASH_CHANCE := 0.62  # of a station also getting a shoulder blotch
const _ROAD_WASH_OFF := Vector2(2.8, 4.6)  # shoulder offset from the lane centre (m)
const _ROAD_WASH_SIZE := Vector2(2.2, 4.0)
const _ROAD_FADE := Vector2(70.0, 22.0)  # roads read from far — they are the wayfinding cue
const _WASH_FADE := Vector2(45.0, 15.0)
const _PLAZA_SPAN := 22.0  # the plaza POI has w=d=0; treat it as this square (as D3.4 does)

# --- pass 3: ford stones -----------------------------------------------------------
## A "shallow place" is defined by MEASUREMENT, not by a hand-picked coordinate: the scan
## walks the river centreline and keeps the reaches where the water over the deepest point
## is at most _FORD_MAX_DEPTH. On the current river that is only the southern terminus,
## where ProceduralTerrain._river_depth_scale tapers the channel to half depth — which is
## the honest answer, and it will follow the terrain if the taper is ever retuned.
const _FORD_MAX_DEPTH := 1.35  # water depth at the crossing centre (m)
const _FORD_MIN_DEPTH := 0.35  # shallower than this you just walk across; stones would be litter
const _FORD_SCAN_STEP := 4.0  # metres of centreline between candidate sites
const _FORD_MAX_SITES := 2
const _FORD_SITE_SPACING := 40.0
const _FORD_PROP_CLEAR := 22.0  # from the existing bridge / stepping stones (read off the scene)
const _FORD_STONE_MIN_DEPTH := 0.10  # no stone on ground that is already all but dry
## How far the slab TOP breaks the water. Only this much of a stone is ever visible — the
## rest of its mass stands in the channel, which is exactly how a real stepping stone reads
## (a flat top at the waterline over a hidden block). Low enough that stepping on or off one
## is free, high enough to be seen before you are standing in it.
const _FORD_PROUD := 0.26
const _FORD_MIN_THICK := 0.4
const _FORD_MAX_THICK := 3.0  # guard: never grow a pillar if a site sits over deeper water
const _FORD_STONE_W := 1.35  # extent ACROSS the crossing (the step you take)
const _FORD_STONE_D := 1.7  # extent ALONG the flow (the slab lies with the current)
const _FORD_GAP := 0.9  # clear gap between neighbouring stones — see the navmesh note below
const _FORD_RING := 2  # stones each side of the centreline (row half-span = RING * pitch)
const _FORD_SCATTER := 2  # extra jittered boulders so the row is not three boxes in a line
const _FORD_STONE_COLOR := Color(0.47, 0.47, 0.49)  # the arch bridge's masonry, a hair wetter

# Painted-wear palette. Kept OFF the floor deliberately: the cold grade crushes anything
# under ~0.015 screen value, so "black" mud is charcoal-brown and reads as depth, not a hole.
const _MUD := Color(0.145, 0.128, 0.105)
const _GRAVEL := Color(0.33, 0.30, 0.25)
const _RUT := Color(0.19, 0.17, 0.14)
const _GROUND_LIFT := 0.35  # decal box centre above the surface, ALONG THE SURFACE NORMAL
const _GROUND_DEPTH := 1.6  # projection depth; the box hugs the slope, so this can be short

static var _erosion_img: ImageTexture = null
static var _rut_img: ImageTexture = null
static var _wash_img: ImageTexture = null


## Adds the painted-wear decals under `arena_root` ("TerrainWear") and the ford stones
## under NavigationRegion3D. Call AFTER the terrain + the D3.4 street props exist and
## BEFORE the navmesh bake.
static func build(arena_root: Node3D, poi_defs: Dictionary) -> void:
	if arena_root == null:
		return
	# GAMEPLAY FIRST: the ford is navmesh input, so a dedicated server must build it too.
	_fords(arena_root)
	if DisplayServer.get_name() == "headless":
		return
	var root := Node3D.new()
	root.name = "TerrainWear"
	arena_root.add_child(root)
	var ctx: Dictionary = _keepouts(arena_root, poi_defs)
	var count: int = 0
	count = _erosion(root, ctx, count)
	count = _street_wear(root, arena_root, ctx, poi_defs, count)
	if count > _BUDGET:
		push_warning("[TerrainPolish] decal budget exceeded: %d > %d" % [count, _BUDGET])


## Keep-outs derived from LIVE data — the POI defs the buildings were actually built from
## and the arena's own ExtractionZone/PlayerSpawnMarkers nodes — so nothing here can drift
## out of sync with a hand-copied list.
##
## `spawn` comes from ProceduralBuildingDetail._marker_centroid ON PURPOSE: it is the same
## function that fed the street graph when the props were placed, and the graph moves with
## it. Deriving the centroid independently here would eventually paint the lane markings
## down a different line than the props stand on.
static func _keepouts(arena_root: Node3D, poi_defs: Dictionary) -> Dictionary:
	var rects: Array[Vector4] = []  # (x, z, half-width, half-depth) — raw footprint
	for k in poi_defs.keys():
		var def: Dictionary = poi_defs[k]
		rects.append(
			Vector4(
				float(def["x"]),
				float(def["z"]),
				maxf(float(def["w"]), _PLAZA_SPAN) * 0.5,
				maxf(float(def["d"]), _PLAZA_SPAN) * 0.5
			)
		)
	var zones: Array[Vector2] = []
	for c in arena_root.get_children():
		if c is Node3D and str(c.name).begins_with("ExtractionZone"):
			var p: Vector3 = (c as Node3D).position
			zones.append(Vector2(p.x, p.z))
	return {
		"rects": rects,
		"zones": zones,
		"spawn": ProceduralBuildingDetail._marker_centroid(arena_root, "PlayerSpawnMarkers"),
	}


## True when (x,z) is inside a building footprint grown by `pad`, inside an extraction pad
## of `zone_r`, or inside the deploy pad of `spawn_r`. Zero radii disable a family.
static func _blocked(ctx: Dictionary, x: float, z: float, pad: float, zone_r: float) -> bool:
	var rects: Array[Vector4] = ctx["rects"]
	for r in rects:
		if absf(x - r.x) < r.z + pad and absf(z - r.y) < r.w + pad:
			return true
	if zone_r > 0.0:
		var zones: Array[Vector2] = ctx["zones"]
		for zc in zones:
			if Vector2(x - zc.x, z - zc.y).length_squared() < zone_r * zone_r:
				return true
	return false


# =========================================================== pass 1: slope erosion
## Scans the whole rectangle on a coarse grid, keeps the cells steeper than
## _SLOPE_MIN_DEG, then paints a gully on an EVENLY SPREAD subset of them.
##
## The two-phase shape is load-bearing: accepting cells as they are found would spend the
## whole budget on the first steep thing the row-major scan meets (the north-west corner
## of the perimeter berm) and leave the other three quadrants bare.
static func _erosion(root: Node3D, ctx: Dictionary, count: int) -> int:
	if not EROSION_ENABLED:
		return count
	var cands: Array[Vector4] = []  # (x, z, dh/dx, dh/dz)
	var min_grad: float = tan(deg_to_rad(_SLOPE_MIN_DEG))
	var x0: float = WorldBounds.X_MIN + _SLOPE_EDGE_INSET
	var z0: float = WorldBounds.Z_MIN + _SLOPE_EDGE_INSET
	var nx: int = int((WorldBounds.X_MAX - _SLOPE_EDGE_INSET - x0) / _SLOPE_STEP)
	var nz: int = int((WorldBounds.Z_MAX - _SLOPE_EDGE_INSET - z0) / _SLOPE_STEP)
	var spawn: Vector2 = ctx["spawn"]
	for iz in range(nz):
		for ix in range(nx):
			var s: int = ProcHash.h(51001 + iz * 733 + ix * 29)
			var x: float = x0 + (float(ix) + ProcHash.hrange(s, 0.15, 0.85)) * _SLOPE_STEP
			var z: float = z0 + (float(iz) + ProcHash.hrange(s + 1, 0.15, 0.85)) * _SLOPE_STEP
			# Cheapest tests first: the keep-outs are a handful of compares, the gradient is
			# four height_at samples, and this loop runs ~1000 times during the arena build —
			# the one phase that must not grow a long main-thread stall (it drops co-op
			# clients on load).
			if _blocked(ctx, x, z, _SLOPE_POI_CLEAR, _SLOPE_ZONE_CLEAR):
				continue
			if spawn.is_finite() and spawn.distance_to(Vector2(x, z)) < _SLOPE_SPAWN_CLEAR:
				continue
			var g: Vector2 = _gradient(x, z)
			if g.length() < min_grad:
				continue
			cands.append(Vector4(x, z, g.x, g.y))
	for i in range(cands.size()):
		if not _take(i, cands.size(), _SLOPE_BUDGET):
			continue
		if _streak(root, cands[i], ProcHash.h(52003 + i * 61)):
			count += 1
	return count


## Central-difference height gradient (dh/dx, dh/dz) at (x,z). Central rather than forward
## because this vector sets the DIRECTION the gully is drawn in, not just a pass/fail.
static func _gradient(x: float, z: float) -> Vector2:
	var p: float = _SLOPE_PROBE
	var gx: float = ProceduralTerrain.height_at(x + p, z) - ProceduralTerrain.height_at(x - p, z)
	var gz: float = ProceduralTerrain.height_at(x, z + p) - ProceduralTerrain.height_at(x, z - p)
	return Vector2(gx, gz) / (2.0 * p)


## One down-slope gully at candidate `c` = (x, z, dh/dx, dh/dz). False when the spot turns
## out to be under water (a wash streak on a riverbed is just a stain nobody sees).
static func _streak(root: Node3D, c: Vector4, s: int) -> bool:
	var x: float = c.x
	var z: float = c.y
	var h: float = ProceduralTerrain.height_at(x, z)
	var surf: float = ProceduralTerrain.water_surface_at(x, z)
	if not is_nan(surf) and h < surf + _SLOPE_WATER_CLEAR:
		return false
	# Steepest descent: the horizontal gradient points UPHILL, so runoff runs against it.
	var down: Vector2 = Vector2(-c.z, -c.w).normalized()
	var n: Vector3 = Vector3(-c.z, 1.0, -c.w).normalized()
	var fwd := Vector3(down.x, 0.0, down.y)
	var dec := _decal(
		_erosion_tex(),
		Vector3(
			ProcHash.hrange(s, _STREAK_W.x, _STREAK_W.y),
			_GROUND_DEPTH,
			ProcHash.hrange(s + 1, _STREAK_L.x, _STREAK_L.y)
		),
		_SLOPE_FADE
	)
	dec.transform = Transform3D(_surface_basis(n, fwd), Vector3(x, h, z) + n * _GROUND_LIFT)
	root.add_child(dec)
	return true


# ============================================================ pass 2: street wear
## Gravel/mud strips along the SAME street graph the D3.4 props stand on. The graph is not
## re-derived here — ProceduralBuildingDetail._street_links IS the graph, and calling it is
## what guarantees the paint and the props describe one road rather than two.
##
## Only `ctx["spawn"]` is read out of that lane's placement context, so the minimal dict
## below is a complete stand-in: passing its real _street_ctx would be actively WRONG,
## since that function FREES and re-creates the StreetProps node as a side effect.
static func _street_wear(
	root: Node3D, arena_root: Node3D, ctx: Dictionary, poi_defs: Dictionary, count: int
) -> int:
	if not STREET_WEAR_ENABLED:
		return count
	if arena_root.get_node_or_null("NavigationRegion3D") == null:
		return count
	var links: Array[Vector4] = ProceduralBuildingDetail._street_links(
		poi_defs, {"spawn": ctx["spawn"]}
	)
	var stations: Array[Vector4] = []  # (x, z, lane dir x, lane dir z)
	for li in range(links.size()):
		_stations(links[li], li, ctx, stations)
	for i in range(stations.size()):
		if not _take(i, stations.size(), _ROAD_STATION_BUDGET):
			continue
		count = _strip(root, stations[i], ProcHash.h(70001 + i * 89), count)
	return count


## Valid strip stations along one street: every ~_ROAD_STEP metres, minus the first/last
## _ROAD_END (that ground is the POI apron), minus anything over a building or the river.
static func _stations(link: Vector4, li: int, ctx: Dictionary, out: Array[Vector4]) -> void:
	var a := Vector2(link.x, link.y)
	var b := Vector2(link.z, link.w)
	var span: Vector2 = b - a
	var len_m: float = span.length()
	if len_m < _ROAD_END * 2.0 + _ROAD_STEP:
		return
	var dir: Vector2 = span / len_m
	for k in range(1, int(len_m / _ROAD_STEP) + 1):
		var s: int = ProcHash.h(71003 + li * 617 + k * 43)
		var t: float = (float(k) + ProcHash.hrange(s, -0.22, 0.22)) * _ROAD_STEP
		if t < _ROAD_END or t > len_m - _ROAD_END:
			continue
		var p: Vector2 = a + dir * t
		if not _road_spot_ok(ctx, p):
			continue
		out.append(Vector4(p.x, p.y, dir.x, dir.y))


static func _road_spot_ok(ctx: Dictionary, p: Vector2) -> bool:
	if (
		p.x < WorldBounds.X_MIN + _ROAD_EDGE_INSET
		or p.x > WorldBounds.X_MAX - _ROAD_EDGE_INSET
		or p.y < WorldBounds.Z_MIN + _ROAD_EDGE_INSET
		or p.y > WorldBounds.Z_MAX - _ROAD_EDGE_INSET
	):
		return false
	# The extraction pads are deliberately NOT excluded: an approach road running onto an
	# evac apron is exactly what should be there. Buildings are, because a 1.6 m-deep decal
	# box standing against a wall paints a gravel skirt up its bottom course.
	if _blocked(ctx, p.x, p.y, _ROAD_POI_CLEAR, 0.0):
		return false
	var river: float = ProceduralTerrain.river_distance(p.x, p.y)
	return river >= ProceduralTerrain.RIVER_CHANNEL_HALF + _ROAD_RIVER_CLEAR


## One station: the worn rut down the lane, plus a shoulder wash on one side.
static func _strip(root: Node3D, st: Vector4, s: int, count: int) -> int:
	var p := Vector2(st.x, st.y)
	var dir := Vector2(st.z, st.w)
	var lift: Vector3 = _place(p)
	var n := Vector3(lift.x, 1.0, lift.z).normalized()  # packed gradient, see _place
	var pos := Vector3(p.x, lift.y, p.y)
	var fwd := Vector3(dir.x, 0.0, dir.y)
	var dec := _decal(
		_rut_tex(),
		Vector3(
			ProcHash.hrange(s, _ROAD_WIDTH.x, _ROAD_WIDTH.y),
			_GROUND_DEPTH,
			ProcHash.hrange(s + 1, _ROAD_STRIP.x, _ROAD_STRIP.y)
		),
		_ROAD_FADE
	)
	dec.transform = Transform3D(_surface_basis(n, fwd), pos + n * _GROUND_LIFT)
	root.add_child(dec)
	count += 1
	if ProcHash.hf(s + 2) >= _ROAD_WASH_CHANCE:
		return count
	var side: float = 1.0 if ProcHash.h(s + 3) % 2 == 0 else -1.0
	var off: float = ProcHash.hrange(s + 4, _ROAD_WASH_OFF.x, _ROAD_WASH_OFF.y) * side
	var wp: Vector2 = p + Vector2(-dir.y, dir.x) * off
	var wl: Vector3 = _place(wp)
	var wn := Vector3(wl.x, 1.0, wl.z).normalized()
	var wash := _decal(
		_wash_tex(),
		Vector3(
			ProcHash.hrange(s + 5, _ROAD_WASH_SIZE.x, _ROAD_WASH_SIZE.y),
			_GROUND_DEPTH,
			ProcHash.hrange(s + 6, _ROAD_WASH_SIZE.x, _ROAD_WASH_SIZE.y)
		),
		_WASH_FADE
	)
	wash.transform = Transform3D(
		_surface_basis(wn, fwd), Vector3(wp.x, wl.y, wp.y) + wn * _GROUND_LIFT
	)
	root.add_child(wash)
	return count + 1


## Ground sample packed as (-dh/dx, height, -dh/dz) — i.e. the surface height plus the two
## components the caller needs to rebuild the normal, in ONE return value (a Dictionary per
## decal would allocate on a build-time hot path).
static func _place(p: Vector2) -> Vector3:
	var g: Vector2 = _gradient(p.x, p.y)
	return Vector3(-g.x, ProceduralTerrain.height_at(p.x, p.y), -g.y)


# ============================================================= pass 3: ford stones
## Flat stepping slabs across the shallow reach of the river.
##
## NOT A NEW CROSSING — at the depth this pass accepts (≤ _FORD_MAX_DEPTH) a player already
## wades over without submerging, so the stones only make a crossing that exists READABLE
## and dry-footed. That is also why they cannot unbalance the raid.
##
## NAVMESH: the row is deliberately SHORT along the flow (_FORD_STONE_D) and spans at most
## RING*(w+gap) each side of the centreline — a couple of metres of a channel corridor that
## is over ten metres wide — so it is an island cluster to path around, never a barrier
## across a lane (the D3.4 trap: a solid line laid ACROSS a route + agent_radius 0.6 closes
## it). Neither can it CONNECT the two banks: neighbouring stones keep a _FORD_GAP that the
## 0.6 m agent radius erodes shut, and every stone top stands the full water depth above the
## bed, which is far over agent_max_climb 0.5.
static func _fords(arena_root: Node3D) -> void:
	if not FORD_STONES_ENABLED:
		return
	var nav := arena_root.get_node_or_null("NavigationRegion3D") as Node3D
	if nav == null:
		return  # a preview/tool scene, never a real arena
	var sites: Array[Vector4] = _ford_sites(arena_root)
	if sites.is_empty():
		push_warning("[TerrainPolish] no ford site found — river never gets shallow enough")
		return
	var stale := nav.get_node_or_null("FordStones")
	if stale != null:
		stale.free()
	var root := Node3D.new()
	root.name = "FordStones"
	nav.add_child(root)
	for i in range(sites.size()):
		_ford(root, sites[i], i)


## Candidate crossings: walk the river centreline (RIVER_PTS is the very polyline
## _river_dist measures against, so a point on it IS the deepest line) and keep the reaches
## whose water is between _FORD_MIN_DEPTH and _FORD_MAX_DEPTH, spaced out and clear of the
## crossings the terrain already built. Returns (x, z, flow dir x, flow dir z).
static func _ford_sites(arena_root: Node3D) -> Array[Vector4]:
	var taken: Array[Vector2] = _river_prop_points(arena_root)
	var sites: Array[Vector4] = []
	var pts: Array[Vector2] = ProceduralTerrain.RIVER_PTS
	var carry: float = 0.0
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var seg: Vector2 = pts[i + 1] - a
		var seg_len: float = seg.length()
		if seg_len < 0.01:
			continue
		var dir: Vector2 = seg / seg_len
		var t: float = carry
		while t < seg_len:
			var p: Vector2 = a + dir * t
			t += _FORD_SCAN_STEP
			if sites.size() >= _FORD_MAX_SITES:
				break
			if not _ford_site_ok(p, sites, taken):
				continue
			sites.append(Vector4(p.x, p.y, dir.x, dir.y))
		carry = maxf(t - seg_len, 0.0)
	return sites


static func _ford_site_ok(p: Vector2, sites: Array[Vector4], taken: Array[Vector2]) -> bool:
	var depth: float = _water_depth(p.x, p.y)
	if depth < _FORD_MIN_DEPTH or depth > _FORD_MAX_DEPTH:
		return false
	for s in sites:
		if Vector2(s.x, s.y).distance_to(p) < _FORD_SITE_SPACING:
			return false
	for q in taken:
		if q.distance_to(p) < _FORD_PROP_CLEAR:
			return false
	return true


## Water above the bed at (x,z), or -1 where there is no channel (NAN off the river).
static func _water_depth(x: float, z: float) -> float:
	var surf: float = ProceduralTerrain.water_surface_at(x, z)
	if is_nan(surf):
		return -1.0
	return surf - ProceduralTerrain.height_at(x, z)


## XZ of everything the terrain already parked on the river (the stone arch bridge and its
## own stepping stones) — read off the LIVE scene rather than re-stating their coordinates,
## so a retuned bridge takes its keep-out with it.
static func _river_prop_points(arena_root: Node3D) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var rp := arena_root.get_node_or_null("NavigationRegion3D/ProceduralTerrain/RiverProps")
	if rp == null:
		rp = arena_root.find_child("RiverProps", true, false)
	if rp == null:
		return out
	for c in rp.get_children():
		var n3 := c as Node3D
		if n3 != null:
			out.append(Vector2(n3.position.x, n3.position.z))
	return out


## One ford: a row of slabs across the flow at `site` = (x, z, flow dir x, flow dir z),
## plus a couple of scattered boulders so it reads as a natural shallows rather than a
## dashed line. Each slab sits ON the bed and breaks _FORD_PROUD above the water.
static func _ford(root: Node3D, site: Vector4, idx: int) -> void:
	var mat: StandardMaterial3D = ProcMaterials.weathered(_FORD_STONE_COLOR, 0.0, 0.9, 0.6, 71)
	var c := Vector2(site.x, site.y)
	var flow := Vector2(site.z, site.w)
	var across := Vector2(-flow.y, flow.x)
	var yaw: float = rad_to_deg(atan2(flow.x, flow.y))
	var pitch: float = _FORD_STONE_W + _FORD_GAP
	var half_span: float = float(_FORD_RING) * pitch
	var n: int = 0
	for k in range(-_FORD_RING, _FORD_RING + 1):
		var s: int = ProcHash.h(83003 + idx * 271 + (k + _FORD_RING) * 37)
		var p: Vector2 = c + across * (float(k) * pitch)
		if _stone(root, p, yaw + ProcHash.hrange(s, -7.0, 7.0), mat, idx, n):
			n += 1
	for j in range(_FORD_SCATTER):
		var sj: int = ProcHash.h(84009 + idx * 331 + j * 53)
		# Kept INSIDE the row's own span so the clear bed either side of it stays clear.
		var off: Vector2 = across * ProcHash.hrange(sj, -half_span, half_span)
		var drift: Vector2 = flow * ProcHash.hrange(sj + 1, -2.4, 2.4)
		if _stone(root, c + off + drift, ProcHash.hf(sj + 2) * 360.0, mat, idx, n):
			n += 1


## One slab at `p`. False (and nothing built) where the bed is already all but dry — a
## stepping stone on a gravel bar is litter, not a crossing.
##
## The slab is seated on the DEEPEST bed under its own footprint, not on the bed at its
## centre: the channel walls run at ~33 deg, so a 1.35 m stone spans ~0.9 m of fall and a
## centre-seated box would hang its downhill half in the water. Burying the uphill corner
## instead is free — that half is inside the bank.
static func _stone(
	root: Node3D, p: Vector2, yaw: float, mat: StandardMaterial3D, idx: int, seq: int
) -> bool:
	if _water_depth(p.x, p.y) < _FORD_STONE_MIN_DEPTH:
		return false
	var s: int = ProcHash.h(85013 + idx * 197 + seq * 29)
	var w: float = _FORD_STONE_W * ProcHash.hrange(s, 0.86, 1.1)
	var d: float = _FORD_STONE_D * ProcHash.hrange(s + 1, 0.84, 1.12)
	var top: float = ProceduralTerrain.water_surface_at(p.x, p.y) + _FORD_PROUD
	var yr: float = deg_to_rad(yaw)
	var ax := Vector2(cos(yr), -sin(yr)) * (w * 0.5)  # local +X in world XZ
	var az := Vector2(sin(yr), cos(yr)) * (d * 0.5)  # local +Z in world XZ
	var bed: float = ProceduralTerrain.height_at(p.x, p.y)
	for e: Vector2 in [ax, -ax, az, -az]:
		bed = minf(bed, ProceduralTerrain.height_at(p.x + e.x, p.y + e.y))
	var thick: float = clampf(top - bed, _FORD_MIN_THICK, _FORD_MAX_THICK)
	var body: StaticBody3D = ProceduralBuildings._solid(
		root, Vector3(w, thick, d), mat, Vector3(p.x, top - thick * 0.5, p.y), yaw
	)
	# Explicit name: the golden checksum folds node names, and "@StaticBody3D@N" would make
	# this container unreadable in a diff (auto names fold as "@anon").
	body.name = "Ford%d_%d" % [idx, seq]
	return true


# ==================================================================== shared helpers
## Bresenham-even subset: true for EXACTLY `budget` of `total` indices, spread evenly over
## the scan order (which is spatial), so a cap thins the map instead of truncating it.
static func _take(i: int, total: int, budget: int) -> bool:
	if budget >= total:
		return true
	if budget <= 0 or total <= 0:
		return false
	return (i * budget) / total != ((i + 1) * budget) / total


## Basis that lays a ground decal ON the surface: local -Y (the projection axis) along the
## surface normal, local +Z along `fwd` re-projected into the tangent plane. Hugging the
## slope is what lets the projection box stay shallow — an axis-aligned box would have to
## be metres tall to cover a 7 m run down a 30 deg bank, and would then bleed onto every
## rock and wall standing inside it.
##
## The texture's V axis runs along local +Z (row 0 at -Z), which is why the gully art is
## painted top-of-image = uphill. No flip_x is needed the way the wall signage needs one:
## these textures are symmetric across the lane / the gully.
static func _surface_basis(n: Vector3, fwd: Vector3) -> Basis:
	var up: Vector3 = n.normalized()
	var z: Vector3 = fwd - up * fwd.dot(up)
	if z.length_squared() < 0.0001:
		z = up.cross(Vector3.RIGHT)
	z = z.normalized()
	return Basis(up.cross(z), up, z)


## Shared Decal factory: albedo + the distance fade every pass must carry.
static func _decal(tex: Texture2D, size: Vector3, fade: Vector2) -> Decal:
	var dec := Decal.new()
	dec.texture_albedo = tex
	dec.size = size
	dec.distance_fade_enabled = true
	dec.distance_fade_begin = fade.x
	dec.distance_fade_length = fade.y
	return dec


# ================================================================ generated textures
## 64x128 down-slope GULLY: a wandering dark channel with finer rills either side, alpha
## rising from the head (v=0, uphill) and dispersing toward the toe (v=1, downhill).
static func _erosion_tex() -> ImageTexture:
	if _erosion_img != null:
		return _erosion_img
	var w: int = 64
	var h: int = 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var lin: Color = _MUD.srgb_to_linear()
	for y in range(h):
		var v: float = float(y) / float(h - 1)
		# The channel MEANDERS: a straight dark bar reads as a painted line, a wandering
		# one reads as water that found its own way down.
		var mid: float = 0.5 + (_noise(v * 2.6, 0.5, 31) - 0.5) * 0.2
		var av: float = smoothstep(0.0, 0.2, v) * (1.0 - smoothstep(0.42, 1.0, v))
		for x in range(w):
			var u: float = float(x) / float(w - 1)
			var d: float = absf(u - mid) * 2.0
			# Channel falloff around the WANDERING centre, times a fixed border envelope: a
			# meander that drifts off-centre would otherwise still carry alpha at u=0/1 and
			# cut a dead-straight line along the edge of the decal box.
			var au: float = (
				(1.0 - smoothstep(0.3, 1.0, d)) * (1.0 - smoothstep(0.72, 1.0, absf(u - 0.5) * 2.0))
			)
			# Rills: fine parallel scratches beside the main channel.
			var rill: float = _noise(u * 22.0, v * 3.0, 57)
			var a: float = av * au * (0.62 + rill * 0.5)
			img.set_pixel(x, y, Color(lin.r, lin.g, lin.b, clampf(a * 0.55, 0.0, 1.0)))
	_erosion_img = ImageTexture.create_from_image(img)
	return _erosion_img


## 64x128 worn LANE strip: U runs across the road, V along it. Pale gravel body with two
## darker wheel ruts; alpha falls off at both shoulders and at both ends so a strip lands
## as a worn patch rather than a rectangle of paint.
static func _rut_tex() -> ImageTexture:
	if _rut_img != null:
		return _rut_img
	var w: int = 64
	var h: int = 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var body: Color = _GRAVEL.srgb_to_linear()
	var rut: Color = _RUT.srgb_to_linear()
	for y in range(h):
		var v: float = float(y) / float(h - 1)
		var av: float = smoothstep(0.0, 0.11, v) * (1.0 - smoothstep(0.89, 1.0, v))
		# Both ruts wander together — a vehicle track drifts, it is not two rails.
		var drift: float = (_noise(v * 3.4, 1.5, 73) - 0.5) * 0.13
		for x in range(w):
			var u: float = float(x) / float(w - 1)
			var au: float = 1.0 - smoothstep(0.62, 1.0, absf(u - 0.5) * 2.0)
			var wheel: float = minf(absf(u - (0.28 + drift)), absf(u - (0.72 + drift)))
			var deep: float = 1.0 - smoothstep(0.0, 0.09, wheel)
			var grit: float = _noise(u * 14.0, v * 26.0, 91)
			var a: float = av * au * (0.5 + grit * 0.34 + deep * 0.38)
			var col: Color = body.lerp(rut, deep)
			# 0.68, not 1.0: a rut that fully REPLACES the ground albedo reads as spilled tar
			# rather than as worn earth, and the whole point is that the ground shows through.
			img.set_pixel(x, y, Color(col.r, col.g, col.b, clampf(a * 0.68, 0.0, 1.0)))
	_rut_img = ImageTexture.create_from_image(img)
	return _rut_img


## 96x96 shoulder WASH: an irregular gravel/mud blotch (radial base cut by 2-octave value
## noise, the puddle recipe with a dry palette) for the edge of the roadway.
static func _wash_tex() -> ImageTexture:
	if _wash_img != null:
		return _wash_img
	var n: int = 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var pale: Color = _GRAVEL.srgb_to_linear()
	var dark: Color = _MUD.srgb_to_linear()
	for y in range(n):
		for x in range(n):
			var nx: float = float(x) / float(n - 1)
			var ny: float = float(y) / float(n - 1)
			var r: float = Vector2((nx - 0.5) * 2.0, (ny - 0.5) * 2.0).length()
			var blob: float = (
				_noise(nx * 4.0, ny * 4.0, 13) * 0.62 + _noise(nx * 9.0, ny * 9.0, 29) * 0.32
			)
			var a: float = clampf((0.8 - (r + (blob - 0.47) * 0.6)) * 3.4, 0.0, 1.0)
			var col: Color = pale.lerp(dark, clampf(blob * 1.2, 0.0, 1.0))
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a * 0.5))
	_wash_img = ImageTexture.create_from_image(img)
	return _wash_img


## Deterministic smoothed value noise in [0,1). REUSES the grime-decal lattice instead of
## carrying a fourth copy of the same eight lines — a duplicated noise helper is exactly
## the "edit one, the other drifts" trap docs/AUDIT.md F1 removed. It is a pure static, so
## a rename over there fails LOUDLY at import rather than silently changing this art.
static func _noise(x: float, y: float, sid: int) -> float:
	return ProceduralGrimeDecals._vnoise(x, y, sid)
