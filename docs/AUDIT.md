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
| F1 | **`_h`/`_hf`(/`_hrange`) hash helpers copy-pasted ×3**: `procedural_terrain.gd:80`, `procedural_flora.gd:27`, `procedural_buildings.gd:126`. Editing one desyncs co-op world determinism (peers build different worlds). | CRITICAL | PLANNED-P2 → `scripts/core/proc_hash.gd` (byte-identical math), golden-verified |
| F2 | **POI coordinates duplicated by hand**: `arena.gd _POI_DEFS` (12 POIs) ↔ `procedural_flora.gd:68 _POI_RECTS` ("Must match arena.gd" comment = manual-sync trap) ↔ extraction-pad coords hardcoded in `procedural_terrain._collect_pads:131` (duplicating the `ExtractionZone*` node positions in Arena.tscn). | CRITICAL | PLANNED-P2 → single source: flora/terrain receive POI defs + extraction points as build params |
| F3 | **World bounds duplicated**: X_MIN/X_MAX/Z_MIN/Z_MAX/WORLD_CX/CZ in `procedural_terrain.gd:31` AND `procedural_flora.gd:43`; biome split constant 80.0 inside `Settings.biome_at`; map_ui WORLD_MIN/SPAN; world_atmosphere MAP_SPAN/CX/CZ. A future map resize = 5-file hunt. | HIGH | PLANNED-P2 → `scripts/core/world_bounds.gd` |
| F4 | **5 near-identical player-AoE damage loops**: `robot_worm._bite_area`, `robot_kamikaze._detonate`, `robot_slammer._slam`, `robot_pouncer._swipe_area`, + the boss slam variant in `robot_boss.gd`. Fixing falloff/teamdamage in one ≠ the others. | MED | PLANNED-P2 → `scripts/core/combat_aoe.gd` |
| F5 | **Orbit steering math ×2**: `robot_flyer._orbit_dir:74` ↔ `robot_strafer._orbit_dir`. | MED | PLANNED-P2 → `scripts/core/steering.gd` |
| F6 | **`load("res://scripts/visual/…")` by string path ×5 in arena.gd** (terrain/flora/probes/fog/climate, lines 122–202) — every class has a `class_name`; a file move = silent no-op world (guards return null). Historical reason (parallel lanes) no longer applies. | HIGH | PLANNED-P2 → direct class calls |
| F7 | **Magic strings as contracts**: groups `"players"` (49 call sites), `"enemies"` (9), `"extraction"`, `"arena"`, `"world_events"`; node names `"Health"`, `"Hurtbox"`, `"WeakPoint"`, `"ModelRoot"`, `"Net/Loot"`. A typo compiles fine and silently skips damage/credit (get_node_or_null → null → skip). | HIGH | PLANNED-P2 → `scripts/core/groups.gd` consts + sweep of the hottest literals |
| F8 | **`ENEMY_STATS`/`POWERS`/`UPGRADES` are untyped dicts** read via `.get(key, default)` at 30+ sites — a typo'd key silently serves the default. | MED | PLANNED-P2 (cheap half): boot-time validation in debug builds (every scene id present, keys whitelisted). Full typed-Resource conversion: DEFERRED (large churn, low payoff while validation exists). |
| F9 | **Autoload coupling knot**: RaidManager ↔ MetaProgression ↔ Stash call each other directly (deploy/extract economy). Documented contract, single ownership each. | LOW | ACCEPTED — refactor would ripple through saves/netcode for no behavioural gain |
| F10 | **Pause-leak class of bugs**: anything that pauses (`get_tree().paused`) must guarantee its unpause on EVERY exit path incl. harness `restart`. RaidSummary needed 3 layers (unpause-on-match-start, phase-gate, visibility watchdog). | — | FIXED (this session, raid_summary.gd); pattern recorded in memory |
| F11 | **Wide-radius spawn fan-out**: wave spawns picked any same-side marker world-wide after the 4× expansion. | — | FIXED (NEAR_SPAWN_RADIUS=70 bias in `wave_manager._spawn_xform`) |
| F12 | `Arena.tscn` perimeter wall colliders were still at the old ±80 after the 4× expansion (invisible mid-map cross). Single-owner scene rule exists because of exactly this class of edit. | — | FIXED (pre-audit, commit cb272f7) |

## 3. Duplication (non-fragile, quality)

| Finding | Status |
|---|---|
| `COL_*` palette consts re-declared per UI file (hub.gd, loadout_tab, quests_tab, gunsmith_tab, raid_summary…) while `UIStyle.*` is the declared single source. | PLANNED-P2 sweep (values that DIFFER from UIStyle stay + get noted here) |
| `tools/agent/raw.py` ↔ `play.py` share the socket protocol by copy. | ACCEPTED — 30-line file, stdlib-only by design |

## 4. Dead code

| Item | Evidence | Status |
|---|---|---|
| `procedural_terrain._bake_ground_texture` / `_bake_ground_normal` / `_ground_detail_texture` (+ the `HALF` const they read) | superseded by ambientCG PBR triplanar splat | PLANNED-P2 delete (after grep re-check) |
| `RIM_INNER`/`RIM_OUTER` legacy ring consts | old circular-map rim | PLANNED-P2 delete |
| `FLORA_GRASS_PATCHES`/`FLORA_GRASS_FAR` | grass is density-driven + tiled now | PLANNED-P2 delete (verify no readers) |
| `arena._enrich_ground` GroundDetail branch | looks up `Ground/Mesh` AFTER `_build_terrain` already removed `Ground` → guaranteed early-return; the asphalt/stain layer never spawns when procedural terrain is on (always) | PLANNED-P2 delete (found during golden-snapshot work) |

## 5. Lint baseline (gdlint, `gdlintrc` at repo root)

**111 problems** across `scripts/` + `autoload/` at audit time:

| Rule | Count | Plan |
|---|---|---|
| max-line-length (120) | 100 | Phase-3 `gdformat` baseline auto-fixes the bulk |
| function-variable-name | 5 | fix during Phase-2 touches |
| unused-argument | 3 | fix during Phase-2 touches (`_`-prefix) |
| max-public-methods (40) | 1 | AgentBridge — accepted (dispatcher) unless trivial |
| function-argument-name | 1 | fix |
| duplicated-load | 1 | fix |

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
