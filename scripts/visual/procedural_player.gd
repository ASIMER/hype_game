class_name ProceduralPlayer
extends RefCounted
## The PLAYER as a procedural modular robot (same system as the enemies in
## ProceduralModels), so head / torso / arms / legs are INDEPENDENT swappable parts the
## character-customization constructor can mix + match, plus a PAINT colour scheme.
##
## Reuses ProceduralModels' static mesh helpers (_box/_sphere/_cyl/_cone/_strut/_part/_mat)
## and ProcMaterials.weathered. The assembled body is a single Node3D the PlayerAnimator
## bobs/leans as a rigid whole (the player has no skeleton — pure procedural anim).
##
## Body coordinate frame: feet at local y=0, ~1.8 m tall, facing -Z. Anchors:
##   legs 0..0.82 · pelvis ~0.86 · chest ~1.16 · shoulders ~1.37 · head ~1.6.
## The catalog (CATEGORIES/VARIANTS) is the FROZEN interface the UI + netcode build
## against; every variant id listed here resolves to a builder (unimplemented ids fall
## back to that category's default so the game is always runnable).

const CATEGORIES := ["head", "torso", "arms", "legs", "paint"]

# Per category: ordered list of { id, name, cost }. cost 0 = free starter (equipped by
# default); others are currency-locked. IDS ARE FROZEN — UI/netcode key off them.
const VARIANTS := {
	"head":
	[
		{"id": "head_dome", "name": "Dome", "cost": 0},
		{"id": "head_visor", "name": "Visor", "cost": 0},
		{"id": "head_antenna", "name": "Antenna", "cost": 120},
		{"id": "head_cyclops", "name": "Cyclops", "cost": 120},
		{"id": "head_horned", "name": "Horned", "cost": 150},
		{"id": "head_crest", "name": "Crest", "cost": 150},
		{"id": "head_hood", "name": "Hooded", "cost": 180},
		{"id": "head_mohawk", "name": "Fin", "cost": 180},
		{"id": "head_riot", "name": "Riot", "cost": 220},
		{"id": "head_oni", "name": "Oni", "cost": 260},
	],
	"torso":
	[
		{"id": "torso_plated", "name": "Plated", "cost": 0},
		{"id": "torso_light", "name": "Light", "cost": 0},
		{"id": "torso_heavy", "name": "Heavy", "cost": 140},
		{"id": "torso_rig", "name": "Tac Rig", "cost": 140},
		{"id": "torso_reactor", "name": "Reactor", "cost": 160},
		{"id": "torso_riot", "name": "Riot", "cost": 180},
		{"id": "torso_recon", "name": "Recon", "cost": 160},
		{"id": "torso_exo", "name": "Exo-Frame", "cost": 220},
		{"id": "torso_trench", "name": "Trench", "cost": 180},
		{"id": "torso_jugg", "name": "Juggernaut", "cost": 280},
	],
	"arms":
	[
		{"id": "arms_standard", "name": "Standard", "cost": 0},
		{"id": "arms_light", "name": "Light", "cost": 0},
		{"id": "arms_bulky", "name": "Bulky", "cost": 120},
		{"id": "arms_servo", "name": "Servo", "cost": 120},
		{"id": "arms_pauldron", "name": "Pauldron", "cost": 150},
		{"id": "arms_blade", "name": "Blade", "cost": 160},
		{"id": "arms_gauntlet", "name": "Gauntlet", "cost": 160},
		{"id": "arms_piston", "name": "Piston", "cost": 180},
		{"id": "arms_shield", "name": "Bracer", "cost": 200},
		{"id": "arms_claw", "name": "Claw", "cost": 220},
	],
	"legs":
	[
		{"id": "legs_standard", "name": "Standard", "cost": 0},
		{"id": "legs_light", "name": "Light", "cost": 0},
		{"id": "legs_heavy", "name": "Heavy", "cost": 120},
		{"id": "legs_digi", "name": "Digitigrade", "cost": 140},
		{"id": "legs_boots", "name": "Boots", "cost": 120},
		{"id": "legs_thruster", "name": "Thruster", "cost": 160},
		{"id": "legs_armored", "name": "Armored", "cost": 160},
		{"id": "legs_runner", "name": "Runner", "cost": 140},
		{"id": "legs_tank", "name": "Tread", "cost": 220},
		{"id": "legs_greaves", "name": "Greaves", "cost": 180},
	],
	"paint":
	[
		{"id": "paint_raider", "name": "Raider", "cost": 0},
		{"id": "paint_ash", "name": "Ash", "cost": 0},
		{"id": "paint_crimson", "name": "Crimson", "cost": 100},
		{"id": "paint_forest", "name": "Forest", "cost": 100},
		{"id": "paint_arctic", "name": "Arctic", "cost": 120},
		{"id": "paint_void", "name": "Void", "cost": 140},
		{"id": "paint_toxic", "name": "Toxic", "cost": 140},
		{"id": "paint_gold", "name": "Gilded", "cost": 160},
		{"id": "paint_ember", "name": "Ember", "cost": 160},
		{"id": "paint_royal", "name": "Royal", "cost": 180},
		# Quest-exclusive paints (cost = -1 = NOT for sale; granted only by quest rewards).
		{"id": "paint_foreman", "name": "Foreman's Mark", "cost": -1},
		{"id": "paint_salvage", "name": "Salvager", "cost": -1},
		{"id": "paint_ghost", "name": "Ghost", "cost": -1},
		{"id": "paint_warden", "name": "Warden's End", "cost": -1},
	],
}

