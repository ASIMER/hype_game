extends Node
## Entry point (res://scenes/boot/Main.tscn is the main scene). Parses CLI args
## for headless/dedicated runs, otherwise shows the main menu.
##   --server         start hosting immediately and load the arena (dedicated host)
##   --client <ip>    join the server at <ip> and load the arena on connect.
##                    Mirrors --server for automated two-process testing; <ip>
##                    is optional (defaults to Settings.DEFAULT_IP).
##   --agent          single-player + start the AgentBridge control server and put
##                    the window small/borderless/off-screen/no-focus so Claude can
##                    play and screenshot it without disrupting the desktop.

const MAIN_MENU := preload("res://scenes/boot/MainMenu.tscn")
const ARENA_PATH := "res://scenes/world/Arena.tscn"
const PAUSE_MENU := "res://scenes/ui/PauseMenu.tscn"
const HUB_PATH := "res://scenes/ui/Hub.tscn"
const WORKSHOP_PATH := "res://scenes/ui/Workshop.tscn"   # legacy fallback hub
const RAID_SUMMARY := "res://scenes/ui/RaidSummary.tscn"
const HAUL_MANAGER := "res://scenes/ui/HaulManager.tscn"

@onready var ui_layer: Node = $UILayer
@onready var world_root: Node = $WorldRoot

var _pause_menu: Node = null
var _raid_summary: Node = null
var _paused: bool = false
var _deploy_mode: String = "solo"   # "solo" | "host" | "client" — set when opening the hub

func _ready() -> void:
	# Main + the UI layer keep processing while the tree is paused; the WORLD pauses.
	# This lets the pause/HUD UI stay live without the engine running gameplay.
	process_mode = Node.PROCESS_MODE_ALWAYS
	world_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	Events.match_started.connect(_on_match_started)
	# Accept flags from either the user-args section (after a `--`) or the raw
	# command line so `godot --headless --server` and `godot -- --client <ip>`
	# both work.
	var all_args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if "--server" in all_args:
		_start_dedicated()
	elif "--client" in all_args:
		_start_client(_parse_client_ip(all_args))
	elif "--agent" in all_args:
		_start_agent("--menu" in all_args)
	else:
		_show_menu()

## Pulls the IP that follows `--client` on the command line, falling back to the
## configured default (e.g. for a bare `--client` with no argument).
func _parse_client_ip(args: PackedStringArray) -> String:
	var idx := args.find("--client")
	if idx != -1 and idx + 1 < args.size():
		var candidate := args[idx + 1]
		# Guard against another flag immediately following `--client`.
		if not candidate.begins_with("--"):
			return candidate
	return Settings.DEFAULT_IP

func _show_menu() -> void:
	for c in ui_layer.get_children():
		c.queue_free()
	var menu := MAIN_MENU.instantiate()
	ui_layer.add_child(menu)

func _start_dedicated() -> void:
	NetworkManager.host_game()
	load_arena()

## Pre-run LOBBY/HUB (stash / loadout / workshop / deploy) over the UI layer. DEPLOY
## commits the bring-list and loads the raid; BACK returns to the menu. `mode` is
## "solo" | "host" | "client"; the networking peer is set up at menu time (offline is
## started at deploy for solo). Falls back to the legacy Workshop, then a direct deploy,
## if no hub scene exists yet.
func open_hub(mode: String = "solo") -> void:
	_deploy_mode = mode
	var path := HUB_PATH if ResourceLoader.exists(HUB_PATH) else WORKSHOP_PATH
	if not ResourceLoader.exists(path):
		_on_hub_deploy()
		return
	for c in ui_layer.get_children():
		c.queue_free()
	var hub: Node = (load(path) as PackedScene).instantiate()
	ui_layer.add_child(hub)
	if hub.has_signal("deploy_requested"):
		hub.deploy_requested.connect(_on_hub_deploy)
	if hub.has_signal("back_requested"):
		hub.back_requested.connect(_on_hub_back)

## Back-compat alias used by the main menu's Single Player button + the harness.
func open_workshop() -> void:
	open_hub("solo")

