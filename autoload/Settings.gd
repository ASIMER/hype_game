extends Node
## Tunable constants + simple runtime settings. Centralized so designers/agents
## tweak balance in one place instead of hunting through scenes.

# Networking
const DEFAULT_PORT: int = 24565
const MAX_PLAYERS: int = 4
const DEFAULT_IP: String = "127.0.0.1"
# When true, the netcode emits [net]/[arena]/[client] diagnostic prints (connection,
# roster sync, spawn/replication). Off for normal play; flip on to debug co-op.
const NET_DEBUG: bool = false

# Agent self-play harness: in-game TCP control server port (localhost). Only
# listens when the game is launched with --agent (see AgentBridge / main.gd).
const AGENT_PORT: int = 24700

# Player
const PLAYER_MAX_HEALTH: float = 100.0
const PLAYER_MOVE_SPEED: float = 5.5
const PLAYER_SPRINT_SPEED: float = 8.5
const PLAYER_JUMP_VELOCITY: float = 7.0
const MOUSE_SENSITIVITY: float = 0.0025
const CAMERA_PITCH_MIN: float = -1.2
const CAMERA_PITCH_MAX: float = 0.6

# Combat
const WEAPON_NET_REPLICATION_HZ: float = 30.0

# Enemy
const ENEMY_MAX_HEALTH: float = 40.0
const ENEMY_DETECT_RADIUS: float = 18.0
# Melee strike distance. Must be short so robots CHASE up to the player before
# attacking; a large value lets them deal damage from across the arena (they hold
# position and strike when in ATTACK state — see robot_enemy._do_attack).
const ENEMY_ATTACK_RANGE: float = 2.2
const ENEMY_MOVE_SPEED: float = 4.0     # close distance faster -> pressure (player walk 5.5)
const ENEMY_DAMAGE: float = 8.0
const ENEMY_ATTACK_COOLDOWN: float = 1.2

# Inventory
const INVENTORY_COLS: int = 6
const INVENTORY_ROWS: int = 5
const INVENTORY_MAX_WEIGHT: float = 50.0

# Extraction
const EXTRACTION_TIME: float = 8.0
# Timed extraction windows (ExtractionDirector rotates which zone is open). A zone
# is open OPEN_DURATION then closed COOLDOWN before the next zone opens; only an
# OPEN zone makes extraction progress. STAGGER opens zones at offset phases so the
# map shows several with different countdowns.
const EXTRACT_OPEN_DURATION: float = 75.0
const EXTRACT_COOLDOWN: float = 35.0
const EXTRACT_WINDOW_STAGGER: float = 28.0

# Match timer — the raid has a hard time budget. When it expires the FINAL "storm"
# wave begins (see WaveManager) and forces extraction. Gradual wave progression is
# preserved up to that point.
const MATCH_DURATION: float = 540.0          # 9 minutes
const FINAL_WAVE_WARN: float = 30.0          # warn the player this many seconds before
const FINAL_WAVE_COUNT_MULT: float = 3.5     # storm wave size vs a normal late wave
const FINAL_WAVE_CONCURRENT: int = 18        # storm raises the alive-cap hard
const FINAL_WAVE_SPAWN_INTERVAL: float = 0.5 # and spawns much faster

# Atmosphere / mood — ambient particle density + how long the day→storm visual
# transition takes when the final wave begins (world_atmosphere.gd reads these).
const ATMOSPHERE_DUST := 90       # ambient dust-mote particle count
const ATMOSPHERE_EMBERS := 40     # drifting ember particle count
const STORM_TWEEN_TIME := 6.0     # seconds to lerp sky/fog/light into the storm look

# Ballistics — shots now arc under gravity (bullet drop). The shot is resolved as a
# stepped raycast along the trajectory; per-weapon muzzle velocity may override.
const BULLET_GRAVITY: float = 9.8            # m/s² downward on the projectile
const BULLET_MUZZLE_VELOCITY: float = 120.0  # m/s default (high = flat; low = droppy)
const BULLET_STEP: float = 2.5               # metres per ballistic raycast segment

# Waves — spawns are STAGGERED (a steady trickle, capped concurrency) rather than
# dumped all at once, so late waves stay beatable-but-challenging instead of an
# instant swarm. Total enemies per wave = WAVE_BASE_ENEMIES + (wave-1)*GROWTH.
const WAVE_BASE_ENEMIES: int = 3
const WAVE_ENEMY_GROWTH: int = 2
const WAVE_INTERMISSION: float = 6.0
const WAVE_MAX_CONCURRENT: int = 6      # never more than this many alive at once
const WAVE_SPAWN_INTERVAL: float = 1.2  # seconds between trickle spawns

# Camera / ADS / peek
const DEFAULT_FOV: float = 60.0
const ADS_FOV: float = 42.0             # zoomed FOV when aiming (per-weapon may override)
const ADS_SENS_SCALE: float = 0.5       # look sensitivity multiplier while aiming
const ADS_SPRING_LENGTH: float = 2.0    # camera pulled in when aiming
const DEFAULT_SPRING_LENGTH: float = 4.0
const SHOULDER_OFFSET: float = 0.5      # over-the-shoulder camera x-offset (flipped by swap)
const AIM_TWEEN_SPEED: float = 10.0     # lerp speed for fov/length/offset
const PEEK_PROBE: float = 1.4           # side-raycast distance to detect a wall to lean past
const PEEK_SHIFT: float = 0.7           # extra lateral camera shift when leaning out

