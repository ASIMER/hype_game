# Photostand — `d1c`

captured 2026-08-16 02:43:13 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.241 | 0.508 | 0.729 | 0.488 | 73.2% | 0.191 | FAIL — under floor (73% > 50%) |
| urban_night | 21.0 | 0.018 | 0.140 | 0.261 | 0.242 | 99.8% | 0.425 | FAIL — no anchors (p95 0.26 < 0.30) |
| snow_day | 13.0 | 0.320 | 0.567 | 0.790 | 0.470 | 58.4% | 0.176 | FAIL — under floor (58% > 50%) |
| snow_night | 21.0 | 0.045 | 0.144 | 0.261 | 0.215 | 99.8% | 0.587 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | 0.332 | 0.494 | 0.772 | 0.440 | 67.6% | 0.298 | FAIL — under floor (68% > 50%) |
| desert_night | 21.0 | 0.040 | 0.098 | 0.222 | 0.182 | 99.8% | 0.458 | FAIL — no anchors (p95 0.22 < 0.30) |
| rain_day | 13.0 | 0.298 | 0.571 | 0.795 | 0.497 | 54.3% | 0.190 | FAIL — under floor (54% > 50%) |
| rain_night | 21.0 | 0.029 | 0.095 | 0.220 | 0.190 | 99.8% | 0.612 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.186 | 0.298 | 0.493 | 0.306 | 99.2% | 0.269 | FAIL — under floor (99% > 50%) |
| combat_day | 13.0 | 0.264 | 0.575 | 0.744 | 0.480 | 51.9% | 0.183 | FAIL — under floor (52% > 50%) |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.171 | 0.169 | 98.3% | 0.133 | 11.5% | FAIL |
| robot_heavy | 0.144 | 0.143 | 100.0% | 0.172 | 13.5% | FAIL |
| robot_elite | 0.175 | 0.136 | 98.6% | 0.204 | 11.8% | FAIL |
| robot_frosthound | 0.241 | 0.217 | 95.9% | 0.200 | 8.9% | FAIL |
| robot_oni | 0.118 | 0.087 | 100.0% | 0.573 | 13.2% | FAIL |
| robot_boss | 0.126 | 0.112 | 99.8% | 0.246 | 15.4% | FAIL |
| player | 0.155 | 0.134 | 97.5% | 0.423 | 12.4% | FAIL |

**VERDICT: 10/10 frames FAIL, 7/7 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, desert_night, rain_day, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_frosthound, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
