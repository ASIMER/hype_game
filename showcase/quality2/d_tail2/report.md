# Photostand — `d_tail2`

captured 2026-08-16 07:00:39 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.241 | 0.555 | 0.741 | 0.501 | 65.0% | 0.178 | FAIL — under floor (65% > 50%) |
| urban_night | 21.0 | 0.061 | 0.142 | 0.370 | 0.309 | 99.8% | 0.387 | ok |
| snow_day | 13.0 | 0.249 | 0.527 | 0.772 | 0.524 | 74.0% | 0.208 | FAIL — under floor (74% > 50%) |
| snow_night | 21.0 | 0.040 | 0.134 | 0.259 | 0.219 | 99.7% | 0.598 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.335 | 0.490 | 0.764 | 0.428 | 69.6% | 0.299 | FAIL — under floor (70% > 50%) |
| desert_night | 21.0 | 0.036 | 0.105 | 0.194 | 0.158 | 99.8% | 0.437 | FAIL — no anchors (p95 0.19 < 0.30) |
| rain_day | 13.0 | 0.280 | 0.513 | 0.753 | 0.473 | 69.7% | 0.225 | FAIL — under floor (70% > 50%) |
| rain_night | 21.0 | 0.022 | 0.084 | 0.188 | 0.165 | 99.8% | 0.624 | FAIL — no anchors (p95 0.19 < 0.30) |
| interior_day | 13.0 | 0.246 | 0.449 | 0.590 | 0.344 | 95.0% | 0.124 | FAIL — under floor (95% > 50%) |
| combat_day | 13.0 | 0.269 | 0.618 | 0.749 | 0.480 | 44.0% | 0.173 | ok |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.376 | 0.399 | 87.5% | 0.075 | 13.7% | FAIL |
| robot_heavy | 0.389 | 0.433 | 85.5% | 0.090 | 15.2% | FAIL |
| robot_elite | 0.422 | 0.451 | 81.7% | 0.212 | 11.9% | FAIL |
| robot_tick | 0.279 | 0.168 | 87.1% | 0.162 | 9.5% | FAIL |
| robot_wasp | 0.463 | 0.485 | 72.9% | 0.178 | 6.7% | ok |
| robot_specter | 0.409 | 0.355 | 76.5% | 0.092 | 7.2% | FAIL |
| robot_caller | 0.410 | 0.402 | 76.5% | 0.226 | 7.3% | FAIL |
| robot_bastion | 0.371 | 0.236 | 81.7% | 0.236 | 10.7% | FAIL |
| robot_frosthound | 0.396 | 0.452 | 78.3% | 0.124 | 7.5% | FAIL |
| robot_kappa | 0.318 | 0.241 | 89.6% | 0.094 | 11.1% | FAIL |
| robot_scarab | 0.361 | 0.383 | 86.3% | 0.248 | 8.1% | FAIL |
| robot_cryomortar | 0.392 | 0.223 | 71.4% | 0.170 | 8.0% | FAIL |
| robot_avalanche | 0.364 | 0.221 | 76.3% | 0.123 | 13.9% | FAIL |
| robot_sandworm | 0.245 | 0.161 | 95.2% | 0.114 | 6.2% | FAIL |
| robot_oni | 0.252 | 0.166 | 97.4% | 0.289 | 12.5% | FAIL |
| robot_boss | 0.311 | 0.256 | 91.5% | 0.140 | 15.0% | FAIL |
| player | 0.281 | 0.283 | 96.7% | 0.341 | 12.4% | FAIL |

**VERDICT: 8/10 frames FAIL, 16/17 machines FAIL | dark frames: urban_day, snow_day, snow_night, desert_day, desert_night, rain_day, rain_night, interior_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_tick, robot_specter, robot_caller, robot_bastion, robot_frosthound, robot_kappa, robot_scarab, robot_cryomortar, robot_avalanche, robot_sandworm, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
