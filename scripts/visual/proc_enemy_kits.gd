class_name ProcEnemyKits
extends RefCounted
## Per-enemy MATERIAL KITS for the model-quality overhaul: ONE table defines every
## procedural enemy's palette (desaturated military/industrial hues with value
## contrast — the anti-"toy" pass) + plating archetype; kit() assembles the five
## shared material roles every builder consumes:
##   hull   — the painted plated shell (ProcPlating bake)
##   frame  — rubber joints/underbelly/cabling (contrast against the painted hull)
##   steel  — bare worn metal: barrels, claws, blades, drills
##   accent — the enemy's IDENTITY hue (AssetRegistry color) as restrained paint
##   glow   — the emissive core/eye material (v2 energy 2.5-3.5, down from neon 6.0)
## Fresh material instances per call (the hit-flash duplicate contract); textures
## cached inside ProcPlating/ProcMaterials.
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

# id: [hull Color, secondary Color, Arch, sid, glow_energy]
# glow_energy 3.5 = gameplay signage (kill windows / weak domes / arming blinks);
# 2.5-3.0 = ambient identity glow.
#
# D2 PALETTE — TWO-TONE, and this is the whole point of the table.
# The photostand measured every machine at 0.12-0.24 mean luma in a NEUTRALLY LIT isolated
# render (mean target: 0.45). They were not dark because of the grade or the weather — the
# hulls were simply painted mid-charcoal, so a machine could only ever read as a silhouette.
# Every hull here now sits in the LIGHT band (luma ~0.68-0.80, i.e. above the grade's warm
# threshold so it keeps its own hue) and every secondary sits near-black (~0.12-0.17). That
# pairing — light plate over black frame — is the readable-machine formula, and it needs no
# builder changes at all: `hull` already covers the big plates and `secondary` the joints,
# cabling and underbelly, so the two roles were already the 60/30 of a 60/30/10 split.
# IDENTITY still lives where it belongs: the accent (AssetRegistry colour, the 10%) and the
# emissive eye. Hulls vary by BIOME instead of by unit — bone-warm urban, sand desert,
# cold-white snow, damp-warm rain — so a quadrant reads as a place, not a colour swatch.
const _SPECS: Dictionary = {
	# v0.5-B4: the starter troopers (rebuilt procedural — were the last .glb enemies).
	"robot_grunt":
	[Color(0.76, 0.74, 0.69), Color(0.13, 0.135, 0.15), ProcPlating.Arch.MECH_HULL, 137, 3.5],
	"robot_heavy":
	[Color(0.74, 0.7, 0.645), Color(0.125, 0.12, 0.12), ProcPlating.Arch.ARMOR_PLATE, 139, 3.5],
	"robot_elite":
	[Color(0.79, 0.78, 0.755), Color(0.13, 0.13, 0.145), ProcPlating.Arch.ARMOR_PLATE, 149, 3.5],
	"robot_tick":
	[Color(0.71, 0.735, 0.74), Color(0.115, 0.125, 0.135), ProcPlating.Arch.MECH_HULL, 11, 2.5],
	"robot_wasp":
	[Color(0.7, 0.715, 0.745), Color(0.1, 0.105, 0.12), ProcPlating.Arch.MECH_HULL, 23, 3.0],
	"robot_bastion":
	[Color(0.78, 0.7, 0.645), Color(0.135, 0.13, 0.14), ProcPlating.Arch.ARMOR_PLATE, 31, 3.5],
	"robot_boss":
	[Color(0.72, 0.715, 0.735), Color(0.115, 0.11, 0.13), ProcPlating.Arch.ARMOR_PLATE, 47, 3.5],
	"robot_caller":
	[Color(0.79, 0.76, 0.665), Color(0.14, 0.135, 0.12), ProcPlating.Arch.MECH_HULL, 53, 3.0],
	"robot_sandworm":
	[Color(0.8, 0.735, 0.615), Color(0.135, 0.12, 0.105), ProcPlating.Arch.MECH_HULL, 41, 3.5],
	"robot_scarab":
	[Color(0.81, 0.7, 0.55), Color(0.14, 0.115, 0.09), ProcPlating.Arch.MECH_HULL, 59, 3.5],
	"robot_dustdevil":
	[Color(0.79, 0.745, 0.655), Color(0.15, 0.135, 0.11), ProcPlating.Arch.ARMOR_PLATE, 61, 2.5],
	"robot_frosthound":
	[Color(0.8, 0.825, 0.845), Color(0.145, 0.155, 0.17), ProcPlating.Arch.ARMOR_PLATE, 67, 2.5],
	"robot_cryomortar":
	[Color(0.755, 0.79, 0.82), Color(0.13, 0.14, 0.155), ProcPlating.Arch.MECH_HULL, 71, 3.0],
	"robot_avalanche":
	[Color(0.83, 0.845, 0.865), Color(0.155, 0.16, 0.175), ProcPlating.Arch.ARMOR_PLATE, 73, 3.0],
	"robot_oni":
	[Color(0.755, 0.665, 0.635), Color(0.135, 0.12, 0.125), ProcPlating.Arch.LACQUER, 79, 3.0],
	"robot_kappa":
	[Color(0.71, 0.755, 0.715), Color(0.115, 0.13, 0.12), ProcPlating.Arch.MECH_HULL, 83, 2.5],
	"robot_raiju":
	[Color(0.715, 0.735, 0.79), Color(0.115, 0.12, 0.14), ProcPlating.Arch.MECH_HULL, 89, 3.0],
	"robot_snow_golem":
	[Color(0.81, 0.83, 0.86), Color(0.15, 0.155, 0.17), ProcPlating.Arch.ARMOR_PLATE, 97, 3.5],
	"robot_dune_warden":
	[Color(0.82, 0.73, 0.585), Color(0.145, 0.125, 0.1), ProcPlating.Arch.ARMOR_PLATE, 101, 3.5],
	"robot_oni_chief":
	[Color(0.775, 0.675, 0.645), Color(0.14, 0.12, 0.125), ProcPlating.Arch.LACQUER, 103, 3.5],
	"robot_specter":
	[Color(0.71, 0.7, 0.755), Color(0.115, 0.11, 0.135), ProcPlating.Arch.MECH_HULL, 107, 3.0],
	# Gadgets share the kit pipeline (deployables are friendly "enemy-grade" hardware).
	"gadget_turret":
	[Color(0.72, 0.755, 0.735), Color(0.12, 0.13, 0.125), ProcPlating.Arch.ARMOR_PLATE, 113, 3.0],
	"gadget_dome":
	[Color(0.71, 0.745, 0.78), Color(0.115, 0.125, 0.14), ProcPlating.Arch.MECH_HULL, 127, 3.0],
	"gadget_sensor":
	[Color(0.765, 0.75, 0.715), Color(0.13, 0.13, 0.12), ProcPlating.Arch.MECH_HULL, 131, 3.0],
}


