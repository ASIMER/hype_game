# M7.4 — item card + stash inspector wiring

**No wiring needed.** `scripts/ui/tabs/stash_tab.gd` builds the inspector itself in `_ready()` (`_build_inspector`) — StashTab.tscn, hub.gd, and main.gd are untouched, and no other script addresses the node paths it rearranges (verified by grep: only `hub.gd`'s scene-path list references StashTab).

**locale/ui.csv — 3 new rows needed** (I did not touch the CSV; reused `Value: %d`, `Total value: %d`, `CLOSE`, and the `Common`…`Legendary` rarity keys, which all already exist):

    "Weight: %.1f kg","Вес: %.1f кг"
    "[Unknown item]","[Неизвестный предмет]"
    "INSPECT","ОСМОТР"

- **Assumptions:** `ItemCard.make(id, count)` is the only entry point (`build()` is public solely so the static factory can call it without tripping gdlint's private-method-call); rarity colour comes exclusively from `ItemData.rarity_color()`; static label text is set RAW so Godot's Control auto-translate resolves it live (only format templates go through `tr()`); the ITEM **kind** is deliberately not shown — it would cost 6 more locale keys for a read the icon already gives.
- **Layout note:** the inspector adds a fixed 292 px column to the right of the stash grid; below ~740 px of tab width the 6-column grid starts scrolling horizontally instead of the panel shrinking.
