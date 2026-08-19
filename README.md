Push The Game
=============

**Push The Game** is a 2-4 player online arena brawler built in the
[Godot](https://godotengine.org/) game engine, by **Jakub Skowronski**,
**Stefano Mancone** and **Alessandro Compagnucci**.

It is built on top of ["Fish Game"](https://github.com/heroiclabs/fishgame-godot),
Heroic Labs' [Nakama](https://heroiclabs.com/) demo by David Snopek — see the
[License](#license) section for the full attribution.

![Animated GIF showing gameplay](assets/screenshots/gameplay.gif)

There are no published builds yet; run it from source (see
[Playing the game from source](#playing-the-game-from-source) below). The export
presets and CI workflows have not been validated end to end.

Multiplayer works three ways, and everything above the transport layer
(`Main.gd`, `Game.gd`, `ReadyScreen`) is peer-id based and does not know which
one is in use:

| Mode | Needs | Where it lives |
| --- | --- | --- |
| Online (room codes, matchmaking, leaderboard) | a [Nakama](https://heroiclabs.com/) server | `autoload/Online.gd`, `autoload/OnlineMatch.gd` |
| Same wi-fi (LAN) | nothing at all | `autoload/LanMatch.gd` |
| Steam (friends & invites) | the GodotSteam extension + the Steam client | `autoload/SteamMatch.gd`, see [docs/steam.md](docs/steam.md) |

The Nakama path uses [user authentication](https://heroiclabs.com/docs/authentication/),
[matchmaking](https://heroiclabs.com/docs/gameplay-matchmaker/),
[leaderboards](https://heroiclabs.com/docs/gameplay-leaderboards/) and
[realtime multiplayer](https://heroiclabs.com/docs/gameplay-multiplayer-realtime/).

The game design is heavily inspired by [Duck Game](https://store.steampowered.com/app/312530/Duck_Game/).

Controls
--------

### Playing Online ###

#### Gamepad: ####

- **D-PAD** or **LEFT ANALOG STICK** = move
- **A (XBox)** or **Cross (PS)** = jump
- **Y (XBox)** or **Triangle (PS)** = pickup/throw weapon
- **X (XBox)** or **Square (PS)** = use weapon
- **B (Xbox)** or **Circle (PS)** = blop

#### Keyboard: ####

- **A**, **D** = move left/right
- **W** = jump
- **S** = down
- **C** = pickup/throw weapon
- **V** = use weapon
- **E** = blop

### Playing Locally ###

#### Gamepad: ####

*Same as the "Playing Online" controls above.*

#### Keyboard: ####

Two to four players share one machine. Pick the number on the title screen next
to **LOCAL** — it tells you which input each seat expects and says so plainly
when a seat needs a pad that is not plugged in.

**Players 3 and 4 are gamepad only.** There are no keyboard bindings for them:
four players on one keyboard would need 8–12 simultaneous keys, which most
keyboards cannot register, and the dropped inputs would look like a game bug.

| Action               | Player 1                   | Player 2   | Players 3 / 4 |
| -------------------- | -------------------------- | ---------- | ------------- |
| move                 | **W**, **A**, **S**, **D** | Arrow keys | D-pad / stick |
| pickup/throw weapon  | **C**                      | **L**      | Y / Triangle  |
| use weapon           | **V**                      | **;**      | X / Square    |
| blop                 | **E**                      | **P**      | B / Circle    |

### Pausing ###

**Escape**, or **Start on any pad** — on a four-player couch the person who needs
to stop the game is not necessarily holding controller 1. Online play shows the
menu but does **not** pause: the other players keep going regardless, and halting
your own simulation while their input keeps arriving would desync you.

### During a round ###

Rounds count in from three before anyone can move, so everyone can see the arena
and which character is theirs. A scoreboard along the bottom shows every
player's portrait, name and round wins out of the target; an eliminated player
dims rather than disappearing, so the row does not reflow mid-fight.

### The arenas ###

Three, drawn from a shuffled bag so every arena gets an outing per cycle without
the order being guessable:

- **Terrace** — wide and tiered, with a central stack and a pit in the floor. A
  launch pad is the only way to the crow's nest.
- **The Well** — tall and enclosed: two towers of staggered ledges and a central
  shaft of one-way platforms you can punch straight up through.
- **The Maw** — read horizontally instead. The middle of the floor is missing,
  and one droppable stepping stone hangs in the hole. Everything worth having is
  on the iced island above it, and the shotgun's knockback is what puts people in.

`tools/build_maps.gd` is the source of truth for all three: it generates them
from a code layout against a documented movement budget, and
`tests/MapReachabilityTest.tscn` then proves every surface is reachable and
escapable before a build is trusted.

Playing the game from source
----------------------------

### Dependencies ###

You'll need:

* [Godot](https://godotengine.org/download) **4.7.2** (the project declares
  `config/features = "4.7"` and the scripts use Godot 4 syntax throughout).
* For online play, a Nakama server to connect to. The bundled
  `docker-compose.yml` runs Nakama 3.20.1 against CockroachDB.
  LAN play needs no server at all.

The easiest way to set up a Nakama server locally for testing/learning purposes
is [via Docker](https://heroiclabs.com/docs/install-docker-quickstart/), and
there is a `docker-compose.yml` included in the source code of Push The Game.

So, if you have [Docker Compose](https://docs.docker.com/compose/install/)
installed on your system, all you need to do is navigate to the directory where
you put the Push The Game source code and run this command:

```
docker compose up -d
```

That brings up the Nakama API on `:7350` and the admin console on
<http://127.0.0.1:7351> (admin/password).

### Running the game from source ###


The quickest way to play, which also checks you are on the right engine:

```
./run.sh
```

**This project needs Godot 4.7 or newer.** Running it with an older Godot does
not fail cleanly: 4.2 cannot read the import cache 4.7 writes, so every font,
sound and scene fails to load and you get a wall of "can't be loaded, as it uses
a format version (6)" errors that look like a broken project. `run.sh` refuses
to start on an older engine and tells you so. If you have several Godots
installed, point it at the right one:

```
GODOT='/Applications/Godot 4.7.app/Contents/MacOS/Godot' ./run.sh
```
1. Download the source code to your computer.
2. Open Godot and "Import" the project.
3. (Optional) Point the game at your own Nakama server. The defaults live at
the top of `autoload/Online.gd`, but they are overridden at runtime by
`user://settings.cfg`, so you can change the server without editing code.
4. Press F5 or click the play button in the upper-right corner to start the game.

You do **not** need to create an account to play online. The game signs in
silently using a per-installation device id (`autoload/Online.gd`), and stores
your display name in `user://profile.cfg`. Email/password sign-in is still
available as a fallback for existing accounts.

### Hosting a game over the internet ###

Click **Play Online**, then **HOST**. You get a four-character room code; anyone
who enters that code under **Room code** joins your game. Codes deliberately
avoid look-alike characters (no O/0, I/1, S/5, Z/2) so they survive being read
out loud.

### Playing over LAN ###

On the same wi-fi you need no server, no account and no room code. Click
**Play Online**, then **HOST LAN** to host, or **FIND GAMES** on the other
machines: hosts announce themselves over a UDP broadcast beacon and show up in
the list ready to join, so nobody has to type an IP address
(`autoload/LanMatch.gd`). This is LAN only by design — playing across the
internet without port forwarding is what the Nakama mode is for.

### Playing over Steam ###

The Steam section of the match screen (**HOST ON STEAM**, **Steam friends**,
invites) is wired up but disabled unless the GodotSteam extension is installed,
which this repository does not ship. It says so on screen. See
[docs/steam.md](docs/steam.md) — and note that none of the Steam code has yet
been run against a real Steam client.

### Setting up the leaderboard ###

If you didn't use the `docker-compose.yml` included with Push The Game, then the
"Leaderboard" won't work until you first create it on your server.

To do that, copy the `nakama/data/modules/push_the_game.lua` file to the
`modules/` directory where your Nakama server keeps its data, and then restart
your Nakama server.

_Note: the leaderboard id in that module (`push_the_game_wins`) must match
`Main.LEADERBOARD_ID`. They disagreed for a long time, which silently disabled
the leaderboard entirely._

_Note: The game will play fine without the leaderboard._

Running the checks
------------------

There is no unit-test framework in this project; `scripts/check.sh` is the
regression harness. It parses every script, boots the game headless, drives a
full local 2-player round (including a death and a round end), and runs the
scene-based tests under `tests/`:

```
./scripts/check.sh          # all gates
./scripts/check.sh play     # just the local-play gate
```

It exists because this project was ported from Godot 3, and the dominant bug
class -- calls into APIs that no longer exist -- parses fine and only fails on
the frame it finally runs.

_Note: the export presets now carry the Godot 4 platform names (`Windows
Desktop`, `Linux`, `macOS`, `Web`, each verified to load under 4.7.2), but the
per-preset option keys in `export_presets.cfg` are still Godot 3 vintage, and
the CI workflows have not been validated against Godot 4. Regenerate the presets
from the editor's Export dialog before relying on a build._

Credits
-------

Push The Game is by **Jakub Skowronski**, **Stefano Mancone** and
**Alessandro Compagnucci**.

It is based on ["Fish Game"](https://github.com/heroiclabs/fishgame-godot),
whose original programming is by [David Snopek](https://www.snopekgames.com) of
Snopek Games. The art is by Orlando Herrera a.k.a.
[Pixel Frog](https://pixelfrog-store.itch.io/), the music and sound are by
Jakob T. Rypdal, and the [Monogram](https://datagoblin.itch.io/monogram) font is
by Vinícius Menézio. The same credits are shown in-game on the Credits screen.

License
-------

This project is licensed under the Apache 2.0 License (see [LICENSE.txt](LICENSE.txt)),
with the following exceptions:

* The font (in [assets/fonts/](assets/fonts)) and a handful of art assets (in
  [assets/kenney-platform-deluxe/](assets/kenney-platform-deluxe)) originate
  from CC0 sources: [Monogram](https://datagoblin.itch.io/monogram) by Vinícius
  Menézio, and the Platformer Art Complete Pack by
  [Kenney](https://www.kenney.nl/) (see
  [assets/kenney-platform-deluxe/license.txt](assets/kenney-platform-deluxe/license.txt)).
* The remaining art, music and sound assets are licensed under the
  [CC BY-NC License](assets/LICENSE.txt) — art by Orlando Herrera a.k.a.
  [Pixel Frog](https://pixelfrog-store.itch.io/), music and sound by Jakob T.
  Rypdal.
* The title screen's CRT/VHS treatment (`assets/shaders/`) came from this
  project's own `compa_dev` branch, where it carried no attribution. The
  scanline/grille/aberration pass is the widely-shared "VHS and CRT monitor
  effect" by pend00 on [godotshaders.com](https://godotshaders.com) (MIT); the
  wobble pass derives from the "bad TV" ShaderToy effect that circulates with
  it. Both files carry a note saying so.

* The [Snopek State Machine](https://gitlab.com/snopek-games/godot-state-machine)
  included in [addons/snopek-state-machine/](addons/snopek-state-machine) is
  licensed under the MIT License.
* Most of the UI code (included in [main/](main)) and some other auxiliary code
  files originate from the
  [WebRTC and Nakama addon for Godot](https://gitlab.com/snopek-games/godot-nakama-webrtc),
  which is licensed under the MIT License.

The codebase derives from
["Fish Game" for Godot](https://github.com/heroiclabs/fishgame-godot) © Heroic
Labs, originally written by David Snopek / Snopek Games and licensed under
Apache 2.0. That notice, and every attribution above, is preserved deliberately:
both Apache 2.0 and CC BY-NC require it.
