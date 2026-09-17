#!/usr/bin/env bash
#
# Build (and optionally test) one module. This is the command a track gate
# runs, and its output is what gets pasted at the gate.
#
#   ./scripts/build.sh TeesData            # build only
#   ./scripts/build.sh TeesData test       # build and run that module's tests
#   ./scripts/build.sh TeesForTheBoys      # the whole app
#
# Each scheme gets its own DerivedData so five concurrent tracks do not fight
# over one build directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${1:?usage: build.sh <scheme> [test]}"
ACTION="${2:-build}"
SIM="${TEES_SIM:-iPhone 17}"
DD="$ROOT/ios/.build/$SCHEME"

"$ROOT/scripts/xcgen.sh" >/dev/null

if [ "$ACTION" = "test" ]; then
  exec xcodebuild test \
    -project "$ROOT/ios/TeesForTheBoys.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIM" \
    -derivedDataPath "$DD" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO
else
  exec xcodebuild build \
    -project "$ROOT/ios/TeesForTheBoys.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIM" \
    -derivedDataPath "$DD" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO
fi
