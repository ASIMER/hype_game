extends Control
class_name ShopTab
## ShopTab — the SHOP hub tab. Lets the player spend currency to buy consumables,
## ammo, and materials from a fixed stock, plus purchase crafting blueprints.
##
## Data flow:
##   MetaProgression.currency      -> live currency shown in header
##   MetaProgression.spend(n)      -> deduct currency on purchase
##   MetaProgression.is_blueprint_known(bp) -> drives LEARNED / BUY state
##   Stash.add(id, 1)              -> deliver purchased items
##   Crafting.buy_blueprint(bp, p) -> spends + learns a blueprint
##   Crafting.all_recipes()        -> yields blueprints to list
##   ItemCatalog.get_item(id)      -> display name / value for each stock entry
##   AssetRegistry.get_icon(id)    -> icon or colored-box fallback
##
## Refreshed automatically on Events.currency_changed + Events.blueprint_learned.

# ── Stock: item id -> buy price (≈ ItemData.value * 2 markup) ────────────────
const STOCK: Dictionary = {
	"loot_medkit": 60,
	"loot_grenade": 50,
	"loot_ammo": 20,
	"loot_scrap": 10,
	"loot_cell": 40,
	"loot_plastic": 15,
	# Batch C: annex keys (price mirrors Settings.KEY_SHOP_PRICE — const init can't
	# read the autoload; keep in sync) + the signal-extraction flare.
	"key_tower": 700,
	"key_lodge": 700,
	"key_temple": 700,
	"loot_flare": 150,
	# Batch B: worn armor + medicine (≈ value × 2 markup, like the rest).
	"armor_helmet_t1": 440,
	"armor_helmet_t2": 840,
	"armor_vest_t1": 600,
	"armor_vest_t2": 1120,
	"armor_pack_med": 520,
	"armor_pack_large": 1040,
	"loot_bandage": 80,
	"loot_splint": 160,
	"loot_painkiller": 120,
}

# ── Blueprint prices: blueprint id -> buy price ───────────────────────────────
const BLUEPRINT_PRICE: Dictionary = {
# Default for any blueprint not explicitly listed is BLUEPRINT_PRICE_DEFAULT.
}
const BLUEPRINT_PRICE_DEFAULT := 400

# Project theme colours (matching workshop_tab.gd / loadout_tab.gd).
const COL_AMBER := UIStyle.AMBER
const COL_TEAL := UIStyle.TEAL
const COL_DIM := UIStyle.DIM
const COL_WHITE := UIStyle.WHITE
const COL_RED := UIStyle.RED
const COL_GREEN := UIStyle.GREEN

# ── Node refs (assigned by _build_layout; no @onready — tree is built in code) ─
var _currency_label: Label = null
var _item_rows: GridContainer = null
var _blueprint_rows: VBoxContainer = null
var _no_blueprints_label: Label = null

## Per-stock-cell UI references: item id -> { buy_btn: Button, price_lbl: Label }
var _item_ui: Dictionary = {}
## Per-blueprint-row UI references: bp id -> { buy_btn: Button, status_lbl: Label }
var _blueprint_ui: Dictionary = {}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	_build_layout()
	Events.currency_changed.connect(_on_currency_changed)
	Events.blueprint_learned.connect(_on_blueprint_learned)
	Events.reputation_changed.connect(_on_reputation_changed)
	_refresh()


func _exit_tree() -> void:
	if Events.currency_changed.is_connected(_on_currency_changed):
		Events.currency_changed.disconnect(_on_currency_changed)
	if Events.blueprint_learned.is_connected(_on_blueprint_learned):
		Events.blueprint_learned.disconnect(_on_blueprint_learned)
	if Events.reputation_changed.is_connected(_on_reputation_changed):
		Events.reputation_changed.disconnect(_on_reputation_changed)


# ── Layout construction ───────────────────────────────────────────────────────