func _on_hub_deploy() -> void:
	for c in ui_layer.get_children():
		c.queue_free()
	if _deploy_mode == "solo" and not NetworkManager.is_offline:
		NetworkManager.start_offline()
	# Fresh raid state (wave/peers) when re-deploying after a prior raid.
	if GameState.is_local_authority_server():
		GameState.reset_match()
	# Commit the bring-list: pull those consumables out of the LOCAL stash (now at risk).
	RaidManager.deploy()
	load_arena()

func _on_hub_back() -> void:
	# Leaving the hub in co-op tears down the connection; solo just returns to the menu.
	if multiplayer.has_multiplayer_peer() and not NetworkManager.is_offline:
		multiplayer.multiplayer_peer = null
		GameState.peers.clear()
		GameState.set_phase(GameState.Phase.MENU)
	_show_menu()

## Self-play mode: boot single-player, open the control server, and park the
## window off-screen without focus so screenshots render but the desktop is undisturbed.
func _start_agent(menu_mode := false) -> void:
	if menu_mode:
		# Show the main menu (for screenshot QA of menus) instead of the arena.
		_show_menu()
	else:
		NetworkManager.start_offline()
		load_arena()
	AgentBridge.activate()
	_park_window_offscreen()

func _park_window_offscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_size(Vector2i(640, 360))
	# Far off any monitor so it never appears in front of the user. Offset each
	# instance by its agent-port slot so multiple windows don't stack (only matters
	# if someone drags them on-screen — off-screen they're invisible regardless).
	var slot: int = Settings.agent_port - Settings.AGENT_PORT
	DisplayServer.window_set_position(Vector2i(-4000 + slot * 700, -4000))

## Dedicated client (mirror of --server): connect to <ip>, then load the arena
## once the ENet handshake completes. Used for automated two-process testing.
func _start_client(ip: String) -> void:
	var err := NetworkManager.join_game(ip)
	if err != OK:
		push_error("--client: join_game(%s) failed: %s" % [ip, err])
		return
	if Settings.NET_DEBUG:
		print("[client] connecting to %s:%d…" % [ip, Settings.DEFAULT_PORT])
	multiplayer.connected_to_server.connect(func() -> void:
		if Settings.NET_DEBUG:
			print("[client] connected to server — loading arena")
		load_arena(), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		push_error("[client] connection to %s failed" % ip), CONNECT_ONE_SHOT)

## Loads the arena under WorldRoot on this peer. Each peer calls this; once the
## scene is ready it tells the server via NetworkManager.notify_loaded().
func load_arena() -> void:
	for c in ui_layer.get_children():
		c.queue_free()
	for c in world_root.get_children():
		c.queue_free()
	var arena: Node = (load(ARENA_PATH) as PackedScene).instantiate()
	world_root.add_child(arena)
	# World-space floating damage numbers (visual only).
	if DisplayServer.get_name() != "headless" and ResourceLoader.exists("res://scenes/fx/DamageNumbersLayer.tscn"):
		world_root.add_child((load("res://scenes/fx/DamageNumbersLayer.tscn") as PackedScene).instantiate())
	# Ambient atmosphere (dust/embers + the day→storm transition on the final wave).
	if DisplayServer.get_name() != "headless" and ResourceLoader.exists("res://scenes/fx/Atmosphere.tscn"):
		world_root.add_child((load("res://scenes/fx/Atmosphere.tscn") as PackedScene).instantiate())
	# Local HUD + inventory overlay (skip on a dedicated headless server).
	if DisplayServer.get_name() != "headless":
		if ResourceLoader.exists("res://scenes/ui/HUD.tscn"):
			var hud: Node = (load("res://scenes/ui/HUD.tscn") as PackedScene).instantiate()
			ui_layer.add_child(hud)
		if ResourceLoader.exists("res://scenes/ui/InventoryUI.tscn"):
			var inv_ui: Node = (load("res://scenes/ui/InventoryUI.tscn") as PackedScene).instantiate()
			ui_layer.add_child(inv_ui)
		# Full-screen map (M) + crosshair hit-marker overlay.
		if ResourceLoader.exists("res://scenes/ui/MapUI.tscn"):
			ui_layer.add_child((load("res://scenes/ui/MapUI.tscn") as PackedScene).instantiate())
		if ResourceLoader.exists("res://scenes/ui/HitMarker.tscn"):
			ui_layer.add_child((load("res://scenes/ui/HitMarker.tscn") as PackedScene).instantiate())
		if ResourceLoader.exists(PAUSE_MENU):
			_pause_menu = (load(PAUSE_MENU) as PackedScene).instantiate()
			ui_layer.add_child(_pause_menu)
			if _pause_menu.has_method("hide_pause"):
				_pause_menu.hide_pause()
			if _pause_menu.has_signal("resume_pressed"):
				_pause_menu.resume_pressed.connect(_resume)
			if _pause_menu.has_signal("quit_to_menu_pressed"):
				_pause_menu.quit_to_menu_pressed.connect(_on_quit_to_menu)
		# Post-raid summary (self-shows on match_won/lost). Continue → back to the Lobby.
		if ResourceLoader.exists(RAID_SUMMARY):
			_raid_summary = (load(RAID_SUMMARY) as PackedScene).instantiate()
			ui_layer.add_child(_raid_summary)
			if _raid_summary.has_signal("continue_requested"):
				_raid_summary.continue_requested.connect(_on_summary_continue)
			if _raid_summary.has_signal("restart_requested"):
				_raid_summary.restart_requested.connect(_on_summary_restart)
		# Manage-Your-Haul overlay (self-shows on Events.haul_overflow when the stash
		# would exceed capacity on deposit).
		if ResourceLoader.exists(HAUL_MANAGER):
			ui_layer.add_child((load(HAUL_MANAGER) as PackedScene).instantiate())
	# Networked: run the load->ready handshake. Offline (incl. the OfflineMultiplayerPeer
	# used by single-player/--agent) has a peer but needs no handshake — start directly.
	if multiplayer.has_multiplayer_peer() and not NetworkManager.is_offline:
		NetworkManager.notify_loaded.rpc_id(1)
	else:
		Events.match_started.emit()

