extends Node2D

# Must match the id created in nakama/data/modules/push_the_game.lua.
const LEADERBOARD_ID := 'push_the_game_wins'

@onready var game = $Game
@onready var ui_layer: UILayer = $UILayer
@onready var ready_screen = $UILayer/Screens/ReadyScreen
@onready var music := $Music

const MIN_LOCAL_PLAYERS := 2
const MAX_LOCAL_PLAYERS := 4

var players := {}

var players_ready := {}
var players_score := {}

var match_started := false

# How many seats a local match sets up, chosen on TitleScreen. Online play takes
# its roster from OnlineMatch instead and ignores this.
var local_player_count := MIN_LOCAL_PLAYERS

func _ready() -> void:
	OnlineMatch.error.connect(Callable(self, "_on_OnlineMatch_error"))
	OnlineMatch.disconnected.connect(Callable(self, "_on_OnlineMatch_disconnected"))
	OnlineMatch.player_joined.connect(Callable(self, "_on_OnlineMatch_player_joined"))
	OnlineMatch.player_left.connect(Callable(self, "_on_OnlineMatch_player_left"))

	# Only the host ever calls start_game(), so this is the one thing that tells
	# a client who is in the round. Connected in code rather than in Main.tscn so
	# the wiring lives next to the handler that depends on it.
	game.roster_updated.connect(Callable(self, "_on_Game_roster_updated"))
	game.countdown_tick.connect(Callable(self, "_on_Game_countdown_tick"))
	ui_layer.pause_menu.quit_to_menu.connect(Callable(self, "_on_PauseMenu_quit_to_menu"))

	# The round clock lives in Game (it has to: the host drives it and RPCs the
	# decisions), and the HUD lives in UILayer. These three are the whole bridge.
	game.round_clock_changed.connect(Callable(self, "_on_Game_round_clock_changed"))
	game.sudden_death_warning.connect(Callable(self, "_on_Game_sudden_death_warning"))
	game.sudden_death_started.connect(Callable(self, "_on_Game_sudden_death_started"))

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

# `player_count` comes from the selector on TitleScreen. Defaulted so that any
# other caller (a test, or a connection made before the signal carried an
# argument) still gets the original two-player behaviour.
func _on_TitleScreen_play_local(player_count: int = 2) -> void:
	GameState.online_play = false
	local_player_count = clampi(player_count, MIN_LOCAL_PLAYERS, MAX_LOCAL_PLAYERS)

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

	# A screen being up means a menu or the lobby, never a running round.
	# set_round_time() enforces the same rule every frame; this just makes the
	# HUD disappear on the very frame the screen appears.
	ui_layer.hide_round_timer()

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

# Quitting from the pause menu is the same journey as the Back button: tear the
# round down and return to whichever menu this mode came from.
func _on_PauseMenu_quit_to_menu() -> void:
	_on_UILayer_back_button()

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
		# One seat per local player. Game._do_game_setup walks this dictionary in
		# order, spawning at PlayerStartPositions/PlayerN and assigning the
		# playerN_ input prefix, so the peer ids have to be 1..N.
		players = {}
		for seat in range(1, local_player_count + 1):
			players[seat] = "P%d" % seat

		# Local players share one machine and cannot each pick, so give them
		# distinct characters starting from whatever this profile chose.
		var index := 0
		for peer_id in players:
			characters[peer_id] = (Online.character_index + index) % Characters.count()
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

	ui_layer.hide_round_timer()
	if ui_layer.hud != null:
		ui_layer.hud.hide_hud()
	ui_layer.hide_countdown()
	# close() before disabling, so a tree this menu paused is handed back running.
	ui_layer.pause_menu.close()
	ui_layer.pause_menu.enabled = false

	game.game_stop()

func restart_game() -> void:
	stop_game(false)
	start_game()

