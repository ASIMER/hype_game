class_name ProceduralModelsFauna
extends RefCounted
## Procedural models for the v0.3 BIOME FAUNA + biome minibosses + the recon drone.
## Split from procedural_models.gd purely for size discipline (that file sits near the
## gdlint max-file-lines ceiling); reuses ITS static mesh/material/placement helpers
## (no copy-paste — the AUDIT F1 rule). Dispatched via ProceduralModels.build()/
## has_builder (FAUNA_BUILDERS), so AssetRegistry.get_model — and therefore the
## enemy scenes AND IconRenderer — pick these up automatically.
##
## Same discipline as the enemies in procedural_models.gd: StandardMaterial3D only
## (hit-flash compatible), authored facing -Z, named parts for the per-frame idle
## animation hooks in the enemy scripts (robot_worm / robot_kamikaze / robot_strafer).


static func build(id: String) -> Node3D:
	match id:
		"robot_sandworm":
			return build_robot_sandworm()
		"robot_scarab":
			return build_robot_scarab()
		"robot_dustdevil":
			return build_robot_dustdevil()
		"robot_frosthound":
			return build_robot_frosthound()
		"robot_cryomortar":
			return build_robot_cryomortar()
		"robot_avalanche":
			return build_robot_avalanche()
		"robot_oni":
			return build_robot_oni()
		"robot_kappa":
			return build_robot_kappa()
		"robot_raiju":
			return build_robot_raiju()
		"robot_snow_golem":
			return build_robot_snow_golem()
		"robot_dune_warden":
			return build_robot_dune_warden()
		"robot_oni_chief":
			return build_robot_oni_chief()
		"robot_specter":
			return build_robot_specter()
	return null


## DESERT — Sand-worm: a segmented mechanical drill-worm. Horizontal body along Z with
## a drill-cone head (-Z), a glowing amber MAW ring (the weak point sits there in the
## scene), 7 tapered ring segments under pivots "Seg0".."Seg6" (the crawl undulation
## sways the pivots), dorsal fins, and a tail spike. ModelRoot at y=0 — body axis ≈y0.5.
static func build_robot_sandworm() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand hull; the drill cone + dorsal fins read as bare
	# steel; the Maw keeps its identity-amber kill-window glow (kit energy 3.5 = signage).
	var k := ProcEnemyKits.kit("robot_sandworm")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var plate: StandardMaterial3D = k["steel"]
	var maw_mat: StandardMaterial3D = k["glow"]

	# Drill head: a ribbed cone whose apex faces -Z (the travel direction).
	ProceduralModels._part(
		root, ProceduralModels._cone(0.4, 0.8, 12), dark, Vector3(0, 0.5, -0.85), Vector3(-90, 0, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.3, 0.62, 10),
		plate,
		Vector3(0, 0.5, -0.8),
		Vector3(-90, 0, 0)
	)
	# Glowing maw ring just behind the drill (named for the emission pulse).
	var maw := ProceduralModels._part(
		root,
		ProceduralModels._cyl(0.46, 0.12, 16),
		maw_mat,
		Vector3(0, 0.5, -0.42),
		Vector3(90, 0, 0)
	)
	maw.name = "Maw"

	# 7 tapered body segments, each under its own pivot so the crawl can undulate them.
	for i in 7:
		var t := float(i) / 6.0
		var r: float = lerpf(0.44, 0.2, t)
		var y: float = lerpf(0.5, 0.36, t)
		var pivot := Node3D.new()
		pivot.name = "Seg%d" % i
		pivot.position = Vector3(0, y, -0.15 + float(i) * 0.27)
		root.add_child(pivot)
		var seg_mat := shell if (i % 2 == 0) else dark
		ProceduralModels._part(
			pivot,
			ProceduralModels._sphere(r, false, 8, 14),
			seg_mat,
			Vector3.ZERO,
			Vector3.ZERO,
			Vector3(1.0, 0.85, 0.78)
		)
		# Dorsal fin on every other segment for a serrated silhouette.
		if i % 2 == 0:
			ProceduralModels._part(
				pivot, ProceduralModels._cone(0.1, 0.26, 6), plate, Vector3(0, r * 0.8, 0)
			)
	# Tail spike (+Z rear).
	ProceduralModels._part(
		root, ProceduralModels._cone(0.16, 0.5, 8), dark, Vector3(0, 0.36, 1.85), Vector3(90, 0, 0)
	)
	return root


