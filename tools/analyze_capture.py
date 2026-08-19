#!/usr/bin/env python3
"""Scan a capture's telemetry for things that look wrong.

Feel bugs are usually a disagreement between what the game IS and what it shows:
a player in the Fall state while standing on the floor, an animation that never
matches its state, a hitbox live for one frame or forty, a body that pops
between poses instead of easing. Those are all obvious in numbers and nearly
invisible in a screenshot, which is the whole reason this exists.

  python3 tools/analyze_capture.py <capturedir>
"""
import json, sys, os
from collections import defaultdict

AIRBORNE = {"Jump", "Fall", "WallJump"}
GROUNDED = {"Idle", "Move", "Duck", "Slide"}

def load(d):
    rows = []
    with open(os.path.join(d, "telemetry.jsonl")) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows

def per_player(rows):
    out = defaultdict(list)
    for r in rows:
        for p in r["p"]:
            out[p["id"]].append((r["f"], p))
    return out

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    d = sys.argv[1]
    rows = load(d)
    findings = []

    for pid, seq in sorted(per_player(rows).items()):
        # --- state vs. ground truth ---------------------------------------
        run = None
        for f, p in seq:
            bad = (p["floor"] and p["state"] in AIRBORNE) or \
                  (not p["floor"] and p["state"] in GROUNDED)
            if bad:
                run = (f, p["state"], p["floor"]) if run is None else run
            elif run is not None:
                if f - run[0] >= 3:
                    findings.append(("state/ground mismatch", pid,
                        "frames %d-%d: state=%s floor=%s for %d frames"
                        % (run[0], f-1, run[1], run[2], f - run[0])))
                run = None

        # --- state thrashing ----------------------------------------------
        changes = [f for i, (f, p) in enumerate(seq[1:], 1) if p["state"] != seq[i-1][1]["state"]]
        for i in range(len(changes) - 2):
            if changes[i+2] - changes[i] <= 3:
                findings.append(("state thrash", pid,
                    "3 state changes within %d frames around f%d"
                    % (changes[i+2] - changes[i], changes[i])))
                break

        # --- animation never matching its state ---------------------------
        mism = sum(1 for f, p in seq if p["state"] in ("Jump", "Fall", "Duck", "Slide")
                   and p["anim"] not in (p["state"], "Glide", "Land", "SlideFinished"))
        if mism > len(seq) * 0.15:
            findings.append(("anim lags state", pid,
                "%d/%d frames the animation did not match the state" % (mism, len(seq))))

        # --- squash popping -----------------------------------------------
        for i in range(1, len(seq)):
            dy = abs(seq[i][1]["sqy"] - seq[i-1][1]["sqy"])
            # A landing is SUPPOSED to snap -- fast in, slow out is how impact
            # reads. Only flag a jump that is not explained by hitting something.
            landed = seq[i][1]["floor"] and not all(
                seq[max(0, i-3):i][k][1]["floor"] for k in range(len(seq[max(0, i-3):i])))
            hurt = seq[i][1]["state"] == "Hurt" and seq[i-1][1]["state"] != "Hurt"
            if dy > 0.30 and not (landed or hurt):
                findings.append(("squash pop", pid,
                    "f%d: vertical squash jumped %.2f in one frame (%.2f -> %.2f)"
                    % (seq[i][0], dy, seq[i-1][1]["sqy"], seq[i][1]["sqy"])))

        # --- teleports ------------------------------------------------------
        for i in range(1, len(seq)):
            dx = abs(seq[i][1]["x"] - seq[i-1][1]["x"])
            if dx > 40:
                findings.append(("position jump", pid,
                    "f%d: moved %.0f px horizontally in one frame" % (seq[i][0], dx)))

        # --- hitbox live windows --------------------------------------------
        live, start = False, None
        for f, p in seq:
            hb = p.get("hb", False)
            if hb and not live:
                live, start = True, f
            elif not hb and live:
                live = False
                n = f - start
                if n <= 1:
                    findings.append(("hitbox flicker", pid,
                        "f%d: weapon hitbox live for only %d frame(s)" % (start, n)))
                elif n > 20:
                    findings.append(("hitbox overstays", pid,
                        "f%d-%d: weapon hitbox live for %d frames" % (start, f, n)))

        # --- landings with no Land beat --------------------------------------
        for i in range(1, len(seq)):
            was_air = not seq[i-1][1]["floor"]
            now_gnd = seq[i][1]["floor"]
            fell = seq[i-1][1]["vy"] > 120
            if was_air and now_gnd and fell:
                # The real invariant is that the body REACTS, not that a
                # particular animation played: landing while holding a direction
                # goes Fall -> Move and never touches the "Land" animation, but
                # it must still land with weight.
                window = [seq[j][1]["sqy"] for j in range(i, min(i+5, len(seq)))]
                if not window or min(window) > 0.95:
                    findings.append(("landing not acknowledged", pid,
                        "f%d: hit ground at vy=%.0f but the body never squashed "
                        "(min sqy %.2f)" % (seq[i][0], seq[i-1][1]["vy"],
                                            min(window) if window else 1.0)))

        # --- silent walls ----------------------------------------------------
        wall_run = None
        for f, p in seq:
            if p["wall"] and not p["floor"]:
                wall_run = f if wall_run is None else wall_run
            elif wall_run is not None:
                if f - wall_run >= 20:
                    findings.append(("clinging to wall", pid,
                        "frames %d-%d: airborne against a wall for %d frames"
                        % (wall_run, f-1, f - wall_run)))
                wall_run = None

    if not findings:
        print("no anomalies found in %d frames" % len(rows))
        return 0

    by_kind = defaultdict(list)
    for kind, pid, msg in findings:
        by_kind[kind].append((pid, msg))
    print("%d finding(s) across %d frames\n" % (len(findings), len(rows)))
    for kind in sorted(by_kind):
        print("== %s (%d)" % (kind, len(by_kind[kind])))
        for pid, msg in by_kind[kind][:6]:
            print("   p%s  %s" % (pid, msg))
        if len(by_kind[kind]) > 6:
            print("   ... and %d more" % (len(by_kind[kind]) - 6))
        print()
    return 0

if __name__ == "__main__":
    sys.exit(main())
