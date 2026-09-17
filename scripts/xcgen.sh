#!/usr/bin/env bash
#
# Regenerate ios/TeesForTheBoys.xcodeproj from ios/project.yml.
#
# Always use this instead of calling xcodegen directly. Stage 1 runs a dozen or
# more agents at once in this working tree; two generating the project
# simultaneously corrupt it. The mkdir lock is atomic on every filesystem we
# care about, which a lock file created with `>` is not.
#
# Generation takes well under a second, so a lock older than a few seconds is
# a dead holder, not a slow one — an agent killed mid-generation would
# otherwise wedge every track at once, and the house rules forbid a worker from
# reaching outside its files to clear it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/ios/.xcgen.lock"
STALE_AFTER=30
TRIES=60

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not installed — brew install xcodegen" >&2
  exit 1
fi

lock_age() {
  local mtime
  mtime="$(stat -f %m "$LOCK" 2>/dev/null || echo 0)"
  [ "$mtime" = 0 ] && { echo 0; return; }
  echo $(( $(date +%s) - mtime ))
}

holder_alive() {
  local pid
  pid="$(cat "$LOCK/pid" 2>/dev/null || echo)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

for i in $(seq 1 $TRIES); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT
    cd "$ROOT/ios"
    xcodegen generate --quiet --spec project.yml
    echo "generated ios/TeesForTheBoys.xcodeproj"
    exit 0
  fi

  if ! holder_alive && [ "$(lock_age)" -gt "$STALE_AFTER" ]; then
    echo "breaking a stale lock (holder gone, ${STALE_AFTER}s+ old)" >&2
    rm -rf "$LOCK"
    continue
  fi

  [ "$i" = 1 ] && echo "waiting for another agent to finish generating the project..."
  sleep 1
done

echo "could not take $LOCK after ${TRIES}s and its holder is still alive" >&2
exit 1
