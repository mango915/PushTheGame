# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

"Push The Game" — a 2-4 player online arena brawler in **Godot 4.7.2** (GDScript), by Jakub Skowronski, Stefano Mancone and Alessandro Compagnucci (<https://github.com/mango915/PushTheGame>). Multiplayer runs over a [Nakama](https://heroiclabs.com/) server via the bundled `addons/com.heroiclabs.nakama` SDK.

**Provenance.** The codebase was forked from Heroic Labs' `fishgame-godot` Nakama demo ("Fish Game", by David Snopek / Snopek Games, Apache 2.0). That is accurate history and the attributions that come with it are load-bearing, not decoration: Apache 2.0 (code) and CC BY-NC (art/music) both *require* them. Never strip the Fish Game / Snopek Games derivation notice from `README.md`, the in-game Credits screen (`main/screens/CreditsScreen.tscn`), `LICENSE.txt` or `assets/LICENSE.txt`, nor the credits for Orlando Herrera (Pixel Frog, art), Jakob T. Rypdal (music/sound) or Vinícius Menézio (Monogram font). Rebranding means changing the *game's* identity and authorship, not deleting anyone's credit.

`assets/music/FISHSTICKS.ogg` and the `Fishsticks` node in `Main.tscn` are a **track title by the composer**, not a leftover reference to the old game. Leave them alone.

**This was a sloppy Godot 3 → 4 port.** The dominant bug class is calls into APIs that no longer exist: they parse fine and only fail on the frame they finally run. A large batch has been fixed (see git log), but assume more are lurking in code paths nothing exercises yet. `export_presets.cfg` had Godot 3 platform names; the platform/preset names are now the Godot 4 ones (`Windows Desktop`, `Linux`, `macOS`, `Web` — verified against 4.7.2 by loading each preset), but the per-preset **option keys** in that file are still Godot 3 vintage, so regenerate it from the editor's Export dialog before any build is trustworthy. `project.godot` likewise still carries dead Godot 3 sections (`[gdnative] singletons`, the `[importer_defaults] texture` block, and `quality/driver/driver_name="GLES2"` / `quality/2d/use_pixel_snap` / `vram_compression/import_etc` under `[rendering]`); Godot 4 ignores them.

Several scenes are also still saved in the Godot 3 text format (`format=2`): `main/screens/{LeaderboardRecord,LeaderboardScreen,MatchScreen,PeerStatus}.tscn`. They load, but Godot-3-only properties in them are silently dropped — that is exactly how the Credits screen ended up rendering an unstyled fallback for months (see below).

## Commands

There is no linter or package manager in this repo; the Godot editor is the toolchain and
`scripts/check.sh` is the test runner (see "The regression harness" below).

The engine is **Godot 4.7.2** (`project.godot` declares `config/features = "4.7"`). The
project was upgraded from 4.2.1 and the entire suite — 514 assertions plus both
multiplayer runners — passed on 4.7.2 with **no code changes**; the only edit needed was
a log-filter casing tweak in the harness, because 4.7 writes "N resources still in use at
exit" where 4.2 wrote "Resources still in use at exit".

`scripts/check.sh`, `scripts/nettest.sh` and `tests/lantest.sh` resolve Godot in this
order: a `GODOT` environment variable, then `/Applications/Godot 4.7.app`, then
`/Applications/Godot.app`, then `godot` on `PATH`. On this machine 4.7.2 is installed
alongside the older 4.2.1 rather than replacing it, so a stale `/Applications/Godot.app`
cannot silently run the suite on the wrong engine.

`TileMap` is deprecated in favour of `TileMapLayer` from 4.3 onward but still present and
instantiable in 4.7, which is why the maps still work untouched. That is a deprecation to
retire deliberately, not something to discover when it is finally removed.

```bash
# Regression harness -- run this before and after any change (see below)
./scripts/check.sh

# Open in the editor
godot --path .

# Run the game headless-ish from CLI (main scene is Main.tscn)
godot --path . Main.tscn

# Local Nakama server + CockroachDB (required for "Play Online")
docker compose up -d      # Nakama on :7350, console on :7351

# Export a build. NOTE: the preset PLATFORM names are correct for Godot 4 now
# ("Windows Desktop", "Linux", "macOS", "Web"), but the per-preset option keys
# in export_presets.cfg are still Godot 3 vintage and it should be regenerated
# from the editor's Export dialog before any build from it is trustworthy.
godot --path . --export-release "Linux" ./build/linux/push-the-game.x86_64
```

Two-player local play needs no server: Title screen → "Play Local" wires `player1_*` / `player2_*` input actions to two players in the same window.

### Watch for this bug pattern
`var x: T = v: set = _set_readonly_variable` — an empty setter used to make a property read-only from outside. GDScript setters intercept writes from **inside** the class too, so every internal assignment is silently discarded and nothing errors. This has been found and fixed three times now: `OnlineMatch` (the whole match state machine was inert) and `UILayer` (`current_screen_name` was permanently `''`, so the Back button could never leave MatchScreen online). If you meet another one, it is a bug, not a style.

### Testing multiplayer for real
`scripts/check.sh` runs one process with no server, so it cannot see the online path at all. `scripts/nettest.sh` launches two headless clients that host and join the same room code against a local Nakama (`docker compose up -d` first). Use it for anything touching auth, the match lifecycle, or RPCs.

Note `tests/net_multiplayer.tscn` is deliberately **not** named `*Test.tscn` — that pattern is auto-discovered by the unit gate, and this one needs a server plus CLI args.

### The regression harness

`scripts/check.sh` is the only safety net — there is no unit-test framework. Four gates: **parse** every non-addon script, **boot** `Main.tscn` headless, **play** a full local 2-player round (including a forced death and round end), and **units**, which auto-discovers `tests/*Test.tscn`.

Test scenes follow one convention: print `[tag] OK:` / `[tag] FAIL:` lines, then `print("[tag] %d assertion(s) failed" % _failures)`, then `get_tree().quit(0)`. Drop a new `tests/FooTest.tscn` in and the harness picks it up. Assert on *invariants*, not just absence of crashes — most bugs here are silently wrong behavior, not errors.

Godot quirks the harness had to work around, all of which cost real time:
- **There is no `--import` flag.** Passing one is silently ignored and the engine just runs the game forever.
- **`--headless --editor` imports correctly but never exits** (`--quit`/`--quit-after` do not end the editor's import pass). The harness watches `.godot/imported` until it settles, then stops it.
- **`--quit-after` counts render frames**, which in headless run far faster than the 60 Hz physics tick. Anything counting physics frames must bound itself.
- **`--check-only` parses each script in isolation with no autoloads registered**, so every reference to `GameState`/`Online`/`OnlineMatch`/`Util` reports "Identifier not found". The parse gate filters those; it only meaningfully catches syntax errors.
- **Some engine `ERROR:` lines are a test's success condition, not a failure.** `check.sh` greps for a bare `ERROR: `, so two classes of shutdown/expected chatter are filtered in `IGNORE_PATTERN` — each with a comment saying why. `Couldn't create an ENet host` is emitted *by* the LAN tests that deliberately provoke a refused bind. `Resources still in use at exit` / `ObjectDB instances leaked at exit` fire because every scene in `tests/` calls `get_tree().quit()` the moment its assertions finish, leaving that frame's deferred `queue_free()` calls unprocessed by construction — it tracks teardown timing, not the game, and was observed hopping between scenes on consecutive runs of an identical tree. Before adding to that list, check the error is genuinely not about the product; a real leak check would be its own test asserting on `Performance.get_monitor(OBJECT_COUNT)`.

## Server configuration

`autoload/Online.gd` holds the default Nakama connection (currently a hardcoded remote host `54.37.12.116:7350`, `defaultkey`, `http`). To point at the local docker server, change these to `127.0.0.1` or set them from outside.

`autoload/Build.gd` is **generated** — `scripts/generate-build-variables.sh` overwrites it in CI from `NAKAMA_HOST` / `NAKAMA_PORT` / `NAKAMA_SERVER_KEY` env vars and stamps `OnlineMatch.client_version` with the commit SHA (the matchmaker refuses to pair clients with mismatched `client_version`). Never hand-edit it.

The leaderboard module `nakama/data/modules/push_the_game.lua` is mounted into the container by `docker-compose.yml`. It creates a leaderboard named `push_the_game_wins`, which is what `Main.gd` (`LEADERBOARD_ID`) and `LeaderboardScreen.gd` read and write — these three must agree or the leaderboard silently does nothing. `/nakama/data/` is gitignored apart from the tracked lua module.

## Architecture

### Autoload singletons (`autoload/`, registered in `project.godot`)
- **`Online`** — owns the `NakamaClient`, session, and socket. Emits `session_changed`, `session_connected`, `socket_connected`. Screens `await` these signals rather than polling.
- **`OnlineMatch`** — the layer that matters most. It wraps `NakamaMultiplayerBridge`, which turns a Nakama match into a Godot high-level multiplayer peer, so ordinary `@rpc` calls work over Nakama. Owns `MatchState` (LOBBY→MATCHING→CONNECTING→WAITING→READY→PLAYING), `MatchMode` (CREATE / JOIN / MATCHMAKER / LAN_HOST / LAN_JOIN / STEAM_HOST / STEAM_JOIN), the `players` dict keyed by **peer_id**, and enforces min/max players, client-version match, and "match already begun" rejection. **Peer 1 is always the host/authority.**
- **`LanMatch`** — the serverless transport: an `ENetMultiplayerPeer` plus a UDP broadcast beacon so hosts on the same wi-fi are discovered without anyone typing an IP. `OnlineMatch.host_lan_match()` / `join_lan_match()` drive it.
- **`SteamMatch`** — the Steam transport: lobbies, the friends list, invites, and a `SteamMultiplayerPeer`. Requires the GodotSteam GDExtension, which is **not installed in this repo**; every call is guarded behind `Engine.has_singleton("Steam")` so the game is unaffected without it, and the UI shows the Steam section disabled with the reason. See `docs/steam.md`.
- **`GameState`** — a single `online_play: bool`. This flag is the central branch in nearly every gameplay path (see below).
- **`Build`**, **`Util`** — generated config; name helpers.

### Scene composition
`Main.tscn` is the only scene loaded at boot and contains both the UI layer and the game.

- **`Main.gd`** — glue between UI, `OnlineMatch`, and `Game`. Handles readiness (`player_ready` RPC), round/match scoring (first to 5 wins the match), winner announcements, and leaderboard writes.
- **`Game.gd`** — match lifecycle. `game_start()` → `_do_game_setup()` (RPC'd to all peers) spawns one `Player` per peer, **names the node `str(peer_id)`** and calls `set_multiplayer_authority(peer_id)`; each client reports back with `_finished_game_setup` to peer 1, which then broadcasts `_do_game_start`. The tree is paused during setup. Emits `game_over_signal` when one player remains.
- **`main/UILayer.gd` + `main/Screen.gd`** — a simple screen stack: all screens live under `UILayer/Screens`, are shown one at a time by node name (`ui_layer.show_screen("MatchScreen", info)`), and opt into `_setup_screen` / `_show_screen(info)` / `_hide_screen` hooks. New screens extend `res://main/Screen.gd`.
- **`Camera.gd`** — recomputes position and zoom every physics frame to frame all live players; limits are set from `Map.get_map_rect()` on map reload.
- **`maps/Map.gd`** — maps expose `PlayerStartPositions/Player1..4` markers and broadcast `map_start`/`map_stop` to the `map_object` group. `Game.map_scene` selects the map (`Map1.tscn` by default).
- **`main/screens/CreditsScreen.tscn`** — the game's attribution surface; treat its content as licence compliance, not copy. It was a `format=2` (Godot 3) scene carrying the credits text **twice under the same `text` key** — a bbcode copy and a plain copy — so the last one won and the styled version never rendered, and its two `FontFile` sub-resources used the Godot 3 `font_data` property, which Godot 4 does not have. Converted to `format=3` with a single bbcode `text` and the theme's font; the colours and `[url]` links now actually show.

### Getting online
Playing online needs no account. `Online.authenticate_device()` signs in silently with a stable per-installation id (persisted in `user://profile.cfg` alongside the display name); email/password remains only as a fallback in `ConnectionScreen`. Server host/port live in `user://settings.cfg` and override the defaults at the top of `Online.gd`, so pointing at a different Nakama is a settings change, not a code change.

Hosting uses **named matches**: `NakamaMultiplayerBridge.join_named_match(code)` is create-or-join, so `OnlineMatch.host_room()` and `join_room()` are the same call and the first player in becomes host. That is where the four-character room code comes from. The sharp edge: a generated code that collides with a live match would silently drop the would-be host into a stranger's game, so `MatchScreen` checks it actually came out as peer 1 and retries with a fresh code otherwise.

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

## Tuning, weapons and rules are data

Two `Resource` types hold what used to be magic numbers. Change these rather than editing scripts:

- **`resources/GameSettings.gd`** (+ `resources/default_game_settings.tres`) — movement and throw tuning (speed, acceleration, friction, jump, gravity, terminal velocity, knockback, throw vectors) plus match rules `rounds_to_win` and `sync_delay`. `Player.gd` keeps getter-only properties under the original names (`host.speed`, `host.friction`, …) so `actors/player-states/*.gd` needs no changes. `gravity = 0` is a sentinel meaning "use `physics/2d/default_gravity`".
  **The host's settings are replicated to every peer** in `Game._do_game_setup` (serialized via `to_dict()`, rebuilt with `from_dict()`) before any player spawns. This is load-bearing, not a nicety: remote players are simulated locally from a replayed input buffer, so peers running different numbers desync silently, with no error anywhere. Add a field to `GameSettings.FIELDS` and it replicates automatically.
- **`resources/WeaponData.gd`** (+ `gun_weapon.tres`, `sword_weapon.tres`) — per-weapon values (projectile scene/velocity/range, cooldown, ammo, carry position, bounce). `Pickup._apply_weapon_data()` copies them in `_ready`; subclasses override it and call `super()` first. A weapon with no resource assigned keeps its script defaults.

Adding a weapon: make a `.tres` from `WeaponData`, duplicate a pickup scene, point it at the resource, and override `use()`.

## Conventions

- Godot 4 signal/callable syntax is used inconsistently across the port: some code uses `signal.connect(Callable(self, "_on_x"))`, some uses `.bind()`. Match the surrounding file.
- RPCs need explicit annotations: `@rpc("any_peer", "call_local")` is the norm here. A couple of `@rpc` declarations in `OnlineMatch.gd` are leftovers from Godot 3 `master`/`puppet` semantics and are flagged with comments.
- Input actions follow `player{1..4}_{left,right,down,jump,grab,use,blop}`; online play always uses the `player1_` prefix for the locally controlled player.
- `main/screens/ConnectionScreen.gd::_ready()` begins with a bare `return`, which disables loading saved credentials from `user://credentials.json`. That is deliberate-looking dead code, not an accident to "fix" casually.
