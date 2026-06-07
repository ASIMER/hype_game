extends Node
## Single indirection between logical ids ("robot_grunt", "rifle", "crate") and
## actual art. If a CC0 asset exists at the mapped path it is used; otherwise a
## tinted primitive mesh is returned so the game is ALWAYS runnable with zero
## downloaded assets. Only logical ids are networked — never model subtrees.

enum Prim { CAPSULE, BOX, SPHERE, CYLINDER }

# logical id -> { model: res-path or "", icon: res-path or "",
#                 prim: Prim, size: Vector3, color: Color,
#                 model_scale: float|Vector3 (optional, default 1),
#                 model_rot_deg: Vector3 (optional, Euler degrees),
#                 model_offset: Vector3 (optional, local metres) }
# model_scale/model_rot_deg/model_offset ONLY affect the visual GLB subtree so
# differently-authored CC0 art lines up with the capsule `size`. They never touch
# collision shapes — those live in the scenes and are unchanged.
const CATALOG := {
	# Kenney Starter-Kit-3D-Platformer character.glb (CC0). Authored ~1.1m tall,
	# feet at y=0, facing +Z; scale up to capsule height and spin 180° to face -Z.
	"player": { "model": "res://assets/models/characters/raider.glb", "icon": "",
		"prim": Prim.CAPSULE, "size": Vector3(0.8, 1.8, 0.8), "color": Color(0.3, 0.7, 0.9),
		"model_scale": 1.55, "model_rot_deg": Vector3(0, 180, 0) },
	# three.js RobotExpressive.glb (Quaternius / Tomás Laulhé, CC0). ~4.6m tall,
	# feet at y=0; ModelRoot sits at capsule centre (y=0.8) so drop the feet to ground.
	"robot_grunt": { "model": "res://assets/models/robots/grunt.glb", "icon": "",
		"prim": Prim.CAPSULE, "size": Vector3(0.9, 1.6, 0.9), "color": Color(0.85, 0.25, 0.2),
		"model_scale": 0.33, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.7, 0) },
	# Same RobotExpressive, scaled for the heavy variant (BOX hitbox, ~1.8m tall).
	"robot_heavy": { "model": "res://assets/models/robots/heavy.glb", "icon": "",
		"prim": Prim.BOX, "size": Vector3(1.4, 1.8, 1.4), "color": Color(0.6, 0.15, 0.15),
		"model_scale": 0.36, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.9, 0) },
	# Kenney Starter-Kit-FPS blaster.glb (CC0). ~1.6m long down +Z; shrink to a held weapon.
	# Weapons: Kenney Blaster Kit (CC0) glTF view-models. Barrel faces +Z so held guns
	# rotate 180° to point -Z; share Textures/colormap.png. See docs/ASSETS.md.
	"rifle": { "model": "res://assets/models/weapons/rifle.glb", "icon": "res://assets/ui/icons/rifle.png",
		"prim": Prim.BOX, "size": Vector3(0.12, 0.18, 0.8), "color": Color(0.2, 0.2, 0.22),
		"model_scale": 0.34, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.02, 0) },
	# Khronos glTF-Sample-Assets Box.glb (CC0). Unit cube centred at origin; shrink to
	# 0.6m. The sample box is a plain red cube, so retint untextured faces to crate tan.
	"crate": { "model": "res://assets/models/environment/crate.glb", "icon": "res://assets/ui/icons/crate.png",
		"prim": Prim.BOX, "size": Vector3(0.6, 0.6, 0.6), "color": Color(0.7, 0.55, 0.25),
		"model_scale": 0.6, "model_albedo": Color(0.7, 0.55, 0.25) },
	"loot_scrap": { "model": "", "icon": "",
		"prim": Prim.SPHERE, "size": Vector3(0.4, 0.4, 0.4), "color": Color(0.8, 0.7, 0.3) },
	"loot_cell": { "model": "", "icon": "",
		"prim": Prim.CYLINDER, "size": Vector3(0.3, 0.5, 0.3), "color": Color(0.3, 0.9, 0.5) },

	# --- Weapons: Kenney Blaster Kit (CC0) glTF view-models (was procedural). ---
	"smg": { "model": "res://assets/models/weapons/smg.glb", "icon": "res://assets/ui/icons/smg.png",
		"prim": Prim.BOX, "size": Vector3(0.1, 0.16, 0.55), "color": Color(0.18, 0.18, 0.2),
		"model_scale": 0.58, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.02, 0) },
	"shotgun": { "model": "res://assets/models/weapons/shotgun.glb", "icon": "res://assets/ui/icons/shotgun.png",
		"prim": Prim.BOX, "size": Vector3(0.12, 0.16, 0.9), "color": Color(0.25, 0.16, 0.1),
		"model_scale": 0.6, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.02, 0) },
	"pistol": { "model": "res://assets/models/weapons/pistol.glb", "icon": "res://assets/ui/icons/pistol.png",
		"prim": Prim.BOX, "size": Vector3(0.08, 0.18, 0.35), "color": Color(0.2, 0.2, 0.22),
		"model_scale": 0.48, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.02, 0) },
	"dmr": { "model": "res://assets/models/weapons/dmr.glb", "icon": "res://assets/ui/icons/dmr.png",
		"prim": Prim.BOX, "size": Vector3(0.1, 0.16, 1.1), "color": Color(0.15, 0.17, 0.2),
		"model_scale": 0.34, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.02, -0.06) },

	# --- Expansion: enemy archetypes (primitive fallbacks; enemies-dev may swap glbs) ---
	"robot_tick": { "model": "", "icon": "",
		"prim": Prim.SPHERE, "size": Vector3(0.7, 0.6, 0.7), "color": Color(0.9, 0.55, 0.1) },
	"robot_wasp": { "model": "", "icon": "",
		"prim": Prim.SPHERE, "size": Vector3(0.8, 0.7, 0.8), "color": Color(0.2, 0.7, 0.9) },
	# Distinct procedural turret/mech (ProceduralModels) — no shared .glb.
	"robot_bastion": { "model": "", "icon": "",
		"prim": Prim.BOX, "size": Vector3(2.0, 2.6, 2.0), "color": Color(0.5, 0.1, 0.1) },
	"robot_boss": { "model": "", "icon": "",
		"prim": Prim.BOX, "size": Vector3(3.4, 4.4, 3.4), "color": Color(0.35, 0.05, 0.35) },
	# Caller / "Snitch" — distinct procedural antenna-bot (ProceduralModels); alarm-red beacon.
	"robot_caller": { "model": "", "icon": "",
		"prim": Prim.CAPSULE, "size": Vector3(0.8, 1.5, 0.8), "color": Color(0.95, 0.45, 0.2) },
	# Elite — a bigger, gold-trimmed variant of the RobotExpressive grunt model (like heavy).
	"robot_elite": { "model": "res://assets/models/robots/grunt.glb", "icon": "",
		"prim": Prim.BOX, "size": Vector3(1.0, 1.7, 1.0), "color": Color(0.92, 0.72, 0.18),
		"model_scale": 0.42, "model_rot_deg": Vector3(0, 180, 0), "model_offset": Vector3(0, -0.85, 0) },

	# --- Expansion: items ---
	"loot_medkit": { "model": "", "icon": "",
		"prim": Prim.BOX, "size": Vector3(0.4, 0.28, 0.4), "color": Color(0.9, 0.95, 0.95) },
	"loot_grenade": { "model": "", "icon": "",
		"prim": Prim.SPHERE, "size": Vector3(0.3, 0.3, 0.3), "color": Color(0.25, 0.4, 0.2) },
	"loot_ammo": { "model": "", "icon": "",
		"prim": Prim.BOX, "size": Vector3(0.35, 0.25, 0.35), "color": Color(0.7, 0.6, 0.25) },

	# --- Expansion: salvage materials + valuables (colored-box fallback; no icons yet) ---
	"loot_plastic":   { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.35, 0.25, 0.35), "color": Color(0.82, 0.82, 0.86) },
	"loot_chemicals": { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.3, 0.45, 0.3), "color": Color(0.6, 0.85, 0.25) },
	"loot_circuit":   { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.35, 0.08, 0.3), "color": Color(0.25, 0.7, 0.55) },
	"loot_artifact":  { "model": "", "icon": "", "prim": Prim.SPHERE, "size": Vector3(0.35, 0.35, 0.35), "color": Color(0.7, 0.35, 0.85) },
	"loot_data_chip": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.25, 0.04, 0.18), "color": Color(0.3, 0.85, 0.9) },

	# --- Crafted gear + schematics (colored-box fallback) ---
	"loot_stim":         { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.2, 0.4, 0.2), "color": Color(0.3, 0.9, 0.6) },
	"loot_self_revive":     { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.34, 0.24, 0.34), "color": Color(0.95, 0.45, 0.45) },
	"loot_knockdown_shield": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.36, 0.4, 0.1), "color": Color(0.55, 0.7, 0.95) },
	"loot_grenade_mk2":  { "model": "", "icon": "", "prim": Prim.SPHERE, "size": Vector3(0.32, 0.32, 0.32), "color": Color(0.2, 0.5, 0.25) },
	"loot_circuit_pack": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.4, 0.12, 0.3), "color": Color(0.2, 0.75, 0.6) },
	"schematic_ammo":         { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.35, 0.55, 0.95) },
	"schematic_stim":         { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.35, 0.55, 0.95) },
	"schematic_circuit_pack": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.35, 0.55, 0.95) },
	"schematic_grenade_mk2":  { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.45, 0.45, 0.95) },

	# --- Weapon attachments (colored-box fallback) ---
	"att_scope_4x":    { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.12, 0.3, 0.12), "color": Color(0.2, 0.25, 0.32) },
	"att_ext_mag":     { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.14, 0.3, 0.1), "color": Color(0.4, 0.42, 0.45) },
	"att_compensator": { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.1, 0.18, 0.1), "color": Color(0.55, 0.55, 0.58) },
	"att_holo_sight":     { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.12, 0.14, 0.12), "color": Color(0.22, 0.3, 0.4) },
	"att_red_dot":        { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.1, 0.12, 0.1), "color": Color(0.25, 0.32, 0.42) },
	"att_drum_mag":       { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.2, 0.16, 0.2), "color": Color(0.36, 0.38, 0.42) },
	"att_light_mag":      { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.12, 0.24, 0.09), "color": Color(0.46, 0.48, 0.5) },
	"att_long_barrel":    { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.08, 0.4, 0.08), "color": Color(0.5, 0.5, 0.54) },
	"att_suppressor":     { "model": "", "icon": "", "prim": Prim.CYLINDER, "size": Vector3(0.1, 0.28, 0.1), "color": Color(0.3, 0.3, 0.33) },
	"att_heavy_grip":     { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.1, 0.16, 0.12), "color": Color(0.4, 0.36, 0.32) },
	"att_quickdraw_grip": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.1, 0.16, 0.12), "color": Color(0.45, 0.42, 0.36) },
	"schematic_drum_mag":   { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.4, 0.5, 0.95) },
	"schematic_suppressor": { "model": "", "icon": "", "prim": Prim.BOX, "size": Vector3(0.3, 0.02, 0.22), "color": Color(0.4, 0.5, 0.95) },
}