## DESERT — Scarab: a squat kamikaze beetle. Domed rust-orange shell, 4 stub legs under
## pivots "Leg0".."Leg3", front mandibles, and a rear glowing red "Core" that the script
## blinks faster while ARMED. ModelRoot at y=0 — feet at ground.
static func build_robot_scarab() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated rust hull; the arming Core keeps its bespoke RED
	# blink (gameplay signage, NOT the identity orange) at restrained energy.
	var k := ProcEnemyKits.kit("robot_scarab")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var leg_mat: StandardMaterial3D = k["steel"]
	var core_mat := ProcPlating.glow(Color(0.95, 0.2, 0.12), 3.5)
	var accent: StandardMaterial3D = k["accent"]

	# Domed carapace + dark underbelly.
	ProceduralModels._part(
		root,
		ProceduralModels._sphere(0.3, true, 8, 14),
		shell,
		Vector3(0, 0.16, 0),
		Vector3.ZERO,
		Vector3(1.2, 0.9, 1.35)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.12, 0.5)), dark, Vector3(0, 0.12, 0)
	)
	# Shell seam stripe + the rear ARMING core (named for the blink).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.04, 0.04, 0.5)), accent, Vector3(0, 0.42, 0)
	)
	var core := ProceduralModels._part(
		root, ProceduralModels._sphere(0.1, false, 8, 12), core_mat, Vector3(0, 0.4, 0.22)
	)
	core.name = "Core"
	# Front mandible prongs (-Z).
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.045, 0.2, 6),
		dark,
		Vector3(0.1, 0.1, -0.42),
		Vector3(-100, 0, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.045, 0.2, 6),
		dark,
		Vector3(-0.1, 0.1, -0.42),
		Vector3(-100, 0, 0)
	)
	# 4 stub legs under pivots (2 per side) for the skitter sway.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.14, 0.18]:
			var zf := float(z)
			var attach := Vector3(side * 0.22, 0.12, zf)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			ProceduralModels._strut(
				pivot, Vector3.ZERO, Vector3(side * 0.2, -0.12, 0.02), 0.04, leg_mat
			)
			ProceduralModels._part(
				pivot,
				ProceduralModels._sphere(0.045, false, 6, 8),
				dark,
				Vector3(side * 0.2, -0.12, 0.02)
			)
			li += 1
	return root


## DESERT — Dust-devil: a grounded strafing gunner riding a SPINNING sand-skirt cone
## (pivot named "Skirt", spun by the script), with a slim torso, a single amber "Eye",
## and vent fins. ModelRoot at y=0 — skirt base at ground.
static func build_robot_dustdevil() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand hull; skirt vanes carry the identity-amber accent.
	var k := ProcEnemyKits.kit("robot_dustdevil")
	var sand: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat: StandardMaterial3D = k["glow"]
	var plate: StandardMaterial3D = k["accent"]

	# Spinning skirt: an inverted dust cone + 3 angled vanes, all under the "Skirt" pivot.
	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	ProceduralModels._part(skirt, ProceduralModels._cone(0.55, 0.95, 14), sand, Vector3(0, 0.48, 0))
	for i in 3:
		var ang := TAU * float(i) / 3.0
		ProceduralModels._part(
			skirt,
			ProceduralModels._box(Vector3(0.06, 0.5, 0.28)),
			plate,
			Vector3(cos(ang) * 0.34, 0.42, sin(ang) * 0.34),
			Vector3(0, rad_to_deg(-ang), 18)
		)
	# Torso column + shoulder ring + head dome.
	ProceduralModels._part(root, ProceduralModels._cyl(0.26, 0.5, 12), dark, Vector3(0, 1.18, 0))
	ProceduralModels._part(root, ProceduralModels._cyl(0.32, 0.1, 12), plate, Vector3(0, 1.0, 0))
	ProceduralModels._part(
		root, ProceduralModels._sphere(0.24, true, 8, 12), sand, Vector3(0, 1.46, 0)
	)
	# Single amber sensor eye (-Z) + two rear vents.
	var eye := ProceduralModels._part(
		root, ProceduralModels._sphere(0.09, false, 8, 12), eye_mat, Vector3(0, 1.42, -0.22)
	)
	eye.name = "Eye"
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.1, 0.18, 0.05)),
		dark,
		Vector3(0.14, 1.25, 0.24),
		Vector3(0, 15, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.1, 0.18, 0.05)),
		dark,
		Vector3(-0.14, 1.25, 0.24),
		Vector3(0, -15, 0)
	)
	return root


