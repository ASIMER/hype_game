# Photostand — `pre_v3`

captured 2026-08-16 04:53:26 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.293 | 0.469 | 0.642 | 0.349 | 92.3% | 0.189 | FAIL — under floor (92% > 50%) |
| urban_night | 21.0 | 0.083 | 0.171 | 0.329 | 0.246 | 99.6% | 0.320 | ok |
| snow_day | 13.0 | 0.367 | 0.519 | 0.652 | 0.284 | 87.4% | 0.244 | FAIL — under floor (87% > 50%) |
| snow_night | 21.0 | 0.077 | 0.140 | 0.264 | 0.187 | 99.7% | 0.604 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.319 | 0.428 | 0.583 | 0.264 | 95.4% | 0.324 | FAIL — under floor (95% > 50%) |
| desert_night | 21.0 | 0.045 | 0.085 | 0.174 | 0.129 | 99.8% | 0.537 | FAIL — no anchors (p95 0.17 < 0.30) |
| rain_day | 13.0 | 0.316 | 0.591 | 0.783 | 0.467 | 49.3% | 0.171 | ok |
| rain_night | 21.0 | 0.038 | 0.111 | 0.223 | 0.184 | 99.8% | 0.605 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.227 | 0.443 | 0.648 | 0.421 | 89.5% | 0.147 | FAIL — under floor (89% > 50%) |
| combat_day | 13.0 | 0.240 | 0.549 | 0.753 | 0.513 | 55.9% | 0.152 | FAIL — under floor (56% > 50%) |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.330 | 0.388 | 91.3% | 0.098 | 11.5% | FAIL |
| robot_heavy | 0.323 | 0.226 | 90.8% | 0.119 | 13.5% | FAIL |
| robot_elite | 0.357 | 0.411 | 88.2% | 0.132 | 11.8% | FAIL |
| robot_tick | 0.346 | 0.232 | 81.5% | 0.179 | 9.6% | FAIL |
| robot_wasp | 0.287 | 0.203 | 84.9% | 0.172 | 6.5% | FAIL |
| robot_specter | 0.366 | 0.213 | 79.9% | 0.095 | 8.0% | FAIL |
| robot_caller | 0.395 | 0.324 | 76.9% | 0.167 | 6.7% | FAIL |
| robot_bastion | 0.303 | 0.179 | 89.1% | 0.224 | 15.8% | FAIL |
| robot_frosthound | 0.420 | 0.455 | 74.1% | 0.125 | 8.9% | FAIL |
| robot_kappa | 0.223 | 0.164 | 94.6% | 0.082 | 10.7% | FAIL |
| robot_scarab | 0.418 | 0.438 | 83.8% | 0.252 | 10.8% | FAIL |
| robot_cryomortar | 0.448 | 0.377 | 67.4% | 0.191 | 8.3% | FAIL |
| robot_avalanche | 0.483 | 0.531 | 61.9% | 0.122 | 15.8% | ok |
| robot_sandworm | 0.364 | 0.216 | 80.5% | 0.178 | 4.7% | FAIL |
| robot_oni | 0.270 | 0.180 | 97.0% | 0.358 | 13.2% | FAIL |
| robot_boss | 0.268 | 0.199 | 98.5% | 0.190 | 15.4% | FAIL |
| player | 0.283 | 0.283 | 96.7% | 0.340 | 12.4% | FAIL |

**VERDICT: 8/10 frames FAIL, 16/17 machines FAIL | dark frames: urban_day, snow_day, snow_night, desert_day, desert_night, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_tick, robot_wasp, robot_specter, robot_caller, robot_bastion, robot_frosthound, robot_kappa, robot_scarab, robot_cryomortar, robot_sandworm, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
