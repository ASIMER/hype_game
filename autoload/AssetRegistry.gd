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
	# Power cache — a glowing chest the player opens for a timed buff (Vampire-Survivors-style).
	"power_cache":
	{
		# Procedural chest if a builder exists, else a gold box; the loot-glow pillar makes it pop.
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.9, 0.7, 0.7),
		"color": Color(0.96, 0.78, 0.28)
	},
	# Kenney Starter-Kit-3D-Platformer character.glb (CC0). Authored ~1.1m tall,
	"player":
	{
		# feet at y=0, facing +Z; scale up to capsule height and spin 180° to face -Z.
		"model": "res://assets/models/characters/raider.glb",
		"icon": "",
		"prim": Prim.CAPSULE,
		"size": Vector3(0.8, 1.8, 0.8),
		"color": Color(0.3, 0.7, 0.9),
		"model_scale": 1.55,
		"model_rot_deg": Vector3(0, 180, 0)
	},
	# v0.5-B4: the starter troopers are PROCEDURAL now (ProceduralModelsTroopers) — the
	# old RobotExpressive .glbs left a dark toy blob with unpainted eyes after the reskin.
	"robot_grunt":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CAPSULE,
		"size": Vector3(0.9, 1.6, 0.9),
		"color": Color(0.85, 0.25, 0.2)
	},
	"robot_heavy":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(1.4, 1.8, 1.4),
		"color": Color(0.6, 0.15, 0.15)
	},
	# Kenney Starter-Kit-FPS blaster.glb (CC0). ~1.6m long down +Z; shrink to a held weapon.
	# Weapons: Kenney Blaster Kit (CC0) glTF view-models. Barrel faces +Z so held guns
	"rifle":
	{
		# rotate 180° to point -Z; share Textures/colormap.png. See docs/ASSETS.md.
		"model": "res://assets/models/weapons/rifle.glb",
		"icon": "res://assets/ui/icons/rifle.png",
		"prim": Prim.BOX,
		"size": Vector3(0.12, 0.18, 0.8),
		"color": Color(0.2, 0.2, 0.22),
		"model_scale": 0.34,
		"model_rot_deg": Vector3(0, 180, 0),
		"model_offset": Vector3(0, -0.02, 0)
	},
	# Khronos glTF-Sample-Assets Box.glb (CC0). Unit cube centred at origin; shrink to
	"crate":
	{
		# 0.6m. The sample box is a plain red cube, so retint untextured faces to crate tan.
		"model": "res://assets/models/environment/crate.glb",
		"icon": "res://assets/ui/icons/crate.png",
		"prim": Prim.BOX,
		"size": Vector3(0.6, 0.6, 0.6),
		"color": Color(0.7, 0.55, 0.25),
		"model_scale": 0.6,
		"model_albedo": Color(0.7, 0.55, 0.25)
	},
	"loot_scrap":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.4, 0.4, 0.4),
		"color": Color(0.8, 0.7, 0.3)
	},
	"loot_cell":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.3, 0.5, 0.3),
		"color": Color(0.3, 0.9, 0.5)
	},
	"smg":
	{
		# --- Weapons: Kenney Blaster Kit (CC0) glTF view-models (was procedural). ---
		"model": "res://assets/models/weapons/smg.glb",
		"icon": "res://assets/ui/icons/smg.png",
		"prim": Prim.BOX,
		"size": Vector3(0.1, 0.16, 0.55),
		"color": Color(0.18, 0.18, 0.2),
		"model_scale": 0.58,
		"model_rot_deg": Vector3(0, 180, 0),
		"model_offset": Vector3(0, -0.02, 0)
	},
	"shotgun":
	{
		"model": "res://assets/models/weapons/shotgun.glb",
		"icon": "res://assets/ui/icons/shotgun.png",
		"prim": Prim.BOX,
		"size": Vector3(0.12, 0.16, 0.9),
		"color": Color(0.25, 0.16, 0.1),
		"model_scale": 0.6,
		"model_rot_deg": Vector3(0, 180, 0),
		"model_offset": Vector3(0, -0.02, 0)
	},
	"pistol":
	{
		"model": "res://assets/models/weapons/pistol.glb",
		"icon": "res://assets/ui/icons/pistol.png",
		"prim": Prim.BOX,
		"size": Vector3(0.08, 0.18, 0.35),
		"color": Color(0.2, 0.2, 0.22),
		"model_scale": 0.48,
		"model_rot_deg": Vector3(0, 180, 0),
		"model_offset": Vector3(0, -0.02, 0)
	},
	"dmr":
	{
		"model": "res://assets/models/weapons/dmr.glb",
		"icon": "res://assets/ui/icons/dmr.png",
		"prim": Prim.BOX,
		"size": Vector3(0.1, 0.16, 1.1),
		"color": Color(0.15, 0.17, 0.2),
		"model_scale": 0.34,
		"model_rot_deg": Vector3(0, 180, 0),
		"model_offset": Vector3(0, -0.02, -0.06)
	},
	"robot_tick":
	{
		# --- Expansion: enemy archetypes (primitive fallbacks; enemies-dev may swap glbs) ---
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.7, 0.6, 0.7),
		"color": Color(0.9, 0.55, 0.1)
	},
	"robot_wasp":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.8, 0.7, 0.8),
		"color": Color(0.2, 0.7, 0.9)
	},
	"robot_bastion":
	{
		# Distinct procedural turret/mech (ProceduralModels) — no shared .glb.
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(2.0, 2.6, 2.0),
		"color": Color(0.5, 0.1, 0.1)
	},
	"robot_boss":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(3.4, 4.4, 3.4),
		"color": Color(0.35, 0.05, 0.35)
	},
	"robot_caller":
	{
		# Caller / "Snitch" — distinct procedural antenna-bot (ProceduralModels); alarm-red beacon.
		"model": "",
		"icon": "",
		"prim": Prim.CAPSULE,
		"size": Vector3(0.8, 1.5, 0.8),
		"color": Color(0.95, 0.45, 0.2)
	},
	"robot_elite":
	{
		# Elite — procedural commander trooper (v0.5-B4; crest fin + gold trims).
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(1.0, 1.7, 1.0),
		"color": Color(0.92, 0.72, 0.18)
	},
	# --- Biome fauna (v0.3, all-procedural ProceduralModels builders; the `color` also
	"robot_sandworm":
	{
		# tints HP bars / weak-point markers / death debris). 3 per new biome. ---
		"model": "",
		"icon": "",
		"prim": Prim.CAPSULE,
		"size": Vector3(1.0, 1.1, 1.0),
		"color": Color(0.86, 0.6, 0.2)
	},
	"robot_scarab":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.6, 0.5, 0.6),
		"color": Color(0.82, 0.4, 0.12)
	},
	"robot_dustdevil":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.9, 1.6, 0.9),
		"color": Color(0.88, 0.72, 0.4)
	},
	"robot_frosthound":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.7, 1.0, 1.3),
		"color": Color(0.55, 0.82, 0.95)
	},
	"robot_cryomortar":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(1.4, 1.6, 1.4),
		"color": Color(0.35, 0.65, 0.92)
	},
	"robot_avalanche":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(1.5, 2.0, 1.2),
		"color": Color(0.88, 0.93, 0.98)
	},
	"robot_oni":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(1.3, 2.2, 1.0),
		"color": Color(0.88, 0.22, 0.2)
	},
	"robot_kappa":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CAPSULE,
		"size": Vector3(0.9, 1.3, 0.9),
		"color": Color(0.3, 0.76, 0.45)
	},
	"robot_raiju":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.6, 1.0, 1.2),
		"color": Color(0.45, 0.65, 1.0)
	},
	"loot_medkit":
	{
		# --- Expansion: items ---
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.4, 0.28, 0.4),
		"color": Color(0.9, 0.95, 0.95)
	},
	"loot_grenade":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.3, 0.3, 0.3),
		"color": Color(0.25, 0.4, 0.2)
	},
	"loot_ammo":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.35, 0.25, 0.35),
		"color": Color(0.7, 0.6, 0.25)
	},
	# Walk-up reserve resupply dropped by dying machines (never enters the inventory —
	# LootPickup routes it straight to the picker's WeaponController).
	"loot_ammo_shard":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.22, 0.14, 0.22),
		"color": Color(0.95, 0.78, 0.3)
	},
	# --- Batch B/C gear + consumables (ProceduralModelsGear builders; prim = safety
	# net). Without CATALOG entries these ids were invisible: the icon prewarm loops
	# THIS dict, so get_icon returned null forever -> grey boxes in the shop/stash.
	"key_tower":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.06, 0.15),
		"color": Color(0.85, 0.7, 0.3)
	},
	"key_lodge":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.06, 0.15),
		"color": Color(0.55, 0.8, 0.95)
	},
	"key_temple":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.06, 0.15),
		"color": Color(0.9, 0.35, 0.25)
	},
	"loot_flare":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.12, 0.4, 0.12),
		"color": Color(0.7, 0.4, 1.0)
	},
	"loot_bandage":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.22, 0.14, 0.22),
		"color": Color(0.92, 0.9, 0.85)
	},
	"loot_splint":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.14, 0.42, 0.12),
		"color": Color(0.72, 0.55, 0.3)
	},
	"loot_painkiller":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.15, 0.24, 0.15),
		"color": Color(0.95, 0.6, 0.2)
	},
	"armor_helmet_t1":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.42, 0.3, 0.42),
		"color": Color(0.5, 0.52, 0.4)
	},
	"armor_helmet_t2":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.44, 0.32, 0.44),
		"color": Color(0.35, 0.4, 0.48)
	},
	"armor_vest_t1":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.42, 0.55, 0.2),
		"color": Color(0.45, 0.47, 0.36)
	},
	"armor_vest_t2":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.44, 0.58, 0.22),
		"color": Color(0.32, 0.36, 0.42)
	},
	"armor_pack_med":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.42, 0.55, 0.3),
		"color": Color(0.55, 0.45, 0.3)
	},
	"armor_pack_large":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.46, 0.66, 0.34),
		"color": Color(0.45, 0.38, 0.28)
	},
	"loot_plastic":
	{
		# --- Expansion: salvage materials + valuables (colored-box fallback; no icons yet) ---
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.35, 0.25, 0.35),
		"color": Color(0.82, 0.82, 0.86)
	},
	"loot_chemicals":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.3, 0.45, 0.3),
		"color": Color(0.6, 0.85, 0.25)
	},
	"loot_circuit":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.35, 0.08, 0.3),
		"color": Color(0.25, 0.7, 0.55)
	},
	"loot_artifact":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.35, 0.35, 0.35),
		"color": Color(0.7, 0.35, 0.85)
	},
	"loot_data_chip":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.25, 0.04, 0.18),
		"color": Color(0.3, 0.85, 0.9)
	},
	"loot_stim":
	{
		# --- Crafted gear + schematics (colored-box fallback) ---
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.2, 0.4, 0.2),
		"color": Color(0.3, 0.9, 0.6)
	},
	"loot_self_revive":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.34, 0.24, 0.34),
		"color": Color(0.95, 0.45, 0.45)
	},
	"loot_knockdown_shield":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.36, 0.4, 0.1),
		"color": Color(0.55, 0.7, 0.95)
	},
	"loot_grenade_mk2":
	{
		"model": "",
		"icon": "",
		"prim": Prim.SPHERE,
		"size": Vector3(0.32, 0.32, 0.32),
		"color": Color(0.2, 0.5, 0.25)
	},
	"loot_circuit_pack":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.4, 0.12, 0.3),
		"color": Color(0.2, 0.75, 0.6)
	},
	"schematic_ammo":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.35, 0.55, 0.95)
	},
	"schematic_stim":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.35, 0.55, 0.95)
	},
	"schematic_circuit_pack":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.35, 0.55, 0.95)
	},
	"schematic_grenade_mk2":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.45, 0.45, 0.95)
	},
	"att_scope_4x":
	{
		# --- Weapon attachments (colored-box fallback) ---
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.12, 0.3, 0.12),
		"color": Color(0.2, 0.25, 0.32)
	},
	"att_ext_mag":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.14, 0.3, 0.1),
		"color": Color(0.4, 0.42, 0.45)
	},
	"att_compensator":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.1, 0.18, 0.1),
		"color": Color(0.55, 0.55, 0.58)
	},
	"att_holo_sight":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.12, 0.14, 0.12),
		"color": Color(0.22, 0.3, 0.4)
	},
	"att_red_dot":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.1, 0.12, 0.1),
		"color": Color(0.25, 0.32, 0.42)
	},
	"att_drum_mag":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.2, 0.16, 0.2),
		"color": Color(0.36, 0.38, 0.42)
	},
	"att_light_mag":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.12, 0.24, 0.09),
		"color": Color(0.46, 0.48, 0.5)
	},
	"att_mag_shock":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.13, 0.28, 0.1),
		"color": Color(0.3, 0.7, 0.95)
	},
	"att_mag_incendiary":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.13, 0.28, 0.1),
		"color": Color(0.9, 0.45, 0.14)
	},
	"att_mag_cryo":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.13, 0.28, 0.1),
		"color": Color(0.72, 0.88, 1.0)
	},
	"att_long_barrel":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.08, 0.4, 0.08),
		"color": Color(0.5, 0.5, 0.54)
	},
	"att_suppressor":
	{
		"model": "",
		"icon": "",
		"prim": Prim.CYLINDER,
		"size": Vector3(0.1, 0.28, 0.1),
		"color": Color(0.3, 0.3, 0.33)
	},
	"att_heavy_grip":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.1, 0.16, 0.12),
		"color": Color(0.4, 0.36, 0.32)
	},
	"att_quickdraw_grip":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.1, 0.16, 0.12),
		"color": Color(0.45, 0.42, 0.36)
	},
	"schematic_drum_mag":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.4, 0.5, 0.95)
	},
	"schematic_suppressor":
	{
		"model": "",
		"icon": "",
		"prim": Prim.BOX,
		"size": Vector3(0.3, 0.02, 0.22),
		"color": Color(0.4, 0.5, 0.95)
	},
}


