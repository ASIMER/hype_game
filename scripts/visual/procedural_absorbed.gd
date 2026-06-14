class_name ProceduralAbsorbed
extends RefCounted
## The visual side of the ABSORPTION mechanic: a deterministic trophy CLUSTER of absorbed
## enemy parts welded onto the player's back, plus the single-part nodes the homing streak FX
## reuses. Every enemy archetype donates a recognizable signature part (Settings.ABSORB_PARTS):
## spider→legs, oni→horn, scarab→shell, … capped PER TYPE (the user's "max 8 spider legs").
##
## Built from `absorbed` ({enemy_id: count}) — the owner-authoritative replicated dict — and a
## STABLE seed (the peer id), with an LCG (no randf/Time) and SORTED-key iteration, so every
## co-op peer rebuilds the byte-identical cluster (same discipline as ProceduralModels.scar_parts).
## Parts are faintly emissive in the enemy's signature colour (the "one hot accent" look). The
## body faces -Z, so the back is +Z — the cluster sits on the upper back where the centered
## behind-the-back camera frames it. Render-only.

const _MODELS := preload("res://scripts/visual/procedural_models.gd")


# --- primitive shorthands (mirror ProceduralPlayer) --------------------------
static func _p(
	root: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	off := Vector3.ZERO,
	rot := Vector3.ZERO,
	scl := Vector3.ONE
) -> MeshInstance3D:
	return _MODELS._part(root, mesh, mat, off, rot, scl)


static func _box(s: Vector3) -> BoxMesh:
	return _MODELS._box(s)


static func _cyl(r: float, h: float, seg := 8) -> CylinderMesh:
	return _MODELS._cyl(r, h, seg)


static func _cone(r: float, h: float, seg := 6) -> CylinderMesh:
	return _MODELS._cone(r, h, seg)


static func _sph(r: float, hemi := false) -> SphereMesh:
	return _MODELS._sphere(r, hemi)


## A saturated, strongly-emissive material in the part's signature colour so the parts GLOW (the
## "absorbed energy" read) and bloom past the glow HDR threshold even under the cold grade.
static func _pmat(color: Color) -> StandardMaterial3D:
	return _MODELS._mat(color.lightened(0.15), 0.3, 0.35, color, 5.5)


# --- one signature part (shared by the cluster + the homing streak) ----------
## Build a single signature part (the shape extends +Y from its local origin). `token` is the
## part id from Settings.ABSORB_PARTS; `color` is its signature tint.
static func build_part_node(token: String, color: Color) -> Node3D:
	var n := Node3D.new()
	n.name = "Part"
	var m := _pmat(color)
	match token:
		"horn":
			_p(n, _cone(0.055, 0.34, 6), m, Vector3(0, 0.17, 0))
		"spike":
			_p(n, _cone(0.05, 0.26, 6), m, Vector3(0, 0.13, 0))
		"fin":
			_p(
				n,
				_cone(0.07, 0.30, 5),
				m,
				Vector3(0, 0.15, 0),
				Vector3.ZERO,
				Vector3(0.5, 1.0, 1.0)
			)
		"blade":
			_p(n, _box(Vector3(0.05, 0.30, 0.15)), m, Vector3(0, 0.15, 0))
		"claw":
			_p(n, _cyl(0.035, 0.24, 6), m, Vector3(0, 0.12, 0))
			_p(n, _cone(0.04, 0.12, 5), m, Vector3(0.03, 0.27, 0), Vector3(0, 0, -35))
		"fist":
			_p(n, _box(Vector3(0.19, 0.17, 0.19)), m, Vector3(0, 0.10, 0))
			_p(n, _box(Vector3(0.20, 0.05, 0.05)), m, Vector3(0, 0.18, 0))
		"shell":
			_p(n, _sph(0.17, true), m, Vector3(0, 0.03, 0), Vector3.ZERO, Vector3(1.1, 0.7, 1.3))
		"rotor":
			_p(n, _cyl(0.17, 0.03, 12), m, Vector3(0, 0.12, 0))
			_p(n, _box(Vector3(0.34, 0.035, 0.05)), m, Vector3(0, 0.12, 0))
			_p(n, _box(Vector3(0.05, 0.035, 0.34)), m, Vector3(0, 0.12, 0))
		"antenna":
			_p(n, _cyl(0.013, 0.34, 5), m, Vector3(0, 0.17, 0))
			_p(n, _sph(0.035), _pmat(color.lightened(0.3)), Vector3(0, 0.35, 0))
		"barrel":
			_p(n, _cyl(0.07, 0.26, 8), m, Vector3(0, 0.13, 0))
		"vane":
			_p(n, _box(Vector3(0.06, 0.26, 0.17)), m, Vector3(0, 0.13, 0), Vector3(0, 0, 18))
		"maw":
			_p(n, _cyl(0.16, 0.09, 10), m, Vector3(0, 0.07, 0))
			for k in 4:
				var a: float = float(k) / 4.0 * TAU
				_p(n, _cone(0.03, 0.10, 4), m, Vector3(cos(a) * 0.13, 0.16, sin(a) * 0.13))
		_:  # "scrap" + any unmapped id
			_p(n, _box(Vector3(0.16, 0.12, 0.13)), m, Vector3(0, 0.08, 0), Vector3(12, 20, 8))
			_p(
				n,
				_box(Vector3(0.10, 0.14, 0.09)),
				m,
				Vector3(0.06, 0.18, 0.02),
				Vector3(-18, 5, 22)
			)
	return n


