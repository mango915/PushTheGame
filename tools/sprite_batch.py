#!/usr/bin/env python3
"""Run several sprite prompts unattended and lay the results out to be judged.

CPU inference costs roughly a quarter of an hour per image, so the useful unit
of work is not one sprite -- it is a batch left running while nobody watches,
with the results arranged so they can be compared in one look afterwards.

The contact sheet is the point, for the same reason tools/assemble_capture.py
builds a frame strip: a lone 48x68 sprite tells you almost nothing, and a folder
of them tells you less. Side by side against the reference, with each one's
style fingerprint printed underneath, differences that are invisible per-image
become obvious -- which is exactly how this project's earlier art bugs were
finally caught.

Each variant is generated, projected onto the measured style, scored, and drawn
into the sheet with its numbers. Failures are drawn too, as a labelled gap: a
missing tile is information, and silently dropping it would make a batch that
half-failed look like a batch that succeeded.

    tools/sprite_batch.py --character char_chili --weapon weapon_sword \\
        --out /tmp/sword_batch
"""

import argparse
import os
import sys
import traceback

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_sprite as gs           # noqa: E402
import style_normalize as sn      # noqa: E402

# The open question these are built to answer: can the model put an ARM on a
# character that ships as an armless capsule? Each variant attacks it from a
# different angle, because a single phrasing failing proves nothing about the
# model and a single phrasing working proves nothing about the next weapon.
DEFAULT_VARIANTS = [
    ("plain", "holding the sword in its hand"),
    ("arm", "with a thin arm extended to the side, holding the sword"),
    ("both", "with two thin stick arms, gripping the sword handle in one"),
    ("raised", "one arm raised above its head holding the sword, ready to swing"),
    ("copy-style", "give it a simple arm like the reference art and put the "
                   "sword in its hand"),
]

TILE_PAD = 8
LABEL_H = 54
ZOOM = 4


def _tile(sprite, label, lines, font_w=6):
    """One column of the sheet: the sprite, zoomed, over its numbers."""
    w = max(sprite.width * ZOOM, font_w * max(len(s) for s in [label] + lines) + 6)
    h = sprite.height * ZOOM + LABEL_H
    tile = Image.new("RGBA", (w, h), (26, 26, 32, 255))
    big = sprite.resize((sprite.width * ZOOM, sprite.height * ZOOM), Image.NEAREST)
    tile.alpha_composite(big, ((w - big.width) // 2, 0))
    d = ImageDraw.Draw(tile)
    y = sprite.height * ZOOM + 4
    d.text((3, y), label, fill=(255, 235, 190, 255))
    for line in lines:
        y += 11
        d.text((3, y), line, fill=(150, 190, 210, 255))
    return tile


def contact_sheet(entries, out_path):
    """entries: list of (label, PIL.Image or None, [lines])."""
    tiles = []
    for label, sprite, lines in entries:
        if sprite is None:
            sprite = Image.new("RGBA", (48, 68), (0, 0, 0, 0))
            d = ImageDraw.Draw(sprite)
            d.line((4, 4, 43, 63), fill=(200, 70, 70, 255), width=2)
            d.line((43, 4, 4, 63), fill=(200, 70, 70, 255), width=2)
        tiles.append(_tile(sprite, label, lines))
    w = sum(t.width for t in tiles) + TILE_PAD * (len(tiles) + 1)
    h = max(t.height for t in tiles) + TILE_PAD * 2
    sheet = Image.new("RGBA", (w, h), (16, 16, 20, 255))
    x = TILE_PAD
    for t in tiles:
        sheet.alpha_composite(t, (x, TILE_PAD))
        x += t.width + TILE_PAD
    sheet.convert("RGB").save(out_path)
    return out_path


def _fingerprint(img, profile, ref):
    s = sn.score(img, profile, ref)
    lines = ["cols %d  ink %.0f%%" % (s["colors"], 100 * s["ink_coverage"]),
             "dom %.0f%%  aa %.0f%%" % (100 * s["dominant_coverage"],
                                        100 * s["aa_fraction"])]
    if "ink_delta" in s:
        lines.append("d_ink %+.0f%%  d_dom %+.0f%%"
                     % (100 * s["ink_delta"], 100 * s["dominant_delta"]))
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--character", default="char_chili")
    ap.add_argument("--weapon", default="weapon_sword")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--server", default=os.environ.get("COMFY_SERVER",
                                                       gs.DEFAULT_SERVER))
    ap.add_argument("--steps", type=int, default=gs.DEFAULT_STEPS)
    ap.add_argument("--cfg", type=float, default=gs.DEFAULT_CFG)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--gen-size", default="768x768")
    ap.add_argument("--size", default="48x68")
    ap.add_argument("--sheet-only", action="store_true",
                    help="rebuild the sheet from files already generated")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    profile = sn.StyleProfile.from_json(
        open(os.path.join(HERE, "scribble_style.json")).read())
    size = tuple(int(v) for v in args.size.lower().split("x"))
    palette = profile.palettes.get(args.character) or [
        p for pal in profile.palettes.values() for p in pal]

    # The reference leads the sheet. Judging a generated sprite against a
    # remembered impression of the art is how style drift gets waved through.
    ref_path = os.path.join(gs.SPRITES, args.character + ".png")
    ref_img = Image.open(ref_path).convert("RGBA")
    entries = [("REFERENCE", ref_img,
                _fingerprint(sn._load(ref_path), profile, args.character))]

    gw, gh = (int(v) for v in args.gen_size.lower().split("x"))
    refs = None
    for name, prompt in DEFAULT_VARIANTS:
        out_png = os.path.join(args.out, "%s.png" % name)
        raw_png = os.path.join(args.out, "%s.raw.png" % name)
        try:
            if not args.sheet_only:
                if refs is None:
                    paths = [os.path.join(gs.SPRITES, args.character + ".png"),
                             os.path.join(gs.SPRITES, args.weapon + ".png")]
                    refs = [gs.upload_image(args.server, p) for p in paths]
                print("=== %s: %s" % (name, prompt), flush=True)
                graph = gs.build_graph(prompt, refs, args.seed, args.steps,
                                       args.cfg, (gw, gh))
                img, secs = gs.run(args.server, graph)
                import urllib.parse
                q = urllib.parse.urlencode({
                    "filename": img["filename"],
                    "subfolder": img.get("subfolder", ""),
                    "type": img.get("type", "output")})
                open(raw_png, "wb").write(
                    gs._get(args.server, "/view?" + q, raw=True, timeout=300))
                print("    %.1f min" % (secs / 60), flush=True)
            out = sn.apply_style(sn._load(raw_png), palette, profile.ink,
                                 size=size, bg=gs.BACKDROP)
            Image.fromarray(out, "RGBA").save(out_png)
            entries.append((name, Image.open(out_png).convert("RGBA"),
                            _fingerprint(out, profile, args.character)))
        except Exception as exc:                       # noqa: BLE001
            # Keep going: one bad variant must not cost the rest of a batch that
            # has already spent an hour of CPU.
            print("    FAILED: %s" % exc, flush=True)
            traceback.print_exc()
            entries.append((name, None, [str(exc)[:28]]))

    sheet = contact_sheet(entries, os.path.join(args.out, "sheet.png"))
    print("sheet -> %s (%d tiles)" % (sheet, len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
