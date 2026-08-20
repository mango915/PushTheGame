# Synthetic art

In-house sprites, generated locally, for testing gameplay that the Kenney
Scribble pack has no art for — held-weapon poses above all. The pack gives each
character a single capsule with no arms, so "the sword sits beside the character
instead of in a hand" is not a code bug and cannot be fixed in code.

## Why this is tractable here

Generating a good image is easy. Generating the *same character* twice, in the
same style, is the hard part — that is the objection this pipeline has to answer.

It is answerable because the target style is extraordinarily tight. Measured
across the eight shipped sprites (`tools/style_normalize.py learn`):

| sprite | body | white band | ink | tint |
|---|---|---|---|---|
| char_butter | `#ffb600` 52% | 22% | 9% | 3% |
| char_chili  | `#fc5c65` 54% | 22% | 10% | 3% |
| char_moody  | `#9179ff` 52% | 24% | 10% | 3% |
| char_sprout | `#37d98c` 54% | 22% | 10% | 4% |

Four flat colours, in near-identical proportions, with a canonical ink of
`#282828` — not pure black — across all ten art files. The ~6% soft edge is a
downsampling artefact of vector source art, not a brush.

A scanline through a character reads, from the outside in: **~2px dark outline,
~4px white band, then the flat fill** (facial features are white too). That white
band is 22% of the sprite — more of it than there is ink — and it is easy to
mistake for "white eyes" from the coverage table alone. Prompting for "thick
black outline, flat colours" without it describes a different character design
and gets one. Measure the art; do not describe it from memory.

That changes where consistency comes from. **The model does not have to hold the
style; it only has to get the shape roughly right.** Hue drift, invented shading
and soft gradients all collapse onto the same four colours when the output is
snapped to the measured palette. Two sprites generated an hour apart cannot
disagree about what colour a character is, because neither of them chooses.

This is the general technique for stylised 2D: move style consistency out of
sampling, which is unreliable, and into a deterministic post-process, which is
not. It works in proportion to how flat the target style is, and this one is
about as flat as they come.

## The tool

`tools/style_normalize.py` — four subcommands:

```bash
# Measure the style from the real art (writes tools/scribble_style.json)
python3 tools/style_normalize.py learn assets/doodle/sprites/*.png

# Project a generated image onto it
python3 tools/style_normalize.py apply gen.png out.png \
    --palette-from char_chili --size 48x68 --bg '#ff00ff' --anchor bottom

# Score any image against the fingerprint
python3 tools/style_normalize.py score out.png --reference char_chili

# Prove the projection is faithful
python3 tools/style_normalize.py check assets/doodle/sprites/*.png
```

`score` matters more than it looks. A 48x68 sprite cannot be reliably judged by
eye, and definitely not in bulk — that is exactly how this project's earlier art
bugs survived until they were laid out in a frame strip (see
`tools/assemble_capture.py`). Coverage ratios are checkable in bulk and do not
care how small the image is. A candidate that comes back at 40% ink is off-style
whatever it looks like.

### The check is the load-bearing part

`check` asserts one invariant: **the projection is a no-op on colours already in
the palette.** Currently 0.00% on every character and every weapon.

Getting to that number took two wrong versions of the test, both worth recording
because both looked like art failures rather than test failures:

1. Comparing a trimmed result against an untrimmed original. `apply` crops
   transparent padding; the shipped sprites carry it (a 48x68 canvas around a
   43x64 character). Every file "failed" on a difference the projection never
   introduced. Hence `apply_style(trim=False)`.
2. Counting antialiased pixels as drift. An AA pixel is a blend of two palette
   colours, so it is not itself a palette member and snapping it is correct
   behaviour. Excluding *partial-alpha* pixels was not enough: downsampled vector
   art antialiases its **interior** edges too, so a sprite carries a few hundred
   fully-opaque blends (`#4b4b4b` between ink and grey, `#e3e3e3` between white
   and body). All four characters "failed" at almost exactly their ink coverage —
   a suspicious coincidence that turned out to be the tell.

The lesson generalises: when a measurement lands suspiciously close to a
quantity you already know, suspect the measurement.

### Cut the backdrop as a snap target, not with a threshold

Generated art arrives on a flat backdrop (prompt for magenta; nothing in the
palette is near it) and has to be cut out. The obvious way — threshold anything
within tolerance of the backdrop colour — is wrong, and wrong in the most
expensive place.

