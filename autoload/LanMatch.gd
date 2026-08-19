extends Node

# Serverless multiplayer on a local network.
#
# The Nakama path needs an account, a server and a room code. On a LAN none of
# that is available or necessary: the players are on the same wire, so the game
# can find itself. This autoload provides the transport (a plain
# ENetMultiplayerPeer) plus a UDP broadcast beacon so that nobody has to type an
# IP address or open a port on their router.
#
# How discovery works:
#   - The host binds a PacketPeerUDP to DISCOVERY_PORT and answers every probe
#     it recognises with a small JSON advert (game id, host name, player count,
#     max players, and the ENet port the game itself listens on).
#   - A client binds an ephemeral UDP port, enables broadcast, and fires the
#     same probe at 255.255.255.255, at every local subnet broadcast address,
#     and at 127.0.0.1 (so two instances on one machine find each other even
#     where the OS does not loop broadcast traffic back). It then collects
#     replies for a second and a half.
#   - The address a client joins is the source address of the reply, so the
#     list is directly joinable: no IP field anywhere in the UI.
#
# Everything above the transport (OnlineMatch, Main, Game, ReadyScreen) is peer
# id based and knows nothing about Nakama, so LAN play reuses all of it: this
# class only installs the multiplayer peer, and OnlineMatch populates the same
# `players` dictionary and emits the same signals it always did.
#
# This is LAN only, by design. Playing across the internet without port
# forwarding needs a rendezvous/relay server, which is exactly the thing the
# Nakama mode already is.

# The port the game itself is played on. ENet, TCP-ish reliability over UDP.
const DEFAULT_GAME_PORT := 8676
# The port the beacon lives on. Fixed, because it is what makes discovery work
# with no configuration at all.
const DISCOVERY_PORT := 8677

# Bumped if the advert payload ever changes shape, so an old build and a new one
# do not show each other games they cannot join.
const PROTOCOL_ID := 'push_the_game_lan'
const PROTOCOL_VERSION := 1

const MSG_PROBE := 'probe'
const MSG_ADVERT := 'advert'

# How long discover_hosts() listens, and how often it repeats the probe while
# listening (UDP has no retransmission of its own).
const DISCOVERY_TIMEOUT := 1.5
const PROBE_INTERVAL := 0.4

# If the preferred game port is taken (a second host on the same machine), walk
# upwards rather than failing outright.
const PORT_FALLBACK_ATTEMPTS := 8

signal host_started (port)
signal host_stopped ()
signal hosts_discovered (hosts)
signal lan_error (message)

# True while this instance is hosting a LAN game.
var hosting := false
# The port the ENet server actually ended up on (may differ from the requested
# one when a fallback was used).
var game_port := 0
# Last failure, for callers that want to show it. Cleared by every successful
# host_lan()/join_lan().
var last_error := ''

# Set once per hosting session so a host answering probes on several interfaces
# is not listed several times.
var _host_id := ''

var _peer: ENetMultiplayerPeer = null
var _beacon: PacketPeerUDP = null
var _discovering := false

#####
# Payload encoding
#####

static func encode_message(data: Dictionary) -> PackedByteArray:
	return JSON.stringify(data).to_utf8_buffer()

