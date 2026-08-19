#!/bin/bash
#
# Regression harness for Push The Game.
#
# This project was ported from Godot 3 to Godot 4 and the dominant bug class is
# calls into APIs that no longer exist. Those parse fine and only blow up on the
# frame they run, so this script exercises the game and greps the engine output
# for runtime errors.
#
# Usage:
#   scripts/check.sh              run all gates
#   scripts/check.sh parse        parse gate only
#   scripts/check.sh boot         boot gate only
#   scripts/check.sh play         local-play gate only
#   scripts/check.sh units        unit-style test scenes only
#
# Exit code 0 = no errors found. Non-zero = errors (printed to stdout).

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
if [ ! -x "$GODOT" ]; then
	if command -v godot >/dev/null 2>&1; then
		GODOT="$(command -v godot)"
	else
		echo "ERROR: Godot not found. Set GODOT=/path/to/godot" >&2
		exit 2
	fi
fi

OUT_DIR="${TMPDIR:-/tmp}/ptg-check"
mkdir -p "$OUT_DIR"

# Patterns that indicate a real GDScript/engine failure. Kept deliberately tight
# so that ordinary engine chatter does not produce false positives.
#
# NOTE the leading '[tag] FAIL' alternative matches ANY test suite's tag. It
# used to list only [smoke] and [state], so every suite added later -- zone,
# char, cfg, weapon, player, match, lan, steam -- could fail while the gate
# still reported "all gates clean". Keep this generic.
ERROR_PATTERN='\[[a-z-]+\] FAIL|SCRIPT ERROR|Nonexistent function|Invalid call|Invalid access|Invalid get index|Invalid set index|Attempt to call|Parse Error|Compile Error|Cannot call method|Trying to assign|out of bounds|Condition "[^"]*" is true|USER ERROR|ERROR: '

# Engine noise that matches the patterns above but is not a defect in our code.
# Add narrowly and with a comment.
#
# "Couldn't create an ENet host" is pushed by the engine whenever
# create_server()/create_client() refuses, and tests/lan_test.gd deliberately
# provokes exactly that twice: it squats on a port and asserts hosting fails
# cleanly rather than half-working, then asserts a join to an empty address is
# refused. The engine error IS the behaviour under test, so a healthy LAN suite
# always emitted two of these and the whole run reported failure. The real guard
# on those paths is the assertions around them ("hosting on a busy port fails
# instead of half-working"), which still fail loudly if the behaviour regresses.
#
# "Resources still in use at exit" / "ObjectDB instances leaked at exit" are
# emitted when the engine shuts down with objects still alive. Every scene in
# tests/ ends by calling get_tree().quit() the moment its assertions are done,
# which leaves that frame's deferred queue_free() calls unprocessed by
# construction -- so the diagnostic fires on test TEARDOWN TIMING, not on
# anything the game does. It was seen on two different scenes on two
# consecutive runs of an identical tree, both with every assertion passing,
# which is the tell: in this harness it carries no signal about the product.
# Making it deterministic would mean tuning awaited frame counts in a dozen
# scenes, including ones that quit from _physics_process and from timer
# callbacks -- fragile in exactly the way that makes a suite untrustworthy.
# Tests should still free what they create (see tests/effect_zone_test.gd); a
# real leak check would need to be its own test, asserting on
# Performance.get_monitor(OBJECT_COUNT) rather than grepping shutdown chatter.
IGNORE_PATTERN='ERROR: Cannot open file .*\.import|texture_create|No loader found|vulkan|Vulkan|OpenGL|GLES|audio driver|Dummy|CPU pipeline|Couldn'"'"'t create an ENet host|Resources still in use at exit|ObjectDB instances leaked at exit'

FAILED=0

hr() { printf '%s\n' "------------------------------------------------------------"; }

# Filter engine output down to just the lines that look like real errors.
filter_errors() {
	grep -aE "$ERROR_PATTERN" | grep -avE "$IGNORE_PATTERN" || true
}

