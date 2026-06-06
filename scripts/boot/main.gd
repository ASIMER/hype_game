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

const STATS_OVERLAY := "res://scenes/ui/StatsOverlay.tscn"
const LOADING_SCREEN := "res://scenes/ui/LoadingScreen.tscn"

@onready var ui_layer: Node = $UILayer
@onready var world_root: Node = $WorldRoot

var _pause_menu: Node = null
var _raid_summary: Node = null
var _paused: bool = false
var _deploy_mode: String = "solo"   # "solo" | "host" | "client" — set when opening the hub
# Persistent overlays (children of Main, NOT ui_layer — they must survive the ui_layer
# wipe on every menu/arena transition): the diagnostics overlay + the loading screen.
var _stats_overlay: Node = null
var _loading: Node = null

func _ready() -> void:
	# Main + the UI layer keep processing while the tree is paused; the WORLD pauses.
	# This lets the pause/HUD UI stay live without the engine running gameplay.
	process_mode = Node.PROCESS_MODE_ALWAYS
	world_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	# Stamp the window title with this instance's identity (worktree branch + ports) so
	# parallel instances are tellable apart in the OS task manager / window list.
	if DisplayServer.get_name() != "headless":
		get_window().title = Settings.window_title()
	_build_persistent_overlays()
	Events.match_started.connect(_on_match_started)
	# Synchronized co-op deploy: the leader's START broadcasts begin_deploy to all
	# peers, and each runs its local deploy here on the same tick.
	Events.begin_deploy.connect(_do_deploy)
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
		# Normal player boot: run the shader/icon prewarm behind the loading screen (visible
		# progress instead of a first-frame hitch), then show the menu. Async fire-and-forget.
		_boot_prewarm_then_menu()

## Boot prewarm → menu (real player launch only; headless/server/agent/client skip it).
func _boot_prewarm_then_menu() -> void:
	if _loading != null and _loading.has_method("prewarm"):
		await _loading.prewarm()
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

## Instance the overlays that must persist across menu↔arena transitions (the ui_layer is
## wiped on each). Both are CanvasLayers so they render regardless of parent. Skipped on a
## headless/dedicated server (no rendering). The StatsOverlay reflects the persisted settings
## immediately; the LoadingScreen drives itself off Events.arena_build_progress.
func _build_persistent_overlays() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if ResourceLoader.exists(STATS_OVERLAY):
		_stats_overlay = (load(STATS_OVERLAY) as PackedScene).instantiate()
		add_child(_stats_overlay)
		if _stats_overlay.has_method("set_config"):
			_stats_overlay.set_config(
				bool(SettingsManager.get_value("show_fps")),
				bool(SettingsManager.get_value("show_detailed_stats")),
				int(SettingsManager.get_value("stats_display_mode")))
	if ResourceLoader.exists(LOADING_SCREEN):
		_loading = (load(LOADING_SCREEN) as PackedScene).instantiate()
		add_child(_loading)

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

## The Hub footer button. Solo deploys immediately; in co-op only the LEADER reaches
## here (clients' button is a READY toggle) and it kicks off the SYNCHRONIZED deploy —
## every peer loads the arena together, players spawn only once all have loaded.
func _on_hub_deploy() -> void:
	if _deploy_mode == "solo":
		if not NetworkManager.is_offline:
			NetworkManager.start_offline()
		GameState.reset_match()
		_do_deploy()
		return
	# Co-op leader: ask the server to start the squad (gated on all members ready).
	# Returns false if not everyone is ready — the button should already be disabled,
	# so just no-op. The actual deploy runs via Events.begin_deploy on every peer.
	if GameState.is_leader():
		NetworkManager.request_start()

## The local deploy step — runs on every peer (solo: directly; co-op: on begin_deploy).
func _do_deploy() -> void:
	for c in ui_layer.get_children():
		c.queue_free()
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
	# Show the loading screen immediately so raid entry shows progress, not a frozen window.
	# (The arena's phased build also drives the bar via Events.arena_build_progress; this just
	# guarantees the screen is up before the first phase emit.)
	if _loading != null and _loading.has_method("show_screen"):
		_loading.show_screen("ENTERING RAID…")
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
	# Renders teammates' shots (tracer/muzzle/impact) from Events.remote_shot so the
	# whole squad sees each other's combat (co-op FX sync).
	if DisplayServer.get_name() != "headless":
		world_root.add_child(RemoteShotFX.new())
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
		# Co-op comms: contextual squad pings (middle-mouse) + the radial comms wheel (Z).
		# Self-bind to the local player/camera; data flows via Events.ping_placed (networked).
		if ResourceLoader.exists("res://scenes/ui/PingSystem.tscn"):
			ui_layer.add_child((load("res://scenes/ui/PingSystem.tscn") as PackedScene).instantiate())
		if ResourceLoader.exists("res://scenes/ui/CommsWheel.tscn"):
			ui_layer.add_child((load("res://scenes/ui/CommsWheel.tscn") as PackedScene).instantiate())
		# Underwater post-processing overlay (blue-green tint + wobble while the LOCAL
		# player wades/submerges in the river). Self-shows on Events.water_state_changed.
		if ResourceLoader.exists("res://scenes/fx/UnderwaterOverlay.tscn"):
			ui_layer.add_child((load("res://scenes/fx/UnderwaterOverlay.tscn") as PackedScene).instantiate())
		# Co-op TAB leaderboard (synced kills) + teammate trade UI. Self-show on their
		# own input/Events; harmless in single-player (the table just shows you).
		if ResourceLoader.exists("res://scenes/ui/Scoreboard.tscn"):
			ui_layer.add_child((load("res://scenes/ui/Scoreboard.tscn") as PackedScene).instantiate())
		if ResourceLoader.exists("res://scenes/ui/TradeUI.tscn"):
			ui_layer.add_child((load("res://scenes/ui/TradeUI.tscn") as PackedScene).instantiate())
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
	# The arena build is now PHASED (an async coroutine). Gate the load→match handshake on
	# the build reporting complete (arena_build_progress == 1.0), so notify_loaded /
	# match_started never fire into a half-built world (players/enemies would otherwise spawn
	# before terrain + navmesh exist). _finish_arena_load runs deferred so the WaveManager
	# (added at the tail of arena._ready) exists before match_started is emitted.
	if not Events.arena_build_progress.is_connected(_on_arena_built):
		Events.arena_build_progress.connect(_on_arena_built)

## Fires for every arena build phase; acts only once the build is complete, then detaches.
func _on_arena_built(frac: float, _label: String) -> void:
	if frac < 1.0:
		return
	Events.arena_build_progress.disconnect(_on_arena_built)
	_finish_arena_load.call_deferred()

## The load→ready handshake, deferred until after arena._ready has fully returned. Offline
## (incl. the OfflineMultiplayerPeer used by single-player/--agent) has a peer but needs no
## handshake — start directly; networked tells the server this peer finished loading.
func _finish_arena_load() -> void:
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
