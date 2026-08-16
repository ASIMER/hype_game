# Photostand — `v3c`

captured 2026-08-16 05:24:32 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.253 | 0.516 | 0.729 | 0.476 | 72.8% | 0.178 | FAIL — under floor (73% > 50%) |
| urban_night | 21.0 | 0.053 | 0.145 | 0.261 | 0.208 | 99.8% | 0.389 | FAIL — no anchors (p95 0.26 < 0.30) |
| snow_day | 13.0 | 0.252 | 0.543 | 0.770 | 0.518 | 71.4% | 0.203 | FAIL — under floor (71% > 50%) |
| snow_night | 21.0 | 0.045 | 0.133 | 0.263 | 0.218 | 99.7% | 0.615 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.325 | 0.569 | 0.877 | 0.552 | 53.6% | 0.258 | FAIL — under floor (54% > 50%) |
| desert_night | 21.0 | 0.051 | 0.131 | 0.732 | 0.682 | 93.6% | 0.407 | ok |
| rain_day | 13.0 | 0.299 | 0.571 | 0.796 | 0.497 | 54.5% | 0.190 | FAIL — under floor (54% > 50%) |
| rain_night | 21.0 | 0.035 | 0.097 | 0.220 | 0.184 | 99.8% | 0.610 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.200 | 0.375 | 0.576 | 0.376 | 96.0% | 0.126 | FAIL — under floor (96% > 50%) |
| combat_day | 13.0 | 0.279 | 0.576 | 0.743 | 0.464 | 51.9% | 0.174 | FAIL — under floor (52% > 50%) |

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

**VERDICT: 9/10 frames FAIL, 16/17 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, rain_day, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_tick, robot_specter, robot_caller, robot_bastion, robot_frosthound, robot_kappa, robot_scarab, robot_cryomortar, robot_avalanche, robot_sandworm, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