## SNOW — Frost-hound: a wolf-like quadruped. Low box body, wedge head with an
## ice-blue "Core" visor, 4 strut legs under pivots "Leg0".."Leg3" (trot gait),
## dorsal icicle fins, stub tail. ModelRoot at y=0 — paws at ground.
static func build_robot_frosthound() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated frost-grey hull; icicle fins keep their translucent-ice
	# read (kept as-is per the sweep rules); legs are bare steel.
	var k := ProcEnemyKits.kit("robot_frosthound")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var ice := ProceduralModels._mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)
	var visor: StandardMaterial3D = k["glow"]
	var leg_mat: StandardMaterial3D = k["steel"]

	# Body + chest plate + wedge head (-Z) with the glowing visor.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.5, 0.42, 1.05)), shell, Vector3(0, 0.66, 0.05)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.42, 0.3, 0.4)), dark, Vector3(0, 0.6, -0.55)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.34, 0.26, 0.34)),
		shell,
		Vector3(0, 0.82, -0.72),
		Vector3(12, 0, 0)
	)
	var core := ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.26, 0.07, 0.06)), visor, Vector3(0, 0.86, -0.9)
	)
	core.name = "Core"
	# Jaw + ear prongs.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.2, 0.08, 0.24)), dark, Vector3(0, 0.66, -0.84)
	)
	ProceduralModels._part(
		root, ProceduralModels._cone(0.05, 0.16, 6), dark, Vector3(0.12, 1.0, -0.62)
	)
	ProceduralModels._part(
		root, ProceduralModels._cone(0.05, 0.16, 6), dark, Vector3(-0.12, 1.0, -0.62)
	)
	# Dorsal icicle fins + tail stub.
	for i in 3:
		ProceduralModels._part(
			root,
			ProceduralModels._cone(0.07, 0.26 - float(i) * 0.05, 6),
			ice,
			Vector3(0, 0.92, -0.2 + float(i) * 0.3),
			Vector3(-12, 0, 0)
		)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.06, 0.3, 6),
		shell,
		Vector3(0, 0.74, 0.68),
		Vector3(110, 0, 0)
	)
	# 4 legs under pivots at the body corners.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.38, 0.42]:
			var zf := float(z)
			var attach := Vector3(side * 0.24, 0.6, zf)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = attach
			root.add_child(pivot)
			ProceduralModels._strut(
				pivot, Vector3.ZERO, Vector3(side * 0.06, -0.32, 0.06), 0.06, leg_mat
			)
			ProceduralModels._strut(
				pivot,
				Vector3(side * 0.06, -0.32, 0.06),
				Vector3(side * 0.08, -0.6, -0.02),
				0.05,
				leg_mat
			)
			ProceduralModels._part(
				pivot,
				ProceduralModels._sphere(0.06, false, 6, 8),
				dark,
				Vector3(side * 0.08, -0.6, -0.02)
			)
			li += 1
	return root


## SNOW — Cryo-mortar: a squat tripod artillery piece. Base disc on 3 splayed legs,
## a fat 45°-angled mortar "Tube" pivot (player-yaw tracked), cyan frost-tank "Core".
## ModelRoot at y=0.
static func build_robot_cryomortar() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated frost hull; the mortar tube + tripod legs are bare steel.
	var k := ProcEnemyKits.kit("robot_cryomortar")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var steel: StandardMaterial3D = k["steel"]
	var frost: StandardMaterial3D = k["glow"]
	var leg_mat: StandardMaterial3D = k["steel"]

	# 3 splayed tripod legs + the base platform.
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.5
		var foot := Vector3(cos(ang) * 0.62, 0.0, sin(ang) * 0.62)
		ProceduralModels._strut(root, Vector3(0, 0.5, 0), foot, 0.07, leg_mat)
		ProceduralModels._part(root, ProceduralModels._sphere(0.08, false, 6, 8), dark, foot)
	ProceduralModels._part(root, ProceduralModels._cyl(0.42, 0.22, 12), shell, Vector3(0, 0.55, 0))
	# The mortar tube under a yaw pivot, angled up 45° facing -Z.
	var tube := Node3D.new()
	tube.name = "Tube"
	tube.position = Vector3(0, 0.72, 0)
	root.add_child(tube)
	ProceduralModels._part(
		tube, ProceduralModels._cyl(0.2, 1.1, 12), steel, Vector3(0, 0.32, -0.3), Vector3(-45, 0, 0)
	)
	ProceduralModels._part(
		tube,
		ProceduralModels._cyl(0.24, 0.18, 12),
		shell,
		Vector3(0, 0.66, -0.66),
		Vector3(-45, 0, 0)
	)
	# Frost tanks: one glowing "Core" + a dark twin.
	var core := ProceduralModels._part(
		root, ProceduralModels._cyl(0.13, 0.4, 10), frost, Vector3(0.3, 0.9, 0.18)
	)
	core.name = "Core"
	ProceduralModels._part(
		root, ProceduralModels._cyl(0.13, 0.4, 10), dark, Vector3(-0.3, 0.9, 0.18)
	)
	return root


## SNOW — Avalanche: a hulking white-plated brute. Wide torso, huge "Fist0"/"Fist1"
## boxes (raised during the slam windup), small sensor head, blue chest "Core"
## (the weak point sits there in the scene). ModelRoot at y=0.
static func build_robot_avalanche() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated white armour; the chest Core hosts the scene weak point,
	# so it keeps its bespoke saturated blue at signage energy; ice pads kept as-is.
	var k := ProcEnemyKits.kit("robot_avalanche")
	var plate: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var core_mat := ProcPlating.glow(Color(0.35, 0.7, 1.0), 3.5)
	var ice := ProceduralModels._mat(Color(0.7, 0.88, 0.98), 0.1, 0.25)

	# Thick legs + pelvis.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.7, 0.34)), dark, Vector3(0.26, 0.35, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.7, 0.34)), dark, Vector3(-0.26, 0.35, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.84, 0.3, 0.5)), plate, Vector3(0, 0.82, 0)
	)
	# Wide armored torso + shoulder pads + the glowing chest core (-Z face).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(1.15, 0.95, 0.7)), plate, Vector3(0, 1.5, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.34, 0.5)), ice, Vector3(0.74, 1.92, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.34, 0.5)), ice, Vector3(-0.74, 1.92, 0)
	)
	var core := ProceduralModels._part(
		root, ProceduralModels._sphere(0.16, false, 8, 12), core_mat, Vector3(0, 1.55, -0.36)
	)
	core.name = "Core"
	# Small sensor head between the shoulders.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.24, 0.3)), dark, Vector3(0, 2.12, -0.05)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.2, 0.05, 0.05)), core_mat, Vector3(0, 2.12, -0.22)
	)
	# HUGE fists on arm struts, under pivots so the windup can RAISE them.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 0.95, 1.0, -0.1)
		root.add_child(fist)
		ProceduralModels._strut(
			root, Vector3(side * 0.74, 1.85, 0), Vector3(side * 0.95, 1.25, -0.1), 0.1, dark
		)
		ProceduralModels._part(
			fist, ProceduralModels._box(Vector3(0.42, 0.42, 0.46)), plate, Vector3(0, 0, 0)
		)
		ProceduralModels._part(
			fist, ProceduralModels._box(Vector3(0.44, 0.16, 0.2)), dark, Vector3(0, -0.16, -0.18)
		)
	return root


