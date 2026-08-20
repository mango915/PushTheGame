#!/usr/bin/env python3
"""Generate a sprite by editing existing art, then project it onto the style.

Drives Qwen-Image-Edit-2511 on a remote ComfyUI (scatoletta) over its HTTP API,
and pipes the result through tools/style_normalize.py. See docs/synthetic-art.md.

The reason this is an EDIT model rather than a text-to-image one: we are not
asking for a character, we already have four. We are asking for the character we
already have, holding the weapon we already have. Qwen-Image-Edit-2511 takes up
to three reference images alongside the instruction, so "the character from
image 1 holding the sword from image 2" is one node and not a LoRA training run.

Style fidelity is NOT this model's job -- see the module docstring in
style_normalize.py. It needs to get the SHAPE right; the projection afterwards
forces the palette. That division is what makes a handful of sprites tractable
without training anything.

Usage:
    tools/gen_sprite.py --character char_chili --weapon weapon_sword \\
        --prompt "holding the sword in its right hand, arm extended" \\
        --out /tmp/chili_sword.png
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SPRITES = os.path.join(REPO, "assets", "doodle", "sprites")

DEFAULT_SERVER = "scatoletta:8188"

UNET = "qwen-image-edit-2511-Q8_0.gguf"
CLIP = "qwen_2.5_vl_7b.safetensors"
VAE = "qwen_image_vae.safetensors"

# The SD1.5 pipeline, for comparison against Qwen-Image-Edit.
#
# Qwen at 20B measured 1197 s/it on the 8-core CPU box -- about twice what the
# raw FLOP count predicts, so it is model SIZE, not a misconfiguration, and
# 20 steps would be nearly seven hours per image. SD1.5 is 0.86B: ~23x smaller.
#
# It cannot follow an instruction the way an edit model can, so identity comes
# from IP-Adapter conditioning on the reference sprite instead of from a
# sentence. That is a real downgrade in control -- but style, palette, ink and
# outline weight are all forced afterwards by style_normalize, so the only thing
# actually being asked of the model is the SHAPE. A weaker model is allowed to
# be enough, and this comparison is what decides whether it is.
SD15_CKPT = "v1-5-pruned-emaonly-fp16.safetensors"
SD15_IPADAPTER = "ip-adapter-plus_sd15.safetensors"
SD15_CLIP_VISION = "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

# Flat magenta backdrop, keyed out afterwards by style_normalize --bg. Asking for
# a known backdrop beats running a matting model: nothing in the palette is near
# magenta, so the cut is exact and costs nothing.
BACKDROP = "#ff00ff"

# Describes the art as MEASURED, not as remembered. A scanline through a
# character reads, from the outside in: ~2px dark outline, ~4px WHITE band, then
# the flat colour fill. That white band is 22% of the sprite -- more of it than
# there is ink -- so a prompt that says only "black outline, flat colours" asks
# for a different character design and gets one.
STYLE_SUFFIX = (
    "hand-drawn doodle style, thick dark outline with a broad white band just "
    "inside the outline, flat solid colour fill, simple white facial features, "
    "no shading, no gradients, no texture, plain flat magenta background, "
    "full body, centred, side view"
)

# Steps are low because the projection absorbs the noise a short schedule leaves
# in the fill. On CPU each step costs minutes, so this is the single biggest
# lever on turnaround -- and the usual reason to spend more steps (clean, subtly
# shaded surfaces) is a property we throw away one stage later.
DEFAULT_STEPS = 20
DEFAULT_CFG = 2.5


def _post(server, path, payload, is_json=True):
    url = f"http://{server}{path}"
    data = json.dumps(payload).encode() if is_json else payload
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"}
                                 if is_json else {})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # ComfyUI puts the reason a graph was rejected in the BODY of its 400 --
        # which node, which input, and what it expected. Letting HTTPError
        # propagate turns every graph mistake into an opaque "Bad Request" and
        # throws away the one thing that would fix it.
        body = e.read().decode("utf-8", "replace")
        try:
            detail = json.dumps(json.loads(body), indent=2)
        except ValueError:
            detail = body
        raise SystemExit("ComfyUI %s on %s:\n%s" % (e.code, path, detail[:3000]))


def _get(server, path, raw=False, timeout=60):
    with urllib.request.urlopen(f"http://{server}{path}", timeout=timeout) as r:
        return r.read() if raw else json.load(r)


def upload_image(server, path):
    """Push a reference image into ComfyUI's input folder."""
    name = os.path.basename(path)
    boundary = uuid.uuid4().hex
    body = b""
    for field, value in (("overwrite", b"true"),):
        body += (f"--{boundary}\r\nContent-Disposition: form-data; "
                 f'name="{field}"\r\n\r\n').encode() + value + b"\r\n"
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; "
             f'filename="{name}"\r\n'
             "Content-Type: image/png\r\n\r\n").encode()
    body += open(path, "rb").read() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"http://{server}/upload/image", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["name"]