func has_id(id: String) -> bool:
	return CATALOG.has(id)


## Returns a fresh Node3D containing the model for `id` (CC0 if present, else primitive).
## CC0 art is wrapped in a transform-carrying root so per-asset scale/rotation/offset
## from the CATALOG make it fit the capsule `size`. Hitboxes are never touched here.
func get_model(id: String, cosmetics: Dictionary = {}) -> Node3D:
	# The PLAYER is a procedural modular robot assembled from cosmetic part ids (head/
	# torso/arms/legs/paint) so it can be customized + swapped per peer. (Was a baked glb.)
	if id == "player":
		return ProceduralPlayer.build_player(cosmetics)
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
			xform.basis = (
				Basis.from_euler(Vector3(deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z)))
				* xform.basis
			)
		xform.origin = entry.get("model_offset", Vector3.ZERO)
		n3d.transform = xform
	var albedo: Variant = entry.get("model_albedo", null)
	if albedo is Color:
		_retint_untextured(glb, albedo)
	# De-toy pass: the orange RobotExpressive mascot (grunt/heavy) → dark gunmetal machine.
	if bool(entry.get("reskin_machine", false)):
		_machine_reskin(glb, entry.get("color", Color(0.6, 0.6, 0.6)))
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


## Re-skin a "toy" robot GLB (the orange Godot RobotExpressive mascot, used by grunt/heavy)
## into a menacing dark MACHINE: dark desaturated gunmetal on the body (faint identity tint +
## real metallic/roughness), HOT emissive accent on any eye/emissive surface (the "cold world +
## one hot accent" signature). Per-surface overrides (the _retint_untextured pattern) so the
## hit-flash still collects + duplicates them per instance. Visual only.
func _machine_reskin(node: Node, ident: Color) -> void:
	if node is MeshInstance3D:
		# material_override (not surface overrides) — the RobotExpressive parts carry their own
		# material_override which outranks surface overrides, so only this beats the toy colormap.
		# It's also exactly what the hit-flash collects + duplicates per instance.
		(node as MeshInstance3D).material_override = _machine_mat(ident)
	for c in node.get_children():
		_machine_reskin(c, ident)


