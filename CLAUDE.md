# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

"Push The Game" — a 2-4 player online arena brawler in **Godot 4.2** (GDScript), forked from Heroic Labs' `fishgame-godot` Nakama demo. Multiplayer runs over a [Nakama](https://heroiclabs.com/) server via the bundled `addons/com.heroiclabs.nakama` SDK.

**Version drift to be aware of:** `project.godot` declares `config/features=("4.2")` and all scripts use Godot 4 syntax (`@onready`, `@export`, `@rpc`, `CharacterBody2D`, `Callable`), but `README.md`, `.github/workflows/godot-export.yml`, and `.gitlab-ci.yml` still reference Godot 3.2.3 and the old "fishgame" naming. The CI export jobs are stale — they will not build this project as-is. Trust `project.godot`, not the README.

## Commands

There is no test suite, linter, or package manager in this repo; the Godot editor is the toolchain.

```bash
# Open in the editor (macOS)
/Applications/Godot.app/Contents/MacOS/Godot --path .

# Run the game headless-ish from CLI (main scene is Main.tscn)
/Applications/Godot.app/Contents/MacOS/Godot --path . Main.tscn

# Local Nakama server + CockroachDB (required for "Play Online")
docker-compose up -d      # Nakama on :7350, console on :7351

# Export a build (presets in export_presets.cfg: "Windows Desktop", "Linux/X11", "Mac OSX", "HTML5")
/Applications/Godot.app/Contents/MacOS/Godot --path . --export-release "Mac OSX" ./build/macosx/game.zip
```

Two-player local play needs no server: Title screen → "Play Local" wires `player1_*` / `player2_*` input actions to two players in the same window.

## Server configuration

`autoload/Online.gd` holds the default Nakama connection (currently a hardcoded remote host `54.37.12.116:7350`, `defaultkey`, `http`). To point at the local docker server, change these to `127.0.0.1` or set them from outside.

`autoload/Build.gd` is **generated** — `scripts/generate-build-variables.sh` overwrites it in CI from `NAKAMA_HOST` / `NAKAMA_PORT` / `NAKAMA_SERVER_KEY` env vars and stamps `OnlineMatch.client_version` with the commit SHA (the matchmaker refuses to pair clients with mismatched `client_version`). Never hand-edit it.

The leaderboard module `nakama/data/modules/fish_game.lua` is mounted into the container by `docker-compose.yml`. Note: it creates a leaderboard named `fish_game_wins`, but `Main.gd` and `LeaderboardScreen.gd` read/write `push_the_game_wins` — the leaderboard silently does nothing until these agree. `/nakama/data/` is gitignored apart from the tracked lua module.

## Architecture

### Autoload singletons (`autoload/`, registered in `project.godot`)
- **`Online`** — owns the `NakamaClient`, session, and socket. Emits `session_changed`, `session_connected`, `socket_connected`. Screens `await` these signals rather than polling.
- **`OnlineMatch`** — the layer that matters most. It wraps `NakamaMultiplayerBridge`, which turns a Nakama match into a Godot high-level multiplayer peer, so ordinary `@rpc` calls work over Nakama. Owns `MatchState` (LOBBY→MATCHING→CONNECTING→WAITING→READY→PLAYING), `MatchMode` (CREATE / JOIN / MATCHMAKER), the `players` dict keyed by **peer_id**, and enforces min/max players, client-version match, and "match already begun" rejection. **Peer 1 is always the host/authority.**
- **`GameState`** — a single `online_play: bool`. This flag is the central branch in nearly every gameplay path (see below).
- **`Build`**, **`Util`** — generated config; name helpers.

### Scene composition
`Main.tscn` is the only scene loaded at boot and contains both the UI layer and the game.

