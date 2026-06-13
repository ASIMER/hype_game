class_name NetThrowables
## The Net/GadgetSpawner's custom spawn_function (wired in arena.gd, the LootSpawner
## pattern): ONE dispatcher for everything the server spawns under Arena/Net/Gadgets —
## thrown grenades (all types) and placed deployable gadgets. Runs on EVERY peer with
## the replicated spawn data, so each builds the identical node; the server instance
## is the only one whose gameplay effects fire (the scripts gate themselves).

const GRENADE_SCENES := {
	"frag": "res://scenes/items/Grenade.tscn",
	"smoke": "res://scenes/items/GrenadeSmoke.tscn",
	"emp": "res://scenes/items/GrenadeEmp.tscn",
	"decoy": "res://scenes/items/GrenadeDecoy.tscn",
	"incendiary": "res://scenes/items/GrenadeIncendiary.tscn",
	"cryo": "res://scenes/items/GrenadeCryo.tscn",
}


static func spawn(data: Dictionary) -> Node:
	var kind := String(data.get("kind", ""))
	if kind == "gadget":
		return GadgetBase._spawn_gadget(data)
	# Grenade: instantiate the type's scene and throw with the replicated initial
	# conditions — every peer simulates the same projectile locally (minor visual
	# divergence between peers is acceptable, same as the original frag).
	var type := String(data.get("type", "frag"))
	var path := String(GRENADE_SCENES.get(type, GRENADE_SCENES["frag"]))
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var nade: Node = packed.instantiate()
	var from: Vector3 = data.get("from", Vector3.ZERO)
	var dir: Vector3 = data.get("dir", Vector3.FORWARD)
	var force: float = float(data.get("force", Settings.GRENADE_THROW_FORCE))
	if nade.has_method("throw"):
		# Deferred: the spawner parents the node right after we return; throw() needs
		# the body in-tree to set its global transform + impulse.
		nade.call_deferred("throw", from, dir, force)
	return nade