## The five-material kit for `id` (see header). Unknown ids get a neutral grey kit so
## a new enemy is never invisible — register a real spec in _SPECS when adding one.
static func kit(id: String) -> Dictionary:
	var spec: Array = _SPECS.get(
		id, [Color(0.35, 0.36, 0.38), Color(0.16, 0.17, 0.18), ProcPlating.Arch.MECH_HULL, 7, 3.0]
	)
	var hull_col: Color = spec[0]
	var sec_col: Color = spec[1]
	var arch: int = spec[2]
	var sid: int = spec[3]
	var energy: float = spec[4]
	var ident: Color = AssetRegistry.get_color(id)
	return {
		"hull": _rimmed(ProcPlating.plated(hull_col, arch, sid)),
		"frame": ProcPlating.rubber(sec_col, sid + 1),
		"steel": ProcPlating.steel(),
		"accent": _accent(ident),
		"glow": ProcPlating.glow(ident, energy),
	}


## Cheap fresnel RIM on the painted shell: grazing angles pick up a light edge, so a
## machine keeps a readable silhouette against fog, forest and the cold grade instead of
## melting into them. Pure lighting — it does NOT disturb the neutral-bake × albedo_color
## tint pattern (rim is added after the albedo term) nor the hit-flash duplicate contract.
static func _rimmed(m: StandardMaterial3D) -> StandardMaterial3D:
	m.rim_enabled = true
	m.rim = 0.28
	m.rim_tint = 0.6
	return m


## The identity hue as RESTRAINED paint (×0.85 value, modest metal/rough) — keeps each
## enemy recognisable without the old full-saturation toy read.
static func _accent(ident: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(ident.r * 0.85, ident.g * 0.85, ident.b * 0.85, 1.0)
	m.metallic = 0.3
	m.roughness = 0.5
	return m
