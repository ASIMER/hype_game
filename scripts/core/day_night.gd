## In-raid day-night clock — a PURE function of the already-synced match timer, so the
## sky is identical on every peer and on the headless server with ZERO new netcode. The
## clock maps the match's elapsed time onto a fixed slice of an in-game day
## (Settings.DAY_NIGHT_START_HOUR .. + DAY_NIGHT_HOURS_PER_MATCH), with the `night_raid`
## mutator simply shifting the START hour later so a raid begins toward dusk. Static +
## node/scene-free so it is callable from anywhere (AI perception, the atmosphere driver,
## the harness) including headless.
##
## Hour convention: 0.0 .. 24.0, wrapping. "Night" is the window [NIGHT_FROM .. 24) ∪
## [0 .. NIGHT_TO). The same hour drives both the visual sky (world_atmosphere.gd) and the
## enemy detection penalty (detect_mult), so what the player SEES matches how stealthy the
## night actually is.
class_name DayNight


## The in-game hour [0 .. 24) for a given match progress. `elapsed` is clamped into
## [0, total]; the clock starts at NIGHT_RAID_START_HOUR under the "night_raid" mutator,
## else DAY_NIGHT_START_HOUR, and advances DAY_NIGHT_HOURS_PER_MATCH across the whole
## match. fposmod keeps it wrapped past midnight (e.g. an 18.5 start + 12 h spans into the
## small hours). This is the one place the time math lives.
static func hour_for(time_left: float, total: float, mutator: String) -> float:
	var elapsed: float = clampf(total - time_left, 0.0, total)
	var start: float = (
		Settings.NIGHT_RAID_START_HOUR if mutator == "night_raid" else Settings.DAY_NIGHT_START_HOUR
	)
	var span: float = (elapsed / maxf(total, 1.0)) * Settings.DAY_NIGHT_HOURS_PER_MATCH
	return fposmod(start + span, 24.0)


## The current in-game hour, read straight off the synced GameState match clock. Headless
## safe (GameState is an autoload with no scene deps).
static func current_hour() -> float:
	return hour_for(GameState.match_time_left, GameState.match_duration, GameState.raid_mutator)


## True when `hour` falls in the night window: at/after NIGHT_FROM_HOUR (evening) OR before
## NIGHT_TO_HOUR (pre-dawn). The window wraps midnight, hence the OR rather than a range.
static func is_night(hour: float) -> bool:
	return hour >= Settings.NIGHT_FROM_HOUR or hour < Settings.NIGHT_TO_HOUR


## Enemy sight-range multiplier for the hour: NIGHT_DETECT_MULT (<1, harder to be seen) at
## night, 1.0 by day. Lets the AI shrink its detection radius after dark without re-deriving
## the night window.
static func detect_mult(hour: float) -> float:
	return Settings.NIGHT_DETECT_MULT if is_night(hour) else 1.0


## A 0..1 "how much daylight" curve for the atmosphere driver: 1.0 around mid-day, falling
## smoothly to 0.0 across dusk (17.5 → 20.5) and rising across dawn (5.5 → 8.5); 0.0 through
## the deep night. It is the product of a dawn ramp (0 before 5.5, 1 after 8.5) and a dusk
## ramp (1 before 17.5, 0 after 20.5), so the day plateaus at 1.0 between ~08:30 and ~17:30.
## world_atmosphere lerps sun energy / ambient / sun pitch off this single scalar.
static func sun_ratio(hour: float) -> float:
	var dawn: float = smoothstep(5.5, 8.5, hour)
	var dusk: float = 1.0 - smoothstep(17.5, 20.5, hour)
	return clampf(dawn * dusk, 0.0, 1.0)
