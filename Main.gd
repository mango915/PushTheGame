extends Node2D

# Must match the id created in nakama/data/modules/fish_game.lua.
const LEADERBOARD_ID := 'push_the_game_wins'

@onready var game = $Game
@onready var ui_layer: UILayer = $UILayer
@onready var ready_screen = $UILayer/Screens/ReadyScreen
@onready var music := $Music

var players := {}

var players_ready := {}
var players_score := {}

var match_started := false

func _ready() -> void:
	OnlineMatch.error.connect(Callable(self, "_on_OnlineMatch_error"))
	OnlineMatch.disconnected.connect(Callable(self, "_on_OnlineMatch_disconnected"))
	OnlineMatch.player_joined.connect(Callable(self, "_on_OnlineMatch_player_joined"))
	OnlineMatch.player_left.connect(Callable(self, "_on_OnlineMatch_player_left"))

	# Only the host ever calls start_game(), so this is the one thing that tells
	# a client who is in the round. Connected in code rather than in Main.tscn so
	# the wiring lives next to the handler that depends on it.
	game.roster_updated.connect(Callable(self, "_on_Game_roster_updated"))

	# Accepting a Steam invite has to switch the game into online mode by
	# itself: the player never passed through the title screen's PLAY ONLINE
	# button, so nothing else has set GameState.online_play. OnlineMatch does
	# the joining (it listens for the same signal); this only prepares the UI.
	SteamMatch.invite_accepted.connect(Callable(self, "_on_SteamMatch_invite_accepted"))

	randomize()
	music.play_random()

	# Steam launches the game with `+connect_lobby <id>` when an invite is
	# accepted while the game is closed. Deferred so every autoload is up.
	call_deferred("_join_pending_steam_invite")

#####
# UI callbacks
#####

func _on_TitleScreen_play_local() -> void:
	GameState.online_play = false

	ui_layer.hide_screen()
	ui_layer.show_back_button()

	start_game()

func _on_TitleScreen_play_online() -> void:
	GameState.online_play = true

	# Show the game map in the background because we have nothing better.
	game.reload_map()

	# MatchScreen offers both transports: Nakama rooms/matchmaking, and LAN play
	# (autoload/LanMatch.gd), which needs no server, no account and no port
	# forwarding. So the screen is shown FIRST and the Nakama sign-in happens
	# behind it -- previously a missing or unreachable server bounced the player
	# to ConnectionScreen and there was no way to reach LAN play at all.
	ui_layer.hide_screen()
	ui_layer.show_screen("MatchScreen")

	_sign_in_for_online_play()

# Signs in silently with a device identity so playing online does not require
# creating an account. The email/password screen is only a fallback now, reached
# from the message below rather than automatically.
#
# Deliberately not awaited by the caller: the LAN buttons must be usable while
# this is still waiting on (or timing out against) the server. The online
# buttons re-check the session themselves in MatchScreen._on_match_button_pressed.
func _sign_in_for_online_play() -> void:
	if Online.has_valid_session():
		return

	ui_layer.show_message("Signing in...")
	var signed_in: bool = await Online.ensure_session()

	# The player may have moved on (or started a LAN game) while we waited.
	if ui_layer.current_screen_name != 'MatchScreen':
		return

	if signed_in:
		ui_layer.hide_message()
	else:
		# Server host/port is editable on SettingsScreen; the LAN buttons on
		# MatchScreen work regardless.
		ui_layer.show_message("No server - LAN games still work")

func _on_SteamMatch_invite_accepted(_lobby_id: int, _friend_steam_id: int) -> void:
	GameState.online_play = true

	# Show the game map in the background, exactly as PLAY ONLINE does.
	game.reload_map()

	ui_layer.hide_screen()
	ui_layer.show_message("Joining your friend's Steam game...")

func _join_pending_steam_invite() -> void:
	# Raises invite_accepted, which OnlineMatch turns into a join and the
	# handler above turns into the online-mode UI. Does nothing at all in the
	# normal case where the game was started by hand.
	SteamMatch.accept_pending_invite()

func _on_UILayer_change_screen(name: String, _screen) -> void:
	if name == 'TitleScreen':
		ui_layer.hide_back_button()
	else:
		ui_layer.show_back_button()

	if name != 'ReadyScreen':
		if match_started:
			match_started = false
			music.play_random()

