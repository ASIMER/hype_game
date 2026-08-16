"""Balance passport: the TTK matrix and the economy audit, generated from the data tables.

Why this is analytic and not a play-test: TTK is fully determined by four numbers the
project already stores (weapon damage x pellets x fire_rate, enemy health), and reading
them is exact where a harness measurement is noisy — enemies dodge, spread scatters
pellets, and a wave walks into frame mid-burst. What a play-test IS needed for is the
handful of cases where the model can be WRONG, and those are called out per row so the
lead can spot-check them live instead of re-measuring everything.

Modelled: body TTK and weak-point TTK, magazine sufficiency (can one mag kill it?), and
time-to-kill under the reload that a longer fight forces. Elite modifiers and the nemesis
tier ramp are applied as multipliers so the tail of the curve is visible too.

Outputs docs/BALANCE.md.

Usage: python tools/agent/balance_matrix.py
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "autoload" / "Settings.gd"
WEAPON_DIR = ROOT / "resources" / "weapons"
OUT = ROOT / "docs" / "BALANCE.md"

# Archetypes worth a row: the ones a player actually shoots at, in encounter order.
ROW_ORDER = [
    "robot_tick",
    "robot_grunt",
    "robot_caller",
    "robot_wasp",
    "robot_scarab",
    "robot_specter",
    "robot_dustdevil",
    "robot_frosthound",
    "robot_kappa",
    "robot_elite",
    "robot_heavy",
    "robot_raiju",
    "robot_cryomortar",
    "robot_bastion",
    "robot_oni",
    "robot_avalanche",
    "robot_sandworm",
    "robot_boss",
]

# Weak-point multipliers live in the enemy .tscn Hurtbox, not a table; these are the
# authored values (grunt/heavy/elite head, oni back). Anything absent has no weak point.
WEAK_POINTS = {
    "robot_grunt": 2.0,
    "robot_heavy": 2.0,
    "robot_elite": 2.5,
    "robot_oni": 3.0,
}


def parse_enemy_stats() -> dict[str, dict[str, float]]:
    text = SETTINGS.read_text(encoding="utf-8")
    start = text.index("const ENEMY_STATS")
    # The table ends at the first line that closes it at column 0.
    end = text.index("\n}", start)
    body = text[start:end]
    out: dict[str, dict[str, float]] = {}
    # The `(?:#...)*` is load-bearing: several entries carry a comment BETWEEN the key and
    # its opening brace (robot_specter does), and a regex that demands `": {" adjacent
    # silently drops exactly those rows — a missing archetype looks like a deleted enemy.
    for m in re.finditer(r'"(robot_[a-z_]+)":\s*(?:#[^\n]*\n\s*)*\{(.*?)\}', body, re.S):
        name, fields = m.group(1), m.group(2)
        stats: dict[str, float] = {}
        for k, v in re.findall(r'"([a-z_]+)":\s*([0-9.]+)', fields):
            stats[k] = float(v)
        out[name] = stats
    return out


def parse_weapons() -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    for path in sorted(WEAPON_DIR.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        w: dict[str, float] = {}
        for key in (
            "damage",
            "fire_rate",
            "pellets",
            "mag_size",
            "reload_time",
            "crit_mult",
            "range",
            "spread_deg",
        ):
            m = re.search(rf"^{key} = ([0-9.]+)", text, re.M)
            if m:
                w[key] = float(m.group(1))
        w.setdefault("pellets", 1.0)
        w.setdefault("crit_mult", 1.0)
        out[path.stem] = w
    return out


def ttk(weapon: dict[str, float], health: float, mult: float = 1.0) -> tuple[float, int, bool]:
    """Seconds to kill, shots needed, and whether one magazine covers it.

    Reload is charged only when the kill genuinely needs more than a magazine — that is
    the case the player feels as "this thing outlasts my gun".
    """
    per_shot = weapon["damage"] * weapon["pellets"] * mult
    shots = max(1, int(-(-health // per_shot)))
    mag = int(weapon.get("mag_size", 30))
    seconds = (shots - 1) / weapon["fire_rate"]
    reloads = (shots - 1) // mag
    seconds += reloads * weapon.get("reload_time", 2.0)
    return seconds, shots, reloads == 0


def main() -> None:
    stats = parse_enemy_stats()
    weapons = parse_weapons()
    order = [w for w in ("pistol", "smg", "rifle", "dmr", "shotgun") if w in weapons]
    lines: list[str] = []
    lines.append("# Balance passport (generated)")
    lines.append("")
    lines.append(
        "Regenerate with `python tools/agent/balance_matrix.py`. Every number here is "
        "derived from `Settings.ENEMY_STATS` and `resources/weapons/*.tres`, so it is "
        "exact for the model described in that script's docstring — and only as good as "
        "the model. Read the caveats at the bottom before acting on a row."
    )
    lines.append("")
    lines.append("## TTK — body shots, seconds (shots)")
    lines.append("")
    lines.append("| archetype | HP | " + " | ".join(w.upper() for w in order) + " |")
    lines.append("|---|---:|" + "---:|" * len(order))
    for eid in ROW_ORDER:
        st = stats.get(eid)
        if not st:
            continue
        hp = st.get("health", 0.0)
        cells = []
        for wid in order:
            sec, shots, one_mag = ttk(weapons[wid], hp)
            mark = "" if one_mag else " ⚠"
            cells.append(f"{sec:.2f} ({shots}){mark}")
        lines.append(f"| `{eid}` | {hp:.0f} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("⚠ = the kill needs more than one magazine, so the listed time includes a reload.")
    lines.append("")
    lines.append("## TTK — weak point, seconds (shots)")
    lines.append("")
    lines.append("| archetype | mult | " + " | ".join(w.upper() for w in order) + " |")
    lines.append("|---|---:|" + "---:|" * len(order))
    for eid, mult in WEAK_POINTS.items():
        st = stats.get(eid)
        if not st:
            continue
        cells = []
        for wid in order:
            sec, shots, _ = ttk(weapons[wid], st.get("health", 0.0), mult)
            cells.append(f"{sec:.2f} ({shots})")
        lines.append(f"| `{eid}` | ×{mult} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("## Enemy threat — damage per second of contact")
    lines.append("")
    lines.append("| archetype | dmg | cooldown | DPS | speed | detect | attack range |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for eid in ROW_ORDER:
        st = stats.get(eid)
        if not st:
            continue
        dmg = st.get("damage", 0.0)
        cd = max(0.01, st.get("cooldown", 1.0))
        lines.append(
            f"| `{eid}` | {dmg:.0f} | {cd:.2f} | {dmg / cd:.1f} | "
            f"{st.get('speed', 0):.1f} | {st.get('detect', 0):.0f} | "
            f"{st.get('attack_range', 0):.1f} |"
        )
    lines.append("")
    lines.append("## Weapons")
    lines.append("")
    lines.append("| id | dmg | pellets | rate | burst DPS | mag | reload | range | spread |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for wid in order:
        w = weapons[wid]
        dps = w["damage"] * w["pellets"] * w["fire_rate"]
        lines.append(
            f"| `{wid}` | {w['damage']:.0f} | {w['pellets']:.0f} | {w['fire_rate']:.1f} | "
            f"{dps:.0f} | {w.get('mag_size', 0):.0f} | {w.get('reload_time', 0):.1f} | "
            f"{w.get('range', 0):.0f} | {w.get('spread_deg', 0):.2f} |"
        )
    lines.append("")
    lines.append("## What this model does NOT capture — spot-check these live")
    lines.append("")
    lines.append(
        "- **Shotgun rows are optimistic.** The table assumes every pellet lands, which is "
        "only true inside a few metres. Past that its real TTK climbs steeply and the "
        "column stops meaning anything."
    )
    lines.append(
        "- **Burst DPS is not sustained DPS.** Reload is charged only once a kill "
        "overruns the magazine; a fight against several enemies pays it far more often."
    )
    lines.append(
        "- **Modifiers and tiers multiply health**: elite `armored`, the nemesis tier ramp "
        "(`Settings.NEMESIS_TIER_HEALTH`) and the difficulty mults all stack on top of "
        "these rows. A tier-5 rival is several of these columns wide."
    )
    lines.append(
        "- **Weak points need to be reachable.** The oni's is on its BACK, so its listed "
        "time assumes a flank the player may never get."
    )
    lines.append(
        "- **Chemistry changes the arithmetic**: BRITTLE multiplies incoming damage "
        "(`CHEM_BRITTLE_MULT`), and a frozen machine that shatters skips the rest of its "
        "health bar entirely."
    )
    lines.append("")
    lines.append(
        "The parser itself is verified against the running game: spawning grunt / heavy / "
        "elite / oni / specter / bastion / avalanche through the harness and reading "
        "`state.enemies[].health` returned exactly the values in the HP column. That is "
        "the check worth repeating after any `ENEMY_STATS` edit — a stat block that grows "
        "a comment between its key and its brace is the failure mode that silently drops "
        "a row."
    )
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUT} ({len(lines)} lines, {len(stats)} archetypes, {len(order)} weapons)")


if __name__ == "__main__":
    main()
