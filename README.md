"Push The Game" for Godot
=====================

**"Push The Game" for Godot** is a 2-4 player online game built in the
[Godot](https://godotengine.org/) game engine, created as a demonstration of
[Nakama](https://heroiclabs.com/), an open-source scalable game server.

![Animated GIF showing gameplay](assets/screenshots/gameplay.gif)

You can download playable builds for Windows, Linux and MacOS from the
[Releases page](https://github.com/heroiclabs/fishgame-godot/releases).

**"Push The Game"** demonstrates the following Nakama features:

- [User authentication](https://heroiclabs.com/docs/authentication/)
- [Matchmaking](https://heroiclabs.com/docs/gameplay-matchmaker/)
- [Leaderboards](https://heroiclabs.com/docs/gameplay-leaderboards/)
- [Realtime Multiplayer](https://heroiclabs.com/docs/gameplay-multiplayer-realtime/)

The game design is heavily inspired by [Duck Game](https://store.steampowered.com/app/312530/Duck_Game/).

Controls
--------

### Playing Online ###

#### Gamepad: ####

- **D-PAD** or **LEFT ANALOG STICK** = move your fish
- **A (XBox)** or **Cross (PS)** = jump
- **Y (XBox)** or **Triangle (PS)** = pickup/throw weapon
- **X (XBox)** or **Square (PS)** = use weapon
- **B (Xbox)** or **Circle (PS)** = blub

#### Keyboard: ####

- **W**, **A**, **S**, **D** = move your fish
- **C** = pickup/throw weapon
- **V** = use weapon
- **E** = blub

### Playing Locally ###

#### Gamepad: ####

*Same as the "Playing Online" controls above.*

#### Keyboard: ####

| Action               | Player 1                   | Player 2   |
| -------------------- | -------------------------- | ---------- |
| move your fish       | **W**, **A**, **S**, **D** | Arrow keys |
| pickup/throw weapon  | **C**                      | **L**      |
| use weapon           | **V**                      | **;**      |
| blub                 | **E**                      | **P**      |

Playing the game from source
----------------------------

### Dependencies ###

You'll need:

* [Godot](https://godotengine.org/download) **4.2** (the project declares
  `config/features = "4.2"` and the scripts use Godot 4 syntax throughout).
* A Nakama server to connect to. The bundled `docker-compose.yml` runs
  Nakama 3.20.1 against CockroachDB.

The easiest way to setup a Nakama server locally for testing/learning purposes is [via Docker](https://heroiclabs.com/docs/install-docker-quickstart/), and in fact, there is a `docker-compose.yml` included in the source code of "Fish Game".

So, if you have [Docker Compose](https://docs.docker.com/compose/install/) installed on your system, all you need to do is navigate to the directory where you put the "Fish Game" source code and run this command:

```
docker-compose up -d
```

### Running the game from source ###

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

### Hosting a game ###

Click **Play Online**, then **HOST**. You get a four-character room code; anyone
who enters that code under **Room code** joins your game. Codes deliberately
avoid look-alike characters (no O/0, I/1, S/5, Z/2) so they survive being read
out loud.

### Setting up the leaderboard ###

If you didn't use the `docker-compose.yml` included with "Fish Game", then the "Leaderboard" won't work until you first create it on your server.

To do that, copy the `nakama/data/modules/fish_game.lua` file to the `modules/` directory where your Nakama server keeps its data, and then restart your Nakama server.

_Note: the leaderboard id in that module must match `Main.LEADERBOARD_ID`. They disagreed for a long time, which silently disabled the leaderboard entirely._

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

_Note: `export_presets.cfg` still carries Godot 3 platform names (`Mac OSX`,
`HTML5`, `Linux/X11`), and the CI workflows have not been validated against
Godot 4. Regenerate the presets from the editor's Export dialog before relying
on a build._

License
-------

This project is licensed under the Apache 2.0 License, with the following exceptions: 

* The font (in [assets/fonts/](https://github.com/heroiclabs/fishgame-godot/blob/main/assets/fonts)) and a handful of art assets (in [assets/kenney-platform-deluxe/](https://github.com/heroiclabs/fishgame-godot/blob/main/assets/kenney-platform-deluxe)) originate from CC0 sources (see [CREDITS-CC0.txt](https://github.com/heroiclabs/fishgame-godot/blob/main/CREDITS-CC0.txt)).
* The remaining art, music and sound assets are licensed under the [CC BY-NC License](https://github.com/heroiclabs/fishgame-godot/blob/main/assets/LICENSE.txt).
* The [Snopek State Machine](https://gitlab.com/snopek-games/godot-state-machine) included in [addons/snopek-state-machine/](https://github.com/heroiclabs/fishgame-godot/tree/main/addons/snopek-state-machine) is licensed under the MIT License.
* Most of the UI code (included in [main/](https://github.com/heroiclabs/fishgame-godot/tree/main/main)) and some other auxilary code files originate from the [WebRTC and Nakama addon for Godot](https://gitlab.com/snopek-games/godot-nakama-webrtc), which is licensed under the MIT License.