# Weapons
const WEAPON_SWITCH_TIME: float = 0.35

# Healing / gadgets
const HEAL_AMOUNT: float = 45.0
const HEAL_TIME: float = 1.4
const GRENADE_DAMAGE: float = 70.0
const GRENADE_RADIUS: float = 5.5
const GRENADE_FUSE: float = 1.6
const GRENADE_THROW_FORCE: float = 15.0

# Per-enemy archetype stats (read by enemies-dev / robot_enemy). Falls back to the
# legacy ENEMY_* constants above for "robot_grunt". flying/ranged are behaviour flags.
const ENEMY_STATS := {
	"robot_grunt":   { "health": 40.0,  "speed": 4.0, "damage": 8.0,  "detect": 18.0, "attack_range": 2.2,  "cooldown": 1.2,  "score": 10 },
	"robot_heavy":   { "health": 95.0,  "speed": 2.8, "damage": 14.0, "detect": 18.0, "attack_range": 2.6,  "cooldown": 1.6,  "score": 25 },
	"robot_tick":    { "health": 14.0,  "speed": 6.6, "damage": 5.0,  "detect": 22.0, "attack_range": 1.6,  "cooldown": 0.8,  "score": 6 },
	"robot_wasp":    { "health": 22.0,  "speed": 5.2, "damage": 6.0,  "detect": 26.0, "attack_range": 15.0, "cooldown": 1.4,  "score": 14, "flying": true, "hover": 4.5, "ranged": true },
	"robot_bastion": { "health": 170.0, "speed": 2.2, "damage": 10.0, "detect": 28.0, "attack_range": 20.0, "cooldown": 0.25, "score": 45, "ranged": true, "burst": true },
	"robot_boss":    { "health": 650.0, "speed": 2.6, "damage": 22.0, "detect": 45.0, "attack_range": 22.0, "cooldown": 0.4,  "score": 250, "ranged": true },
}

# Difficulty multipliers, keyed by GameState.Difficulty. enemy_health/enemy_damage
# scale per-enemy stats (robot_enemy._load_stats); enemy_count scales the wave size
# (wave_manager._enemy_count_for_wave); player_damage scales outgoing weapon damage
# (a small assist on Easy / handicap on Hard). Normal is the 1.0 baseline.
const DIFFICULTY_MODS := {
	0: { "enemy_health": 0.72, "enemy_damage": 0.70, "enemy_count": 0.75, "player_damage": 1.25 }, # EASY
	1: { "enemy_health": 1.00, "enemy_damage": 1.00, "enemy_count": 1.00, "player_damage": 1.00 }, # NORMAL
	2: { "enemy_health": 1.40, "enemy_damage": 1.30, "enemy_count": 1.30, "player_damage": 0.90 }, # HARD
}

## Returns the multiplier dict for a GameState.Difficulty value (falls back to Normal).
func difficulty_mods(d: int = -1) -> Dictionary:
	if d < 0:
		d = GameState.difficulty
	return DIFFICULTY_MODS.get(d, DIFFICULTY_MODS[1])

# Sprint stamina + interaction range.
const MAX_STAMINA: float = 100.0
const STAMINA_DRAIN: float = 28.0      # per second while sprinting
const STAMINA_REGEN: float = 22.0      # per second while not sprinting
const STAMINA_SPRINT_MIN: float = 10.0 # need at least this to start sprinting
const INTERACT_RANGE: float = 3.5      # metres for the "[E]" prompt

# Runtime-mutable settings (driven by SettingsManager / the settings menu).
var mouse_sensitivity: float = MOUSE_SENSITIVITY
var fov: float = DEFAULT_FOV            # camera FOV (player.gd reads this)
var sfx_volume: float = 0.9             # 0..1, applied to AudioManager
var invert_y: bool = false
var ads_toggle: bool = false            # false = hold to aim, true = toggle

# --- Multi-instance (parallel agent testing) -------------------------------
# To run 2–4 game instances at once (each driven by its own agent) the agent
# control port AND the shared user:// files must be per-instance. Launch with
# `--agent-port N`: agent_port=N and instance_tag="N". Without the flag the
# defaults preserve single-instance behaviour (port 24700, un-suffixed user://).
# Resolved once at startup; Settings autoloads before AgentBridge / MetaProgression
# / SettingsManager so they can read these safely.
var agent_port: int = AGENT_PORT
var instance_tag: String = ""

func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var idx := args.find("--agent-port")
	if idx != -1 and idx + 1 < args.size():
		var raw := args[idx + 1]
		if not raw.begins_with("--") and raw.is_valid_int():
			agent_port = int(raw)
			instance_tag = str(agent_port)

## Per-instance user:// path. Single instance → `user://<base>.<ext>`; under
## `--agent-port N` → `user://<base>_N.<ext>`, so concurrent instances never clobber
## each other's saves/screenshots.
func user_path(base: String, ext: String) -> String:
	if instance_tag == "":
		return "user://%s.%s" % [base, ext]
	return "user://%s_%s.%s" % [base, instance_tag, ext]
