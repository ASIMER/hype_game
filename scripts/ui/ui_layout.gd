class_name UILayout
extends RefCounted
## Single source of truth for the ultrawide-comfort HUD inset. Edge-anchored UI shifts
## toward screen center by a configurable margin (a fraction of the viewport size), so
## corner elements stay readable on very wide displays. Driven by Settings.ui_edge_margin
## / Settings.ui_top_margin and re-applied on Events.ui_layout_changed + size_changed.

## Horizontal inset in pixels: how far to pull left/right-edge UI toward center.
static func edge_px(vp_w: float) -> float:
	return Settings.ui_edge_margin * vp_w

## Vertical inset in pixels: how far to pull top/bottom-edge UI toward center.
static func top_px(vp_h: float) -> float:
	return Settings.ui_top_margin * vp_h

## How many columns of `card_w`-wide cards (with `gutter` between) fit in `avail_w` pixels,
## clamped to [1, max_cols]. The single source of truth for the responsive Hub list grids
## (quests / gunsmith / stash / shop / character) so a single card never stretches full-width
## on a wide/ultrawide monitor — more columns appear as the window gets wider. Recompute on
## the tab's `resized` signal and set GridContainer.columns from this.
static func columns_for(avail_w: float, card_w: float, gutter: float = 12.0, max_cols: int = 6) -> int:
	if avail_w <= 0.0 or card_w <= 0.0:
		return 1
	var cols: int = int(floor((avail_w + gutter) / (card_w + gutter)))
	return clampi(cols, 1, max_cols)
