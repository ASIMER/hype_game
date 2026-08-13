extends Node
## Tunable constants + simple runtime settings. Centralized so designers/agents
## tweak balance in one place instead of hunting through scenes.

# Networking
const DEFAULT_PORT: int = 24565
const MAX_PLAYERS: int = 8  # listen-server cap; "however many friends join" (ENet-safe)
const DEFAULT_IP: String = "127.0.0.1"
## UDP port the host answers LAN-discovery pings on (separate from the ENet game port
## so it doesn't fight the ENet socket). ServerBrowser broadcasts here to find servers.
const DISCOVERY_PORT: int = 24566
## Game build version (canonical = the VERSION file at the repo root). Stamped into
## save files so loads survive game updates (see MetaProgression/Stash version checks).
const GAME_VERSION: String = "0.4.1"
## Max number of non-daily contracts the player can have ACTIVE (accepted) at once.
## Manual-accept enforces it; dailies are exempt.
const ACTIVE_QUEST_CAP: int = 6
## Quest random-pool offering (Iteration 2): how many weighted random contracts the
## QuestDirector offers per successful raid, and the cap on simultaneously-AVAILABLE
## (offered-but-not-accepted) contracts so the board never floods.
const RANDOM_OFFER_PER_RAID: int = 1
const AVAILABLE_OFFER_CAP: int = 4

## Per-giver reputation (Iteration 3). Shared tier thresholds for every giver; a contract
## claimed for a giver grants GIVER_REP_BASELINE_ON_CLAIM even without an explicit reward.
## GIVER_REP_TIER_REWARDS[tier] = { currency, cosmetic } granted once on crossing that tier.
const GIVER_REP_TIERS := [0, 3, 7, 12, 18]
const GIVER_REP_BASELINE_ON_CLAIM: int = 1
const GIVER_REP_TIER_REWARDS := {
	1: {"currency": 200},
	2: {"currency": 400},
	3: {"currency": 700},
	4: {"currency": 1200},
}
# When true, the netcode emits [net]/[arena]/[client] diagnostic prints (connection,
# roster sync, spawn/replication). Off for normal play; flip on to debug co-op.
const NET_DEBUG: bool = false

# Agent self-play harness: in-game TCP control server port (localhost). Only
# listens when the game is launched with --agent (see AgentBridge / main.gd).
const AGENT_PORT: int = 24700

# Terrain / world visuals (ALL world-gen must stay deterministic for co-op — every
# peer builds its own arena locally, so geometry derives ONLY from these constants).
const TERRAIN_SEED: int = 1337  # the one seed all terrain noise derives from
const TERRAIN_CELL: float = 1.0  # heightmap grid step (m); 1 m = smooth river banks
const TERRAIN_HILL_AMP: float = 3.5  # max rolling-hill height (m); keep slopes well under 47°
const TERRAIN_RIM_HEIGHT: float = 7.0  # rocky berm height near the perimeter walls
const RIVER_WIDTH: float = 5.0  # river channel width (m)
const RIVER_DEPTH: float = 0.45  # ≤ navmesh agent_max_climb 0.5 → walkable ford everywhere
# Flora budgets (MultiMesh where possible; trees/boulders are individual nodes).
# VEGETATION OVERHAUL (forest + clearings): trees/bushes are placed by the FloraField
# density field (groves, treelines, ecotone edges, authored corridors) — these are
# EXPECTED TOTALS for calibration/QA prints, not caps (the field's acceptance math in
# procedural_flora is tuned to land near them: 6400 cells × mean_w 0.30 × accept 0.45
# ≈ 760 trees after keep-out/river losses). GRASS is density-driven (per-cell probability
# + spatial tiling) so its budgets are unused for placement — only visibility ranges.
# FAIRNESS: all vegetation density is identical on every graphics preset (concealment).
const FLORA_TREES: int = 760
const FLORA_BUSHES: int = 650
const GRASS_VIS_RANGE: float = 58.0  # near-layer visibility_range_end (m); wider so grass doesn't pop on the 160m map
const GRASS_FAR_RANGE: float = 90.0  # far-layer visibility_range_end (m)
const FLORA_STONES: int = 1000  # textured pebbles (FloraClutter MultiMesh, render-only)
const FLORA_BOULDERS: int = 36  # big collidable cover rocks (breakable STONE when destruction is on)
const FLORA_SMALL_ROCKS: int = 60  # small shoot-only breakable rocks ("мелкие камни"; don't block)
# FloraClutter expected per-layer totals (documentation + NET_DEBUG count checks).
const FLORA_CLUTTER: Dictionary = {
	"fern": 500, "flower": 280, "clover": 200, "mushroom": 180, "plant": 250, "flagstone": 60
}
# Building interior lighting (shadowless warm omnis; budget ≤ ~14 lights map-wide)
const INTERIOR_LIGHT_ENERGY: float = 2.6
const INTERIOR_LIGHT_RANGE: float = 10.0

# Player
const PLAYER_MAX_HEALTH: float = 100.0
const PLAYER_MOVE_SPEED: float = 5.5
const PLAYER_SPRINT_SPEED: float = 8.5
const PLAYER_JUMP_VELOCITY: float = 7.0
const MOUSE_SENSITIVITY: float = 0.0025
const CAMERA_PITCH_MIN: float = -1.2
const CAMERA_PITCH_MAX: float = 0.6
# Crouch + slide (Arc Raiders-style stances).
const PLAYER_CROUCH_SPEED: float = 2.6  # m/s while crouched
const CROUCH_CAMERA_DROP: float = 0.55  # camera_pivot.y drop when crouched
const SLIDE_SPEED: float = 9.5  # initial slide speed (decays to crouch speed)
const SLIDE_TIME: float = 0.7  # slide duration (s)
const SLIDE_CAMERA_DROP: float = 0.8  # camera drop during a slide
const CROUCH_CAMERA_LERP: float = 10.0  # camera-height ease speed
# Dodge-roll (Stance.ROLL): committed burst in the input direction with brief i-frames
# vs ENEMY damage (player._iframes_until_ms — deliberately NOT Health.invulnerable,
# godmode owns that). Drains stamina; cooldown stops roll-spam.
const ROLL_SPEED: float = 11.0  # initial roll speed (decays to walk speed)
const ROLL_TIME: float = 0.45  # roll duration (s)
const ROLL_IFRAME_TIME: float = 0.35  # invulnerability window vs enemies (s)
const ROLL_STAMINA_COST: float = 25.0
const ROLL_COOLDOWN: float = 1.2  # s between rolls
const ROLL_CAMERA_DROP: float = 0.5  # camera drop during the roll
# Mantle (climb low obstacles on jump near a wall): ledge height window + motion time.
const MANTLE_MAX_HEIGHT: float = 1.2  # highest climbable ledge (m above feet)
const MANTLE_MIN_HEIGHT: float = 0.5  # below this just step/jump normally
const MANTLE_TIME: float = 0.35  # up-and-over duration (s)
const MANTLE_PROBE: float = 1.0  # forward wall-probe length (m)
# Ziplines (authored anchor pairs between POIs; ride is authority-local movement).
const ZIPLINE_SPEED: float = 12.0  # m/s along the cable
const ZIPLINE_HANG: float = 1.7  # rider hangs this far below the cable
const ZIPLINE_END_RADIUS: float = 2.2  # mount Area3D radius at each anchor
# Stance spread multipliers (applied to weapon.spread_deg at fire time — crouch < stand <
# move < sprint, ADS tightest; the dynamic crosshair shows the resulting cone).
const SPREAD_MULT_CROUCH: float = 0.45
const SPREAD_MULT_STAND: float = 1.0
const SPREAD_MULT_MOVE: float = 1.7
const SPREAD_MULT_SPRINT: float = 2.6
const SPREAD_MULT_SLIDE: float = 3.0
const SPREAD_MULT_ADS: float = 0.4
const FP_SPRING_LENGTH: float = 0.15  # spring length in first-person view
# Co-op downed / revive loop.
const BLEEDOUT_TIME: float = 45.0  # seconds downed before true death (no revive)
const REVIVE_CHANNEL_TIME: float = 4.0  # hold-to-revive duration (s)
const REVIVE_HEALTH_FRAC: float = 0.35  # fraction of max HP restored on revive
const DOWNED_MOVE_SPEED: float = 2.0  # crawl speed while downed (m/s) — enough to reach cover / an evac
const DOWNED_CAMERA_DROP: float = 1.0  # camera drop while downed
const GIVE_UP_HOLD_TIME: float = 2.0  # hold the give_up key this long while downed to self-finish (skip bleedout)
const CARRY_SPEED_MULT: float = 0.5  # carrier move-speed multiplier while carrying a buddy
const KNOCKDOWN_SHIELD_ABSORB: float = 150.0  # damage a knockdown shield soaks while downed
const SELF_REVIVE_ITEM: String = "loot_self_revive"  # consumable id that self-revives when downed
const KNOCKDOWN_SHIELD_ITEM: String = "loot_knockdown_shield"

# Ammo economy (the "ran dry mid-raid with no counterplay" fix): machines shed
# usable rounds on death — a walk-up shard resupplies a FRACTION of every weapon's
# reserve; an Ammo Box (inventory use) resupplies in full.
const AMMO_DROP_CHANCE: float = 0.5  # chance an enemy death also drops an ammo shard
const AMMO_SHARD_FRAC: float = 0.35  # reserve fraction one shard restores

# Destructible trees ("разрушение-как-оружие"): shoot a trunk down — the falling
# tree CRUSHES enemies, settles into cover, leaves a stump. Server-auth by index.
const TREE_FELL_ENABLED: bool = true
const TREE_HP: float = 30.0  # ~3 rifle hits fell a tree
const TREE_CRUSH_DMG: float = 55.0  # crush cap for a fast-falling trunk
const TREE_FALLEN_LIFETIME: float = 22.0  # seconds the fallen trunk persists as cover
# Physics debris crush: chunk shards damage enemies they slam into (server-side).
const DEBRIS_CRUSH_ENABLED: bool = true
const DEBRIS_CRUSH_DMG_MAX: float = 16.0  # per-shard cap (a collapse = many shards)

# Combat
const WEAPON_NET_REPLICATION_HZ: float = 30.0

# Enemy
const ENEMY_MAX_HEALTH: float = 40.0
const ENEMY_DETECT_RADIUS: float = 18.0
# Melee strike distance. Must be short so robots CHASE up to the player before
# attacking; a large value lets them deal damage from across the arena (they hold
# position and strike when in ATTACK state — see robot_enemy._do_attack).
const ENEMY_ATTACK_RANGE: float = 2.2
const ENEMY_MOVE_SPEED: float = 4.0  # close distance faster -> pressure (player walk 5.5)
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
const MATCH_DURATION: float = 540.0  # 9 minutes
const FINAL_WAVE_WARN: float = 30.0  # warn the player this many seconds before
const FINAL_WAVE_COUNT_MULT: float = 3.5  # storm wave size vs a normal late wave
const FINAL_WAVE_CONCURRENT: int = 18  # storm raises the alive-cap hard
const FINAL_WAVE_SPAWN_INTERVAL: float = 0.5  # and spawns much faster

