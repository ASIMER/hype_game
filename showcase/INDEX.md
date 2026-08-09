# Hype Raiders — Visual Showcase

A curated set of screenshots showing the visual side of **Hype Raiders** (an Arc Raiders-style
co-op extraction shooter, Godot 4.6.3, runs with zero art assets — every model is built
procedurally in code). Captured via the self-play harness on 2026-06-17.

Two kinds of images:
- **Isolated renders** (enemies / loot / player) — clean, evenly-lit hero shots of the model on a
  transparent background (the in-engine `render` tool). Best for "what does X look like".
- **In-world screenshots** (locations / destruction / UI) — the *actual* in-game look: a cold,
  cinematic, moody grade with volumetric fog and per-biome climate. This is how the game really
  reads while playing.

---

## Characters / player
- `sc_player_default.png` — the player robot (procedural modular body: head/torso/arms/legs + paint).
- `limb3_leap_leg.png`, `limb3_blink_leg.png` — "Mutant Harvest" salvaged LEG limbs (bent knee + foot).
- `limb3_ram_arm.png`, `limb3_chain_arm.png`, `limb3_whirl_arm.png` — salvaged ARM limbs (bent elbow +
  hand). These drop from enemies and graft onto the player; each skill has its own colour + end-bit.

## Enemies (21 archetypes — every body is a distinct procedural silhouette)
- Urban roster: `sc_enemy_grunt`, `sc_enemy_heavy`, `sc_enemy_bastion`, `sc_enemy_caller`,
  `sc_enemy_tick`, `sc_enemy_wasp`, `sc_enemy_elite`.
- Snow biome: `sc_enemy_frosthound`, `sc_enemy_kappa`, `sc_enemy_cryomortar`, `sc_enemy_avalanche`.
- Desert biome: `sc_enemy_sandworm`, `sc_enemy_scarab`, `sc_enemy_dustdevil`.
- Rain biome: `sc_enemy_oni`, `sc_enemy_raiju`.
- Recon/special: `sc_enemy_specter`.
- Minibosses + boss (big): `sc_enemy_snowgolem`, `sc_enemy_dunewarden`, `sc_enemy_onichief`,
  `sc_enemy_boss`.

## Loot / items
- Weapons: `sc_loot_rifle`, `sc_loot_pistol`.
- Power cores: `sc_loot_powercore` (epic carry-objective), `sc_loot_nemesiscore` (rival trophy).
- Consumables: `sc_loot_medkit`, `sc_loot_selfrevive`.
- Gadgets: `sc_loot_turret`, `sc_loot_dome`.
- Throwable: `sc_loot_incendiary`. Armor: `sc_loot_vest`. Valuable: `sc_loot_artifact`.

## Locations (in-world — the 4 biomes + a landmark)
- `sc_loc_urban.png` — NW urban ruins (warehouses, container yards) — the original map.
- `sc_loc_northtower.png` — the North Tower landmark wrapped in its tall smoke plume.
- `sc_loc_snow.png` — NE alpine snow biome (white slopes, mist, the lodge).
- `sc_loc_desert.png` — SW desert biome (sand, dust haze, sandstone ruins).
- `sc_loc_temple_rain.png` — SE rain biome (wet, rain streaks, Japanese temple).

## Destruction (in-world — walls break into ~0.8 m chunks + physics debris)
- `sc_destruction_fire.png`, `sc_destruction_aim.png` — the modular **breakable wall** (you can see
  the ~0.8 m cell grid the wall is built from).
- `sc_destruction_big.png` — mid-fight by the warehouse after breaking a 25-cell cluster.
- NOTE: a clean "hole + flying debris" beauty shot is hard to capture in the harness (swarming
  enemies, the dark grade, and debris that fades in ~3.6 s). The destruction is fully working
  (any wall/floor/ceiling/container/rock breaks into falling RigidBody shards) — it just photographs
  best in a free-camera/lit build.

## UI
- `sc_ui_extracted.png` — the post-raid EXTRACTED (win) summary screen.