func has_id(id: String) -> bool:
	return CATALOG.has(id)

## Returns a fresh Node3D containing the model for `id` (CC0 if present, else primitive).
## CC0 art is wrapped in a transform-carrying root so per-asset scale/rotation/offset
## from the CATALOG make it fit the capsule `size`. Hitboxes are never touched here.
func get_model(id: String) -> Node3D:
	var entry: Dictionary = CATALOG.get(id, {})
	var model_path: String = entry.get("model", "")
	if model_path != "" and ResourceLoader.exists(model_path):
		var packed := load(model_path)
		if packed is PackedScene:
			var glb := (packed as PackedScene).instantiate()
			return _fit_model(glb, entry)
	# Procedural weapon view-models, then composite enemy/item shapes, then the flat fallback.
	if ProceduralWeapons.has_builder(id):
		var gun: Node3D = ProceduralWeapons.build(id)
		if gun != null:
			return gun
	if ProceduralModels.has_builder(id):
		var built: Node3D = ProceduralModels.build(id)
		if built != null:
			return built
	return _make_primitive(entry)

## Wraps an instantiated GLB in a Node3D and applies the optional CATALOG fit
## fields (model_scale, model_rot_deg, model_offset) so art lines up with the capsule.
func _fit_model(glb: Node, entry: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.add_child(glb)
	if glb is Node3D:
		var n3d := glb as Node3D
		var xform := Transform3D.IDENTITY
		var scale_val: Variant = entry.get("model_scale", null)
		if scale_val != null:
			if scale_val is Vector3:
				xform = xform.scaled(scale_val)
			else:
				xform = xform.scaled(Vector3.ONE * float(scale_val))
		var rot: Vector3 = entry.get("model_rot_deg", Vector3.ZERO)
		if rot != Vector3.ZERO:
			xform.basis = Basis.from_euler(Vector3(
				deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z))) * xform.basis
		xform.origin = entry.get("model_offset", Vector3.ZERO)
		n3d.transform = xform
	var albedo: Variant = entry.get("model_albedo", null)
	if albedo is Color:
		_retint_untextured(glb, albedo)
	return root