def build_graph(prompt, refs, seed, steps, cfg, size):
    """ComfyUI API-format graph: {node_id: {class_type, inputs}}."""
    w, h = size
    g = {
        "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": UNET}},
        "2": {"class_type": "CLIPLoader",
              "inputs": {"clip_name": CLIP, "type": "qwen_image"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "10": {"class_type": "EmptySD3LatentImage",
               "inputs": {"width": w, "height": h, "batch_size": 1}},
    }
    pos = {"clip": ["2", 0], "vae": ["3", 0],
           "prompt": f"{prompt}. {STYLE_SUFFIX}"}
    for i, ref in enumerate(refs[:3], start=1):
        nid = str(20 + i)
        g[nid] = {"class_type": "LoadImage",
                  "inputs": {"image": ref, "upload": "image"}}
        pos[f"image{i}"] = [nid, 0]
    g["30"] = {"class_type": "TextEncodeQwenImageEditPlus", "inputs": pos}
    # Negative conditioning gets the same reference images. Omitting them makes
    # the two conditionings differ in more than the text, which turns CFG into a
    # lever on "with vs without references" rather than on the instruction.
    neg = dict(pos)
    neg["prompt"] = ("photorealistic, 3d render, soft shading, gradient, "
                     "blurry, grainy, thin faint outline, drop shadow, text")
    g["31"] = {"class_type": "TextEncodeQwenImageEditPlus", "inputs": neg}
    g["40"] = {"class_type": "KSampler", "inputs": {
        "model": ["1", 0], "positive": ["30", 0], "negative": ["31", 0],
        "latent_image": ["10", 0], "seed": seed, "steps": steps, "cfg": cfg,
        "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}}
    g["50"] = {"class_type": "VAEDecode",
               "inputs": {"samples": ["40", 0], "vae": ["3", 0]}}
    g["60"] = {"class_type": "SaveImage",
               "inputs": {"images": ["50", 0], "filename_prefix": "ptg_sprite"}}
    return g


def build_graph_sd15(prompt, refs, seed, steps, cfg, size,
                     ip_weight=0.85, weapon_weight=0.35, ip_end=0.7):
    """SD1.5 + IP-Adapter: identity from the reference image, not the prompt."""
    w, h = size
    g = {
        "1": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": SD15_CKPT}},
        "2": {"class_type": "IPAdapterModelLoader",
              "inputs": {"ipadapter_file": SD15_IPADAPTER}},
        "3": {"class_type": "CLIPVisionLoader",
              "inputs": {"clip_name": SD15_CLIP_VISION}},
        "4": {"class_type": "LoadImage",
              "inputs": {"image": refs[0], "upload": "image"}},
        # Character identity. end_at < 1.0 on purpose: IP-Adapter held for the
        # whole schedule reproduces the reference so faithfully that the prompt
        # never gets to add anything -- the first run came back as the input
        # character with no sword at all. Releasing it partway leaves the late,
        # detail-forming steps to the text.
        "10": {"class_type": "IPAdapterAdvanced", "inputs": {
            "model": ["1", 0], "ipadapter": ["2", 0], "image": ["4", 0],
            "clip_vision": ["3", 0],
            "weight": ip_weight, "weight_type": "linear",
            "combine_embeds": "concat", "start_at": 0.0, "end_at": ip_end,
            "embeds_scaling": "V only"}},
        "20": {"class_type": "CLIPTextEncode",
               "inputs": {"clip": ["1", 1],
                          "text": "%s. %s" % (prompt, STYLE_SUFFIX)}},
        "21": {"class_type": "CLIPTextEncode",
               "inputs": {"clip": ["1", 1],
                          "text": "photorealistic, 3d render, soft shading, "
                                  "gradient, blurry, grainy, thin faint "
                                  "outline, drop shadow, text, watermark"}},
        "30": {"class_type": "EmptyLatentImage",
               "inputs": {"width": w, "height": h, "batch_size": 1}},
        "40": {"class_type": "KSampler", "inputs": {
            "model": ["10", 0], "positive": ["20", 0], "negative": ["21", 0],
            "latent_image": ["30", 0], "seed": seed, "steps": steps,
            "cfg": cfg, "sampler_name": "dpmpp_2m", "scheduler": "karras",
            "denoise": 1.0}},
        "50": {"class_type": "VAEDecode",
               "inputs": {"samples": ["40", 0], "vae": ["1", 2]}},
        "60": {"class_type": "SaveImage",
               "inputs": {"images": ["50", 0],
                          "filename_prefix": "ptg_sd15"}},
    }
    model_out = "10"
    # The weapon, as a second and much weaker reference. The first run uploaded
    # it and never wired it in -- the graph only ever read refs[0] -- so "the
    # sword from image 2" was asking the model to invent a sword it had never
    # been shown.
    if len(refs) > 1 and weapon_weight > 0.0:
        g["5"] = {"class_type": "LoadImage",
                  "inputs": {"image": refs[1], "upload": "image"}}
        g["11"] = {"class_type": "IPAdapterAdvanced", "inputs": {
            "model": ["10", 0], "ipadapter": ["2", 0], "image": ["5", 0],
            "clip_vision": ["3", 0],
            "weight": weapon_weight, "weight_type": "linear",
            "combine_embeds": "concat", "start_at": 0.0, "end_at": ip_end,
            "embeds_scaling": "V only"}}
        model_out = "11"
    g["40"]["inputs"]["model"] = [model_out, 0]
    return g


def run(server, graph, poll=15, timeout=7200):
    client_id = uuid.uuid4().hex
    res = _post(server, "/prompt", {"prompt": graph, "client_id": client_id})
    if "error" in res:
        raise SystemExit("ComfyUI rejected the graph: %s"
                         % json.dumps(res, indent=2)[:1500])
    pid = res["prompt_id"]
    print("queued %s; CPU inference, expect minutes per step" % pid)
    start = time.time()
    ticks = 0
    while time.time() - start < timeout:
        time.sleep(poll)
        ticks += 1
        hist = _get(server, f"/history/{pid}")
        if pid in hist:
            entry = hist[pid]
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                raise SystemExit("run failed: %s"
                                 % json.dumps(status, indent=2)[:1500])
            for out in entry.get("outputs", {}).values():
                for img in out.get("images", []):
                    return img, time.time() - start
            raise SystemExit("finished with no image: %s" % json.dumps(entry)[:800])
        # Poll often (so the result is picked up promptly) but report rarely --
        # a 20 minute generation at a 15s poll is 80 lines of nothing.
        if ticks % 8 == 0:
            print("  ... %.0f min" % ((time.time() - start) / 60), flush=True)
    raise SystemExit("timed out after %.0f min" % (timeout / 60))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--prompt", required=True,
                    help="what to change, e.g. 'holding the sword, arm extended'")
    ap.add_argument("--character", help="sprite name in assets/doodle/sprites")
    ap.add_argument("--weapon", help="second reference sprite")
    ap.add_argument("--ref", action="append", default=[],
                    help="extra reference image path")
    ap.add_argument("--out", required=True)
    ap.add_argument("--raw", help="also keep the unprojected generation here")
    ap.add_argument("--server", default=os.environ.get("COMFY_SERVER", DEFAULT_SERVER))
    ap.add_argument("--pipeline", choices=["qwen", "sd15"], default="qwen")
    ap.add_argument("--ip-weight", type=float, default=0.85)
    ap.add_argument("--weapon-weight", type=float, default=0.35)
    ap.add_argument("--ip-end", type=float, default=0.7,
                    help="release IP-Adapter after this fraction of the schedule")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--steps", type=int, default=DEFAULT_STEPS)
    ap.add_argument("--cfg", type=float, default=DEFAULT_CFG)
    ap.add_argument("--gen-size", default="768x768")
    ap.add_argument("--size", default="48x68", help="final sprite size")
    ap.add_argument("--anchor", choices=["center", "bottom"], default="center")
    ap.add_argument("--no-project", action="store_true",
                    help="skip the style projection (for inspecting raw output)")
    args = ap.parse_args(argv)

    paths = []
    for name in (args.character, args.weapon):
        if name:
            p = name if os.path.exists(name) else os.path.join(SPRITES, name + ".png")
            if not os.path.exists(p):
                raise SystemExit("no such reference: %s" % p)
            paths.append(p)
    paths += args.ref
    if not paths:
        raise SystemExit("need at least one reference (--character/--weapon/--ref)")

    print("references: %s" % ", ".join(os.path.basename(p) for p in paths))
    refs = [upload_image(args.server, p) for p in paths]
    gw, gh = (int(v) for v in args.gen_size.lower().split("x"))
    if args.pipeline == "sd15":
        graph = build_graph_sd15(args.prompt, refs, args.seed, args.steps,
                                 args.cfg, (gw, gh), args.ip_weight,
                                 args.weapon_weight, args.ip_end)
    else:
        graph = build_graph(args.prompt, refs, args.seed, args.steps,
                            args.cfg, (gw, gh))
    img, secs = run(args.server, graph)

    q = urllib.parse.urlencode({"filename": img["filename"],
                                "subfolder": img.get("subfolder", ""),
                                "type": img.get("type", "output")})
    blob = _get(args.server, "/view?" + q, raw=True, timeout=300)
    raw_path = args.raw or (args.out + ".raw.png")
    with open(raw_path, "wb") as f:
        f.write(blob)
    print("generated in %.1f min -> %s" % (secs / 60, raw_path))

    if args.no_project:
        return 0

    sys.path.insert(0, HERE)
    import style_normalize as sn
    profile = sn.StyleProfile.from_json(
        open(os.path.join(HERE, "scribble_style.json")).read())
    pal_key = args.character if args.character in profile.palettes else None
    palette = (profile.palettes[pal_key] if pal_key else
               [p for pal in profile.palettes.values() for p in pal])
    out = sn.apply_style(sn._load(raw_path), palette, profile.ink,
                         size=tuple(int(v) for v in args.size.lower().split("x")),
                         bg=BACKDROP, anchor=args.anchor)
    from PIL import Image
    Image.fromarray(out, "RGBA").save(args.out)
    s = sn.score(out, profile, pal_key)
    print("projected -> %s   colors=%d ink=%.1f%% dom=%.1f%% aa=%.1f%%"
          % (args.out, s["colors"], 100 * s["ink_coverage"],
             100 * s["dominant_coverage"], 100 * s["aa_fraction"]))
    if pal_key:
        print("  vs %s: d_ink=%+.1f%% d_dom=%+.1f%%"
              % (pal_key, 100 * s["ink_delta"], 100 * s["dominant_delta"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
