# Hype Raiders — Architecture Audit (v0.3)

**Date:** 2026-06-10 · **Method:** knowledge graph (`graphify-out/`) + 3 parallel deep-read audits
(fragility / quality / tooling) + gdlint baseline. **Trigger:** "change one thing, something
unrelated breaks" — this file names WHY that happens and what we did / deliberately did not do.

**Companion pieces:** the quality gates (gdlint/gdformat/ruff + the Claude Code PostToolUse hook)
live in `gdlintrc` / `ruff.toml` / `tools/lint/`; the golden determinism snapshot (the refactoring
safety net) is documented in §6.

Status legend: **FIXED** (done, this pass) · **PLANNED-P2/P3** (scheduled this pass, phase 2/3) ·
**ACCEPTED** (left alone on purpose, reason given) · **DEFERRED** (worth doing, not now).

---

## 1. God files (size inventory)

Per user decision these are **NOT being split** — only de-duplicated and contract-hardened.
`gdlintrc max-file-lines: 1600` is the hard ceiling: none of these may GROW past it.

| File | Lines | Responsibilities (and why it survived as one file) |
|---|---|---|
| `scripts/player/player.gd` | 1444 | movement+stances, camera coupling, water, downed/revive/carry, cosmetics sync, interaction. Heavily cross-replicated — split risk > benefit. |
| `autoload/AgentBridge.gd` | 1430 | the whole self-play TCP protocol. Dispatcher style; grows one `match` arm per QA verb. |
| `scripts/visual/procedural_terrain.gd` | 1252 | heightfield math + mesh + water + river props. Pure/deterministic core other systems call into. |
| `scripts/enemies/robot_enemy.gd` | 1186 | base enemy: FSM, perception, nav, replication. 9 archetypes subclass it. |
| `scripts/visual/procedural_models.gd` | 949 | per-id enemy/item model builders (catalog of small pure functions). |
| `scripts/waves/wave_manager.gd` | 843 | waves, storm, patrols, director spawns, biome pools. |
| `autoload/MetaProgression.gd` | 837 | persistent profile: currency/unlocks/loadout/attachments/perks/cosmetics/milestones. |
| `scripts/visual/procedural_buildings.gd` | 815 | 8 themed structure builders. |
| `scripts/visual/procedural_flora.gd` | 790 | trees/bushes/grass/boulders scatter. |

## 2. Fragility findings (the "change A, B breaks" list)

