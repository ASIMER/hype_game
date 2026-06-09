extends Node
## Tunable constants + simple runtime settings. Centralized so designers/agents
## tweak balance in one place instead of hunting through scenes.

# Networking
const DEFAULT_PORT: int = 24565
const MAX_PLAYERS: int = 8   # listen-server cap; "however many friends join" (ENet-safe)
const DEFAULT_IP: String = "127.0.0.1"
## UDP port the host answers LAN-discovery pings on (separate from the ENet game port
## so it doesn't fight the ENet socket). ServerBrowser broadcasts here to find servers.
const DISCOVERY_PORT: int = 24566
## Game build version (canonical = the VERSION file at the repo root). Stamped into
## save files so loads survive game updates (see MetaProgression/Stash version checks).
const GAME_VERSION: String = "0.3.0"
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
	1: { "currency": 200 },
	2: { "currency": 400 },
	3: { "currency": 700 },
	4: { "currency": 1200 },
}
# When true, the netcode emits [net]/[arena]/[client] diagnostic prints (connection,
# roster sync, spawn/replication). Off for normal play; flip on to debug co-op.
const NET_DEBUG: bool = false

# Agent self-play harness: in-game TCP control server port (localhost). Only
# listens when the game is launched with --agent (see AgentBridge / main.gd).
const AGENT_PORT: int = 24700

# Terrain / world visuals (ALL world-gen must stay deterministic for co-op — every
# peer builds its own arena locally, so geometry derives ONLY from these constants).
const TERRAIN_SEED: int = 1337            # the one seed all terrain noise derives from
const TERRAIN_CELL: float = 1.0           # heightmap grid step (m); 1 m = smooth river banks
const TERRAIN_HILL_AMP: float = 3.5       # max rolling-hill height (m); keep slopes well under 47°
const TERRAIN_RIM_HEIGHT: float = 7.0     # rocky berm height near the perimeter walls
const RIVER_WIDTH: float = 5.0            # river channel width (m)
const RIVER_DEPTH: float = 0.45           # ≤ navmesh agent_max_climb 0.5 → walkable ford everywhere
# Flora budgets (MultiMesh where possible; trees/boulders are individual nodes)
const FLORA_TREES: int = 80
const FLORA_BUSHES: int = 60
const FLORA_GRASS_PATCHES: int = 14000    # near grass layer (MultiMesh; fine dense blades)
const FLORA_GRASS_FAR: int = 3000         # sparse far grass layer (larger tufts)
const GRASS_VIS_RANGE: float = 58.0       # near-layer visibility_range_end (m); wider so grass doesn't pop on the 160m map
const GRASS_FAR_RANGE: float = 90.0       # far-layer visibility_range_end (m)
const FLORA_STONES: int = 400             # small render-only stones (MultiMesh)
const FLORA_BOULDERS: int = 14            # big collidable cover rocks
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
const PLAYER_CROUCH_SPEED: float = 2.6      # m/s while crouched
const CROUCH_CAMERA_DROP: float = 0.55      # camera_pivot.y drop when crouched
const SLIDE_SPEED: float = 9.5              # initial slide speed (decays to crouch speed)
const SLIDE_TIME: float = 0.7               # slide duration (s)
const SLIDE_CAMERA_DROP: float = 0.8        # camera drop during a slide
const CROUCH_CAMERA_LERP: float = 10.0      # camera-height ease speed
# Stance spread multipliers (applied to weapon.spread_deg at fire time — crouch < stand <
# move < sprint, ADS tightest; the dynamic crosshair shows the resulting cone).
const SPREAD_MULT_CROUCH: float = 0.45
const SPREAD_MULT_STAND: float = 1.0
const SPREAD_MULT_MOVE: float = 1.7
const SPREAD_MULT_SPRINT: float = 2.6
const SPREAD_MULT_SLIDE: float = 3.0
const SPREAD_MULT_ADS: float = 0.4
const FP_SPRING_LENGTH: float = 0.15        # spring length in first-person view
# Co-op downed / revive loop.
const BLEEDOUT_TIME: float = 45.0           # seconds downed before true death (no revive)
const REVIVE_CHANNEL_TIME: float = 4.0      # hold-to-revive duration (s)
const REVIVE_HEALTH_FRAC: float = 0.35      # fraction of max HP restored on revive
const DOWNED_MOVE_SPEED: float = 2.0        # crawl speed while downed (m/s) — enough to reach cover / an evac
const DOWNED_CAMERA_DROP: float = 1.0       # camera drop while downed
const GIVE_UP_HOLD_TIME: float = 2.0        # hold the give_up key this long while downed to self-finish (skip bleedout)
const CARRY_SPEED_MULT: float = 0.5         # carrier move-speed multiplier while carrying a buddy
const KNOCKDOWN_SHIELD_ABSORB: float = 150.0 # damage a knockdown shield soaks while downed
const SELF_REVIVE_ITEM: String = "loot_self_revive"       # consumable id that self-revives when downed
const KNOCKDOWN_SHIELD_ITEM: String = "loot_knockdown_shield"

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

