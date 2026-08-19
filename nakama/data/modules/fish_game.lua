local nk = require("nakama")

nk.run_once(function(context)
	nk.leaderboard_create("push_the_game_wins", false, "desc", "incr")
end)

