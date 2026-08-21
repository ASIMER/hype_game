# M4a — in-raid levelup widget: wiring

**1. Instance it** (one line in `scripts/ui/hud.gd` `_build_hud_widgets()`, right after the skill-hotbar line ~142 — same parent, the HUD CanvasLayer's full-rect `Root` Control):
```gdscript
$Root.add_child((load("res://scripts/ui/raid_levelup.gd") as Script).new())
```

**2. Append to `locale/ui.csv`** (keys,ru — I did not touch the file):
```
LEVEL UP — PICK ONE,УРОВЕНЬ — ВЫБЕРИ ОДНО
LVL %d,УР %d
POWER UP: %s,УСИЛЕНИЕ: %s
```

**3. Assumptions / deviations**
- `AudioManager.play()` does **not** exist (only the private `_play`); I used the public `AudioManager.ui_panel(true/false)` for offer open/pick.
- Cards read `Settings.POWERS[id]` `name`/`desc`/`color`/`icon` when present (prettified id is only the fallback) — power names/descs stay English like the existing PowerReveal until someone adds catalog rows to the CSV.
- XP bar sits at bottom-centre offsets **-164..-140**, not -132: the `EXTRACTING` VBox grows up to ≈-127 and would have overlapped.
- Level/kills reset on `Events.match_started` (per-raid, like harvested skills); F1–F3 are read via `_unhandled_key_input`, no new input actions.
