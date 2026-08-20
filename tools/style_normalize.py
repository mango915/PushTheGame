#!/usr/bin/env python3
"""Project an image onto the Scribble art style, and score how well it fits.

The art (Kenney Scribble Platformer, see CLAUDE.md) is far more constrained than
it looks: every character sprite is FOUR flat colours -- a body colour at ~53%
coverage, white eyes at ~22%, ink at ~10%, and a light tint of the body at ~3%.
Ink is #292829 across all ten shipped sprites, not pure black. Antialiasing is
~6% of the sprite and comes from downsampling vector art, not from a brush.

That tightness is what makes synthetic art viable here. A diffusion model will
not reproduce a four-colour palette on its own -- it drifts in hue, softens the
outline, and invents shading. But if the target style is this flat, style
consistency does not have to come from the model at all: generate roughly the
right shape, then SNAP it onto the measured palette. Drift in the fill becomes
a no-op, because every fill pixel is quantised to one of four colours anyway.

So this module does two jobs:

  learn  -- measure the style fingerprint from the real art
  apply  -- project a generated image onto it
  score  -- report how far an image sits from the fingerprint, as numbers

`score` exists because "does this look right" is not a question you can answer
reliably by eye at 48x68, and definitely not in bulk. Coverage ratios are.

The idempotency check (`check`) is the load-bearing test: running `apply` over
the REAL art must barely change it. If projecting genuine Scribble art moves it,
the projection is lying about the style and would drag generated art somewhere
else entirely.
"""

import argparse
import json
import os
import sys
from dataclasses import dataclass, asdict

import numpy as np
from PIL import Image

# Colours within this Chebyshev distance are the same flat colour wearing
# resampling noise. Measured: the shipped sprites spread a single fill across
# ~300 near-duplicate RGB values, all inside this radius.
CLUSTER_TOL = 18

# A cluster below this share of the sprite is a stray artefact, not a colour in
# the palette. The real palettes bottom out at ~1.8%.
MIN_COVERAGE = 0.015

ALPHA_SOLID = 200
ALPHA_PRESENT = 8


@dataclass
class StyleProfile:
    ink: tuple            # canonical outline colour
    palettes: dict        # name -> list of [r,g,b], most-covered first
    coverage: dict        # name -> list of float, parallel to palettes
    aa_fraction: float    # share of present pixels that are partial alpha

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    @staticmethod
    def from_json(text: str) -> "StyleProfile":
        d = json.loads(text)
        return StyleProfile(tuple(d["ink"]), d["palettes"], d["coverage"],
                            d["aa_fraction"])


def _load(path: str) -> np.ndarray:
    return np.array(Image.open(path).convert("RGBA"))


def _cluster(colors: np.ndarray, counts: np.ndarray, tol: int = CLUSTER_TOL):
    """Greedy merge of near-duplicate colours, heaviest first.

    Deliberately not k-means: the number of flat colours is not known ahead of
    time and k-means would happily split one fill in two, or fuse the ink into
    a dark fill. Seeding from the most-covered colour and absorbing everything
    within tol reproduces the hand-authored palette exactly.
    """
    order = np.argsort(-counts)
    cents, weights = [], []
    for i in order:
        c = colors[i].astype(int)
        n = int(counts[i])
        for j, cc in enumerate(cents):
            if np.abs(cc - c).max() <= tol:
                weights[j] += n
                break
        else:
            cents.append(c)
            weights.append(n)
    return cents, weights


def palette_of(img: np.ndarray, tol: int = CLUSTER_TOL,
               min_coverage: float = MIN_COVERAGE):
    """The flat palette of one sprite, plus each entry's share of the sprite."""
    opaque = img[..., 3] > ALPHA_SOLID
    if not opaque.any():
        return [], []
    cols = img[..., :3][opaque]
    uniq, counts = np.unique(cols.reshape(-1, 3), axis=0, return_counts=True)
    cents, weights = _cluster(uniq, counts, tol)
    total = float(sum(weights))
    keep = [(c, w / total) for c, w in zip(cents, weights)
            if w / total >= min_coverage]
    keep.sort(key=lambda cw: -cw[1])
    return [c.tolist() for c, _ in keep], [round(w, 4) for _, w in keep]


