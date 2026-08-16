# Photostand — `d2b`

captured 2026-08-16 03:00:01 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.253 | 0.509 | 0.729 | 0.476 | 72.9% | 0.184 | FAIL — under floor (73% > 50%) |
| urban_night | 21.0 | 0.068 | 0.141 | 0.261 | 0.193 | 99.8% | 0.406 | FAIL — no anchors (p95 0.26 < 0.30) |
| snow_day | 13.0 | 0.341 | 0.562 | 0.790 | 0.449 | 60.7% | 0.178 | FAIL — under floor (61% > 50%) |
| snow_night | 21.0 | 0.057 | 0.144 | 0.267 | 0.211 | 99.8% | 0.580 | FAIL — no anchors (p95 0.27 < 0.30) |
| desert_day | 13.0 | 0.332 | 0.495 | 0.774 | 0.442 | 66.3% | 0.296 | FAIL — under floor (66% > 50%) |
| desert_night | 21.0 | 0.040 | 0.099 | 0.221 | 0.181 | 99.8% | 0.454 | FAIL — no anchors (p95 0.22 < 0.30) |
| rain_day | 13.0 | 0.299 | 0.571 | 0.796 | 0.497 | 54.4% | 0.189 | FAIL — under floor (54% > 50%) |
| rain_night | 21.0 | 0.035 | 0.095 | 0.220 | 0.184 | 99.8% | 0.608 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.178 | 0.294 | 0.503 | 0.325 | 98.7% | 0.275 | FAIL — under floor (99% > 50%) |
| combat_day | 13.0 | 0.279 | 0.576 | 0.744 | 0.465 | 51.8% | 0.178 | FAIL — under floor (52% > 50%) |

## Machines (isolated 640px renders, alpha>0.5 mask)

| model | mean | p50 | %<0.588 | sat | coverage | status |
|---|---|---|---|---|---|---|
| robot_grunt | 0.261 | 0.301 | 98.2% | 0.104 | 11.5% | FAIL |
| robot_heavy | 0.252 | 0.178 | 98.5% | 0.124 | 13.5% | FAIL |
| robot_elite | 0.284 | 0.325 | 96.8% | 0.133 | 11.8% | FAIL |
| robot_frosthound | 0.337 | 0.355 | 85.3% | 0.130 | 8.9% | FAIL |
| robot_oni | 0.212 | 0.139 | 99.8% | 0.373 | 13.2% | FAIL |
| robot_boss | 0.212 | 0.153 | 99.8% | 0.195 | 15.4% | FAIL |
| player | 0.223 | 0.218 | 97.5% | 0.354 | 12.4% | FAIL |

**VERDICT: 10/10 frames FAIL, 7/7 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, desert_night, rain_day, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_frosthound, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
