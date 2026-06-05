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
var move: Vector2 = Vector2.ZERO   # x = strafe right(+)/left(-), y = forward(+)/back(-)
var sprint: bool = false
var fire: bool = false
var ads: bool = false               # aim-down-sights (harness-driven)
var _pending_look: Vector2 = Vector2.ZERO   # dx = yaw (right+), dy = pitch (down+), radians

var _server: TCPServer
var _client: StreamPeerTCP
var _rx: String = ""
# A move/fire command holds input for `duration`, replying only when it ends, so the
# client blocks until the action completes (synchronous scripted play).
var _pending: Dictionary = {}   # { deadline_ms, response, clears }

# Cached match feedback (filled from the Events bus).
var _extraction_active: bool = false
var _extraction_ratio: float = 0.0
var _result: String = ""        # "", "won", "lost"
var _weapon_id: String = ""     # cached from Events for state()
var _ammo: int = 0
var _reserve: int = 0
var _reloading: bool = false


func _ready() -> void:
	# Keep serving the control socket even when the tree is paused (for QA of menus).
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)   # stays inert until activate()


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
	Events.extraction_progress.connect(func(_p, r): _extraction_active = true; _extraction_ratio = r)
	Events.extraction_completed.connect(func(_p): _extraction_active = false; _extraction_ratio = 1.0)
	Events.extraction_cancelled.connect(func(_p): _extraction_active = false; _extraction_ratio = 0.0)
	Events.match_won.connect(func(): _result = "won")
	Events.match_lost.connect(func(): _result = "lost")
	# A new match (incl. restart) clears cached match-result/extraction state.
	Events.match_started.connect(func(): _result = ""; _extraction_active = false; _extraction_ratio = 0.0)
	# Cache weapon/ammo for state() assertions (the controller emits these).
	Events.weapon_switched.connect(func(id, a, r): _weapon_id = id; _ammo = a; _reserve = r)
	Events.ammo_changed.connect(func(a, r): _ammo = a; _reserve = r)
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
				"move": move = Vector2.ZERO
				"fire": fire = false
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
		_send({ "ok": false, "error": "malformed json" })
		return
	var json: Dictionary = parsed
	var cmd := str(json.get("cmd", ""))
	match cmd:
		"ping":
			_send({ "ok": true, "agent": true })
		"state":
			_send(_snapshot())
		"move":
			move = Vector2(clampf(float(json.get("x", 0.0)), -1.0, 1.0),
				clampf(float(json.get("y", 0.0)), -1.0, 1.0))
			_hold(float(json.get("duration", 0.5)), "move")
		"fire":
			fire = true
			_hold(float(json.get("duration", 0.3)), "fire")
		"look":
			_pending_look += Vector2(float(json.get("dx", 0.0)), float(json.get("dy", 0.0)))
			_send({ "ok": true })
		"aim":
			# Precisely point the player's camera at an enemy (engine-side math, exact).
			# target: "nearest" (default) or an enemy node name.
			var aimed := _aim_at(str(json.get("target", "nearest")))
			_send({ "ok": aimed })
		"sprint":
			sprint = bool(json.get("on", false))
			_send({ "ok": true })
		"ads":
			ads = bool(json.get("on", false))
			_send({ "ok": true })
		"spawn":
			# Debug: spawn an enemy archetype near the local player for verification.
			var ok := _debug_spawn(str(json.get("id", "wasp")), float(json.get("dist", 9.0)))
			_send({ "ok": ok })
		"tp":
			# Debug: teleport the local player to a world XZ (for reaching far test spots).
			var pl2: Node = _local_player(get_tree().get_nodes_in_group("players"))
			if pl2 is Node3D:
				(pl2 as Node3D).global_position = Vector3(
					float(json.get("x", 0.0)), float(json.get("y", 1.5)), float(json.get("z", 0.0)))
			_send({ "ok": pl2 != null })
		"godmode":
			# Debug: toggle local-player invulnerability (for safe verification).
			var pl: Node = _local_player(get_tree().get_nodes_in_group("players"))
			var hp: Health = pl.get_node_or_null("Health") if pl else null
			if hp:
				hp.invulnerable = bool(json.get("on", true))
			_send({ "ok": hp != null })
		"refill":
			# Debug: top the local player's weapons back to full ammo (sustained playtests).
			var plr: Node = _local_player(get_tree().get_nodes_in_group("players"))
			var wc2: Node = plr.get_node_or_null("CameraPivot/SpringArm3D/Camera3D/WeaponController") if plr else null
			if wc2 and wc2.has_method("refill_ammo"):
				wc2.refill_ammo()
			_send({ "ok": wc2 != null })
		"render":
			# Debug: render a logical id's model in isolation (clean 3/4 hero shot) and
			# save it as a PNG for visual QA of procedural models + inventory icons.
			var rid := str(json.get("id", ""))
			var rname := str(json.get("name", rid))
			var rtex: Texture2D = await IconRenderer.render_now(rid)
			if rtex == null:
				_send({ "ok": false, "error": "no texture (headless or unknown id)" })
			else:
				var rdir := "user://agent" if Settings.instance_tag == "" else "user://agent/%s" % Settings.instance_tag
				DirAccess.make_dir_recursive_absolute(rdir)
				var rpath := "%s/%s.png" % [rdir, rname.validate_filename()]
				var rerr := rtex.get_image().save_png(rpath)
				_send({ "ok": rerr == OK, "path": ProjectSettings.globalize_path(rpath),
					"debug": IconRenderer.last_debug })
		"stash":
			# Debug: manipulate the persistent stash + bring-list (raid-economy QA).
			#   {action:add|remove, id, count} · {action:bring, id, count} · {action:clear}
			var act := str(json.get("action", ""))
			var sid := str(json.get("id", ""))
			var cnt := int(json.get("count", 1))
			match act:
				"add": Stash.add(sid, cnt)
				"remove": Stash.remove(sid, cnt)
				"clear": Stash.clear()
				"bring":
					var b: Dictionary = MetaProgression.get_bring()
					if cnt > 0: b[sid] = cnt
					else: b.erase(sid)
					MetaProgression.set_bring(b)
				"deploy": RaidManager.deploy()   # commit the bring-list (remove from stash)
				"craft": Crafting.craft(Crafting.recipe_by_id(sid))
				"recycle": Crafting.recycle(sid)
				"learn": MetaProgression.learn_blueprint(sid)   # simulate buy/quest blueprint
				"claim": Quests.claim(sid)
				"give":
					# Add an item to the local player's MATCH inventory (simulate found loot).
					var gpl: Node = _local_player(get_tree().get_nodes_in_group("players"))
					var ginv: Node = gpl.get_node_or_null("Inventory") if gpl else null
					var git: ItemData = ItemCatalog.get_item(sid)
					if ginv and git and ginv.has_method("add_item"):
						ginv.add_item(git, cnt)
				"currency": MetaProgression.earn(cnt)           # grant currency for QA
				"buy": Crafting.buy_blueprint(sid, int(json.get("price", 0)))
				"questprog":                                    # force quest progress for QA
					MetaProgression.quest_progress[sid] = cnt
					MetaProgression.save_profile()
				"equip": MetaProgression.equip_attachment(str(json.get("weapon", "")), str(json.get("slot", "")), sid)
				"unequip": MetaProgression.unequip_attachment(str(json.get("weapon", "")), str(json.get("slot", "")))
				"perk": MetaProgression.buy_weapon_perk(str(json.get("weapon", "")), str(json.get("perk", "")))
				"daily": Quests.get_daily_quests()   # trigger daily rotation for QA
			_send({ "ok": true, "stash": Stash.items, "bring": MetaProgression.bring,
				"blueprints": MetaProgression.unlocked_blueprints })
		"net":
			# Debug: start co-op from an --agent --menu instance so the harness can drive
			# multiplayer + per-player stash tests across instances. action: host | join.
			var nact := str(json.get("action", ""))
			var nsc := get_tree().current_scene
			if nact == "host":
				NetworkManager.host_game()
				if nsc and nsc.has_method("open_hub"):
					nsc.open_hub("host")
				_send({ "ok": true })
			elif nact == "join":
				var ip := str(json.get("ip", "127.0.0.1"))
				var jerr := NetworkManager.join_game(ip)
				if jerr == OK and not multiplayer.connected_to_server.is_connected(_agent_open_client_hub):
					multiplayer.connected_to_server.connect(_agent_open_client_hub, CONNECT_ONE_SHOT)
				_send({ "ok": jerr == OK })
			else:
				_send({ "ok": false, "error": "net action host|join" })
		"deploy":
			# Debug: trigger the hub DEPLOY (commit bring-list + load the raid).
			var dsc := get_tree().current_scene
			if dsc and dsc.has_method("_on_hub_deploy"):
				dsc._on_hub_deploy()
			_send({ "ok": dsc != null })
		"ui":
			# Debug: open/close menus for screenshot verification.
			_send({ "ok": _ui_action(str(json.get("action", ""))) })
		"setting":
			# Debug: get/set a SettingsManager value (verify apply + persist).
			var skey := str(json.get("key", ""))
			if json.has("value"):
				SettingsManager.set_value(skey, json.get("value"))
			_send({ "ok": true, "value": SettingsManager.get_value(skey) })
		"goto":
			# Face a world XZ point and walk forward toward it for `duration`.
			_face_point(Vector2(float(json.get("x", 0.0)), float(json.get("z", 0.0))))
			move = Vector2(0.0, 1.0)
			_hold(float(json.get("duration", 0.5)), "move")
		"act":
			_do_action(str(json.get("action", "")))
			_send({ "ok": true })
		"screenshot":
			_screenshot(str(json.get("name", "shot")))   # replies asynchronously
		"restart":
			# Reload the match (used to reset between play-test scenarios).
			var main := get_tree().current_scene
			if main and main.has_method("restart_match"):
				main.restart_match()
			_send({ "ok": true })
		"quit":
			_send({ "ok": true })
			get_tree().quit()
		_:
			_send({ "ok": false, "error": "unknown cmd '%s'" % cmd })


