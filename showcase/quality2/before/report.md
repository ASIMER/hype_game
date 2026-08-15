# Photostand — `before`

captured 2026-08-16 02:25:13 | port 24702 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

| frame | hour | p05 | p50 | p95 | %<0.588 | sat | sky p50 | status |
|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | 0.135 | 0.519 | 0.716 | 73.5% | 0.148 | 0.555 | FAIL |
| urban_night | 21.0 | 0.073 | 0.127 | 0.505 | 97.7% | 0.353 | 0.120 | FAIL |
| snow_day | 13.0 | 0.119 | 0.503 | 0.736 | 68.6% | 0.193 | 0.539 | FAIL |
| snow_night | 21.0 | 0.049 | 0.103 | 0.225 | 99.4% | 0.495 | 0.112 | FAIL |
| desert_day | 13.0 | 0.116 | 0.459 | 0.731 | 71.8% | 0.237 | 0.498 | FAIL |
| desert_night | 21.0 | 0.029 | 0.086 | 0.179 | 99.4% | 0.344 | 0.090 | FAIL |
| rain_day | 13.0 | 0.294 | 0.535 | 0.778 | 60.2% | 0.193 | 0.647 | FAIL |
| rain_night | 21.0 | 0.011 | 0.077 | 0.181 | 99.7% | 0.555 | 0.085 | FAIL |
| interior_day | 13.0 | 0.218 | 0.375 | 0.544 | 97.9% | 0.172 | 0.606 | FAIL |
| combat_day | 13.0 | 0.192 | 0.540 | 0.800 | 66.1% | 0.145 | 0.540 | FAIL |

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