# Colour schemes: primary armour, secondary trim, accent (emissive glow).
# D2: every `primary` carries a perceptual lift (v**0.72) over the values this catalog
# shipped with. Once the machine roster went two-tone (light plate over black frame), the
# PLAYER became the darkest object in frame — a raider who reads as a silhouette while the
# things hunting them read as painted metal. The lift keeps each scheme's hue and their
# relative ordering (void and ghost are still the dark ones, arctic still the bright one),
# it just pulls the whole set off the floor. `secondary` stays dark on purpose: it is the
# frame half of the same two-tone. `accent` is identity and is not touched.
const PAINTS := {
	"paint_raider":
	{
		"primary": Color(0.420, 0.517, 0.624),
		"secondary": Color(0.18, 0.23, 0.30),
		"accent": Color(0.25, 0.80, 0.85)
	},
	"paint_ash":
	{
		"primary": Color(0.535, 0.554, 0.581),
		"secondary": Color(0.22, 0.23, 0.25),
		"accent": Color(0.90, 0.55, 0.20)
	},
	"paint_crimson":
	{
		"primary": Color(0.650, 0.255, 0.255),
		"secondary": Color(0.16, 0.10, 0.10),
		"accent": Color(1.00, 0.55, 0.20)
	},
	"paint_forest":
	{
		"primary": Color(0.420, 0.517, 0.336),
		"secondary": Color(0.20, 0.17, 0.10),
		"accent": Color(0.75, 0.85, 0.30)
	},
	"paint_arctic":
	{
		"primary": Color(0.836, 0.882, 0.927),
		"secondary": Color(0.35, 0.42, 0.50),
		"accent": Color(0.35, 0.75, 1.00)
	},
	"paint_void":
	{
		"primary": Color(0.230, 0.230, 0.279),
		"secondary": Color(0.07, 0.07, 0.09),
		"accent": Color(0.70, 0.35, 1.00)
	},
	"paint_toxic":
	{
		"primary": Color(0.314, 0.379, 0.291),
		"secondary": Color(0.12, 0.14, 0.10),
		"accent": Color(0.55, 1.00, 0.25)
	},
	"paint_gold":
	{
		"primary": Color(0.789, 0.676, 0.336),
		"secondary": Color(0.25, 0.20, 0.10),
		"accent": Color(1.00, 0.85, 0.40)
	},
	"paint_ember":
	{
		"primary": Color(0.400, 0.314, 0.314),
		"secondary": Color(0.14, 0.10, 0.10),
		"accent": Color(1.00, 0.40, 0.15)
	},
	"paint_royal":
	{
		"primary": Color(0.400, 0.336, 0.563),
		"secondary": Color(0.14, 0.11, 0.22),
		"accent": Color(0.55, 0.65, 1.00)
	},
	"paint_foreman":
	{
		# Quest-exclusive schemes.
		"primary": Color(0.479, 0.390, 0.230),
		"secondary": Color(0.18, 0.14, 0.08),
		"accent": Color(1.00, 0.72, 0.22)
	},
	"paint_salvage":
	{
		"primary": Color(0.314, 0.460, 0.479),
		"secondary": Color(0.10, 0.17, 0.18),
		"accent": Color(0.30, 0.95, 0.85)
	},
	"paint_ghost":
	{
		"primary": Color(0.267, 0.291, 0.336),
		"secondary": Color(0.08, 0.09, 0.11),
		"accent": Color(0.60, 0.95, 0.75)
	},
	"paint_warden":
	{
		"primary": Color(0.191, 0.191, 0.217),
		"secondary": Color(0.05, 0.05, 0.06),
		"accent": Color(1.00, 0.25, 0.30)
	},
}

const DEFAULT_PAINT := "paint_raider"


# ── Catalog API ─────────────────────────────────────────────────────────────
## The free starter look (every cost-0 first entry per category) — equipped by default.
static func defaults() -> Dictionary:
	return {
		"head": "head_dome",
		"torso": "torso_plated",
		"arms": "arms_standard",
		"legs": "legs_standard",
		"paint": "paint_raider"
	}


static func variants_of(category: String) -> Array:
	return VARIANTS.get(category, [])


static func category_of(variant_id: String) -> String:
	for cat in CATEGORIES:
		for v in VARIANTS[cat]:
			if String(v["id"]) == variant_id:
				return cat
	return ""


static func cost_of(variant_id: String) -> int:
	var cat := category_of(variant_id)
	if cat == "":
		return 0
	for v in VARIANTS[cat]:
		if String(v["id"]) == variant_id:
			return int(v["cost"])
	return 0


static func name_of(variant_id: String) -> String:
	var cat := category_of(variant_id)
	if cat == "":
		return variant_id
	for v in VARIANTS[cat]:
		if String(v["id"]) == variant_id:
			return String(v["name"])
	return variant_id


## Fill any missing/invalid category with its free default so the body always builds.
static func _with_defaults(cosmetics: Dictionary) -> Dictionary:
	var out := defaults()
	for cat in CATEGORIES:
		var picked: String = String(cosmetics.get(cat, ""))
		if picked != "" and category_of(picked) == cat:
			out[cat] = picked
	return out


# ── Materials from a paint scheme ───────────────────────────────────────────
static func _paint_of(paint_id: String) -> Dictionary:
	return PAINTS.get(paint_id, PAINTS[DEFAULT_PAINT])


static func _mats(paint: Dictionary) -> Dictionary:
	var primary: Color = paint["primary"]
	var secondary: Color = paint["secondary"]
	var accent: Color = paint["accent"]
	return {
		"armor": ProcPlating.armor_plate(primary, 7, Vector3(0.9, 0.9, 0.9)),
		"trim": ProcPlating.lacquer(secondary, 9),
		"metal": ProcPlating.steel(),
		"dark": ProcPlating.rubber(Color(0.12, 0.13, 0.15), 5),
		"suit": ProcPlating.rubber(secondary.lerp(Color(0.13, 0.14, 0.16), 0.6), 13),
		"accent": ProcPlating.glow(accent, 3.5),
	}


# ── Assembly ────────────────────────────────────────────────────────────────
## Build the full player body from a cosmetics dict {head,torso,arms,legs,paint}.
static func build_player(cosmetics: Dictionary) -> Node3D:
	var cos := _with_defaults(cosmetics)
	var mats := _mats(_paint_of(String(cos["paint"])))
	var root := Node3D.new()
	root.name = "PlayerBody"
	_build_legs(root, String(cos["legs"]), mats)
	_build_torso(root, String(cos["torso"]), mats)
	_build_arms(root, String(cos["arms"]), mats)
	_build_head(root, String(cos["head"]), mats)
	return root


## Build a single part in isolation (for the constructor's variant thumbnails). For
## "paint" there's no single part — return the whole body in that scheme.
static func build_part(category: String, variant_id: String, paint_id: String) -> Node3D:
	if category == "paint":
		return build_player({"paint": variant_id})
	var mats := _mats(_paint_of(paint_id))
	var root := Node3D.new()
	root.name = "Part_" + variant_id
	match category:
		"head":
			_build_head(root, variant_id, mats)
		"torso":
			_build_torso(root, variant_id, mats)
		"arms":
			_build_arms(root, variant_id, mats)
		"legs":
			_build_legs(root, variant_id, mats)
	return root


# Shorthand to keep the builders readable.
static func _p(
	root: Node3D,
	mesh: Mesh,
	mat: StandardMaterial3D,
	off: Vector3,
	rot := Vector3.ZERO,
	scl := Vector3.ONE
) -> MeshInstance3D:
	return ProceduralModels._part(root, mesh, mat, off, rot, scl)