func _on_game_started_signal() -> void:
	ui_layer.hide_screen()
	ui_layer.hide_all()
	ui_layer.show_back_button()

	# After hide_all(), which does not touch the scoreboard but does take the
	# back button down with it.
	_refresh_hud()
	ui_layer.pause_menu.enabled = true

	if not match_started:
		match_started = true
		music.play_random()

# The HUD is a pure mirror of Game's clock: it is redrawn from whatever the
# round clock last reported, and hidden the moment that clock stops. Nothing
# here decides anything, so a client cannot show a different countdown from the
# host's for longer than one sync interval.
func _on_Game_round_clock_changed(seconds_left: float, running: bool, sudden_death: bool) -> void:
	ui_layer.set_round_time(seconds_left, running, sudden_death)

func _on_Game_sudden_death_warning(seconds_left: float) -> void:
	var text := "Sudden death in %d..." % int(ceil(maxf(0.0, seconds_left)))
	ui_layer.show_message(text)
	_hide_message_later(text)

func _on_Game_sudden_death_started() -> void:
	var text := "SUDDEN DEATH - the arena is flooding!"
	ui_layer.show_message(text)
	_hide_message_later(text)

# Clears a transient notice, but only if nothing more important (a death, a
# winner, a player leaving) has taken the message label over in the meantime.
func _hide_message_later(text: String, seconds: float = 2.5) -> void:
	await get_tree().create_timer(seconds).timeout
	if ui_layer.message_label.text == text:
		ui_layer.hide_message()
# 3, 2, 1 while the tree is still paused, then a brief "GO!" once it is running.
#
# The label is cleared by the tick itself rather than by a timer started
# elsewhere, so a round abandoned mid-countdown cannot leave a number stranded on
# the menu behind it: every exit path calls game_stop(), which bumps the setup
# generation and ends the countdown without another tick.
const GO_FLASH_SECONDS := 0.6

func _on_Game_countdown_tick(seconds_left: int) -> void:
	if seconds_left > 0:
		ui_layer.show_countdown(str(seconds_left))
		return

	ui_layer.show_countdown("GO!")
	await get_tree().create_timer(GO_FLASH_SECONDS).timeout
	# Another round may have started counting while this flash was on screen.
	if ui_layer.countdown_label.text == "GO!":
		ui_layer.hide_countdown()

# Rebuilds the scoreboard from the players actually spawned in the round.
#
# Reading the live nodes rather than a roster dictionary is what makes this work
# identically in local and online play: Game._do_game_setup names each node
# str(peer_id) and applies the character on every peer, so a client that never
# called start_game() still has everything the scoreboard needs. It also means
# no new data has to be added to any RPC.
func _refresh_hud() -> void:
	var hud = ui_layer.hud
	if hud == null:
		return

	var entries := []
	for child in game.players_node.get_children():
		# Death explosions are parented into the same container.
		if not child.has_method("pickup_or_throw"):
			continue
		var peer_id := int(str(child.name))
		var display_name: String = child.player_name
		if display_name == "":
			display_name = players.get(peer_id, "P%d" % peer_id)
		entries.append({
			peer_id = peer_id,
			name = display_name,
			character = child.player_skin,
			score = int(players_score.get(peer_id, 0)),
		})

	entries.sort_custom(func(a, b): return a.peer_id < b.peer_id)

	hud.set_target(game.get_game_settings().rounds_to_win)
	hud.set_players(entries)
	hud.reset_alive()
	hud.show_hud()

func _on_player_dead(peer_id: int) -> void:
	if ui_layer.hud != null:
		ui_layer.hud.set_alive(peer_id, false)

	if GameState.online_play:
		var my_id = get_tree().get_multiplayer().get_unique_id()
		if peer_id == my_id:
			ui_layer.show_message("You lose!")

# Adds a round win to the scoreboard and reports the new total.
func _record_win(peer_id: int) -> int:
	players_score[peer_id] = int(players_score.get(peer_id, 0)) + 1
	if ui_layer.hud != null:
		ui_layer.hud.set_score(peer_id, players_score[peer_id])
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
