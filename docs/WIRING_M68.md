# M6.8 wiring — offscreen world-event chevrons + sonar sting

**1. Instancing** — ONE line in `scripts/ui/hud.gd` `_ready()`, next to the M4 lane widgets (~line 80). It is a self-contained full-rect `extends Control` (no scene edit, no autoload, no `$Root` — added straight to the HUD CanvasLayer it draws ABOVE `$Root`, which is what edge markers want): `add_child((load("res://scripts/ui/event_chevrons.gd") as GDScript).new())`

**2. locale/ui.csv** — ZERO new rows (I did not touch the file). The only drawn string is the range readout, which reuses the EXISTING `"%d m"` key (settings_menu). The event NAME is deliberately not drawn: `hud._on_world_event_started` already banners `⚠ %s — %dm` at that exact moment, so the chevron adds only what the banner cannot — a persistent bearing + live range.

**3. Assumptions / risks**
- Range is measured from `get_viewport().get_camera_3d()` (null-checked every frame, per brief), i.e. from the CAMERA rather than the player body — a ~4 m third-person offset that never shows in a whole-metre readout.
- Data = `Events.world_event_started/ended` (NetworkManager relays BOTH to co-op clients) + a per-frame `"world_events"` group refresh so a moving mini-boss keeps its chevron. A client that JOINS mid-event still gets nothing (no catch-up relay exists — same limitation as `map_ui`). An ENDED event whose node lingers (a cracked `SupplyCache` sits ~3 s) is suppressed by an `_ended` set, otherwise the group refresh re-adopts it and the chevron ghosts back.
- **Not run in-engine** (instructed not to launch): gdformat + gdlint clean, and every API is proven in-repo (`get_theme_default_font` hud.gd:1248, `sort_custom(_method)` scoreboard.gd:198, `unproject_position`/`is_position_behind`/edge-rect math from ping_system.gd). Wants a visual pass on chevron scale at 16:9 vs 32:9 and on the 2 s flash brightness.
