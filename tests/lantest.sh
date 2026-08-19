#!/bin/bash
#
# Two-instance LAN multiplayer test. NO server required.
#
# scripts/check.sh runs a single process, so it can only see one side of
# discovery; scripts/nettest.sh needs a Nakama server. This launches two
# headless instances on this machine: one hosts on the local network, the other
# broadcasts a discovery probe, finds it, and joins the address that came back.
# Nobody types an IP, nobody opens a port, nobody signs in.
#
# Usage:     tests/lantest.sh [port]
# Requires:  nothing but Godot.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

GODOT="${GODOT:-/Applications/Godot 4.7.app/Contents/MacOS/Godot}"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="$(command -v godot)" || { echo "Godot not found"; exit 2; }

# The discovery port is fixed (that is what makes discovery configuration-free),
# but the game port can move, so a leftover process from a previous run cannot
# be joined by accident.
PORT="${1:-$((8700 + RANDOM % 80))}"
echo "Game port: $PORT  (discovery is always UDP 8677)"

OUT="${TMPDIR:-/tmp}/ptg-lan"
mkdir -p "$OUT"

"$GODOT" --headless --path . tests/lan_multiplayer.tscn -- host "$PORT" >"$OUT/lan-host.log" 2>&1 &
HOST_PID=$!
"$GODOT" --headless --path . tests/lan_multiplayer.tscn -- join "$PORT" >"$OUT/lan-join.log" 2>&1 &
JOIN_PID=$!

wait $HOST_PID; HOST_RC=$?
wait $JOIN_PID; JOIN_RC=$?

for role in host join; do
	echo "------------------------------------------------------------"
	echo "$role:"
	sed 's/\x1b\[[0-9;]*m//g' "$OUT/lan-$role.log" \
		| grep -aE '\[lan-|SCRIPT ERROR|Nonexistent|Invalid ' | sed 's/^/  /'
done

echo "------------------------------------------------------------"

# A script that fails to COMPILE never runs its assertions, so _failures stays 0
# and the process still exits 0. Require the run to actually reach its
# assertions, and to be free of engine errors.
ERRORS=0
ASSERTIONS=0
for role in host join; do
	if grep -aqE 'SCRIPT ERROR|Parse Error|Nonexistent function|Invalid call' "$OUT/lan-$role.log"; then
		echo "$role: engine errors present"
		ERRORS=1
	fi
	n="$(grep -ac '\] OK:' "$OUT/lan-$role.log" || true)"
	ASSERTIONS=$((ASSERTIONS + n))
done

if [ "$ASSERTIONS" -lt 20 ]; then
	echo "only $ASSERTIONS assertions ran - the test did not get far enough"
	ERRORS=1
fi

if [ "$HOST_RC" -eq 0 ] && [ "$JOIN_RC" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
	echo "RESULT: LAN multiplayer OK ($ASSERTIONS assertions, host rc=$HOST_RC join rc=$JOIN_RC)"
	exit 0
fi
echo "RESULT: FAILED (host rc=$HOST_RC join rc=$JOIN_RC). Logs in $OUT"
exit 1
