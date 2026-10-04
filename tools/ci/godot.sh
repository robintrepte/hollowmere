#!/usr/bin/env bash
# Run Godot in CI. 4.7.2 can SIGABRT (exit 134) while tearing down after a
# clean quit; treat that as success when stdout matches GODOT_OK.
set -u
if [ -z "${GODOT_OK:-}" ]; then
	echo "GODOT_OK (success regex) is required" >&2
	exit 2
fi
bin=${GODOT:-godot}
log=$(mktemp)
set +e
"$bin" "$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
set -e
if grep -Eq "$GODOT_OK" "$log"; then
	rm -f "$log"
	exit 0
fi
rm -f "$log"
exit "${code:-1}"