## RAIN — Oni: a temple-guardian samurai mech. Broad torso, kabuto helmet with horn
## cones, a glowing RED oni-mask face, a katana-arm blade, skirt plates. Its weak
## point (scene) sits on the BACK — the model marks it with a glowing seal. ModelRoot at y=0.
static func build_robot_oni() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): lacquered dark-red hull (kit arch LACQUER); skirt/sode plates
	# keep their brighter red via the ProcPlating.lacquer factory; katana = bare steel;
	# kabuto gold routed through the high-metallic decor recipe (same colour).
	var k := ProcEnemyKits.kit("robot_oni")
	var armor: StandardMaterial3D = k["hull"]
	var lacquer := ProcPlating.lacquer(Color(0.5, 0.12, 0.12), 81)
	var dark: StandardMaterial3D = k["frame"]
	var mask: StandardMaterial3D = k["glow"]
	var steel: StandardMaterial3D = k["steel"]
	var gold := ProceduralModels._mat(Color(0.85, 0.68, 0.25), 0.85, 0.25)

	# Legs + skirt plates (kusazuri).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.28, 0.66, 0.3)), dark, Vector3(0.22, 0.33, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.28, 0.66, 0.3)), dark, Vector3(-0.22, 0.33, 0)
	)
	for i in 4:
		var a := -0.45 + float(i) * 0.3
		ProceduralModels._part(
			root,
			ProceduralModels._box(Vector3(0.26, 0.34, 0.06)),
			lacquer,
			Vector3(a, 0.78, -0.26),
			Vector3(8, 0, 0)
		)
		ProceduralModels._part(
			root,
			ProceduralModels._box(Vector3(0.26, 0.34, 0.06)),
			lacquer,
			Vector3(a, 0.78, 0.26),
			Vector3(-8, 0, 0)
		)
	# Broad torso + chest cords + shoulder sode plates.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.95, 0.9, 0.55)), armor, Vector3(0, 1.4, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.5, 0.5, 0.04)), gold, Vector3(0, 1.45, -0.29)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.42, 0.5, 0.3)),
		lacquer,
		Vector3(0.64, 1.7, 0),
		Vector3(0, 0, -10)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.42, 0.5, 0.3)),
		lacquer,
		Vector3(-0.64, 1.7, 0),
		Vector3(0, 0, 10)
	)
	# Kabuto head: helmet dome + horns + the glowing oni mask (-Z).
	ProceduralModels._part(
		root, ProceduralModels._sphere(0.24, true, 8, 12), armor, Vector3(0, 2.05, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.05, 0.34, 6),
		gold,
		Vector3(0.12, 2.28, -0.05),
		Vector3(0, 0, -22)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.05, 0.34, 6),
		gold,
		Vector3(-0.12, 2.28, -0.05),
		Vector3(0, 0, 22)
	)
	var face := ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.26, 0.22, 0.06)), mask, Vector3(0, 1.98, -0.24)
	)
	face.name = "Core"
	# Katana arm (right): a long blade box angled down-forward.
	ProceduralModels._strut(root, Vector3(0.64, 1.45, 0), Vector3(0.86, 1.0, -0.2), 0.08, dark)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.05, 0.9, 0.14)),
		steel,
		Vector3(0.9, 0.65, -0.45),
		Vector3(30, 0, 0)
	)
	# Left fist.
	ProceduralModels._strut(root, Vector3(-0.64, 1.45, 0), Vector3(-0.8, 1.05, -0.1), 0.08, dark)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.24, 0.24, 0.26)), armor, Vector3(-0.8, 0.95, -0.12)
	)
	# BACK seal — a glowing plate marking the scene's ×3 weak point.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.3, 0.05)), mask, Vector3(0, 1.55, 0.3)
	)
	return root