static func _box(s: Vector3) -> BoxMesh:
	return ProceduralModels._box(s)


static func _sph(r: float, hemi := false, ri := 8, ra := 12) -> SphereMesh:
	return ProceduralModels._sphere(r, hemi, ri, ra)


static func _cyl(r: float, h: float, seg := 10) -> CylinderMesh:
	return ProceduralModels._cyl(r, h, seg)


static func _cone(r: float, h: float, seg := 10) -> CylinderMesh:
	return ProceduralModels._cone(r, h, seg)


static func _strut(
	root: Node3D, a: Vector3, b: Vector3, r: float, mat: StandardMaterial3D
) -> MeshInstance3D:
	return ProceduralModels._strut(root, a, b, r, mat)


# ── LEGS ────────────────────────────────────────────────────────────────────
static func _build_legs(root: Node3D, variant: String, m: Dictionary) -> void:
	match variant:
		"legs_standard":
			_legs_standard(root, m)
		"legs_light":
			_legs_light(root, m)
		"legs_heavy":
			_legs_heavy(root, m)
		"legs_digi":
			_legs_digi(root, m)
		"legs_boots":
			_legs_boots(root, m)
		"legs_thruster":
			_legs_thruster(root, m)
		"legs_armored":
			_legs_armored(root, m)
		"legs_runner":
			_legs_runner(root, m)
		"legs_tank":
			_legs_tank(root, m)
		"legs_greaves":
			_legs_greaves(root, m)
		_:
			_legs_standard(root, m)


# legs_standard — tubular humanoid, cylinder thigh+shin, flat boot.
static func _legs_standard(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_p(root, _cyl(0.12, 0.42, 10), m.armor, Vector3(x, 0.6, 0.0))
		_p(root, _sph(0.11, false, 8, 10), m.metal, Vector3(x, 0.4, 0.0))
		_p(root, _cyl(0.095, 0.38, 10), m.armor, Vector3(x, 0.2, 0.01))
		_p(root, _box(Vector3(0.17, 0.11, 0.30)), m.dark, Vector3(x, 0.05, 0.04))


# legs_light — slender strut legs, exposed ball joints, thin pointed toe.
static func _legs_light(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.16
		_strut(root, Vector3(x, 0.82, 0.0), Vector3(x, 0.42, 0.0), 0.055, m.armor)
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x, 0.42, 0.0))
		_strut(root, Vector3(x, 0.42, 0.0), Vector3(x, 0.1, 0.0), 0.045, m.armor)
		_p(root, _sph(0.055, false, 6, 8), m.metal, Vector3(x, 0.1, 0.0))
		_p(root, _box(Vector3(0.08, 0.06, 0.24)), m.trim, Vector3(x, 0.04, 0.06))  # slim pointed boot