# Atmosphere / mood — ambient particle density + how long the day→storm visual
# transition takes when the final wave begins (world_atmosphere.gd reads these).
const ATMOSPHERE_DUST := 170  # ambient dust-mote particle count (4× map → ~2× to hold density)
const ATMOSPHERE_EMBERS := 70  # drifting ember particle count
const STORM_TWEEN_TIME := 6.0  # seconds to lerp sky/fog/light into the storm look

# Ballistics — shots now arc under gravity (bullet drop). The shot is resolved as a
# stepped raycast along the trajectory; per-weapon muzzle velocity may override.
const BULLET_GRAVITY: float = 9.8  # m/s² downward on the projectile
const BULLET_MUZZLE_VELOCITY: float = 120.0  # m/s default (high = flat; low = droppy)
const BULLET_STEP: float = 2.5  # metres per ballistic raycast segment

# Waves — spawns are STAGGERED (a steady trickle, capped concurrency) rather than
# dumped all at once, so late waves stay beatable-but-challenging instead of an
# instant swarm. Total enemies per wave = WAVE_BASE_ENEMIES + (wave-1)*GROWTH.
const WAVE_BASE_ENEMIES: int = 3
const WAVE_ENEMY_GROWTH: int = 2
const WAVE_INTERMISSION: float = 6.0
const WAVE_MAX_CONCURRENT: int = 6  # never more than this many alive at once
const WAVE_SPAWN_INTERVAL: float = 1.2  # seconds between trickle spawns

# --- AI perception / sound stealth (Batch 2 "Living threat") ----------------
# A noise's audible RADIUS in metres. The server's enemy perception hears any noise
# whose radius reaches it; non-hunter enemies INVESTIGATE the source (or CHASE if very
# close). Gunfire/grenades route through NetworkManager.report_noise; footstep loudness
# is derived per-frame from a player's speed + stance (no RPC — server reads synced state).
const NOISE_GUNFIRE: float = 22.0  # unsuppressed shot audible radius
const NOISE_GRENADE: float = 34.0  # explosion audible radius (always loud)
const NOISE_WALK: float = 8.0  # standing/walking footstep loudness
const NOISE_SPRINT: float = 16.0  # sprinting is loud
const NOISE_CROUCH_MULT: float = 0.4  # crouch-walking is quiet (×NOISE_WALK)
const NOISE_IDLE: float = 2.5  # barely-moving hum (still faintly audible up close)
# A noise this loud or louder at the enemy counts as a "spike" → CHASE straight away
# (instead of the cautious INVESTIGATE walk-to-the-sound). Fraction of the heard radius.
const NOISE_CHASE_FRACTION: float = 0.45
# A non-hunter patrol NOTICES a player within this radius even without clean line-of-sight or
# loud footsteps (so a patrol you walk right up to engages instead of standing idle). Beyond it,
# the normal hearing/LOS stealth applies. Read by robot_enemy's perception.
const PROXIMITY_AGGRO_RADIUS: float = 9.0
# M3 territoriality: a NON-hunter chased past this far from its spawn point breaks
# off and returns home (patrols garrison their POI instead of cross-map pursuits).
const ENEMY_LEASH_RADIUS: float = 28.0
# INVESTIGATE behaviour: move to the last-heard point at this speed mult, look around,
# then give up after GIVEUP seconds with no confirmation and return to PATROL.
const INVESTIGATE_SPEED_MULT: float = 0.8
const INVESTIGATE_GIVEUP: float = 8.0  # seconds investigating before giving up
const INVESTIGATE_ARRIVE: float = 1.8  # within this of the point = "arrived, look around"
# Cascading alert: an enemy entering CHASE flips nearby NON-hunter enemies within this
# radius to INVESTIGATE its target (so a firefight wakes the block). Each enemy only
# re-alerts once per ALERT_REFRACTORY window so it can't ping-pong.
const ALERT_CASCADE_RADIUS: float = 20.0
const ALERT_REFRACTORY: float = 4.0

# --- Reactive AI director + alarms + patrols --------------------------------
# Camp-punish: if the whole squad stays clustered within CAMP_RADIUS for CAMP_TIME
# during an active wave, the director spawns FLANK_COUNT enemies around/behind them.
const DIRECTOR_CAMP_RADIUS: float = 14.0
const DIRECTOR_CAMP_TIME: float = 10.0
const DIRECTOR_FLANK_COUNT: int = 3
const DIRECTOR_CAMP_COOLDOWN: float = 18.0  # min seconds between flank punishes
# Boss-phase support adds: when the boss drops below this HP fraction, spawn a few adds (once).
const DIRECTOR_BOSS_ADD_HP: float = 0.5
const DIRECTOR_BOSS_ADD_COUNT: int = 3
# Alarms: a caller/alarm (Events.enemy_alerted) summons reinforcements on a cooldown.
const ALARM_REINFORCE_COUNT: int = 4
const ALARM_COOLDOWN: float = 12.0
# A noise_emitted event must be at least this loud to count as an alarm-worthy "bang"
# (so only grenades, not every gunshot, trigger director reinforcements).
const ALARM_GRENADE_MIN_LOUDNESS: float = NOISE_GRENADE * 0.6
# Between-wave patrols: spawn this many NON-hunter enemies during intermission (and
# pre-first-wave) so the map feels inhabited + stealth has something to sneak past.
const PATROL_COUNT: int = 3

# --- Risk tiers (Batch 3 "Live raid") ---------------------------------------
# Each POI is tiered 1 (low) … 3 (high). Higher tier = tougher event guards + rarer
# loot (rarity-weighted) + more world-loot caches. Keyed by the POI names in
# arena.gd::_POI_DEFS. arena.get_poi_tier() reads this; the map shades by tier.
const POI_RISK_TIERS := {
	"POI_NorthTower": 3,
	"POI_EastWarehouse": 1,
	"POI_Plaza": 2,
	"POI_SWHouse": 1,
	"POI_SouthYard": 2,
	"POI_EastYard": 3,
	# New far-quadrant POIs: the themed landmarks are high-risk/high-reward (tier 3), their
	# fillers tier 2 — the long trek out to the new quadrants should pay off.
	"POI_SnowLodge": 3,
	"POI_SnowDepot": 2,
	"POI_DesertRuins": 3,
	"POI_RuinColumns": 2,
	"POI_Temple": 3,
	"POI_ShrineHouse": 2,
}
# Per-tier loot rarity band [min, max] (ItemData.Rarity: 0 COMMON…4 LEGENDARY). The
# loot_tables roll picks within the band, weighted toward the lower (commoner) end.
const RISK_TIER_LOOT := {
	1: [0, 1],  # COMMON–UNCOMMON
	2: [1, 2],  # UNCOMMON–RARE
	3: [2, 3],  # RARE–EPIC
}
# How many world-loot pickups to scatter near a POI of each tier (at arena build).
const RISK_TIER_CACHE_COUNT := {1: 2, 2: 3, 3: 4}
# Map shading per tier (low green → high red).
const RISK_TIER_COLORS := {
	1: Color(0.45, 0.85, 0.5),
	2: Color(0.95, 0.8, 0.35),
	3: Color(0.95, 0.4, 0.35),
}

# --- Dynamic world events (Batch 3) -----------------------------------------
# The WorldEventDirector fires the first event after FIRST_DELAY, then every
# INTERVAL ± JITTER seconds, picking a random enabled kind. Suspended during the storm.
const WORLD_EVENT_FIRST_DELAY: float = 60.0
const WORLD_EVENT_INTERVAL: float = 90.0
const WORLD_EVENT_JITTER: float = 25.0
const SUPPLY_CACHE_HOLD_TIME: float = 8.0  # seconds a player must hold the cache to crack it
const SUPPLY_CACHE_GUARDS: int = 3  # defenders spawned around a cache
const SUPPLY_CACHE_LOOT: int = 5  # loot pickups dropped when cracked
const MINIBOSS_REWARD_CURRENCY: int = 150  # bonus on the mini-boss kill
const CONTESTED_POI_DURATION: float = 45.0  # how long a POI stays "hot"
const CONTESTED_POI_GUARDS: int = 4
const SURGE_DURATION: float = 25.0  # enemy-surge / sensor-blackout window

# --- Progression: Raider Level + XP (Batch 3) --------------------------------
# Account XP curve: xp needed to go from level n→n+1 = BASE * GROWTH^(n-1).
const XP_CURVE_BASE: float = 1000.0
const XP_CURVE_GROWTH: float = 1.35
const SKILL_POINTS_PER_LEVEL: int = 1
const XP_PER_KILL: int = 30
const XP_PER_EXTRACT: int = 500
const XP_PER_EVENT: int = 250  # completing a world event
const XP_PER_RARE_LOOT: int = 60  # per RARE+ item in the extracted haul
# Account skill tree. key -> { name, desc, max, mult_field (a player_mods key), per }.
# Skills fold MULTIPLICATIVELY into MetaProgression.player_mods() alongside upgrades.
const SKILLS := {
	"vitality":
	{
		"name": "Vitality",
		"desc": "+6% max health / level",
		"max": 5,
		"field": "health_mult",
		"per": 0.06
	},
	"scavenger":
	{
		"name": "Scavenger",
		"desc": "+8% loot value / level",
		"max": 5,
		"field": "loot_mult",
		"per": 0.08
	},
	"endurance":
	{
		"name": "Endurance",
		"desc": "+8% stamina / level",
		"max": 5,
		"field": "stamina_mult",
		"per": 0.08
	},
	"gunner":
	{
		"name": "Gunner",
		"desc": "+4% weapon damage / level",
		"max": 5,
		"field": "damage_mult",
		"per": 0.04
	},
}