## RAIN — Kappa: a hunched shell-backed pouncer. Forward-leaning body under a domed
## shell, claw arms, glowing green eye "Core", legs under "Leg0".."Leg3" pivots
## (shares the pouncer gait with the hound). ModelRoot at y=0.
static func build_robot_kappa() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated swamp-green hull; claws are bare steel.
	var k := ProcEnemyKits.kit("robot_kappa")
	var shell: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat: StandardMaterial3D = k["glow"]
	var claw: StandardMaterial3D = k["steel"]

	# Hunched body (tilted capsule) + the domed back shell with ridge plates.
	ProceduralModels._part(
		root, ProceduralModels._capsule(0.3, 0.9), shell, Vector3(0, 0.7, -0.05), Vector3(55, 0, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._sphere(0.46, true, 8, 14),
		dark,
		Vector3(0, 0.78, 0.18),
		Vector3(-18, 0, 0),
		Vector3(1.0, 0.7, 1.1)
	)
	for i in 3:
		ProceduralModels._part(
			root,
			ProceduralModels._cone(0.06, 0.14, 6),
			shell,
			Vector3(0, 1.06 - float(i) * 0.1, 0.1 + float(i) * 0.22),
			Vector3(-20, 0, 0)
		)
	# Head: flat dish crown + the glowing eyes bar.
	ProceduralModels._part(
		root, ProceduralModels._sphere(0.18, false, 8, 12), shell, Vector3(0, 1.06, -0.42)
	)
	ProceduralModels._part(
		root, ProceduralModels._cyl(0.16, 0.05, 12), dark, Vector3(0, 1.2, -0.42)
	)
	var eyes := ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.22, 0.06, 0.06)), eye_mat, Vector3(0, 1.06, -0.58)
	)
	eyes.name = "Core"
	# Claw arms (-Z reach).
	ProceduralModels._strut(root, Vector3(0.3, 0.85, -0.15), Vector3(0.45, 0.5, -0.45), 0.06, dark)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.07, 0.22, 6),
		claw,
		Vector3(0.45, 0.42, -0.52),
		Vector3(-115, 0, 0)
	)
	ProceduralModels._strut(
		root, Vector3(-0.3, 0.85, -0.15), Vector3(-0.45, 0.5, -0.45), 0.06, dark
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.07, 0.22, 6),
		claw,
		Vector3(-0.45, 0.42, -0.52),
		Vector3(-115, 0, 0)
	)
	# 4 squat legs under pouncer pivots.
	var li := 0
	for side in [-1.0, 1.0]:
		for z in [-0.18, 0.26]:
			var zf := float(z)
			var pivot := Node3D.new()
			pivot.name = "Leg%d" % li
			pivot.position = Vector3(side * 0.28, 0.5, zf)
			root.add_child(pivot)
			ProceduralModels._strut(
				pivot, Vector3.ZERO, Vector3(side * 0.1, -0.5, 0.04), 0.06, dark
			)
			ProceduralModels._part(
				pivot,
				ProceduralModels._sphere(0.07, false, 6, 8),
				claw,
				Vector3(side * 0.1, -0.5, 0.04)
			)
			li += 1
	return root


## RAIN — Raiju: a sleek storm-spirit canine. Slim long body, thin legs, lightning-rod
## "Antler0"/"Antler1" cones, electric-blue chest "Core" + arc fins. ModelRoot at y=0.
static func build_robot_raiju() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated storm-blue hull; core/fins/antlers share the identity
	# electric glow (kit energy, down from the old neon 7.0); legs are bare steel.
	var k := ProcEnemyKits.kit("robot_raiju")
	var body: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var bolt: StandardMaterial3D = k["glow"]
	var leg_mat: StandardMaterial3D = k["steel"]

	# Slim body + neck + fox head (-Z).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.34, 0.3, 0.95)), body, Vector3(0, 0.62, 0.08)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.24, 0.22, 0.3)),
		body,
		Vector3(0, 0.78, -0.5),
		Vector3(20, 0, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.22, 0.18, 0.3)), dark, Vector3(0, 0.92, -0.72)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.05, 0.16, 6),
		dark,
		Vector3(0, 0.9, -0.92),
		Vector3(-100, 0, 0)
	)
	# Electric core + dorsal arc fins.
	var core := ProceduralModels._part(
		root, ProceduralModels._sphere(0.1, false, 8, 12), bolt, Vector3(0, 0.66, -0.32)
	)
	core.name = "Core"
	for i in 2:
		ProceduralModels._part(
			root,
			ProceduralModels._box(Vector3(0.04, 0.16, 0.2)),
			bolt,
			Vector3(0, 0.84, -0.05 + float(i) * 0.34),
			Vector3(-16, 0, 0)
		)
	# Lightning-rod antlers under quiver pivots.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var ant := Node3D.new()
		ant.name = "Antler%d" % i
		ant.position = Vector3(side * 0.1, 1.0, -0.66)
		root.add_child(ant)
		ProceduralModels._part(
			ant,
			ProceduralModels._cone(0.03, 0.3, 5),
			bolt,
			Vector3(side * 0.04, 0.12, 0.02),
			Vector3(0, 0, -side * 18.0)
		)
	# Bushy segmented tail (+Z) + 4 thin legs.
	ProceduralModels._part(
		root, ProceduralModels._cone(0.1, 0.5, 6), body, Vector3(0, 0.74, 0.72), Vector3(115, 0, 0)
	)
	for side in [-1.0, 1.0]:
		for z in [-0.3, 0.38]:
			var zf := float(z)
			ProceduralModels._strut(
				root,
				Vector3(side * 0.16, 0.55, zf),
				Vector3(side * 0.2, 0.0, zf + 0.04),
				0.045,
				leg_mat
			)
	return root


