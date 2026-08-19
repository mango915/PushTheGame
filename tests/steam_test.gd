extends Node

# Guards the Steam transport (autoload/SteamMatch.gd) on a machine where
# GodotSteam is NOT installed -- which is every machine this project currently
# builds on, and the state the game ships in.
#
# So this is not a test of Steam multiplayer. It cannot be: there is no Steam
# singleton, no Steamworks SDK and no Steam client here. It is a test of the
# guard rails, and those are the part that can break the game for everybody:
#
#   - nothing may name the `Steam` singleton or `SteamMultiplayerPeer` in a way
#     that fails to resolve when they are absent,
#   - every Steam entry point must refuse cleanly (false + a message) rather
#     than erroring,
#   - no Steam code may install a multiplayer peer, touch the Nakama socket, or
#     otherwise disturb the two transports that do work here.
#
# The one piece of real Steam-facing logic that IS testable without Steam is the
# signal adapter: GodotSteam has changed the arity of its callbacks between
# versions (lobby_joined grew a `response` field), and connecting a callable of
# the wrong arity is a hard error in Godot 4. That is exercised below against a
# local object with signals of known shape.

var _failures := 0

# Filled in by the signal-adapter checks.
var _adapter_args := []

class SignalDummy extends Node:
	signal two_args (a, b)
	signal four_args (a, b, c, d)

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[steam] OK: %s" % label)
	else:
		_failures += 1
		print("[steam] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[steam] starting")

	_check_autoload()
	_check_unavailable()
	_check_refuses_to_host_and_join()
	_check_friends_and_invites()
	_check_leave_is_safe()
	_check_command_line_invites()
	_check_signal_adapter()
	_check_match_modes()
	_check_online_match_entry_points()
	_check_match_screen_ui()
	_check_other_transports_untouched()

	print("[steam] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

#####
# The autoload has to exist, and OnlineMatch has to be able to find it.
#####

func _check_autoload() -> void:
	var steam_match := get_node_or_null("/root/SteamMatch")
	_check_true("SteamMatch autoload is registered", steam_match != null)
	_check_true("SteamMatch is the script we expect", steam_match != null and steam_match.has_method("host_lobby"))

#####
# With no GodotSteam, every read-only accessor has to answer honestly and
# quietly.
#####

func _check_unavailable() -> void:
	_check("is_available() is false without GodotSteam", SteamMatch.is_available(), false)
	_check("has_multiplayer_peer() is false without GodotSteam", SteamMatch.has_multiplayer_peer(), false)
	_check("is_ready() is false", SteamMatch.is_ready(), false)
	_check("is_steam_running() is false", SteamMatch.is_steam_running(), false)
	_check("no persona name", SteamMatch.get_persona_name(), "")
	_check("no steam id", SteamMatch.get_steam_id(), 0)
	_check("no lobby", SteamMatch.current_lobby, 0)
	_check("not hosting", SteamMatch.hosting, false)
	_check("not active", SteamMatch.is_active(), false)
	_check("not waiting on Steam for anything", SteamMatch.is_busy(), false)

	# The UI shows this string instead of a dead button with no explanation.
	_check("status explains why Steam is off", SteamMatch.status_text(),
		SteamMatch.UNAVAILABLE_MESSAGE)

	# initialize() must fail rather than reach for a singleton that is not there.
	var errors := _collect_errors()
	_check("initialize() fails without GodotSteam", SteamMatch.initialize(), false)
	_check("initialize() explains itself once", errors.size(), 1)
	_check("initialize() error names the extension", SteamMatch.last_error,
		SteamMatch.UNAVAILABLE_MESSAGE)
	_stop_collecting_errors()

#####
# Hosting and joining must refuse, not crash, and must leave the engine's
# multiplayer peer alone.
#####

func _check_refuses_to_host_and_join() -> void:
	var errors := _collect_errors()

	_check("host_lobby() refuses", SteamMatch.host_lobby(), false)
	_check("join_lobby() refuses", SteamMatch.join_lobby(109775240000000000), false)
	_check("join_lobby(0) refuses", SteamMatch.join_lobby(0), false)

	_check("each refusal reported exactly one error", errors.size(), 3)
	_check_true("an error message is not empty", str(errors[0]) != "")
	_stop_collecting_errors()

	_check("still no lobby", SteamMatch.current_lobby, 0)
	_check("still not hosting", SteamMatch.hosting, false)
	# A refused request must not leave the "waiting on Steam" state latched on,
	# or the UI would show "Talking to Steam..." forever.
	_check("no request left pending", SteamMatch.is_busy(), false)
	_check("no multiplayer peer was installed", _active_peer_kind(), "none")

#####
# Friends and invites.
#####

func _check_friends_and_invites() -> void:
	var friends := SteamMatch.get_friends()
	_check("get_friends() is an Array", typeof(friends), TYPE_ARRAY)
	_check("get_friends() is empty without Steam", friends.size(), 0)

	# refresh_friends() must still announce, so a UI waiting on the signal does
	# not hang waiting for a list that will never come.
	var announced := []
	var handler := func(list): announced.append(list)
	SteamMatch.friends_updated.connect(handler)
	SteamMatch.refresh_friends()
	SteamMatch.friends_updated.disconnect(handler)
	_check("refresh_friends() still emits friends_updated", announced.size(), 1)
	_check("the announced list is empty", (announced[0] as Array).size(), 0)

	var errors := _collect_errors()
	_check("invite_friend() refuses", SteamMatch.invite_friend(76561197960287930), false)
	_check("open_invite_overlay() refuses", SteamMatch.open_invite_overlay(), false)
	_check("both refusals were reported", errors.size(), 2)
	_stop_collecting_errors()

#####
# leave() is called unconditionally from OnlineMatch.leave(), so it has to be a
# no-op when nothing is running and safe to repeat.
#####

func _check_leave_is_safe() -> void:
	var left := []
	var handler := func(): left.append(true)
	SteamMatch.lobby_left.connect(handler)

	SteamMatch.leave()
	SteamMatch.leave()

	SteamMatch.lobby_left.disconnect(handler)
	_check("leave() with no lobby is silent", left.size(), 0)
	_check("leave() leaves no lobby behind", SteamMatch.current_lobby, 0)
	_check("leave() did not install a peer", _active_peer_kind(), "none")

#####
# `+connect_lobby <id>` is how Steam starts the game when an invite is accepted
# while the game is closed. Pure parsing, so it is testable here.
#####

func _check_command_line_invites() -> void:
	_check("parses +connect_lobby",
		SteamMatch.parse_command_line_lobby(["+connect_lobby", "109775241234567890"]),
		109775241234567890)
	_check("parses the =-joined form",
		SteamMatch.parse_command_line_lobby(["+connect_lobby=42"]), 42)
	_check("ignores an unrelated command line",
		SteamMatch.parse_command_line_lobby(["--headless", "res://tests/SteamTest.tscn"]), 0)
	_check("ignores an empty command line",
		SteamMatch.parse_command_line_lobby([]), 0)
	_check("ignores a missing id",
		SteamMatch.parse_command_line_lobby(["+connect_lobby"]), 0)
	_check("ignores a non-numeric id",
		SteamMatch.parse_command_line_lobby(["+connect_lobby", "not-a-lobby"]), 0)
	_check("ignores a zero id",
		SteamMatch.parse_command_line_lobby(["+connect_lobby", "0"]), 0)

	# Nothing pending in this run, so accepting must be a no-op rather than a
	# join attempt.
	_check("accept_pending_invite() is a no-op with nothing pending",
		SteamMatch.accept_pending_invite(), false)

#####
# The signal adapter. This is what keeps us compatible with more than one
# GodotSteam version without a build of it to test against.
#####

func _check_signal_adapter() -> void:
	var dummy := SignalDummy.new()
	add_child(dummy)

	_check("signal_arity reads a 2-argument signal",
		SteamMatch.signal_arity(dummy, "two_args"), 2)
	_check("signal_arity reads a 4-argument signal",
		SteamMatch.signal_arity(dummy, "four_args"), 4)
	_check("signal_arity reports an absent signal",
		SteamMatch.signal_arity(dummy, "no_such_signal"), -1)
	_check("signal_arity tolerates a null object",
		SteamMatch.signal_arity(null, "two_args"), -1)

	_check("connect_adapting refuses an absent signal",
		SteamMatch.connect_adapting(dummy, "no_such_signal", Callable(self, "_record_two"), 2), false)
	_check("connect_adapting refuses a null object",
		SteamMatch.connect_adapting(null, "two_args", Callable(self, "_record_two"), 2), false)

	# A signal that carries MORE than the handler takes: the extra arguments
	# must be unbound, or Godot rejects the connection outright.
	_adapter_args = []
	_check_true("connects a 2-argument handler to a 4-argument signal",
		SteamMatch.connect_adapting(dummy, "four_args", Callable(self, "_record_two"), 2))
	dummy.emit_signal("four_args", 11, 22, 33, 44)
	_check("the handler ran", _adapter_args.size(), 2)
	if _adapter_args.size() == 2:
		_check("it got the leading arguments", _adapter_args, [11, 22])

	# A signal that carries FEWER than the handler takes: the handler's default
	# values have to cover the difference. This is the older-GodotSteam case.
	_adapter_args = []
	_check_true("connects a 4-argument handler to a 2-argument signal",
		SteamMatch.connect_adapting(dummy, "two_args", Callable(self, "_record_four"), 4))
	dummy.emit_signal("two_args", 7, 8)
	_check("the handler ran", _adapter_args.size(), 4)
	if _adapter_args.size() == 4:
		_check("the missing arguments defaulted", _adapter_args, [7, 8, -1, -1])

	dummy.queue_free()

func _record_two(a, b) -> void:
	_adapter_args = [a, b]

func _record_four(a, b, c = -1, d = -1) -> void:
	_adapter_args = [a, b, c, d]

#####
# The MatchMode additions.
#####

func _check_match_modes() -> void:
	_check("STEAM_HOST does not collide with LAN_HOST",
		OnlineMatch.MatchMode.STEAM_HOST != OnlineMatch.MatchMode.LAN_HOST, true)
	_check("STEAM_JOIN does not collide with LAN_JOIN",
		OnlineMatch.MatchMode.STEAM_JOIN != OnlineMatch.MatchMode.LAN_JOIN, true)
	_check("STEAM_HOST and STEAM_JOIN differ",
		OnlineMatch.MatchMode.STEAM_HOST != OnlineMatch.MatchMode.STEAM_JOIN, true)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.STEAM_HOST
	_check_true("is_steam() while hosting on Steam", OnlineMatch.is_steam())
	_check("is_lan() is false while hosting on Steam", OnlineMatch.is_lan(), false)
	_check_true("Steam counts as a peer transport", OnlineMatch.is_peer_transport())
	_check("match id is the Steam placeholder", OnlineMatch.get_match_id(),
		OnlineMatch.STEAM_MATCH_ID)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.STEAM_JOIN
	_check_true("is_steam() while joining on Steam", OnlineMatch.is_steam())

	OnlineMatch.match_mode = OnlineMatch.MatchMode.LAN_HOST
	_check("is_steam() is false on a LAN", OnlineMatch.is_steam(), false)
	_check_true("LAN still counts as a peer transport", OnlineMatch.is_peer_transport())

	OnlineMatch.match_mode = OnlineMatch.MatchMode.CREATE
	_check("Nakama is not a peer transport", OnlineMatch.is_peer_transport(), false)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.NONE

	# Steam players get a synthetic session id of their own, so a stray Steam
	# player can never be mistaken for a LAN one in the lobby.
	var steam_player = OnlineMatch.Player.from_steam(3, "Kuba", 2)
	_check("a Steam player is tagged as such", steam_player.session_id, "steam-3")
	_check("a Steam player keeps their name", steam_player.username, "Kuba")
	_check("a Steam player keeps their character", steam_player.character, 2)

	# The LAN factory must not have changed shape: lan_test.gd depends on it.
	var lan_player = OnlineMatch.Player.from_lan(3, "Kuba")
	_check("a LAN player is still tagged lan-", lan_player.session_id, "lan-3")
	_check("an unnamed player still gets a fallback",
		OnlineMatch.Player.from_steam(5, "   ").username, "Player 5")

#####
# OnlineMatch's Steam entry points, from the outside.
#####

func _check_online_match_entry_points() -> void:
	_check("steam_is_available() is false", OnlineMatch.steam_is_available(), false)

	var errors := _collect_match_errors()

	_check("host_steam_match() refuses", OnlineMatch.host_steam_match(), false)
	_check("host_steam_match() reported exactly one error", errors.size(), 1)
	_check("host_steam_match() reset the mode", OnlineMatch.match_mode,
		OnlineMatch.MatchMode.NONE)
	_check("host_steam_match() reset the state", OnlineMatch.match_state,
		OnlineMatch.MatchState.LOBBY)

	errors.clear()
	_check("join_steam_match() refuses", OnlineMatch.join_steam_match(109775241234567890), false)
	_check("join_steam_match() reported exactly one error", errors.size(), 1)
	_check("join_steam_match() reset the mode", OnlineMatch.match_mode,
		OnlineMatch.MatchMode.NONE)

	_stop_collecting_match_errors()

	_check("no peer after a refused Steam match", _active_peer_kind(), "none")
	_check("no players after a refused Steam match", OnlineMatch.players.size(), 0)

#####
# The match screen. The requirement is that the Steam section is *visible* and
# disabled with a reason, not hidden: a section that silently disappears looks
# like a missing feature rather than a missing extension.
#####

func _check_match_screen_ui() -> void:
	var screen = load("res://main/screens/MatchScreen.tscn").instantiate()
	add_child(screen)
	screen._show_screen({})

	var panel = screen.get_node_or_null("PanelContainer/VBoxContainer/SteamPanel")
	_check_true("the match screen has a Steam section", panel != null)
	if panel == null:
		_free_screen(screen)
		return

	_check_true("the Steam section is visible", panel.visible)
	_check("the Steam section says why it is off",
		panel.get_node("StatusLabel").text, SteamMatch.UNAVAILABLE_MESSAGE)
	_check_true("HOST ON STEAM is disabled", panel.get_node("SteamHostButton").disabled)
	_check_true("INVITE FRIENDS is disabled", panel.get_node("SteamInviteButton").disabled)
	_check_true("the friends list button is disabled", panel.get_node("SteamFriendsButton").disabled)

	# The LAN section next to it must be untouched: still there, still enabled.
	var lan_panel = screen.get_node_or_null("PanelContainer/VBoxContainer/LanPanel")
	_check_true("the LAN section is still there", lan_panel != null)
	if lan_panel != null:
		_check("HOST LAN is still enabled", lan_panel.get_node("LanHostButton").disabled, false)
		_check("FIND GAMES is still enabled", lan_panel.get_node("LanFindButton").disabled, false)

	# The in-game friend browser has to explain itself too, rather than showing
	# an empty list that looks like "you have no friends".
	_check("browsing friends with no Steam shows the reason",
		_friend_browser_status(screen), SteamMatch.UNAVAILABLE_MESSAGE)

	_free_screen(screen)

	# The ready screen carries the invite button, because that is where the host
	# waits and a Steam match has no room code to read out instead.
	var ready_screen = load("res://main/screens/ReadyScreen.tscn").instantiate()
	add_child(ready_screen)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.NONE
	ready_screen._show_screen({})
	_check("no Steam invite button outside a Steam match",
		ready_screen.steam_invite_button.visible, false)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.STEAM_HOST
	ready_screen._show_screen({})
	_check_true("the Steam invite button appears in a Steam lobby",
		ready_screen.steam_invite_button.visible)
	OnlineMatch.match_mode = OnlineMatch.MatchMode.NONE

	_free_screen(ready_screen)

# Freed immediately rather than with queue_free(): this whole test runs inside
# one _ready(), so a queued node is still alive -- and still connected to
# OnlineMatch.match_joined -- when the LAN checks below start a match. It would
# then run its handlers with no UILayer attached.
func _free_screen(screen) -> void:
	remove_child(screen)
	screen.free()

# Opens the in-game friend browser and reads back what it told the player.
func _friend_browser_status(screen) -> String:
	screen._refresh_steam_friends()
	return str(screen.get_node("SteamBrowser/VBoxContainer/StatusLabel").text)

#####
# The regression that actually matters: adding a transport must not disturb the
# two that work.
#####

func _check_other_transports_untouched() -> void:
	# Nakama is untouched: nothing above ever built a socket or a bridge.
	_check("no Nakama socket was opened", OnlineMatch.nakama_socket, null)
	_check("no Nakama bridge was built", OnlineMatch.nakama_multiplayer_bridge, null)

	# leave() calls into Steam unconditionally; it still has to clear the match.
	OnlineMatch.players[42] = OnlineMatch.Player.new("session-42", "ghost", 42)
	OnlineMatch.match_mode = OnlineMatch.MatchMode.STEAM_HOST
	OnlineMatch.match_state = OnlineMatch.MatchState.PLAYING
	OnlineMatch.leave()
	_check("leave() clears the players", OnlineMatch.players.size(), 0)
	_check("leave() resets the state", OnlineMatch.match_state, OnlineMatch.MatchState.LOBBY)
	_check("leave() resets the mode", OnlineMatch.match_mode, OnlineMatch.MatchMode.NONE)
	_check("leave() left Nakama alone", OnlineMatch.nakama_socket, null)
	_check("leave() left no peer behind", _active_peer_kind(), "none")

	# LAN still works end to end on this side of the wire: it hosts, it reports
	# itself as a LAN match, and it tears down. (tests/lantest.sh covers the
	# two-instance case; this only guards against the Steam changes breaking the
	# shared code paths they now run through.)
	var hosted: bool = OnlineMatch.host_lan_match(LanMatch.DEFAULT_GAME_PORT + 40)
	_check_true("LAN hosting still works", hosted)
	if hosted:
		_check_true("a LAN match is a LAN match", OnlineMatch.is_lan())
		_check("is_steam() is false on a LAN match", OnlineMatch.is_steam(), false)
		_check("the LAN match id is unchanged", OnlineMatch.get_match_id(),
			OnlineMatch.LAN_MATCH_ID)
		_check("the LAN host registered itself", OnlineMatch.players.size(), 1)
		var host_player = OnlineMatch.players.get(1)
		_check_true("the LAN host is peer 1 with a lan- session id",
			host_player != null and str(host_player.session_id).begins_with("lan-"))

	OnlineMatch.leave()
	_check("leaving a LAN match clears it", OnlineMatch.is_lan(), false)
	_check("leaving a LAN match drops the peer", _active_peer_kind(), "none")

# What transport, if any, is actually installed on the engine's MultiplayerAPI.
#
# "Nothing" is not simply null: Godot substitutes an OfflineMultiplayerPeer once
# a peer has been detached (which every leave() path does), and that is still
# the absence of networking. Anything else is a live transport and would mean
# the Steam code installed one it had no business installing.
func _active_peer_kind() -> String:
	var peer = get_tree().get_multiplayer().multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return "none"
	return peer.get_class()

#####
# Error collection helpers. Steam failures are reported by signal, and "it fails
# quietly" and "it fails loudly enough for the UI" are both requirements.
#####

var _collected_errors := []
var _collecting_steam := false
var _collecting_match := false

func _collect_errors() -> Array:
	_collected_errors = []
	if not _collecting_steam:
		SteamMatch.steam_error.connect(Callable(self, "_on_error"))
		_collecting_steam = true
	return _collected_errors

func _stop_collecting_errors() -> void:
	if _collecting_steam:
		SteamMatch.steam_error.disconnect(Callable(self, "_on_error"))
		_collecting_steam = false

func _collect_match_errors() -> Array:
	_collected_errors = []
	if not _collecting_match:
		OnlineMatch.error.connect(Callable(self, "_on_error"))
		_collecting_match = true
	return _collected_errors

func _stop_collecting_match_errors() -> void:
	if _collecting_match:
		OnlineMatch.error.disconnect(Callable(self, "_on_error"))
		_collecting_match = false

func _on_error(message) -> void:
	_collected_errors.append(str(message))