func _hold(duration: float, clears: String) -> void:
	_pending = {
		"deadline": Time.get_ticks_msec() + int(maxf(0.0, duration) * 1000.0),
		"response": { "ok": true },
		"clears": clears,
	}


## Points the local player's camera straight at an enemy's torso. Iterates a few
## times because the camera orbits the pivot (changing the yaw moves the camera
## position), so position and aim direction must converge together. After this the
## screen-center crosshair is on the target, so Weapon.try_fire connects.
func _aim_at(target_name: String) -> bool:
	var players := get_tree().get_nodes_in_group("players")
	var p: Node = _local_player(players)
	if p == null:
		return false
	var pivot: Node3D = p.get_node_or_null("CameraPivot")
	var spring: Node3D = p.get_node_or_null("CameraPivot/SpringArm3D")
	var cam: Node3D = p.get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
	if pivot == null or spring == null or cam == null:
		return false

	var enemy: Node3D = _pick_enemy(p, target_name)
	if enemy == null:
		return false
	# Aim at the body CENTRE (global_position). The old +0.9 torso bias overshot small
	# targets like the 0.4 m flying wasp (crosshair landed just above it → every shot
	# missed); the centre is inside every archetype's hitbox, ground or air.
	var aimp := enemy.global_position

	# The body carries the global yaw (pivot yaw is transferred into it each frame by
	# the controller), so set the BODY yaw and keep the pivot's local yaw at 0; pitch
	# lives on the spring arm. We aim so the CAMERA'S forward ray lands on the target,
	# because the weapon's two-stage shot converges bullets to that crosshair point.
	# The camera sits ~4 m back/up on the spring arm, so for ELEVATED targets (flying
	# wasps) the pivot-based angle misses — refine a few times from the camera's true
	# position (which moves as we rotate) until it converges onto the target.
	var origin: Vector3 = pivot.global_position
	for _i in 3:
		var to := (aimp - origin).normalized()
		(p as Node3D).rotation.y = atan2(-to.x, -to.z)
		pivot.rotation.y = 0.0
		var flat := Vector2(to.x, to.z).length()
		spring.rotation.x = clampf(atan2(to.y, flat),
			Settings.CAMERA_PITCH_MIN, Settings.CAMERA_PITCH_MAX)
		(p as Node3D).force_update_transform()
		pivot.force_update_transform()
		spring.force_update_transform()
		cam.force_update_transform()
		origin = cam.global_position   # refine against where the camera actually ended up
	return true