# Populate .godot/ (imported textures, audio, and the class_name registry).
#
# Two Godot 4.2 quirks make this fiddly:
#   - There is no --import flag. Passing one is silently ignored and the engine
#     just runs the game forever.
#   - `--headless --editor` does import correctly, but never exits on its own
#     (--quit / --quit-after do not terminate the editor's import pass).
# So: run the editor, watch .godot/imported until the file count stops growing,
# then stop it.
# A new `class_name` is not usable until Godot regenerates
# .godot/global_script_class_cache.cfg. Assets alone being imported is not
# enough -- scripts referencing the new type fail with "Could not find type X"
# until the editor runs again. So check the cache actually knows about every
# class_name declared in the project.
class_cache_is_current() {
	local cache="$PROJECT_DIR/.godot/global_script_class_cache.cfg"
	[ -f "$cache" ] || return 1

	while IFS= read -r declared; do
		grep -q "\"class\": &\"$declared\"" "$cache" 2>/dev/null || return 1
	done < <(grep -rhoE '^class_name[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
		--include='*.gd' "$PROJECT_DIR" \
		--exclude-dir=addons --exclude-dir=.godot 2>/dev/null \
		| awk '{print $2}' | sort -u)

	return 0
}

ensure_imported() {
	if [ -d "$PROJECT_DIR/.godot/imported" ] \
		&& [ "$(ls "$PROJECT_DIR/.godot/imported" | wc -l)" -gt 0 ] \
		&& class_cache_is_current; then
		return
	fi

	echo "Importing project assets (first run only, ~1 min)..."
	"$GODOT" --headless --editor --path . >"$OUT_DIR/import.log" 2>&1 &
	local pid=$!
	local prev=-1 stable=0 waited=0
	while [ "$waited" -lt 300 ]; do
		sleep 3; waited=$((waited + 3))
		local cur
		cur="$(ls "$PROJECT_DIR/.godot/imported" 2>/dev/null | wc -l | tr -d ' ')"
		if [ "$cur" = "$prev" ]; then stable=$((stable + 3)); else stable=0; fi
		prev="$cur"
		[ "$stable" -ge 15 ] && [ "$cur" -gt 0 ] && break
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	echo "Imported $prev resources."
}

# ---------------------------------------------------------------------------
# Gate 1: parse every non-addon script.
# ---------------------------------------------------------------------------
gate_parse() {
	hr; echo "GATE 1/4: parse"; hr
	local log="$OUT_DIR/parse.log"
	: >"$log"
	local count=0

	while IFS= read -r script; do
		count=$((count + 1))
		local rel="${script#./}"
		"$GODOT" --headless --path . --check-only --script "res://$rel" >>"$log" 2>&1
	done < <(find . -name '*.gd' -not -path './addons/*' -not -path './.godot/*' | sort)

	echo "Parsed $count scripts."

	# --check-only parses each script in isolation, with no autoloads
	# registered, so every reference to GameState/Online/OnlineMatch/Util
	# reports "Identifier not found" and cascades into "Compilation failed".
	# Those are artifacts of the gate, not defects. Syntax errors still show up
	# distinctly as "Parse Error", which is what this gate is actually for.
	local errors
	errors="$(filter_errors <"$log" \
		| grep -avE 'Compile Error|Compilation failed|Identifier not found')"
	if [ -n "$errors" ]; then
		echo "PARSE ERRORS:"
		echo "$errors"
		FAILED=$((FAILED + 1))
	else
		echo "OK - no parse errors."
	fi
}

# ---------------------------------------------------------------------------
# Gate 2: boot the real main scene and sit on the title screen.
# ---------------------------------------------------------------------------
gate_boot() {
	hr; echo "GATE 2/4: boot Main.tscn"; hr
	local log="$OUT_DIR/boot.log"
	"$GODOT" --headless --path . --quit-after 300 Main.tscn >"$log" 2>&1

	local errors
	errors="$(filter_errors <"$log")"
	if [ -n "$errors" ]; then
		echo "BOOT ERRORS:"
		echo "$errors" | sort | uniq -c | sort -rn
		FAILED=$((FAILED + 1))
	else
		echo "OK - booted clean."
	fi
}