# --- Power caches: timed buffs (Vampire-Survivors-style) ----------------------
# A Power Cache on the map, when opened, plays a non-blocking side reveal reel then grants ONE
# of these as a TIMED buff (~20-30s). `field` is the buff kind read at runtime by player/weapon.
# `mag` is the effect magnitude (mult delta, flat, or fraction depending on field). `free` powers
# can roll from raid 1; the rest are UNLOCKED with skill points (`cost`) in the RAIDER tab. `color`
# tints the reveal/icon. Pool that can roll = MetaProgression.available_powers().
const POWER_REVEAL_TIME: float = 2.6  # length of the non-blocking lottery reveal
# Power icons are CC BY 3.0 from game-icons.net (see docs/ASSETS.md / tools/art/fetch_power_icons.ps1).
const POWERS := {
	"berserk":
	{
		"name": "Berserk",
		"desc": "+60% weapon damage",
		"field": "damage",
		"mag": 0.60,
		"dur": 22.0,
		"color": Color(0.95, 0.32, 0.26),
		"rarity": 1,
		"free": true,
		"cost": 0,
		"icon": "res://assets/ui/icons/powers/berserk.svg"
	},
	"rapidfire":
	{
		"name": "Rapid Fire",
		"desc": "+45% fire rate",
		"field": "fire_rate",
		"mag": 0.45,
		"dur": 22.0,
		"color": Color(0.98, 0.74, 0.25),
		"rarity": 1,
		"free": true,
		"cost": 0,
		"icon": "res://assets/ui/icons/powers/rapidfire.svg"
	},
	"swift":
	{
		"name": "Swift",
		"desc": "+35% move speed",
		"field": "speed",
		"mag": 0.35,
		"dur": 25.0,
		"color": Color(0.30, 0.80, 0.95),
		"rarity": 1,
		"free": true,
		"cost": 0,
		"icon": "res://assets/ui/icons/powers/swift.svg"
	},
	"overshield":
	{
		"name": "Overshield",
		"desc": "Absorb 90 damage",
		"field": "overshield",
		"mag": 90.0,
		"dur": 30.0,
		"color": Color(0.40, 0.70, 1.00),
		"rarity": 1,
		"free": true,
		"cost": 0,
		"icon": "res://assets/ui/icons/powers/overshield.svg"
	},
	"regen":
	{
		"name": "Regen",
		"desc": "Heal 9 HP/sec",
		"field": "regen",
		"mag": 9.0,
		"dur": 20.0,
		"color": Color(0.36, 0.90, 0.55),
		"rarity": 1,
		"free": true,
		"cost": 0,
		"icon": "res://assets/ui/icons/powers/regen.svg"
	},
	"lifesteal":
	{
		"name": "Lifesteal",
		"desc": "Heal 30% of damage dealt",
		"field": "lifesteal",
		"mag": 0.30,
		"dur": 22.0,
		"color": Color(0.80, 0.25, 0.55),
		"rarity": 2,
		"free": false,
		"cost": 1,
		"icon": "res://assets/ui/icons/powers/lifesteal.svg"
	},
	"juggernaut":
	{
		"name": "Juggernaut",
		"desc": "−45% damage taken",
		"field": "armor",
		"mag": 0.45,
		"dur": 24.0,
		"color": Color(0.75, 0.78, 0.85),
		"rarity": 2,
		"free": false,
		"cost": 1,
		"icon": "res://assets/ui/icons/powers/juggernaut.svg"
	},
	"adrenaline":
	{
		"name": "Adrenaline",
		"desc": "Infinite stamina + reload",
		"field": "adrenaline",
		"mag": 0.40,
		"dur": 24.0,
		"color": Color(0.95, 0.55, 0.20),
		"rarity": 2,
		"free": false,
		"cost": 1,
		"icon": "res://assets/ui/icons/powers/adrenaline.svg"
	},
	"frenzy":
	{
		"name": "Frenzy",
		"desc": "+40% damage, fire & speed",
		"field": "frenzy",
		"mag": 0.40,
		"dur": 18.0,
		"color": Color(1.00, 0.40, 0.85),
		"rarity": 3,
		"free": false,
		"cost": 2,
		"icon": "res://assets/ui/icons/powers/frenzy.svg"
	},
}

## Cached power-icon textures (loaded once; null if missing/headless). Drawn tinted by the power
## colour in the reveal reel / active-buff strip / RAIDER tab.
static var _power_icon_cache: Dictionary = {}


static func power_icon(power_id: String) -> Texture2D:
	if _power_icon_cache.has(power_id):
		return _power_icon_cache[power_id]
	var path: String = String(POWERS.get(power_id, {}).get("icon", ""))
	var tex: Texture2D = null
	if path != "" and ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			tex = res
	_power_icon_cache[power_id] = tex
	return tex


# --- Progression: Vendor Reputation (Batch 3) --------------------------------
# Cumulative rep thresholds per tier (index = tier; rep >= threshold → that tier).
const REP_TIER_THRESHOLDS := [0, 300, 800, 1600, 2800]
# Reward granted when a NEW tier is reached: currency + an optional blueprint to learn.
const REP_TIER_REWARDS := {
	1: {"currency": 200, "blueprint": ""},
	2: {"currency": 400, "blueprint": "bp_suppressor"},
	3: {"currency": 700, "blueprint": "bp_stim"},
	4: {"currency": 1200, "blueprint": "bp_drum_mag"},
}
# Shop price discount fraction per rep tier (tier 0 = none … tier 4 = 20% off).
const REP_TIER_DISCOUNT := {0: 0.0, 1: 0.05, 2: 0.10, 3: 0.15, 4: 0.20}
const REP_PER_EXTRACT: int = 50
const REP_PER_CONTRACT: int = 120  # claiming a quest
const REP_PER_HIGH_TIER_HAUL: int = 80  # extracting RARE+ loot

# --- Progression: Weapon Mastery (Batch 3) -----------------------------------
# Per-weapon mastery XP from use (kills/damage). Level n→n+1 needs BASE*n mastery xp.
const WEAPON_MASTERY_BASE: float = 8.0  # ~8 kills for level 1, scaling up
const WEAPON_MASTERY_MAX: int = 10
const WEAPON_MASTERY_XP_PER_KILL: int = 1
# "Veteran" ramp (validation pass): mastery levels gently improve the gun you USE — a small
# per-level reduction in recoil/spread/reload (capped at MASTERY_MAX). DISTINCT from the
# bought permanent perks (damage/mag): mastery is the passive "I've used this a lot" feel.
# Per-level fractions; total at L10 = 15% recoil / 10% spread / 10% reload.
const WEAPON_MASTERY_RECOIL_PER: float = 0.015
const WEAPON_MASTERY_SPREAD_PER: float = 0.010
const WEAPON_MASTERY_RELOAD_PER: float = 0.010

# --- Progression: Raider Level milestones (validation pass) -------------------
# Reaching a Raider Level grants a one-time permanent milestone (gives leveling a POINT
# without an Arc-Raiders-style tech tree). Applied idempotently on level-up + on load.
#   kind: "unlock_weapon" (free weapon id) | "stash" (+capacity) | "currency" (one-time CR).
const RAIDER_MILESTONES := {
	3: {"kind": "unlock_weapon", "value": "smg", "label": "Free SMG"},
	5: {"kind": "stash", "value": 25, "label": "+25 Stash Capacity"},
	8: {"kind": "currency", "value": 500, "label": "+500 Credits"},
	12: {"kind": "unlock_weapon", "value": "dmr", "label": "Free DMR"},
}

# Camera / ADS / peek
const DEFAULT_FOV: float = 60.0
const ADS_FOV: float = 42.0  # zoomed FOV when aiming (per-weapon may override)
const ADS_SENS_SCALE: float = 0.5  # look sensitivity multiplier while aiming
const ADS_SPRING_LENGTH: float = 2.0  # camera pulled in when aiming
const DEFAULT_SPRING_LENGTH: float = 3.5  # legacy single 3rd-person distance (kept for ref)
# V cycles the camera through these THIRD-person distances (m, ×camera_distance_scale) then
# first-person — so V "zooms out" instead of jumping into the head. Index 3 (size) = first-person.
const VIEW_STEP_LENGTHS: Array = [3.0, 4.5, 6.5]  # 0 close · 1 medium · 2 far
# FIRST-PERSON RESTORED as the 4th V-step (user: «мог видеть оружие и руку, но не
# видел шлем — переключался на тот вид»): the local ModelRoot hides in FP so the
# helmet NEVER shows — you see the weapon viewmodel + hands only. The spawn view
# is still ALWAYS third-person medium (DEFAULT_VIEW_STEP + the SettingsManager
# default_view force) — FP is opt-in per press, never the spawn state.
const VIEW_STEP_COUNT: int = 4
const DEFAULT_VIEW_STEP: int = 1  # spawn at MEDIUM (4.5 m) — the whole body is in frame
const VIEW_STEP_FIRST_PERSON: int = 3
const SHOULDER_OFFSET: float = 0.5  # over-the-shoulder camera x-offset (flipped by swap)
const AIM_TWEEN_SPEED: float = 10.0  # lerp speed for fov/length/offset
const PEEK_PROBE: float = 1.4  # side-raycast distance to detect a wall to lean past
const PEEK_SHIFT: float = 0.7  # extra lateral camera shift when leaning out

# Weapons
const WEAPON_SWITCH_TIME: float = 0.35

# Healing / gadgets
const HEAL_AMOUNT: float = 45.0
const HEAL_TIME: float = 1.4
const GRENADE_DAMAGE: float = 70.0
const GRENADE_RADIUS: float = 5.5
const GRENADE_FUSE: float = 1.6
const GRENADE_THROW_FORCE: float = 15.0

# --- Grenade types (batch A): the synced per-type counts dict uses these ids. "frag"
# is the classic damage grenade; the others are utility (see scripts/items/grenade_*.gd).
const GRENADE_TYPES := ["frag", "smoke", "emp", "decoy", "incendiary", "cryo"]
# Maps a grenade type to its consumable item id (bring-list / loot / stash economy).
const GRENADE_ITEM_IDS := {
	"frag": "loot_grenade",
	"smoke": "loot_grenade_smoke",
	"emp": "loot_grenade_emp",
	"decoy": "loot_grenade_decoy",
	"incendiary": "loot_grenade_incendiary",
	"cryo": "loot_grenade_cryo",
}
const SMOKE_DURATION: float = 10.0  # smoke cloud lifetime (s)
const SMOKE_RADIUS: float = 5.0  # LOS-blocking sphere radius (m)
const EMP_RADIUS: float = 6.0  # stun radius vs robots (m)
const EMP_STUN_TIME: float = 3.5  # robot stun duration (s)
const EMP_BOSS_STUN_MULT: float = 0.4  # bosses shrug most of the stun off
const DECOY_DURATION: float = 8.0  # noise-beacon lifetime (s)
const DECOY_PULSE: float = 1.5  # s between noise pulses
const DECOY_LOUDNESS: float = NOISE_GRENADE * 0.8

