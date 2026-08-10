extends Control
## Main menu: Single Player / Host / Join + Settings + Quit. Drives NetworkManager
## and tells Main to load the arena. Settings open an overlaid SettingsMenu instance.

@onready var ip_field: LineEdit = $Panel/VBox/IPField
@onready var name_field: LineEdit = $Panel/VBox/NameField
@onready var status: Label = $Panel/VBox/Status
@onready var settings_menu := $SettingsMenu

const SERVER_BROWSER := "res://scenes/ui/ServerBrowser.tscn"
var _server_browser: Control = null
var _credits: Node = null  # CanvasLayer overlay (credits_screen.gd)


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Show the real build version (single source of truth) so it never drifts from VERSION.
	if has_node("Version"):
		$Version.text = "v" + Settings.GAME_VERSION
	Events.all_players_ready.connect(_on_all_ready)
	$Panel/VBox/SinglePlayerBtn.pressed.connect(_on_single_player)
	$Panel/VBox/HostBtn.pressed.connect(_on_host)
	$Panel/VBox/JoinBtn.pressed.connect(_on_join)
	$Panel/VBox/ServersBtn.pressed.connect(_on_servers)
	$Panel/VBox/BottomRow/SettingsBtn.pressed.connect(_on_settings)
	$Panel/VBox/BottomRow/QuitBtn.pressed.connect(_on_quit)
	settings_menu.closed.connect(_on_settings_closed)
	settings_menu.visible = false
	# Server browser overlay (direct connect / favorites / LAN) — instanced like the
	# settings menu. Selecting a server emits connect_requested → the shared _join flow.
	if ResourceLoader.exists(SERVER_BROWSER):
		_server_browser = (load(SERVER_BROWSER) as PackedScene).instantiate()
		add_child(_server_browser)
		if _server_browser.has_signal("connect_requested"):
			_server_browser.connect_requested.connect(_on_browser_connect)
		if _server_browser.has_signal("closed"):
			_server_browser.closed.connect(_on_browser_closed)
	# CREDITS button (code-added — MainMenu.tscn stays single-owner) + its overlay:
	# in-product CC-BY/OFL/MIT attribution, legally required for release builds.
	var credits_btn := Button.new()
	credits_btn.name = "CreditsBtn"
	credits_btn.text = "CREDITS"
	$Panel/VBox/BottomRow.add_child(credits_btn)
	$Panel/VBox/BottomRow.move_child(credits_btn, $Panel/VBox/BottomRow/QuitBtn.get_index())
	credits_btn.pressed.connect(_on_credits)
	UIStyle.hover_lift(credits_btn)
	_credits = (load("res://scripts/ui/credits_screen.gd") as GDScript).new()
	add_child(_credits)
	_apply_glass_style()


## Military-glass polish: Russo One title, frosted-glass backdrop behind the panel,
## hover-lift on the buttons, and a fade+slide open animation.
func _apply_glass_style() -> void:
	UIStyle.make_header($TitleBox/Title, UIStyle.WHITE, 46, 6)
	UIStyle.make_header($TitleBox/Subtitle, UIStyle.AMBER, 15, 4)
	var bg := GlassBackdrop.new()
	add_child(bg)
	move_child(bg, $Vignette.get_index() + 1)  # frost the bg, stay behind title + panel
	for btn in [
		$Panel/VBox/SinglePlayerBtn,
		$Panel/VBox/HostBtn,
		$Panel/VBox/JoinBtn,
		$Panel/VBox/ServersBtn,
		$Panel/VBox/BottomRow/SettingsBtn,
		$Panel/VBox/BottomRow/QuitBtn
	]:
		UIStyle.hover_lift(btn)
	UIStyle.pop_in($Panel)


func _main() -> Node:
	return get_tree().current_scene


func _apply_name() -> void:
	if name_field.text.strip_edges() != "":
		NetworkManager.local_player_name = name_field.text.strip_edges()


