# Photostand — `d3`

captured 2026-08-16 03:07:34 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | range | %<0.588 | sat | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.253 | 0.513 | 0.729 | 0.476 | 72.7% | 0.182 | FAIL — under floor (73% > 50%) |
| urban_night | 21.0 | 0.055 | 0.142 | 0.266 | 0.211 | 99.8% | 0.402 | FAIL — no anchors (p95 0.27 < 0.30) |
| snow_day | 13.0 | 0.337 | 0.567 | 0.790 | 0.454 | 59.0% | 0.175 | FAIL — under floor (59% > 50%) |
| snow_night | 21.0 | 0.059 | 0.144 | 0.266 | 0.206 | 99.8% | 0.582 | FAIL — no anchors (p95 0.27 < 0.30) |
| desert_day | 13.0 | 0.299 | 0.506 | 0.782 | 0.483 | 67.1% | 0.276 | FAIL — under floor (67% > 50%) |
| desert_night | 21.0 | 0.043 | 0.115 | 0.356 | 0.313 | 97.3% | 0.390 | ok |
| rain_day | 13.0 | 0.298 | 0.571 | 0.796 | 0.497 | 54.5% | 0.190 | FAIL — under floor (55% > 50%) |
| rain_night | 21.0 | 0.035 | 0.096 | 0.219 | 0.184 | 99.8% | 0.608 | FAIL — no anchors (p95 0.22 < 0.30) |
| interior_day | 13.0 | 0.189 | 0.301 | 0.494 | 0.305 | 99.1% | 0.267 | FAIL — under floor (99% > 50%) |
| combat_day | 13.0 | 0.279 | 0.577 | 0.744 | 0.465 | 51.7% | 0.177 | FAIL — under floor (52% > 50%) |

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

**VERDICT: 9/10 frames FAIL, 7/7 machines FAIL | dark frames: urban_day, urban_night, snow_day, snow_night, desert_day, rain_day, rain_night, interior_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_frosthound, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
