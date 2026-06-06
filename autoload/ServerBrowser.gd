extends Node
## Local server list (favorites + recent connections) persisted to favorites.cfg,
## plus LAN discovery over UDP broadcast. Pure client-side convenience — it does NOT
## touch the authoritative netcode. The server-browser UI + main menu read through here.
##
## Persistence mirrors SettingsManager: a `_meta/save_version` stamp + a defensive,
## version-resilient load that never wipes and warns once on a newer-than-this-build save.
## LAN discovery: a host auto-answers `HYPE_DISCOVER?` pings on Settings.DISCOVERY_PORT;
## a client `scan_lan()` broadcasts the ping and collects replies for a short window.

const _DISCOVER_MSG := "HYPE_DISCOVER?"
const RECENTS_CAP := 8

# [{ name:String, ip:String, port:int }]
var favorites: Array = []
# [{ name:String, ip:String, port:int, last:int }]  (MRU, capped at RECENTS_CAP)
var recents: Array = []
# Most recent LAN scan result (UI + harness read this): [{ name, ip, port, players, max }]
var last_found: Array = []

var _warned_newer := false

# LAN sockets (null when inactive). Responder = host side; scanner = client side.
var _responder: PacketPeerUDP = null
var _scanner: PacketPeerUDP = null
var _scan_until_ms: int = 0
var _found: Dictionary = {}   # "ip:port" -> server dict (dedup within one scan)

func _path() -> String:
	return Settings.user_path("favorites", "cfg")

func _ready() -> void:
	load_config()

