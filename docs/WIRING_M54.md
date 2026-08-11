# M5.4 — micro-vignettes wiring

Add ONE line at the END of `arena._on_match_started()` (already server-gated; `loot` is the `$Net/Loot` @onready):

    MicroVignettes.spawn_all(self, loot, randi())

- **Seed:** `randi()` = per-raid variety (runtime-only, the golden snapshot never sees it); pass a fixed int for reproducible QA. The internal rng is a local `RandomNumberGenerator` — zero global-rng or wall-clock entropy.
- **Loot ids used** (verified against the `id` field inside `resources/items/*.tres`, not filenames): `loot_scrap`, `loot_plastic`, `loot_circuit`, `loot_cell`, `loot_chemicals`, `loot_medkit`, `loot_artifact`. The brief's `loot_alloy`/`loot_electronics` do NOT exist — `loot_circuit` covers electronics, `loot_artifact` the shrine's rare drop.
- **Assumptions:** call after the world build (props are render-only so the navmesh bake — which parses colliders only — is unaffected either way); `get_poi_points()`/`get_player_spawn_points()` are duck-typed and skipped if absent; keep-outs are 25 m spawn / 12 m evac / 20 m POI, plus the river channel, slopes >1.6 m, and 34 m between vignettes; returns 4-7 placed, or 0 if the `"MicroVignettes"` root already exists (idempotent — a re-fired `begin_match` for a late joiner will not double-spawn).
- **Co-op v1:** props are built server-side only and do NOT replicate — a joined client sees the loot but not the wreck around it. The loot itself replicates normally through `LootPickup.spawn_at` → `Net/LootSpawner`.
