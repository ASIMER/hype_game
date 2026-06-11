## The ONE definition of the world rectangle (v0.3 4× expansion): X,Z ∈ [−80, 240],
## centre (80,80), edge 320. The original 160×160 map is the NW quadrant. Everything
## that needs map bounds reads THESE consts — terrain mesh/berm, flora scatter, the
## tactical-map projection, atmosphere emission boxes, worm burrow clamp, the biome
## split (docs/AUDIT.md F3: these used to live in 5 files). A future map resize is an
## edit HERE only — then re-verify navmesh/walls and re-capture the golden snapshot.
class_name WorldBounds

const X_MIN: float = -80.0
const X_MAX: float = 240.0
const Z_MIN: float = -80.0
const Z_MAX: float = 240.0
const SPAN: float = 320.0  # full edge length (== X_MAX - X_MIN == Z_MAX - Z_MIN)
const CX: float = 80.0  # rectangle centre X
const CZ: float = 80.0  # rectangle centre Z


## Biome quadrant at a world position — the split runs along the centre lines:
## NW urban (the original map), NE snow, SW desert, SE rain. Drives the
## biome-exclusive enemy pools (wave_manager) and matches the climate zones.
static func biome_at(x: float, z: float) -> String:
	if x < CX:
		return "urban" if z < CZ else "desert"
	return "snow" if z < CZ else "rain"