func _on_match_started() -> void:
	GameState.set_phase(GameState.Phase.IN_MATCH)

## Post-raid summary: CONTINUE returns to the Lobby (re-equip / craft / shop / quests
## between raids); RESTART reloads a fresh raid directly.
func _on_summary_continue() -> void:
	_raid_summary = null
	if GameState.is_local_authority_server():
		GameState.reset_match()
	open_hub(_deploy_mode)

func _on_summary_restart() -> void:
	_raid_summary = null
	restart_match()

## Restart on ENTER once the match has ended (won or lost). Reloads the arena with
## fresh state. Single-player / host only (clients would need a server-driven reload).
func _unhandled_input(event: InputEvent) -> void:
	# ESC pauses during a match (inventory consumes ESC first when it's open, so this
	# only fires when the inventory is closed).
	if _pause_menu != null and event.is_action_pressed("ui_cancel") \
			and (GameState.phase == GameState.Phase.IN_MATCH or _paused):
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if GameState.phase != GameState.Phase.RESULTS:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc := (event as InputEventKey).keycode
		if kc == KEY_ENTER or kc == KEY_KP_ENTER:
			restart_match()
			get_viewport().set_input_as_handled()

# ---------------------------------------------------------------- pause
func _toggle_pause() -> void:
	if _paused:
		_resume()
	else:
		_open_pause()

func _open_pause() -> void:
	if _pause_menu == null:
		return
	_paused = true
	# Freeze the world only in single-player; co-op can't pause the shared sim.
	if NetworkManager.is_offline:
		get_tree().paused = true
	_pause_menu.show_pause()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Events.game_paused.emit(true)

func _resume() -> void:
	_paused = false
	get_tree().paused = false
	if _pause_menu and _pause_menu.has_method("hide_pause"):
		_pause_menu.hide_pause()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Events.game_paused.emit(false)

func _on_quit_to_menu() -> void:
	_paused = false
	get_tree().paused = false
	_pause_menu = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	GameState.set_phase(GameState.Phase.MENU)
	for c in world_root.get_children():
		c.queue_free()
	_show_menu()

func restart_match() -> void:
	# Only the offline player or the host may drive a restart.
	if multiplayer.has_multiplayer_peer() and not NetworkManager.is_offline and not multiplayer.is_server():
		return
	GameState.reset_match()
	GameState.set_phase(GameState.Phase.IN_MATCH)
	load_arena()
