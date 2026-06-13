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
## Write every field into `cfg`'s `section` (the host-only nemesis.cfg).
func to_cfg(cfg: ConfigFile, section: String) -> void:
	cfg.set_value(section, "serial", serial)
	cfg.set_value(section, "title", title)
	cfg.set_value(section, "archetype", archetype)
	cfg.set_value(section, "scene_path", scene_path)
	cfg.set_value(section, "tier", tier)
	cfg.set_value(section, "traits", traits)
	cfg.set_value(section, "scar_seed", scar_seed)
	cfg.set_value(section, "grudge_peer", grudge_peer)
	cfg.set_value(section, "created_version", created_version)


## Reconstruct a profile from `cfg`'s `section`, or null if the section is absent/empty.
static func from_cfg(cfg: ConfigFile, section: String) -> NemesisProfile:
	if not cfg.has_section(section):
		return null
	var p := NemesisProfile.new()
	p.serial = String(cfg.get_value(section, "serial", ""))
	p.title = String(cfg.get_value(section, "title", ""))
	p.archetype = String(cfg.get_value(section, "archetype", "robot_grunt"))
	p.scene_path = String(cfg.get_value(section, "scene_path", ""))
	p.tier = int(cfg.get_value(section, "tier", 1))
	p.scar_seed = int(cfg.get_value(section, "scar_seed", 0))
	p.grudge_peer = int(cfg.get_value(section, "grudge_peer", 0))
	p.created_version = String(cfg.get_value(section, "created_version", ""))
	var raw: Array = cfg.get_value(section, "traits", [])
	var typed: Array[String] = []
	for t in raw:
		typed.append(String(t))
	p.traits = typed
	if p.serial == "" or p.scene_path == "":
		return null
	return p
