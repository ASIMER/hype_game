extends Control
## Main menu: Single Player / Host / Join + Settings + Quit. Drives NetworkManager
## and tells Main to load the arena. Settings open an overlaid SettingsMenu instance.

@onready var ip_field: LineEdit = $Panel/VBox/IPField
@onready var name_field: LineEdit = $Panel/VBox/NameField
@onready var status: Label = $Panel/VBox/Status
@onready var settings_menu := $SettingsMenu

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Events.all_players_ready.connect(_on_all_ready)
	$Panel/VBox/SinglePlayerBtn.pressed.connect(_on_single_player)
	$Panel/VBox/HostBtn.pressed.connect(_on_host)
	$Panel/VBox/JoinBtn.pressed.connect(_on_join)
	$Panel/VBox/BottomRow/SettingsBtn.pressed.connect(_on_settings)
	$Panel/VBox/BottomRow/QuitBtn.pressed.connect(_on_quit)
	settings_menu.closed.connect(_on_settings_closed)
	settings_menu.visible = false

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
		status.text = "Hosting on port %d — configure your loadout…" % Settings.DEFAULT_PORT
		# Host goes through the Hub (loadout/stash) then DEPLOY; the match begins once
		# every connected peer has deployed (the existing notify_loaded handshake).
		if _main().has_method("open_hub"):
			_main().open_hub("host")
		else:
			_main().load_arena()
	else:
		status.text = "Host failed: %s" % err

func _on_join() -> void:
	_apply_name()
	var ip := ip_field.text.strip_edges()
	if ip == "":
		ip = Settings.DEFAULT_IP
	var err := NetworkManager.join_game(ip)
	if err == OK:
		status.text = "Connecting to %s…" % ip
		# On connect, the client opens its OWN Hub to pick its loadout; DEPLOY loads the
		# arena + readies it. (Falls back to a direct arena load if no hub exists.)
		multiplayer.connected_to_server.connect(_on_connected_to_host, CONNECT_ONE_SHOT)
	else:
		status.text = "Join failed: %s" % err

func _on_connected_to_host() -> void:
	if _main().has_method("open_hub"):
		_main().open_hub("client")
	else:
		_main().load_arena()

func _on_all_ready() -> void:
	status.text = "All players ready — match starting!"

# ---------------------------------------------------------------- settings / quit
func _on_settings() -> void:
	$Panel.hide()
	settings_menu.open()

func _on_settings_closed() -> void:
	$Panel.show()

func _on_quit() -> void:
	get_tree().quit()