# legs_heavy — wide armored slab thighs, knee plate, heavy flat boot.
static func _legs_heavy(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.18
		_p(root, _box(Vector3(0.26, 0.4, 0.26)), m.armor, Vector3(x, 0.62, 0.0))
		_p(root, _box(Vector3(0.28, 0.1, 0.30)), m.trim, Vector3(x, 0.46, 0.02))  # knee plate
		_p(root, _box(Vector3(0.22, 0.36, 0.24)), m.armor, Vector3(x, 0.22, 0.01))
		_p(root, _box(Vector3(0.22, 0.14, 0.38)), m.dark, Vector3(x, 0.06, 0.06))
		_p(root, _box(Vector3(0.24, 0.05, 0.4)), m.trim, Vector3(x, 0.12, 0.06))


# legs_digi — reverse-jointed digitigrade sprinter.
static func _legs_digi(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_strut(root, Vector3(x, 0.82, 0.0), Vector3(x, 0.5, 0.14), 0.08, m.armor)
		_p(root, _sph(0.1, false, 8, 10), m.metal, Vector3(x, 0.5, 0.14))
		_strut(root, Vector3(x, 0.5, 0.14), Vector3(x, 0.16, -0.04), 0.06, m.armor)
		_p(root, _sph(0.07, false, 6, 8), m.metal, Vector3(x, 0.16, -0.04))
		_strut(root, Vector3(x, 0.16, -0.04), Vector3(x, 0.03, 0.16), 0.05, m.dark)
		_p(root, _box(Vector3(0.1, 0.06, 0.18)), m.dark, Vector3(x, 0.03, 0.14))


# legs_boots — sturdy humanoid leg with a tall reinforced combat boot.
static func _legs_boots(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_p(root, _cyl(0.11, 0.40, 10), m.armor, Vector3(x, 0.60, 0.0))
		_p(root, _sph(0.10, false, 8, 10), m.metal, Vector3(x, 0.40, 0.0))
		_p(root, _cyl(0.10, 0.34, 10), m.armor, Vector3(x, 0.22, 0.0))
		# tall boot cuff
		_p(root, _cyl(0.115, 0.22, 10), m.trim, Vector3(x, 0.10, 0.0))
		_p(root, _box(Vector3(0.18, 0.10, 0.34)), m.dark, Vector3(x, 0.05, 0.06))
		_p(root, _box(Vector3(0.20, 0.04, 0.36)), m.trim, Vector3(x, 0.12, 0.06))  # boot sole band


# legs_thruster — standard shin + glowing jet nozzle pods on the calves.
static func _legs_thruster(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_p(root, _cyl(0.11, 0.40, 10), m.armor, Vector3(x, 0.60, 0.0))
		_p(root, _sph(0.10, false, 8, 10), m.metal, Vector3(x, 0.40, 0.0))
		_p(root, _cyl(0.09, 0.34, 10), m.armor, Vector3(x, 0.22, 0.0))
		# thruster nozzle pod on rear calf
		_p(root, _box(Vector3(0.14, 0.20, 0.10)), m.metal, Vector3(x, 0.24, 0.10))
		_p(root, _cyl(0.05, 0.10, 8), m.accent, Vector3(x, 0.18, 0.14), Vector3(80, 0, 0))
		_p(root, _cyl(0.035, 0.06, 8), m.dark, Vector3(x, 0.14, 0.16), Vector3(80, 0, 0))
		_p(root, _box(Vector3(0.14, 0.09, 0.26)), m.dark, Vector3(x, 0.05, 0.04))


# legs_armored — full-plate legs with side skirt panels and toe guards.
static func _legs_armored(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.18
		_p(root, _box(Vector3(0.24, 0.38, 0.24)), m.armor, Vector3(x, 0.62, 0.0))
		# thigh side-skirt
		_p(root, _box(Vector3(0.06, 0.24, 0.20)), m.trim, Vector3(x + sx * 0.15, 0.60, 0.0))
		_p(root, _box(Vector3(0.26, 0.08, 0.28)), m.trim, Vector3(x, 0.44, 0.02))  # knee guard
		_p(root, _box(Vector3(0.20, 0.34, 0.22)), m.armor, Vector3(x, 0.22, 0.01))
		# shin front plate
		_p(root, _box(Vector3(0.18, 0.28, 0.06)), m.metal, Vector3(x, 0.24, -0.12))
		_p(root, _box(Vector3(0.20, 0.12, 0.36)), m.dark, Vector3(x, 0.05, 0.05))
		_p(root, _box(Vector3(0.18, 0.06, 0.10)), m.trim, Vector3(x, 0.10, -0.13))  # toe guard


# legs_runner — long strut sprinter legs, wide knee disc, canted heel spur.
static func _legs_runner(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_strut(root, Vector3(x, 0.82, -0.04), Vector3(x, 0.46, 0.04), 0.075, m.armor)
		# wide knee disc
		_p(root, _cyl(0.13, 0.04, 12), m.trim, Vector3(x, 0.46, 0.04), Vector3(90, 0, 0))
		_p(root, _sph(0.08, false, 6, 8), m.metal, Vector3(x, 0.46, 0.04))
		_strut(root, Vector3(x, 0.46, 0.04), Vector3(x, 0.14, 0.0), 0.055, m.armor)
		# heel spur
		_p(root, _box(Vector3(0.06, 0.16, 0.06)), m.trim, Vector3(x, 0.22, 0.13))
		_p(root, _box(Vector3(0.13, 0.07, 0.28)), m.dark, Vector3(x, 0.04, 0.05))


# legs_tank — tread/wheel feet: blocky shin blocks + visible wheel disc at ankle.
static func _legs_tank(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.18
		_p(root, _box(Vector3(0.25, 0.38, 0.25)), m.armor, Vector3(x, 0.62, 0.0))
		_p(root, _box(Vector3(0.27, 0.08, 0.30)), m.trim, Vector3(x, 0.46, 0.02))
		_p(root, _box(Vector3(0.22, 0.32, 0.22)), m.armor, Vector3(x, 0.24, 0.0))
		# ankle wheel/tread disc
		_p(root, _cyl(0.16, 0.10, 12), m.metal, Vector3(x, 0.12, 0.0), Vector3(0, 0, 90))
		_p(root, _cyl(0.10, 0.12, 12), m.dark, Vector3(x, 0.12, 0.0), Vector3(0, 0, 90))
		# tread block foot
		_p(root, _box(Vector3(0.26, 0.06, 0.36)), m.dark, Vector3(x, 0.03, 0.04))
		_p(root, _box(Vector3(0.24, 0.04, 0.36)), m.trim, Vector3(x, 0.08, 0.04))


# legs_greaves — humanoid with thick front-facing greave plates + ankle ring.
static func _legs_greaves(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.17
		_p(root, _cyl(0.11, 0.40, 10), m.armor, Vector3(x, 0.60, 0.0))
		_p(root, _sph(0.10, false, 8, 10), m.metal, Vector3(x, 0.40, 0.0))
		_p(root, _cyl(0.095, 0.34, 10), m.armor, Vector3(x, 0.22, 0.01))
		# front greave plate
		_p(root, _box(Vector3(0.18, 0.30, 0.06)), m.trim, Vector3(x, 0.24, -0.11))
		_p(root, _box(Vector3(0.16, 0.04, 0.08)), m.accent, Vector3(x, 0.12, -0.12))  # greave glow strip
		# ankle band
		_p(root, _cyl(0.12, 0.05, 10), m.trim, Vector3(x, 0.10, 0.0))
		_p(root, _box(Vector3(0.16, 0.10, 0.28)), m.dark, Vector3(x, 0.05, 0.04))


# ── TORSO ───────────────────────────────────────────────────────────────────
static func _build_torso(root: Node3D, variant: String, m: Dictionary) -> void:
	match variant:
		"torso_plated":
			_torso_plated(root, m)
		"torso_light":
			_torso_light(root, m)
		"torso_heavy":
			_torso_heavy(root, m)
		"torso_rig":
			_torso_rig(root, m)
		"torso_reactor":
			_torso_reactor(root, m)
		"torso_riot":
			_torso_riot(root, m)
		"torso_recon":
			_torso_recon(root, m)
		"torso_exo":
			_torso_exo(root, m)
		"torso_trench":
			_torso_trench(root, m)
		"torso_jugg":
			_torso_jugg(root, m)
		_:
			_torso_plated(root, m)


static func _torso_core(root: Node3D, m: Dictionary) -> void:
	# pelvis + collar shared by most torsos.
	_p(root, _box(Vector3(0.40, 0.22, 0.26)), m.metal, Vector3(0.0, 0.92, 0.0))
	_p(root, _box(Vector3(0.30, 0.10, 0.26)), m.trim, Vector3(0.0, 1.44, 0.0))


# torso_plated — standard medium plating, round chest core emitter.
static func _torso_plated(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.48, 0.52, 0.30)), m.armor, Vector3(0.0, 1.18, 0.0))
	_p(root, _box(Vector3(0.5, 0.14, 0.32)), m.trim, Vector3(0.0, 1.36, 0.0))
	var core := _p(root, _sph(0.06, false, 8, 10), m.accent, Vector3(0.0, 1.2, -0.17))
	core.name = "Core"
	for sx: float in [-1.0, 1.0]:
		_p(
			root,
			_sph(0.15, true, 8, 10),
			m.armor,
			Vector3(sx * 0.3, 1.38, 0.0),
			Vector3.ZERO,
			Vector3(1.0, 0.7, 1.0)
		)


# torso_light — slim cylinder torso, vest panel, small core.
static func _torso_light(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _cyl(0.21, 0.5, 12), m.armor, Vector3(0.0, 1.17, 0.0))
	_p(root, _box(Vector3(0.36, 0.18, 0.24)), m.trim, Vector3(0.0, 1.3, -0.05))
	var core := _p(root, _sph(0.05, false, 8, 10), m.accent, Vector3(0.0, 1.22, -0.16))
	core.name = "Core"


# torso_heavy — wide slab torso, thick collar, big pauldron bumps.
static func _torso_heavy(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.58, 0.56, 0.38)), m.armor, Vector3(0.0, 1.18, 0.0))
	_p(root, _box(Vector3(0.62, 0.16, 0.4)), m.trim, Vector3(0.0, 1.34, 0.0))
	_p(root, _box(Vector3(0.3, 0.3, 0.06)), m.metal, Vector3(0.0, 1.18, -0.2))
	var core := _p(root, _sph(0.07, false, 8, 10), m.accent, Vector3(0.0, 1.18, -0.23))
	core.name = "Core"
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.22, 0.24, 0.34)), m.armor, Vector3(sx * 0.38, 1.4, 0.0))


# torso_rig — plated base + tactical pouches + chest straps.
static func _torso_rig(root: Node3D, m: Dictionary) -> void:
	_torso_plated(root, m)
	_p(root, _box(Vector3(0.5, 0.05, 0.06)), m.dark, Vector3(0.0, 1.28, -0.16), Vector3(0, 0, 18))
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.12, 0.14, 0.1)), m.dark, Vector3(sx * 0.14, 1.02, -0.16))
		_p(root, _box(Vector3(0.12, 0.05, 0.1)), m.trim, Vector3(sx * 0.14, 1.07, -0.18))