# --- MACHINE CHEMISTRY (Phase 5): enemy status-effect framework -----------------
# Machines react to elemental/electro effects like NO human enemy can (the signature
# "un-copyable machine lever"). 4 statuses, bit-packed for the visual-sync RPC.
# Logic is authority-local (mirrors apply_stun); HP/position replicate the result.
const CHEM_SHOCK: int = 1  # electric: stun + chains to nearby WET machines
const CHEM_BURN: int = 2  # thermal DoT: amplified in desert, doused when wet
const CHEM_SLOW: int = 4  # cryo: movement slow; longer in snow → freeze→shatter window
const CHEM_BRITTLE: int = 8  # incoming-damage amplifier (a frozen machine shatters)
# Shock / chain discharge.
const CHEM_SHOCK_STUN: float = 1.0  # base stun seconds (reuses _stunned_until_ms)
const CHEM_SHOCK_FX: float = 0.5  # arc-VFX window (independent of stun length)
const CHEM_CHAIN_RADIUS: float = 6.0  # jump reach to the next wet machine (m)
const CHEM_CHAIN_JUMPS: int = 3  # max extra machines per discharge
const CHEM_CHAIN_FALLOFF: float = 0.75  # stun ×this per hop
# Burn (DoT).
const CHEM_BURN_TICK: float = 1.0  # seconds between burn ticks
const CHEM_BURN_DESERT_MULT: float = 1.5  # desert heat amplifies burn dps
const CHEM_BURN_RAIN_MULT: float = 0.0  # rain/wet douses burn (0 = extinguish)
# Slow (cryo).
const CHEM_SLOW_MIN_MULT: float = 0.2  # never freeze below this via slow
const CHEM_SLOW_SNOW_MULT: float = 1.5  # snow lengthens the slow
const CHEM_FREEZE_THRESHOLD: float = 0.5  # slow mult <= this latches BRITTLE (shatter combo)
# Brittle.
const CHEM_BRITTLE_DUR: float = 4.0  # seconds the amplifier lasts (auto-latched by deep slow)
const CHEM_BRITTLE_MULT: float = 1.5  # incoming damage ×this while brittle
# Visual gate.
const CHEM_FX_DIST: float = 45.0  # status FX spawns only within this range of the camera (m)
# --- Elemental ammo (Chemistry Phase 6) — SERVER-side numbers; clients only send the kind.
const CHEM_AMMO_SHOCK_CHANCE: float = 0.25  # proc roll per landed shock-mag shot
const CHEM_AMMO_SHOCK_STUN: float = 0.4  # seconds per proc (vs 1.0 for the EMP shock)
const CHEM_AMMO_SHOCK_ICD: float = 2.5  # per-enemy cooldown between procs (anti-stunlock)
const CHEM_AMMO_BURN_DUR: float = 2.5  # incendiary DoT window, refreshed per hit
const CHEM_AMMO_BURN_DPS: float = 7.0  # incendiary DoT dps
const CHEM_AMMO_SLOW_DUR: float = 1.8  # cryo slow window per hit
const CHEM_AMMO_SLOW_STEP: float = 0.12  # each cryo hit deepens the slow by this much
const CHEM_AMMO_SLOW_FLOOR: float = 0.42  # ramp floor — BELOW freeze threshold (shatter combo)
# Nemesis learned counter (Phase 6): a rival the squad kept dousing in statuses.
const NEMESIS_CHEM_MULT: float = 0.35  # status duration ×this on a chemistry_resist rival
# --- Hijack & Pilot (v0.5-B2) — steal a SHOCK/EMP-stunned machine and drive it.
const HIJACK_HOLD_TIME: float = 1.2  # hold-X seconds on a stunned machine to crack it
const HIJACK_RANGE: float = 4.5  # max distance to hack (big hulls have 1.5-2m body radii)
const HIJACK_TIME: float = 25.0  # pilot window; expiry = the machine blows from inside
const HIJACK_SPEED_MULT: float = 1.15  # stolen machines drive a little hot
const HIJACK_ATTACK_CD: float = 0.9  # piloted slam cooldown (fire button)
const HIJACK_ATTACK_DMG_MULT: float = 1.4  # machine attack stat ×this per slam
const HIJACK_ATTACK_RANGE: float = 3.6  # slam radius ahead of the hull
const HIJACK_EXIT_BLAST_RADIUS: float = 6.0  # leaving the hull detonates it from inside
const HIJACK_EXIT_BLAST_DMG: float = 70.0  # blast hits MACHINES only — the pilot hops clear
const HIJACK_EJECT_IFRAMES: float = 1.0  # enemy-source safety after ejecting
# Never hijackable: the boss, the burrower, and the true flyers (camera/motion breaks).
const HIJACK_EXCLUDE: Array[String] = [
	"robot_boss", "robot_sandworm", "robot_wasp", "robot_specter"
]

# --- Source: Incendiary grenade (Phase 5) — applies BURN in radius.
const INCENDIARY_RADIUS: float = 5.0
const INCENDIARY_BURN_DUR: float = 5.0
const INCENDIARY_BURN_DPS: float = 8.0
# --- Source: Cryo grenade (Phase 5) — applies SLOW (deep slow primes BRITTLE) in radius.
const CRYO_RADIUS: float = 5.0
const CRYO_SLOW_DUR: float = 4.0
const CRYO_SLOW_MULT: float = 0.45
# --- Source: the EMP grenade ALSO tags SHOCK (the only player-side shock → enables the rain chain).
const EMP_SHOCK_DUR: float = 1.5
const EMP_SHOCK_MAG: float = 1.0

# --- Deployable gadgets (batch A): brought from the stash, placed with keys 6/7/8,
# server-spawned under Arena/Net/Gadgets so every peer sees them.
const GADGET_TYPES := ["gadget_turret", "gadget_dome", "gadget_sensor"]
const TURRET_RANGE: float = 14.0  # auto-turret acquisition range (m, LOS required)
const TURRET_DAMAGE: float = 6.0  # per tick
const TURRET_TICK: float = 0.5  # s between shots
const TURRET_LIFETIME: float = 25.0  # s
const TURRET_HP: float = 80.0  # enemies can destroy it
const DOME_RADIUS: float = 4.0  # shield dome radius (m)
const DOME_DAMAGE_MULT: float = 0.5  # damage taken by players inside
const DOME_DURATION: float = 10.0  # s
const SENSOR_RANGE: float = 18.0  # motion-sensor ping radius (m)
const SENSOR_DURATION: float = 25.0  # s
const SENSOR_PULSE: float = 2.0  # s between ping sweeps

# Per-enemy archetype stats (read by enemies-dev / robot_enemy). Falls back to the
# legacy ENEMY_* constants above for "robot_grunt". flying/ranged are behaviour flags.
const ENEMY_STATS := {
	"robot_grunt":
	{
		"health": 40.0,
		"speed": 4.0,
		"damage": 8.0,
		"detect": 18.0,
		"attack_range": 2.2,
		"cooldown": 1.2,
		"score": 10
	},
	"robot_heavy":
	{
		"health": 95.0,
		"speed": 2.8,
		"damage": 14.0,
		"detect": 18.0,
		"attack_range": 2.6,
		"cooldown": 1.6,
		"score": 25
	},
	"robot_tick":
	{
		"health": 14.0,
		"speed": 6.6,
		"damage": 5.0,
		"detect": 22.0,
		"attack_range": 1.6,
		"cooldown": 0.8,
		"score": 6
	},
	"robot_wasp":
	{
		"health": 22.0,
		"speed": 5.2,
		"damage": 6.0,
		"detect": 26.0,
		"attack_range": 15.0,
		"cooldown": 1.4,
		"score": 14,
		"flying": true,
		"hover": 4.5,
		"ranged": true
	},
	"robot_bastion":
	{
		"health": 170.0,
		"speed": 2.2,
		"damage": 10.0,
		"detect": 28.0,
		"attack_range": 20.0,
		"cooldown": 0.25,
		"score": 45,
		"ranged": true,
		"burst": true
	},
	"robot_boss":
	{
		"health": 650.0,
		"speed": 2.6,
		"damage": 22.0,
		"detect": 45.0,
		"attack_range": 22.0,
		"cooldown": 0.4,
		"score": 250,
		"ranged": true
	},
	# Caller ("Snitch"): low HP, fast, keeps its distance and — instead of dealing
	# damage — fires Events.enemy_alerted so the director summons reinforcements. Kill
	"robot_caller":
	{
		# it fast or get swarmed. Behaviour lives in robot_caller.gd (caller flag).
		"health": 30.0,
		"speed": 5.0,
		"damage": 0.0,
		"detect": 30.0,
		"attack_range": 14.0,
		"cooldown": 6.0,
		"score": 30,
		"caller": true
	},
	# Elite grunt: a tankier, harder-hitting grunt with an exposed weak point (the
	"robot_elite":
	{
		# WeakPoint Hurtbox Area in its scene takes ×2.5 — reward precise fire).
		"health": 140.0,
		"speed": 4.2,
		"damage": 15.0,
		"detect": 22.0,
		"attack_range": 2.4,
		"cooldown": 1.1,
		"score": 40
	},
	# --- Biome fauna (v0.3): 3 per NEW biome, biome-EXCLUSIVE spawns (see biome_at +
	# wave_manager BIOME pools). All mechanical; behaviour params live alongside the
	# stats so the scripts read ONE dict. ---
	# DESERT (SW): the sand-worm burrows underground (untargetable, fast), LEAPS out at
	"robot_sandworm":
	{
		# the player, crawls vulnerable for surface_time, then re-burrows (robot_worm.gd).
		"health": 160.0,
		"speed": 3.4,
		"damage": 16.0,
		"detect": 32.0,
		"attack_range": 2.4,
		"cooldown": 1.2,
		"score": 50,
		"burrow_speed": 7.5,
		"surface_time": 5.0,
		"emerge_range": 5.0,
		"leap_damage": 14.0,
		"leap_radius": 2.4
	},
	"robot_scarab":
	{
		# Scarab: fast skitterer that ARMS in range (blinking core) then self-destructs.
		"health": 18.0,
		"speed": 6.4,
		"damage": 0.0,
		"detect": 24.0,
		"attack_range": 2.8,
		"cooldown": 0.5,
		"score": 12,
		"fuse": 0.8,
		"blast_radius": 3.4,
		"blast_damage": 24.0
	},
	"robot_dustdevil":
	{
		# Dust-devil: grounded orbit-strafing gunner wrapped in a spinning sand skirt.
		"health": 55.0,
		"speed": 4.8,
		"damage": 6.0,
		"detect": 28.0,
		"attack_range": 16.0,
		"cooldown": 1.1,
		"score": 22,
		"ranged": true
	},
	"robot_frosthound":
	{
		# SNOW (NE): frost-hound = quadruped with a low fast LUNGE on cooldown.
		"health": 60.0,
		"speed": 5.4,
		"damage": 10.0,
		"detect": 26.0,
		"attack_range": 2.2,
		"cooldown": 1.2,
		"score": 24,
		"pounce_range": 7.0,
		"pounce_up": 5.0,
		"pounce_fwd": 9.0,
		"pounce_cooldown": 4.0,
		"pounce_damage": 12.0,
		"pounce_radius": 1.8
	},
	"robot_cryomortar":
	{
		# Cryo-mortar: slow long-range frost artillery; hits SLOW the player briefly.
		"health": 120.0,
		"speed": 2.0,
		"damage": 9.0,
		"detect": 30.0,
		"attack_range": 22.0,
		"cooldown": 0.35,
		"score": 35,
		"ranged": true,
		"burst": true,
		"slow_mult": 0.6,
		"slow_dur": 1.6
	},
	# Avalanche: tank brute with a telegraphed AoE ground SLAM.
	"robot_avalanche":
	{
		# attack_range covers its FAT body (r0.7 + player + separation park it at ~3.3 m).
		"health": 190.0,
		"speed": 2.4,
		"damage": 12.0,
		"detect": 22.0,
		"attack_range": 3.8,
		"cooldown": 2.4,
		"score": 55,
		"slam_radius": 4.2,
		"slam_windup": 0.9,
		"slam_damage": 20.0
	},
	# RAIN (SE): oni = temple-guardian brute; its WeakPoint sits on its BACK (×3 — flank it).
	"robot_oni":
	{
		# attack_range covers its big body (r0.6 parks it at ~3.1 m from a player).
		"health": 180.0,
		"speed": 3.4,
		"damage": 17.0,
		"detect": 24.0,
		"attack_range": 3.4,
		"cooldown": 1.4,
		"score": 55
	},
	# Kappa: HIGH-arc pouncer that leaps onto the player (shares robot_pouncer.gd with the hound).
	"robot_kappa":
	{
		# pounce_up tuned for the project's gravity=20 (apex = up²/40 ≈ 3 m — it leaps ONTO you).
		"health": 70.0,
		"speed": 4.6,
		"damage": 9.0,
		"detect": 26.0,
		"attack_range": 2.2,
		"cooldown": 1.1,
		"score": 26,
		"pounce_range": 9.0,
		"pounce_up": 11.0,
		"pounce_fwd": 7.0,
		"pounce_cooldown": 5.0,
		"pounce_damage": 14.0,
		"pounce_radius": 2.2
	},
	"robot_raiju":
	{
		# Raiju: storm-spirit skirmisher — electric hitscan + short sideways BLINK teleports.
		"health": 50.0,
		"speed": 5.0,
		"damage": 7.0,
		"detect": 28.0,
		"attack_range": 15.0,
		"cooldown": 1.2,
		"score": 26,
		"ranged": true,
		"blink_range": 5.0,
		"blink_cooldown": 3.0
	},
	# --- Batch D: per-biome MINIBOSSES (scene-clones on existing scripts) + recon drone.
	"robot_snow_golem":
	{
		# Snow golem: oversized avalanche-slammer — slow, huge slam, a wall of HP.
		"health": 520.0,
		"speed": 2.2,
		"damage": 16.0,
		"detect": 30.0,
		"attack_range": 4.5,
		"cooldown": 2.8,
		"score": 150,
		"slam_radius": 6.0,
		"slam_windup": 1.1,
		"slam_damage": 30.0
	},
	"robot_dune_warden":
	{
		# Dune warden: heavy orbit-strafing gunner (dustdevil base, miniboss-scaled).
		"health": 420.0,
		"speed": 3.6,
		"damage": 9.0,
		"detect": 34.0,
		"attack_range": 18.0,
		"cooldown": 0.9,
		"score": 150,
		"ranged": true,
		"burst": true
	},
	"robot_oni_chief":
	# Oni chief: brute melee lord — back WeakPoint x3 is the intended counterplay.
	{
		# Big-body rule: attack_range > its parking distance (radii + separation).
		"health": 560.0,
		"speed": 3.2,
		"damage": 22.0,
		"detect": 28.0,
		"attack_range": 3.8,
		"cooldown": 1.6,
		"score": 170
	},
	"robot_specter":
	# Recon drone: does NOT attack — confirmed LOS for channel_time CALLS
	{
		# reinforcements onto you (kill it fast / break LOS / smoke it).
		"health": 26.0,
		"speed": 6.0,
		"damage": 0.0,
		"detect": 34.0,
		"attack_range": 18.0,
		"cooldown": 2.0,
		"score": 35,
		"flying": true,
		"hover": 6.0,
		"ranged": true,
		"channel_time": 2.5,
		"recon_reinforce": 3
	},
}

