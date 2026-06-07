class_name UIStyle
extends RefCounted
## Shared "military glass" UI styling — the single source of truth for the dark
## translucent / chamfered / amber-accent look (Battlefield 2042 / Arc Raiders).
## Replaces the ~86 duplicated COL_* consts and the hand-rolled StyleBoxFlats spread
## across scripts/ui. Sibling of UILayout (both stateless RefCounted helpers).
##
## Two kinds of API:
##   - palette consts (AMBER/TEAL/DIM/…) → swap per-file COL_* blocks for UIStyle.AMBER
##   - factories (glass_panel/header_panel/chip/glow_fill/micro_header) + animation
##     helpers (pop_in/hover_lift) so each screen styles + animates with one call.
##
## The palette mirrors assets/ui/theme.tres exactly; the theme reaches most Controls
## automatically, this helper covers the in-code panels/labels the theme can't touch.

# ── Palette (matches assets/ui/theme.tres) ──────────────────────────────────
const AMBER     := Color(0.91, 0.64, 0.24, 1.0)
const TEAL      := Color(0.247, 0.71, 0.79, 1.0)
const DIM       := Color(0.45, 0.50, 0.55, 1.0)
const WHITE     := Color(0.88, 0.90, 0.92, 1.0)
const TEXT      := Color(0.85, 0.88, 0.90, 1.0)
const RED       := Color(0.85, 0.30, 0.25, 1.0)
const GREEN     := Color(0.40, 0.85, 0.40, 1.0)
const PANEL_BG  := Color(0.106, 0.133, 0.157, 1.0)
const GLASS_BG  := Color(0.062, 0.078, 0.094, 1.0)  # base for translucent panels
const BORDER_LT := Color(1.0, 1.0, 1.0, 0.12)       # thin light edge

# Chamfer radii — asymmetric bevel (top-left + bottom-right rounded, the other two
# tight) gives the beveled metal-plate read of the style.
const CHAMFER_BIG   := 10
const CHAMFER_SMALL := 2

const FONT_HEADER := preload("res://assets/fonts/RussoOne-Regular.ttf")

static var _header_font: FontVariation = null

## Russo One with extra glyph spacing — the spaced-caps header face. Cached.
static func header_font(extra_spacing: int = 3) -> FontVariation:
	if _header_font == null:
		_header_font = FontVariation.new()
		_header_font.base_font = FONT_HEADER
		_header_font.spacing_glyph = extra_spacing
	return _header_font

# ── StyleBox factories ──────────────────────────────────────────────────────

## The signature container background: translucent, chamfered, thin light border.
## Pass accent_stripe=true for a thicker colored top edge (header strips).
static func glass_panel(alpha: float = 0.82) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(GLASS_BG.r, GLASS_BG.g, GLASS_BG.b, alpha)
	sb.set_border_width_all(1)
	sb.border_color = BORDER_LT
	sb.corner_radius_top_left = CHAMFER_BIG
	sb.corner_radius_bottom_right = CHAMFER_BIG
	sb.corner_radius_top_right = CHAMFER_SMALL
	sb.corner_radius_bottom_left = CHAMFER_SMALL
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb

## A glass panel that reads as a header/section strip: a solid colored accent bar
## along the top edge + a faint accent glow. The colored border replaces the light
## one (StyleBoxFlat has a single border color) — top is thick, the rest hairline.
static func header_panel(accent: Color = AMBER, alpha: float = 0.85) -> StyleBoxFlat:
	var sb := glass_panel(alpha)
	sb.border_color = accent
	sb.border_width_top = 3
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.shadow_color = Color(accent.r, accent.g, accent.b, 0.18)
	sb.shadow_size = 6
	return sb

## Small inline pill (killfeed rows, scoreboard cells, status tags).
static func chip(color: Color, alpha: float = 0.16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, alpha)
	sb.set_border_width_all(1)
	sb.border_color = Color(color.r, color.g, color.b, 0.5)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	return sb

## A progress-bar fill with a soft same-color glow (amber/teal energy line).
static func glow_fill(color: Color = TEAL) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(3)
	sb.shadow_color = Color(color.r, color.g, color.b, 0.45)
	sb.shadow_size = 6
	return sb

## A spaced-caps micro-heading Label (Russo One). NOTE: text is left as-is so the
## localization auto-translate (English-as-key) still matches — pass the caps form
## you want (most section names are already uppercase in source).
static func micro_header(text: String, color: Color = DIM, size: int = 13) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", header_font(3))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

## Apply the header face to an existing Label in place (for titles built elsewhere).
static func make_header(l: Label, color: Color = WHITE, size: int = 22, spacing: int = 3) -> void:
	if l == null:
		return
	l.add_theme_font_override("font", header_font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)

# ── Animation helpers (the "Full set" polish) ───────────────────────────────

enum Dir { DOWN, UP, LEFT, RIGHT }

## Fade-in (+ a short slide when the control is free-positioned, not container-laid)
## when a screen opens. ~150 ms cubic ease-out. Safe to call in _ready()/open().
static func pop_in(c: Control, dir: int = Dir.DOWN, dist: float = 12.0, dur: float = 0.15) -> void:
	if c == null or not c.is_inside_tree():
		return
	c.modulate.a = 0.0
	var tw := c.create_tween()
	tw.set_parallel(true)
	tw.tween_property(c, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Only slide when the parent isn't a Container (else we fight the layout engine).
	if not (c.get_parent() is Container):
		var off := Vector2.ZERO
		match dir:
			Dir.DOWN: off = Vector2(0.0, -dist)
			Dir.UP:   off = Vector2(0.0, dist)
			Dir.LEFT: off = Vector2(dist, 0.0)
			Dir.RIGHT: off = Vector2(-dist, 0.0)
		var base: Vector2 = c.position
		c.position = base + off
		tw.tween_property(c, "position", base, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

## Wire a button to lift+brighten on hover (center-pivot scale + modulate). Cheap;
## scale is a visual transform so it co-exists with container layout.
static func hover_lift(btn: Control, scale_to: float = 1.03) -> void:
	if btn == null:
		return
	btn.mouse_entered.connect(func() -> void:
		btn.pivot_offset = btn.size * 0.5
		var tw := btn.create_tween()
		tw.set_parallel(true)
		tw.tween_property(btn, "scale", Vector2(scale_to, scale_to), 0.08)
		tw.tween_property(btn, "modulate", Color(1.12, 1.12, 1.12, 1.0), 0.08)
	)
	btn.mouse_exited.connect(func() -> void:
		var tw := btn.create_tween()
		tw.set_parallel(true)
		tw.tween_property(btn, "scale", Vector2.ONE, 0.08)
		tw.tween_property(btn, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.08)
	)