# --- AI perception / sound stealth (Batch 2 "Living threat") ----------------
# A noise's audible RADIUS in metres. The server's enemy perception hears any noise
# whose radius reaches it; non-hunter enemies INVESTIGATE the source (or CHASE if very
# close). Gunfire/grenades route through NetworkManager.report_noise; footstep loudness
# is derived per-frame from a player's speed + stance (no RPC — server reads synced state).
const NOISE_GUNFIRE: float = 22.0            # unsuppressed shot audible radius
const NOISE_GRENADE: float = 34.0            # explosion audible radius (always loud)
const NOISE_WALK: float = 8.0                # standing/walking footstep loudness
const NOISE_SPRINT: float = 16.0             # sprinting is loud
const NOISE_CROUCH_MULT: float = 0.4         # crouch-walking is quiet (×NOISE_WALK)
const NOISE_IDLE: float = 2.5                # barely-moving hum (still faintly audible up close)
# A noise this loud or louder at the enemy counts as a "spike" → CHASE straight away
# (instead of the cautious INVESTIGATE walk-to-the-sound). Fraction of the heard radius.
const NOISE_CHASE_FRACTION: float = 0.45
# A non-hunter patrol NOTICES a player within this radius even without clean line-of-sight or
# loud footsteps (so a patrol you walk right up to engages instead of standing idle). Beyond it,
# the normal hearing/LOS stealth applies. Read by robot_enemy's perception.
const PROXIMITY_AGGRO_RADIUS: float = 9.0
# INVESTIGATE behaviour: move to the last-heard point at this speed mult, look around,
# then give up after GIVEUP seconds with no confirmation and return to PATROL.
const INVESTIGATE_SPEED_MULT: float = 0.8
const INVESTIGATE_GIVEUP: float = 8.0        # seconds investigating before giving up
const INVESTIGATE_ARRIVE: float = 1.8        # within this of the point = "arrived, look around"
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
const DIRECTOR_CAMP_COOLDOWN: float = 18.0   # min seconds between flank punishes
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
	"POI_NorthTower":   3,
	"POI_EastWarehouse": 1,
	"POI_Plaza":        2,
	"POI_SWHouse":      1,
	"POI_SouthYard":    2,
	"POI_EastYard":     3,
}
# Per-tier loot rarity band [min, max] (ItemData.Rarity: 0 COMMON…4 LEGENDARY). The
# loot_tables roll picks within the band, weighted toward the lower (commoner) end.
const RISK_TIER_LOOT := {
	1: [0, 1],   # COMMON–UNCOMMON
	2: [1, 2],   # UNCOMMON–RARE
	3: [2, 3],   # RARE–EPIC
}
# How many world-loot pickups to scatter near a POI of each tier (at arena build).
const RISK_TIER_CACHE_COUNT := { 1: 2, 2: 3, 3: 4 }
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
const SUPPLY_CACHE_HOLD_TIME: float = 8.0     # seconds a player must hold the cache to crack it
const SUPPLY_CACHE_GUARDS: int = 3            # defenders spawned around a cache
const SUPPLY_CACHE_LOOT: int = 5              # loot pickups dropped when cracked
const MINIBOSS_REWARD_CURRENCY: int = 150     # bonus on the mini-boss kill
const CONTESTED_POI_DURATION: float = 45.0    # how long a POI stays "hot"
const CONTESTED_POI_GUARDS: int = 4
const SURGE_DURATION: float = 25.0            # enemy-surge / sensor-blackout window