## The dark gunmetal MACHINE material: a cool desaturated steel faintly tinted toward the
## enemy's identity hue, with real metallic/roughness so it reads as worn metal (not flat toy
## plastic). One fresh instance per part per enemy (the hit-flash duplicate contract).
func _machine_mat(ident: Color) -> StandardMaterial3D:
	var d := StandardMaterial3D.new()
	# DARK gunmetal hull faintly carrying the identity hue (art-panel "kill the
	# salmon", exact formula: ident.lerp(gunmetal, 0.75) — the old mid-grey ×
	# warm-lift lerp read as pink vinyl under AgX).
	d.albedo_color = ident.lerp(Color(0.15, 0.16, 0.19), 0.75)
	# Real machine metal: harder metallic, tighter roughness so plates catch the sun.
	d.metallic = 0.6
	d.roughness = 0.45
	d.metallic_specular = 0.4
	# NO body emission. LESSON (two failed takes): ANY whole-surface emission tints
	# the entire silhouette into a flat glow blob — with one material_override per
	# part, per-part "eye" isolation is impossible, so threat color lives in the
	# dark-tinted albedo instead. A dark machine never goes pure-black thanks to the
	# metallic sky response.
	d.emission_enabled = false
	return d


# Merged-static-model cache: id -> ArrayMesh (or null when the model can't merge).
var _merged_cache: Dictionary = {}


