## Magic-string contracts (docs/AUDIT.md F7): scene groups + load-bearing child-node
## names. A typo'd literal compiles fine and silently skips damage/credit/registration
## (get_node_or_null → null → skip; an unknown group is just empty) — referencing these
## consts from CODE turns that class of bug into a compile-time error.
## NOTE: .tscn files still declare groups as plain strings (scenes can't reference
## consts) — these values are therefore FROZEN: renaming one means touching scenes too.
class_name Groups

const PLAYERS := "players"
const ENEMIES := "enemies"
const EXTRACTION := "extraction"
const ARENA := "arena"
const WORLD_EVENTS := "world_events"
const PICKUPS := "pickups"
const SMOKE := "smoke_clouds"  # active smoke-grenade clouds (enemy LOS test)
const DOMES := "shield_domes"  # active shield-dome gadgets (damage-mult test)
const WAVE_MANAGER := "wave_manager"  # the per-match WaveManager registers itself
const LOCKED_DOORS := "locked_doors"  # key-gated annex doors (batch C)
const NIGHT_LIGHTS := "night_lights"  # street-lamp OmniLights driven by the day-night ramp
const BREAKABLE_GLASS := "breakable_glass"  # window panes a bullet/blast can shatter
const BREAKABLE_CHUNK := "breakable_chunk"  # building wall segments a bullet/blast can crumble
const NEMESIS := "nemesis"  # the active Machine Nemesis (map marker + kill-payoff lookup)
const POWER_CORE := "power_core"  # a boss/miniboss-dropped carriable beacon (map marker)

# Load-bearing child-node names (get_node_or_null targets on players/enemies).
const NODE_HEALTH := "Health"
const NODE_HURTBOX := "Hurtbox"
const NODE_WEAKPOINT := "WeakPoint"
const NODE_MODEL_ROOT := "ModelRoot"
