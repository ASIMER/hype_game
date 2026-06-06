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