## Per-biome miniboss scene (the ONE source both spawn paths read: the world-event
## miniboss picks the local biome's boss; the wave-4 champion uses the same map).
const MINIBOSS_BY_BIOME := {
	"snow": "res://scenes/enemies/RobotSnowGolem.tscn",
	"desert": "res://scenes/enemies/RobotDuneWarden.tscn",
	"rain": "res://scenes/enemies/RobotOniChief.tscn",
}
## Wave-4 "champion": one miniboss replaces a normal spawn in a non-urban biome
## (one per biome per match). Flag so the balance change is one-line revertible.
const CHAMPION_WAVE_ENABLED := true
const CHAMPION_WAVE: int = 4

# --- Elite enemy modifiers (batch D): name-encoded prefixes rolled per spawn -----
# Chance = BASE + PER_WAVE*wave + (BIOME_BONUS outside urban); DOUBLE_CHANCE of the
# rolled elites gain a second distinct prefix. The boss is excluded. Stats apply
# server-side after _load_stats; the tint runs on every peer (parsed from the name).
const ELITE_MOD_BASE_CHANCE: float = 0.06
const ELITE_MOD_PER_WAVE: float = 0.02
const ELITE_MOD_BIOME_BONUS: float = 0.04
const ELITE_MOD_DOUBLE_CHANCE: float = 0.15
const ELITE_MOD_STATS := {
	"armored": {"health_mult": 2.2},
	"swift": {"speed_mult": 1.4},
	"volatile": {"aoe_damage": 25.0, "aoe_radius": 4.0},
	"regenerating": {"regen": 2.0},
	"golden": {"health_mult": 1.8, "speed_mult": 1.25},
}
const ELITE_MOD_COLORS := {
	"armored": Color(0.45, 0.62, 0.95),
	"swift": Color(0.95, 0.85, 0.25),
	"volatile": Color(0.95, 0.45, 0.15),
	"regenerating": Color(0.35, 0.9, 0.45),
	"golden": Color(1.0, 0.82, 0.1),
}
# M5.2 rare encounter: ~1% of ANY non-boss spawn is a GOLDEN elite (loot piñata:
# tanky+fast; its death rains GOLDEN_ELITE_DROPS bonus rare pickups).
const GOLDEN_ELITE_CHANCE: float = 0.01
const GOLDEN_ELITE_DROPS: int = 4

# --- Machine Nemesis (signature mechanic) ------------------------------------
## A robot that SURVIVES a fight with the squad persists across raids, adapts to how it
## was fought (learned counters), wears scars, and hunts the squad. Server-authoritative;
## traits + scars ride the node NAME (the EnemyModifiers channel) so co-op replicates free.
# M2.5: lowered 25→18 so mid archetypes qualify too — rivals birth noticeably more often.
const NEMESIS_MIN_SCORE: int = 18
const NEMESIS_MAX_TIER: int = 5  # leveling cap (each survival = +1 tier)
const NEMESIS_TIER_HEALTH: float = 0.35  # health_mult = 1 + tier * this (a returning rival is tankier)
const NEMESIS_RETURN_DELAY: float = 25.0  # s after match start before the rival is injected
const NEMESIS_EMP_STUN_MULT: float = 0.35  # "emp_hard" trait: EMP stun lasts this fraction
const NEMESIS_BLAST_MULT: float = 0.5  # "blast_hard" trait: incoming grenade/AoE damage fraction
const NEMESIS_KEEN_THRESHOLD: float = 8.0  # s a candidate must stay UN-chased to teach "keen"
# Phase 3 — defeat payoff (bounty to the killer) + caps.
const NEMESIS_BOUNTY_CURRENCY: int = 400  # credits to the killer peer on a rival's defeat
const NEMESIS_BOUNTY_REP: int = 80  # vendor reputation to the killer
const NEMESIS_BOUNTY_XP: int = 200  # raider XP to the killer
const NEMESIS_LOST_GEAR_CAP: int = 8  # max at-risk items the rival "wears" + drops on defeat
const NEMESIS_FAVORITE_MIN: int = 2  # extractions at a zone before it counts as "favorite"
const NEMESIS_HISTORY_CAP: int = 10  # retired rivals kept for the Hub codex
# Phase 4 — successor: on a rival's defeat a nearby lieutenant inherits a weakened grudge.
const NEMESIS_SUCCESSOR_ENABLED: bool = true
const NEMESIS_HEIR_RADIUS: float = 35.0  # m around the death to find an heir

# --- Power-Core Beacon (Phase 4) ---------------------------------------------
## A boss/miniboss drops a glowing core the squad must CARRY to extract for a big reward —
## but carrying pings every machine to your position (a growing beacon) + occupies hands
## (no ADS, slower; firing still allowed). Power = exposure (Hunt-style).
const POWER_CORE_BOUNTY: int = 600  # credits to the carrier on extract-with-core
const POWER_CORE_REP: int = 120  # vendor reputation to the carrier
const POWER_CORE_NOISE_MIN: float = 8.0  # beacon noise radius (m) at pickup
const POWER_CORE_NOISE_MAX: float = 30.0  # …ramped to this
const POWER_CORE_RAMP: float = 20.0  # s to ramp the beacon from MIN to MAX
const POWER_CORE_NOISE_CD: float = 1.5  # s between beacon noise pulses
const POWER_CORE_PICKUP_RADIUS: float = 2.5  # m — walk this close (server-checked) to grab it

