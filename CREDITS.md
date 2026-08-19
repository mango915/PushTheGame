Credits and asset provenance
============================

Push The Game is by Jakub Skowronski, Stefano Mancone and Alessandro
Compagnucci, and derives from Heroic Labs' "Fish Game" Nakama demo.

These attributions are **load-bearing, not decoration**: Apache 2.0 (code) and
CC BY-NC (art and music) both require them. See CLAUDE.md.

Code
----

| What | Who | Licence |
| --- | --- | --- |
| Original "Fish Game" programming | David Snopek, [Snopek Games](https://www.snopekgames.com) | Apache 2.0 |
| [Snopek State Machine](https://gitlab.com/snopek-games/godot-state-machine) (`addons/snopek-state-machine/`) | David Snopek | MIT |
| [WebRTC and Nakama addon for Godot](https://gitlab.com/snopek-games/godot-nakama-webrtc) — much of the UI and networking | David Snopek | MIT |
| Nakama SDK (`addons/com.heroiclabs.nakama/`) | Heroic Labs | Apache 2.0 |

Art
---

| What | Who | Licence |
| --- | --- | --- |
| Characters and arena tiles (`assets/sprites/kings_and_pigs/`) | Orlando Herrera, [Pixel Frog](https://pixelfrog-store.itch.io/) | see `assets/LICENSE.txt` |
| Remaining original art | project authors | CC BY-NC |
| [Scribble Platformer](https://kenney.nl/assets/scribble-platformer) (`assets/doodle/sprites/`) | Kenney | CC0 |
| [1-Bit Pack](https://kenney.nl/assets/1-bit-pack) (`assets/doodle/tilesets/`) | Kenney | CC0 |
| `assets/doodle/splash_screen.png` | project authors (photo collage) | project authors |

Fonts
-----

| What | Who | Licence |
| --- | --- | --- |
| [Monogram](https://datagoblin.itch.io/monogram) | Vinícius Menézio | CC0 |
| [m5x7](https://managore.itch.io/m5x7) | Daniel Linssen (managore) | CC0 |

Music and sound
---------------

| What | Who | Licence |
| --- | --- | --- |
| Music and sound effects (`assets/music/`, `assets/sounds/`) | Jakob T. Rypdal | CC BY-NC |
| `hitHurt-2.wav`, `laserShoot.wav`, `laserShoot-2.wav` | project authors, generated with [sfxr/bfxr](https://www.bfxr.net/) | project authors |

Shaders
-------

`assets/shaders/menu_crt.gdshader` and `menu_vhs.gdshader` came from this
project's own `compa_dev` branch, where they carried no attribution. The
scanline/grille/aberration pass is the widely-shared "VHS and CRT monitor
effect" by **pend00** on [godotshaders.com](https://godotshaders.com) (MIT); the
wobble pass derives from the "bad TV" ShaderToy effect that circulates with it.
Both files carry the same note in their headers.

Deliberately NOT included
-------------------------

**`bensound-lofinerdbassbuzzer.mp3`** (from `compa_dev`) is not in this
repository. Bensound's free licence covers *online video and educational
projects only* — it does not grant the right to ship the track inside a game,
and attribution alone does not fix that. Shipping it would need a Bensound
Pro or custom licence. Buy one, or replace the track, before putting it back.