# ================================================================= BIOME MINIBOSSES (v0.3)
# Oversized landmark threats — each is the silhouette of its biome's grunt scaled up
# with extra plating. They reuse the SAME named animation parts as their base archetype
# (slammer Fist0/Fist1 + Core, strafer Skirt + Eye, oni back-seal, flyer RotorHub + Body
# + Core) so the inherited _animate_visual binds with no script change. ModelRoot at y=0.


## SNOW miniboss — Snow Golem: a colossal icy avalanche. Huge plated torso, massive
## shoulder slabs, two oversized "Fist0"/"Fist1" boxes (raised during the slam windup),
## a glowing pale-cyan chest "Core". ~2.6 m tall.
static func build_robot_snow_golem() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated glacial armour; the boss core keeps its bespoke pale
	# cyan at signage energy; ice slabs kept as-is.
	var glow_col := Color(0.55, 0.85, 1.0)  # pale cyan
	var k := ProcEnemyKits.kit("robot_snow_golem")
	var plate: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var core_mat := ProcPlating.glow(glow_col, 3.5)
	var ice := ProceduralModels._mat(Color(0.72, 0.9, 1.0), 0.1, 0.22)

	# Thick legs + wide pelvis block.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.95, 0.46)), dark, Vector3(0.36, 0.48, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.95, 0.46)), dark, Vector3(-0.36, 0.48, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(1.15, 0.4, 0.66)), plate, Vector3(0, 1.12, 0)
	)
	# Massive armored torso + the glowing chest core (-Z face).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(1.55, 1.3, 0.95)), plate, Vector3(0, 2.05, 0)
	)
	var core := ProceduralModels._part(
		root, ProceduralModels._sphere(0.22, false, 8, 12), core_mat, Vector3(0, 2.1, -0.5)
	)
	core.name = "Core"
	# Huge shoulder slabs (jagged ice crown on top of each).
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		ProceduralModels._part(
			root, ProceduralModels._box(Vector3(0.58, 0.5, 0.7)), ice, Vector3(side * 1.02, 2.6, 0)
		)
		ProceduralModels._part(
			root,
			ProceduralModels._cone(0.12, 0.4, 6),
			ice,
			Vector3(side * 1.02, 2.95, 0),
			Vector3(0, 0, side * -10.0)
		)
	# Small sensor head sunk between the shoulders.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.32, 0.4)), dark, Vector3(0, 2.86, -0.06)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.28, 0.06, 0.06)), core_mat, Vector3(0, 2.86, -0.28)
	)
	# OVERSIZED fists on arm struts, under pivots so the slam windup can RAISE them.
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		var fist := Node3D.new()
		fist.name = "Fist%d" % i
		fist.position = Vector3(side * 1.28, 1.3, -0.12)
		root.add_child(fist)
		ProceduralModels._strut(
			root, Vector3(side * 1.02, 2.5, 0), Vector3(side * 1.28, 1.65, -0.12), 0.14, dark
		)
		ProceduralModels._part(
			fist, ProceduralModels._box(Vector3(0.6, 0.6, 0.66)), plate, Vector3(0, 0, 0)
		)
		ProceduralModels._part(
			fist, ProceduralModels._box(Vector3(0.64, 0.22, 0.28)), dark, Vector3(0, -0.22, -0.24)
		)
		# Icy knuckle spikes.
		for ki in 3:
			ProceduralModels._part(
				fist,
				ProceduralModels._cone(0.06, 0.2, 5),
				ice,
				Vector3(-0.18 + float(ki) * 0.18, 0.0, -0.38),
				Vector3(-90, 0, 0)
			)
	return root


