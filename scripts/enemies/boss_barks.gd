class_name BossBarks
extends Node
## Talking-boss bark ENGINE (v1, text only — voice lines come later).
##
## Owns the line bank + the selection policy; it knows nothing about the boss. A driver
## (BossBarkDriver) watches real game state and calls say("<context>"); this node decides
## whether the line is allowed to speak right now and which line it is.
##
## Selection policy:
##   • never repeat one of the last RECENT_MAX lines (a ring across ALL contexts, so the
##     player doesn't hear the same taunt twice in a fight),
##   • per-context cooldown (idle taunts + generic filler are rarer than reactions),
##   • a global min-gap so two contexts firing on the same frame don't talk over each other.
## A say() that fails any gate is silently dropped — callers never need to check first.
##
## Output goes to Events.notify (kind 2 = the red/bad channel, the guaranteed path today)
## and, IF the lead later adds a dedicated HUD channel, to Events.boss_bark. That signal
## is emitted through emit_signal() by NAME on purpose: `Events.boss_bark.emit()` would be
## a PARSE error while the signal doesn't exist yet.
##
## Fully null-safe + headless-safe: a missing/corrupt bank leaves the node inert (say() is
## a no-op), nothing touches the render tree, and time comes from Time.get_ticks_msec()
## so the engine is pause-proof and needs no _process.

const BANK_PATH: String = "res://resources/barks/boss_barks.json"
const RECENT_MAX: int = 6  # how many just-said lines are blocked from re-selection
const DEFAULT_COOLDOWN: float = 6.0
const GLOBAL_GAP: float = 2.5  # min seconds between ANY two barks
const NOTIFY_KIND_BAD: int = 2  # killfeed/HUD colour channel (0 info / 1 good / 2 bad / 3 wave)
## Contexts that would otherwise spam: idle taunts + combat filler speak far less often.
const CONTEXT_COOLDOWNS: Dictionary = {"generic_combat": 10.0, "boss_healthy_taunt": 18.0}

var _bank: Dictionary = {}
var _recent: Array[String] = []
var _next_ms: Dictionary = {}  # context -> earliest Time.get_ticks_msec() that may speak
var _global_next_ms: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_bank = _read_bank()


## Speak one line for `context`, or do nothing if a cooldown / the global gap blocks it.
## `fmt` fills the %s slots (the nemesis contexts carry a serial); a line with a slot is
## never chosen when `fmt` is empty, so a raw "%s" can't reach the HUD.
func say(context: String, fmt: Array = []) -> void:
	if not context_available(context):
		return
	var line: String = _pick(context, not fmt.is_empty())
	if line == "":
		return
	var now: int = Time.get_ticks_msec()
	_next_ms[context] = now + int(_cooldown_for(context) * 1000.0)
	_global_next_ms = now + int(GLOBAL_GAP * 1000.0)
	_remember(line)
	_emit(_format(line, fmt))


## True when `context` exists in the bank AND neither its cooldown nor the global gap is
## still running. Callers may poll this to avoid building expensive fmt args.
func context_available(context: String) -> bool:
	if not _bank.has(context):
		return false
	var now: int = Time.get_ticks_msec()
	if now < _global_next_ms:
		return false
	return now >= int(_next_ms.get(context, 0))


## False when the bank file was missing/unreadable — the whole engine is inert.
func bank_loaded() -> bool:
	return not _bank.is_empty()


## Number of lines in a context's pool (0 for an unknown context). For QA/debug.
func pool_size(context: String) -> int:
	var pool: Array = _pool(context)
	return pool.size()


# ------------------------------------------------------------------ selection internals
## Pick a line, preferring one that isn't in the recent ring. `allow_slots` is false when
## the caller passed no fmt args, which excludes every "%s" line from the candidates.
## Falls back to the unfiltered pool when the ring has eaten every option (small pools).
func _pick(context: String, allow_slots: bool) -> String:
	var pool: Array = _pool(context)
	var usable: Array[String] = []
	for entry in pool:
		var line: String = String(entry)
		if line == "":
			continue
		if not allow_slots and line.contains("%s"):
			continue
		usable.append(line)
	if usable.is_empty():
		return ""
	var fresh: Array[String] = []
	for line in usable:
		if not _recent.has(line):
			fresh.append(line)
	var candidates: Array[String] = fresh if not fresh.is_empty() else usable
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


func _pool(context: String) -> Array:
	var entry: Variant = _bank.get(context, [])
	if entry is Array:
		return entry as Array
	return []


func _cooldown_for(context: String) -> float:
	return float(CONTEXT_COOLDOWNS.get(context, DEFAULT_COOLDOWN))


func _remember(line: String) -> void:
	_recent.append(line)
	while _recent.size() > RECENT_MAX:
		_recent.remove_at(0)


## Fill the line's %s slots from `fmt`, reusing the last arg if the line wants more than
## it was given (a size mismatch would otherwise be a runtime format error).
func _format(line: String, fmt: Array) -> String:
	var slots: int = line.count("%s")
	if slots <= 0 or fmt.is_empty():
		return line
	var args: Array = []
	for i in slots:
		args.append(fmt[mini(i, fmt.size() - 1)])
	return line % args


func _emit(text: String) -> void:
	if text == "":
		return
	# Dedicated HUD speech chip when the channel exists; killfeed notify as the fallback
	# (never both — the same line twice on screen reads as a bug).
	if Events.has_signal("boss_bark"):
		Events.emit_signal("boss_bark", text)
	elif Events.has_signal("notify"):
		Events.notify.emit(text, NOTIFY_KIND_BAD)


# ------------------------------------------------------------------------- bank loading
## Read the JSON bank. Raw FileAccess first (how it lives in the repo + in an export that
## ships the file); if that yields nothing, try it as a JSON *resource* so the engine still
## finds it when the exporter imported it instead. Anything unexpected → {} (inert).
static func _read_bank() -> Dictionary:
	var text: String = ""
	if FileAccess.file_exists(BANK_PATH):
		var f: FileAccess = FileAccess.open(BANK_PATH, FileAccess.READ)
		if f != null:
			text = f.get_as_text()
	if text.strip_edges() == "":
		if not ResourceLoader.exists(BANK_PATH):
			return {}
		var res: Resource = load(BANK_PATH)
		if res is JSON:
			var data: Variant = (res as JSON).data
			if data is Dictionary:
				return data as Dictionary
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}
