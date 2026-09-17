#!/usr/bin/env bash
#
# Regenerate ios/TeesForTheBoys.xcodeproj from ios/project.yml.
#
# Always use this instead of calling xcodegen directly. Stage 1 runs five
# tracks at once in this working tree; two agents generating the project
# simultaneously corrupt it. The mkdir lock is atomic on every filesystem we
# care about, which a lock file created with `>` is not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/ios/.xcgen.lock"
TRIES=60

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not installed — brew install xcodegen" >&2
  exit 1
fi

for i in $(seq 1 $TRIES); do
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
    cd "$ROOT/ios"
    xcodegen generate --quiet --spec project.yml
    echo "generated ios/TeesForTheBoys.xcodeproj"
    exit 0
  fi
  [ "$i" = 1 ] && echo "waiting for another agent to finish generating the project..."
  sleep 1
done

echo "could not take $LOCK after ${TRIES}s — a stale lock? remove it with: rmdir $LOCK" >&2
exit 1
