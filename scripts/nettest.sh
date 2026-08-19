#!/bin/bash
#
# Two-client multiplayer test against a real Nakama server.
#
# Everything in scripts/check.sh runs a single process with no server, so the
# online path is invisible to it. This launches two headless clients that host
# and join the same room code and verify they can actually see each other.
#
# Requires:  docker compose up -d
# Usage:     scripts/nettest.sh

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="$(command -v godot)" || { echo "Godot not found"; exit 2; }

if ! curl -s -o /dev/null http://127.0.0.1:7350/; then
	echo "ERROR: no Nakama on 127.0.0.1:7350. Run: docker compose up -d" >&2
	exit 2
fi

OUT="${TMPDIR:-/tmp}/ptg-net"
mkdir -p "$OUT"

# A fresh code each run, so a room left over from a previous run cannot be
# joined by accident.
CODE="T$(printf '%03d' $((RANDOM % 1000)))"
echo "Room code: $CODE"

"$GODOT" --headless --path . tests/net_multiplayer.tscn -- host "$CODE" >"$OUT/host.log" 2>&1 &
HOST_PID=$!
"$GODOT" --headless --path . tests/net_multiplayer.tscn -- join "$CODE" >"$OUT/join.log" 2>&1 &
JOIN_PID=$!

wait $HOST_PID; HOST_RC=$?
wait $JOIN_PID; JOIN_RC=$?

for role in host join; do
	echo "------------------------------------------------------------"
	echo "$role:"
	sed 's/\x1b\[[0-9;]*m//g' "$OUT/$role.log" | grep -aE '\[net-|SCRIPT ERROR|Nonexistent|Invalid ' | sed 's/^/  /'
done

echo "------------------------------------------------------------"
if [ "$HOST_RC" -eq 0 ] && [ "$JOIN_RC" -eq 0 ]; then
	echo "RESULT: multiplayer OK (host rc=$HOST_RC join rc=$JOIN_RC)"
	exit 0
fi
echo "RESULT: FAILED (host rc=$HOST_RC join rc=$JOIN_RC). Logs in $OUT"
exit 1
