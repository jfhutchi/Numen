#!/usr/bin/env bash
# The whole gate: asset licences, project import check, test suites.
# Must exit 0 on a clean clone.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# --- Resolve the Godot binary -------------------------------------------------
# On Windows use the *_console.exe variant. The plain .exe detaches from the
# console and its stdout never reaches the terminal, so test results would
# vanish silently and a red suite would look green.
if [ -z "${GODOT_BIN:-}" ] && [ -f tools/godot_bin.local ]; then
	GODOT_BIN="$(tr -d '\r\n' < tools/godot_bin.local)"
fi
if [ -z "${GODOT_BIN:-}" ]; then
	for candidate in godot godot4 Godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			GODOT_BIN="$candidate"
			break
		fi
	done
fi
if [ -z "${GODOT_BIN:-}" ]; then
	cat >&2 <<-'EOF'
	FAIL: no Godot binary found.
	  Set GODOT_BIN, or write the path into tools/godot_bin.local (gitignored).
	  On Windows point it at the *_console.exe variant.
	EOF
	exit 1
fi

echo "== NUMEN CI =="
echo "godot: $GODOT_BIN"
"$GODOT_BIN" --version
echo

# --- 1. Asset licences --------------------------------------------------------
echo "-- licences --"
bash tools/check_licenses.sh
echo

# --- 2. Import check ----------------------------------------------------------
# Must be --import, not --quit. --quit imports resources but does not register
# script class_names, so GUT aborts with "Some GUT class_names have not been
# imported". Import chatter on a cold cache is expected; the exit code is what
# matters.
echo "-- import check --"
"$GODOT_BIN" --headless --path . --import >/dev/null
echo "import: ok"
echo

# --- 3. Tests -----------------------------------------------------------------
echo "-- tests --"
test_log="$(mktemp)"
trap 'rm -f "$test_log"' EXIT

set +e
"$GODOT_BIN" --headless --path . -s addons/gut/gut_cmdln.gd \
	-gdir=res://tests -ginclude_subdirs -gexit 2>&1 | tee "$test_log"
gut_status=${PIPESTATUS[0]}
set -e

# GUT reports failures in its summary as well as via exit code; check both so a
# non-propagating exit status cannot make a red suite look green.
if [ "$gut_status" -ne 0 ]; then
	echo "FAIL: gut exited $gut_status" >&2
	exit 1
fi
if grep -qE '^[[:space:]]*(Failing tests|Tests that were pending)' "$test_log"; then
	if grep -qE '[1-9][0-9]* (failing|failures)' "$test_log"; then
		echo "FAIL: gut reported failing tests" >&2
		exit 1
	fi
fi
if ! grep -qE 'Totals|All tests passed|passing' "$test_log"; then
	echo "FAIL: gut produced no recognisable summary - treating as failure" >&2
	exit 1
fi

echo
echo "== CI OK =="
