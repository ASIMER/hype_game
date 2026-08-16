# Photostand — `d3_lanes`

captured 2026-08-16 06:03:44 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.293 | 0.564 | 0.732 | 0.439 | 64.8% | 0.157 | FAIL — under floor (65% > 50%) |
| urban_night | 21.0 | 0.067 | 0.150 | 0.382 | 0.315 | 99.3% | 0.376 | ok |
| snow_day | 13.0 | 0.244 | 0.549 | 0.757 | 0.512 | 71.3% | 0.194 | FAIL — under floor (71% > 50%) |
| snow_night | 21.0 | 0.045 | 0.130 | 0.256 | 0.211 | 99.7% | 0.609 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.357 | 0.500 | 0.756 | 0.399 | 67.7% | 0.298 | FAIL — under floor (68% > 50%) |
| desert_night | 21.0 | 0.041 | 0.098 | 0.186 | 0.145 | 99.8% | 0.445 | FAIL — no anchors (p95 0.19 < 0.30) |
| rain_day | 13.0 | 0.353 | 0.607 | 0.796 | 0.444 | 45.8% | 0.142 | ok |
| rain_night | 21.0 | 0.040 | 0.106 | 0.224 | 0.184 | 99.8% | 0.599 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.238 | 0.464 | 0.601 | 0.363 | 93.1% | 0.121 | FAIL — under floor (93% > 50%) |
| combat_day | 13.0 | 0.284 | 0.626 | 0.754 | 0.470 | 38.1% | 0.157 | ok |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.378 | 0.399 | 86.3% | 0.075 | 13.7% | FAIL |
| robot_heavy | 0.392 | 0.434 | 85.3% | 0.088 | 15.2% | FAIL |
| robot_elite | 0.423 | 0.454 | 81.8% | 0.212 | 11.9% | FAIL |
| robot_tick | 0.287 | 0.178 | 86.9% | 0.157 | 9.5% | FAIL |
| robot_wasp | 0.464 | 0.485 | 72.7% | 0.177 | 6.7% | ok |
| robot_specter | 0.410 | 0.355 | 76.3% | 0.092 | 7.2% | FAIL |
| robot_caller | 0.414 | 0.407 | 76.3% | 0.224 | 7.3% | FAIL |
| robot_bastion | 0.376 | 0.262 | 81.5% | 0.234 | 10.7% | FAIL |
| robot_frosthound | 0.403 | 0.452 | 77.9% | 0.123 | 7.5% | FAIL |
| robot_kappa | 0.321 | 0.253 | 89.3% | 0.093 | 11.1% | FAIL |
| robot_scarab | 0.366 | 0.394 | 86.1% | 0.245 | 8.1% | FAIL |
| robot_cryomortar | 0.396 | 0.227 | 71.2% | 0.170 | 8.0% | FAIL |
| robot_avalanche | 0.368 | 0.223 | 76.1% | 0.122 | 13.9% | FAIL |
| robot_sandworm | 0.249 | 0.165 | 95.0% | 0.112 | 6.2% | FAIL |
| robot_oni | 0.258 | 0.170 | 96.7% | 0.286 | 12.5% | FAIL |
| robot_boss | 0.314 | 0.270 | 91.4% | 0.141 | 15.0% | FAIL |
| player | 0.283 | 0.283 | 96.7% | 0.340 | 12.4% | FAIL |

**VERDICT: 7/10 frames FAIL, 16/17 machines FAIL | dark frames: urban_day, snow_day, snow_night, desert_day, desert_night, rain_night, interior_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_tick, robot_specter, robot_caller, robot_bastion, robot_frosthound, robot_kappa, robot_scarab, robot_cryomortar, robot_avalanche, robot_sandworm, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
