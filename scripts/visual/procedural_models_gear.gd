class_name ProceduralModelsGear
extends RefCounted
## Procedural models for the batch B/C gear + consumables (annex keys, the signal
## flare, medicine, worn armor). Split from procedural_models.gd purely for size
## discipline (that file sits at the gdlint max-file-lines ceiling); reuses ITS
## static mesh/material/placement helpers (no copy-paste — the AUDIT F1 rule).
## Dispatched via ProceduralModels.build()/has_builder (GEAR_BUILDERS), so
## AssetRegistry.get_model — and therefore IconRenderer's icon prewarm AND world
## loot drops — pick these up automatically.

const KEY_COLORS := {
	"key_tower": Color(0.85, 0.7, 0.3),  # amber-steel (urban NW landmark)
	"key_lodge": Color(0.55, 0.8, 0.95),  # ice-blue (alpine lodge)
	"key_temple": Color(0.9, 0.35, 0.25),  # vermilion (temple)
}


static func build(id: String) -> Node3D:
	match id:
		"key_tower", "key_lodge", "key_temple":
			return _key(KEY_COLORS[id])
		"loot_flare":
			return _flare()
		"loot_bandage":
			return _bandage()
		"loot_splint":
			return _splint()
		"loot_painkiller":
			return _painkiller()
		"armor_helmet_t1":
			return _helmet(false)
		"armor_helmet_t2":
			return _helmet(true)
		"armor_vest_t1":
			return _vest(false)
		"armor_vest_t2":
			return _vest(true)
		"armor_pack_med":
			return _pack(false)
		"armor_pack_large":
			return _pack(true)
	return null


## A chunky keycard: body + dark grip band + an emissive tag stripe in the landmark
## color + two cut teeth so it still reads "key" at icon size.
static func _key(col: Color) -> Node3D:
	var root := Node3D.new()
	var body := ProceduralModels._mat(Color(0.75, 0.76, 0.8), 0.7, 0.35)
	var grip := ProceduralModels._mat(Color(0.18, 0.19, 0.22), 0.1, 0.8)
	var tag := ProceduralModels._mat(col * 0.6, 0.2, 0.4, col, 2.2)
	ProceduralModels._part(root, ProceduralModels._box(Vector3(0.3, 0.05, 0.14)), body)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.12, 0.06, 0.15)), grip, Vector3(-0.11, 0.0, 0.0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.16, 0.052, 0.04)), tag, Vector3(0.02, 0.0, 0.0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.05, 0.05, 0.05)), body, Vector3(0.17, 0.0, 0.035)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.05, 0.05, 0.04)), body, Vector3(0.17, 0.0, -0.04)
	)
	return root


## A stubby signal flare: violet body, dark cap, bright emissive tip + a pull ring.
static func _flare() -> Node3D:
	var root := Node3D.new()
	var body := ProceduralModels._mat(Color(0.45, 0.3, 0.6), 0.1, 0.55)
	var cap := ProceduralModels._mat(Color(0.16, 0.15, 0.18), 0.2, 0.6)
	var tip := ProceduralModels._mat(Color(0.8, 0.45, 1.0), 0.0, 0.3, Color(0.7, 0.4, 1.0), 2.0)
	ProceduralModels._part(root, ProceduralModels._cyl(0.055, 0.3), body)
	ProceduralModels._part(root, ProceduralModels._cyl(0.06, 0.05), cap, Vector3(0, -0.16, 0))
	ProceduralModels._part(root, ProceduralModels._cyl(0.045, 0.06), tip, Vector3(0, 0.17, 0))
	ProceduralModels._part(
		root, ProceduralModels._cyl(0.03, 0.012, 8), cap, Vector3(0.05, -0.2, 0), Vector3(90, 0, 0)
	)
	return root


## A white gauze roll lying on its side with a trailing wrap strip.
static func _bandage() -> Node3D:
	var root := Node3D.new()
	var gauze := ProceduralModels._mat(Color(0.92, 0.9, 0.85), 0.0, 0.9)
	var strip := ProceduralModels._mat(Color(0.85, 0.83, 0.78), 0.0, 0.9)
	ProceduralModels._part(
		root, ProceduralModels._cyl(0.1, 0.14, 12), gauze, Vector3.ZERO, Vector3(0, 0, 90)
	)
	ProceduralModels._part(root, ProceduralModels._cyl(0.045, 0.15, 8), gauze, Vector3(0, 0, 0))
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.22, 0.01, 0.13)), strip, Vector3(0.14, -0.085, 0)
	)
	return root


## Two wooden splint sticks with strap bands.
static func _splint() -> Node3D:
	var root := Node3D.new()
	var wood := ProceduralModels._mat(Color(0.72, 0.55, 0.3), 0.0, 0.8)
	var strap := ProceduralModels._mat(Color(0.35, 0.3, 0.25), 0.0, 0.7)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.06, 0.42, 0.05)), wood, Vector3(-0.06, 0, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.06, 0.42, 0.05)), wood, Vector3(0.06, 0, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.2, 0.05, 0.07)), strap, Vector3(0, 0.12, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.2, 0.05, 0.07)), strap, Vector3(0, -0.12, 0)
	)
	return root


