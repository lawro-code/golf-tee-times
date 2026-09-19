#!/usr/bin/env bash
#
# Boot a simulator, install the app, launch it and grab a screenshot.
# The gate is "a populated list on a real screen", not "it compiled".
#
#   ./scripts/screenshot.sh [output.png]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/screenshots/scaffold.png}"
SIM="${TEES_SIM:-iPhone 17}"
BUNDLE_ID="code.lawro.TeesForTheBoys"
# Must match build.sh's own naming: "$SCHEME-${TEES_WORKER:-$$}". A plain
# "ios/.build/TeesForTheBoys" here never matched anything build.sh actually
# produces, so this always installed whatever bundle happened to be sitting
# at that literal path — stale by definition, and silently so, since a stale
# .app still boots and screenshots fine. Same worker default as build.sh:
# set TEES_WORKER to whatever you built with, or take a cold PID-named one.
APP="$ROOT/ios/.build/TeesForTheBoys-${TEES_WORKER:-$$}/Build/Products/Debug-iphonesimulator/TeesForTheBoys.app"

[ -d "$APP" ] || { echo "build it first: TEES_WORKER=${TEES_WORKER:-$$} ./scripts/build.sh TeesForTheBoys" >&2; exit 1; }

UDID="$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
for runtime, devices in d.items():
    for dev in devices:
        if dev['name'] == '$SIM':
            print(dev['udid']); raise SystemExit
raise SystemExit('simulator \"$SIM\" not found')
")"

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# ios/project.yml's scheme `run.environmentVariables` ONLY apply when Xcode
# itself launches the app (`xcodebuild test`, or Xcode's own Run) — a bare
# `simctl launch` starts the process with none of that. simctl's own
# mechanism is the SIMCTL_CHILD_ prefix: it strips the prefix and forwards
# whatever is left to the child. Same two names SupabaseConfiguration checks,
# so exporting these before calling this script is what makes a screenshot
# built against live Supabase instead of the bundled fixture.
SIMCTL_CHILD_TEES_SUPABASE_URL="${TEES_SUPABASE_URL:-}" \
SIMCTL_CHILD_TEES_SUPABASE_ANON_KEY="${TEES_SUPABASE_ANON_KEY:-}" \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# Give SwiftUI a moment to decode the fixture and lay out the list.
for _ in $(seq 1 20); do
  xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1 && break
  sleep 0.5
done
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null
echo "$OUT"
