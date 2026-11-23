#!/usr/bin/env bash
# Written by Claude (claude-fable-5-2), 2026-11-16: the project's test runner, checked in after the wider code audit. Before, each
# test scene was run by hand, and a scene can print "ALL PASSED" and exit 0 even though a script error skipped part of it. This
# runs the headless test scenes one at a time (never two Godots at once) and calls a suite passed only if all four hold:
#   - it exits 0 within its time limit
#   - it printed "ALL PASSED"
#   - it printed no line starting with FAIL
#   - it printed no SCRIPT ERROR (a network test also prints its other machines' script errors here)
# The runner itself exits 0 only if every suite it ran passed.
#
# Use, from Git Bash, anywhere:
#   bash tools/run_tests.sh full                 every local suite (before a commit or push)
#   bash tools/run_tests.sh full net             the same, plus the shorter network suites (net_pawn, net_streaming, net_projectile)
#   bash tools/run_tests.sh <name> [<name>...]   only suites whose file name contains one of these, e.g. replay kill_floor
#                                                (a slow suite such as net_selftest runs when it's named like this)
# Godot is looked for beside the project folder. To use another one:  GODOT="/path/to/godot" bash tools/run_tests.sh full
# Legacy tests (assets/legacy/) are never run.

cd "$(dirname "$0")/.." || exit 2
GODOT="${GODOT:-../Godot_v4.7.2-stable_win64_console.exe}"
if [ ! -x "$GODOT" ] && ! command -v "$GODOT" > /dev/null; then
  echo "Godot not found at $GODOT. Set GODOT to its path."
  exit 2
fi

# Suites "full" leaves out: slow ones (run by name, or with "net"), and scenes that are helpers or print numbers, not tests.
SLOW='net_selftest|net_streaming_selftest|net_pawn_selftest|net_projectile_selftest'
NET_SUITES="assets/scripts/pawn/tests/net_pawn_selftest.tscn assets/scripts/streaming/tests/net_streaming_selftest.tscn assets/scripts/abilities/tests/net_projectile_selftest.tscn"

failed_suites=()
ran=0

# Runs one suite and prints one line for it, then up to five of its failure lines. $1: what to show, $2: seconds allowed, the rest:
# Godot's arguments.
run_suite() {
  local name="$1" limit="$2"
  shift 2
  local started=$(date +%s) out code
  out=$(timeout "$limit" "$GODOT" --headless --path . "$@" 2>&1)
  code=$?
  local passed=$(echo "$out" | grep -cE "^ *(ok|PASS) ")
  local failed=$(echo "$out" | grep -cE "^ *FAIL")
  local errors=$(echo "$out" | grep -c "SCRIPT ERROR")
  local all_passed=$(echo "$out" | grep -c "ALL PASSED")
  local verdict="PASSED"
  if [ "$code" -ne 0 ] || [ "$failed" -ne 0 ] || [ "$errors" -ne 0 ] || [ "$all_passed" -eq 0 ]; then
    verdict="FAILED"
    failed_suites+=("$name")
  fi
  ran=$((ran + 1))
  local why=""
  [ "$code" -eq 124 ] && why=" (ran out of time: ${limit}s)"
  [ "$all_passed" -eq 0 ] && [ "$code" -ne 124 ] && why=" (never printed ALL PASSED)"
  echo "$verdict  $name  checks=$passed fail=$failed script_errors=$errors exit=$code $(( $(date +%s) - started ))s$why"
  if [ "$verdict" = "FAILED" ]; then
    echo "$out" | grep -E "^ *FAIL|SCRIPT ERROR" | head -5
  fi
}

run_scene() {
  local limit=600
  [[ "$1" == *net_selftest* ]] && limit=900 # about 8 minutes on its own
  run_suite "$(basename "$1" .tscn)" "$limit" "res://$1"
}

mapfile -t every < <(find assets/scripts addons -name '*_selftest.tscn' -not -path 'assets/legacy/*' | sort)

if [ "$1" = "full" ]; then
  for scene in "${every[@]}"; do
    if ! echo "$scene" | grep -qE "$SLOW"; then run_scene "$scene"; fi
  done
  # The navigation test is a plain script, not a scene.
  run_suite "nav_selftest" 300 --script res://assets/scripts/navigation/tests/nav_selftest.gd
  if [ "$2" = "net" ]; then
    for scene in $NET_SUITES; do run_scene "$scene"; done
  fi
elif [ $# -gt 0 ]; then
  for scene in "${every[@]}"; do
    for wanted in "$@"; do
      if [[ "$(basename "$scene")" == *"$wanted"* ]]; then run_scene "$scene"; break; fi
    done
  done
  for wanted in "$@"; do # the navigation test is a plain script, not a scene
    if [[ "nav_selftest" == *"$wanted"* ]]; then
      run_suite "nav_selftest" 300 --script res://assets/scripts/navigation/tests/nav_selftest.gd
      break
    fi
  done
  if [ "$ran" -eq 0 ]; then
    echo "No suite matched: $*. Suites are the *_selftest scenes; stress and compare scenes are run by hand."
    exit 2
  fi
else
  sed -n '2,18p' "$0"
  exit 2
fi

echo
if [ "${#failed_suites[@]}" -eq 0 ]; then
  echo "=== all $ran suites passed ==="
  exit 0
fi
echo "=== ${#failed_suites[@]} of $ran suites FAILED: ${failed_suites[*]} ==="
exit 1
