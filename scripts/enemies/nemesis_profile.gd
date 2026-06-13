class_name NemesisProfile
extends RefCounted
## The persistent rival — the Machine Nemesis data object. A robot that SURVIVES a fight
## with the squad is promoted into one of these: it persists across raids (host-owned
## nemesis.cfg), ADAPTS to how it was fought (learned-counter `traits`), wears `scar_seed`
## damage, and HUNTS the squad when re-injected by the NemesisDirector.
##
## TWO ENCODING CHANNELS (the load-bearing co-op decision):
##   • NODE NAME token (`_NEMt<tier>s<seed>x<TRAITLETTERS>`) — carries the gameplay-relevant
##     subset. Replicates to every co-op client FOR FREE via the auto-spawn (exactly like the
##     EnemyModifiers `_modAV` channel), so each peer rebuilds the IDENTICAL scarred/buffed
##     body in robot_enemy._ready with zero extra RPCs. Parsed with `parse_token`.
##   • SAVE (host ConfigFile) — the authoritative full profile (serial/title/grudge/scene).
##     The name is a lossy PROJECTION of this; the save is the source of truth on injection.
##
## The token mirrors EnemyModifiers.parse_from_name discipline: a distinct `_NEM` marker
## (coexists with `_mod`), letter-tagged numeric fields, tolerant of the trailing de-dupe
## digits `add_child(., true)` may append (digit terminates the trait-letter scan).
##
## PARSE TRAP (warnings-as-errors): never `var x := <Variant>`; locals explicitly typed.

const NEM_MARKER := "_NEM"

## Learned-counter trait ⇄ single name-token letter (uppercase, distinct from the lowercase
## field tags t/s/x so the parser never confuses them).
const TRAIT_TO_LETTER := {
	"emp_hard": "E",
	"blast_hard": "B",
	"weakpoint_armored": "W",
	"keen": "K",
}
const LETTER_TO_TRAIT := {
	"E": "emp_hard",
	"B": "blast_hard",
	"W": "weakpoint_armored",
	"K": "keen",
}

## Serial-name word bank + title ladder (deterministic from scar_seed / tier).
const _METAL_WORDS := ["IRON", "RUST", "COBALT", "SLAG", "CHROME", "VANTA", "EMBER", "OXIDE"]
const _TITLES := [
	"the One Who Walked Away",
	"the Unbroken",
	"the Relentless",
	"the Vengeful",
	"the Undying",
]

var serial: String = ""
var title: String = ""
var archetype: String = "robot_grunt"  # the promoted enemy_id (⇄ Settings.ENEMY_STATS)
var scene_path: String = ""  # captured from the candidate node so injection needs no id→scene map
var tier: int = 1
var traits: Array[String] = []
var scar_seed: int = 0
var grudge_peer: int = 0  # peer who dealt the crippling blow (placement hint; 0 = any)
var created_version: String = ""
# Phase 3: gear the squad LOST in the raid(s) that birthed/leveled this rival — dropped on
# its defeat ("reclaim your armor"). zone_counts tracks where the squad extracts → the
# rival ambushes its favorite zone. Both saved host-only; neither rides the node name.
var lost_gear: Array[String] = []
var zone_counts: Dictionary = {}  # extraction zone node name -> times the squad went there


## The node-name suffix carrying tier/scar_seed/traits to every peer. Appended to the base
## scene name BEFORE add_child so it replicates as spawn data.
func to_name_token() -> String:
	var letters := ""
	for t in traits:
		letters += String(TRAIT_TO_LETTER.get(t, ""))
	return "%st%ds%dx%s" % [NEM_MARKER, tier, scar_seed, letters]


## Parse the gameplay subset out of a node name (the client rebuild path). Returns an empty
## Dictionary when the name carries no `_NEM` token (a plain / elite-only enemy).
## On success: {is_nemesis:true, tier:int, scar_seed:int, traits:Array[String]}.
static func parse_token(node_name: String) -> Dictionary:
	var idx := node_name.find(NEM_MARKER)
	if idx < 0:
		return {}
	var rest := node_name.substr(idx + NEM_MARKER.length())
	var traits_out: Array[String] = []
	for ch in _read_letters_field(rest, "x"):
		var tr_name: String = String(LETTER_TO_TRAIT.get(ch, ""))
		if tr_name != "" and not traits_out.has(tr_name):
			traits_out.append(tr_name)
	return {
		"is_nemesis": true,
		"tier": _read_int_field(rest, "t"),
		"scar_seed": _read_int_field(rest, "s"),
		"traits": traits_out,
	}


