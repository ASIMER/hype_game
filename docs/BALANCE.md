# Balance passport (generated)

Regenerate with `python tools/agent/balance_matrix.py`. Every number here is derived from `Settings.ENEMY_STATS` and `resources/weapons/*.tres`, so it is exact for the model described in that script's docstring — and only as good as the model. Read the caveats at the bottom before acting on a row.

## TTK — body shots, seconds (shots)

| archetype | HP | PISTOL | SMG | RIFLE | DMR | SHOTGUN |
|---|---:|---:|---:|---:|---:|---:|
| `robot_tick` | 14 | 0.00 (1) | 0.07 (2) | 0.00 (1) | 0.00 (1) | 0.00 (1) |
| `robot_grunt` | 40 | 0.40 (3) | 0.29 (5) | 0.22 (3) | 0.33 (2) | 0.00 (1) |
| `robot_caller` | 30 | 0.20 (2) | 0.21 (4) | 0.22 (3) | 0.00 (1) | 0.00 (1) |
| `robot_wasp` | 22 | 0.20 (2) | 0.14 (3) | 0.11 (2) | 0.00 (1) | 0.00 (1) |
| `robot_scarab` | 18 | 0.20 (2) | 0.07 (2) | 0.11 (2) | 0.00 (1) | 0.00 (1) |
| `robot_specter` | 26 | 0.20 (2) | 0.14 (3) | 0.11 (2) | 0.00 (1) | 0.00 (1) |
| `robot_dustdevil` | 55 | 0.60 (4) | 0.43 (7) | 0.33 (4) | 0.33 (2) | 0.00 (1) |
| `robot_frosthound` | 60 | 0.60 (4) | 0.43 (7) | 0.44 (5) | 0.33 (2) | 0.00 (1) |
| `robot_kappa` | 70 | 0.80 (5) | 0.50 (8) | 0.44 (5) | 0.67 (3) | 0.00 (1) |
| `robot_elite` | 140 | 1.60 (9) | 1.07 (16) | 1.00 (10) | 1.33 (5) | 0.71 (2) |
| `robot_heavy` | 95 | 1.00 (6) | 0.71 (11) | 0.67 (7) | 0.67 (3) | 0.71 (2) |
| `robot_raiju` | 50 | 0.60 (4) | 0.36 (6) | 0.33 (4) | 0.33 (2) | 0.00 (1) |
| `robot_cryomortar` | 120 | 1.40 (8) | 0.93 (14) | 0.89 (9) | 1.00 (4) | 0.71 (2) |
| `robot_bastion` | 170 | 2.00 (11) | 1.29 (19) | 1.33 (13) | 1.33 (5) | 0.71 (2) |
| `robot_oni` | 180 | 2.20 (12) | 1.36 (20) | 1.33 (13) | 1.67 (6) | 1.43 (3) |
| `robot_avalanche` | 190 | 2.20 (12) | 1.50 (22) | 1.44 (14) | 1.67 (6) | 1.43 (3) |
| `robot_sandworm` | 160 | 1.80 (10) | 1.21 (18) | 1.22 (12) | 1.33 (5) | 0.71 (2) |
| `robot_boss` | 650 | 12.20 (41) ⚠ | 8.74 (73) ⚠ | 7.11 (47) ⚠ | 8.73 (20) ⚠ | 7.80 (8) ⚠ |

⚠ = the kill needs more than one magazine, so the listed time includes a reload.

## TTK — weak point, seconds (shots)

| archetype | mult | PISTOL | SMG | RIFLE | DMR | SHOTGUN |
|---|---:|---:|---:|---:|---:|---:|
| `robot_grunt` | ×2.0 | 0.20 (2) | 0.14 (3) | 0.11 (2) | 0.00 (1) | 0.00 (1) |
| `robot_heavy` | ×2.0 | 0.40 (3) | 0.36 (6) | 0.33 (4) | 0.33 (2) | 0.00 (1) |
| `robot_elite` | ×2.5 | 0.60 (4) | 0.43 (7) | 0.33 (4) | 0.33 (2) | 0.00 (1) |
| `robot_oni` | ×3.0 | 0.60 (4) | 0.43 (7) | 0.44 (5) | 0.33 (2) | 0.00 (1) |