# torso_reactor — glowing reactor ring on chest.
static func _torso_reactor(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.46, 0.5, 0.3)), m.armor, Vector3(0.0, 1.18, 0.0))
	_p(root, _cyl(0.13, 0.06, 16), m.metal, Vector3(0.0, 1.2, -0.16), Vector3(90, 0, 0))
	var core := _p(
		root, _cyl(0.09, 0.08, 16), m.accent, Vector3(0.0, 1.2, -0.18), Vector3(90, 0, 0)
	)
	core.name = "Core"
	for sx: float in [-1.0, 1.0]:
		_p(
			root,
			_sph(0.14, true, 8, 10),
			m.armor,
			Vector3(sx * 0.3, 1.38, 0.0),
			Vector3.ZERO,
			Vector3(1.0, 0.7, 1.0)
		)


# torso_riot — wide slab + front riot-shield breastplate + two side reinforcement bars.
static func _torso_riot(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.52, 0.54, 0.32)), m.armor, Vector3(0.0, 1.18, 0.0))
	# large flat breastplate bolted on front
	_p(root, _box(Vector3(0.38, 0.44, 0.06)), m.trim, Vector3(0.0, 1.18, -0.18))
	_p(root, _box(Vector3(0.36, 0.04, 0.08)), m.accent, Vector3(0.0, 1.38, -0.18))  # visor slit glow
	# side reinforcement bars
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.04, 0.44, 0.30)), m.metal, Vector3(sx * 0.27, 1.18, 0.0))
	var core := _p(root, _sph(0.05, false, 8, 10), m.accent, Vector3(0.0, 1.10, -0.22))
	core.name = "Core"


# torso_recon — slim cylinder torso + backpack sensor pod + shoulder antenna nub.
static func _torso_recon(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _cyl(0.20, 0.48, 12), m.armor, Vector3(0.0, 1.17, 0.0))
	_p(root, _box(Vector3(0.32, 0.16, 0.22)), m.trim, Vector3(0.0, 1.28, -0.04))
	var core := _p(root, _sph(0.045, false, 8, 10), m.accent, Vector3(0.0, 1.22, -0.15))
	core.name = "Core"
	# backpack sensor pod
	_p(root, _box(Vector3(0.20, 0.26, 0.12)), m.dark, Vector3(0.0, 1.22, 0.18))
	_p(root, _sph(0.05, false, 6, 8), m.accent, Vector3(0.0, 1.32, 0.24))  # sensor lens
	# shoulder antenna nub
	_p(root, _cyl(0.012, 0.18, 6), m.metal, Vector3(0.22, 1.44, 0.0))
	_p(root, _sph(0.02, false, 4, 6), m.accent, Vector3(0.22, 1.53, 0.0))


# torso_exo — heavy box torso with exposed exo-skeleton rib struts.
static func _torso_exo(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.54, 0.52, 0.34)), m.armor, Vector3(0.0, 1.18, 0.0))
	_p(root, _box(Vector3(0.58, 0.14, 0.36)), m.trim, Vector3(0.0, 1.36, 0.0))
	# exposed exo ribs on the sides
	for i: int in range(3):
		var ry: float = 1.06 + float(i) * 0.12
		for sx: float in [-1.0, 1.0]:
			_p(root, _box(Vector3(0.06, 0.06, 0.32)), m.metal, Vector3(sx * 0.30, ry, 0.0))
	var core := _p(root, _sph(0.06, false, 8, 10), m.accent, Vector3(0.0, 1.18, -0.19))
	core.name = "Core"
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.20, 0.22, 0.30)), m.armor, Vector3(sx * 0.38, 1.40, 0.0))


# torso_trench — narrow torso with long coat-skirt flaps and high collar.
static func _torso_trench(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _cyl(0.22, 0.50, 12), m.armor, Vector3(0.0, 1.17, 0.0))
	# high collar guard
	_p(root, _cyl(0.17, 0.12, 10), m.trim, Vector3(0.0, 1.44, 0.0))
	_p(root, _box(Vector3(0.32, 0.16, 0.24)), m.trim, Vector3(0.0, 1.30, -0.04))
	var core := _p(root, _sph(0.05, false, 8, 10), m.accent, Vector3(0.0, 1.22, -0.16))
	core.name = "Core"
	# coat-skirt flap panels hanging from pelvis
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.14, 0.28, 0.08)), m.armor, Vector3(sx * 0.20, 0.72, -0.04))
	_p(root, _box(Vector3(0.20, 0.24, 0.08)), m.trim, Vector3(0.0, 0.72, -0.12))  # front flap


# torso_jugg — massive fortress torso, double-layered slab armor + shoulder domes.
static func _torso_jugg(root: Node3D, m: Dictionary) -> void:
	_torso_core(root, m)
	_p(root, _box(Vector3(0.64, 0.58, 0.42)), m.armor, Vector3(0.0, 1.18, 0.0))
	_p(root, _box(Vector3(0.68, 0.18, 0.44)), m.trim, Vector3(0.0, 1.34, 0.0))
	# secondary over-plate
	_p(root, _box(Vector3(0.42, 0.44, 0.08)), m.metal, Vector3(0.0, 1.18, -0.22))
	_p(root, _box(Vector3(0.38, 0.06, 0.10)), m.accent, Vector3(0.0, 1.38, -0.22))  # chest glow bar
	var core := _p(root, _sph(0.08, false, 8, 10), m.accent, Vector3(0.0, 1.18, -0.26))
	core.name = "Core"
	# massive shoulder domes
	for sx: float in [-1.0, 1.0]:
		_p(
			root,
			_sph(0.20, true, 8, 10),
			m.armor,
			Vector3(sx * 0.40, 1.40, 0.0),
			Vector3.ZERO,
			Vector3(1.0, 0.8, 1.0)
		)
		_p(root, _box(Vector3(0.06, 0.40, 0.08)), m.metal, Vector3(sx * 0.34, 1.16, -0.20))  # side rib