func _on_single_player() -> void:
	_apply_name()
	# Route through the Workshop hub (loadout / upgrades / difficulty) → DEPLOY.
	# main.open_workshop() falls back to a direct start if the Workshop is absent.
	if _main().has_method("open_workshop"):
		_main().open_workshop()
	else:
		NetworkManager.start_offline()
		_main().load_arena()


func _on_host() -> void:
	_apply_name()
	var err := NetworkManager.host_game()
	if err == OK:
		status.text = tr("Hosting on port %d — configure your loadout…") % Settings.DEFAULT_PORT
		# Host goes through the Hub (loadout/stash) then DEPLOY; the match begins once
		# every connected peer has deployed (the existing notify_loaded handshake).
		if _main().has_method("open_hub"):
			_main().open_hub("host")
		else:
			_main().load_arena()
	elif err == ERR_CANT_CREATE or err == ERR_ALREADY_IN_USE:
		# Port bind failed — almost always another copy of the game is still running and
		# holding the UDP port (e.g. a previous session that didn't close cleanly).
		status.text = (
			tr("Port %d is busy — close any other running copy of the game and try again.")
			% Settings.DEFAULT_PORT
		)
	else:
		status.text = tr("Host failed: %s") % err


func _on_join() -> void:
	var a := ServerBrowser.parse_addr(ip_field.text)
	_join(String(a["ip"]), int(a["port"]))


## Shared connect path used by the JOIN button AND the server browser. Parses/uses an
## explicit ip+port, wires success (open the client hub + remember the server) and
## FAILURE feedback (previously silent — the menu just hung on "Connecting…").
func _join(ip: String, port: int) -> void:
	_apply_name()
	if ip.strip_edges() == "":
		ip = Settings.DEFAULT_IP
	var err := NetworkManager.join_game(ip, port)
	if err == OK:
		status.text = tr("Connecting to %s:%d…") % [ip, port]
		_pending_ip = ip
		_pending_port = port
		# On connect, the client opens its OWN Hub to pick its loadout; DEPLOY loads the
		# arena + readies it. (Falls back to a direct arena load if no hub exists.)
		multiplayer.connected_to_server.connect(_on_connected_to_host, CONNECT_ONE_SHOT)
		multiplayer.connection_failed.connect(_on_join_failed, CONNECT_ONE_SHOT)
	else:
		status.text = tr("Join failed — check IP/port")


var _pending_ip: String = ""
var _pending_port: int = 0


func _on_connected_to_host() -> void:
	if multiplayer.connection_failed.is_connected(_on_join_failed):
		multiplayer.connection_failed.disconnect(_on_join_failed)
	# Remember this server in the local recents list (MRU).
	ServerBrowser.record_connect(_pending_ip, _pending_port, NetworkManager.local_player_name)
	if _main().has_method("open_hub"):
		_main().open_hub("client")
	else:
		_main().load_arena()


func _on_join_failed() -> void:
	if multiplayer.connected_to_server.is_connected(_on_connected_to_host):
		multiplayer.connected_to_server.disconnect(_on_connected_to_host)
	status.text = tr("Join failed — check IP/port (is the host up?)")


# ---------------------------------------------------------------- server browser
func _on_servers() -> void:
	if _server_browser == null:
		return
	$Panel.hide()
	if _server_browser.has_method("open"):
		_server_browser.open()


func _on_browser_connect(ip: String, port: int) -> void:
	# A server was picked in the browser — close it and run the shared join flow.
	if _server_browser and _server_browser.has_method("close"):
		_server_browser.close()
	$Panel.show()
	_join(ip, port)


func _on_browser_closed() -> void:
	$Panel.show()


func _on_all_ready() -> void:
	status.text = tr("All players ready — match starting!")


# ---------------------------------------------------------------- settings / quit
func _on_settings() -> void:
	$Panel.hide()
	settings_menu.open()


func _on_settings_closed() -> void:
	$Panel.show()


func _on_credits() -> void:
	if _credits != null and _credits.has_method("open"):
		_credits.open()


func _on_quit() -> void:
	get_tree().quit()