- **`Main.gd`** — glue between UI, `OnlineMatch`, and `Game`. Handles readiness (`player_ready` RPC), round/match scoring (first to 5 wins the match), winner announcements, and leaderboard writes.
- **`Game.gd`** — match lifecycle. `game_start()` → `_do_game_setup()` (RPC'd to all peers) spawns one `Player` per peer, **names the node `str(peer_id)`** and calls `set_multiplayer_authority(peer_id)`; each client reports back with `_finished_game_setup` to peer 1, which then broadcasts `_do_game_start`. The tree is paused during setup. Emits `game_over_signal` when one player remains.
- **`main/UILayer.gd` + `main/Screen.gd`** — a simple screen stack: all screens live under `UILayer/Screens`, are shown one at a time by node name (`ui_layer.show_screen("MatchScreen", info)`), and opt into `_setup_screen` / `_show_screen(info)` / `_hide_screen` hooks. New screens extend `res://main/Screen.gd`.
- **`Camera.gd`** — recomputes position and zoom every physics frame to frame all live players; limits are set from `Map.get_map_rect()` on map reload.
- **`maps/Map.gd`** — maps expose `PlayerStartPositions/Player1..4` markers and broadcast `map_start`/`map_stop` to the `map_object` group. `Game.map_scene` selects the map (`Map1.tscn` by default).

### Player: state machine + networking
`actors/Player.gd` (`CharacterBody2D`) delegates behaviour to the `snopek-state-machine` addon: `$StateMachine` with child `State` nodes in `actors/player-states/` (Idle, Move, Jump, Fall, Duck, Slide, Hurt, Dead). States access the player as `host = $"../.."`, transition with `get_parent().change_state("Name", info_dict)`, and inherit from each other (`Jump.gd extends Move.gd`, `Move.gd extends Idle.gd`) — shared movement logic lives up that chain. The `StateMachine` node's `_physics_process` is **disabled** and driven manually from `Player._physics_process` so input → state → movement ordering is deterministic.

Input never reads `Input` directly inside states. `components/InputBuffer.gd` snapshots all actions for a prefix (`player1_`…`player4_`) into a dict; states query the buffer. This is what makes remote players work: the authoritative client sends its buffer over the wire and remote instances replay it.

**Sync model** (`Player._physics_process` / `update_remote_player`): the authoritative client sends a single unreliable-style RPC carrying input buffer + state name + state info + position + velocity + sprite frame + flip/glide/slide flags, at least once every `SYNC_DELAY = 3` physics frames and immediately on any input or state change (`sync_forced`). Between packets, remote instances run the same state code against the last buffer with `predict_next_frame()` clearing the just-pressed/just-released edges.

**Authority split for pickups** — a recurring pattern worth copying: *pickup* is resolved on the host only (`rpc_id(1, "_try_pickup")`) so two players can't grab the same item, then broadcast; *throw* is called on all clients (`rpc("_do_throw")`) since the outcome is deterministic. `pickups/Pickup.gd` implements its own gravity/damping/bounce integration (not RigidBody2D) and sleeps when slow, with the authority broadcasting `_do_physics_finished` so everyone converges on the same resting transform. Weapons (`Gun.gd`, `Sword.gd`) extend `Pickup` and override `use()` / `_on_throw()`.

`components/Hitbox.gd` (Area2D) calls `hurt()` on overlapping bodies, but only on the peer with authority over the victim when online.

### The `GameState.online_play` pattern
Almost every action that mutates shared state is written as:

```gdscript
if GameState.online_play:
    rpc("_do_thing", args)     # or rpc_id(1, ...) when the host must arbitrate
else:
    _do_thing(args)            # local play: call directly, no RPC
```

When adding gameplay features, keep both branches working — local 2-player mode has no multiplayer peer at all, so an unguarded `rpc()` breaks it.

## Conventions

- Godot 4 signal/callable syntax is used inconsistently across the port: some code uses `signal.connect(Callable(self, "_on_x"))`, some uses `.bind()`. Match the surrounding file.
- RPCs need explicit annotations: `@rpc("any_peer", "call_local")` is the norm here. A couple of `@rpc` declarations in `OnlineMatch.gd` are leftovers from Godot 3 `master`/`puppet` semantics and are flagged with comments.
- Input actions follow `player{1..4}_{left,right,down,jump,grab,use,blop}`; online play always uses the `player1_` prefix for the locally controlled player.
- `main/screens/ConnectionScreen.gd::_ready()` begins with a bare `return`, which disables loading saved credentials from `user://credentials.json`. That is deliberate-looking dead code, not an accident to "fix" casually.