## MERGED static model for HIGH-COUNT world props (loot pickups): the id's multi-part
## model collapsed into ONE MeshInstance3D with one ArrayMesh surface per material —
## ~100 pickups × ~4 parts stop costing a draw call per part. The ArrayMesh (with its
## materials embedded) is cached per id and SHARED by every pickup, so this is only
## safe for static visuals that never mutate materials per instance (loot never
## hit-flashes; its rarity glow is an OmniLight). Falls back to get_model() when the
## model has nothing mergeable (e.g. a skinned .glb).
func get_model_merged(id: String) -> Node3D:
	if not _merged_cache.has(id):
		_merged_cache[id] = _merge_model(id)
	var mesh: ArrayMesh = _merged_cache[id]
	if mesh == null:
		return get_model(id)
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	return root


func _merge_model(id: String) -> ArrayMesh:
	var src: Node3D = get_model(id)
	if src == null:
		return null
	var by_mat: Dictionary = {}  # Material -> SurfaceTool
	_collect_merge_surfaces(src, Transform3D.IDENTITY, by_mat)
	src.free()
	if by_mat.is_empty():
		return null
	var arr := ArrayMesh.new()
	for mat in by_mat:
		var st: SurfaceTool = by_mat[mat]
		st.commit(arr)
		arr.surface_set_material(arr.get_surface_count() - 1, mat)
	return arr


func _collect_merge_surfaces(n: Node, xf: Transform3D, by_mat: Dictionary) -> void:
	var local: Transform3D = xf
	if n is Node3D:
		local = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var mat: Material = mi.get_active_material(s)
				if not by_mat.has(mat):
					var st := SurfaceTool.new()
					st.begin(Mesh.PRIMITIVE_TRIANGLES)
					by_mat[mat] = st
				(by_mat[mat] as SurfaceTool).append_from(mi.mesh, s, local)
	for c in n.get_children():
		_collect_merge_surfaces(c, local, by_mat)


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