## Builds the full node tree in code once. No .tscn sub-resources required.
## Structure:
##   ScrollContainer (fills tab)
##     MarginContainer
##       VBoxContainer (body)
##         Header HBox (title "SHOP" + live currency label)
##         Section header "ITEMS"
##         Panel → _item_rows VBox
##         Section header "BLUEPRINTS"
##         Panel → _blueprint_rows VBox  (+ _no_blueprints_label)
func _build_layout() -> void:
	# ── Scroll wrapper ────────────────────────────────────────────────────────
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	scroll.add_child(margin)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	margin.add_child(body)

	# ── Header: "SHOP" title + live currency ─────────────────────────────────
	var hdr_row := HBoxContainer.new()
	hdr_row.name = "HeaderRow"
	hdr_row.add_theme_constant_override("separation", 12)
	body.add_child(hdr_row)

	var title_lbl := Label.new()
	title_lbl.name = "TitleLabel"
	title_lbl.text = "SHOP"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.make_header(title_lbl, UIStyle.AMBER, 42, 3)
	hdr_row.add_child(title_lbl)

	_currency_label = Label.new()
	_currency_label.name = "CurrencyLabel"
	_currency_label.text = tr("CR %d") % MetaProgression.currency
	_currency_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_currency_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UIStyle.make_header(_currency_label, UIStyle.AMBER, 20, 2)
	hdr_row.add_child(_currency_label)

	# ── ITEMS section ─────────────────────────────────────────────────────────
	body.add_child(_make_section_header("ITEMS"))

	var items_panel := _make_panel()
	body.add_child(items_panel)

	_item_rows = GridContainer.new()
	_item_rows.name = "ItemRows"
	_item_rows.columns = 5
	_item_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_rows.add_theme_constant_override("h_separation", 12)
	_item_rows.add_theme_constant_override("v_separation", 12)
	items_panel.add_child(_item_rows)

	_build_item_rows()

	# ── BLUEPRINTS section ────────────────────────────────────────────────────
	body.add_child(_make_section_header("BLUEPRINTS"))

	var bp_panel := _make_panel()
	body.add_child(bp_panel)

	var bp_vbox := VBoxContainer.new()
	bp_vbox.name = "BpVBox"
	bp_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bp_vbox.add_theme_constant_override("separation", 8)
	bp_panel.add_child(bp_vbox)

	_no_blueprints_label = Label.new()
	_no_blueprints_label.name = "NoBpLabel"
	_no_blueprints_label.text = tr(
		"No blueprints available — check back after crafting more recipes."
	)
	_no_blueprints_label.add_theme_color_override("font_color", COL_DIM)
	_no_blueprints_label.add_theme_font_size_override("font_size", 14)
	_no_blueprints_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_no_blueprints_label.visible = false
	bp_vbox.add_child(_no_blueprints_label)

	_blueprint_rows = VBoxContainer.new()
	_blueprint_rows.name = "BpRows"
	_blueprint_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blueprint_rows.add_theme_constant_override("separation", 8)
	bp_vbox.add_child(_blueprint_rows)

	_build_blueprint_rows()


## Builds one compact icon cell per STOCK entry inside the _item_rows grid:
## an icon cell (40px) above the item name, a price caption, and a small BUY button.
func _build_item_rows() -> void:
	_item_ui.clear()
	for id in STOCK:
		var price: int = int(STOCK[id])
		var item: ItemData = ItemCatalog.get_item(id)
		var display: String = item.display_name if item != null else id

		# Vertical cell: [icon] [name] [price] [BUY]
		var cell := VBoxContainer.new()
		cell.name = "Cell_" + id
		cell.add_theme_constant_override("separation", 4)
		cell.size_flags_horizontal = Control.SIZE_FILL
		cell.tooltip_text = tr("%s\nCR %d") % [tr(display), price]

		# Icon cell (clickable shortcut to buy).
		var icon := _icon_cell(id, 0, 56)
		icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon.gui_input.connect(
			func(ev: InputEvent) -> void:
				if (
					ev is InputEventMouseButton
					and ev.pressed
					and ev.button_index == MOUSE_BUTTON_LEFT
				):
					_on_buy_item(id, price)
		)
		cell.add_child(icon)

		# Display name (small, centered, wrapping).
		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.text = tr(display)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_lbl.custom_minimum_size = Vector2(72, 0)
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		name_lbl.add_theme_font_size_override("font_size", 12)
		cell.add_child(name_lbl)

		# Price caption (recolors red when unaffordable in _refresh).
		var price_lbl := Label.new()
		price_lbl.name = "PriceLbl"
		price_lbl.text = tr("CR %d") % price
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_lbl.add_theme_color_override("font_color", COL_AMBER)
		price_lbl.add_theme_font_size_override("font_size", 13)
		cell.add_child(price_lbl)

		# Compact BUY button.
		var buy_btn := Button.new()
		buy_btn.name = "BuyBtn"
		buy_btn.text = tr("BUY")
		buy_btn.custom_minimum_size = Vector2(72, 26)
		buy_btn.focus_mode = Control.FOCUS_NONE
		buy_btn.pressed.connect(func() -> void: _on_buy_item(id, price))
		UIStyle.hover_lift(buy_btn)
		cell.add_child(buy_btn)

		_item_rows.add_child(cell)
		_item_ui[id] = {"buy_btn": buy_btn, "price_lbl": price_lbl}


