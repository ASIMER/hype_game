@tool
extends SceneTree

# Icon generator — run headless:
#   Godot_v4.6.3-stable_win64_console.exe --headless --path "C:\personal\hype game" --script res://tools/gen_icons.gd
#
# Writes 96x96 PNGs to res://assets/ui/icons/<name>.png
# Dark sci-fi palette: amber #e8a33d, teal #3fb6c9, steel #8899aa, dark panel #111820

const SIZE = 96
const OUT_DIR = "res://assets/ui/icons/"

# ---- palette -----------------------------------------------------------------
const C_CLEAR    := Color(0, 0, 0, 0)
const C_PANEL    := Color(0.067, 0.094, 0.125, 0.92)    # #111820 dark panel
const C_PANEL_LT := Color(0.11,  0.16,  0.22,  0.95)    # slightly lighter panel
const C_BORDER   := Color(0.3,   0.38,  0.46,  1.0)     # steel border
const C_AMBER    := Color(0.91,  0.64,  0.24,  1.0)     # #e8a33d weapons
const C_AMBER_D  := Color(0.55,  0.37,  0.12,  1.0)     # amber dark
const C_TEAL     := Color(0.25,  0.71,  0.79,  1.0)     # #3fb6c9 tech/medical
const C_TEAL_D   := Color(0.10,  0.35,  0.42,  1.0)
const C_STEEL    := Color(0.53,  0.60,  0.67,  1.0)     # steel grey
const C_STEEL_D  := Color(0.25,  0.30,  0.36,  1.0)
const C_WHITE    := Color(0.9,   0.94,  0.97,  1.0)
const C_GREEN    := Color(0.30,  0.80,  0.35,  1.0)
const C_GREEN_D  := Color(0.10,  0.40,  0.14,  1.0)
const C_TAN      := Color(0.65,  0.52,  0.34,  1.0)
const C_RED      := Color(0.80,  0.22,  0.18,  1.0)
const C_SCRAP    := Color(0.55,  0.55,  0.52,  1.0)
const C_SCRAP_D  := Color(0.30,  0.30,  0.28,  1.0)

# ---- helpers -----------------------------------------------------------------

func new_img() -> Image:
	var img = Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(C_CLEAR)
	return img

func fill_rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for py in range(y, y + h):
		for px in range(x, x + w):
			if px >= 0 and py >= 0 and px < SIZE and py < SIZE:
				img.set_pixel(px, py, c)

func draw_hline(img: Image, y: int, x0: int, x1: int, c: Color) -> void:
	for px in range(x0, x1 + 1):
		if px >= 0 and px < SIZE and y >= 0 and y < SIZE:
			img.set_pixel(px, y, c)

func draw_vline(img: Image, x: int, y0: int, y1: int, c: Color) -> void:
	for py in range(y0, y1 + 1):
		if py >= 0 and py < SIZE and x >= 0 and x < SIZE:
			img.set_pixel(x, py, c)

