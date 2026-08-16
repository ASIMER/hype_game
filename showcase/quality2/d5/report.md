# Photostand — `d5`

captured 2026-08-16 03:36:01 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.216 | 0.523 | 0.733 | 0.516 | 72.1% | 0.178 | FAIL — under floor (72% > 50%) |
| urban_night | 21.0 | 0.019 | 0.124 | 0.255 | 0.236 | 99.5% | 0.436 | FAIL — no anchors (p95 0.25 < 0.30) |
| snow_day | 13.0 | 0.240 | 0.588 | 0.802 | 0.561 | 50.0% | 0.155 | FAIL — under floor (50% > 50%) |
| snow_night | 21.0 | 0.045 | 0.142 | 0.261 | 0.217 | 99.6% | 0.592 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.067 | 0.396 | 0.755 | 0.688 | 80.7% | 0.407 | FAIL — under floor (81% > 50%) |
| desert_night | 21.0 | 0.000 | 0.084 | 0.287 | 0.287 | 99.1% | 0.405 | FAIL — no anchors (p95 0.29 < 0.30) |
| rain_day | 13.0 | 0.255 | 0.517 | 0.775 | 0.520 | 63.3% | 0.210 | FAIL — under floor (63% > 50%) |
| rain_night | 21.0 | 0.000 | 0.030 | 0.199 | 0.199 | 99.6% | 0.793 | FAIL — no anchors (p95 0.20 < 0.30) |
| interior_day | 13.0 | 0.190 | 0.302 | 0.497 | 0.307 | 99.1% | 0.267 | FAIL — under floor (99% > 50%) |
| combat_day | 13.0 | 0.251 | 0.569 | 0.746 | 0.495 | 52.9% | 0.175 | FAIL — under floor (53% > 50%) |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.330 | 0.388 | 91.5% | 0.098 | 11.5% | FAIL |
| robot_heavy | 0.320 | 0.229 | 91.8% | 0.120 | 13.5% | FAIL |
| robot_elite | 0.357 | 0.415 | 88.6% | 0.130 | 11.8% | FAIL |
| robot_frosthound | 0.420 | 0.456 | 74.6% | 0.124 | 8.9% | FAIL |
| robot_oni | 0.269 | 0.181 | 97.5% | 0.358 | 13.2% | FAIL |
| robot_boss | 0.268 | 0.199 | 98.8% | 0.189 | 15.4% | FAIL |
| player | 0.282 | 0.283 | 96.9% | 0.340 | 12.4% | FAIL |

**VERDICT: 10/10 frames FAIL, 7/7 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, desert_night, rain_day, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_frosthound, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