# --- Mutant Harvest: body-part SKILLS (signature mechanic) -------------------
## Every enemy drops a UNIQUE body-part as world loot; the player chooses to pick it up (E) → it
## becomes an ACTIVE SKILL on the bottom hotbar AND a visible LIMB on the body (Frankenstein).
## Max 5 distinct skills; a duplicate UPGRADES (level↑) up to max_level (the user's "8 spider
## legs"); per-raid. ENEMY_SKILLS maps each enemy archetype to a skill FAMILY; SKILL_DEFS carries
## per-skill data (part token for ProceduralAbsorbed, signature color, name, active ability,
## cooldown, max level). Colors are SATURATED so the limb/icon pops under the cold grade.
const ENEMY_SKILLS := {
	"robot_frosthound": "leap",
	"robot_kappa": "leap",
	"robot_tick": "leap",
	"robot_avalanche": "slam",
	"robot_heavy": "slam",
	"robot_raiju": "blink",
	"robot_cryomortar": "mortar",
	"robot_dune_warden": "mortar",
	"robot_bastion": "mortar",
	"robot_scarab": "shield",
	"robot_snow_golem": "shield",
	"robot_oni": "ram",
	"robot_oni_chief": "ram",
	"robot_caller": "chainshock",
	"robot_sandworm": "bite",
	"robot_dustdevil": "whirlwind",
	"robot_wasp": "whirlwind",
	"robot_specter": "recon",
	"robot_grunt": "recon",
	"robot_elite": "recon",
	"robot_boss": "recon",
}
const SKILL_FALLBACK_ID := "recon"
const SKILL_DEFS := {
	"leap":
	{
		"part": "claw",
		"limb": "leg",
		"color": Color(0.55, 0.95, 0.55),
		"name_key": "LEAP",
		"ability": "dash",
		"cooldown": 6.0,
		"max_level": 8
	},
	"slam":
	{
		"part": "fist",
		"color": Color(0.45, 0.74, 1.0),
		"name_key": "LEAP SLAM",
		"ability": "leap_slam",
		"cooldown": 10.0,
		"max_level": 5
	},
	"blink":
	{
		"part": "blade",
		"limb": "leg",
		"color": Color(0.40, 0.90, 1.0),
		"name_key": "BLINK",
		"ability": "blink",
		"cooldown": 8.0,
		"max_level": 6
	},
	"mortar":
	{
		"part": "barrel",
		"color": Color(1.0, 0.5, 0.15),
		"name_key": "METEOR",
		"ability": "meteor",
		"cooldown": 13.0,
		"max_level": 5
	},
	"shield":
	{
		"part": "shell",
		"color": Color(0.95, 0.32, 0.14),
		"name_key": "SHIELD",
		"ability": "shield",
		"cooldown": 14.0,
		"max_level": 5
	},
	"ram":
	{
		"part": "horn",
		"color": Color(0.92, 0.74, 0.30),
		"name_key": "BREACH",
		"ability": "breach",
		"cooldown": 10.0,
		"max_level": 4
	},
	"chainshock":
	{
		"part": "antenna",
		"color": Color(0.95, 0.58, 0.20),
		"name_key": "CHAIN SHOCK",
		"ability": "chain",
		"cooldown": 9.0,
		"max_level": 6
	},
	"bite":
	{
		"part": "maw",
		"color": Color(1.0, 0.62, 0.18),
		"name_key": "BITE",
		"ability": "bite_cone",
		"cooldown": 7.0,
		"max_level": 5
	},
	"whirlwind":
	{
		"part": "vane",
		"color": Color(0.55, 0.85, 1.0),
		"name_key": "STORM",
		"ability": "storm",
		"cooldown": 14.0,
		"max_level": 5
	},
	"recon":
	{
		"part": "rotor",
		"color": Color(0.40, 0.90, 1.0),
		"name_key": "CLOAK",
		"ability": "cloak",
		"cooldown": 16.0,
		"max_level": 6
	},
}


## The skill definition (part/color/name/ability/cooldown/max_level) for `id`, or the fallback.
func skill_def(id: String) -> Dictionary:
	return SKILL_DEFS.get(id, SKILL_DEFS[SKILL_FALLBACK_ID])


## Which skill family an enemy archetype drops (by enemy_id), or the fallback skill.
func skill_for_enemy(enemy_id: String) -> String:
	return String(ENEMY_SKILLS.get(enemy_id, SKILL_FALLBACK_ID))


## The "[E]" interaction-prompt text for a world pickup id (power cache / body-part skill / loot).
func loot_prompt(item_id: String) -> String:
	if item_id == "power_cache":
		return tr("Open Power Cache")
	if item_id.begins_with("bodypart_"):
		return tr("Pick up skill: %s") % tr(String(skill_def(item_id.substr(9))["name_key"]))
	return tr("Pick up %s") % item_id.replace("loot_", "").capitalize()


const SKILL_MAX_SLOTS: int = 5  # max distinct skills held (6th refused; can only upgrade)
const SKILL_DROP_GUARANTEED: bool = true  # every enemy drops its body-part skill
const SKILL_FX_DIST: float = 70.0  # m — skip cast/pickup FX beyond this (perf)
const LIMB_CLUSTER_MAX: int = 24  # hard cap on limbs rendered on the body (perf + tidy)
# Active-ability base tuning (skill level scales these — applied in SkillDirector):
const SKILL_DASH_IMPULSE: float = 14.0  # forward+up leap velocity
const SKILL_SLAM_RADIUS: float = 5.0
const SKILL_SLAM_DAMAGE: float = 45.0
const SKILL_SLAM_STAGGER: float = 1.4
const SKILL_BLINK_RANGE: float = 9.0
const SKILL_MORTAR_RADIUS: float = 4.0
const SKILL_MORTAR_DAMAGE: float = 55.0
const SKILL_SHIELD_AMOUNT: float = 60.0
const SKILL_SHIELD_TIME: float = 5.0
const SKILL_RAM_RANGE: float = 8.0
const SKILL_RAM_DAMAGE: float = 50.0
const SKILL_CHAIN_JUMPS: int = 2
const SKILL_CHAIN_DAMAGE: float = 30.0
# Bite widened (playtest: «дамажащие скилы бьют крошечную область»).
const SKILL_BITE_RANGE: float = 6.5
const SKILL_BITE_ANGLE: float = 60.0  # degrees half-angle of the bite cone
const SKILL_BITE_DAMAGE: float = 50.0
const SKILL_WHIRL_RADIUS: float = 4.5
const SKILL_WHIRL_DAMAGE: float = 35.0
const SKILL_RECON_RADIUS: float = 22.0

# MOBA-style rework (v0.4.5): targeted casts aim at the CAMERA CROSSHAIR ground
# point («метеорит в точку куда смотрим»), spectacle-first VFX.
const SKILL_TARGET_RANGE: float = 30.0  # max planar cast distance from the caster
# METEOR (mortar family): telegraph ring → a flaming rock falls → impact breaks
# WALLS (BreakableChunk) + burns machines (chemistry) — Invoker/Doomfist grammar.
const SKILL_METEOR_DELAY: float = 0.9  # telegraph seconds before impact
const SKILL_METEOR_RADIUS: float = 5.0
const SKILL_METEOR_DAMAGE: float = 75.0
const SKILL_METEOR_BREAK_R: float = 2.6  # wall-chunk demolition radius at impact
const SKILL_METEOR_BURN: float = 4.0  # burn seconds applied to victims
# STORM (whirlwind family): a Crystal-Maiden-style field — explosions rain in a
# ring around the CAST POINT for several seconds, slowing machines caught inside.
const SKILL_STORM_TIME: float = 4.0
const SKILL_STORM_PULSES: int = 6
const SKILL_STORM_RING_MIN: float = 2.5
const SKILL_STORM_RING_MAX: float = 7.0
const SKILL_STORM_PULSE_RADIUS: float = 3.0
const SKILL_STORM_PULSE_DMG: float = 24.0
const SKILL_STORM_SLOW: float = 2.5  # slow seconds per pulse hit
# LEAP SLAM (slam family): a ballistic leap TO the aim point + a landing shockwave.
const SKILL_LEAP_TIME: float = 0.55  # airtime — the server delays the AoE to landing
# BREACH (ram family): the charge SMASHES THROUGH breakable walls along its path.
const SKILL_BREACH_BREAK_R: float = 1.5
# CLOAK (recon family, «читаемость скилов» rework): active camo — machines drop you
# as a target for the duration; firing BREAKS it. Reveal pulse pings enemies nearby.
const SKILL_CLOAK_TIME: float = 5.0
# SHIELD rework: a VISIBLE energy dome that CATCHES bullets (frozen in the field) —
# absorption via the existing _overshield pool; the bubble lives until the pool
# empties or SKILL_SHIELD_TIME passes.

# --- Mutant Harvest DEPTH (v0.4.1): passives, set synergies, combos, evolution -------------
## Each skill's archetype (drives SET bonuses) — melee / ranged / mobility / defense.
const SKILL_ARCHETYPES := {
	"leap": "mobility",
	"slam": "melee",
	"blink": "mobility",
	"mortar": "ranged",
	"shield": "defense",
	"ram": "melee",
	"chainshock": "ranged",
	"bite": "melee",
	"whirlwind": "melee",
	"recon": "ranged",
}
## A PASSIVE that applies WHILE the limb is worn (level-scaled), even without casting.
## stat: "damage" (gun + ability) or "toughness" (incoming-damage reduction). skill_id -> {..}.
const SKILL_PASSIVES := {
	"leap": {"stat": "toughness", "per_level": 0.015},
	"slam": {"stat": "damage", "per_level": 0.04},
	"blink": {"stat": "toughness", "per_level": 0.015},
	"mortar": {"stat": "damage", "per_level": 0.03},
	"shield": {"stat": "toughness", "per_level": 0.05},
	"ram": {"stat": "damage", "per_level": 0.04},
	"chainshock": {"stat": "damage", "per_level": 0.03},
	"bite": {"stat": "damage", "per_level": 0.04},
	"whirlwind": {"stat": "damage", "per_level": 0.035},
	"recon": {"stat": "damage", "per_level": 0.025},
}
## SET bonuses: holding N distinct skills of an archetype grants a build-defining passive.
## archetype -> [[count, stat, value], ...] (highest matching threshold per archetype applies).
const SKILL_SETS := {
	"melee": [[2, "damage", 0.12], [3, "damage", 0.25]],
	"ranged": [[2, "damage", 0.10], [3, "damage", 0.20]],
	"mobility": [[2, "toughness", 0.10]],
	"defense": [[1, "toughness", 0.10]],
}
const SKILL_PASSIVE_DMG_CAP: float = 0.8  # cap total bonus gun/ability damage at +80%
const SKILL_PASSIVE_TOUGH_CAP: float = 0.6  # cap total incoming-damage reduction at 60%
# Combo: casting a DIFFERENT skill within the window empowers it (bigger effect + cd refund).
const SKILL_COMBO_WINDOW: float = 3.0  # s after a cast that the next (different) cast can combo
const SKILL_COMBO_MULT: float = 1.5  # empowered effect multiplier
const SKILL_COMBO_CD_REFUND: float = 0.4  # fraction of the empowered cast's cooldown refunded
# Evolution: a skill at max_level MUTATES — its effect gets this multiplier + a distinct look.
const SKILL_EVOLVE_MULT: float = 1.6


## Archetype of a skill (for set bonuses), or "" if unknown.
func skill_archetype(id: String) -> String:
	return String(SKILL_ARCHETYPES.get(id, ""))


