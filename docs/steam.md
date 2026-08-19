# Steam multiplayer (friends, invites, networking)

Push The Game has three multiplayer transports:

| Mode | Needs | Where it lives |
| --- | --- | --- |
| Online (rooms, matchmaking) | a Nakama server and an account | `autoload/Online.gd`, `autoload/OnlineMatch.gd` |
| Same wi-fi (LAN) | nothing at all | `autoload/LanMatch.gd` |
| **Steam (friends & invites)** | **the GodotSteam extension + the Steam client** | `autoload/SteamMatch.gd` |

Everything above the transport (`Main.gd`, `Game.gd`, `ReadyScreen`) is peer-id based
and does not know which of the three is in use. The host is always peer 1.

**The Steam mode is not installed in this repository.** The code for it is here and
it is wired into the UI, but the GodotSteam extension itself is a binary that has to
be downloaded and dropped in. Until you do that, the Steam section of the match
screen is visible but disabled, and it says why. Nothing else in the game changes.

**None of the Steam code has ever been run against a real Steam client.** It was
written against the GodotSteam documentation. What *is* tested (in
`tests/SteamTest.tscn`) is that with GodotSteam absent the game behaves exactly as it
did before: that is the part that could have broken the working modes, and it is the
only part this machine can verify. Expect to debug the live path the first time you
run it with the extension installed.

---

## 1. Install GodotSteam — and mind the version

Releases: <https://codeberg.org/godotsteam/godotsteam/releases>
Docs and downloads: <https://godotsteam.com>

You want a build whose file name ends in **`-gde`**. That is the **GDExtension**
build, which drops into a project and works with the stock Godot editor you already
have. The builds without that suffix are a *custom Godot binary* with Steam compiled
in, which you do not want here.

### Do not grab the latest release

**This project runs Godot 4.2.1.** The current GodotSteam line (v4.16 and up) targets
Godot 4.4+, and a GDExtension built for 4.4+ **will not load on 4.3 or lower**. It
fails quietly: `Engine.has_singleton("Steam")` stays false and the game carries on as
if nothing were installed, which looks exactly like not having installed it at all.

GDExtension releases that cover Godot 4.2:

| Release | Godot versions |
| --- | --- |
| **v4.14-gde** | **4.1 – 4.4  ← use this one** |
| v4.13-gde | 4.1 – 4.4 |
| v4.12-gde | 4.1 / 4.2 / 4.3 |
| v4.11-gde | 4.1 / 4.2 / 4.3 |
| v4.9-gde | 4.1.x / 4.2.x |

Use **v4.14-gde**: it is the newest release that still supports 4.2.

Note also that the GitHub mirror only lists the newer releases; the older ones are on
Codeberg, linked above.

> **About staying on 4.2.** The maintained GodotSteam line has moved on to Godot 4.4+,
> so remaining on 4.2 means remaining on an older GodotSteam. Upgrading the project's
> engine version later would let you track current releases. That is a trade-off, not
> a recommendation: this project was already ported once from Godot 3 to Godot 4, and
> that port left a long tail of runtime bugs. Another engine jump is not a small job.

### Where the files go

Unzip the release and copy the `addons/godotsteam/` folder into this project, so you
end up with:

```
PushTheGame/
  addons/
    godotsteam/
      godotsteam.gdextension
      ... platform binaries (.dylib / .so / .dll) ...
```

Then restart the Godot editor. `godotsteam.gdextension` is what registers the `Steam`
singleton and the `SteamMultiplayerPeer` class.

### Check that it actually loaded

Run this from a script or the editor's debugger:

```gdscript
print(Engine.has_singleton("Steam"))                    # must be true
print(ClassDB.class_exists("SteamMultiplayerPeer"))     # must be true
```

Both must print `true`.

- The first being false means the extension did not load — almost always the
  Godot-version mismatch above, or a macOS quarantine flag on the `.dylib`
  (`xattr -dr com.apple.quarantine addons/godotsteam`).
- The second being false means you have a GodotSteam build without the multiplayer
  peer. `SteamMultiplayerPeer` lives in the **main** GodotSteam branches; it used to
  be a separate `-mp` repository (`v4.10-mp`, `v4.9-mp`), which is now **retired**,
  its functionality having been merged into the main branches from about v4.11
  onward. v4.14-gde should include it — verify rather than assume.

The game checks both of these itself: `SteamMatch.is_available()` and
`SteamMatch.has_multiplayer_peer()`. If the peer is missing you get lobbies and
invites but no transport, and the UI says so explicitly instead of half-working.

## 2. App ID

Steam refuses to initialise without an app ID.

- For development, use Valve's public test app **480 ("Spacewar")**. That is what
  `SteamMatch.SPACEWAR_APP_ID` defaults to. Anyone with Steam can use it; it is
  shared by every developer testing, so treat lobbies on it as public.
- For a real release you need your own app ID from
  <https://partner.steamgames.com>, which means a Steamworks account and the $100
  app fee.

To run **outside** the Steam client (from the Godot editor, for instance), put a file
called `steam_appid.txt` next to the executable, containing just the ID:

```
480
```