def learn(paths, ink_lum: int = 70) -> StyleProfile:
    inks, aa_num, aa_den = [], 0, 0
    palettes, coverage = {}, {}
    for p in paths:
        img = _load(p)
        name = os.path.splitext(os.path.basename(p))[0]
        pal, cov = palette_of(img)
        if pal:
            palettes[name] = pal
            coverage[name] = cov
        alpha = img[..., 3]
        present = alpha > ALPHA_PRESENT
        aa_num += int(((alpha > ALPHA_PRESENT) & (alpha <= ALPHA_SOLID)).sum())
        aa_den += int(present.sum())
        lum = img[..., :3].astype(float).mean(2)
        m = (alpha > ALPHA_SOLID) & (lum < ink_lum)
        if m.any():
            inks.append(img[..., :3][m].astype(float).mean(0))
    ink = tuple(int(round(v)) for v in np.mean(inks, 0)) if inks else (41, 40, 41)
    return StyleProfile(ink, palettes, coverage,
                        round(aa_num / max(1, aa_den), 4))


def _key_background(img: np.ndarray, bg, tol: int = 40) -> np.ndarray:
    """Knock out a flat backdrop.

    Generated images arrive on a solid background rather than on transparency,
    so the sprite has to be cut out before anything else is measured -- palette
    coverage counts pixels, and a backdrop would dominate every ratio.

    Keying a named colour beats a learned matte here because we control the
    generation prompt: ask for the character on flat magenta and the cut is
    exact, with no model needed. `auto` samples the corners for the case where
    we did not get to choose.
    """
    rgb = img[..., :3].astype(int)
    if bg == "auto":
        h, w = rgb.shape[:2]
        corners = np.array([rgb[0, 0], rgb[0, w - 1], rgb[h - 1, 0], rgb[h - 1, w - 1]])
        bg_rgb = np.median(corners, axis=0).astype(int)
    else:
        s = bg.lstrip("#")
        bg_rgb = np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)])
    out = img.copy()
    out[..., 3] = np.where(np.abs(rgb - bg_rgb).max(2) <= tol, 0, img[..., 3])
    return out


def _snap(img: np.ndarray, palette, ink) -> np.ndarray:
    """Quantise every visible pixel to the palette, or to ink.

    This is where style consistency actually comes from. The model only has to
    get the SHAPE approximately right; hue drift, invented shading and soft
    gradients all collapse onto the same handful of colours here, so two sprites
    generated an hour apart cannot disagree about what colour the character is.
    """
    targets = np.array(list(palette) + [list(ink)], dtype=float)
    rgb = img[..., :3].astype(float)
    flat = rgb.reshape(-1, 3)
    # Chunked so a 1024x1024 source does not allocate a 1M x N x 3 temporary.
    idx = np.empty(flat.shape[0], dtype=np.int32)
    for lo in range(0, flat.shape[0], 65536):
        chunk = flat[lo:lo + 65536]
        d = ((chunk[:, None, :] - targets[None, :, :]) ** 2).sum(2)
        idx[lo:lo + 65536] = d.argmin(1)
    out = img.copy()
    out[..., :3] = targets[idx].reshape(rgb.shape).astype(np.uint8)
    return out


def _trim(img: np.ndarray, alpha_min: int = ALPHA_PRESENT) -> np.ndarray:
    ys, xs = np.where(img[..., 3] > alpha_min)
    if len(ys) == 0:
        return img
    return img[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def _resize_premultiplied(img: np.ndarray, size) -> np.ndarray:
    """Downsample without letting transparent pixels bleed their colour in.

    Straight RGBA resampling averages the RGB of fully transparent pixels into
    the edge, which fringes a cutout sprite with whatever happened to be in the
    unused channel. Premultiplying, resampling, then dividing back out is the
    standard fix, and it is what produces the ~6% soft edge the real art has --
    the antialiasing is a consequence of the downsample, exactly as it was when
    Kenney rendered these from vectors.
    """
    a = img[..., 3:4].astype(float) / 255.0
    pm = np.concatenate([img[..., :3].astype(float) * a, a * 255.0], axis=2)
    small = np.array(Image.fromarray(pm.astype(np.uint8), "RGBA")
                     .resize(size, Image.LANCZOS)).astype(float)
    sa = np.clip(small[..., 3:4], 0, 255)
    with np.errstate(divide="ignore", invalid="ignore"):
        rgb = np.where(sa > 0, small[..., :3] / (sa / 255.0), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 255), sa], axis=2)
    return out.astype(np.uint8)