## Read the digit run following a single-letter `tag` (e.g. "t3..." → 3). 0 if absent.
static func _read_int_field(s: String, tag: String) -> int:
	var i := s.find(tag)
	if i < 0:
		return 0
	i += tag.length()
	var num := ""
	while i < s.length() and s[i] >= "0" and s[i] <= "9":
		num += s[i]
		i += 1
	return int(num) if num != "" else 0


## Read the UPPERCASE-letter run following `tag` (the trait letters). Stops at the first
## non-uppercase char — a de-dupe digit, an appended `_modAV`, or end of string.
static func _read_letters_field(s: String, tag: String) -> String:
	var i := s.find(tag)
	if i < 0:
		return ""
	i += tag.length()
	var out := ""
	while i < s.length() and s[i] >= "A" and s[i] <= "Z":
		out += s[i]
		i += 1
	return out


## Deterministic serial name + flavor title (never re-rolled — stable across the rivalry).
static func make_serial(seed: int) -> String:
	var word: String = String(_METAL_WORDS[absi(seed) % _METAL_WORDS.size()])
	return "%s-%d" % [word, (absi(seed) / 7) % 89 + 1]


static func make_title(t: int) -> String:
	return String(_TITLES[clampi(t - 1, 0, _TITLES.size() - 1)])


# ----------------------------------------------------------------- persistence
## Plain-Dictionary serialization — the single source the cfg + the codex history reuse.
func to_dict() -> Dictionary:
	return {
		"serial": serial,
		"title": title,
		"archetype": archetype,
		"scene_path": scene_path,
		"tier": tier,
		"traits": traits,
		"scar_seed": scar_seed,
		"grudge_peer": grudge_peer,
		"lost_gear": lost_gear,
		"zone_counts": zone_counts,
		"created_version": created_version,
	}


## Build a profile from a to_dict() Dictionary (codex history). Returns null if no serial.
static func from_dict(d: Dictionary) -> NemesisProfile:
	if String(d.get("serial", "")) == "":
		return null
	var p := NemesisProfile.new()
	p.serial = String(d.get("serial", ""))
	p.title = String(d.get("title", ""))
	p.archetype = String(d.get("archetype", "robot_grunt"))
	p.scene_path = String(d.get("scene_path", ""))
	p.tier = int(d.get("tier", 1))
	p.scar_seed = int(d.get("scar_seed", 0))
	p.grudge_peer = int(d.get("grudge_peer", 0))
	p.created_version = String(d.get("created_version", ""))
	p.zone_counts = d.get("zone_counts", {}) if d.get("zone_counts") is Dictionary else {}
	p.traits = _typed_strings(d.get("traits", []))
	p.lost_gear = _typed_strings(d.get("lost_gear", []))
	return p


## Write every field into `cfg`'s `section` (the host-only nemesis.cfg).
func to_cfg(cfg: ConfigFile, section: String) -> void:
	for key in to_dict():
		cfg.set_value(section, key, to_dict()[key])


## Reconstruct a profile from `cfg`'s `section`, or null if absent / missing serial+scene.
static func from_cfg(cfg: ConfigFile, section: String) -> NemesisProfile:
	if not cfg.has_section(section):
		return null
	var d := {}
	for key in cfg.get_section_keys(section):
		d[key] = cfg.get_value(section, key)
	var p := from_dict(d)
	if p == null or p.scene_path == "":
		return null
	return p


## Coerce a raw Array into a typed Array[String] (the inferred-Variant parse trap otherwise).
static func _typed_strings(raw_val: Variant) -> Array[String]:
	var out: Array[String] = []
	if raw_val is Array:
		for v in raw_val as Array:
			out.append(String(v))
	return out