func draw_circle_filled(img: Image, cx: int, cy: int, r: int, c: Color) -> void:
	for py in range(cy - r, cy + r + 1):
		for px in range(cx - r, cx + r + 1):
			if (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r:
				if px >= 0 and py >= 0 and px < SIZE and py < SIZE:
					img.set_pixel(px, py, c)

func draw_circle_ring(img: Image, cx: int, cy: int, r_outer: int, r_inner: int, c: Color) -> void:
	for py in range(cy - r_outer, cy + r_outer + 1):
		for px in range(cx - r_outer, cx + r_outer + 1):
			var d2 = (px - cx) * (px - cx) + (py - cy) * (py - cy)
			if d2 <= r_outer * r_outer and d2 >= r_inner * r_inner:
				if px >= 0 and py >= 0 and px < SIZE and py < SIZE:
					img.set_pixel(px, py, c)

# Rounded rect: fills a rect then rounds corners by clearing pixels outside a radius
func fill_rounded_rect(img: Image, x: int, y: int, w: int, h: int, r: int, c: Color) -> void:
	fill_rect(img, x + r, y, w - r * 2, h, c)
	fill_rect(img, x, y + r, w, h - r * 2, c)
	draw_circle_filled(img, x + r, y + r, r, c)
	draw_circle_filled(img, x + w - r - 1, y + r, r, c)
	draw_circle_filled(img, x + r, y + h - r - 1, r, c)
	draw_circle_filled(img, x + w - r - 1, y + h - r - 1, r, c)

func draw_panel(img: Image) -> void:
	fill_rounded_rect(img, 2, 2, SIZE - 4, SIZE - 4, 8, C_PANEL)
	# border
	for py in range(2, SIZE - 2):
		for px in range(2, SIZE - 2):
			var on_border = (px == 2 or px == SIZE - 3 or py == 2 or py == SIZE - 3)
			if on_border:
				img.set_pixel(px, py, C_BORDER)

func save_icon(img: Image, name: String) -> void:
	var path = OUT_DIR + name + ".png"
	var err = img.save_png(path)
	if err == OK:
		print("  wrote " + path)
	else:
		printerr("  FAILED to write " + path + " err=" + str(err))

# ---- icon generators ---------------------------------------------------------

func gen_rifle() -> Image:
	var img = new_img()
	draw_panel(img)
	# Body — long rectangular barrel
	fill_rect(img, 14, 42, 58, 9, C_STEEL_D)
	fill_rect(img, 14, 43, 57, 7, C_STEEL)
	# Receiver / body
	fill_rect(img, 30, 38, 22, 17, C_AMBER_D)
	fill_rect(img, 31, 39, 20, 15, C_AMBER)
	# Stock
	fill_rect(img, 68, 44, 14, 8, C_AMBER_D)
	fill_rect(img, 69, 45, 12, 6, C_STEEL_D)
	# Grip
	fill_rect(img, 48, 53, 10, 16, C_AMBER_D)
	fill_rect(img, 49, 54, 8, 14, C_AMBER)
	# Muzzle detail
	fill_rect(img, 11, 44, 4, 5, C_TEAL)
	# Scope rail accent
	fill_rect(img, 32, 37, 18, 2, C_TEAL)
	# Highlight line on barrel
	draw_hline(img, 44, 14, 67, C_WHITE)
	return img

func gen_smg() -> Image:
	var img = new_img()
	draw_panel(img)
	# Compact barrel
	fill_rect(img, 16, 42, 38, 8, C_STEEL_D)
	fill_rect(img, 16, 43, 37, 6, C_STEEL)
	# Body
	fill_rect(img, 34, 37, 24, 18, C_AMBER_D)
	fill_rect(img, 35, 38, 22, 16, C_AMBER)
	# Stock (folded — short nub)
	fill_rect(img, 57, 43, 22, 7, C_STEEL_D)
	fill_rect(img, 58, 44, 20, 5, C_STEEL)
	# Grip (slightly forward)
	fill_rect(img, 44, 53, 10, 18, C_AMBER_D)
	fill_rect(img, 45, 54, 8, 16, C_AMBER)
	# Muzzle flash suppressor
	fill_rect(img, 13, 41, 4, 10, C_TEAL)
	fill_rect(img, 12, 43, 5, 6, C_TEAL_D)
	# Accent
	draw_hline(img, 44, 16, 53, C_WHITE)
	draw_hline(img, 37, 35, 56, C_TEAL)
	return img

func gen_shotgun() -> Image:
	var img = new_img()
	draw_panel(img)
	# Wide barrel (double-barrel look)
	fill_rect(img, 12, 36, 48, 10, C_STEEL_D)
	fill_rect(img, 12, 37, 47, 8, C_STEEL)
	fill_rect(img, 12, 48, 48, 10, C_STEEL_D)
	fill_rect(img, 12, 49, 47, 8, C_STEEL)
	# Receiver
	fill_rect(img, 56, 33, 14, 28, C_AMBER_D)
	fill_rect(img, 57, 34, 12, 26, C_AMBER)
	# Stock
	fill_rect(img, 68, 38, 16, 18, C_AMBER_D)
	fill_rect(img, 69, 39, 14, 16, C_AMBER)
	# Muzzle ends (two barrels)
	fill_rect(img, 9, 38, 4, 6, C_TEAL)
	fill_rect(img, 9, 50, 4, 6, C_TEAL)
	# Trigger guard
	fill_rect(img, 60, 56, 8, 4, C_STEEL)
	return img

func gen_pistol() -> Image:
	var img = new_img()
	draw_panel(img)
	# Slide / barrel (compact)
	fill_rect(img, 20, 36, 36, 11, C_STEEL_D)
	fill_rect(img, 20, 37, 35, 9, C_STEEL)
	# Frame
	fill_rect(img, 36, 46, 24, 14, C_AMBER_D)
	fill_rect(img, 37, 47, 22, 12, C_AMBER)
	# Grip
	fill_rect(img, 40, 58, 14, 20, C_AMBER_D)
	fill_rect(img, 41, 59, 12, 18, C_AMBER)
	# Barrel end
	fill_rect(img, 17, 39, 4, 6, C_TEAL)
	# Sight (small nub on top)
	fill_rect(img, 44, 34, 4, 3, C_TEAL)
	fill_rect(img, 22, 34, 4, 3, C_TEAL)
	# Highlight
	draw_hline(img, 38, 20, 54, C_WHITE)
	return img

func gen_dmr() -> Image:
	var img = new_img()
	draw_panel(img)
	# Long precision barrel
	fill_rect(img, 8, 43, 66, 8, C_STEEL_D)
	fill_rect(img, 8, 44, 65, 6, C_STEEL)
	# Receiver (longer than rifle)
	fill_rect(img, 32, 38, 26, 16, C_AMBER_D)
	fill_rect(img, 33, 39, 24, 14, C_AMBER)
	# Stock (longer, precision)
	fill_rect(img, 72, 41, 14, 12, C_AMBER_D)
	fill_rect(img, 73, 42, 12, 10, C_STEEL_D)
	# Scope (distinctive big box on top)
	fill_rect(img, 36, 31, 22, 8, C_STEEL_D)
	fill_rect(img, 37, 32, 20, 6, C_TEAL_D)
	fill_rect(img, 40, 33, 14, 4, C_TEAL)
	# Scope lens gleam
	draw_circle_filled(img, 42, 35, 2, C_WHITE)
	# Muzzle brake
	fill_rect(img, 5, 41, 5, 12, C_TEAL)
	# Bipod (small feet)
	fill_rect(img, 20, 50, 3, 10, C_STEEL)
	fill_rect(img, 28, 50, 3, 10, C_STEEL)
	# Grip
	fill_rect(img, 50, 52, 10, 16, C_AMBER_D)
	fill_rect(img, 51, 53, 8, 14, C_AMBER)
	return img

func gen_scrap() -> Image:
	var img = new_img()
	draw_panel(img)
	# Irregular shard silhouette — draw overlapping rects at angles to suggest metal fragments
	# Main shard — tilted parallelogram feel via overlapping rects
	fill_rect(img, 28, 22, 10, 50, C_SCRAP_D)
	fill_rect(img, 22, 30, 12, 34, C_SCRAP_D)
	fill_rect(img, 26, 24, 40, 8, C_SCRAP_D)
	fill_rect(img, 30, 62, 34, 8, C_SCRAP_D)
	# Fill interior
	fill_rect(img, 26, 28, 42, 40, C_SCRAP_D)
	# Highlight faces
	fill_rect(img, 28, 26, 36, 36, C_SCRAP)
	# Edge highlights (lighter top-left face)
	fill_rect(img, 30, 28, 20, 18, C_WHITE)
	# Scratch lines
	draw_hline(img, 38, 28, 62, C_SCRAP_D)
	draw_hline(img, 48, 32, 64, C_SCRAP_D)
	draw_vline(img, 42, 28, 62, C_SCRAP_D)
	# Darken corners to suggest 3D
	fill_rect(img, 60, 26, 8, 40, C_SCRAP_D)
	fill_rect(img, 26, 62, 40, 8, C_SCRAP_D)
	return img

func gen_cell() -> Image:
	var img = new_img()
	draw_panel(img)
	# Energy cell — vertical cylinder shape
	# Cylinder body
	fill_rect(img, 33, 20, 30, 56, C_TEAL_D)
	fill_rect(img, 35, 22, 26, 52, C_TEAL)
	# End caps (ellipse feel via rect + short rect)
	fill_rect(img, 33, 18, 30, 5, C_TEAL_D)
	fill_rect(img, 35, 16, 26, 6, C_STEEL)
	fill_rect(img, 33, 73, 30, 5, C_TEAL_D)
	fill_rect(img, 35, 75, 26, 4, C_STEEL)
	# Glow bands (energy segments)
	for i in range(3):
		var by = 28 + i * 14
		fill_rect(img, 35, by, 26, 4, C_GREEN)
	# Lightning bolt / charge symbol
	var bx = 43; var by2 = 34
	fill_rect(img, bx + 4, by2,      6, 10, C_WHITE)  # top bar
	fill_rect(img, bx,     by2 + 8,  10, 3, C_WHITE)  # middle
	fill_rect(img, bx + 2, by2 + 11, 6, 10, C_WHITE)  # bottom bar
	# Highlight edge
	draw_vline(img, 36, 22, 73, C_WHITE)
	return img

func gen_crate() -> Image:
	var img = new_img()
	draw_panel(img)
	# Box / crate shape (isometric-ish front face)
	# Front face
	fill_rect(img, 16, 30, 56, 44, C_TAN)
	# Top face (slightly lighter, offset)
	fill_rect(img, 24, 18, 48, 14, Color(0.78, 0.66, 0.46, 1.0))
	# Side face (right, darker)
	fill_rect(img, 72, 30, 8, 44, Color(0.42, 0.33, 0.20, 1.0))
	# Dark outline
	draw_hline(img, 30, 16, 71, C_PANEL)
	draw_hline(img, 73, 16, 71, C_PANEL)
	draw_vline(img, 16, 30, 73, C_PANEL)
	draw_vline(img, 72, 30, 73, C_PANEL)
	# Top edge lines
	draw_hline(img, 18, 24, 71, C_PANEL)
	draw_vline(img, 72, 18, 30, C_PANEL)
	# Cross planks on front face
	draw_hline(img, 48, 16, 71, C_PANEL)
	draw_vline(img, 44, 30, 73, C_PANEL)
	# Metal corner brackets (amber)
	fill_rect(img, 16, 30, 6, 6, C_AMBER)
	fill_rect(img, 66, 30, 6, 6, C_AMBER)
	fill_rect(img, 16, 68, 6, 6, C_AMBER)
	fill_rect(img, 66, 68, 6, 6, C_AMBER)
	# Lock/clasp
	fill_rect(img, 40, 46, 8, 6, C_AMBER_D)
	fill_rect(img, 41, 47, 6, 4, C_AMBER)
	return img

func gen_medkit() -> Image:
	var img = new_img()
	draw_panel(img)
	# White box body
	fill_rect(img, 18, 22, 60, 52, C_STEEL_D)
	fill_rect(img, 20, 24, 56, 48, C_WHITE)
	# Teal cross (classic medkit symbol)
	fill_rect(img, 36, 28, 24, 40, C_TEAL)   # vertical bar
	fill_rect(img, 26, 38, 44, 20, C_TEAL)   # horizontal bar
	# White inner cross highlight
	fill_rect(img, 38, 30, 20, 36, Color(0.8, 0.97, 1.0, 1.0))
	fill_rect(img, 28, 40, 40, 16, Color(0.8, 0.97, 1.0, 1.0))
	# Handle
	fill_rect(img, 34, 16, 28, 8, C_STEEL)
	fill_rect(img, 36, 18, 24, 6, C_STEEL_D)
	# Red accent stripe (urgency)
	fill_rect(img, 20, 68, 56, 4, C_RED)
	return img

func gen_grenade() -> Image:
	var img = new_img()
	draw_panel(img)
	# Grenade body (sphere, approximated)
	draw_circle_filled(img, 46, 58, 26, C_GREEN_D)
	draw_circle_filled(img, 46, 58, 24, C_GREEN)
	# Segmentation lines (grenade ridges)
	draw_hline(img, 58, 22, 70, C_GREEN_D)
	draw_hline(img, 48, 24, 68, C_GREEN_D)
	draw_hline(img, 68, 24, 68, C_GREEN_D)
	draw_vline(img, 46, 34, 80, C_GREEN_D)
	# Highlight (top-left sphere glint)
	draw_circle_filled(img, 37, 48, 6, Color(0.55, 0.95, 0.55, 0.7))
	# Spoon / lever
	fill_rect(img, 41, 24, 10, 6, C_STEEL)
	fill_rect(img, 43, 28, 6, 8, C_STEEL_D)
	# Pin ring
	draw_circle_ring(img, 48, 22, 7, 4, C_STEEL)
	fill_rect(img, 40, 18, 10, 5, C_STEEL)
	# Safety clip
	fill_rect(img, 54, 20, 4, 12, C_AMBER)
	return img

func gen_ammo() -> Image:
	var img = new_img()
	draw_panel(img)
	# Three bullets arranged diagonally
	var positions = [[20, 50], [38, 42], [56, 34]]
	for pos in positions:
		var bx = pos[0]; var by = pos[1]
		# Casing (amber cylinder)
		fill_rect(img, bx, by, 16, 28, C_AMBER_D)
		fill_rect(img, bx + 1, by + 1, 14, 26, C_AMBER)
		# Tip (steel/lead)
		fill_rect(img, bx + 2, by - 12, 12, 14, C_STEEL_D)
		fill_rect(img, bx + 3, by - 11, 10, 12, C_STEEL)
		# Tip point (tapering via smaller rects)
		fill_rect(img, bx + 4, by - 16, 8, 5, C_STEEL_D)
		fill_rect(img, bx + 6, by - 20, 4, 5, C_STEEL)
		# Primer (base dot)
		draw_circle_filled(img, bx + 8, by + 25, 3, C_AMBER_D)
		# Highlight line on casing
		draw_vline(img, bx + 3, by + 2, by + 24, C_WHITE)
	return img

# ---- main --------------------------------------------------------------------

func _init():
	print("gen_icons.gd: starting icon generation...")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var icons = {
		"rifle":   gen_rifle(),
		"smg":     gen_smg(),
		"shotgun": gen_shotgun(),
		"pistol":  gen_pistol(),
		"dmr":     gen_dmr(),
		"scrap":   gen_scrap(),
		"cell":    gen_cell(),
		"crate":   gen_crate(),
		"medkit":  gen_medkit(),
		"grenade": gen_grenade(),
		"ammo":    gen_ammo(),
	}

	for name in icons:
		save_icon(icons[name], name)

	print("gen_icons.gd: done — wrote " + str(icons.size()) + " icons to " + OUT_DIR)
	quit(0)