## Faces the player body (and camera) toward a world XZ point — used by `goto` so
## forward movement heads straight at loot / the extraction zone.
func _face_point(target_xz: Vector2) -> void:
	var players := get_tree().get_nodes_in_group("players")
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
	var enemies := get_tree().get_nodes_in_group("enemies")
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


## Debug: instance an enemy archetype in front of the local player (for verifying
## the new types). Server-authoritative; reuses the wave enemy container.
func _debug_spawn(eid: String, dist: float) -> bool:
	if not GameState.is_local_authority_server():
		return false
	var scene_map := {
		"grunt": "res://scenes/enemies/RobotEnemy.tscn",
		"tick": "res://scenes/enemies/RobotTick.tscn",
		"heavy": "res://scenes/enemies/RobotHeavy.tscn",
		"wasp": "res://scenes/enemies/RobotWasp.tscn",
		"bastion": "res://scenes/enemies/RobotBastion.tscn",
		"boss": "res://scenes/enemies/RobotBoss.tscn",
	}
	var path: String = scene_map.get(eid, "")
	if path == "" or not ResourceLoader.exists(path):
		return false
	var container: Node = null
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			container = e.get_parent()
			break
	var p: Node = _local_player(get_tree().get_nodes_in_group("players"))
	if container == null or p == null or not (p is Node3D):
		return false
	var enemy: Node = (load(path) as PackedScene).instantiate()
	if "hunter" in enemy:
		enemy.hunter = true
	container.add_child(enemy, true)
	var fwd := -(p as Node3D).global_transform.basis.z
	(enemy as Node3D).global_position = (p as Node3D).global_position + fwd * dist + Vector3.UP * 0.5
	return true