A generated silhouette has a soft edge, so the pixels along it are blends of
backdrop and *outline*. A fixed tolerance cuts a band of those and takes the
outline with them. Measured on a simulated generation (real art, upscaled onto
magenta, blurred, hue-shifted, gradient-shaded):

| | ink | dominant | aa | opaque px |
|---|---|---|---|---|
| reference | 10.3% | 53.5% | 6.0% | 2217 |
| threshold key | **4.8%** | 61.7% | 9.2% | 1737 |
| backdrop as snap target | **9.7%** | 51.1% | 5.1% | 2515 |

Making the backdrop one more entry in the snap targets puts the decision
boundary exactly halfway between "mostly backdrop" and "mostly ink", so a pixel
only vanishes when it really is more backdrop than character. Half the outline
came back, and every metric landed within ~2.5% of the reference.

Worth noting how this was caught: by faking a generation and measuring it, not
by generating one. The failure was invisible in the output image — it just
looked like a slightly thinner sprite.

## Pipeline order

Generate large, project, *then* downsample. In that order the ~6% soft edge is
produced by the downsample — the same way Kenney's own art got it, rendering
vectors at retina and scaling down. Projecting after the downsample instead would
harden every edge and lose it. `_resize_premultiplied` handles the alpha so
transparent pixels do not bleed their colour into the cutout.

Round-tripping the real art through an 8x upscale, a heavy Gaussian blur, the
projection and back to 48x68 recovers dominant coverage to within 1.5%:

```
char_butter    ref: dom=52.4% ink=9.4%   out: dom=51.1% ink=7.9%
char_chili     ref: dom=53.5% ink=10.3%  out: dom=53.0% ink=9.0%
char_moody     ref: dom=51.5% ink=10.2%  out: dom=52.0% ink=8.8%
char_sprout    ref: dom=53.8% ink=9.6%   out: dom=53.9% ink=7.5%
```

Ink erodes (9.4% → 7.9%) because blur eats thin outlines. That is not noise — it
is the characteristic failure of generated line art, and the fingerprint turns it
into a number you can gate on rather than a hunch.

## Hardware

Two machines, and the split is deliberate.

| | workstation (RTX 2080, 8 GB) | `scatoletta` (Ryzen 9 8945HS, 96 GB, no GPU) |
|---|---|---|
| Qwen-Image-Edit (20B) | Q2_K / Q3_K_S only | Q8_0, or BF16 with room to spare |
| speed | seconds | ~10–25 min/image at sprite resolution |
| role | prompt iteration | the sprites we actually ship |

8 GB forces the low quants, and their documented artefact is "noticeably softer"
— which is the one artefact a hard-ink style cannot absorb. Since this is a
finite, one-time set of assets, wall-clock is the cheapest thing to spend. The
workstation is also at 99% disk (5.7 GB free), so it could not host the models
regardless.

Model choice: **Qwen-Image-Edit-2511**, which takes up to three reference images
plus an instruction ("the character from image 1, holding the sword from image 2,
same line style"). Instruction-driven editing from references is a much better
fit than text-to-image plus IP-Adapter/ControlNet, which is what most tutorials
still describe. The text encoder is the full-precision
`qwen_2.5_vl_7b.safetensors`, not `fp8_scaled` — fp8 is a GPU storage format that
on CPU buys nothing and costs an upcast.

Layout on `scatoletta` (`/data2`, 904 GB free):

```
/data2/ai/venv                  python + torch CPU
/data2/ai/comfy                 ComfyUI + ComfyUI-GGUF
/data2/ai/models/{unet,text_encoders,vae}
/data2/ai/hf                    HF_HOME
```

Relocating model storage needs no symlinks: `export HF_HOME=…` for
diffusers/huggingface, and `extra_model_paths.yaml` (`base_path:`) for ComfyUI.

## Licensing

Anything generated here is for **testing**, and must not ship without a
deliberate decision recorded in `CREDITS.md`. The shipped art is Kenney's
Scribble Platformer (CC0) and the attributions in `README.md`, the Credits screen
and `assets/LICENSE.txt` are licence compliance, not decoration — see `CLAUDE.md`.
Synthetic art derived from CC0 references does not inherit an obligation, but
mixing generated and hand-authored art without saying which is which is exactly
how attribution gets lost.