## A pill bottle: orange body, white cap, pale label band.
static func _painkiller() -> Node3D:
	var root := Node3D.new()
	var body := ProceduralModels._mat(Color(0.95, 0.6, 0.2), 0.0, 0.45)
	var cap := ProceduralModels._mat(Color(0.95, 0.95, 0.95), 0.0, 0.5)
	var label := ProceduralModels._mat(Color(0.98, 0.95, 0.88), 0.0, 0.7)
	ProceduralModels._part(root, ProceduralModels._cyl(0.075, 0.2, 12), body)
	ProceduralModels._part(root, ProceduralModels._cyl(0.06, 0.05, 12), cap, Vector3(0, 0.125, 0))
	ProceduralModels._part(root, ProceduralModels._cyl(0.077, 0.09, 12), label)
	return root


## A combat helmet: hemisphere dome + visor slit; t2 adds side plates + a darker,
## more metallic shell.
static func _helmet(t2: bool) -> Node3D:
	var root := Node3D.new()
	var shell := ProceduralModels._mat(
		Color(0.35, 0.4, 0.48) if t2 else Color(0.5, 0.52, 0.4), 0.6 if t2 else 0.25, 0.5
	)
	var visor := ProceduralModels._mat(Color(0.1, 0.1, 0.12), 0.3, 0.3)
	ProceduralModels._part(root, ProceduralModels._sphere(0.21, true, 8, 14), shell)
	# Visor on BOTH faces so the icon camera (which orbits to a -Z 3/4 view) always
	# catches one — the in-world drop is tiny, the symmetry never reads.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.06, 0.06)), visor, Vector3(0, 0.05, 0.17)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.06, 0.06)), visor, Vector3(0, 0.05, -0.17)
	)
	if t2:
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.05, 0.12, 0.2)), shell, Vector3(0.2, 0.03, 0)
		)
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.05, 0.12, 0.2)), shell, Vector3(-0.2, 0.03, 0)
		)
	return root


## A body vest: torso plate + shoulder straps + a center plate; t2 adds an emissive
## trim line + gunmetal palette.
static func _vest(t2: bool) -> Node3D:
	var root := Node3D.new()
	var cloth := ProceduralModels._mat(
		Color(0.32, 0.36, 0.42) if t2 else Color(0.45, 0.47, 0.36), 0.15, 0.75
	)
	var plate := ProceduralModels._mat(
		Color(0.22, 0.25, 0.3) if t2 else Color(0.34, 0.36, 0.3), 0.5 if t2 else 0.2, 0.45
	)
	ProceduralModels._part(root, ProceduralModels._box(Vector3(0.42, 0.5, 0.18)), cloth)
	# Chest plate on BOTH faces (see the helmet visor note — icon-camera angle).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.26, 0.3, 0.06)), plate, Vector3(0, 0.04, 0.11)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.26, 0.3, 0.06)), plate, Vector3(0, 0.04, -0.11)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.1, 0.08, 0.24)), cloth, Vector3(0.16, 0.29, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.1, 0.08, 0.24)), cloth, Vector3(-0.16, 0.29, 0)
	)
	if t2:
		var trim := ProceduralModels._mat(
			Color(0.6, 0.5, 0.2), 0.4, 0.4, Color(1.0, 0.78, 0.25), 1.6
		)
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.28, 0.025, 0.065)), trim, Vector3(0, 0.2, 0.11)
		)
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.28, 0.025, 0.065)), trim, Vector3(0, 0.2, -0.11)
		)
	return root


## A backpack: main bag + lid + strap cylinders; the large variant is taller with
## side pouches and a darker canvas.
static func _pack(large: bool) -> Node3D:
	var root := Node3D.new()
	var canvas := ProceduralModels._mat(
		Color(0.45, 0.38, 0.28) if large else Color(0.55, 0.45, 0.3), 0.0, 0.85
	)
	var dark := ProceduralModels._mat(Color(0.3, 0.26, 0.2), 0.0, 0.8)
	var h := 0.62 if large else 0.5
	ProceduralModels._part(root, ProceduralModels._box(Vector3(0.42, h, 0.26)), canvas)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.12, 0.28)), dark, Vector3(0, h * 0.5, 0.0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cyl(0.025, h * 0.9, 6),
		dark,
		Vector3(0.12, 0.0, -0.16),
		Vector3(8, 0, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cyl(0.025, h * 0.9, 6),
		dark,
		Vector3(-0.12, 0.0, -0.16),
		Vector3(8, 0, 0)
	)
	if large:
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.1, 0.3, 0.2)), dark, Vector3(0.26, -0.08, 0)
		)
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.1, 0.3, 0.2)), dark, Vector3(-0.26, -0.08, 0)
		)
	return root
