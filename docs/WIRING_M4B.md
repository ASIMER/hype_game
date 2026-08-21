# M4b wiring — XP popups (M4.5) + contract tracker (M4.6)
**1. Instancing** — both are plain `extends Control`, self-position via anchors+offsets, and belong under the HUD's `$Root`. The one edit is the existing UX-component loop at `scripts/ui/hud.gd:275` — append the two ids, nothing else (no scene edit, no autoload):
`for comp in ["interaction_prompt", "stamina_bar", "compass", "killfeed", "damage_indicator", "xp_popup", "quest_tracker"]:`

**2. locale/ui.csv** — exactly ONE new row (I did not touch the file): `CONTRACTS,КОНТРАКТЫ`. Quest titles go through `tr(q.title)` over the existing `.tres` English-as-key strings; `xp_popup.gd` is deliberately tr()-free (raw number + source id).

**3. Assumptions / deviations**
- XP column raised to **270 px** above the bottom edge (brief said ~220): `hud.gd`'s 4-line key-hint sheet owns ~86–154 px and only *dims* after 75 s (hidden only in the storm), so 220 collided. The tracker sits at `offset_top 250` as specced, below the minimap (which ends at y≈172).
- Tracker source = `Quests.accepted()` (opted-in standing contracts) then `Quests.get_daily_quests()` (auto-active dailies), filtered to `state_of()=="active"` and not complete; a completed row flashes green and holds its slot 3 s before dropping.
- Both apply the `UILayout` ultrawide inset (minimap/killfeed pattern) and are headless-inert; the tracker also hides on `Events.map_toggled` and collapses when empty. **Not run in-engine** (instructed not to launch): gdformat+gdlint clean and the Godot 4.6.3 API names are binary-verified, but both want a visual pass at 16:9 + ultrawide.
