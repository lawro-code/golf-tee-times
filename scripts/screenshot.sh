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
APP="$ROOT/ios/.build/TeesForTheBoys/Build/Products/Debug-iphonesimulator/TeesForTheBoys.app"

[ -d "$APP" ] || { echo "build it first: ./scripts/build.sh TeesForTheBoys" >&2; exit 1; }

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
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# Give SwiftUI a moment to decode the fixture and lay out the list.
for _ in $(seq 1 20); do
  xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1 && break
  sleep 0.5
done
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null
echo "$OUT"