# --- Local building destruction (v0.4.1): shoot a wall -> a hole crumbles where you hit ----
# Walls are split into a grid of breakable CELLS (BreakableChunk), so a burst punches a localized
# hole exactly where you shoot (user's pick). With the toggle false, _solid is byte-identical to a
# plain StaticBody3D (no cell, no naming) -> world + golden unaffected.
const CHUNK_DESTRUCTION_ENABLED: bool = true  # master toggle for BreakableChunk wall cells
const CHUNK_HP: float = 16.0  # HP per wall CELL — a shot (~10-12 dmg) pops a small cell precisely
const CHUNK_NOISE: float = 14.0  # how loud a crumbling cell is to enemy hearing (m)
const CHUNK_CELL_SIZE: float = 0.8  # wall grid-cell edge (m) — FINE "voxel-ish" hole granularity
const CHUNK_GRID_MIN: float = 1.0  # walls whose wide/height ≤ this stay ONE cell (no grid)
# Big flat slabs (floors/roofs/containers) grid at a coarser-than-wall cell. 2.8 → 1.4 in the
# merged-render pass: containers/floors were breaking «кусками большими» (user), and with cells
# batched into MultiMeshes the extra pieces cost bodies, not draw calls.
const CHUNK_CELL_SIZE_BIG: float = 1.4  # grid edge (m) for floors/roofs/containers
const CHUNK_BREAK_FLOORS: bool = true  # floors/roofs/containers/pillars also crumble (user's pick)
# Falling physics DEBRIS on crumble (RigidBody shards that fall + tumble, then fade). Purely
# local/visual (collision_layer 0, mask 1 = world only) so it never desyncs co-op or the navmesh.
const CHUNK_DEBRIS_ENABLED: bool = true  # spawn falling RigidBody shards (vs static rubble)
const CHUNK_DEBRIS_PER_CELL: int = 10  # shards per crumbled cell (scaled down near the global cap)
const CHUNK_DEBRIS_CAP: int = 200  # global concurrent live shards — over this, cells drop fewer
const CHUNK_DEBRIS_LIFETIME: float = 3.6  # seconds a shard lives before it fades + frees
const CHUNK_DEBRIS_FADE: float = 2.4  # shard age (s) at which the fade-out starts
const CHUNK_FLASH_ENABLED: bool = true  # a brief OmniLight pop on crumble (rate-limited; dark grade)
# Merged-render (v0.4.4 perf): breakable BOX cells render in per-(parent,material) MultiMesh
# batches (ChunkMeshMerger) instead of ~4k per-cell MeshInstances whose draw calls halved fps
# at POIs. OFF = the old per-cell path (visual A/B / dial-back). World-triplanar materials make
# the batched scaled unit-cube shade identically to the old sized box.
const CHUNK_MERGED_RENDER: bool = true

# --- Material-typed destruction (v0.4.3): a chunk's `material_kind` selects its debris look, break
# SFX, HP, and bullet-penetration. Threaded onto the node at BUILD on EVERY peer (the build is
# identical), so it never rides the crumble RPC. CONCRETE is the default → walls/floors are
# unchanged and the golden OFF path stays byte-identical. AudioManager/ChunkDebris read it locally.
const CHUNK_KIND_CONCRETE: int = 0
const CHUNK_KIND_METAL: int = 1  # containers — thin steel: low HP + bullets penetrate + sparks
const CHUNK_KIND_STONE: int = 2  # boulders + small rocks — earthy chunky shards
# Per-kind tunables. `debris_mult`×CHUNK_DEBRIS_PER_CELL; `hp_mult`×CHUNK_HP (metal thinner → 0.6);
# `shard_flat` = shard box height factor (metal=flat panels, stone=chunky); `shard_size` scale;
# `metallic`/`roughness`/`tint_lighten` style the shards (lightened so they read in the dark grade).
const CHUNK_KIND_DEFS := {
	CHUNK_KIND_CONCRETE:
	{
		"debris_mult": 1.0,
		"hp_mult": 1.0,
		"shard_flat": 0.72,
		"shard_size": 1.0,
		"metallic": 0.2,
		"roughness": 0.92,
		"tint_lighten": 0.15,
		"spark": false,
		"sfx": "chunk_concrete",
	},
	CHUNK_KIND_METAL:
	{
		"debris_mult": 0.8,
		"hp_mult": 0.6,
		"shard_flat": 0.22,
		"shard_size": 1.5,
		"metallic": 0.7,
		"roughness": 0.35,
		"tint_lighten": 0.2,
		"spark": true,
		"sfx": "chunk_metal",
	},
	CHUNK_KIND_STONE:
	{
		"debris_mult": 1.3,
		"hp_mult": 1.5,
		"shard_flat": 0.85,
		"shard_size": 0.8,
		"metallic": 0.0,
		"roughness": 1.0,
		"tint_lighten": 0.1,
		"spark": false,
		"sfx": "chunk_stone",
	},
}
# Bullet penetration: a METAL chunk lets the shot pass THROUGH (it's not solid cover like a wall) up
# to MAX times, losing FALLOFF of its damage per pass; concrete/stone STOP the ray. The pierced
# chunk still takes (scaled) damage so a container breaks. Anti-spam SFX throttle for crumbles.
const CHUNK_PENETRATE_METAL: bool = true
const CHUNK_PENETRATE_MAX: int = 2
const CHUNK_PENETRATE_FALLOFF: float = 0.55
const CHUNK_SFX_MIN_INTERVAL: float = 0.08  # min seconds between crumble SFX (burst → 1-2, not 14)
# Small breakable rocks (_build_stones → shoot-only): on this NON-world layer so the navmesh + the
# player ignore them (no tripping, no nav-fragmentation) but the weapon ray + grenades still break
# them. The weapon's hurtbox_mask gets this bit added so shots register.
const CHUNK_ROCK_LAYER: int = 8  # physics layer for shoot-only small rocks (bit 7)

## Learned-counter trait → stat effects (same shape discipline as ELITE_MOD_STATS). Resists
## that aren't a simple _stat_* mult (EMP/blast) are read at their resist site, not here.
## "weakpoint_armored" sets the WeakPoint Hurtbox damage_multiplier to an ABSOLUTE armor_mult
## (the former weak spot is now armored, ~0.8× body — works for any base 2.0/2.5/×3).
const NEMESIS_TRAIT_STATS := {
	"weakpoint_armored": {"armor_mult": 0.8},
	"blast_hard": {"blast_mult": 0.5},
	"keen": {"detect_mult": 1.4},
}

# --- Recon drone (robot_specter) ---------------------------------------------
const RECON_RETREAT_TIME: float = 6.0  # flee duration after a successful call
const RECON_RECHANNEL_CD: float = 10.0  # s before it may channel again

# --- Siege world event (kind 4) ------------------------------------------------
const SIEGE_HOLD_TIME: float = 60.0  # s of in-zone presence to win
const SIEGE_WAVE_INTERVAL: float = 12.0  # s between reinforcement waves
const SIEGE_WAVE_BASE: int = 2  # first wave size (grows +1 per wave)
const SIEGE_LOOT_COUNT: int = 6  # tier-3 loot rolls on success
const SIEGE_MAX_LIFETIME: float = 150.0  # director failsafe timeout
const SIEGE_RADIUS: float = 10.0  # defend-zone radius (m)

# --- Day-night cycle (batch C) ---------------------------------------------------
# In-raid time is a PURE function of the synced match timer (DayNight.hour_for —
# scripts/core/day_night.gd): zero new netcode, headless-server identical.
const DAY_NIGHT_START_HOUR: float = 10.0  # matches Sky3D's authored morning look
const DAY_NIGHT_HOURS_PER_MATCH: float = 12.0  # full timer spans 10:00 → 22:00
const NIGHT_FROM_HOUR: float = 19.5  # is_night window [FROM .. 24) ∪ [0 .. TO)
const NIGHT_TO_HOUR: float = 5.5
const NIGHT_DETECT_MULT: float = 0.75  # enemy sight range × this at night
const NIGHT_RAID_START_HOUR: float = 18.5  # clock start under the night_raid mutator

# --- Locked annexes + keys (batch C) ----------------------------------------------
# Key-gated loot rooms attached to the 3 tier-3 landmarks. Keys are biome-matched
# consumable items (Kind.KEY): 6% drop from elites/minibosses dying in that biome,
# shop-buyable, bring-able (replicated `_keys` counts on the player).
const LOCKED_ROOM_POIS := {
	"POI_NorthTower": {"key": "key_tower", "theme": "tower"},
	"POI_SnowLodge": {"key": "key_lodge", "theme": "snow_lodge"},
	"POI_Temple": {"key": "key_temple", "theme": "temple"},
}
const KEY_DROP_CHANCE: float = 0.06  # per elite/miniboss death, biome-matched key
const KEY_SHOP_PRICE: int = 700
const LOCKED_DOOR_HOLD_TIME: float = 2.5  # hold-E seconds at the keypad
const LOCKED_LOOT_ROLLS: int = 3  # EPIC rolls per opened annex

# --- Extraction zone types (batch C) ----------------------------------------------
# Typed zones read their OWN node name here (zero Arena.tscn edits). "paid" stays
# closed until a 300-cr charge force-opens it; "signal" opens via a flare but rings
# the dinner bell. Default (absent) = the classic rotating-window zone.
const EXTRACTION_ZONE_TYPES := {
	"ExtractionZone4": "paid",
	"ExtractionZone9": "paid",
	"ExtractionZone7": "signal",
}
const PAID_EXTRACT_COST: int = 300
const PAID_EXTRACT_WINDOW: float = 30.0  # s the bought window stays open
const SIGNAL_EXTRACT_WINDOW: float = 45.0
const SIGNAL_FLARE_NOISE: float = 60.0  # report_noise radius — the whole area hears
const SIGNAL_REINFORCEMENTS: int = 4  # guaranteed wave on flare

# --- Raid mutators (batch C) -------------------------------------------------------
# Rolled ONCE on the server in _begin_deploy (BEFORE load_arena — double_loot is
# read at build), synced via NetworkManager.sync_mutator; "" = no mutator.
const RAID_MUTATOR_CHANCE: float = 0.35
const RAID_MUTATORS := ["fog", "double_loot", "elite_patrols", "night_raid"]
const MUTATOR_FOG_DENSITY: float = 0.0175  # half the storm's whole-map murk
const MUTATOR_ELITE_PATROL_BONUS: float = 0.25  # added elite-mod chance in patrols

# --- Armor / gear (batch B) ---------------------------------------------------------
# Worn gear slots (ArmorData.slot must be one of these). Mitigation from intact
# pieces is summed and CAPPED; absorbed damage drains per-item-ID durability
# (MetaProgression.armor_durability — two identical vests share one durability pool,
# a documented limitation of id-keyed persistence). 0 durability = BROKEN (inert).
const GEAR_SLOTS := ["helmet", "vest", "backpack"]
const ARMOR_MITIGATION_CAP: float = 0.45  # max summed damage reduction
const ARMOR_REPAIR_COST_FRAC: float = 0.4  # repair = ceili(value * this * missing_frac)

