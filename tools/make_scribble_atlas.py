#!/usr/bin/env python3
"""Compose the arena atlas used by tools/build_maps.gd from Kenney's Scribble
Platformer sheet.

WHY A DERIVED ATLAS RATHER THAN POINTING AT THE SHEET DIRECTLY

build_maps.gd addresses art by 16px CELL coordinates and treats every 2x2 cell
block as one 32px art tile, with a full nine-slice at fixed coordinates. The
Scribble sheet is an 11x11 grid of 128px tiles with no nine-slice at all. Rather
than rewrite the generator's addressing (and with it every arena and the
reachability proof), this bakes the chosen scribble tiles into a texture laid
out exactly where build_maps.gd already looks.

The nine-slice slots all get the SAME block. That is not laziness: each scribble
tile is drawn with its own outline, so a wall reads as a stack of sketched
bricks and edge caps would fight that rather than help it.

Usage:  python3 tools/make_scribble_atlas.py
        <re-import in Godot>            # see below
        godot --headless --path . --script res://tools/build_maps.gd

IMPORTANT: rewriting this PNG is not enough on its own. Godot serves textures
from its import cache under .godot/imported/, so build_maps.gd will happily
rebuild the tilesets against the PREVIOUS version of this file and report zero
errors while doing it. The maps then ship art nobody chose. Let the editor
re-import (scripts/check.sh does it, or run `godot --headless --editor --path .`
briefly) between regenerating this atlas and rebuilding the maps.
"""
from PIL import Image

SRC = "assets/doodle/sprites/spritesheet_retina.png"
DST = "assets/doodle/tilesets/scribble_arena.png"
SRC_TILE = 128
CELL = 16
BLOCK = 32

# (col, row) in the source sheet.
BRICK = (5, 5)   # solid terrain
# The jump-through platform is the TOP BAND of the same block rather than a
# separate thin bar. A one-tile-high sliver of line art reads as a scratch on
# the background; a cropped brick edge reads as a ledge, and it keeps the
# one-way platforms in the same visual language as the terrain around them.
LEDGE_BAND = 13  # px of the block's top edge to keep

# Top-left CELL of each 2x2 art tile, mirroring build_maps.gd's constants.
TERRAIN_SLOTS = [
    (2, 2), (4, 2), (6, 2),      # T_TL  T_T   T_TR
    (2, 4), (4, 4), (6, 4),      # T_L   T_C   T_R
    (2, 6), (4, 6), (6, 6),      # T_BL  T_B   T_BR
    (2, 10), (4, 10), (6, 10),   # horizontal strip
    (10, 2), (10, 4), (10, 6),   # vertical column
    (10, 10),                    # isolated block
]
# Kept clear of the terrain strip above: the two tilesets share one texture, and
# they no longer want the same shape there.
ONEWAY_SLOTS = [(2, 14), (4, 14), (6, 14), (8, 14)]

CELLS_W, CELLS_H = 16, 16


def cut(sheet, col, row, size):
    box = (col * SRC_TILE, row * SRC_TILE, (col + 1) * SRC_TILE, (row + 1) * SRC_TILE)
    return sheet.crop(box).resize((size, size), Image.LANCZOS)


def main():
    sheet = Image.open(SRC).convert("RGBA")
    out = Image.new("RGBA", (CELLS_W * CELL, CELLS_H * CELL), (0, 0, 0, 0))

    brick = cut(sheet, *BRICK, size=BLOCK)
    for cx, cy in TERRAIN_SLOTS:
        out.alpha_composite(brick, (cx * CELL, cy * CELL))

    # The one-way TileSet puts its collision on the TOP cell row only, so the
    # art has to sit in the top half of its tile or the ledge floats above the
    # surface players actually stand on.
    ledge = Image.new("RGBA", (BLOCK, BLOCK), (0, 0, 0, 0))
    ledge.alpha_composite(brick.crop((0, 0, BLOCK, LEDGE_BAND)), (0, 0))
    for cx, cy in ONEWAY_SLOTS:
        out.alpha_composite(ledge, (cx * CELL, cy * CELL))

    out.save(DST)
    print("wrote %s (%dx%d)" % (DST, out.width, out.height))


if __name__ == "__main__":
    main()