For the editor that means the project root (`PushTheGame/steam_appid.txt`). For an
exported game it means next to the exported binary. **Remove it from shipping
builds** — a shipped game should get its app ID from Steam itself.

Once GodotSteam is installed it also exposes **Project Settings → Steam →
Initialization → App ID**. `SteamMatch` reads that setting when it exists and falls
back to 480 otherwise, so setting it there is enough. It reads **Embed Callbacks**
from the same panel too: when that is on, GodotSteam pumps `run_callbacks()` itself
and `SteamMatch._process` stays out of the way; when it is off (the default) we pump
it every frame.

## 3. The Steam client must be running

`steamInitEx()` fails with `STEAM_API_INIT_RESULT_NO_STEAM_CLIENT` if it is not.
The failure is reported through `SteamMatch.steam_error` and shown on the match
screen; the other two transports keep working.

---

## How it is used in the game

On the match screen, under the LAN row:

- **HOST ON STEAM** — creates a *friends-only* Steam lobby (`createLobby`) and starts
  hosting on it. Friends-only rather than public on purpose: this mode is for playing
  with people you know, and a public lobby advertises the game to strangers.
- **INVITE FRIENDS** — opens Steam's own invite dialog
  (`activateGameOverlayInviteDialog`). This is the overlay, so it only draws when the
  game is running under the Steam client.
- **FRIENDS** — an in-game list of your online friends with an Invite button each
  (`inviteUserToLobby`), for when the overlay is not available.

Once the lobby is up the game moves to the ready screen, and an **INVITE FRIENDS**
button appears there too — that is where the host actually waits, and a Steam match
has no room code to read out in the meantime.

On the other side, a friend who accepts the invite:

- **with the game running** — Steam raises `join_requested(lobby, steam_id)`, which
  `SteamMatch` turns into its own `invite_accepted` signal, which `OnlineMatch` turns
  into a join. The player lands in the ready screen without touching anything.
- **with the game closed** — Steam launches the game with `+connect_lobby <lobby id>`
  on the command line. `SteamMatch` parses that at boot into `pending_invite_lobby`,
  and `Main.gd` acts on it once every autoload is up.

Names and chosen characters are announced peer to peer over the existing
`_lan_announce_player` RPC, exactly as on a LAN — Steam gives us a persona name, but
not the display name this game uses or the character the player picked.

**Steam multiplayer only works between Steam users who own the game.** Both ends need
the Steam client, the app in their library, and each other on their friends list. It
is not a replacement for the Nakama mode (which works for anyone with an account) or
the LAN mode (which works for anyone on the same wi-fi) — it is a third option
alongside them.

## GodotSteam API this depends on

If a future GodotSteam release changes any of these, this is the list to re-check.
All of it goes through `_steam_call()` in `autoload/SteamMatch.gd`, which checks the
method exists first, so a rename degrades into a clear error message rather than a
crash.

| Call | Used for |
| --- | --- |
| `steamInitEx(app_id, embed_callbacks) -> Dictionary` | start-up; `status` / `verbal` keys |
| `run_callbacks()` | pumped every frame from `_process` |
| `isSteamRunning()` | diagnostics |
| `createLobby(lobby_type, max_members)` | hosting |
| `joinLobby(id)` / `leaveLobby(id)` | joining / leaving |
| `setLobbyData(id, key, value)` / `setLobbyJoinable(id, bool)` | lobby metadata |
| `inviteUserToLobby(lobby, friend)` | the in-game friend list |
| `getFriendCount(flags)` / `getFriendByIndex(i, flags)` | the friend list |
| `getFriendPersonaName(id)` / `getFriendPersonaState(id)` | friend names, online filter |
| `getPersonaName()` / `getSteamID()` | our own identity |
| `activateGameOverlayInviteDialog(lobby)` | the INVITE FRIENDS button |
| `SteamMultiplayerPeer.host_with_lobby(lobby)` | the host transport |
| `SteamMultiplayerPeer.connect_to_lobby(lobby)` | the client transport |

Signals: `lobby_created(connect, lobby)`, `lobby_joined(lobby_id, permissions, locked,
response)`, `lobby_chat_update(...)`, `lobby_invite(inviter, lobby, game)`,
`join_requested(lobby, steam_id)`.

`lobby_joined` is documented with four parameters today and had three in older
releases, and connecting a callable with the wrong number of parameters is a hard
error in Godot 4. So signals are not connected directly: `SteamMatch.connect_adapting()`
reads the real parameter count off the singleton at runtime and unbinds any extra.
That adapter is covered by `tests/SteamTest.tscn`, which is the one piece of
Steam-facing logic that can be tested without Steam.

## Testing it for real (what nobody here has done)

1. Install v4.14-gde as above and confirm the two `print()` checks.
2. Put `480` in `steam_appid.txt` in the project root.
3. Start the Steam client and sign in.
4. Run the game. The Steam row on the match screen should say
   `Signed in as <your persona name>` instead of the "not installed" message.
5. Press HOST ON STEAM, then INVITE FRIENDS, and invite a second Steam account that
   also has the game.
6. On the second machine, accept. It should land straight in the ready screen.

If step 4 still shows a message, read it — `SteamMatch` reports the reason from
Steam's own `verbal` field rather than a generic failure.