## Enemy threat — damage per second of contact

| archetype | dmg | cooldown | DPS | speed | detect | attack range |
|---|---:|---:|---:|---:|---:|---:|
| `robot_tick` | 5 | 0.80 | 6.2 | 6.6 | 22 | 1.6 |
| `robot_grunt` | 8 | 1.20 | 6.7 | 4.0 | 18 | 2.2 |
| `robot_caller` | 0 | 6.00 | 0.0 | 5.0 | 30 | 14.0 |
| `robot_wasp` | 6 | 1.40 | 4.3 | 5.2 | 26 | 15.0 |
| `robot_scarab` | 0 | 0.50 | 0.0 | 6.4 | 24 | 2.8 |
| `robot_specter` | 0 | 2.00 | 0.0 | 6.0 | 34 | 18.0 |
| `robot_dustdevil` | 6 | 1.10 | 5.5 | 4.8 | 28 | 16.0 |
| `robot_frosthound` | 10 | 1.20 | 8.3 | 5.4 | 26 | 2.2 |
| `robot_kappa` | 9 | 1.10 | 8.2 | 4.6 | 26 | 2.2 |
| `robot_elite` | 15 | 1.10 | 13.6 | 4.2 | 22 | 2.4 |
| `robot_heavy` | 14 | 1.60 | 8.8 | 2.8 | 18 | 2.6 |
| `robot_raiju` | 7 | 1.20 | 5.8 | 5.0 | 28 | 15.0 |
| `robot_cryomortar` | 9 | 0.35 | 25.7 | 2.0 | 30 | 22.0 |
| `robot_bastion` | 10 | 0.25 | 40.0 | 2.2 | 28 | 20.0 |
| `robot_oni` | 17 | 1.40 | 12.1 | 3.4 | 24 | 3.4 |
| `robot_avalanche` | 12 | 2.40 | 5.0 | 2.4 | 22 | 3.8 |
| `robot_sandworm` | 16 | 1.20 | 13.3 | 3.4 | 32 | 2.4 |
| `robot_boss` | 22 | 0.40 | 55.0 | 2.6 | 45 | 22.0 |

## Weapons

| id | dmg | pellets | rate | burst DPS | mag | reload | range | spread |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `pistol` | 16 | 1 | 5.0 | 80 | 12 | 1.4 | 70 | 0.40 |
| `smg` | 9 | 1 | 14.0 | 126 | 35 | 1.8 | 60 | 1.60 |
| `rifle` | 14 | 1 | 9.0 | 126 | 30 | 2.0 | 90 | 0.60 |
| `dmr` | 34 | 1 | 3.0 | 102 | 10 | 2.4 | 140 | 0.15 |
| `shotgun` | 11 | 8 | 1.4 | 123 | 6 | 2.8 | 40 | 4.50 |

## What this model does NOT capture — spot-check these live

- **Shotgun rows are optimistic.** The table assumes every pellet lands, which is only true inside a few metres. Past that its real TTK climbs steeply and the column stops meaning anything.
- **Burst DPS is not sustained DPS.** Reload is charged only once a kill overruns the magazine; a fight against several enemies pays it far more often.
- **Modifiers and tiers multiply health**: elite `armored`, the nemesis tier ramp (`Settings.NEMESIS_TIER_HEALTH`) and the difficulty mults all stack on top of these rows. A tier-5 rival is several of these columns wide.
- **Weak points need to be reachable.** The oni's is on its BACK, so its listed time assumes a flank the player may never get.
- **Chemistry changes the arithmetic**: BRITTLE multiplies incoming damage (`CHEM_BRITTLE_MULT`), and a frozen machine that shatters skips the rest of its health bar entirely.

The parser itself is verified against the running game: spawning grunt / heavy / elite / oni / specter / bastion / avalanche through the harness and reading `state.enemies[].health` returned exactly the values in the HP column. That is the check worth repeating after any `ENEMY_STATS` edit — a stat block that grows a comment between its key and its brace is the failure mode that silently drops a row.
