# Photostand — `d3final`

captured 2026-08-16 04:07:50 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.255 | 0.516 | 0.729 | 0.474 | 73.1% | 0.177 | FAIL — under floor (73% > 50%) |
| urban_night | 21.0 | 0.067 | 0.145 | 0.265 | 0.198 | 99.8% | 0.389 | FAIL — no anchors (p95 0.27 < 0.30) |
| snow_day | 13.0 | 0.253 | 0.543 | 0.772 | 0.520 | 70.9% | 0.203 | FAIL — under floor (71% > 50%) |
| snow_night | 21.0 | 0.045 | 0.133 | 0.274 | 0.229 | 99.7% | 0.617 | FAIL — no anchors (p95 0.27 < 0.30) |
| desert_day | 13.0 | 0.346 | 0.491 | 0.764 | 0.418 | 68.1% | 0.296 | FAIL — under floor (68% > 50%) |
| desert_night | 21.0 | 0.046 | 0.099 | 0.193 | 0.148 | 99.8% | 0.439 | FAIL — no anchors (p95 0.19 < 0.30) |
| rain_day | 13.0 | 0.299 | 0.569 | 0.796 | 0.497 | 54.8% | 0.192 | FAIL — under floor (55% > 50%) |
| rain_night | 21.0 | 0.039 | 0.177 | 0.933 | 0.894 | 78.8% | 0.510 | ok |
| interior_day | 13.0 | 0.200 | 0.378 | 0.573 | 0.372 | 96.3% | 0.121 | FAIL — under floor (96% > 50%) |
| combat_day | 13.0 | 0.279 | 0.577 | 0.744 | 0.465 | 51.7% | 0.174 | FAIL — under floor (52% > 50%) |

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

**VERDICT: 9/10 frames FAIL, 7/7 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, desert_night, rain_day, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_frosthound, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