# ── ARMS ────────────────────────────────────────────────────────────────────
static func _build_arms(root: Node3D, variant: String, m: Dictionary) -> void:
	match variant:
		"arms_standard":
			_arms_standard(root, m)
		"arms_light":
			_arms_light(root, m)
		"arms_bulky":
			_arms_bulky(root, m)
		"arms_servo":
			_arms_servo(root, m)
		"arms_pauldron":
			_arms_pauldron(root, m)
		"arms_blade":
			_arms_blade(root, m)
		"arms_gauntlet":
			_arms_gauntlet(root, m)
		"arms_piston":
			_arms_piston(root, m)
		"arms_shield":
			_arms_shield(root, m)
		"arms_claw":
			_arms_claw(root, m)
		_:
			_arms_standard(root, m)


# arms_standard — tube upper+lower arm, ball shoulder+elbow, box hand.
static func _arms_standard(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.32
		_p(root, _sph(0.12, false, 8, 10), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x * 1.05, 1.05, 0.02), 0.07, m.armor)
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x * 1.05, 1.05, 0.02))
		_strut(root, Vector3(x * 1.05, 1.05, 0.02), Vector3(x * 1.05, 0.78, 0.06), 0.06, m.armor)
		_p(root, _box(Vector3(0.1, 0.12, 0.12)), m.dark, Vector3(x * 1.05, 0.72, 0.06))


# arms_light — thin strut arms, no pauldron, open joint spheres, minimal hand nub.
static func _arms_light(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.30
		_p(root, _sph(0.09, false, 6, 8), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x * 1.04, 1.06, 0.01), 0.045, m.armor)
		_p(root, _sph(0.055, false, 6, 8), m.metal, Vector3(x * 1.04, 1.06, 0.01))
		_strut(root, Vector3(x * 1.04, 1.06, 0.01), Vector3(x * 1.04, 0.80, 0.04), 0.040, m.armor)
		_p(root, _box(Vector3(0.07, 0.09, 0.09)), m.dark, Vector3(x * 1.04, 0.74, 0.04))


# arms_bulky — thick slab upper arm, wide gauntlet forearm, big shoulder.
static func _arms_bulky(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.34
		_p(root, _sph(0.18, true, 8, 10), m.armor, Vector3(x, 1.4, 0.0))
		_p(root, _box(Vector3(0.18, 0.3, 0.2)), m.armor, Vector3(x * 1.05, 1.12, 0.02))
		_p(root, _sph(0.09, false, 6, 8), m.metal, Vector3(x * 1.05, 0.96, 0.02))
		_p(root, _box(Vector3(0.17, 0.28, 0.18)), m.armor, Vector3(x * 1.05, 0.78, 0.05))
		_p(root, _box(Vector3(0.14, 0.14, 0.16)), m.dark, Vector3(x * 1.05, 0.62, 0.06))


# arms_servo — exposed servo rod, glowing piston actuator.
static func _arms_servo(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.31
		_p(root, _sph(0.1, false, 8, 10), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x, 1.05, 0.02), 0.05, m.metal)
		_p(root, _cyl(0.04, 0.18, 8), m.accent, Vector3(x, 1.18, 0.04), Vector3(70, 0, 0))
		_p(root, _sph(0.06, false, 6, 8), m.metal, Vector3(x, 1.05, 0.02))
		_strut(root, Vector3(x, 1.05, 0.02), Vector3(x, 0.78, 0.06), 0.045, m.armor)
		_p(root, _box(Vector3(0.09, 0.11, 0.11)), m.dark, Vector3(x, 0.72, 0.06))


# arms_pauldron — standard arm + wide angular pauldron plate with trim edge.
static func _arms_pauldron(root: Node3D, m: Dictionary) -> void:
	_arms_standard(root, m)
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.34
		_p(root, _box(Vector3(0.2, 0.16, 0.26)), m.trim, Vector3(x, 1.44, 0.0))
		_p(root, _box(Vector3(0.2, 0.04, 0.26)), m.accent, Vector3(x, 1.52, 0.0))


# arms_blade — standard arm + a flat forearm blade on the underside.
static func _arms_blade(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.32
		_p(root, _sph(0.12, false, 8, 10), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x * 1.05, 1.05, 0.02), 0.07, m.armor)
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x * 1.05, 1.05, 0.02))
		_strut(root, Vector3(x * 1.05, 1.05, 0.02), Vector3(x * 1.05, 0.78, 0.06), 0.06, m.armor)
		_p(root, _box(Vector3(0.10, 0.12, 0.12)), m.dark, Vector3(x * 1.05, 0.72, 0.06))
		# forearm blade: thin flat fin extending past the hand
		_p(root, _box(Vector3(0.04, 0.28, 0.06)), m.trim, Vector3(x * 1.05, 0.82, -0.06))
		_p(root, _cone(0.03, 0.12, 6), m.accent, Vector3(x * 1.05, 0.58, -0.06), Vector3(0, 0, 0))


# arms_gauntlet — bulky arm with a ridged oversized gauntlet fist (knuckle bars).
static func _arms_gauntlet(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.33
		_p(root, _sph(0.15, true, 8, 10), m.armor, Vector3(x, 1.38, 0.0))
		_p(root, _box(Vector3(0.17, 0.28, 0.19)), m.armor, Vector3(x * 1.05, 1.12, 0.02))
		_p(root, _sph(0.09, false, 6, 8), m.metal, Vector3(x * 1.05, 0.96, 0.02))
		_p(root, _box(Vector3(0.18, 0.26, 0.20)), m.armor, Vector3(x * 1.05, 0.78, 0.04))
		# knuckle bar ridges
		for i: int in range(3):
			_p(
				root,
				_box(Vector3(0.19, 0.035, 0.06)),
				m.trim,
				Vector3(x * 1.05, 0.90 - float(i) * 0.08, -0.09)
			)
		_p(root, _box(Vector3(0.16, 0.12, 0.18)), m.dark, Vector3(x * 1.05, 0.62, 0.06))


# arms_piston — servo frame + two visible hydraulic pistons on upper arm.
static func _arms_piston(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.32
		_p(root, _sph(0.12, false, 8, 10), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x * 1.05, 1.06, 0.02), 0.06, m.metal)
		# twin hydraulic pistons beside the upper arm
		_p(
			root,
			_cyl(0.03, 0.22, 8),
			m.metal,
			Vector3(x * 1.05 + sx * 0.03, 1.20, 0.04),
			Vector3(10, 0, 0)
		)
		_p(
			root,
			_cyl(0.025, 0.14, 8),
			m.accent,
			Vector3(x * 1.05 + sx * 0.03, 1.10, 0.05),
			Vector3(10, 0, 0)
		)
		_p(
			root,
			_cyl(0.03, 0.22, 8),
			m.metal,
			Vector3(x * 1.05 - sx * 0.03, 1.20, 0.04),
			Vector3(10, 0, 0)
		)
		_p(
			root,
			_cyl(0.025, 0.14, 8),
			m.accent,
			Vector3(x * 1.05 - sx * 0.03, 1.10, 0.05),
			Vector3(10, 0, 0)
		)
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x * 1.05, 1.06, 0.02))
		_strut(root, Vector3(x * 1.05, 1.06, 0.02), Vector3(x * 1.05, 0.78, 0.06), 0.055, m.armor)
		_p(root, _box(Vector3(0.10, 0.12, 0.12)), m.dark, Vector3(x * 1.05, 0.72, 0.06))