func _on_UILayer_back_button() -> void:
	ui_layer.hide_message()

	stop_game()

	if GameState.online_play:
		OnlineMatch.leave()

	if ui_layer.current_screen_name in ['ConnectionScreen', 'MatchScreen', 'CreditsScreen']:
		ui_layer.show_screen("TitleScreen")
	elif not GameState.online_play:
		ui_layer.show_screen("TitleScreen")
	else:
		ui_layer.show_screen("MatchScreen")

func _on_ReadyScreen_ready_pressed() -> void:
	rpc("player_ready", get_tree().get_multiplayer().get_unique_id())

#####
# OnlineMatch callbacks
#####

func _on_OnlineMatch_error(message: String):
	# Every exit from a match goes through here, so this is where the round has
	# to be torn down: stop_game() is what clears players_score (otherwise the
	# scores of an abandoned match leak into the next one) and what stops the
	# abandoned round simulating -- and RPCing into a dead bridge -- behind the
	# menu.
	stop_game()

	if message != '':
		ui_layer.show_message(message)
	ui_layer.show_screen("MatchScreen")

func _on_OnlineMatch_disconnected():
	#_on_OnlineMatch_error("Disconnected from host")
	_on_OnlineMatch_error('')

func _on_OnlineMatch_player_left(player) -> void:
	game.kill_player(player.peer_id)

	players.erase(player.peer_id)
	players_ready.erase(player.peer_id)

	# `players` is only populated when a round starts, so while sitting in the
	# lobby it is empty and this test would fire on ANY departure -- tearing
	# down the match and kicking the host out of their own room the moment a
	# friend backed out. Only abandon a match that is actually in progress; in
	# the lobby, ReadyScreen already disables Ready via match_not_ready.
	if game.game_started and players.size() < 2:
		# _on_OnlineMatch_error() leaves the match and stops the game.
		_on_OnlineMatch_error(player.username + " has left - not enough players!")
	else:
		ui_layer.show_message(player.username + " has left")

func _on_OnlineMatch_player_joined(player) -> void:
	if get_tree().get_multiplayer().is_server():
		# Tell this new player about all the other players that are already
		# ready. players_ready is keyed by peer id and its values are plain
		# `true`, so this iterates the keys -- `true.peer_id` was a runtime error
		# that aborted the loop -- and the message goes to the new arrival, not
		# back to the player who was already ready.
		for ready_peer_id in players_ready:
			rpc_id(player.peer_id, "player_ready", ready_peer_id)

#####
# Gameplay methods and callbacks
#####

# Emitted by Game._do_game_setup on every peer, which is the only roster message
# a client ever receives. Without this, `players` stayed empty on clients all
# match, so the "not enough players" check in _on_OnlineMatch_player_left fired
# on any departure and threw every client back to the match screen.
func _on_Game_roster_updated(roster: Dictionary) -> void:
	players = roster.duplicate()

	if GameState.online_play and OnlineMatch.match_state != OnlineMatch.MatchState.PLAYING:
		# The round is starting on this peer. The host now refuses new arrivals
		# ("the match has already begun"), so a client that still thought it was
		# in READY would have added that rejected peer to its own lobby.
		OnlineMatch.start_playing()

# `peer_id` says whose READY! label to light up -- the host uses it to catch a
# newcomer up on players who were already ready. It is NOT trusted for the
# tally: one client could otherwise mark every other player ready and force the
# round to start.
@rpc("any_peer", "call_local") func player_ready(peer_id: int) -> void:
	ready_screen.set_status(peer_id, "READY!")

	if not get_tree().get_multiplayer().is_server():
		return

	# 0 means this was not a remote call, i.e. the host pressing its own button.
	var sender_id: int = get_tree().get_multiplayer().get_remote_sender_id()
	if sender_id == 0:
		sender_id = get_tree().get_multiplayer().get_unique_id()

	if players_ready.has(sender_id):
		return

	players_ready[sender_id] = true
	if players_ready.size() == OnlineMatch.players.size():
		if OnlineMatch.match_state != OnlineMatch.MatchState.PLAYING:
			OnlineMatch.start_playing()
		start_game()