## Builds blueprint rows from Crafting.all_recipes(), de-duplicated by blueprint id.
## Only recipes with a non-empty .blueprint are shown.
func _build_blueprint_rows() -> void:
	_blueprint_ui.clear()
	for c in _blueprint_rows.get_children():
		c.queue_free()

	# Collect unique blueprint ids (each bp may be referenced by multiple recipes).
	var seen_bps: Dictionary = {}  # bp id -> display_name
	var bp_output: Dictionary = {}  # bp id -> output item id (for the icon)
	for recipe in Crafting.all_recipes():
		var cr := recipe as CraftRecipe
		if cr == null:
			continue
		if cr.blueprint == "":
			continue
		if cr.blueprint in seen_bps:
			continue
		seen_bps[cr.blueprint] = cr.display_name
		bp_output[cr.blueprint] = cr.output_id

	if seen_bps.is_empty():
		_no_blueprints_label.visible = true
		_blueprint_rows.visible = false
		return

	_no_blueprints_label.visible = false
	_blueprint_rows.visible = true

	for bp_id in seen_bps:
		var disp: String = String(seen_bps[bp_id])
		var price: int = int(BLUEPRINT_PRICE.get(bp_id, BLUEPRINT_PRICE_DEFAULT))

		var row := HBoxContainer.new()
		row.name = "BpRow_" + bp_id
		row.add_theme_constant_override("separation", 10)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		# Blueprint icon: the recipe's OUTPUT item icon-cell (what the bp lets you build).
		var out_id: String = String(bp_output.get(bp_id, ""))
		var bp_icon := _icon_cell(out_id, 0, 40)
		bp_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bp_icon)

		# Display name.
		var name_lbl := Label.new()
		name_lbl.name = "NameLbl"
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text = disp
		name_lbl.add_theme_color_override("font_color", COL_WHITE)
		row.add_child(name_lbl)

		# Price / LEARNED label (shares the slot; text swaps at refresh).
		var status_lbl := Label.new()
		status_lbl.name = "StatusLbl"
		status_lbl.text = tr("CR %d") % price
		status_lbl.custom_minimum_size = Vector2(80, 0)
		status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		status_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		status_lbl.add_theme_font_size_override("font_size", 14)
		row.add_child(status_lbl)

		# BUY button.
		var buy_btn := Button.new()
		buy_btn.name = "BuyBtn"
		buy_btn.text = tr("BUY")
		buy_btn.custom_minimum_size = Vector2(72, 32)
		buy_btn.focus_mode = Control.FOCUS_NONE
		buy_btn.pressed.connect(func() -> void: _on_buy_blueprint(bp_id, price))
		UIStyle.hover_lift(buy_btn)
		row.add_child(buy_btn)

		_blueprint_rows.add_child(row)
		_blueprint_ui[bp_id] = {"buy_btn": buy_btn, "status_lbl": status_lbl}


# ── Helpers ───────────────────────────────────────────────────────────────────


## Returns a glass PanelContainer (military-glass look).
func _make_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.glass_panel())
	return pc


## Returns a glass header-panel PanelContainer with a spaced-caps teal label inside.
func _make_section_header(title: String) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.add_theme_stylebox_override("panel", UIStyle.header_panel(UIStyle.TEAL))
	pc.add_child(UIStyle.micro_header(title, UIStyle.TEAL, 15))
	return pc


## Arc-style icon cell: a fixed-size Panel with a rarity-colored border holding an
## icon TextureRect (or colored-box fallback) + an optional count badge.
## Modeled on inventory_ui.gd::_make_slot. `id` may be an ItemData id (border uses
## rarity_color) or any other id (border uses a neutral teal).
func _icon_cell(id: String, count: int, cell_size: int) -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(cell_size, cell_size)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.92)
	sb.set_border_width_all(2)
	var item: ItemData = ItemCatalog.get_item(id)
	sb.border_color = item.rarity_color() if item != null else COL_TEAL
	sb.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", sb)

	var icon := AssetRegistry.get_icon(id)
	if icon != null:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = 6
		tex.offset_top = 6
		tex.offset_right = -6
		tex.offset_bottom = -6
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex)
	else:
		var box := ColorRect.new()
		box.color = AssetRegistry.get_color(id)
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 8
		box.offset_top = 8
		box.offset_right = -8
		box.offset_bottom = -8
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(box)

	if count > 1:
		var badge := Label.new()
		badge.text = "x%d" % count
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		badge.set_anchors_preset(Control.PRESET_FULL_RECT)
		badge.offset_right = -3
		badge.offset_bottom = -1
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.add_theme_color_override("font_outline_color", Color.BLACK)
		badge.add_theme_constant_override("outline_size", 4)
		badge.add_theme_font_size_override("font_size", 13)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(badge)
	return slot


