#!/usr/bin/env python3
"""Turn a captured PNG sequence into things a human and a model can each read.

Produces THREE outputs, because they answer different questions:

  <name>.mp4        60fps, for a person to watch. True frame rate, small file.
  <name>.gif        50fps, for pasting anywhere that will not play video. 50 is
                    the practical ceiling: GIF stores delay in centiseconds, so
                    60fps is not representable and most viewers clamp anything
                    under 2cs to a crawl.
  <name>-strip.png  a labelled grid of consecutive frames.

The strip is the important one for review by a model: an animated image only
ever presents its first frame to something that reads stills, so motion has to
be laid out in space to be seen at all. Every Nth frame, numbered, so a pop, a
missing squash or a camera jerk is visible as a discontinuity across the grid.

  python3 tools/assemble_capture.py <framedir> <outbase> [--stride N] [--cols N]
"""
import subprocess, sys, glob, os
from PIL import Image, ImageDraw

def main():
    if len(sys.argv) < 3:
        print(__doc__); return 1
    frames_dir, out = sys.argv[1], sys.argv[2]
    stride = int(sys.argv[sys.argv.index("--stride") + 1]) if "--stride" in sys.argv else 4
    cols   = int(sys.argv[sys.argv.index("--cols") + 1]) if "--cols" in sys.argv else 6

    files = sorted(glob.glob(os.path.join(frames_dir, "f*.png")))
    if not files:
        print("no frames in", frames_dir); return 1

    # --- video: true 60fps -------------------------------------------------
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60",
                    "-i", os.path.join(frames_dir, "f%04d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
                    out + ".mp4"], check=True)

    # --- gif: 50fps, the highest GIF actually honours -----------------------
    imgs = [Image.open(f).convert("RGB") for f in files]
    imgs[0].save(out + ".gif", save_all=True, append_images=imgs[1:],
                 duration=20, loop=0, optimize=True)

    # --- strip: what a still-image reader can actually inspect --------------
    picks = list(range(0, len(files), stride))
    rows = (len(picks) + cols - 1) // cols
    fw, fh = imgs[0].size
    pad, label = 4, 14
    strip = Image.new("RGB", (cols * (fw + pad) + pad,
                              rows * (fh + pad + label) + pad), (26, 28, 34))
    d = ImageDraw.Draw(strip)
    for i, idx in enumerate(picks):
        x = pad + (i % cols) * (fw + pad)
        y = pad + (i // cols) * (fh + pad + label)
        strip.paste(imgs[idx], (x, y + label))
        d.text((x + 2, y + 1), "f%d" % idx, fill=(210, 214, 224))
    strip.save(out + "-strip.png")

    print("%s.mp4  %s.gif  %s-strip.png  (%d frames, strip every %d)"
          % (out, out, out, len(files), stride))
    return 0

if __name__ == "__main__":
    sys.exit(main())