func start_game() -> void:
	var characters := {}
	if GameState.online_play:
		players = OnlineMatch.get_player_names_by_peer_id()
		for peer_id in OnlineMatch.players:
			characters[peer_id] = OnlineMatch.players[peer_id].character
	else:
		players = {
			1: "Player1",
			2: "Player2",
		}
		# Local players share one machine and cannot each pick, so give them
		# distinct characters starting from whatever this profile chose.
		var index := 0
		for peer_id in players:
			characters[peer_id] = (Online.character_index + index) % 4
			index += 1

	game.game_start(players, characters)

# Full teardown: leaves the match and forgets the scoreboard. `reset_score` is
# false only between the rounds of a match still in progress, which is the one
# case where the running score has to survive.
func stop_game(reset_score: bool = true) -> void:
	OnlineMatch.leave()

	players.clear()
	players_ready.clear()
	if reset_score:
		players_score.clear()

	game.game_stop()

func restart_game() -> void:
	stop_game(false)
	start_game()

func _on_game_started_signal() -> void:
	ui_layer.hide_screen()
	ui_layer.hide_all()
	ui_layer.show_back_button()

	if not match_started:
		match_started = true
		music.play_random()

func _on_player_dead(peer_id: int) -> void:
	if GameState.online_play:
		var my_id = get_tree().get_multiplayer().get_unique_id()
		if peer_id == my_id:
			ui_layer.show_message("You lose!")

# Adds a round win to the scoreboard and reports the new total.
func _record_win(peer_id: int) -> int:
	players_score[peer_id] = int(players_score.get(peer_id, 0)) + 1
	return players_score[peer_id]

func _on_game_over_signal(peer_id: int) -> void:
	players_ready.clear()

	# The roster is cleared on teardown, so do not assume the winner is still in it.
	var winner_name: String = players.get(peer_id, "Player %d" % peer_id)
	var rounds_to_win: int = game.get_game_settings().rounds_to_win

	if not GameState.online_play:
		# Local play used to call show_winner() with just a name, so score and
		# is_match defaulted to 0/false every single round: no scoreboard was
		# ever kept, rounds_to_win was never consulted, and restart_game() looped
		# forever with no way to win the match.
		var score := _record_win(peer_id)
		show_winner(winner_name, peer_id, score, score >= rounds_to_win)
	elif get_tree().get_multiplayer( ).is_server():
		var score := _record_win(peer_id)
		rpc("show_winner", winner_name, peer_id, score, score >= rounds_to_win)

func update_wins_leaderboard() -> void:
	if not Online.has_valid_session():
		# Re-authenticate rather than waiting on a session that may never come.
		if not await Online.ensure_session():
			return

	var result = await Online.nakama_client.write_leaderboard_record_async(Online.nakama_session, LEADERBOARD_ID, 1)
	if result.is_exception():
		push_warning("Failed to record leaderboard win: %s" % str(result))

@rpc("any_peer", "call_local") func show_winner(name: String, peer_id: int = 0, score: int = 0, is_match: bool = false) -> void:
	if is_match:
		ui_layer.show_message(name + " WINS THE WHOLE MATCH!")
	elif score > 0:
		# Local play has no ready screen to show a scoreboard on, so the running
		# score goes in the message.
		ui_layer.show_message("%s wins this round! (%d of %d)" % [name, score, game.get_game_settings().rounds_to_win])
	else:
		ui_layer.show_message(name + " wins this round!")

	await get_tree().create_timer(2.0).timeout
	if not game.game_started:
		return

	if GameState.online_play:
		if is_match:
			stop_game()
			if peer_id != 0 and peer_id == get_tree().get_multiplayer().get_unique_id():
				update_wins_leaderboard()
			ui_layer.show_screen("MatchScreen")
		else:
			ready_screen.hide_match_id()
			ready_screen.reset_status("Waiting...")
			ready_screen.set_score(peer_id, score)
			ui_layer.show_screen("ReadyScreen")
	elif is_match:
		# Local match won: full teardown (which clears the scoreboard) and back
		# to the menu, rather than restarting the same match forever.
		stop_game()
		ui_layer.show_screen("TitleScreen")
	else:
		restart_game()

func _on_Music_song_finished(song) -> void:
	# current_song is null until the first track starts, and play_random() can
	# legitimately no-op when there is nothing else to switch to.
	if music.current_song == null or not music.current_song.playing:
		music.play_random()
