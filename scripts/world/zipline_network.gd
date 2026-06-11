extends Node3D
## ZiplineNetwork — authors the set of traversable ziplines across the map.
##
## Root script of Ziplines.tscn. Holds the authored anchor pairs (XZ from the POI map
## + a per-anchor HEIGHT OFFSET `dy` above terrain) and, at `_ready`, resolves each
## anchor's final Y from `ProceduralTerrain.height_at` + dy, then instances one Zipline
## child per pair via `Zipline.setup(a, b)`.
##
## Cables slope DOWNWARD where it reads well (tower roof high → plaza low). Endpoints
## are render/interaction only (each Zipline's mount areas are layer 0), so this whole
## subtree never touches the navmesh bake or the golden world snapshot.

const _ZIPLINE := preload("res://scripts/world/zipline.gd")

## Authored cables. `a`/`b` carry world XZ + a HEIGHT OFFSET (dy) above terrain; the
## final world Y is resolved in _ready as height_at(x, z) + dy.
const LINES: Array[Dictionary] = [
	{
		a = Vector3(-40.0, 14.0, -45.0),  # NorthTower roof
		b = Vector3(0.0, 4.0, 0.0),  # central Plaza
		name = "NorthTower-Plaza",
	},
	{
		a = Vector3(160.0, 13.0, 158.0),  # Temple upper deck
		b = Vector3(205.0, 4.0, 205.0),  # ShrineHouse
		name = "Temple-ShrineHouse",
	},
	{
		a = Vector3(160.0, 12.0, -10.0),  # SnowLodge roof
		b = Vector3(205.0, 4.0, 40.0),  # SnowDepot
		name = "SnowLodge-SnowDepot",
	},
	{
		a = Vector3(0.0, 12.0, 158.0),  # DesertRuins high wall
		b = Vector3(45.0, 4.0, 205.0),  # RuinColumns
		name = "DesertRuins-RuinColumns",
	},
	{
		a = Vector3(45.0, 11.0, -28.0),  # EastWarehouse roof
		b = Vector3(50.0, 4.0, 42.0),  # EastYard
		name = "EastWarehouse-EastYard",
	},
]


func _ready() -> void:
	for line in LINES:
		var a: Vector3 = line.get("a", Vector3.ZERO)
		var b: Vector3 = line.get("b", Vector3.ZERO)
		var world_a := Vector3(a.x, _resolve_y(a.x, a.y, a.z), a.z)
		var world_b := Vector3(b.x, _resolve_y(b.x, b.y, b.z), b.z)

		var zip := Node3D.new()
		zip.set_script(_ZIPLINE)
		zip.name = "Zipline_%s" % String(line.get("name", "line"))
		add_child(zip)
		zip.call("setup", world_a, world_b)


## Final world Y for an anchor = terrain height at (x, z) + the authored offset dy.
func _resolve_y(x: float, dy: float, z: float) -> float:
	return ProceduralTerrain.height_at(x, z) + dy