## DESERT miniboss — Dune Warden: a heavy sand-skirted strafing gunner. Wide spinning
## "Skirt" sand cone, twin torso, a triple barrel cluster (-Z) named "Barrel", an amber
## sensor "Eye". The strafer animator only spins the Skirt + pulses the Eye, but the
## barrel cluster keeps the heavy-gunner read. ~2 m tall.
static func build_robot_dune_warden() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): plated sand armour; the boss Eye keeps its bespoke amber at
	# signage energy; skirt vanes carry the accent paint; gun cluster is bare steel.
	var glow_col := Color(0.95, 0.62, 0.22)  # desert amber
	var k := ProcEnemyKits.kit("robot_dune_warden")
	var sand: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var eye_mat := ProcPlating.glow(glow_col, 3.5)
	var plate: StandardMaterial3D = k["accent"]
	var gun: StandardMaterial3D = k["steel"]

	# WIDE spinning sand skirt: a big inverted dust cone + 5 angled vanes under "Skirt".
	var skirt := Node3D.new()
	skirt.name = "Skirt"
	root.add_child(skirt)
	ProceduralModels._part(skirt, ProceduralModels._cone(0.85, 1.3, 16), sand, Vector3(0, 0.66, 0))
	for i in 5:
		var ang := TAU * float(i) / 5.0
		ProceduralModels._part(
			skirt,
			ProceduralModels._box(Vector3(0.08, 0.66, 0.38)),
			plate,
			Vector3(cos(ang) * 0.52, 0.6, sin(ang) * 0.52),
			Vector3(0, rad_to_deg(-ang), 16)
		)
	# Heavy torso column + shoulder ring + domed head.
	ProceduralModels._part(root, ProceduralModels._cyl(0.4, 0.7, 14), dark, Vector3(0, 1.62, 0))
	ProceduralModels._part(root, ProceduralModels._cyl(0.5, 0.14, 14), plate, Vector3(0, 1.36, 0))
	ProceduralModels._part(
		root, ProceduralModels._sphere(0.36, true, 8, 14), sand, Vector3(0, 2.0, 0)
	)
	# Single amber sensor eye (-Z) + rear vents.
	var eye := ProceduralModels._part(
		root, ProceduralModels._sphere(0.14, false, 8, 12), eye_mat, Vector3(0, 1.92, -0.34)
	)
	eye.name = "Eye"
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.14, 0.26, 0.06)),
		dark,
		Vector3(0.22, 1.7, 0.36),
		Vector3(0, 15, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.14, 0.26, 0.06)),
		dark,
		Vector3(-0.22, 1.7, 0.36),
		Vector3(0, -15, 0)
	)
	# Triple barrel cluster on a side arm (-Z), under "Barrel".
	var barrel := Node3D.new()
	barrel.name = "Barrel"
	barrel.position = Vector3(0.62, 1.6, -0.2)
	root.add_child(barrel)
	ProceduralModels._part(
		barrel, ProceduralModels._box(Vector3(0.24, 0.24, 0.34)), gun, Vector3(0, 0, 0)
	)
	for i in 3:
		var off := -0.1 + float(i) * 0.1
		ProceduralModels._part(
			barrel,
			ProceduralModels._cyl(0.05, 0.6, 8),
			gun,
			Vector3(off, 0.02, -0.42),
			Vector3(-90, 0, 0)
		)
	return root


## RAIN miniboss — Oni Chief: a hulking crimson temple-guardian. Broad lacquered torso,
## horned kabuto head, a glowing oni mask "Core" (-Z), a heavy club arm, and a bright
## BACK-PLATE seal (+Z) hinting the scene's ×3 weak point. ~2.4 m tall.
static func build_robot_oni_chief() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): lacquered crimson hull (kit arch LACQUER); skirt/sode plates
	# via the ProcPlating.lacquer factory; boss mask keeps its bespoke crimson at
	# signage energy; kabuto gold routed through the high-metallic decor recipe.
	var glow_col := Color(0.75, 0.18, 0.15)  # crimson
	var k := ProcEnemyKits.kit("robot_oni_chief")
	var armor: StandardMaterial3D = k["hull"]
	var lacquer := ProcPlating.lacquer(Color(0.62, 0.14, 0.13), 105)
	var dark: StandardMaterial3D = k["frame"]
	var mask := ProcPlating.glow(glow_col, 3.5)
	var gold := ProceduralModels._mat(Color(0.85, 0.68, 0.25), 0.85, 0.25)

	# Legs + skirt plates (kusazuri).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.34, 0.8, 0.36)), dark, Vector3(0.28, 0.4, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.34, 0.8, 0.36)), dark, Vector3(-0.28, 0.4, 0)
	)
	for i in 5:
		var a := -0.6 + float(i) * 0.3
		ProceduralModels._part(
			root,
			ProceduralModels._box(Vector3(0.3, 0.4, 0.07)),
			lacquer,
			Vector3(a, 0.95, -0.32),
			Vector3(8, 0, 0)
		)
		ProceduralModels._part(
			root,
			ProceduralModels._box(Vector3(0.3, 0.4, 0.07)),
			lacquer,
			Vector3(a, 0.95, 0.32),
			Vector3(-8, 0, 0)
		)
	# Broad torso + chest cords + shoulder sode plates.
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(1.2, 1.1, 0.7)), armor, Vector3(0, 1.72, 0)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.6, 0.6, 0.05)), gold, Vector3(0, 1.78, -0.36)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.52, 0.6, 0.36)),
		lacquer,
		Vector3(0.8, 2.06, 0),
		Vector3(0, 0, -10)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.52, 0.6, 0.36)),
		lacquer,
		Vector3(-0.8, 2.06, 0),
		Vector3(0, 0, 10)
	)
	# Kabuto head: helmet dome + horns + the glowing oni mask (-Z).
	ProceduralModels._part(
		root, ProceduralModels._sphere(0.3, true, 8, 12), armor, Vector3(0, 2.5, 0)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.06, 0.42, 6),
		gold,
		Vector3(0.15, 2.78, -0.06),
		Vector3(0, 0, -22)
	)
	ProceduralModels._part(
		root,
		ProceduralModels._cone(0.06, 0.42, 6),
		gold,
		Vector3(-0.15, 2.78, -0.06),
		Vector3(0, 0, 22)
	)
	var face := ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.32, 0.26, 0.07)), mask, Vector3(0, 2.42, -0.3)
	)
	face.name = "Core"
	# Heavy club arm (right): a thick spiked tetsubo angled down-forward.
	ProceduralModels._strut(root, Vector3(0.8, 1.78, 0), Vector3(1.06, 1.2, -0.24), 0.1, dark)
	ProceduralModels._part(
		root,
		ProceduralModels._box(Vector3(0.2, 0.95, 0.2)),
		dark,
		Vector3(1.12, 0.85, -0.5),
		Vector3(30, 0, 0)
	)
	for ki in 4:
		ProceduralModels._part(
			root,
			ProceduralModels._cone(0.06, 0.16, 5),
			gold,
			Vector3(1.12, 0.62 + float(ki) * 0.18, -0.62),
			Vector3(-60, 0, 0)
		)
	# Left fist.
	ProceduralModels._strut(root, Vector3(-0.8, 1.78, 0), Vector3(-1.0, 1.26, -0.12), 0.1, dark)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.3, 0.3, 0.32)), armor, Vector3(-1.0, 1.14, -0.14)
	)
	# BACK seal — a bright glowing plate marking the scene's ×3 weak point (+Z).
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.4, 0.4, 0.06)), mask, Vector3(0, 1.85, 0.38)
	)
	ProceduralModels._part(
		root, ProceduralModels._box(Vector3(0.5, 0.5, 0.04)), gold, Vector3(0, 1.85, 0.34)
	)
	return root