| # | Finding | Risk | Status |
|---|---|---|---|
| F1 | **`_h`/`_hf`(/`_hrange`) hash helpers copy-pasted ×3**: procedural terrain/flora/buildings. Editing one desyncs co-op world determinism (peers build different worlds). | CRITICAL | **FIXED** → `scripts/core/proc_hash.gd` (`ProcHash.h/hf/hrange`, byte-identical math); golden snapshot MATCH |
| F2 | **POI coordinates duplicated by hand**: `arena.gd _POI_DEFS` (12 POIs) ↔ flora `_POI_RECTS` ("Must match arena.gd" = manual-sync trap) ↔ extraction-pad coords hardcoded in `procedural_terrain._collect_pads` (duplicating the `ExtractionZone*` node positions in Arena.tscn). | CRITICAL | **FIXED** → both builders receive `_POI_DEFS` + the zone XZ centres read off the REAL `ExtractionZone*` nodes (`arena._extraction_zone_points`); golden MATCH. Kept bit-exact: flora extraction keep-outs apply to the 3 original NW zones ONLY (the 9 new-biome zones never had them — adding them would reshape the world; revisit deliberately) |
| F3 | **World bounds duplicated** across terrain, flora, `Settings.biome_at`, map_ui, world_atmosphere (+ worm clamp). A future map resize = 5-file hunt. | HIGH | **FIXED** → `scripts/core/world_bounds.gd` (incl. `biome_at`); golden MATCH |
| F4 | **4 near-identical player-AoE damage loops**: worm bite / kamikaze blast / slammer slam / pouncer swipe. (The boss "slam" turned out single-target — not an AoE loop.) | MED | **FIXED** → `scripts/core/combat_aoe.gd` (`damage_players`, falloff/floor/include_downed cover every variant); live-verified (blast 100→60, slam downs+finishes, bite 100→68) |
| F5 | **Orbit steering math ×2**: flyer ↔ strafer `_orbit_dir`. | MED | **FIXED** → `scripts/core/steering.gd` (`orbit_dir`); both verified orbiting live |
| F6 | **`load("res://scripts/visual/…")` by string path ×5 in arena.gd** (+1 in flora→terrain) — every class has a `class_name`; a file move = silent no-op world. | HIGH | **FIXED** → direct class calls; a move is now a compile error |
| F7 | **Magic strings as contracts**: groups `"players"` (49 call sites), `"enemies"` (9), `"extraction"`, `"arena"`, `"world_events"`, `"pickups"`; node names `"Health"`, `"Hurtbox"`, `"WeakPoint"`, `"ModelRoot"`. A typo compiles fine and silently skips damage/credit. | HIGH | **FIXED** → `scripts/core/groups.gd` + full code-site sweep (37 files). `.tscn` group strings stay literal (scenes can't reference consts) → the VALUES are frozen. `"Net/Loot"`-style node paths left as-is (few sites) |
| F8 | **`ENEMY_STATS`/`POWERS`/`UPGRADES` are untyped dicts** read via `.get(key, default)` at 30+ sites — a typo'd key silently serves the default. | MED | **FIXED** (cheap half) → `scripts/core/boot_validate.gd`: debug-boot validation (required fields, UNKNOWN-key whitelist, wave-pool scene paths exist); negative-tested. Full typed-Resource conversion: DEFERRED (§7) |
| F9 | **Autoload coupling knot**: RaidManager ↔ MetaProgression ↔ Stash call each other directly (deploy/extract economy). Documented contract, single ownership each. | LOW | ACCEPTED — refactor would ripple through saves/netcode for no behavioural gain |
| F10 | **Pause-leak class of bugs**: anything that pauses (`get_tree().paused`) must guarantee its unpause on EVERY exit path. RaidSummary needed **4 layers**: unpause-on-match-start, phase-gate vs teardown ghost re-fires, visibility watchdog, and **`_exit_tree` release** — `load_arena()` frees the UI layer, so the pause OWNER can be destroyed while paused (restart from the KIA screen froze the fresh match forever; the replacement instance never paused so no handler could release it). `main.restart_match` also unpauses (symmetric with quit-to-menu), and the harness `state` exposes `paused` to name this class instantly. | — | **FIXED** (lifetime layer found while live-verifying F4 — it masqueraded as an enemy-AI regression) |
| F11 | **Wide-radius spawn fan-out**: wave spawns picked any same-side marker world-wide after the 4× expansion. | — | FIXED (NEAR_SPAWN_RADIUS=70 bias in `wave_manager._spawn_xform`) |
| F12 | `Arena.tscn` perimeter wall colliders were still at the old ±80 after the 4× expansion (invisible mid-map cross). Single-owner scene rule exists because of exactly this class of edit. | — | FIXED (pre-audit, commit cb272f7) |

## 3. Duplication (non-fragile, quality)

| Finding | Status |
|---|---|
| `COL_*` palette consts re-declared per UI file while `UIStyle.*` is the declared single source. | **FIXED** — 46 duplicate declarations across 9 files + scoreboard's row-highlight now reference `UIStyle.*`. Intentionally-distinct values stay local: `progression_tab`/`quests_tab` GREEN shades, `loadout_tab` COL_WARN, `gunsmith_tab` COL_ORANGE, `raid_summary` COL_WIN/COL_LOSS |
| `tools/agent/raw.py` ↔ `play.py` share the socket protocol by copy. | ACCEPTED — 30-line file, stdlib-only by design |

## 4. Dead code

| Item | Evidence | Status |
|---|---|---|
| `procedural_terrain._bake_ground_texture` / `_bake_ground_normal` / `_ground_detail_texture` / `_detail_ramp` (+ the `HALF` const only they read) | superseded by ambientCG PBR triplanar splat (`_color_srgb` stays — it feeds the live splat) | **FIXED** — deleted (≈90 lines); golden MATCH |
| `RIM_INNER`/`RIM_OUTER` legacy ring consts | old circular-map rim | **FIXED** — deleted |
| `FLORA_GRASS_PATCHES`/`FLORA_GRASS_FAR` | grass is density-driven + tiled now; zero readers | **FIXED** — deleted |
| `arena._enrich_ground` | looked up `Ground/Mesh` AFTER `_build_terrain` already removed `Ground` → guaranteed early-return; the asphalt/stain layer never spawned | **FIXED** — function + call + build phase deleted |

## 5. Lint baseline (gdlint, `gdlintrc` at repo root)

**111 problems** at audit time → **50 after phase 2** → **0 after the phase-3 `gdformat`
baseline** (112 files formatted in one style commit; verified behaviour-neutral: import +
server smoke + golden MATCH after formatting). gdlint AND `gdformat --check` are now both
ZERO and enforced per-edit by the PostToolUse hook + pre-commit (`resource_index.gd` exempt —
generated). `max-file-lines` re-based 1600→1800 (wrapping grew the god files).

| Rule | At audit | After P2 | Resolution |
|---|---|---|---|
| max-line-length (120) | 100 | 50 → 0 | 12 files gdformat'ed early (pre-commit gate); the rest in the phase-3 baseline; 2 unsplittable lines carry inline ignores (a localization-key string; a 23-pattern match arm) |
| function-variable-name | 5 | 0 | locals renamed (they were USED, not unused-markers) |
| unused-argument | 3 | 0 | `_`-prefixed (override-signature args) |
| max-public-methods (40) | 1 | 0 | MetaProgression: inline `gdlint: ignore` + doc (its 41 methods ARE the profile API) |
| function-argument-name | 1 | 0 | `H` → `hgt` |
| duplicated-load | 1 | 0 | loot_pickup: lazy static cache (preload would be a self scene↔script cycle) |

Config notes: 120-col (long doc comments are idiomatic here), `class-definitions-order` disabled
(consts/vars are grouped next to the behaviour they configure, on purpose), `max-returns: 16`
(AgentBridge/Hub dispatchers legitimately early-return per action branch), `max-file-lines: 1600`
(ceiling for the god files in §1). New code must lint CLEAN — the PostToolUse hook enforces this
automatically on every Edit/Write.

## 6. Golden determinism snapshot (the refactoring safety net)

`tools/lint/golden_world.json` + `tools/lint/check_golden.py`. The AgentBridge `golden` command
captures the deterministic slice of a built world:

- **81 terrain height probes** (9×9 grid over X,Z ∈ [−80..240]) + water-surface probes — pure
  `ProceduralTerrain.height_at`/`water_surface_at` math, including pad blending;
- **12 extraction zones**: name, position, pad height under each;
- **placement checksums** per procedural container (`Geometry` = buildings+scatter, `Flora`,
  `ProceduralTerrain`): every node's name/class/quantized global transform + full MultiMesh
  instance buffers folded into one hash.

Verified at capture time: same-run MATCH, in-process arena rebuild (`restart`) MATCH, **fresh
process MATCH** — so any DRIFT reported during phase 2 is a real behaviour change, not noise.

Run: launch `--agent`, then `python tools/lint/check_golden.py` (compare) or `--capture`
(re-baseline — only after an INTENDED world change, never to silence a diff).

Excluded by design: **loot** (field/world rolls use unseeded `randf_range` — run-varying),
**Grass_*** tiles (stream around the player), auto-generated node names (`@Class@N` counter is
process-global; folded as `@anon`).

## 7. Deferred (recorded so they aren't re-litigated)

- **Typed Resources for ENEMY_STATS/POWERS/UPGRADES** — boot validation (F8) gives 80% of the
  safety for 5% of the churn. Revisit if the catalogs keep growing.
- **Directory re-layout** (e.g. `scripts/` by feature) — moving `.gd` files breaks `.tscn`
  script references and git history locality; `scripts/core/` (NEW shared-helper home) is the
  only structural addition this pass.
- **Splitting the god files** — user decision: safe refactor only. The 1600-line lint ceiling
  stops further growth; revisit per-file if one needs major feature work anyway.
