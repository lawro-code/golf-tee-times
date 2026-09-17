#!/usr/bin/env bash
#
# Build (and optionally test) one module. This is the command a track gate
# runs, and its output is what gets pasted at the gate.
#
#   ./scripts/build.sh TeesData            # build only
#   ./scripts/build.sh TeesData test       # build and run that module's tests
#   ./scripts/build.sh TeesForTheBoys      # the whole app
#
# Concurrency, which is the whole reason this script exists:
#
#   Two xcodebuild processes sharing one DerivedData corrupt each other. Not
#   theoretically — measured: three concurrent builds into one cold directory
#   failed 3 of 3 with "Could not resolve package dependencies", "database is
#   locked" and "the Xcode build system has crashed". Stage 1 fans out BELOW
#   the track — each track's 2-4 tickets each have a worker and a tester, all
#   running the same scheme — so the unit of concurrency is the agent, not the
#   track.
#
#   So DerivedData is per-invocation. Set TEES_WORKER to a stable id (a ticket
#   id, say) to keep a warm directory between runs; otherwise it falls back to
#   this shell's PID, which is safe but cold every time.
#
#   The cost is disk: a populated DerivedData is 175-450MB. Run
#   ./scripts/build.sh --gc to delete every worker directory not touched in the
#   last day.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = "--gc" ]; then
  find "$ROOT/ios/.build" -mindepth 1 -maxdepth 1 -type d -mtime +0 -print -exec rm -rf {} + 2>/dev/null || true
  echo "reclaimed: $(du -sh "$ROOT/ios/.build" 2>/dev/null | cut -f1) still in ios/.build"
  exit 0
fi

SCHEME="${1:?usage: build.sh <scheme> [test] | build.sh --gc}"
ACTION="${2:-build}"
SIM="${TEES_SIM:-iPhone 17}"
DD="$ROOT/ios/.build/$SCHEME-${TEES_WORKER:-$$}"

# Seed a fresh worker directory from a sibling's resolved Swift packages. This
# is the expensive, network-bound, race-prone part of a cold build; copying it
# turns a 90-second first build into a warm one and removes the SPM clone race
# entirely.
if [ ! -d "$DD/SourcePackages" ]; then
  for donor in "$ROOT/ios/.build/"*/SourcePackages; do
    [ -d "$donor" ] || continue
    mkdir -p "$DD"
    cp -Rc "$donor" "$DD/SourcePackages" 2>/dev/null || cp -R "$donor" "$DD/SourcePackages" 2>/dev/null || true
    break
  done
fi

"$ROOT/scripts/xcgen.sh" >/dev/null

xcodebuild "$ACTION" \
  -project "$ROOT/ios/TeesForTheBoys.xcodeproj" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DD" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO
