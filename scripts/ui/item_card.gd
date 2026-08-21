class_name ItemCard
extends PanelContainer
## Reusable "military glass" ITEM CARD (M7.4) — the one full presentation of an
## item: icon cell, rarity-coloured edge, name, rarity tier, weight/value, and the
## flavour description. Built entirely in code so any screen can drop one in with
## `ItemCard.make(id, count)` — the STASH inspector today, loot/shop/reward previews
## next — instead of hand-rolling yet another item panel.
##
## The rarity colour comes from `ItemData.rarity_color()`, the ONE rarity→colour
## source already backing the inventory_ui / stash_tab slot borders. Never declare a
## second palette here. Ids missing from ItemCatalog degrade gracefully: the raw id
## as the title, an "[Unknown item]" note, and the same grey edge a slot falls back to.
##
## Localization: STATIC label text is set RAW (English-as-key) so Godot's Control
## auto-translate resolves it and re-translates live on a locale change; only the
## format templates go through tr(). Same rule as UIStyle.micro_header().

## Card footprint. The height is a FLOOR, not a cap — the description autowraps and
## grows the card, so a long blurb is never clipped.
const CARD_MIN_SIZE := Vector2(260, 120)
## Icon cell size — the 64×64 stash/inventory slot, so a card and a grid slot read
## as the same object.
const ICON_SIZE := Vector2(64, 64)
## Edge colour for ids missing from ItemCatalog (mirrors the slot fallback grey).
const UNKNOWN_COLOR := Color(0.62, 0.62, 0.66)
## Inset of the icon texture / colour box inside the icon cell.
const ICON_INSET := 6.0
const BOX_INSET := 8.0


## Builds a finished card for `item_id`. `count` > 1 adds the stack badge and the
## stack's total value. Tolerates unknown ids and a cold (null) icon cache.
static func make(item_id: String, count: int = 1) -> ItemCard:
	var card := ItemCard.new()
	card.build(item_id, count)
	return card


## Fills an empty card. Public (not `_build`) purely so the static `make()` can call
## it without tripping the private-method-call lint. Call it exactly once per card.
func build(item_id: String, count: int = 1) -> void:
	var item: ItemData = ItemCatalog.get_item(item_id)
	var accent: Color = item.rarity_color() if item != null else UNKNOWN_COLOR
	var n: int = maxi(1, count)

	custom_minimum_size = CARD_MIN_SIZE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_stylebox_override("panel", _panel_style(accent))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	row.add_child(_icon_cell(item_id, n, accent))
	row.add_child(_body(item_id, item, n, accent))


# ------------------------------------------------------------------ styling
## Glass panel with a thick rarity-coloured LEFT edge. StyleBoxFlat carries a single
## border colour, so the other three sides stay hairline — the UIStyle.header_panel
## idiom, rotated to the left edge.
func _panel_style(accent: Color) -> StyleBoxFlat:
	var sb := UIStyle.glass_panel(0.88)
	sb.border_color = accent
	sb.border_width_left = 4
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.16)
	sb.shadow_size = 5
	return sb


# ------------------------------------------------------------------ icon cell
## The 64×64 icon: authored/rendered texture when AssetRegistry has one cached,
## else the logical colour box (headless and cold-cache safe), plus a stack badge.
func _icon_cell(item_id: String, count: int, accent: Color) -> Control:
	var cell := Panel.new()
	cell.custom_minimum_size = ICON_SIZE
	cell.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = accent
	sb.set_corner_radius_all(4)
	cell.add_theme_stylebox_override("panel", sb)

	var icon: Texture2D = AssetRegistry.get_icon(item_id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		# EXPAND_IGNORE_SIZE: without it a TextureRect renders at the 256 px source size.
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_inset(tex, ICON_INSET)
		cell.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(item_id)
		_inset(box, BOX_INSET)
		cell.add_child(box)

	if count > 1:
		var badge := Label.new()
		badge.text = "x%d" % count
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		badge.set_anchors_preset(Control.PRESET_FULL_RECT)
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.add_theme_color_override("font_outline_color", Color.BLACK)
		badge.add_theme_constant_override("outline_size", 4)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(badge)
	return cell


## Anchors `c` to fill its parent with an even margin, click-through.
func _inset(c: Control, margin: float) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.offset_left = margin
	c.offset_top = margin
	c.offset_right = -margin
	c.offset_bottom = -margin
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------ text body
## Right column: name, rarity tier, weight + value, the stack total, description.
## Kind is deliberately NOT shown — the icon carries it and it would cost six new
## locale keys for no read the player does not already have.
func _body(item_id: String, item: ItemData, count: int, accent: Color) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)

	var title_text: String = item.display_name if item != null else item_id
	var title := UIStyle.micro_header(title_text, UIStyle.WHITE, UIStyle.FONT_H2)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(title)

	if item == null:
		col.add_child(UIStyle.caption("[Unknown item]", accent))
		return col

	col.add_child(UIStyle.caption(item.rarity_name(), accent))

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 14)
	stats.add_child(UIStyle.caption(tr("Weight: %.1f kg") % item.weight))
	stats.add_child(UIStyle.caption(tr("Value: %d") % item.value))
	col.add_child(stats)

	if count > 1:
		var total_text: String = tr("Total value: %d") % (item.value * count)
		col.add_child(UIStyle.caption(total_text, UIStyle.AMBER))

	var desc: String = item.description.strip_edges()
	if not desc.is_empty():
		var blurb := UIStyle.caption(desc)
		blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		blurb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		col.add_child(blurb)
	return col