# --------------------------------------------------------------- version helper
## -1 if a<b, 0 equal, 1 if a>b. Splits on ".", missing/non-numeric parts = 0.
func _cmp_version(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	var n: int = maxi(pa.size(), pb.size())
	for i in n:
		var ai := int(pa[i]) if i < pa.size() else 0
		var bi := int(pb[i]) if i < pb.size() else 0
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0

# --------------------------------------------------------------- persistence
func load_config() -> void:
	favorites.clear()
	recents.clear()
	var cfg := ConfigFile.new()
	if cfg.load(_path()) != OK:
		return
	var save_ver := String(cfg.get_value("_meta", "save_version", ""))
	if save_ver != "" and _cmp_version(save_ver, Settings.GAME_VERSION) > 0:
		if not _warned_newer:
			_warned_newer = true
			push_warning("[ServerBrowser] favorites.cfg is from a newer game version (v%s > v%s) — loading what we can." % [save_ver, Settings.GAME_VERSION])
			Events.notify.emit("Save is from a newer game version (v%s) — loading what we can." % save_ver, 2)
	favorites = _sanitize(cfg.get_value("servers", "favorites", []), false)
	recents = _sanitize(cfg.get_value("servers", "recents", []), true)

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("_meta", "save_version", Settings.GAME_VERSION)
	cfg.set_value("servers", "favorites", favorites)
	cfg.set_value("servers", "recents", recents)
	cfg.save(_path())

## Keep only well-formed entries (so a malformed/newer file can't break the load).
func _sanitize(raw: Variant, with_last: bool) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for e in raw:
		if not (e is Dictionary):
			continue
		var ip := String(e.get("ip", ""))
		if ip == "":
			continue
		var entry: Dictionary = {
			"name": String(e.get("name", ip)),
			"ip": ip,
			"port": int(e.get("port", Settings.DEFAULT_PORT)),
		}
		if with_last:
			entry["last"] = int(e.get("last", 0))
		out.append(entry)
	return out

# --------------------------------------------------------------- address parsing
## "host" or "host:port" → { ip, port }. Blank → DEFAULT_IP. (IPv4 / hostnames; no
## IPv6-bracket handling — this is co-op LAN/direct-IP.)
func parse_addr(text: String) -> Dictionary:
	var t := text.strip_edges()
	var ip := Settings.DEFAULT_IP
	var port := Settings.DEFAULT_PORT
	if t != "":
		var idx := t.rfind(":")
		if idx > 0 and t.substr(idx + 1).is_valid_int():
			port = int(t.substr(idx + 1))
			ip = t.substr(0, idx)
		else:
			ip = t
	return { "ip": ip, "port": port }

# --------------------------------------------------------------- favorites API
func get_favorites() -> Array:
	return favorites

func get_recents() -> Array:
	return recents

func is_favorite(ip: String, port: int) -> bool:
	for f in favorites:
		if String(f["ip"]) == ip and int(f["port"]) == port:
			return true
	return false

func add_favorite(name: String, ip: String, port: int) -> void:
	if ip.strip_edges() == "" or is_favorite(ip, port):
		return
	favorites.append({ "name": (name if name != "" else ip), "ip": ip, "port": port })
	save()
	Events.favorites_changed.emit()

func remove_favorite(ip: String, port: int) -> void:
	var changed := false
	for i in range(favorites.size() - 1, -1, -1):
		if String(favorites[i]["ip"]) == ip and int(favorites[i]["port"]) == port:
			favorites.remove_at(i)
			changed = true
	if changed:
		save()
		Events.favorites_changed.emit()

## Record a (successful) connection into the MRU recents list.
func record_connect(ip: String, port: int, name: String = "") -> void:
	for i in range(recents.size() - 1, -1, -1):
		if String(recents[i]["ip"]) == ip and int(recents[i]["port"]) == port:
			recents.remove_at(i)
	recents.push_front({
		"name": (name if name != "" else ip),
		"ip": ip, "port": port,
		"last": int(Time.get_unix_time_from_system()),
	})
	while recents.size() > RECENTS_CAP:
		recents.pop_back()
	save()
	Events.favorites_changed.emit()

# --------------------------------------------------------------- LAN discovery
func _process(_dt: float) -> void:
	_update_responder()
	if _responder != null:
		_poll_responder()
	if _scanner != null:
		_poll_scanner()

## Bind/free the host-side responder based on whether we're actually hosting.
func _update_responder() -> void:
	var hosting := multiplayer.has_multiplayer_peer() and multiplayer.is_server() and not NetworkManager.is_offline
	if hosting and _responder == null:
		var u := PacketPeerUDP.new()
		if u.bind(Settings.DISCOVERY_PORT, "*") == OK:
			_responder = u
	elif not hosting and _responder != null:
		_responder.close()
		_responder = null

func _poll_responder() -> void:
	while _responder.get_available_packet_count() > 0:
		var pkt := _responder.get_packet()
		var from_ip := _responder.get_packet_ip()
		var from_port := _responder.get_packet_port()
		if pkt.get_string_from_utf8() != _DISCOVER_MSG:
			continue
		var reply := JSON.stringify({
			"name": NetworkManager.local_player_name,
			"port": Settings.DEFAULT_PORT,
			"players": GameState.peers.size(),
			"max": Settings.MAX_PLAYERS,
		})
		_responder.set_dest_address(from_ip, from_port)
		_responder.put_packet(reply.to_utf8_buffer())

## Broadcast a discovery ping and collect replies for `timeout` seconds. Sends to the
## broadcast address AND 127.0.0.1 so same-machine multi-instance testing is reliable.
func scan_lan(timeout: float = 1.5) -> void:
	if _scanner != null:
		_scanner.close()
	_found.clear()
	var u := PacketPeerUDP.new()
	u.set_broadcast_enabled(true)
	if u.bind(0, "*") != OK:
		return
	_scanner = u
	_scan_until_ms = Time.get_ticks_msec() + int(timeout * 1000.0)
	Events.lan_scan_started.emit()
	for addr in ["255.255.255.255", "127.0.0.1"]:
		_scanner.set_dest_address(addr, Settings.DISCOVERY_PORT)
		_scanner.put_packet(_DISCOVER_MSG.to_utf8_buffer())

func _poll_scanner() -> void:
	while _scanner.get_available_packet_count() > 0:
		var pkt := _scanner.get_packet()
		var from_ip := _scanner.get_packet_ip()
		var data: Variant = JSON.parse_string(pkt.get_string_from_utf8())
		if data is Dictionary:
			var port: int = int(data.get("port", Settings.DEFAULT_PORT))
			_found["%s:%d" % [from_ip, port]] = {
				"name": String(data.get("name", "Server")),
				"ip": from_ip,
				"port": port,
				"players": int(data.get("players", 0)),
				"max": int(data.get("max", Settings.MAX_PLAYERS)),
			}
	if Time.get_ticks_msec() >= _scan_until_ms:
		_scanner.close()
		_scanner = null
		last_found = _found.values()
		Events.lan_servers_found.emit(last_found)