## Client-side: once connected to the host, open this peer's own Hub (loadout/stash).
func _agent_open_client_hub() -> void:
	var sc := get_tree().current_scene
	if sc and sc.has_method("open_hub"):
		sc.open_hub("client")


## Debug: open/close menu overlays so the harness can screenshot them.
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
		"hub_stash", "hub_loadout", "hub_workshop", "hub_shop", "hub_quests", "hub_gunsmith":
			# Switch the open Hub's active tab (screenshot QA of each tab).
			var hub := scene.find_child("Hub", true, false)
			if hub == null or not hub.has_method("_switch_tab"):
				return false
			var idx: int = { "hub_stash": 0, "hub_loadout": 1, "hub_workshop": 2,
				"hub_shop": 3, "hub_quests": 4, "hub_gunsmith": 5 }.get(action, 0)
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
	get_tree().create_timer(0.06).timeout.connect(func() -> void:
		var rel := InputEventAction.new()
		rel.action = action
		rel.pressed = false
		Input.parse_input_event(rel))


func _screenshot(sname: String) -> void:
	# force_draw() renders a frame synchronously — reliable even for an off-screen,
	# unfocused window where frame_post_draw can fail to fire promptly.
	RenderingServer.force_draw(false)
	var img := get_viewport().get_texture().get_image()
	# Namespace screenshots per instance (user://agent/<tag>/) so concurrent agents
	# never overwrite each other's captures. Single instance → plain user://agent/.
	var dir := "user://agent" if Settings.instance_tag == "" else "user://agent/%s" % Settings.instance_tag
	DirAccess.make_dir_recursive_absolute(dir)
	var safe := sname.validate_filename()
	if safe == "":
		safe = "shot"
	var path := "%s/%s.png" % [dir, safe]
	var err := img.save_png(path)
	if err != OK:
		_send({ "ok": false, "error": "save_png failed (%s)" % err })
		return
	_send({ "ok": true, "path": ProjectSettings.globalize_path(path) })


func _send(obj: Dictionary) -> void:
	if _client == null:
		return
	var line := JSON.stringify(obj) + "\n"
	_client.put_data(line.to_utf8_buffer())


func _snapshot() -> Dictionary:
	var d: Dictionary = {
		"ok": true,
		"phase": GameState.phase,
		"wave": GameState.current_wave,
		"fps": Engine.get_frames_per_second(),
		"result": _result,
		"extraction": { "active": _extraction_active, "ratio": _extraction_ratio },
		"meta": {
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
		},
		"stash": Stash.items,
		"stash_weight": Stash.total_weight(),
		"stash_cap": Stash.capacity(),
	}
	var players := get_tree().get_nodes_in_group("players")
	d["players_count"] = players.size()
	var p: Node = _local_player(players)
	if p == null:
		d["player"] = null
		d["inventory"] = []
		d["enemies"] = []
		return d

	var hp: Health = p.get_node_or_null("Health")
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
		"weapon": wid,
		"ammo": _ammo,
		"reserve": _reserve,
		"reloading": _reloading,
		"ads": bool(p.get("_ads")),
		"shoulder": float(p.get("_shoulder_sign")),
		"medkits": int(p.get("_medkits")),
		"grenades": int(p.get("_grenades")),
	}
	var stacks: Array = []
	if inv:
		for s in inv.stacks:
			var item: ItemData = s["item"]
			stacks.append({ "id": item.id, "count": s["count"], "weight": item.weight })
		d["inv_weight"] = inv.total_weight()
		d["inv_value"] = inv.total_value()
	d["inventory"] = stacks

	var enemies: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		var ehp: Health = e.get_node_or_null("Health")
		var st := -1
		if "current_state" in e:
			st = int(e.current_state)
		enemies.append({
			"name": e.name,
			"id": str(e.get("enemy_id")) if "enemy_id" in e else "?",
			"pos": _v3(e.global_position),
			"health": ehp.current if ehp else 0.0,
			"state": st,
			"dist": p.global_position.distance_to(e.global_position),
		})
	d["enemies"] = enemies

	var loot: Array = []
	for l in get_tree().get_nodes_in_group("pickups"):
		loot.append({
			"id": str(l.get("item_id")) if "item_id" in l else "?",
			"count": int(l.get("count")) if "count" in l else 1,
			"pos": _v3(l.global_position),
			"dist": p.global_position.distance_to(l.global_position),
		})
	d["loot"] = loot
	return d


func _local_player(players: Array) -> Node:
	# Prefer the player this peer has authority over; offline there is just one.
	for p in players:
		if p.is_multiplayer_authority():
			return p
	return players[0] if players.size() > 0 else null


func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
