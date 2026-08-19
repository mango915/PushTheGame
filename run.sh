#!/bin/bash
#
# Launch Push The Game with the right engine.
#
# The project is on Godot 4.7 (project.godot: config/features = "4.7"). Running
# it with an older Godot fails in a way that looks like the project is broken:
# 4.2 cannot read the format-version-6 import cache 4.7 writes, so every font,
# sound and scene fails to load and the title screen never appears. On this
# machine 4.7 was installed ALONGSIDE an older /Applications/Godot.app rather
# than replacing it, so the obvious command is the wrong one.
#
# Usage:  ./run.sh            play the game
#         ./run.sh --editor   open it in the editor
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Same resolution order as scripts/check.sh.
if [ -z "${GODOT:-}" ]; then
	for candidate in \
		"/Applications/Godot 4.7.app/Contents/MacOS/Godot" \
		"/Applications/Godot.app/Contents/MacOS/Godot" \
		"$(command -v godot 2>/dev/null || true)"
	do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			GODOT="$candidate"
			break
		fi
	done
fi
if [ -z "${GODOT:-}" ] || [ ! -x "$GODOT" ]; then
	echo "ERROR: Godot not found. Install Godot 4.7 or set GODOT=/path/to/godot" >&2
	exit 2
fi

# Refuse to run on an engine older than the project, rather than emitting a
# hundred confusing resource errors.
version="$("$GODOT" --version 2>/dev/null | head -1)"
major_minor="$(printf '%s' "$version" | cut -d. -f1,2)"
case "$major_minor" in
	4.7|4.8|4.9|5.*) ;;
	*)
		echo "ERROR: this project needs Godot 4.7 or newer; found $version at:" >&2
		echo "         $GODOT" >&2
		echo "       Install 4.7 or point GODOT at it, e.g." >&2
		echo "         GODOT='/Applications/Godot 4.7.app/Contents/MacOS/Godot' ./run.sh" >&2
		exit 2
		;;
esac

echo "Push The Game  --  $version"
exec "$GODOT" --path . "$@"