# --- the back cluster --------------------------------------------------------
## Flatten `absorbed` to a capped, SORTED list of part defs (deterministic order across peers).
static func _flatten(absorbed: Dictionary) -> Array:
	var keys: Array = absorbed.keys()
	keys.sort()
	var parts: Array = []
	for eid in keys:
		var def: Dictionary = Settings.ABSORB_PARTS.get(eid, Settings.ABSORB_FALLBACK)
		var n: int = mini(int(absorbed[eid]), int(def["cap"]))
		for _i in n:
			parts.append(def)
			if parts.size() >= Settings.ABSORB_CLUSTER_MAX:
				return parts
	return parts


## Build the "AbsorbCluster" node: every absorbed part fanned across the upper back, climbing a
## new row every 6, splayed outward (legs/fins "leg out"). Deterministic in `seed_val` (peer id).
static func build_absorbed_cluster(absorbed: Dictionary, seed_val: int) -> Node3D:
	var root := Node3D.new()
	root.name = "AbsorbCluster"
	var parts: Array = _flatten(absorbed)
	var total: int = parts.size()
	if total == 0:
		return root
	# Bigger so the glowing trophy reads from behind; shrink a touch as the haul grows (tidy).
	var pscale: float = clampf(1.0 - 0.012 * float(total), 0.7, 1.0) * 1.3
	var s: int = absi(seed_val)
	for i in total:
		var def: Dictionary = parts[i]
		s = (s * 1103515245 + 12345) & 0x7fffffff  # LCG — deterministic, no Math.random
		var jitter: float = float(s % 1000) / 1000.0 - 0.5
		var row: int = i / 6
		var col: int = i % 6
		var ang: float = -0.75 + 1.5 * (float(col) / 5.0) + jitter * 0.12
		var y: float = 1.18 + float(row) * 0.20 + jitter * 0.04
		var node := build_part_node(String(def["part"]), def["color"])
		node.position = Vector3(sin(ang) * 0.30, y, 0.18 + cos(ang) * 0.06)
		node.scale = Vector3.ONE * pscale
		node.rotation_degrees = Vector3(
			-28.0 + float(row) * 6.0, rad_to_deg(ang) * 0.6, sin(ang) * 32.0
		)
		root.add_child(node)
	return root