# arms_shield — standard upper arm + wide flat bracer shield on the forearm.
static func _arms_shield(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.32
		_p(root, _sph(0.12, false, 8, 10), m.metal, Vector3(x, 1.36, 0.0))
		_strut(root, Vector3(x, 1.34, 0.0), Vector3(x * 1.05, 1.05, 0.02), 0.07, m.armor)
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x * 1.05, 1.05, 0.02))
		_strut(root, Vector3(x * 1.05, 1.05, 0.02), Vector3(x * 1.05, 0.78, 0.06), 0.06, m.armor)
		# wide bracer shield on forearm
		_p(root, _box(Vector3(0.22, 0.24, 0.07)), m.trim, Vector3(x * 1.05, 0.88, -0.06))
		_p(root, _box(Vector3(0.20, 0.04, 0.08)), m.accent, Vector3(x * 1.05, 0.98, -0.07))  # top edge glow
		_p(root, _box(Vector3(0.10, 0.12, 0.12)), m.dark, Vector3(x * 1.05, 0.72, 0.06))


# arms_claw — bulky arm ending in a 3-prong gripper claw hand.
static func _arms_claw(root: Node3D, m: Dictionary) -> void:
	for sx: float in [-1.0, 1.0]:
		var x: float = sx * 0.34
		_p(root, _sph(0.16, true, 8, 10), m.armor, Vector3(x, 1.40, 0.0))
		_p(root, _box(Vector3(0.17, 0.28, 0.19)), m.armor, Vector3(x * 1.05, 1.12, 0.02))
		_p(root, _sph(0.09, false, 6, 8), m.metal, Vector3(x * 1.05, 0.96, 0.02))
		_p(root, _box(Vector3(0.15, 0.24, 0.16)), m.armor, Vector3(x * 1.05, 0.78, 0.04))
		# claw palm hub
		_p(root, _sph(0.075, false, 6, 8), m.metal, Vector3(x * 1.05, 0.64, 0.05))
		# 3-prong claw fingers: center, upper-offset, lower-offset
		_p(root, _cone(0.028, 0.14, 6), m.trim, Vector3(x * 1.05, 0.62, -0.02), Vector3(-90, 0, 0))
		_p(
			root,
			_cone(0.025, 0.11, 6),
			m.trim,
			Vector3(x * 1.05 + sx * 0.05, 0.65, -0.02),
			Vector3(-80, 0, sx * 15)
		)
		_p(
			root,
			_cone(0.025, 0.11, 6),
			m.trim,
			Vector3(x * 1.05 - sx * 0.05, 0.65, -0.02),
			Vector3(-80, 0, sx * -15)
		)
		_p(root, _sph(0.03, false, 4, 6), m.accent, Vector3(x * 1.05, 0.64, -0.04))  # claw tip glow


# ── HEAD ────────────────────────────────────────────────────────────────────
static func _build_head(root: Node3D, variant: String, m: Dictionary) -> void:
	# Shared neck.
	_p(root, _cyl(0.075, 0.08, 8), m.metal, Vector3(0.0, 1.5, 0.0))
	match variant:
		"head_dome":
			_head_dome(root, m)
		"head_visor":
			_head_visor(root, m)
		"head_antenna":
			_head_antenna(root, m)
		"head_cyclops":
			_head_cyclops(root, m)
		"head_horned":
			_head_horned(root, m)
		"head_crest":
			_head_crest(root, m)
		"head_hood":
			_head_hood(root, m)
		"head_mohawk":
			_head_mohawk(root, m)
		"head_riot":
			_head_riot(root, m)
		"head_oni":
			_head_oni(root, m)
		_:
			_head_dome(root, m)


# head_dome — smooth sphere helm, single wide visor slit.
static func _head_dome(root: Node3D, m: Dictionary) -> void:
	_p(
		root,
		_sph(0.17, false, 10, 12),
		m.armor,
		Vector3(0.0, 1.62, 0.0),
		Vector3.ZERO,
		Vector3(1.0, 1.1, 1.0)
	)
	var eye := _p(root, _box(Vector3(0.24, 0.05, 0.04)), m.accent, Vector3(0.0, 1.62, -0.15))
	eye.name = "Eye"


# head_visor — angular boxy helm, wide flat brow trim, bold visor panel.
static func _head_visor(root: Node3D, m: Dictionary) -> void:
	_p(root, _box(Vector3(0.3, 0.28, 0.3)), m.armor, Vector3(0.0, 1.63, 0.0))
	_p(root, _box(Vector3(0.26, 0.04, 0.32)), m.trim, Vector3(0.0, 1.74, 0.0))
	var eye := _p(root, _box(Vector3(0.28, 0.09, 0.06)), m.accent, Vector3(0.0, 1.62, -0.14))
	eye.name = "Eye"


# head_antenna — dome base with side comm box + tall off-center antenna + tip light.
static func _head_antenna(root: Node3D, m: Dictionary) -> void:
	_p(
		root,
		_sph(0.17, false, 10, 12),
		m.armor,
		Vector3(0.0, 1.62, 0.0),
		Vector3.ZERO,
		Vector3(1.0, 1.1, 1.0)
	)
	var eye := _p(root, _box(Vector3(0.24, 0.05, 0.04)), m.accent, Vector3(0.0, 1.62, -0.15))
	eye.name = "Eye"
	_p(root, _cyl(0.015, 0.34, 6), m.metal, Vector3(0.1, 1.86, 0.0))
	_p(root, _sph(0.03, false, 6, 8), m.accent, Vector3(0.1, 2.04, 0.0))
	_p(root, _box(Vector3(0.06, 0.06, 0.04)), m.dark, Vector3(-0.15, 1.66, -0.02))


