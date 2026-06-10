## Boot-time data-table validation (docs/AUDIT.md F8) — debug builds only. The catalog
## Dictionaries (ENEMY_STATS / POWERS / UPGRADES / pools) are read via .get(key, default)
## at 30+ sites: a typo'd key silently serves the default and an unknown enemy id
## silently behaves like a grunt. This makes those mistakes LOUD (push_error) at boot.
## Release builds skip entirely. Called from Settings._ready.
class_name BootValidate

# Every ENEMY_STATS entry must carry these.
const _STAT_REQUIRED := ["health", "speed", "damage", "detect", "attack_range", "cooldown", "score"]
# Union of every stats key any system reads — an entry key OUTSIDE this list is a typo
# (or a new mechanic that must be added here in the same commit that reads it).
const _STAT_KNOWN := [
	"health", "speed", "damage", "detect", "attack_range", "cooldown", "score",
	"ranged", "flying", "caller", "hover", "burst",
	"fuse", "blast_damage", "blast_radius",
	"burrow_speed", "emerge_range", "surface_time",
	"leap_damage", "leap_radius",
	"pounce_range", "pounce_cooldown", "pounce_damage", "pounce_radius", "pounce_fwd", "pounce_up",
	"slam_damage", "slam_radius", "slam_windup",
	"slow_dur", "slow_mult",
	"blink_range", "blink_cooldown",
]


static func run() -> void:
	if not OS.is_debug_build():
		return
	_check_enemy_stats()
	_check_wave_pools()
	_check_named_catalog(Settings.POWERS, ["name", "desc", "color"], "Settings.POWERS")
	_check_named_catalog(
		MetaProgression.UPGRADES,
		["name", "desc", "max_level", "base_cost", "effect"],
		"MetaProgression.UPGRADES")
	_check_named_catalog(
		MetaProgression.WEAPON_PERKS,
		["name", "desc", "max_level", "base_cost", "field", "effect"],
		"MetaProgression.WEAPON_PERKS")


static func _check_enemy_stats() -> void:
	for id in Settings.ENEMY_STATS.keys():
		var stats: Dictionary = Settings.ENEMY_STATS[id]
		for req in _STAT_REQUIRED:
			if not stats.has(req):
				push_error("[boot-validate] ENEMY_STATS['%s'] missing required '%s'" % [id, req])
		for key in stats.keys():
			if not _STAT_KNOWN.has(key):
				push_error(
					("[boot-validate] ENEMY_STATS['%s'] has UNKNOWN key '%s' (typo? add it"
					+ " to BootValidate._STAT_KNOWN when a system reads it)") % [id, key])


## Every scene path in the wave manager's spawn pools must exist — a renamed scene
## otherwise silently empties a biome's roster (the Caller/Elite _spawnable_scenes bug).
static func _check_wave_pools() -> void:
	var wm_script: GDScript = load("res://scripts/waves/wave_manager.gd")
	if wm_script == null:
		push_error("[boot-validate] wave_manager.gd not found")
		return
	var consts: Dictionary = wm_script.get_script_constant_map()
	for cname in ["WAVE_POOLS", "STORM_POOL", "BIOME_WAVE_POOLS", "BIOME_STORM_POOLS", "BIOME_PATROL_POOLS"]:
		_check_pool_paths(consts.get(cname), "wave_manager.%s" % cname)


## Recursively walks pools (Dictionary of Arrays / nested) collecting res:// strings.
static func _check_pool_paths(pool: Variant, label: String) -> void:
	match typeof(pool):
		TYPE_DICTIONARY:
			for k in (pool as Dictionary).keys():
				_check_pool_paths((pool as Dictionary)[k], "%s[%s]" % [label, k])
		TYPE_ARRAY:
			for v in (pool as Array):
				_check_pool_paths(v, label)
		TYPE_STRING:
			var s := str(pool)
			if s.begins_with("res://") and not ResourceLoader.exists(s):
				push_error("[boot-validate] %s references MISSING scene '%s'" % [label, s])


static func _check_named_catalog(catalog: Dictionary, required: Array, label: String) -> void:
	for id in catalog.keys():
		var entry: Dictionary = catalog[id]
		for req in required:
			if not entry.has(req):
				push_error("[boot-validate] %s['%s'] missing required '%s'" % [label, id, req])