# --- Progression: Raider Level + XP (Batch 3) --------------------------------
# Account XP curve: xp needed to go from level n→n+1 = BASE * GROWTH^(n-1).
const XP_CURVE_BASE: float = 1000.0
const XP_CURVE_GROWTH: float = 1.35
const SKILL_POINTS_PER_LEVEL: int = 1
const XP_PER_KILL: int = 30
const XP_PER_EXTRACT: int = 500
const XP_PER_EVENT: int = 250                 # completing a world event
const XP_PER_RARE_LOOT: int = 60              # per RARE+ item in the extracted haul
# Account skill tree. key -> { name, desc, max, mult_field (a player_mods key), per }.
# Skills fold MULTIPLICATIVELY into MetaProgression.player_mods() alongside upgrades.
const SKILLS := {
	"vitality":  { "name": "Vitality", "desc": "+6% max health / level", "max": 5, "field": "health_mult", "per": 0.06 },
	"scavenger": { "name": "Scavenger", "desc": "+8% loot value / level", "max": 5, "field": "loot_mult", "per": 0.08 },
	"endurance": { "name": "Endurance", "desc": "+8% stamina / level", "max": 5, "field": "stamina_mult", "per": 0.08 },
	"gunner":    { "name": "Gunner", "desc": "+4% weapon damage / level", "max": 5, "field": "damage_mult", "per": 0.04 },
}

# --- Power caches: timed buffs (Vampire-Survivors-style) ----------------------
# A Power Cache on the map, when opened, plays a non-blocking side reveal reel then grants ONE
# of these as a TIMED buff (~20-30s). `field` is the buff kind read at runtime by player/weapon.
# `mag` is the effect magnitude (mult delta, flat, or fraction depending on field). `free` powers
# can roll from raid 1; the rest are UNLOCKED with skill points (`cost`) in the RAIDER tab. `color`
# tints the reveal/icon. Pool that can roll = MetaProgression.available_powers().
const POWER_REVEAL_TIME: float = 2.6            # length of the non-blocking lottery reveal
# Power icons are CC BY 3.0 from game-icons.net (see docs/ASSETS.md / tools/art/fetch_power_icons.ps1).
const POWERS := {
	"berserk":    { "name": "Berserk",    "desc": "+60% weapon damage",        "field": "damage",      "mag": 0.60, "dur": 22.0, "color": Color(0.95, 0.32, 0.26), "rarity": 1, "free": true,  "cost": 0, "icon": "res://assets/ui/icons/powers/berserk.svg" },
	"rapidfire":  { "name": "Rapid Fire",  "desc": "+45% fire rate",            "field": "fire_rate",   "mag": 0.45, "dur": 22.0, "color": Color(0.98, 0.74, 0.25), "rarity": 1, "free": true,  "cost": 0, "icon": "res://assets/ui/icons/powers/rapidfire.svg" },
	"swift":      { "name": "Swift",       "desc": "+35% move speed",           "field": "speed",       "mag": 0.35, "dur": 25.0, "color": Color(0.30, 0.80, 0.95), "rarity": 1, "free": true,  "cost": 0, "icon": "res://assets/ui/icons/powers/swift.svg" },
	"overshield": { "name": "Overshield",  "desc": "Absorb 90 damage",          "field": "overshield",  "mag": 90.0, "dur": 30.0, "color": Color(0.40, 0.70, 1.00), "rarity": 1, "free": true,  "cost": 0, "icon": "res://assets/ui/icons/powers/overshield.svg" },
	"regen":      { "name": "Regen",       "desc": "Heal 9 HP/sec",             "field": "regen",       "mag": 9.0,  "dur": 20.0, "color": Color(0.36, 0.90, 0.55), "rarity": 1, "free": true,  "cost": 0, "icon": "res://assets/ui/icons/powers/regen.svg" },
	"lifesteal":  { "name": "Lifesteal",   "desc": "Heal 30% of damage dealt",  "field": "lifesteal",   "mag": 0.30, "dur": 22.0, "color": Color(0.80, 0.25, 0.55), "rarity": 2, "free": false, "cost": 1, "icon": "res://assets/ui/icons/powers/lifesteal.svg" },
	"juggernaut": { "name": "Juggernaut",  "desc": "−45% damage taken",         "field": "armor",       "mag": 0.45, "dur": 24.0, "color": Color(0.75, 0.78, 0.85), "rarity": 2, "free": false, "cost": 1, "icon": "res://assets/ui/icons/powers/juggernaut.svg" },
	"adrenaline": { "name": "Adrenaline",  "desc": "Infinite stamina + reload", "field": "adrenaline",  "mag": 0.40, "dur": 24.0, "color": Color(0.95, 0.55, 0.20), "rarity": 2, "free": false, "cost": 1, "icon": "res://assets/ui/icons/powers/adrenaline.svg" },
	"frenzy":     { "name": "Frenzy",      "desc": "+40% damage, fire & speed",  "field": "frenzy",      "mag": 0.40, "dur": 18.0, "color": Color(1.00, 0.40, 0.85), "rarity": 3, "free": false, "cost": 2, "icon": "res://assets/ui/icons/powers/frenzy.svg" },
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
	1: { "currency": 200, "blueprint": "" },
	2: { "currency": 400, "blueprint": "bp_suppressor" },
	3: { "currency": 700, "blueprint": "bp_stim" },
	4: { "currency": 1200, "blueprint": "bp_drum_mag" },
}
# Shop price discount fraction per rep tier (tier 0 = none … tier 4 = 20% off).
const REP_TIER_DISCOUNT := { 0: 0.0, 1: 0.05, 2: 0.10, 3: 0.15, 4: 0.20 }
const REP_PER_EXTRACT: int = 50
const REP_PER_CONTRACT: int = 120             # claiming a quest
const REP_PER_HIGH_TIER_HAUL: int = 80        # extracting RARE+ loot