# head_cyclops — round dome + recessed single-eye camera barrel.
static func _head_cyclops(root: Node3D, m: Dictionary) -> void:
	_p(root, _sph(0.17, false, 10, 12), m.armor, Vector3(0.0, 1.62, 0.0))
	_p(root, _cyl(0.09, 0.05, 14), m.metal, Vector3(0.0, 1.63, -0.13), Vector3(90, 0, 0))
	var eye := _p(root, _sph(0.06, false, 8, 10), m.accent, Vector3(0.0, 1.63, -0.16))
	eye.name = "Eye"


# head_horned — round dome + two swept horns angling outward.
static func _head_horned(root: Node3D, m: Dictionary) -> void:
	_p(
		root,
		_sph(0.17, false, 10, 12),
		m.armor,
		Vector3(0.0, 1.62, 0.0),
		Vector3.ZERO,
		Vector3(1.0, 1.05, 1.0)
	)
	var eye := _p(root, _box(Vector3(0.26, 0.06, 0.04)), m.accent, Vector3(0.0, 1.62, -0.15))
	eye.name = "Eye"
	for sx: float in [-1.0, 1.0]:
		_p(
			root,
			_cone(0.045, 0.22),
			m.trim,
			Vector3(sx * 0.12, 1.78, 0.02),
			Vector3(-20, 0, sx * 30)
		)


# head_crest — boxy visor base + tall central crest fin running front to back.
static func _head_crest(root: Node3D, m: Dictionary) -> void:
	_p(root, _box(Vector3(0.28, 0.26, 0.30)), m.armor, Vector3(0.0, 1.63, 0.0))
	_p(root, _box(Vector3(0.24, 0.04, 0.28)), m.trim, Vector3(0.0, 1.72, 0.0))
	var eye := _p(root, _box(Vector3(0.26, 0.07, 0.06)), m.accent, Vector3(0.0, 1.62, -0.14))
	eye.name = "Eye"
	# tall central fin crest
	_p(root, _box(Vector3(0.04, 0.22, 0.26)), m.trim, Vector3(0.0, 1.82, 0.0))
	_p(root, _box(Vector3(0.02, 0.06, 0.24)), m.accent, Vector3(0.0, 1.92, 0.0))  # crest glow edge


# head_hood — dark inner skull + broad armored hood cowl.
static func _head_hood(root: Node3D, m: Dictionary) -> void:
	_p(root, _sph(0.15, false, 10, 12), m.dark, Vector3(0.0, 1.6, 0.02))
	_p(
		root,
		_sph(0.2, true, 10, 12),
		m.armor,
		Vector3(0.0, 1.66, 0.04),
		Vector3(10, 0, 0),
		Vector3(1.1, 1.0, 1.2)
	)
	var eye := _p(root, _box(Vector3(0.2, 0.04, 0.04)), m.accent, Vector3(0.0, 1.6, -0.12))
	eye.name = "Eye"


# head_mohawk — flat angular box head + tall narrow fin blade on top.
static func _head_mohawk(root: Node3D, m: Dictionary) -> void:
	_p(root, _box(Vector3(0.28, 0.26, 0.28)), m.armor, Vector3(0.0, 1.63, 0.0))
	_p(root, _box(Vector3(0.22, 0.04, 0.24)), m.metal, Vector3(0.0, 1.72, 0.0))
	var eye := _p(root, _box(Vector3(0.26, 0.06, 0.06)), m.accent, Vector3(0.0, 1.62, -0.13))
	eye.name = "Eye"
	# tall narrow fin — runs fore-aft like a mohawk
	_p(root, _box(Vector3(0.03, 0.30, 0.22)), m.trim, Vector3(0.0, 1.86, 0.0))
	_p(root, _box(Vector3(0.015, 0.08, 0.18)), m.accent, Vector3(0.0, 2.00, 0.0))  # fin tip glow


# head_riot — full tactical riot visor helm: flat box + heavy brow + visor cage bars.
static func _head_riot(root: Node3D, m: Dictionary) -> void:
	_p(root, _box(Vector3(0.32, 0.30, 0.32)), m.armor, Vector3(0.0, 1.63, 0.0))
	_p(root, _box(Vector3(0.34, 0.06, 0.34)), m.trim, Vector3(0.0, 1.76, 0.0))  # heavy brow
	_p(root, _box(Vector3(0.34, 0.06, 0.08)), m.metal, Vector3(0.0, 1.48, -0.15))  # chin guard
	var eye := _p(root, _box(Vector3(0.30, 0.10, 0.06)), m.accent, Vector3(0.0, 1.63, -0.15))
	eye.name = "Eye"
	# visor cage bars
	for i: int in range(3):
		_p(
			root,
			_box(Vector3(0.30, 0.015, 0.05)),
			m.metal,
			Vector3(0.0, 1.57 + float(i) * 0.05, -0.16)
		)


# head_oni — demon-mask head: wide angular face, swept cheek flanges, wide glowing mouth slit + horns.
static func _head_oni(root: Node3D, m: Dictionary) -> void:
	# Wide, slightly flattened head
	_p(root, _box(Vector3(0.34, 0.28, 0.28)), m.armor, Vector3(0.0, 1.63, 0.0))
	_p(root, _box(Vector3(0.32, 0.04, 0.28)), m.trim, Vector3(0.0, 1.74, 0.0))
	# Swept cheek flanges
	for sx: float in [-1.0, 1.0]:
		_p(root, _box(Vector3(0.06, 0.18, 0.20)), m.metal, Vector3(sx * 0.19, 1.60, 0.0))
		# small brow spike
		_p(
			root,
			_cone(0.03, 0.10, 6),
			m.trim,
			Vector3(sx * 0.12, 1.77, -0.04),
			Vector3(-15, 0, sx * 20)
		)
	# Eyes — two small separate orbs
	for sx: float in [-1.0, 1.0]:
		var eyex: float = sx * 0.09
		var eye := _p(root, _sph(0.035, false, 6, 8), m.accent, Vector3(eyex, 1.66, -0.14))
		eye.name = "Eye"
	# Wide glowing mouth slit
	_p(root, _box(Vector3(0.26, 0.04, 0.04)), m.accent, Vector3(0.0, 1.54, -0.14))
	# Teeth bar (dark notches implied by a darker sub-box)
	_p(root, _box(Vector3(0.22, 0.02, 0.04)), m.dark, Vector3(0.0, 1.55, -0.15))