# Never trusts the wire: anything that is not our protocol comes back as {}.
static func decode_message(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() == 0:
		return {}
	# JSON.parse_string() pushes an engine error on malformed input. A
	# well-known UDP port receives all sorts of traffic that is not ours, so
	# unparseable datagrams are normal and must stay quiet.
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return {}
	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	if parsed.get('game', '') != PROTOCOL_ID:
		return {}
	if int(parsed.get('v', 0)) != PROTOCOL_VERSION:
		return {}
	return parsed

static func build_probe() -> Dictionary:
	return {
		game = PROTOCOL_ID,
		v = PROTOCOL_VERSION,
		type = MSG_PROBE,
	}

# What a host tells the network about itself. Deliberately tiny: it has to fit
# in one datagram and it is sent to anyone who asks.
func build_advert() -> Dictionary:
	return {
		game = PROTOCOL_ID,
		v = PROTOCOL_VERSION,
		type = MSG_ADVERT,
		id = _host_id,
		name = _host_name(),
		port = game_port,
		players = _player_count(),
		max_players = _max_players(),
		open = _is_open(),
	}

# Turns a received advert into the entry shape discover_hosts() returns.
static func advert_to_host_entry(advert: Dictionary, address: String) -> Dictionary:
	return {
		id = str(advert.get('id', '')),
		name = str(advert.get('name', 'LAN game')),
		address = address,
		port = int(advert.get('port', DEFAULT_GAME_PORT)),
		players = int(advert.get('players', 0)),
		max_players = int(advert.get('max_players', 0)),
		open = bool(advert.get('open', true)),
	}

#####
# Hosting
#####

# Starts an ENet server and begins answering discovery probes.
#
# `max_clients` of 0 means "derive it from OnlineMatch.max_players" (the host
# occupies one of those slots). Set `allow_port_fallback` to false to insist on
# exactly the port asked for.
func host_lan(port: int = DEFAULT_GAME_PORT, max_clients: int = 0, allow_port_fallback: bool = true) -> bool:
	# A stale peer from a previous match would otherwise keep the port and make
	# hosting a second time in one session fail with "address in use".
	stop_lan()
	last_error = ''

	if max_clients <= 0:
		max_clients = max(1, _max_players() - 1)

	var peer := ENetMultiplayerPeer.new()
	var attempts := PORT_FALLBACK_ATTEMPTS if allow_port_fallback else 1
	var err := ERR_CANT_CREATE
	var chosen := port

	for i in range(attempts):
		chosen = port + i
		err = peer.create_server(chosen, max_clients)
		if err == OK:
			break

	if err != OK:
		last_error = "Could not host on port %d (error %d)" % [port, err]
		emit_signal("lan_error", last_error)
		return false

	_peer = peer
	game_port = chosen
	hosting = true
	_host_id = _generate_host_id()
	get_tree().get_multiplayer().multiplayer_peer = peer

	_start_beacon()

	emit_signal("host_started", game_port)
	return true

# The beacon is a nicety, not the game: if the discovery port is taken (another
# instance on this machine is already hosting) we keep hosting anyway, we are
# just not listed. Callers can see why in last_error.
func _start_beacon() -> void:
	_stop_beacon()

	var beacon := PacketPeerUDP.new()
	var err := beacon.bind(DISCOVERY_PORT)
	if err != OK:
		last_error = "Discovery port %d is busy - this game will not be listed" % DISCOVERY_PORT
		push_warning(last_error)
		return

	# Replies go straight back to whoever probed us, but the socket may also be
	# asked to talk to a broadcast address on some platforms.
	beacon.set_broadcast_enabled(true)
	_beacon = beacon

func _stop_beacon() -> void:
	if _beacon != null:
		_beacon.close()
		_beacon = null

#####
# Joining
#####

func join_lan(address: String, port: int = DEFAULT_GAME_PORT) -> bool:
	stop_lan()
	last_error = ''

	address = address.strip_edges()
	if address == '':
		last_error = "No address to join"
		emit_signal("lan_error", last_error)
		return false

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		last_error = "Could not reach %s:%d (error %d)" % [address, port, err]
		emit_signal("lan_error", last_error)
		return false

	_peer = peer
	game_port = port
	get_tree().get_multiplayer().multiplayer_peer = peer
	return true

#####
# Teardown
#####

# Drops the beacon and the multiplayer peer. Safe to call when nothing is
# running, and safe to call twice.
func stop_lan() -> void:
	var was_hosting := hosting

	_stop_beacon()

	if _peer != null:
		var multiplayer_api := get_tree().get_multiplayer()
		# Detach before closing, so tearing down does not fire a storm of
		# peer_disconnected signals back into OnlineMatch while it is already
		# leaving the match.
		if multiplayer_api.multiplayer_peer == _peer:
			multiplayer_api.multiplayer_peer = null
		_peer.close()
		_peer = null

	hosting = false
	game_port = 0
	_host_id = ''

	if was_hosting:
		emit_signal("host_stopped")

func is_active() -> bool:
	return _peer != null

#####
# Discovery
#####

# Broadcasts a probe and collects replies for `timeout` seconds.
#
# Awaitable: `var hosts = await LanMatch.discover_hosts()`. Also emits
# hosts_discovered for callers that prefer signals. Each entry is
# {id, name, address, port, players, max_players, open} and `address`/`port`
# can be handed straight to join_lan().
func discover_hosts(timeout: float = DISCOVERY_TIMEOUT) -> Array:
	if _discovering:
		# Never run two searches at once: they would fight over the same reply
		# packets. Second caller rides along with the first.
		return await hosts_discovered

	_discovering = true
	var found := {}

	var socket := PacketPeerUDP.new()
	var err := socket.bind(0)
	if err != OK:
		_discovering = false
		last_error = "Could not open a socket to search the network (error %d)" % err
		emit_signal("lan_error", last_error)
		emit_signal("hosts_discovered", [])
		return []

	socket.set_broadcast_enabled(true)

	var probe := encode_message(build_probe())
	var targets := _probe_targets()
	if targets.size() == 0:
		last_error = "No network interface to search on"
		emit_signal("lan_error", last_error)

	var started := Time.get_ticks_msec()
	var next_probe := 0
	var deadline := int(max(0.0, timeout) * 1000.0)

	while Time.get_ticks_msec() - started < deadline:
		var now := Time.get_ticks_msec()
		if now >= next_probe:
			next_probe = now + int(PROBE_INTERVAL * 1000.0)
			for target in targets:
				# A refused target (an interface that cannot broadcast) must not
				# abort the whole search.
				if socket.set_dest_address(target, DISCOVERY_PORT) == OK:
					socket.put_packet(probe)

		_collect_replies(socket, found)
		await get_tree().process_frame

	# One last sweep for replies that landed on the final frame.
	_collect_replies(socket, found)
	socket.close()

	var hosts := found.values()
	_discovering = false
	emit_signal("hosts_discovered", hosts)
	return hosts

func _collect_replies(socket: PacketPeerUDP, found: Dictionary) -> void:
	while socket.get_available_packet_count() > 0:
		var bytes := socket.get_packet()
		var address := socket.get_packet_ip()
		var message := decode_message(bytes)
		if message.get('type', '') != MSG_ADVERT:
			continue
		var entry := advert_to_host_entry(message, address)
		if entry.port <= 0:
			continue
		# A host that answers on several interfaces is one game, not several.
		var key: String = entry.id if entry.id != '' else "%s:%d" % [entry.address, entry.port]
		if not found.has(key):
			found[key] = entry

# Where to aim the probe. The global broadcast address is refused by some
# stacks, the per-interface one by others, and neither necessarily loops back to
# another process on this machine -- so we use all three.
func _probe_targets() -> Array:
	var targets := ['255.255.255.255', '127.0.0.1']
	for address in IP.get_local_addresses():
		if address.contains(':'):
			continue  # IPv6 has no broadcast.
		if address.begins_with('127.'):
			continue
		var parts := address.split('.')
		if parts.size() != 4:
			continue
		var subnet_broadcast := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
		if not targets.has(subnet_broadcast):
			targets.append(subnet_broadcast)
	return targets

#####
# Beacon pump
#####

func _process(_delta: float) -> void:
	if _beacon == null:
		return

	while _beacon.get_available_packet_count() > 0:
		var bytes := _beacon.get_packet()
		var from_ip := _beacon.get_packet_ip()
		var from_port := _beacon.get_packet_port()
		var message := decode_message(bytes)
		if message.get('type', '') != MSG_PROBE:
			continue
		if _beacon.set_dest_address(from_ip, from_port) != OK:
			continue
		_beacon.put_packet(encode_message(build_advert()))

#####
# Details the advert needs, kept tolerant so this class can be used on its own
# (the tests drive it without a match in progress).
#####

func _host_name() -> String:
	var name: String = Online.display_name.strip_edges()
	if name == '':
		name = 'LAN game'
	return name

func _player_count() -> int:
	# Hosting alone still counts as one player, even before OnlineMatch has
	# registered anybody.
	return max(1, OnlineMatch.players.size())

func _max_players() -> int:
	return OnlineMatch.max_players

func _is_open() -> bool:
	return OnlineMatch.match_state != OnlineMatch.MatchState.PLAYING \
		and _player_count() < _max_players()

func _generate_host_id() -> String:
	var characters := '0123456789abcdef'
	var result := ''
	for i in range(12):
		result += characters[randi() % characters.length()]
	return result