## RECON drone — Specter: a slim hovering scout. Thin grey-violet chassis "Body", a 4-rotor
## ring under "RotorHub" (Rotor0..Rotor3 spin), one big cyan lens "Core", a tall antenna.
## Smaller than the wasp (~0.9 m span). Hovers; the flyer animator bobs Body + spins rotors.
static func build_robot_specter() -> Node3D:
	var root := Node3D.new()
	# Material kit (v2): mech-hull chassis, bare-steel rotor blades, identity-cyan lens.
	var k := ProcEnemyKits.kit("robot_specter")
	var body: StandardMaterial3D = k["hull"]
	var dark: StandardMaterial3D = k["frame"]
	var rotor: StandardMaterial3D = k["steel"]
	var lens: StandardMaterial3D = k["glow"]

	# A body pivot wrapping the slim chassis + lens + antenna so the script bobs just the
	# body (named "Body") without moving the rotors' spin hub.
	var bodyp := Node3D.new()
	bodyp.name = "Body"
	root.add_child(bodyp)
	# Slim flattened chassis with a forward sensor lens.
	ProceduralModels._part(
		bodyp, ProceduralModels._box(Vector3(0.34, 0.12, 0.5)), body, Vector3(0, 0, 0)
	)
	ProceduralModels._part(
		bodyp, ProceduralModels._sphere(0.13, true, 8, 12), dark, Vector3(0, 0.05, 0), Vector3.ZERO
	)
	var core := ProceduralModels._part(
		bodyp, ProceduralModels._sphere(0.1, false, 10, 14), lens, Vector3(0, 0.0, -0.26)
	)
	core.name = "Core"
	# Tall sensor antenna with a glowing tip.
	ProceduralModels._strut(bodyp, Vector3(0, 0.04, 0.14), Vector3(0, 0.34, 0.18), 0.012, dark)
	ProceduralModels._part(
		bodyp, ProceduralModels._sphere(0.03, false, 6, 8), lens, Vector3(0, 0.36, 0.18)
	)
	# Four small rotor arms to the diagonals, each disc under its own pivot in "RotorHub".
	var hub := Node3D.new()
	hub.name = "RotorHub"
	root.add_child(hub)
	var arms := [
		Vector3(0.26, 0.06, 0.26),
		Vector3(-0.26, 0.06, 0.26),
		Vector3(0.26, 0.06, -0.26),
		Vector3(-0.26, 0.06, -0.26)
	]
	var ri := 0
	for tip in arms:
		var tv: Vector3 = tip
		ProceduralModels._strut(root, Vector3(tv.x * 0.4, 0.02, tv.z * 0.4), tv, 0.02, dark)
		var pivot := Node3D.new()
		pivot.name = "Rotor%d" % ri
		pivot.position = tv + Vector3(0, 0.015, 0)
		hub.add_child(pivot)
		ProceduralModels._part(pivot, ProceduralModels._cyl(0.11, 0.02, 12), rotor)
		ProceduralModels._part(
			pivot, ProceduralModels._box(Vector3(0.22, 0.028, 0.03)), dark, Vector3(0, 0.015, 0)
		)
		ProceduralModels._part(
			pivot, ProceduralModels._box(Vector3(0.03, 0.028, 0.22)), dark, Vector3(0, 0.015, 0)
		)
		ProceduralModels._part(root, ProceduralModels._sphere(0.04, false, 6, 8), dark, tv)
		ri += 1
	return root