# ---------------------------------------------------------------------------
# Gate 3: drive local 2-player mode for ~10 seconds of game time.
# ---------------------------------------------------------------------------
gate_play() {
	hr; echo "GATE 3/4: local play"; hr
	local log="$OUT_DIR/play.log"

	# The smoke test counts *physics* frames and quits itself. --quit-after
	# counts render frames, which in headless run far faster than the 60Hz
	# physics tick, so it is only a safety net here -- the watchdog below is
	# what actually bounds the run.
	"$GODOT" --headless --path . tests/SmokeTest.tscn >"$log" 2>&1 &
	local pid=$!
	local waited=0
	while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 90 ]; do
		sleep 2; waited=$((waited + 2))
	done
	if kill -0 "$pid" 2>/dev/null; then
		echo "WARNING: smoke test hung; killed after ${waited}s."
		kill -9 "$pid" 2>/dev/null
		FAILED=$((FAILED + 1))
	fi
	wait "$pid" 2>/dev/null

	if ! grep -aq '\[smoke\] completed' "$log"; then
		echo "WARNING: smoke test did not reach completion (crashed or hung early)."
		FAILED=$((FAILED + 1))
	fi

	local errors
	errors="$(filter_errors <"$log")"
	if [ -n "$errors" ]; then
		echo "PLAY ERRORS:"
		echo "$errors" | sort | uniq -c | sort -rn
		FAILED=$((FAILED + 1))
	else
		echo "OK - local play ran clean."
	fi
}

# ---------------------------------------------------------------------------
# Gate 4: unit-style scenes under tests/ (no server required).
#
# Each tests/*Test.tscn boots, prints "[<tag>] OK:" / "[<tag>] FAIL:" lines and
# a final "N assertion(s) failed", then quits. Drop in a new one and it is
# picked up automatically.
# ---------------------------------------------------------------------------
gate_units() {
	hr; echo "GATE 4/4: unit scenes"; hr
	local any=0

	for scene in tests/*Test.tscn; do
		[ -e "$scene" ] || continue
		any=1
		local name log
		name="$(basename "$scene" .tscn)"
		log="$OUT_DIR/unit-$name.log"

		# Watchdog: a scene whose script fails to load never reaches its own
		# get_tree().quit(), so it would hang here forever.
		"$GODOT" --headless --path . "$scene" >"$log" 2>&1 &
		local pid=$!
		local waited=0
		while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 90 ]; do
			sleep 2; waited=$((waited + 2))
		done
		if kill -0 "$pid" 2>/dev/null; then
			echo "  WARNING: $name hung; killed after ${waited}s."
			kill -9 "$pid" 2>/dev/null
			FAILED=$((FAILED + 1))
		fi
		wait "$pid" 2>/dev/null

		echo "$name:"
		sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '\] (OK|FAIL):' | sed 's/^/  /'

		if ! grep -aq 'assertion(s) failed' "$log"; then
			echo "  WARNING: $name did not run to completion."
			FAILED=$((FAILED + 1))
			continue
		fi

		local errors
		errors="$(filter_errors <"$log")"
		if [ -n "$errors" ]; then
			echo "  ERRORS in $name:"
			echo "$errors" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
			FAILED=$((FAILED + 1))
		fi
	done

	if [ "$any" -eq 0 ]; then
		echo "No test scenes found under tests/."
	fi
}

ensure_imported

case "${1:-all}" in
	parse) gate_parse ;;
	boot)  gate_boot ;;
	play)  gate_play ;;
	units|state) gate_units ;;
	all)   gate_parse; gate_boot; gate_play; gate_units ;;
	*) echo "Unknown gate: $1 (use parse|boot|play|units|all)"; exit 2 ;;
esac

hr
if [ "$FAILED" -gt 0 ]; then
	echo "RESULT: $FAILED gate(s) reported errors. Logs in $OUT_DIR"
	exit 1
fi
echo "RESULT: all gates clean."