# --- Progression: Weapon Mastery (Batch 3) -----------------------------------
# Per-weapon mastery XP from use (kills/damage). Level n→n+1 needs BASE*n mastery xp.
const WEAPON_MASTERY_BASE: float = 8.0        # ~8 kills for level 1, scaling up
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
	3:  { "kind": "unlock_weapon", "value": "smg",   "label": "Free SMG" },
	5:  { "kind": "stash",         "value": 25,      "label": "+25 Stash Capacity" },
	8:  { "kind": "currency",      "value": 500,     "label": "+500 Credits" },
	12: { "kind": "unlock_weapon", "value": "dmr",   "label": "Free DMR" },
}

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
	# Caller ("Snitch"): low HP, fast, keeps its distance and — instead of dealing
	# damage — fires Events.enemy_alerted so the director summons reinforcements. Kill
	# it fast or get swarmed. Behaviour lives in robot_caller.gd (caller flag).
	"robot_caller":  { "health": 30.0,  "speed": 5.0, "damage": 0.0,  "detect": 30.0, "attack_range": 14.0, "cooldown": 6.0,  "score": 30, "caller": true },
	# Elite grunt: a tankier, harder-hitting grunt with an exposed weak point (the
	# WeakPoint Hurtbox Area in its scene takes ×2.5 — reward precise fire).
	"robot_elite":   { "health": 140.0, "speed": 4.2, "damage": 15.0, "detect": 22.0, "attack_range": 2.4,  "cooldown": 1.1,  "score": 40 },
}

# Difficulty multipliers, keyed by GameState.Difficulty. enemy_health/enemy_damage
# scale per-enemy stats (robot_enemy._load_stats); enemy_count scales the wave size
# (wave_manager._enemy_count_for_wave); player_damage scales outgoing weapon damage
# (a small assist on Easy / handicap on Hard). Normal is the 1.0 baseline.
const DIFFICULTY_MODS := {
	0: { "enemy_health": 0.55, "enemy_damage": 0.50, "enemy_count": 0.60, "player_damage": 1.40 }, # EASY
	1: { "enemy_health": 1.00, "enemy_damage": 1.00, "enemy_count": 1.00, "player_damage": 1.00 }, # NORMAL
	2: { "enemy_health": 1.45, "enemy_damage": 1.40, "enemy_count": 1.35, "player_damage": 0.90 }, # HARD
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
# HUD layout (ultrawide comfort): edge-anchored UI insets toward center by these fractions
# of the viewport (0 = at the screen edge). Read by minimap/killfeed/hud/stats_overlay.
var ui_edge_margin: float = 0.0         # horizontal inset (fraction of viewport width)
var ui_top_margin: float = 0.0          # vertical inset (fraction of viewport height)
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
var grass_density_scale: float = 1.0    # multiplies the near/far grass caps in procedural_flora
var water_refraction: float = 0.12      # water.gdshader refract_amt baked at water build (0 = flat/cheap)
# "RT-style" tier rebuild-bound levers (scene nodes spawned at arena build; Ultra+RT only).
var reflection_probes_enabled: bool = false  # spawn baked ReflectionProbes at POIs (off-screen reflections)
var voxelgi_enabled: bool = false            # EXPERIMENTAL runtime VoxelGI bake (heavy)
# Cinematic pass III rebuild-bound levers (read at arena build; apply on the NEXT raid).
var draw_distance_scale: float = 1.0         # multiplies flora/grass visibility ranges
var terrain_detail_scale: float = 1.0        # multiplies ground-mesh subdivision density
var terrain_parallax_enabled: bool = false   # parallax-occlusion mapping baked into the ground material
var local_fog_enabled: bool = false          # spawn localized FogVolume zones at POIs

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
var net_port: int = DEFAULT_PORT          # ENet game port (host bind / client connect / discovery reply)
var discovery_port: int = DISCOVERY_PORT  # LAN-discovery UDP port (defaults to net_port + 1)
var instance_label: String = ""           # e.g. the worktree branch; shown in the window title
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
