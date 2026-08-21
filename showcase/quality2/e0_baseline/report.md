# Photostand — `e0_baseline`

captured 2026-08-21 07:20:42 | port 24700 | mutator `-` | clean

Luma = 0.2126R+0.7152G+0.0722B on sRGB bytes, over the frame minus the top 14% / bottom 16% (HUD). `%<0.588` = share of WORLD pixels under the readable floor.

## Frames

`prep` is the shutter hygiene, and it is how a suspicious row is triaged: `cN` = machines cleared around the stand before the shutter (INTERIORS only — an outdoor frame keeps its machines, and combat_day spawns its own), `evK` = a world event of kind K was running and was ended, `dX` = how far p50 still moved between the last two throwaway exposures when the shutter opened (gate: 0.004). A `d` at or under the gate means the scene had stopped; a larger one means the shoot ran out of patience and the row is a sample of a moving scene, not a measurement.

| frame | hour | region | p05 | p50 | p95 | range | %<0.588 | sat | prep | status |
|---|---|---|---|---|---|---|---|---|---|---|
| urban_day | 13.0 | below-sky | 0.255 | 0.554 | 0.737 | 0.482 | 64.9% | 0.178 | d0.002 | FAIL — under floor (65% > 50%) |
| urban_night | 21.0 | below-sky | 0.061 | 0.142 | 0.397 | 0.336 | 98.7% | 0.402 | d0.000 | ok |
| snow_day | 13.0 | below-sky | 0.267 | 0.520 | 0.769 | 0.502 | 74.9% | 0.213 | d0.002 | FAIL — under floor (75% > 50%) |
| snow_night | 21.0 | below-sky | 0.038 | 0.135 | 0.259 | 0.221 | 99.9% | 0.597 | d0.000 | FAIL — no anchors (p95 0.26 < 0.30) |
| desert_day | 13.0 | below-sky | 0.345 | 0.488 | 0.763 | 0.418 | 70.6% | 0.299 | d0.001 | FAIL — under floor (71% > 50%) |
| desert_night | 21.0 | below-sky | 0.032 | 0.108 | 0.210 | 0.178 | 99.8% | 0.434 | d0.000 | FAIL — no anchors (p95 0.21 < 0.30) |
| rain_day | 13.0 | below-sky | 0.283 | 0.524 | 0.729 | 0.446 | 68.1% | 0.209 | d0.001 | FAIL — under floor (68% > 50%) |
| rain_night | 21.0 | below-sky | 0.025 | 0.088 | 0.188 | 0.163 | 99.9% | 0.620 | d0.000 | FAIL — no anchors (p95 0.19 < 0.30) |
| interior_day | 13.0 | FULL (indoor) | 0.221 | 0.530 | 0.725 | 0.504 | 70.3% | 0.147 | c0 d0.001 | FAIL — under floor (70% > 50%) |
| interior_night | 21.0 | FULL (indoor) | 0.189 | 0.478 | 0.687 | 0.498 | 83.8% | 0.231 | c0 d0.001 | FAIL — not night (p50 0.48 > 0.34) |
| interior_tower2_day | 13.0 | FULL (indoor) | 0.276 | 0.447 | 0.665 | 0.390 | 88.1% | 0.220 | c0 d0.001 | FAIL — under floor (88% > 50%) |
| interior_warehouse_day | 13.0 | FULL (indoor) | 0.000 | 0.306 | 0.516 | 0.516 | 97.7% | 0.163 | c0 d0.000 | FAIL — under floor (98% > 50%) |
| interior_house_day | 13.0 | FULL (indoor) | 0.239 | 0.630 | 0.758 | 0.519 | 34.2% | 0.174 | c0 d0.000 | ok |
| interior_shrine_day | 13.0 | FULL (indoor) | 0.079 | 0.385 | 0.727 | 0.648 | 82.1% | 0.347 | c0 d0.001 | FAIL — under floor (82% > 50%) |
| combat_day | 13.1 | below-sky | 0.217 | 0.568 | 0.730 | 0.512 | 54.2% | 0.176 | d0.004 | FAIL — under floor (54% > 50%) |

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

## Readability (A/B pair: same frame without / with ONE machine)

The pixels that differ between the two shots ARE the machine. `contrast` = mean |luma of those pixels - median luma of the 12 px background ring around them|, on the B frame, averaged over the 2 pairs each probe shoots. DAY fails only when the WHOLE measured band (`band`, min..max of those pairs) is under 0.10 — the gate sits inside this tool's own run-to-run spread, so one shutter cannot decide it; read `spread` before trusting any single number. Night pairs are report-only (there the number is mostly the emissive eye). `range` is the measured distance at the shutter (gated to 8.5+-1.0 m so probes are compared at the same apparent size). `dp50` is the naive median-vs-median reading, kept for reference — it collapses on a two-tone chassis (see `analyze_readability`). `cover` = mask share of the analysed region, `noise` = share of that region which changed for reasons OTHER than the machine (wind, particles, other machines): a pair with high `noise` is weather, not a measurement.

| probe | machine | hour | range | target | bg | contrast | band | spread | dp50 | dsat | cover | noise | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| urban_grunt | grunt | 13.0 | 8.7m | 0.550 | 0.687 | **0.193** | 0.168-0.218 | 0.050 | 0.137 | +0.011 | 1.79% | 2.2% | ok (2/2 pairs) |
| urban_heavy | heavy | 13.1 | 9.3m | 0.682 | 0.698 | **0.133** | 0.101-0.165 | 0.064 | 0.024 | +0.032 | 1.74% | 3.0% | ok (2/2 pairs) |
| snow_frosthound | frosthound | 13.1 | 8.8m | 0.661 | 0.721 | **0.126** | 0.117-0.134 | 0.018 | 0.060 | +0.074 | 0.65% | 1.5% | ok (2/2 pairs) |
| urban_grunt_night | grunt | 21.1 | 8.6m | 0.544 | 0.442 | **0.210** | 0.161-0.259 | 0.099 | 0.113 | -0.002 | 3.41% | 3.9% | n/a (2/2 pairs) |

**VERDICT: 13/15 frames FAIL, 16/17 machines FAIL, 0/4 readability FAIL | dark frames: urban_day, snow_day, snow_night, desert_day, desert_night, rain_day, rain_night, interior_day, interior_night, interior_tower2_day, interior_warehouse_day, interior_shrine_day, combat_day | dark machines: robot_grunt, robot_heavy, robot_elite, robot_tick, robot_specter, robot_caller, robot_bastion, robot_frosthound, robot_kappa, robot_scarab, robot_cryomortar, robot_avalanche, robot_sandworm, robot_oni, robot_boss, player**

Contact sheet: `contact.jpg` (montage via ffmpeg).