def apply_style(img: np.ndarray, palette, ink, size=None, bg=None,
                anchor: str = "center", trim: bool = True) -> np.ndarray:
    # trim=False keeps the canvas as-is, which the idempotency check needs: the
    # shipped sprites carry transparent padding (a 48x68 canvas around a 43x64
    # character), so cropping it would make every reference art file "fail" on a
    # difference the projection never introduced.
    if bg:
        img = _key_background(img, bg)
    img = _snap(img, palette, ink)
    if trim:
        img = _trim(img)
    if size is None:
        return img
    tw, th = size
    h, w = img.shape[:2]
    scale = min(tw / w, th / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    small = _resize_premultiplied(img, (nw, nh))
    canvas = np.zeros((th, tw, 4), dtype=np.uint8)
    x = (tw - nw) // 2
    y = th - nh if anchor == "bottom" else (th - nh) // 2
    canvas[y:y + nh, x:x + nw] = small
    return canvas


def score(img: np.ndarray, profile: StyleProfile, reference: str = None) -> dict:
    """How far this image sits from the measured style, as numbers.

    Judging a 48x68 sprite by eye does not scale and is not reliable -- which is
    the whole reason the earlier art bugs in this project went unnoticed until
    they were laid out in a frame strip. Coverage ratios are checkable in bulk
    and do not care how small the image is.
    """
    pal, cov = palette_of(img)
    ink = np.array(profile.ink, dtype=float)
    ink_cov = sum(c for p, c in zip(pal, cov)
                  if np.abs(np.array(p, float) - ink).max() <= CLUSTER_TOL * 2)
    alpha = img[..., 3]
    present = int((alpha > ALPHA_PRESENT).sum())
    aa = int(((alpha > ALPHA_PRESENT) & (alpha <= ALPHA_SOLID)).sum())
    out = {
        "colors": len(pal),
        "ink_coverage": round(ink_cov, 4),
        "dominant_coverage": round(cov[0], 4) if cov else 0.0,
        "aa_fraction": round(aa / max(1, present), 4),
        "palette": ["#%02x%02x%02x" % tuple(p) for p in pal],
    }
    if reference and reference in profile.coverage:
        ref_cov = profile.coverage[reference]
        ref_pal = profile.palettes[reference]
        ref_ink = sum(c for p, c in zip(ref_pal, ref_cov)
                      if np.abs(np.array(p, float) - ink).max() <= CLUSTER_TOL * 2)
        out["ink_delta"] = round(ink_cov - ref_ink, 4)
        out["dominant_delta"] = round(
            (cov[0] if cov else 0.0) - (ref_cov[0] if ref_cov else 0.0), 4)
        out["colors_delta"] = len(pal) - len(ref_pal)
    return out


PROFILE_PATH = os.path.join(os.path.dirname(__file__), "scribble_style.json")


def _size(text: str):
    w, h = text.lower().split("x")
    return int(w), int(h)


def _cmd_learn(args) -> int:
    profile = learn(args.inputs)
    with open(args.out, "w") as f:
        f.write(profile.to_json())
    print("ink #%02x%02x%02x   aa %.1f%%   %d sprite(s)"
          % (*profile.ink, 100 * profile.aa_fraction, len(profile.palettes)))
    for name, pal in profile.palettes.items():
        cov = profile.coverage[name]
        entries = " ".join("#%02x%02x%02x(%.0f%%)" % (*p, 100 * c)
                           for p, c in zip(pal, cov))
        print("  %-18s %s" % (name, entries))
    print("wrote %s" % args.out)
    return 0


def _cmd_apply(args) -> int:
    profile = StyleProfile.from_json(open(args.profile).read())
    if args.palette_from:
        palette = profile.palettes[args.palette_from]
    else:
        palette = [p for pal in profile.palettes.values() for p in pal]
    out = apply_style(_load(args.input), palette, profile.ink,
                      size=_size(args.size) if args.size else None,
                      bg=args.bg, anchor=args.anchor)
    Image.fromarray(out, "RGBA").save(args.out)
    s = score(out, profile, args.palette_from)
    print("%s -> %s  %dx%d  colors=%d ink=%.1f%% aa=%.1f%%"
          % (args.input, args.out, out.shape[1], out.shape[0],
             s["colors"], 100 * s["ink_coverage"], 100 * s["aa_fraction"]))
    return 0


def _cmd_score(args) -> int:
    profile = StyleProfile.from_json(open(args.profile).read())
    for path in args.inputs:
        name = os.path.splitext(os.path.basename(path))[0]
        ref = name if name in profile.palettes else args.reference
        s = score(_load(path), profile, ref)
        extra = ""
        if "ink_delta" in s:
            extra = "  d_ink=%+.1f%% d_dom=%+.1f%% d_colors=%+d" % (
                100 * s["ink_delta"], 100 * s["dominant_delta"], s["colors_delta"])
        print("%-26s colors=%-3d ink=%5.1f%% dom=%5.1f%% aa=%5.1f%%%s"
              % (os.path.basename(path), s["colors"], 100 * s["ink_coverage"],
                 100 * s["dominant_coverage"], 100 * s["aa_fraction"], extra))
    return 0


def _cmd_check(args) -> int:
    """Idempotency: projecting the REAL art must barely move it.

    This is the only evidence that the projection encodes the actual style
    rather than some nearby style of its own invention. It runs before any model
    is downloaded, because if it fails there is no point generating anything --
    every synthetic sprite would be pulled toward the wrong target.
    """
    profile = StyleProfile.from_json(open(args.profile).read())
    worst, failures = 0.0, 0
    for path in args.inputs:
        name = os.path.splitext(os.path.basename(path))[0]
        if name not in profile.palettes:
            continue
        original = _load(path)
        projected = apply_style(original.copy(), profile.palettes[name],
                                profile.ink, trim=False)
        if projected.shape != original.shape:
            print("[style] FAIL: %s changed shape %s -> %s"
                  % (name, original.shape, projected.shape))
            failures += 1
            continue
        # The invariant is NOT "nothing moves" -- it is "the projection is a
        # no-op on colours that are already in the palette".
        #
        # Downsampled vector art antialiases its INTERIOR edges as well as its
        # silhouette, so a sprite carries a few hundred fully-opaque pixels that
        # are blends between two flat colours (#4b4b4b between ink and grey,
        # #e3e3e3 between white and body). Those are not palette members and
        # reassigning them is precisely the tool's job -- counting them as drift
        # measured the art's antialiasing rather than the projection's fidelity,
        # and made all four characters "fail" at almost exactly their ink
        # coverage. Blend share is reported alongside so it stays visible.
        alpha = original[..., 3]
        solid = alpha > ALPHA_SOLID
        targets = np.array(list(profile.palettes[name]) + [list(profile.ink)],
                           dtype=int)
        rgb = original[..., :3].astype(int)
        dist = np.abs(rgb[..., None, :] - targets[None, None, :, :]).max(3)
        on_palette = solid & (dist.min(2) <= CLUSTER_TOL)
        blend = solid & ~on_palette
        delta = np.abs(rgb - projected[..., :3].astype(int)).max(2)
        moved = (float((delta[on_palette] > CLUSTER_TOL).mean())
                 if on_palette.any() else 0.0)
        blend_share = float(blend.sum()) / max(1, int(solid.sum()))
        worst = max(worst, moved)
        status = "OK" if moved <= args.tolerance else "FAIL"
        if status == "FAIL":
            failures += 1
        print("[style] %s: %s %.2f%% of on-palette pixels moved "
              "(%.1f%% of the sprite is blend)"
              % (status, name, 100 * moved, 100 * blend_share))
    print("[style] worst %.2f%% (tolerance %.2f%%), %d failure(s)"
          % (100 * worst, 100 * args.tolerance, failures))
    return 1 if failures else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("learn", help="measure the style from reference art")
    p.add_argument("inputs", nargs="+")
    p.add_argument("--out", default=PROFILE_PATH)
    p.set_defaults(fn=_cmd_learn)

    p = sub.add_parser("apply", help="project an image onto the style")
    p.add_argument("input")
    p.add_argument("out")
    p.add_argument("--profile", default=PROFILE_PATH)
    p.add_argument("--palette-from", help="use this sprite's palette only")
    p.add_argument("--size", help="e.g. 48x68")
    p.add_argument("--bg", help="backdrop to key out: 'auto' or #RRGGBB")
    p.add_argument("--anchor", choices=["center", "bottom"], default="center")
    p.set_defaults(fn=_cmd_apply)

    p = sub.add_parser("score", help="report style fingerprint")
    p.add_argument("inputs", nargs="+")
    p.add_argument("--profile", default=PROFILE_PATH)
    p.add_argument("--reference", help="compare against this sprite")
    p.set_defaults(fn=_cmd_score)

    p = sub.add_parser("check", help="idempotency over the reference art")
    p.add_argument("inputs", nargs="+")
    p.add_argument("--profile", default=PROFILE_PATH)
    p.add_argument("--tolerance", type=float, default=0.02)
    p.set_defaults(fn=_cmd_check)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