# --- Secure pouch (batch B) ---------------------------------------------------------
# In-raid pouch: items secured here survive DEATH (deposited with no bonus). Server-
# validated (slots/weight); the death deposit routes like grant_extraction.
const SECURE_SLOTS: int = 2
const SECURE_MAX_WEIGHT: float = 2.0  # per-item weight ceiling to secure

# --- Status effects / medicine 2.0 (batch B) ----------------------------------------
const BLEED_HIT_THRESHOLD: float = 12.0  # enemy hit >= this may inflict bleed
const BLEED_CHANCE: float = 0.35
const BLEED_DPS_TICK: float = 2.0  # damage per tick
const BLEED_TICK_INTERVAL: float = 2.0  # seconds between ticks
const BLEED_DURATION: float = 30.0  # self-clears after this (or a bandage)
const FRACTURE_FALL_SPEED: float = 14.0  # landing with a fall peak above this
const FRACTURE_HIT_THRESHOLD: float = 30.0  # ...or a single hit >= this
const FRACTURE_SPEED_MULT: float = 0.7  # move speed while fractured (no sprint)
const PAINKILLER_DURATION: float = 60.0  # suppresses status PENALTIES (not the DoT)

# --- Insurance (batch B) -------------------------------------------------------------
# Insure equipped gear/attachments for a fraction of value; a DEATH converts insured
# items to "pending" and they return to the stash after the real-time delay.
const INSURANCE_COST_FRAC: float = 0.30
# M5.6: was 10 real minutes — a friction timer nobody enjoyed. Insured gear now
# returns by the time you're back in the Hub (30 s covers the summary screen).
const INSURANCE_RETURN_MINUTES: float = 0.5

# Biomes: WorldBounds.biome_at(x,z) (scripts/core/world_bounds.gd) classifies the 4×
# map quadrants (NW urban / NE snow / SW desert / SE rain) for biome-EXCLUSIVE spawning.

# Difficulty multipliers, keyed by GameState.Difficulty. enemy_health/enemy_damage
# scale per-enemy stats (robot_enemy._load_stats); enemy_count scales the wave size
# (wave_manager._enemy_count_for_wave); player_damage scales outgoing weapon damage
# (a small assist on Easy / handicap on Hard). Normal is the 1.0 baseline.
const DIFFICULTY_MODS := {
	0: {"enemy_health": 0.55, "enemy_damage": 0.50, "enemy_count": 0.60, "player_damage": 1.40},  # EASY
	1: {"enemy_health": 1.00, "enemy_damage": 1.00, "enemy_count": 1.00, "player_damage": 1.00},  # NORMAL
	2: {"enemy_health": 1.45, "enemy_damage": 1.40, "enemy_count": 1.35, "player_damage": 0.90},  # HARD
}


## Returns the multiplier dict for a GameState.Difficulty value (falls back to Normal).
func difficulty_mods(d: int = -1) -> Dictionary:
	if d < 0:
		d = GameState.difficulty
	return DIFFICULTY_MODS.get(d, DIFFICULTY_MODS[1])


# Sprint stamina + interaction range.
const MAX_STAMINA: float = 100.0
const STAMINA_DRAIN: float = 28.0  # per second while sprinting
const STAMINA_REGEN: float = 22.0  # per second while not sprinting
const STAMINA_SPRINT_MIN: float = 10.0  # need at least this to start sprinting
const INTERACT_RANGE: float = 3.5  # metres for the "[E]" prompt

# Runtime-mutable settings (driven by SettingsManager / the settings menu).
var mouse_sensitivity: float = MOUSE_SENSITIVITY
var fov: float = DEFAULT_FOV  # camera FOV (player.gd reads this)
var sfx_volume: float = 0.9  # 0..1, applied to AudioManager
var invert_y: bool = false
var ads_toggle: bool = false  # false = hold to aim, true = toggle
# HUD layout (ultrawide comfort): edge-anchored UI insets toward center by these fractions
# of the viewport (0 = at the screen edge). Read by minimap/killfeed/hud/stats_overlay.
var ui_edge_margin: float = 0.0  # horizontal inset (fraction of viewport width)
var ui_top_margin: float = 0.0  # vertical inset (fraction of viewport height)
# "Military glass" UI FX master toggle (set by SettingsManager from the Interface tab):
# scanline/grain/vignette overlay + frosted-glass blur behind modals. Read by FXOverlay
# + GlassBackdrop; false → plain dim (cheap fallback for Low-end / preference).
var ui_fx_enabled: bool = true
# Camera (set by SettingsManager from the Interface tab; read by the player rig).
var camera_distance_scale: float = 1.0  # multiplies DEFAULT_SPRING_LENGTH (third-person distance)
var camera_shoulder_scale: float = 1.0  # multiplies SHOULDER_OFFSET (over-shoulder side offset)
var default_first_person: bool = false  # spawn in first-person view
# Graphics-quality scale for rebuild-bound levers (set by SettingsManager from the quality
# preset; read at arena build, so a change applies on the NEXT raid). 1.0 = Ultra ceiling.
var grass_density_scale: float = 1.0  # multiplies the near/far grass caps in procedural_flora
var water_refraction: float = 0.12  # water.gdshader refract_amt baked at water build (0 = flat/cheap)
# "RT-style" tier rebuild-bound levers (scene nodes spawned at arena build; Ultra+RT only).
var reflection_probes_enabled: bool = false  # spawn baked ReflectionProbes at POIs (off-screen reflections)
var voxelgi_enabled: bool = false  # EXPERIMENTAL runtime VoxelGI bake (heavy)
# Cinematic pass III rebuild-bound levers (read at arena build; apply on the NEXT raid).
var draw_distance_scale: float = 1.0  # multiplies flora/grass visibility ranges
var terrain_detail_scale: float = 1.0  # multiplies ground-mesh subdivision density
var terrain_parallax_enabled: bool = false  # parallax-occlusion mapping baked into the ground material
var local_fog_enabled: bool = false  # spawn localized FogVolume zones at POIs
var climate_zones_enabled: bool = true  # spawn localized rain/snow/desert zones at the far landmarks
var climate_density: float = 1.0  # multiplies climate precipitation amount + fog density (0..2)

# --- Multi-instance / git-worktree parallelism -----------------------------
# To run several game instances at once (each driven by its own agent, often from a
# separate git worktree) THREE things must be made per-instance so they never clash:
#   1. agent control port + user:// files → `--agent-port N` (agent_port=N, instance_tag=N).
#   2. the NETWORK ports (ENet game + LAN discovery) → `--net-port N` (net_port=N,
#      discovery_port=N+1 unless `--discovery-port M`). All members of ONE co-op group
#      share the same --net-port; different worktrees pick DIFFERENT --net-ports so two
#      groups can host concurrently on one machine. (Don't derive it from agent_port — a
#      group's host and clients have different agent_ports but must share one net_port.)
#   3. a human-readable label (usually the worktree's branch) → `--label <text>`, folded
#      into the window title so each process is identifiable in the OS / task manager.
# Without any flag, single-instance defaults are preserved (un-suffixed user://, the
# canonical 24565/24566/24700). Resolved once at startup; Settings autoloads before
# AgentBridge / NetworkManager / MetaProgression / SettingsManager so they read these safely.
var agent_port: int = AGENT_PORT
var instance_tag: String = ""
var net_port: int = DEFAULT_PORT  # ENet game port (host bind / client connect / discovery reply)
var discovery_port: int = DISCOVERY_PORT  # LAN-discovery UDP port (defaults to net_port + 1)
var instance_label: String = ""  # e.g. the worktree branch; shown in the window title
## EPHEMERAL: when true, PROGRESSION saves (profile/stash) are no-ops — for test runs that must
## not persist or touch the real save. Set by --no-save.
var ephemeral_save: bool = false


func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	agent_port = _arg_int(args, "--agent-port", agent_port)
	if agent_port != AGENT_PORT:
		instance_tag = str(agent_port)
	# Any --agent run uses an ISOLATED profile (never the real user://profile.cfg): an explicit
	# --agent-port suffixes by port; a bare --agent suffixes "agent". Belt-and-suspenders with
	# --no-save (which also stops progression persisting at all).
	elif "--agent" in args:
		instance_tag = "agent"
	ephemeral_save = "--no-save" in args
	# Network ports: --net-port sets the game port and (by default) discovery = net_port + 1;
	# --discovery-port overrides the discovery port explicitly.
	net_port = _arg_int(args, "--net-port", net_port)
	discovery_port = net_port + 1 if net_port != DEFAULT_PORT else DISCOVERY_PORT
	discovery_port = _arg_int(args, "--discovery-port", discovery_port)
	instance_label = _arg_str(args, "--label", instance_label)
	# Data-table validation (debug builds only): typo'd keys / missing scene paths in the
	# untyped catalogs become LOUD push_errors at boot instead of silent fallbacks.
	# Deferred so every autoload (MetaProgression et al) exists before it reads them.
	BootValidate.run.call_deferred()


## Reads the int value following `flag` in args (guards a missing/flag-like/non-int value),
## else returns `fallback`.
func _arg_int(args: PackedStringArray, flag: String, fallback: int) -> int:
	var idx := args.find(flag)
	if idx != -1 and idx + 1 < args.size():
		var raw := args[idx + 1]
		if not raw.begins_with("--") and raw.is_valid_int():
			return int(raw)
	return fallback


## Reads the string value following `flag` in args, else returns `fallback`.
func _arg_str(args: PackedStringArray, flag: String, fallback: String) -> String:
	var idx := args.find(flag)
	if idx != -1 and idx + 1 < args.size():
		var raw := args[idx + 1]
		if not raw.begins_with("--"):
			return raw
	return fallback


## The window title for this instance: plain "Hype Raiders" for a normal single run, else
## "Hype Raiders_<label>" (worktree branch) with the control/net ports appended so parallel
## instances are tellable apart in the OS task manager / window list.
func window_title() -> String:
	if instance_label == "" and instance_tag == "":
		return "Hype Raiders"
	var tag := instance_label if instance_label != "" else instance_tag
	return "Hype Raiders_%s [a:%d n:%d]" % [tag, agent_port, net_port]


## Per-instance user:// path. Single instance → `user://<base>.<ext>`; under
## `--agent-port N` → `user://<base>_N.<ext>`, so concurrent instances never clobber
## each other's saves/screenshots.
func user_path(base: String, ext: String) -> String:
	if instance_tag == "":
		return "user://%s.%s" % [base, ext]
	return "user://%s_%s.%s" % [base, instance_tag, ext]
