extends Node
## Self-play control server. INERT unless activate() is called (only from the
## --agent launch path in main.gd), so normal play and netcode are unaffected.
##
## Exposes a newline-delimited JSON protocol over localhost TCP (Settings.AGENT_PORT)
## so an external script (tools/agent/play.py) or MCP wrapper can drive the player,
## read game state, and grab screenshots — letting Claude play and validate the game.
##
## Virtual input: player.gd reads `move`/`sprint`/`fire`/consume_look() from here when
## `active`. Discrete actions (jump/interact/toggle_inventory) are injected as real
## InputEvents via Input.parse_input_event so existing consumers need no changes.

var active: bool = false

# Virtual input state read by player.gd while active.
var move: Vector2 = Vector2.ZERO  # x = strafe right(+)/left(-), y = forward(+)/back(-)
var sprint: bool = false
var fire: bool = false
var ads: bool = false  # aim-down-sights (harness-driven)
var _pending_look: Vector2 = Vector2.ZERO  # dx = yaw (right+), dy = pitch (down+), radians
# Sustained HELD inputs (vs the tap-only `act`): player.gd reads held("crouch"/"interact"/
# "carry"/"jump") in place of Input.is_action_pressed when active. Lets the harness test
# hold-to-crouch / hold-E-revive / hold-F-carry. fire/sprint/ads use their own bools above.
var _held: Dictionary = {}


## PUBLIC: is the harness holding `action`? (player.gd consults this when active.)
func held(action: String) -> bool:
	return bool(_held.get(action, false))


var _server: TCPServer
var _client: StreamPeerTCP
var _rx: String = ""
# A move/fire command holds input for `duration`, replying only when it ends, so the
# client blocks until the action completes (synchronous scripted play).
var _pending: Dictionary = {}  # { deadline_ms, response, clears }

# Cached match feedback (filled from the Events bus).
var _extraction_active: bool = false
var _extraction_ratio: float = 0.0
var _result: String = ""  # "", "won", "lost"
var _weapon_id: String = ""  # cached from Events for state()
var _ammo: int = 0
var _reserve: int = 0
var _reloading: bool = false


func _ready() -> void:
	# Keep serving the control socket even when the tree is paused (for QA of menus).
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)  # stays inert until activate()


func activate() -> void:
	if active:
		return
	active = true
	_server = TCPServer.new()
	var port: int = Settings.agent_port
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("[agent] failed to listen on 127.0.0.1:%d (err %s)" % [port, err])
		active = false
		return
	Events.extraction_progress.connect(
		func(_p, r):
			_extraction_active = true
			_extraction_ratio = r
	)
	Events.extraction_completed.connect(
		func(_p):
			_extraction_active = false
			_extraction_ratio = 1.0
	)
	Events.extraction_cancelled.connect(
		func(_p):
			_extraction_active = false
			_extraction_ratio = 0.0
	)
	Events.match_won.connect(func(): _result = "won")
	Events.match_lost.connect(func(): _result = "lost")
	# A new match (incl. restart) clears cached match-result/extraction state.
	Events.match_started.connect(
		func():
			_result = ""
			_extraction_active = false
			_extraction_ratio = 0.0
	)
	# Cache weapon/ammo for state() assertions (the controller emits these).
	Events.weapon_switched.connect(
		func(id, a, r):
			_weapon_id = id
			_ammo = a
			_reserve = r
	)
	Events.ammo_changed.connect(
		func(a, r):
			_ammo = a
			_reserve = r
	)
	Events.reload_started.connect(func(_id): _reloading = true)
	Events.reload_finished.connect(func(_id): _reloading = false)
	set_process(true)
	print("[agent] control server listening on 127.0.0.1:%d" % port)


## Returns and clears the accumulated look delta (player.gd applies it to the camera).
func consume_look() -> Vector2:
	var v := _pending_look
	_pending_look = Vector2.ZERO
	return v


func _process(_dt: float) -> void:
	if _server == null:
		return
	if _server.is_connection_available():
		_client = _server.take_connection()
		_rx = ""
	if _client == null:
		return
	_client.poll()
	var status := _client.get_status()
	if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
		_client = null
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return

	# Resolve a held move/fire command before accepting anything new.
	if not _pending.is_empty():
		if Time.get_ticks_msec() >= int(_pending["deadline"]):
			match str(_pending.get("clears", "")):
				"move":
					move = Vector2.ZERO
				"fire":
					fire = false
			_send(_pending["response"])
			_pending = {}
		else:
			return

	var avail := _client.get_available_bytes()
	if avail > 0:
		_rx += _client.get_utf8_string(avail)
	while _rx.find("\n") != -1 and _pending.is_empty():
		var idx := _rx.find("\n")
		var line := _rx.substr(0, idx).strip_edges()
		_rx = _rx.substr(idx + 1)
		if line != "":
			_handle_line(line)