## Recursively recolors GLB surfaces that carry NO albedo texture (e.g. the plain
## Khronos sample box). Textured art is left untouched so only solid-color stand-ins
## pick up the catalog tint. Visual only — never affects collision.
func _retint_untextured(node: Node, albedo: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for s in mesh.get_surface_count():
				var mat := mi.get_active_material(s)
				if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture == null:
					var tinted := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
					tinted.albedo_color = albedo
					mi.set_surface_override_material(s, tinted)
	for c in node.get_children():
		_retint_untextured(c, albedo)

## Returns an icon texture for inventory UI, or null (UI should draw a colored box fallback).
func get_icon(id: String) -> Texture2D:
	var entry: Dictionary = CATALOG.get(id, {})
	var icon_path: String = entry.get("icon", "")
	if icon_path != "" and ResourceLoader.exists(icon_path):
		var tex := load(icon_path)
		if tex is Texture2D:
			return tex
	# No authored PNG → render the 3D model to a texture (null on headless).
	return IconRenderer.render_icon(id)

func get_color(id: String) -> Color:
	return CATALOG.get(id, {}).get("color", Color(0.6, 0.6, 0.6))

func _make_primitive(entry: Dictionary) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var size: Vector3 = entry.get("size", Vector3.ONE)
	var prim: int = entry.get("prim", Prim.BOX)
	var mesh: Mesh
	match prim:
		Prim.CAPSULE:
			var c := CapsuleMesh.new()
			c.radius = size.x * 0.5
			c.height = size.y
			mesh = c
		Prim.SPHERE:
			var s := SphereMesh.new()
			s.radius = size.x * 0.5
			s.height = size.x
			mesh = s
		Prim.CYLINDER:
			var cy := CylinderMesh.new()
			cy.top_radius = size.x * 0.5
			cy.bottom_radius = size.x * 0.5
			cy.height = size.y
			mesh = cy
		_:
			var b := BoxMesh.new()
			b.size = size
			mesh = b
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = entry.get("color", Color(0.6, 0.6, 0.6))
	mat.roughness = 0.7
	mi.material_override = mat
	root.add_child(mi)
	return root