# ── Refresh ───────────────────────────────────────────────────────────────────


## Full affordability refresh — called on _ready and after any purchase signal.
func _refresh() -> void:
	if not is_inside_tree():
		return
	_refresh_currency_label()
	_refresh_item_buttons()
	_refresh_blueprint_buttons()


func _refresh_currency_label() -> void:
	if _currency_label == null:
		return
	_currency_label.text = tr("CR %d") % MetaProgression.currency


## Enable / disable each stock BUY button based on current currency.
## Displayed price reflects the current rep-tier discount.
func _refresh_item_buttons() -> void:
	for id in _item_ui:
		var base_price: int = int(STOCK.get(id, 0))
		var price: int = _discounted_price(base_price)
		var ui: Dictionary = _item_ui[id]
		var buy_btn: Button = ui["buy_btn"]
		var price_lbl: Label = ui["price_lbl"]
		var affordable: bool = MetaProgression.currency >= price
		buy_btn.disabled = not affordable
		price_lbl.text = tr("CR %d") % price
		price_lbl.add_theme_color_override("font_color", COL_AMBER if affordable else COL_RED)


## Sync blueprint rows: show LEARNED / update BUY affordability.
## Displayed price reflects the current rep-tier discount.
func _refresh_blueprint_buttons() -> void:
	for bp_id in _blueprint_ui:
		var base_price: int = int(BLUEPRINT_PRICE.get(bp_id, BLUEPRINT_PRICE_DEFAULT))
		var price: int = _discounted_price(base_price)
		var ui: Dictionary = _blueprint_ui[bp_id]
		var buy_btn: Button = ui["buy_btn"]
		var status_lbl: Label = ui["status_lbl"]

		if MetaProgression.is_blueprint_known(bp_id):
			status_lbl.text = tr("LEARNED")
			status_lbl.add_theme_color_override("font_color", COL_GREEN)
			buy_btn.text = tr("LEARNED")
			buy_btn.disabled = true
		else:
			status_lbl.text = tr("CR %d") % price
			status_lbl.add_theme_color_override("font_color", COL_AMBER)
			buy_btn.text = tr("BUY")
			buy_btn.disabled = MetaProgression.currency < price


# ── Signal handlers ───────────────────────────────────────────────────────────


func _on_currency_changed(_amount: int) -> void:
	## Currency changed — refresh header and button states.
	_refresh()


func _on_blueprint_learned(_bp: String) -> void:
	## A blueprint was learned (buy or extraction) — refresh blueprint rows.
	_refresh_blueprint_buttons()


func _on_reputation_changed(_rep: int, _tier: int) -> void:
	## Rep tier changed — prices may have changed; full refresh.
	_refresh()


# ── Rep discount helper ───────────────────────────────────────────────────────


## Returns the effective (discounted) price for a base price using the current
## vendor reputation tier discount (0% … 20%). Always >= 1.
func _discounted_price(base_price: int) -> int:
	var discount: float = MetaProgression.rep_discount()
	return maxi(1, int(round(float(base_price) * (1.0 - discount))))


# ── Purchase actions ──────────────────────────────────────────────────────────


## Attempt to buy 1 unit of a stock item. Deducts the discounted price, adds to stash.
func _on_buy_item(id: String, base_price: int) -> void:
	var price: int = _discounted_price(base_price)
	if not MetaProgression.spend(price):
		return
	Stash.add(id, 1)
	# currency_changed fires from spend(); _refresh() runs via _on_currency_changed.


## Attempt to buy a crafting blueprint at the discounted price.
func _on_buy_blueprint(bp_id: String, base_price: int) -> void:
	# Guard: already learned (button should be disabled, but be defensive).
	if MetaProgression.is_blueprint_known(bp_id):
		return
	var price: int = _discounted_price(base_price)
	Crafting.buy_blueprint(bp_id, price)
	# currency_changed + blueprint_learned fire automatically; UI refreshes.