func _handle_line(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_send({"ok": false, "error": "malformed json"})
		return
	var json: Dictionary = parsed
	var cmd := str(json.get("cmd", ""))
	match cmd:
		"ping":
			_send({"ok": true, "agent": true})
		"state":
			_send(_snapshot())
		"move":
			move = Vector2(
				clampf(float(json.get("x", 0.0)), -1.0, 1.0),
				clampf(float(json.get("y", 0.0)), -1.0, 1.0)
			)
			_hold(float(json.get("duration", 0.5)), "move")
		"fire":
			fire = true
			_hold(float(json.get("duration", 0.3)), "fire")
		"look":
			_pending_look += Vector2(float(json.get("dx", 0.0)), float(json.get("dy", 0.0)))
			_send({"ok": true})
		"aim":
			# Precisely point the player's camera at a target (engine-side math, exact). target:
			# "nearest"(default) | enemy name | "weakpoint" | "point" (the world x,y,z).
			var atgt := str(json.get("target", "nearest"))
			var aimed := false
			if atgt == "point":
				aimed = _aim_at_point(
					Vector3(
						float(json.get("x", 0.0)),
						float(json.get("y", 0.0)),
						float(json.get("z", 0.0))
					)
				)
			elif atgt == "weakpoint":
				aimed = _aim_weakpoint()
			else:
				aimed = _aim_at(atgt)
			_send({"ok": aimed})
		"sprint":
			sprint = bool(json.get("on", false))
			_send({"ok": true})
		"ads":
			ads = bool(json.get("on", false))
			_send({"ok": true})
		"spawn":
			# Debug: spawn an enemy archetype near the local player for verification.
			# Optional mods: ["armored","swift","volatile","regenerating"] (elite QA).
			var ok := _debug_spawn(
				str(json.get("id", "wasp")),
				float(json.get("dist", 9.0)),
				bool(json.get("hunter", true)),
				json.get("mods", []) if json.get("mods") is Array else []
			)
			_send({"ok": ok})
		"event":
			var ok_ev := _debug_world_event(int(json.get("kind", 0)), bool(json.get("end", false)))
			_send({"ok": ok_ev})
		"tp":
			# Debug: teleport the local player to a world XZ (for reaching far test spots).
			var pl2: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			if pl2 is Node3D:
				(pl2 as Node3D).global_position = Vector3(
					float(json.get("x", 0.0)), float(json.get("y", 1.5)), float(json.get("z", 0.0))
				)
			_send({"ok": pl2 != null})
		"godmode":
			# Debug: toggle local-player invulnerability (for safe verification).
			var pl: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			var hp: Health = pl.get_node_or_null(Groups.NODE_HEALTH) if pl else null
			if hp:
				hp.invulnerable = bool(json.get("on", true))
			_send({"ok": hp != null})
		"refill":
			# Debug: top the local player's weapons back to full ammo (sustained playtests).
			var plr: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			var wc2: Node = (
				plr.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController")
				if plr
				else null
			)
			if wc2 and wc2.has_method("refill_ammo"):
				wc2.refill_ammo()
			_send({"ok": wc2 != null})
		"pickup":
			# Debug/QA: trigger the local player's nearest in-range loot pickup along the
			# REAL runtime path (loot_pickup._request_pickup -> client RPC -> server
			# distance-validation). The harness can't synthesize the "interact" key event
			# that loot_pickup._unhandled_input listens for, so this is how pickup is tested.
			_send(_debug_pickup())
		"render":
			# Debug: render a logical id's model in isolation (clean 3/4 hero shot) and
			# save it as a PNG for visual QA of procedural models + inventory icons.
			var rid := str(json.get("id", ""))
			var rname := str(json.get("name", rid))
			# Optional: render a single cosmetic PART variant (same path the CHARACTER tab
			# thumbnails use) for QA — {render, category, variant, paint, name}.
			var rcat := str(json.get("category", ""))
			var rtex: Texture2D
			if rcat != "":
				rtex = await IconRenderer.render_cosmetic(
					rcat, str(json.get("variant", "")), str(json.get("paint", "paint_raider"))
				)
			else:
				rtex = await IconRenderer.render_now(rid)
			if rtex == null:
				_send({"ok": false, "error": "no texture (headless or unknown id)"})
			else:
				var rdir := (
					"user://agent"
					if Settings.instance_tag == ""
					else "user://agent/%s" % Settings.instance_tag
				)
				DirAccess.make_dir_recursive_absolute(rdir)
				var rpath := "%s/%s.png" % [rdir, rname.validate_filename()]
				var rerr := rtex.get_image().save_png(rpath)
				_send(
					{
						"ok": rerr == OK,
						"path": ProjectSettings.globalize_path(rpath),
						"debug": IconRenderer.last_debug
					}
				)
		"golden":
			# QA: deterministic-world snapshot (terrain heights, water, extraction zones,
			# placement checksums) for refactor verification — tools/lint/check_golden.py.
			_send(GoldenSnapshot.capture(get_tree()))
		"navdbg":
			# QA: NavigationServer visibility (maps/regions/per-enemy agent path state)
			# for diagnosing ground-enemy pathing failures. Read-only.
			_send(NavDebug.capture(get_tree()))
		"glass":
			# QA: breakable windows. No args = registry summary; {break:true, index:N}
			# or {break:true, nearest:true} = server-gated shatter (logic in the class).
			if bool(json.get("break", false)) and GameState.is_local_authority_server():
				var gi: int = int(json.get("index", -1))
				var gpl3: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
				if bool(json.get("nearest", false)) and gpl3 is Node3D:
					gi = BreakableGlass.nearest_unbroken((gpl3 as Node3D).global_position)
				NetworkManager.request_break_glass(gi)
			_send(BreakableGlass.debug_summary())
		"perf":
			# QA: frame-time sampling window for perf A/B ({window: seconds}) — fps,
			# frame_ms p95, script/physics ms, draw calls, node counts, world_children.
			_send(await PerfProbe.capture(get_tree(), float(json.get("window", 1.0))))
		"mutator":
			# QA (batch C): {id:"fog"|"double_loot"|"elite_patrols"|"night_raid"|""} forces
			# the raid mutator for every FOLLOWING deploy AND applies it immediately
			# (fog/elite_patrols react live; double_loot/night_raid need a redeploy).
			# {clear:true} drops the force (next deploy rolls naturally). No args = report.
			if bool(json.get("clear", false)):
				NetworkManager.forced_mutator = null
			elif json.has("id"):
				var mid := str(json.get("id", ""))
				NetworkManager.forced_mutator = mid
				NetworkManager.set_raid_mutator(mid)
			_send(
				{
					"ok": true,
					"mutator": GameState.raid_mutator,
					"forced": NetworkManager.forced_mutator,
				}
			)
		"door":
			# QA (batch C): locked annex doors. {action:"list"} → every door's state;
			# {action:"give_key", id, count} → grant keys to the LOCAL player (its
			# authority copy — replicates); {action:"open", name?} → server force-open
			# without a key (name matches the door OR its annex; omitted = ALL).
			_send(_debug_door(json))
		"gear":
			# QA (batch B): worn armor. {action:"state"} → equipped/durability/insurance;
			# {action:"equip", slot, id} ("" unequips) · {action:"repair", id} ·
			# {action:"drain", id, amount} (test durability/broken without combat).
			_send(AgentGearDebug.gear(json))
		"secure":
			# QA (batch B): the in-raid secure pouch. {id, on:true|false} flags a stack;
			# no args = report {secure}. Owner-routed (works from a co-op client).
			_send(AgentGearDebug.secure(json, get_tree()))
		"status":
			# QA (batch B): status effects on the LOCAL player. {action:"apply"|"clear",
			# effect:"bleed"|"fracture"|"painkiller"} · {action:"list"} · {action:"use",
			# item:"bandage"|"splint"|"painkiller"|"smart"} (consumes like the H key).
			_send(AgentGearDebug.status(json, get_tree()))
		"insure":
			# QA (batch B): insurance. {id} insures an item · {action:"mature"} rewinds
			# every pending return_at to NOW (then the Hub poll claims them) ·
			# {action:"state"} reports current/pending.
			_send(AgentGearDebug.insure(json))
		"clock":
			# Debug: drive the match timer for QA. {action:set, left:<sec>} sets the
			# remaining time; {action:skip} jumps to ~2s left to trigger the final wave.
			var cact := str(json.get("action", "skip"))
			if cact == "set":
				GameState.match_time_left = float(json.get("left", 0.0))
			else:
				GameState.match_time_left = minf(GameState.match_time_left, 2.0)
			_send(
				{"ok": true, "left": GameState.match_time_left, "total": GameState.match_duration}
			)
		"stash":
			# Debug: manipulate the persistent stash + bring-list (raid-economy QA).
			#   {action:add|remove, id, count} · {action:bring, id, count} · {action:clear}
			var act := str(json.get("action", ""))
			var sid := str(json.get("id", ""))
			var cnt := int(json.get("count", 1))
			match act:
				"add":
					Stash.add(sid, cnt)
				"remove":
					Stash.remove(sid, cnt)
				"clear":
					Stash.clear()
				"bring":
					var b: Dictionary = MetaProgression.get_bring()
					if cnt > 0:
						b[sid] = cnt
					else:
						b.erase(sid)
					MetaProgression.set_bring(b)
				"deploy":
					RaidManager.deploy()  # commit the bring-list (remove from stash)
				"craft":
					Crafting.craft(Crafting.recipe_by_id(sid))
				"recycle":
					Crafting.recycle(sid)
				"learn":
					MetaProgression.learn_blueprint(sid)  # simulate buy/quest blueprint
				"claim":
					Quests.claim(sid)
				"give":
					# Add an item to the local player's MATCH inventory (simulate found loot).
					var gpl: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
					var ginv: Node = gpl.get_node_or_null("Inventory") if gpl else null
					var git: ItemData = ItemCatalog.get_item(sid)
					if ginv and git and ginv.has_method("add_item"):
						ginv.add_item(git, cnt)
				"currency":
					MetaProgression.earn(cnt)  # grant currency for QA
				"buy":
					Crafting.buy_blueprint(sid, int(json.get("price", 0)))
				"questprog":  # force quest progress for QA
					MetaProgression.quest_progress[sid] = cnt
					MetaProgression.save_profile()
				"equip":
					MetaProgression.equip_attachment(
						str(json.get("weapon", "")), str(json.get("slot", "")), sid
					)
				"unequip":
					MetaProgression.unequip_attachment(
						str(json.get("weapon", "")), str(json.get("slot", ""))
					)
				"perk":
					MetaProgression.buy_weapon_perk(
						str(json.get("weapon", "")), str(json.get("perk", ""))
					)
				"daily":
					Quests.get_daily_quests()  # trigger daily rotation for QA
			_send(
				{
					"ok": true,
					"stash": Stash.items,
					"bring": MetaProgression.bring,
					"blueprints": MetaProgression.unlocked_blueprints
				}
			)
		"net":
			# Debug: start co-op from an --agent --menu instance so the harness can drive
			# multiplayer + per-player stash tests across instances. action: host | join.
			var nact := str(json.get("action", ""))
			var nsc := get_tree().current_scene
			if nact == "host":
				NetworkManager.host_game()
				if nsc and nsc.has_method("open_hub"):
					nsc.open_hub("host")
				_send({"ok": true})
			elif nact == "join":
				var ip := str(json.get("ip", "127.0.0.1"))
				# Defaults to this instance's net_port (set via --net-port); an explicit
				# "port" lets the harness target a host on a different net_port.
				var jport := int(json.get("port", Settings.net_port))
				var jerr := NetworkManager.join_game(ip, jport)
				if (
					jerr == OK
					and not multiplayer.connected_to_server.is_connected(_agent_open_client_hub)
				):
					multiplayer.connected_to_server.connect(
						_agent_open_client_hub, CONNECT_ONE_SHOT
					)
				_send({"ok": jerr == OK})
			else:
				_send({"ok": false, "error": "net action host|join"})
		"deploy":
			# Debug: trigger the hub DEPLOY/START (solo or co-op leader synchronized start).
			var dsc := get_tree().current_scene
			if dsc and dsc.has_method("_on_hub_deploy"):
				dsc._on_hub_deploy()
			_send({"ok": dsc != null})
		"ready":
			# Debug: a co-op CLIENT readies/unreadies in the lobby (set_ready RPC to host).
			var rdy := bool(json.get("on", true))
			NetworkManager.set_ready.rpc_id(1, rdy)
			_send({"ok": true, "ready": rdy})
		"transfer":
			# Debug: co-op item give — move {id,count} from {from} peer to {to} peer.
			# Defaults `from` to this instance's peer id (give MY item to a teammate).
			var tfrom := int(json.get("from", GameState.local_peer_id()))
			var tto := int(json.get("to", 1))
			var tid := str(json.get("id", ""))
			var tcnt := int(json.get("count", 1))
			var moved := NetworkManager.transfer_item(tfrom, tto, tid, tcnt)
			_send({"ok": true, "moved": moved})
		"favorites":
			# Debug: drive the local server list (browser QA). action: add|remove|list|connect.
			var fact := str(json.get("action", "list"))
			var fip := str(json.get("ip", ""))
			var fport := int(json.get("port", Settings.net_port))
			var fname := str(json.get("name", ""))
			match fact:
				"add":
					ServerBrowser.add_favorite(fname, fip, fport)
				"remove":
					ServerBrowser.remove_favorite(fip, fport)
				"connect":
					ServerBrowser.record_connect(fip, fport, fname)
			_send(
				{
					"ok": true,
					"favorites": ServerBrowser.get_favorites(),
					"recents": ServerBrowser.get_recents()
				}
			)
		"discover":
			# Debug: trigger a LAN scan; results land in ServerBrowser.last_found (read via
			# `state.lan` after ~timeout). Returns immediately.
			var dto := float(json.get("timeout", 1.5))
			ServerBrowser.scan_lan(dto)
			_send({"ok": true, "scanning": true, "timeout": dto})
		"meshes":
			# Debug forensics: list every visible MeshInstance3D under the arena's
			# NavigationRegion3D (and its top children) with world Y-range + material hint —
			# for hunting mystery surfaces that cover the terrain.
			var sc_root := get_tree().current_scene
			var out: Array = []
			if sc_root:
				_collect_meshes(sc_root, out, 0)
			_send({"ok": true, "meshes": out})
		"hide":
			# Debug forensics: toggle visibility of a node by absolute path substring match
			# under the current scene. {path:"TerrainMesh", on:false} hides it.
			var hpat := str(json.get("path", ""))
			var hon := bool(json.get("on", false))
			var hits: Array = []
			_hide_matching(get_tree().current_scene, hpat, hon, hits)
			_send({"ok": true, "matched": hits})
		"probe":
			# Debug: raycast straight down at world {x,z} → ground height + collider name.
			# The terrain QA tool: placement checks + cross-instance DETERMINISM proof
			# (every co-op peer must generate byte-identical terrain collision).
			var px := float(json.get("x", 0.0))
			var pz := float(json.get("z", 0.0))
			var vp := get_viewport()
			if vp == null or vp.world_3d == null:
				_send({"ok": false, "error": "no world"})
			else:
				var pq := PhysicsRayQueryParameters3D.create(
					Vector3(px, 100.0, pz), Vector3(px, -50.0, pz)
				)
				pq.collision_mask = 1
				var phit := vp.world_3d.direct_space_state.intersect_ray(pq)
				if phit:
					var pcol: Object = phit.get("collider")
					var pname: String = pcol.name if pcol is Node else "?"
					var ppos: Vector3 = phit.get("position")
					_send({"ok": true, "y": ppos.y, "collider": pname})
				else:
					_send({"ok": true, "y": null, "collider": ""})
		"ui":
			# Debug: open/close menus for screenshot verification.
			_send({"ok": _ui_action(str(json.get("action", "")))})
		"setting":
			# Debug: get/set a SettingsManager value (verify apply + persist).
			# graphics_quality routes through apply_quality_preset so the WHOLE lever
			# bundle lands (one-click semantics — same path as the menu dropdown);
			# a bare set_value would only change the label and leave the matrix stale.
			var skey := str(json.get("key", ""))
			if json.has("value"):
				if skey == "graphics_quality":
					SettingsManager.apply_quality_preset(int(json.get("value")))
				else:
					SettingsManager.set_value(skey, json.get("value"))
			_send({"ok": true, "value": SettingsManager.get_value(skey)})
		"goto":
			# Face a world XZ point and walk forward toward it for `duration`.
			_face_point(Vector2(float(json.get("x", 0.0)), float(json.get("z", 0.0))))
			move = Vector2(0.0, 1.0)
			_hold(float(json.get("duration", 0.5)), "move")
		"act":
			_do_action(str(json.get("action", "")))
			_send({"ok": true})
		"hold":
			# Sustained input hold (crouch/interact/carry/jump -> _held; fire/sprint/ads ->
			# their own bools). The counterpart to tap-only `act`.
			var hact := str(json.get("action", ""))
			var hon := bool(json.get("on", true))
			match hact:
				"fire":
					fire = hon
				"sprint":
					sprint = hon
				"ads":
					ads = hon
				_:
					_held[hact] = hon
			_send({"ok": true})
		"noise":
			# QA: inject an AI-audible noise at the player ({loudness, kind}) — isolates
			# the noise->INVESTIGATE plumbing from weapon/grenade emission paths.
			var npl: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			if npl is Node3D:
				NetworkManager.report_noise(
					(npl as Node3D).global_position,
					float(json.get("loudness", Settings.NOISE_GRENADE)),
					int(json.get("kind", 2))
				)
			_send({"ok": npl != null})
		"grenade":
			# QA: select a grenade type and throw it ({type:"frag|smoke|emp|decoy"}).
			# Grants 1 if the player carries none (so recipes don't need stash setup).
			_send(_debug_grenade(str(json.get("type", "frag"))))
		"gadget":
			# QA: force-place a deployable ({type:"gadget_turret|gadget_dome|gadget_sensor"})
			# at the player's feet-forward point, bypassing the carried count.
			_send(_debug_gadget(str(json.get("type", "gadget_turret"))))
		"down":
			# Debug: force the local player DOWNED (on:true) or revive it (on:false).
			_send(_debug_down(bool(json.get("on", true))))
		"hurt":
			# Debug: damage self / nearest / a named enemy (weak:true -> weak-point multiplier).
			_send(
				_debug_hurt(
					str(json.get("target", "nearest")),
					float(json.get("amount", 9999.0)),
					bool(json.get("weak", false))
				)
			)
		"kill":
			_send(_debug_hurt(str(json.get("target", "nearest")), 1.0e9, false))
		"heal":
			var hpl := _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			var hhp: Health = hpl.get_node_or_null(Groups.NODE_HEALTH) if hpl else null
			if hhp:
				hhp.heal(float(json.get("amount", 9999.0)))
			_send({"ok": hhp != null, "health": hhp.current if hhp else 0.0})
		"sethp":
			var spl := _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			var shp: Health = spl.get_node_or_null(Groups.NODE_HEALTH) if spl else null
			if shp:
				shp.current = clampf(float(json.get("value", shp.current)), 0.0, shp.max_health)
				shp.health_changed.emit(shp.current, shp.max_health)
			_send({"ok": shp != null, "health": shp.current if shp else 0.0})
		"prog":
			_send(_debug_prog(json))
		"cosmetic":
			# Debug character customization: {action:equip|buy|grant, id} or {action:get}.
			# grant = unlock free (QA); buy = unlock spending currency; equip = set equipped.
			var cact := str(json.get("action", "get"))
			var cid := str(json.get("id", ""))
			match cact:
				"grant":
					if cid != "" and not (cid in MetaProgression.unlocked_cosmetics):
						MetaProgression.unlocked_cosmetics.append(cid)
						MetaProgression.save_profile()
				"buy":
					MetaProgression.unlock_cosmetic(cid)
				"equip":
					MetaProgression.set_equipped_cosmetic(cid)
			_send(
				{
					"ok": true,
					"equipped": MetaProgression.get_cosmetics(),
					"currency": MetaProgression.currency
				}
			)
		"crosshair":
			_send(_debug_crosshair())
		"power":
			# QA: drive power caches. {action:"open"} plays the full reveal→buff on the local
			# player; {action:"grant", id:"berserk"} applies a buff instantly (skip the reveal);
			# {action:"unlock", id} unlocks a power for skill points; {action:"list"}.
			_send(_debug_power(json))
		"upgrade":
			# QA: set a permanent credit-upgrade level without grinding to verify it changes a
			# stat. {key:"player_health", level:5}. Restart the match for it to apply at spawn.
			var ukey := str(json.get("key", ""))
			if MetaProgression.UPGRADES.has(ukey):
				MetaProgression.upgrades[ukey] = int(json.get("level", 0))
				_send({"ok": true, "key": ukey, "level": int(json.get("level", 0))})
			else:
				_send(
					{
						"ok": false,
						"error": "unknown upgrade",
						"keys": MetaProgression.UPGRADES.keys()
					}
				)
		"screenshot":
			_screenshot(str(json.get("name", "shot")))  # replies asynchronously
		"restart":
			# Reload the match (used to reset between play-test scenarios).
			var main := get_tree().current_scene
			if main and main.has_method("restart_match"):
				main.restart_match()
			_send({"ok": true})
		"quest":
			# QA: inspect + drive the quest lifecycle without grinding.
			# {quest, action:"state"|"offer"|"accept"|"claim"|"stats"|"grantkills"|"evaluate", id?, eid?, n?}
			_send(AgentQuestDebug.handle(json, get_tree()))
		"summary":
			# QA: drive the post-raid RaidSummary buttons ({action:"continue"|"restart"}).
			var m := get_tree().current_scene
			var sact := str(json.get("action", "continue"))
			var ok := false
			if m and sact == "continue" and m.has_method("_on_summary_continue"):
				m.call("_on_summary_continue")
				ok = true
			elif m and sact == "restart" and m.has_method("_on_summary_restart"):
				m.call("_on_summary_restart")
				ok = true
			_send({"ok": ok})
		"quit":
			_send({"ok": true})
			get_tree().quit()
		_:
			_send({"ok": false, "error": "unknown cmd '%s'" % cmd})


func _hold(duration: float, clears: String) -> void:
	_pending = {
		"deadline": Time.get_ticks_msec() + int(maxf(0.0, duration) * 1000.0),
		"response": {"ok": true},
		"clears": clears,
	}


## Points the local player's camera straight at an enemy's torso. Iterates a few
## times because the camera orbits the pivot (changing the yaw moves the camera
## position), so position and aim direction must converge together. After this the
## screen-center crosshair is on the target, so Weapon.try_fire connects.
func _aim_at(target_name: String) -> bool:
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	var enemy: Node3D = _pick_enemy(p, target_name)
	if enemy == null:
		return false
	# Body CENTRE — inside every archetype's hitbox, ground or air.
	return _aim_at_point(enemy.global_position)


## Aim at the nearest enemy's WeakPoint sphere (headshot line-up for weak-point QA).
func _aim_weakpoint() -> bool:
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	var enemy: Node3D = _pick_enemy(p, "nearest")
	if enemy == null:
		return false
	var wp := enemy.get_node_or_null("WeakPoint/CollisionShape3D")
	var pt: Vector3 = (wp as Node3D).global_position if wp is Node3D else enemy.global_position
	return _aim_at_point(pt)


## Converge the player camera so its forward ray lands on `aimp` (the weapon's two-stage
## shot then sends bullets to that crosshair point). Iterates because the camera orbits
## the pivot — moving the yaw moves the camera, so position + aim must converge together.
func _aim_at_point(aimp: Vector3) -> bool:
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if p == null:
		return false
	var pivot: Node3D = p.get_node_or_null("CameraPivot")
	var spring: Node3D = p.get_node_or_null("CameraPivot/SpringArm3D")
	var cam: Node3D = p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
	if pivot == null or spring == null or cam == null:
		return false
	var origin: Vector3 = pivot.global_position
	for _i in 3:
		var to := (aimp - origin).normalized()
		(p as Node3D).rotation.y = atan2(-to.x, -to.z)
		pivot.rotation.y = 0.0
		var flat := Vector2(to.x, to.z).length()
		spring.rotation.x = clampf(
			atan2(to.y, flat), Settings.CAMERA_PITCH_MIN, Settings.CAMERA_PITCH_MAX
		)
		(p as Node3D).force_update_transform()
		pivot.force_update_transform()
		spring.force_update_transform()
		cam.force_update_transform()
		origin = cam.global_position
	return true


## Faces the player body (and camera) toward a world XZ point — used by `goto` so
## forward movement heads straight at loot / the extraction zone.
func _face_point(target_xz: Vector2) -> void:
	var players := get_tree().get_nodes_in_group(Groups.PLAYERS)
	var p: Node = _local_player(players)
	if p == null or not (p is Node3D):
		return
	var pivot: Node3D = p.get_node_or_null("CameraPivot")
	var pos: Vector3 = (p as Node3D).global_position
	var to := Vector3(target_xz.x - pos.x, 0.0, target_xz.y - pos.z)
	if to.length() < 0.05:
		return
	to = to.normalized()
	(p as Node3D).rotation.y = atan2(-to.x, -to.z)
	if pivot:
		pivot.rotation.y = 0.0
	(p as Node3D).force_update_transform()


func _pick_enemy(p: Node, target_name: String) -> Node3D:
	var enemies := get_tree().get_nodes_in_group(Groups.ENEMIES)
	if enemies.is_empty():
		return null
	if target_name != "" and target_name != "nearest":
		for e in enemies:
			if str(e.name) == target_name:
				return e as Node3D
	var best: Node3D = null
	var best_d := INF
	var origin: Vector3 = (p as Node3D).global_position if p is Node3D else Vector3.ZERO
	for e in enemies:
		var d: float = origin.distance_to((e as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = e
	return best


## Debug: down (on:true) or revive (on:false) the local player deterministically.
func _debug_down(on: bool) -> Dictionary:
	if not GameState.is_local_authority_server():
		return {"ok": false, "error": "server-auth only"}
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if p == null:
		return {"ok": false, "error": "no player"}
	if on:
		if p.has_method("_enter_downed"):
			p._enter_downed(null)
	else:
		if p.has_method("_apply_revive"):
			p._apply_revive()
		elif p.has_method("server_revive"):
			p.server_revive(p)
	return {"ok": true, "downed": p.is_downed() if p.has_method("is_downed") else false}


## Debug: deal damage to self / nearest / a named enemy. weak:true routes through the
## enemy's WeakPoint Hurtbox so the damage_multiplier applies (weak-point QA).
func _debug_hurt(target: String, amount: float, weak: bool) -> Dictionary:
	if not GameState.is_local_authority_server():
		return {"ok": false, "error": "server-auth only"}
	var me: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	var node: Node = me if target == "self" else _pick_enemy(me, target)
	if node == null:
		return {"ok": false, "error": "no target"}
	if weak and target != "self":
		var wp := node.get_node_or_null(Groups.NODE_WEAKPOINT)
		if wp and wp.has_method("apply_hit"):
			wp.apply_hit(amount, me)
			var whp: Health = node.get_node_or_null(Groups.NODE_HEALTH)
			return {
				"ok": true,
				"target": str(node.name),
				"weak": true,
				"health": whp.current if whp else 0.0
			}
	var hp: Health = node.get_node_or_null(Groups.NODE_HEALTH)
	if hp == null:
		return {"ok": false, "error": "no Health on target"}
	hp.take_damage(amount, me)
	return {"ok": true, "target": str(node.name), "weak": false, "health": hp.current}


## QA driver for the locked annex doors (batch C) — see the "door" command.
func _debug_door(json: Dictionary) -> Dictionary:
	var action := str(json.get("action", "list"))
	match action:
		"give_key":
			var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
			if p == null or not ("_keys" in p):
				return {"ok": false, "error": "no player"}
			var kid := str(json.get("id", "key_tower"))
			var keys: Dictionary = p.get("_keys")
			keys[kid] = int(keys.get(kid, 0)) + int(json.get("count", 1))
			p.set("_keys", keys)
			return {"ok": true, "keys": keys}
		"open":
			var which := str(json.get("name", ""))
			var opened: Array = []
			for d in get_tree().get_nodes_in_group(Groups.LOCKED_DOORS):
				if which != "" and not _door_matches(d, which):
					continue
				if d.has_method("debug_force_open"):
					d.call("debug_force_open")
					opened.append(_door_entry(d))
			return {"ok": true, "opened": opened}
		_:
			var doors: Array = []
			for d in get_tree().get_nodes_in_group(Groups.LOCKED_DOORS):
				doors.append(_door_entry(d))
			return {"ok": true, "doors": doors}


func _door_matches(d: Node, which: String) -> bool:
	if String(d.name).contains(which):
		return true
	var par := d.get_parent()
	return par != null and String(par.name).contains(which)


func _door_entry(d: Node) -> Dictionary:
	var pos: Vector3 = (d as Node3D).global_position if d is Node3D else Vector3.ZERO
	return {
		"name": String(d.name),
		"annex": String(d.get_parent().name) if d.get_parent() != null else "",
		"key": str(d.call("key_id")) if d.has_method("key_id") else "",
		"opened": bool(d.get("opened")),
		"pos": _v3(pos),
	}


## Debug: drive MetaProgression / Progression directly (jump XP/level/rep/mastery/skills
## to test milestones + bonuses without grinding). Per-peer LOCAL (runs on THIS instance).
func _debug_prog(json: Dictionary) -> Dictionary:
	var a := str(json.get("action", ""))
	match a:
		"add_xp":
			MetaProgression.add_xp(int(json.get("amount", 0)), "debug")
		"set_xp":
			MetaProgression.xp = 0
			MetaProgression.raider_level = 1
			MetaProgression.add_xp(int(json.get("value", 0)), "debug")
		"set_level":
			MetaProgression.raider_level = maxi(1, int(json.get("value", 1)))
			MetaProgression._apply_milestones()
			MetaProgression.save_profile()
		"add_rep":
			MetaProgression.grant_rep(int(json.get("amount", 0)))
		"set_rep":
			MetaProgression.vendor_rep = int(json.get("value", 0))
			MetaProgression.save_profile()
		"add_mastery":
			MetaProgression.add_weapon_mastery(
				str(json.get("weapon", "")), int(json.get("amount", 0))
			)
		"set_mastery":
			var wm: Dictionary = MetaProgression.weapon_mastery
			wm[str(json.get("weapon", ""))] = {"xp": 0, "level": int(json.get("level", 0))}
			MetaProgression.weapon_mastery = wm
			MetaProgression.save_profile()
		"skill_points":
			MetaProgression.skill_points = int(json.get("value", 0))
			MetaProgression.save_profile()
		"buy_skill":
			MetaProgression.buy_skill(str(json.get("key", "")))
		"credit_kill":
			Progression.credit_kill()
	return {
		"ok": true,
		"meta":
		{
			"xp": MetaProgression.xp,
			"raider_level": MetaProgression.raider_level,
			"skill_points": MetaProgression.skill_points,
			"vendor_rep": MetaProgression.vendor_rep,
			"rep_tier": MetaProgression.rep_tier(),
			"weapon_mastery": MetaProgression.weapon_mastery
		}
	}


## Debug: raycast from the camera forward and report what the crosshair is on — entity,
## whether the ray lines up on the enemy's weak-point sphere, distance. Verify aim before firing.
func _debug_power(json: Dictionary) -> Dictionary:
	var action := str(json.get("action", "list"))
	if action == "list":
		return {
			"ok": true,
			"available": MetaProgression.available_powers(),
			"all": Settings.POWERS.keys()
		}
	if action == "unlock":
		var ok := MetaProgression.unlock_power(str(json.get("id", "")))
		return {"ok": ok, "available": MetaProgression.available_powers()}
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if p == null:
		return {"ok": false, "error": "no player"}
	match action:
		"open":
			if p.has_method("begin_power_open"):
				p.begin_power_open()
				return {"ok": true}
			return {"ok": false, "error": "no begin_power_open"}
		"grant":
			var id := str(json.get("id", "berserk"))
			if p.has_method("apply_power"):
				p.apply_power(id)
				return {"ok": true, "id": id}
			return {"ok": false, "error": "no apply_power"}
		"clear":
			# QA: wipe active buffs so each can be measured in isolation.
			p.set("_buffs", {})
			p.set("_overshield", 0.0)
			return {"ok": true}
	return {"ok": false, "error": "unknown action"}


# The crosshair report is refreshed from _physics_process (space-state queries are
# only thread-safe inside the physics step — physics/3d/run_on_separate_thread);
# the verb + state assembly read this cache (≤1 physics frame stale, fine for QA).
var _crosshair_cache: Dictionary = {"ok": false, "error": "not ready"}


func _physics_process(_delta: float) -> void:
	if not active:
		return
	_crosshair_cache = _crosshair_raycast()


func _debug_crosshair() -> Dictionary:
	return _crosshair_cache


func _crosshair_raycast() -> Dictionary:
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	var cam: Camera3D = p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") if p else null
	if cam == null:
		return {"ok": false, "error": "no camera"}
	var from: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	var vp := get_viewport()
	if vp == null or vp.world_3d == null:
		return {"ok": false, "error": "no world"}
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 300.0)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	# Exclude ALL of the player's own collision objects (body + Hurtbox + any view-model)
	# so the ray reports the enemy/world under the reticle, not our own gun at point-blank.
	var excl: Array[RID] = []
	_collect_collision_rids(p, excl)
	q.exclude = excl
	var hit := vp.world_3d.direct_space_state.intersect_ray(q)
	if not hit:
		return {"ok": true, "hit": false}
	var col: Object = hit.get("collider")
	var entity := ""
	var eid := ""
	var enemy_node: Node = null
	var n: Node = col as Node
	while n != null:
		if n.is_in_group(Groups.ENEMIES):
			enemy_node = n
			entity = str(n.name)
			eid = str(n.get("enemy_id")) if "enemy_id" in n else ""
			break
		if n.is_in_group(Groups.PLAYERS):
			entity = str(n.name)
			break
		n = n.get_parent()
	var is_weak := false
	if enemy_node:
		var wps := enemy_node.get_node_or_null("WeakPoint/CollisionShape3D")
		if wps is CollisionShape3D and (wps as CollisionShape3D).shape is SphereShape3D:
			var c: Vector3 = (wps as Node3D).global_position
			var r: float = ((wps as CollisionShape3D).shape as SphereShape3D).radius
			var t: float = maxf(0.0, (c - from).dot(dir))
			is_weak = (from + dir * t).distance_to(c) <= r + 0.05
	var point: Vector3 = hit.get("position")
	return {
		"ok": true,
		"hit": true,
		"entity": entity,
		"enemy_id": eid,
		"is_weakpoint": is_weak,
		"point": _v3(point),
		"dist": from.distance_to(point)
	}


## Debug: instance an enemy archetype in front of the local player (for verifying
## the new types). Server-authoritative; reuses the wave enemy container. `mods`
## forces elite-modifier prefixes via the same name-encode channel waves use.
func _debug_spawn(eid: String, dist: float, as_hunter: bool = true, mods: Array = []) -> bool:
	if not GameState.is_local_authority_server():
		return false
	var scene_map := {
		"grunt": "res://scenes/enemies/RobotEnemy.tscn",
		"tick": "res://scenes/enemies/RobotTick.tscn",
		"heavy": "res://scenes/enemies/RobotHeavy.tscn",
		"wasp": "res://scenes/enemies/RobotWasp.tscn",
		"bastion": "res://scenes/enemies/RobotBastion.tscn",
		"boss": "res://scenes/enemies/RobotBoss.tscn",
		"caller": "res://scenes/enemies/RobotCaller.tscn",
		"elite": "res://scenes/enemies/RobotElite.tscn",
		# Biome fauna (v0.3): desert / snow / rain rosters.
		"worm": "res://scenes/enemies/RobotSandworm.tscn",
		"scarab": "res://scenes/enemies/RobotScarab.tscn",
		"dustdevil": "res://scenes/enemies/RobotDustdevil.tscn",
		"frosthound": "res://scenes/enemies/RobotFrosthound.tscn",
		"cryomortar": "res://scenes/enemies/RobotCryomortar.tscn",
		"avalanche": "res://scenes/enemies/RobotAvalanche.tscn",
		"oni": "res://scenes/enemies/RobotOni.tscn",
		"kappa": "res://scenes/enemies/RobotKappa.tscn",
		"raiju": "res://scenes/enemies/RobotRaiju.tscn",
		# Batch D: biome minibosses + the recon drone.
		"snowgolem": "res://scenes/enemies/RobotSnowGolem.tscn",
		"dunewarden": "res://scenes/enemies/RobotDuneWarden.tscn",
		"onichief": "res://scenes/enemies/RobotOniChief.tscn",
		"specter": "res://scenes/enemies/RobotSpecter.tscn",
	}
	var path: String = scene_map.get(eid, "")
	if path == "" or not ResourceLoader.exists(path):
		return false
	# Resolve the replicated enemy container from the ARENA first — deriving it from
	# "any live enemy's parent" fails on a fully swept field (QA kill-sweeps), which
	# made the FIRST debug spawn after a sweep silently no-op.
	var container: Node = null
	var arena_node: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	if arena_node != null:
		container = arena_node.get_node_or_null("Net/Enemies")
	if container == null:
		for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
			if is_instance_valid(e):
				container = e.get_parent()
				break
	var p: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if container == null or p == null or not (p is Node3D):
		return false
	var enemy: Node = (load(path) as PackedScene).instantiate()
	if "hunter" in enemy:
		enemy.hunter = as_hunter
	# Forced elite modifiers: encode prefix letters into the node name (the same
	# replication channel the wave roll uses; robot_enemy parses it in _ready).
	if not mods.is_empty():
		var flags := ""
		var letter := {"armored": "A", "swift": "S", "volatile": "V", "regenerating": "R"}
		for m in mods:
			flags += String(letter.get(String(m), ""))
		if flags != "":
			enemy.name = "%s_mod%s" % [enemy.name, flags]
	container.add_child(enemy, true)
	var fwd := -(p as Node3D).global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	var spot: Vector3 = (p as Node3D).global_position + fwd.normalized() * dist
	# Snap Y to the TERRAIN at the target XZ — the player's own Y is wrong on slopes
	# (an offset spawn ended inside a dune / in the air and fell through the world,
	# leaving 'ghost' enemies kilometres below that polluted every QA state dump).
	spot.y = ProceduralTerrain.height_at(spot.x, spot.z) + 0.5
	(enemy as Node3D).global_position = spot
	return true


## Debug: force a world event NOW via the WorldEventDirector (QA for Batch 3).
## kind: 0 supply_cache, 1 miniboss, 2 contested_poi, 3 surge. Calls the director's
## per-kind starter directly (underscore = convention, callable). Returns false if the
## director isn't present/idle or the match isn't running.
func _debug_world_event(kind: int, want_end: bool = false) -> bool:
	if not GameState.is_local_authority_server():
		return false
	var d: Node = get_node_or_null("/root/WorldEventDirector")
	if d == null:
		return false
	if want_end:
		# End whatever event is active (by its _active_kind), via the matching _end_* method.
		var ak: int = int(d.get("_active_kind")) if "_active_kind" in d else -1
		var ender: String = (
			{
				0: "_end_supply_cache_timeout",
				1: "_end_miniboss",
				2: "_end_contested_poi",
				3: "_end_surge",
				4: "_end_siege_timeout",
			}
			. get(ak, "")
		)
		if ender == "" or not d.has_method(ender):
			return false
		if ak == 0 or ak == 4:
			d.call(ender)
		else:
			d.call(ender, true)
		return true
	var starter: String = (
		{
			0: "_start_supply_cache",
			1: "_start_miniboss",
			2: "_start_contested_poi",
			3: "_start_surge",
			4: "_start_siege",
		}
		. get(kind, "")
	)
	if starter == "" or not d.has_method(starter):
		return false
	d.call(starter)
	return true


## Client-side: once connected to the host, open this peer's own Hub (loadout/stash).
func _agent_open_client_hub() -> void:
	var sc := get_tree().current_scene
	if sc and sc.has_method("open_hub"):
		sc.open_hub("client")


## Debug: open/close menu overlays so the harness can screenshot them.
## Recursive helper for the `meshes` forensics cmd: big visible meshes only (XZ > 20 m),
## including MultiMeshInstance3D (whose AABB spans all instances).
func _collect_meshes(node: Node, out: Array, depth: int) -> void:
	if depth > 8 or out.size() > 80:
		return
	if (
		(node is MeshInstance3D or node is MultiMeshInstance3D)
		and (node as GeometryInstance3D).visible
	):
		var mi := node as GeometryInstance3D
		var aabb := mi.get_aabb()
		var gx := mi.global_transform * aabb
		if gx.size.x > 20.0 and gx.size.z > 20.0:
			var mat_hint := "none"
			if mi.material_override != null:
				mat_hint = "override:" + mi.material_override.get_class()
				if mi.material_override is BaseMaterial3D:
					var c: Color = (mi.material_override as BaseMaterial3D).albedo_color
					mat_hint += (
						" albedo=(%.2f,%.2f,%.2f) tex=%s"
						% [
							c.r,
							c.g,
							c.b,
							str((mi.material_override as BaseMaterial3D).albedo_texture != null)
						]
					)
			out.append(
				{
					"path": str(mi.get_path()).right(80),
					"y0": gx.position.y,
					"y1": gx.position.y + gx.size.y,
					"sx": gx.size.x,
					"sz": gx.size.z,
					"mat": mat_hint
				}
			)
	for c in node.get_children():
		_collect_meshes(c, out, depth + 1)


func _hide_matching(node: Node, pat: String, on: bool, hits: Array) -> void:
	if hits.size() > 20 or pat == "":
		return
	if node is Node3D and pat in node.name:
		(node as Node3D).visible = on
		hits.append(str(node.get_path()).right(60))
	for c in node.get_children():
		_hide_matching(c, pat, on, hits)


func _ui_action(action: String) -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	match action:
		"open_settings":
			var sm := scene.find_child("SettingsMenu", true, false)
			if sm and sm.has_method("open"):
				sm.open()
				return true
		"open_servers", "close_servers":
			# Show/hide the main-menu server browser overlay (screenshot QA).
			var sb := scene.find_child("ServerBrowser", true, false)
			if sb and sb.has_method("open"):
				if action == "open_servers":
					sb.open()
				else:
					sb.close()
				return true
		"close_settings":
			var sm := scene.find_child("SettingsMenu", true, false)
			if sm and sm.has_method("close"):
				sm.close()
				return true
		"open_pause":
			var pm := scene.find_child("PauseMenu", true, false)
			if pm and pm.has_method("show_pause"):
				pm.show_pause()
				return true
		"close_pause":
			var pm := scene.find_child("PauseMenu", true, false)
			if pm and pm.has_method("hide_pause"):
				pm.hide_pause()
				return true
		"open_workshop":
			# Show the pre-run Workshop hub over the UI layer (for screenshot QA).
			if scene.has_method("open_workshop"):
				scene.open_workshop()
				return true
		"open_map", "close_map":
			# Toggle the in-raid full map (M). MapUI listens to Events.map_toggled.
			var mp := scene.find_child("MapUI", true, false)
			if mp and mp.has_method("set_open"):
				mp.set_open(action == "open_map")
				return true
			Events.map_toggled.emit(action == "open_map")
			return true
		"hub_stash", "hub_loadout", "hub_workshop", "hub_shop", "hub_quests", "hub_gunsmith", "hub_raider", "hub_character":
			# Switch the open Hub's active tab (screenshot QA of each tab).
			var hub := scene.find_child("Hub", true, false)
			if hub == null or not hub.has_method("_switch_tab"):
				return false
			var idx: int = (
				{
					"hub_stash": 0,
					"hub_loadout": 1,
					"hub_workshop": 2,
					"hub_shop": 3,
					"hub_quests": 4,
					"hub_gunsmith": 5,
					"hub_raider": 6,
					"hub_character": 7
				}
				. get(action, 0)
			)
			hub._switch_tab(idx)
			return true
	return false


func _do_action(action: String) -> void:
	if action == "":
		return
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	# Release shortly after so the action can be triggered again.
	get_tree().create_timer(0.06).timeout.connect(
		func() -> void:
			var rel := InputEventAction.new()
			rel.action = action
			rel.pressed = false
			Input.parse_input_event(rel)
	)


func _screenshot(sname: String) -> void:
	# force_draw() renders a frame synchronously — reliable even for an off-screen,
	# unfocused window where frame_post_draw can fail to fire promptly.
	RenderingServer.force_draw(false)
	var img := get_viewport().get_texture().get_image()
	# Namespace screenshots per instance (user://agent/<tag>/) so concurrent agents
	# never overwrite each other's captures. Single instance → plain user://agent/.
	var dir := (
		"user://agent" if Settings.instance_tag == "" else "user://agent/%s" % Settings.instance_tag
	)
	DirAccess.make_dir_recursive_absolute(dir)
	var safe := sname.validate_filename()
	if safe == "":
		safe = "shot"
	var path := "%s/%s.png" % [dir, safe]
	var err := img.save_png(path)
	if err != OK:
		_send({"ok": false, "error": "save_png failed (%s)" % err})
		return
	_send({"ok": true, "path": ProjectSettings.globalize_path(path)})


func _send(obj: Dictionary) -> void:
	if _client == null:
		return
	var line := JSON.stringify(obj) + "\n"
	_client.put_data(line.to_utf8_buffer())


## Per-zone extraction state for QA (position + timed-window state if the zone
## exposes it; defensive so it works before/after the ExtractionDirector lane lands).
func _extraction_zone_states() -> Array:
	var out: Array = []
	for z in get_tree().get_nodes_in_group(Groups.EXTRACTION):
		if not (z is Node3D):
			continue
		var zp: Vector3 = (z as Node3D).global_position
		var entry: Dictionary = {"name": z.name, "pos": [zp.x, zp.y, zp.z]}
		entry["open"] = bool(z.call("is_open")) if z.has_method("is_open") else true
		entry["window_left"] = (
			float(z.call("window_remaining")) if z.has_method("window_remaining") else 0.0
		)
		# Batch C typed zones: paid/signal identity + whether a bought/flared window
		# is currently counting down (the director leaves such zones alone).
		if "zone_type" in z:
			entry["type"] = String(z.get("zone_type"))
		if z.has_method("override_active"):
			entry["override"] = bool(z.call("override_active"))
		out.append(entry)
	return out


func _snapshot() -> Dictionary:
	var d: Dictionary = {
		"ok": true,
		"phase": GameState.phase,
		"wave": GameState.current_wave,
		"fps": Engine.get_frames_per_second(),
		# Pause-leak debugging (a recurring bug class — see raid_summary.gd): a frozen
		# world with paused=true names the culprit instantly vs chasing AI "bugs".
		"paused": get_tree().paused,
		"result": _result,
		"extraction": {"active": _extraction_active, "ratio": _extraction_ratio},
		"match_timer":
		{
			"left": GameState.match_time_left,
			"total": GameState.match_duration,
			"final_wave": GameState.final_wave
		},
		"extraction_zones": _extraction_zone_states(),
		# Batch C world clock — a pure function of the synced match timer (DayNight).
		"world":
		{
			"hour": DayNight.current_hour(),
			"night": DayNight.is_night(DayNight.current_hour()),
			"mutator": GameState.raid_mutator,
		},
		"meta":
		{
			"currency": MetaProgression.currency,
			"difficulty": GameState.difficulty,
			"difficulty_name": GameState.difficulty_name(),
			"loadout": MetaProgression.get_loadout(),
			"bring": MetaProgression.bring,
			"blueprints": MetaProgression.unlocked_blueprints,
			"quests": MetaProgression.quest_progress,
			"completed_quests": MetaProgression.completed_quests,
			"attachments": MetaProgression.equipped_attachments,
			"weapon_perks": MetaProgression.weapon_perks,
			"dailies": MetaProgression.daily_quest_ids,
			"last_reward": GameState.last_run_reward,
			"xp": MetaProgression.xp,
			"raider_level": MetaProgression.raider_level,
			"skill_points": MetaProgression.skill_points,
			"skills": MetaProgression.skills,
			"vendor_rep": MetaProgression.vendor_rep,
			"rep_tier": MetaProgression.rep_tier(),
			"weapon_mastery": MetaProgression.weapon_mastery,
			"quest_states": MetaProgression.quest_states,
			"kills_by_type": MetaProgression.kills_by_type,
			"extractions_total": MetaProgression.extractions_total,
			"giver_rep": MetaProgression.giver_rep,
			"questlines": AgentQuestDebug.questlines_meta(),
			"mutator": GameState.raid_mutator,
			"gear": MetaProgression.get_equipped_gear(),
			"armor_durability": MetaProgression.armor_durability,
			"insured": MetaProgression.insured_current,
			"insured_pending": MetaProgression.insured_pending,
		},
		"agent_held": _held,
		"stash": Stash.items,
		"stash_weight": Stash.total_weight(),
		"stash_cap": Stash.capacity(),
	}
	var players := get_tree().get_nodes_in_group(Groups.PLAYERS)
	d["players_count"] = players.size()
	d["peer_id"] = GameState.local_peer_id()
	d["peers"] = GameState.peers.keys()
	d["peers_count"] = GameState.peers.size()
	d["favorites"] = ServerBrowser.get_favorites()
	d["recents"] = ServerBrowser.get_recents()
	d["lan"] = ServerBrowser.last_found
	d["scoreboard"] = {
		"kills": GameState.kills,
		"deaths": GameState.deaths,
		"mobs_killed": GameState.mobs_killed,
	}
	var p: Node = _local_player(players)
	if p == null:
		d["player"] = null
		d["drivable"] = false
		d["inventory"] = []
		d["enemies"] = []
		return d

	var hp: Health = p.get_node_or_null(Groups.NODE_HEALTH)
	var inv: Inventory = p.get_node_or_null("Inventory")
	var cam_pivot: Node3D = p.get_node_or_null("CameraPivot")
	var spring: Node3D = p.get_node_or_null("CameraPivot/SpringArm3D")
	var wc: Node = p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController")
	var wid := _weapon_id
	if wc and wc.has_method("current_weapon_id"):
		var cwid: String = wc.current_weapon_id()
		if cwid != "":
			wid = cwid
	d["player"] = {
		"pos": _v3(p.global_position),
		"rot_y": p.rotation.y,
		"health": hp.current if hp else 0.0,
		"max_health": hp.max_health if hp else 0.0,
		"on_floor": p.is_on_floor(),
		"velocity": _v3(p.velocity),
		"cam_yaw": cam_pivot.rotation.y if cam_pivot else 0.0,
		"cam_pitch": spring.rotation.x if spring else 0.0,
		"alive": (not hp.is_dead) if hp else false,
		"downed": p.is_downed() if p.has_method("is_downed") else false,
		"weapon": wid,
		"ammo": _ammo,
		"reserve": _reserve,
		"reloading": _reloading,
		"ads": bool(p.get("_ads")),
		"shoulder": float(p.get("_shoulder_sign")),
		"medkits": int(p.get("_medkits")),
		"grenade_counts": p.get("_grenade_counts") if p.get("_grenade_counts") != null else {},
		"grenade_sel": str(p.get("_grenade_sel")) if p.get("_grenade_sel") != null else "",
		"gadget_counts": p.get("_gadget_counts") if p.get("_gadget_counts") != null else {},
		"iframes":
		(
			int(p.get("_iframes_until_ms")) > Time.get_ticks_msec()
			if p.get("_iframes_until_ms") != null
			else false
		),
		"zipline": p.get("_zipline") != null,
		"mantling": bool(p.get("_mantling")) if p.get("_mantling") != null else false,
		"flashlight": bool(p.get("flashlight_on")) if p.get("flashlight_on") != null else false,
		"keys": p.get("_keys") if p.get("_keys") != null else {},
		"flares": int(p.get("_flares")) if p.get("_flares") != null else 0,
		"status": _status_effects_of(p),
		"carry_bonus": float(p.get("carry_bonus")) if p.get("carry_bonus") != null else 0.0,
		"meds":
		{
			"bandages": int(p.get("_bandages")) if p.get("_bandages") != null else 0,
			"splints": int(p.get("_splints")) if p.get("_splints") != null else 0,
			"painkillers": int(p.get("_painkillers")) if p.get("_painkillers") != null else 0,
		},
		"secure": _secure_of(p),
		"stance": int(p.get("stance")) if p.get("stance") != null else 0,
		"water": int(p.get("_water_state")) if p.get("_water_state") != null else 0,
		"noise_radius": p.noise_radius() if p.has_method("noise_radius") else 0.0,
		"fov": _cam_fov(p),
		"agent_active": active,
		"input_enabled": bool(p.get("_input_enabled")),
		"authority": p.is_multiplayer_authority(),
		"bleedout": float(p.get("_bleedout")) if p.get("_bleedout") != null else 0.0,
		"revive_progress":
		float(p.get("_revive_progress")) if p.get("_revive_progress") != null else 0.0,
		"carried_by": int(p.get("_carried_by_peer")) if p.get("_carried_by_peer") != null else 0,
		"carrying": p.is_carrying() if p.has_method("is_carrying") else false,
		"self_revives": int(p.get("_self_revives")) if p.get("_self_revives") != null else 0,
		"shields": int(p.get("_shields")) if p.get("_shields") != null else 0,
		"buffs": p.active_buffs() if p.has_method("active_buffs") else [],
		"stamina": float(p.get("_stamina")) if p.get("_stamina") != null else 0.0,
		"max_stamina": float(p.get("_max_stamina")) if p.get("_max_stamina") != null else 0.0,
		"speed": Vector2(p.velocity.x, p.velocity.z).length() if p is Node3D else 0.0,
		"crosshair": _debug_crosshair(),
		"wdbg":
		{
			"weapons": wc.get("_weapons").size() if (wc and wc.get("_weapons") != null) else 0,
			"cooldown": float(wc.get("_cooldown")) if (wc and wc.get("_cooldown") != null) else 0.0,
			"latched": bool(wc.get("_semi_latched")) if wc else false,
			"reloading": bool(wc.get("_reloading")) if wc else false,
			"enabled": bool(wc.get("_enabled")) if wc else false,
			"agent_fire": fire,
			"tf_calls": int(wc.get("_tf_calls")) if (wc and wc.get("_tf_calls") != null) else 0,
			"tf_fail": str(wc.get("_tf_fail")) if (wc and wc.get("_tf_fail") != null) else "",
			"wc_ref_ok": p.get("_weapon_controller") != null,
			"cam_ref_ok": p.get("camera") != null,
		},
	}
	var stacks: Array = []
	if inv:
		for s in inv.stacks:
			var item: ItemData = s["item"]
			stacks.append({"id": item.id, "count": s["count"], "weight": item.weight})
		d["inv_weight"] = inv.total_weight()
		d["inv_value"] = inv.total_value()
	# Drivable = the local player is fully spawned + its weapon/camera refs resolved +
	# input enabled. Poll this after deploy/join before scripting move/fire (avoids the
	# post-spawn race where refs are briefly null — the cause of "co-op client wont fire").
	d["drivable"] = (
		p.get("_weapon_controller") != null
		and p.get("camera") != null
		and bool(p.get("_input_enabled"))
		and active
	)
	d["inventory"] = stacks

	var enemies: Array = []
	for e in get_tree().get_nodes_in_group(Groups.ENEMIES):
		var ehp: Health = e.get_node_or_null(Groups.NODE_HEALTH)
		var st := -1
		if "current_state" in e:
			st = int(e.current_state)
		var erec := {
			"name": e.name,
			"id": str(e.get("enemy_id")) if "enemy_id" in e else "?",
			"pos": _v3(e.global_position),
			"health": ehp.current if ehp else 0.0,
			"state": st,
			"hunter": bool(e.get("hunter")) if "hunter" in e else false,
			"target":
			(
				str(e.get_target().name)
				if (e.has_method("get_target") and e.get_target() != null)
				else ""
			),
			"investigating": st == 3,
			"dist": p.global_position.distance_to(e.global_position),
		}
		# Worm burrow cycle (0 BURROWED / 1 EMERGE / 2 SURFACE / 3 SUBMERGE) for QA.
		if "phase" in e:
			erec["phase"] = int(e.get("phase"))
		# EMP stun (server-side window; duck-typed so this works pre-feature too).
		var stun_ms: Variant = e.get("_stunned_until_ms")
		erec["stunned"] = stun_ms != null and int(stun_ms) > Time.get_ticks_msec()
		# Elite modifiers (batch D) + the recon drone's channel progress (duck-typed).
		var emods: Variant = e.get("modifiers")
		if emods is Array and not (emods as Array).is_empty():
			erec["modifiers"] = emods
		var chan: Variant = e.get("_channel_t")
		if chan != null:
			erec["channel"] = float(chan)
		enemies.append(erec)
	d["enemies"] = enemies

	# Active deployables + smoke clouds (batch A QA).
	var gadgets: Array = []
	var arena_node: Node = get_tree().get_first_node_in_group(Groups.ARENA)
	var gadget_root: Node = arena_node.get_node_or_null("Net/Gadgets") if arena_node else null
	if gadget_root:
		for g in gadget_root.get_children():
			if g is Node3D:
				gadgets.append({"name": str(g.name), "pos": _v3((g as Node3D).global_position)})
	d["gadgets"] = gadgets
	var smoke: Array = []
	for sc in get_tree().get_nodes_in_group(Groups.SMOKE):
		if sc is Node3D:
			smoke.append(_v3((sc as Node3D).global_position))
	d["smoke"] = smoke

	# All players (incl. remotes) with their REPLICATED cosmetics — proves co-op appearance
	# sync: each peer's copy of another player carries that player's chosen look.
	var players_arr: Array = []
	for pl in get_tree().get_nodes_in_group(Groups.PLAYERS):
		(
			players_arr
			. append(
				{
					"name": str(pl.name),
					"authority":
					(
						pl.is_multiplayer_authority()
						if pl.has_method("is_multiplayer_authority")
						else false
					),
					"cosmetics": pl.get("cosmetics") if "cosmetics" in pl else {},
					"downed": pl.is_downed() if pl.has_method("is_downed") else false,
				}
			)
		)
	d["players"] = players_arr

	var loot: Array = []
	for l in get_tree().get_nodes_in_group(Groups.PICKUPS):
		(
			loot
			. append(
				{
					"id": str(l.get("item_id")) if "item_id" in l else "?",
					"count": int(l.get("count")) if "count" in l else 1,
					"pos": _v3(l.global_position),
					"dist": p.global_position.distance_to(l.global_position),
				}
			)
		)
	d["loot"] = loot

	# Dynamic world events (markers + the active supply cache) for QA introspection.
	var wevents: Array = []
	var director: Node = get_node_or_null("/root/WorldEventDirector")
	for w in get_tree().get_nodes_in_group(Groups.WORLD_EVENTS):
		var wr := -1.0
		if w.has_method("event_ratio"):
			wr = float(w.call("event_ratio"))
		elif director and director.has_method("marker_event_ratio"):
			wr = float(director.call("marker_event_ratio", w))
		(
			wevents
			. append(
				{
					"kind": int(w.get_meta("event_kind")) if w.has_meta("event_kind") else -1,
					"label": str(w.get_meta("event_label")) if w.has_meta("event_label") else "",
					"pos": _v3(w.global_position) if w is Node3D else [0, 0, 0],
					"ratio": wr,
				}
			)
		)
	d["world_events"] = wevents
	d["active_event_kind"] = (
		int(director.get("_active_kind")) if (director and "_active_kind" in director) else -1
	)
	return d


## QA: select + throw a grenade type via the REAL PlayerGear path (server routing
## included). Grants one if the player carries none, so recipes need no stash setup.
func _debug_grenade(type: String) -> Dictionary:
	var pl: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if pl == null:
		return {"ok": false, "reason": "no local player"}
	if not Settings.GRENADE_TYPES.has(type):
		return {"ok": false, "reason": "unknown type"}
	if int(pl._grenade_counts.get(type, 0)) <= 0:
		pl._grenade_counts[type] = 1
	pl._grenade_sel = type
	var gear: Node = pl.get_node_or_null("Gear")
	if gear == null:
		return {"ok": false, "reason": "no gear component"}
	gear.throw_selected()
	return {"ok": true, "type": type, "left": int(pl._grenade_counts.get(type, 0))}


## QA: force-place a deployable gadget at the player's feet-forward point. Bypasses
## the carried count (grants one) but uses the real placement/server-spawn path.
func _debug_gadget(type: String) -> Dictionary:
	var pl: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if pl == null:
		return {"ok": false, "reason": "no local player"}
	if not Settings.GADGET_TYPES.has(type):
		return {"ok": false, "reason": "unknown type"}
	if int(pl._gadget_counts.get(type, 0)) <= 0:
		pl._gadget_counts[type] = 1
	var gear: Node = pl.get_node_or_null("Gear")
	if gear == null:
		return {"ok": false, "reason": "no gear component"}
	gear.place(Settings.GADGET_TYPES.find(type))
	return {"ok": true, "type": type, "left": int(pl._gadget_counts.get(type, 0))}


## Drives the local player's nearest in-range loot pickup through the real
## loot_pickup._request_pickup path (so a client exercises the server-validated RPC).
## Returns the chosen pickup's id + distance, or ok:false if none in range.
func _debug_pickup() -> Dictionary:
	var plr: Node = _local_player(get_tree().get_nodes_in_group(Groups.PLAYERS))
	if plr == null or not (plr is Node3D):
		return {"ok": false, "reason": "no local player"}
	var ppos: Vector3 = (plr as Node3D).global_position
	var best: Node = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(Groups.PICKUPS):
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		var d: float = (n as Node3D).global_position.distance_to(ppos)
		if d < best_d:
			best_d = d
			best = n
	if best == null or best_d > 3.0:
		return {
			"ok": false, "reason": "no pickup in range", "nearest": best_d if best != null else -1.0
		}
	if not best.has_method("_request_pickup"):
		return {"ok": false, "reason": "pickup has no _request_pickup"}
	best.call("_request_pickup", plr)
	return {"ok": true, "id": str(best.get("item_id")), "dist": snappedf(best_d, 0.01)}


func _local_player(players: Array) -> Node:
	# Prefer the player this peer has authority over; offline there is just one.
	for p in players:
		if p.is_multiplayer_authority():
			return p
	return players[0] if players.size() > 0 else null


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


## Active status effects of a player (batch B), [] when the Status node is absent.
func _status_effects_of(p: Node) -> Array:
	var st: Node = p.get_node_or_null("Status")
	if st != null and st.has_method("active_effects"):
		return st.call("active_effects")
	return []


## The player's secured pouch dict (batch B), {} when unavailable.
func _secure_of(p: Node) -> Dictionary:
	var inv: Node = p.get_node_or_null("Inventory")
	if inv != null and inv.get("secure") != null:
		return inv.get("secure")
	return {}


## Current camera FOV of a player (for verifying ADS zoom), or 0.0 if no camera.
func _cam_fov(p: Node) -> float:
	var cam: Camera3D = p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
	return cam.fov if cam else 0.0


## Collect the RIDs of every CollisionObject3D in `root`s subtree (for ray excludes).
func _collect_collision_rids(root: Node, out: Array[RID]) -> void:
	if root is CollisionObject3D:
		out.append((root as CollisionObject3D).get_rid())
	for c in root.get_children():
		_collect_collision_rids(c, out)
