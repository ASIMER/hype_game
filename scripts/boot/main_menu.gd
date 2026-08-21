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


## M7.1 hangar backdrop: a live 3D pedestal with YOUR robot (equipped cosmetics)
## slowly turning behind the menu rail. Transparent viewport over the flat dark
## Background; the vignette + panels stay above. Render-only, headless-inert.
func _build_hangar() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var svc := SubViewportContainer.new()
	svc.name = "Hangar"
	svc.stretch = true
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(svc)
	move_child(svc, 1)  # just above the Background ColorRect, below everything else
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_2X
	svc.add_child(vp)
	var world := Node3D.new()
	vp.add_child(world)
	var robot: Node3D = AssetRegistry.get_model("player", MetaProgression.get_cosmetics())
	if robot == null:
		return
	var pivot := Node3D.new()
	world.add_child(pivot)
	pivot.position = Vector3(0.9, 0.0, 0.0)  # right of centre — the rail sits left
	pivot.add_child(robot)
	var tw := pivot.create_tween().set_loops()
	tw.tween_property(pivot, "rotation:y", TAU, 16.0).from(0.0)
	# Plinth disc under the feet.
	var plinth := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.85
	pm.bottom_radius = 0.95
	pm.height = 0.12
	plinth.mesh = pm
	var plm := StandardMaterial3D.new()
	plm.albedo_color = Color(0.12, 0.14, 0.17)
	plm.metallic = 0.6
	plm.roughness = 0.4
	plinth.material_override = plm
	plinth.position = Vector3(0.9, -0.07, 0.0)
	world.add_child(plinth)
	# Key light (warm) + teal rim — the cold-cinematic two-point look.
	var key := SpotLight3D.new()
	key.light_color = Color(1.0, 0.9, 0.75)
	key.light_energy = 5.0
	key.spot_range = 8.0
	key.position = Vector3(2.4, 2.6, 2.2)
	key.look_at_from_position(key.position, Vector3(0.9, 1.0, 0.0), Vector3.UP)
	world.add_child(key)
	var rim := OmniLight3D.new()
	rim.light_color = Color(0.35, 0.75, 0.72)
	rim.light_energy = 2.2
	rim.omni_range = 6.0
	rim.position = Vector3(-0.8, 1.6, -1.8)
	world.add_child(rim)
	var cam := Camera3D.new()
	cam.position = Vector3(0.55, 1.35, 3.1)
	world.add_child(cam)
	cam.look_at(Vector3(0.9, 1.0, 0.0))
	cam.current = true


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Show the real build version (single source of truth) so it never drifts from VERSION.
	if has_node("Version"):
		$Version.text = "v" + Settings.GAME_VERSION
	_build_hangar()
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
	if _credits.has_signal("closed"):
		_credits.closed.connect(func() -> void: _set_shell_visible(true))
	# Overlay visibility → shell sync (covers harness `ui open_*` paths that skip
	# the menu buttons; CanvasLayer + Control both expose visibility_changed).
	for ov: Node in [_server_browser, _credits, settings_menu]:
		if ov != null and ov.has_signal("visibility_changed"):
			ov.visibility_changed.connect(_sync_shell_to_overlays)
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
## AUTO-RETRIES up to JOIN_ATTEMPTS: a big-map host mid-world-build can miss the ENet
## handshake (the documented transient join-timeout quirk) — one manual retry always
## worked, so the menu now does it for the player before surfacing failure.
func _join(ip: String, port: int) -> void:
	_join_attempt = 1
	_join_try(ip, port)


func _join_try(ip: String, port: int) -> void:
	_apply_name()
	if ip.strip_edges() == "":
		ip = Settings.DEFAULT_IP
	var err := NetworkManager.join_game(ip, port)
	if err == OK:
		if _join_attempt == 1:
			status.text = tr("Connecting to %s:%d…") % [ip, port]
		else:
			# gdlint: ignore=max-line-length
			status.text = (
				tr("Connecting to %s:%d… (attempt %d/%d)")
				% [ip, port, _join_attempt, JOIN_ATTEMPTS]
			)
		_pending_ip = ip
		_pending_port = port
		# On connect, the client opens its OWN Hub to pick its loadout; DEPLOY loads the
		# arena + readies it. (Falls back to a direct arena load if no hub exists.)
		multiplayer.connected_to_server.connect(_on_connected_to_host, CONNECT_ONE_SHOT)
		multiplayer.connection_failed.connect(_on_join_failed, CONNECT_ONE_SHOT)
	else:
		status.text = tr("Join failed — check IP/port")


const JOIN_ATTEMPTS := 3
var _join_attempt: int = 0
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
	# Transient (host mid-build) — reset the half-open peer and retry silently.
	if _join_attempt < JOIN_ATTEMPTS:
		_join_attempt += 1
		NetworkManager.disconnect_game()
		_join_try(_pending_ip, _pending_port)
		return
	status.text = tr("Join failed — check IP/port (is the host up?)")


# ---------------------------------------------------------------- server browser
func _on_servers() -> void:
	if _server_browser == null:
		return
	_set_shell_visible(false)
	if _server_browser.has_method("open"):
		_server_browser.open()


## Hides/restores the menu's own chrome (title + panel) while a fullscreen overlay
## (servers / settings / credits) is up — the huge title used to bleed through the
## frosted backdrop and read as overlapping text.
func _set_shell_visible(on: bool) -> void:
	# An overlay may still be up (e.g. harness-opened credits over settings) —
	# never restore the shell while any of them is visible.
	if on and _any_overlay_visible():
		return
	$Panel.visible = on
	if has_node("TitleBox"):
		$TitleBox.visible = on


func _any_overlay_visible() -> bool:
	if _server_browser != null and _server_browser.visible:
		return true
	if _credits != null and bool(_credits.get("visible")):
		return true
	return settings_menu != null and settings_menu.visible


## Overlays can be opened without their menu button (the QA harness calls open()
## directly) — sync the shell off their visibility so EVERY path hides the title.
func _sync_shell_to_overlays() -> void:
	_set_shell_visible(not _any_overlay_visible())


func _on_browser_connect(ip: String, port: int) -> void:
	# A server was picked in the browser — close it and run the shared join flow.
	if _server_browser and _server_browser.has_method("close"):
		_server_browser.close()
	$Panel.show()
	_join(ip, port)


func _on_browser_closed() -> void:
	_set_shell_visible(true)


func _on_all_ready() -> void:
	status.text = tr("All players ready — match starting!")


# ---------------------------------------------------------------- settings / quit
func _on_settings() -> void:
	_set_shell_visible(false)
	settings_menu.open()


func _on_settings_closed() -> void:
	_set_shell_visible(true)


func _on_credits() -> void:
	if _credits != null and _credits.has_method("open"):
		_set_shell_visible(false)
		_credits.open()


func _on_quit() -> void:
	get_tree().quit()
