#!/usr/bin/env node
// Regression test: docs/app.js `formatLastUpdated` must render the public
// site's "Refreshed" banner in Australia/Sydney, not the visitor's local
// timezone.
//
// Bug: the old implementation did `new Date(iso)` then read
// `.getDay()/.getDate()/.getMonth()/.getHours()/.getMinutes()`, all of which
// report in whatever timezone the *process* (browser/OS) is set to. Every
// other timestamp formatter in this codebase (scraper/cadence.py, the Deno
// edge function's formatSydneyDay/formatSydneyTime, iOS SlotFormatting /
// ContractDecoding) pins Australia/Sydney explicitly (CONTRACT.md §4: "the
// client never recomputes it") — this was the one exception.
//
// This test runs the ACTUAL current `docs/app.js` source (extracted the same
// way the bug report's own repro did: pull the real function out and run
// it) inside a child `node` process with TZ forced to a non-Sydney zone, so
// the result is deterministic no matter what timezone the machine running
// this test happens to be in.

import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const appJsPath = path.join(here, 'app.js');
const source = readFileSync(appJsPath, 'utf8');

function extractFunction(name) {
  const re = new RegExp(`function ${name}\\([\\s\\S]*?\\n\\}\\n`);
  const m = source.match(re);
  if (!m) {
    throw new Error(`could not find function ${name} in docs/app.js — has it moved or been renamed?`);
  }
  return m[0];
}

function extractConst(name) {
  const re = new RegExp(`const ${name} = [\\s\\S]*?;\\n`);
  const m = source.match(re);
  return m ? m[0] : '';
}

// formatLastUpdated's dependencies differ pre-fix (DAY_NAMES_SHORT,
// MONTHS_SHORT) vs post-fix (LAST_UPDATED_FORMAT). Pull all three — whichever
// don't exist in the current source just come back empty — so this harness
// runs unmodified against either version of the function.
const consts = ['LAST_UPDATED_FORMAT', 'DAY_NAMES_SHORT', 'MONTHS_SHORT']
  .map(extractConst)
  .join('\n');

const fn = extractFunction('formatLastUpdated');

const harness = `${consts}\n${fn}\nprocess.stdout.write(formatLastUpdated(process.argv[1]));`;

// 2026-09-19T20:30:00+10:00 is the bug report's own repro instant: 8:30pm on
// a Saturday in Sydney (AEST, +10:00).
const iso = '2026-09-19T20:30:00+10:00';
const expected = 'Refreshed Sat 19 Sep · 8:30 pm';

function runUnderTZ(tz) {
  return execFileSync(process.execPath, ['-e', harness, iso], {
    encoding: 'utf8',
    env: { ...process.env, TZ: tz },
  });
}

// Sanity check: when the host process happens to be in Sydney's own zone,
// the (buggy) local-time reads and the (fixed) explicit-zone reads agree —
// this instant must always render the same as the bug report's expected
// output there.
assert.equal(
  runUnderTZ('Australia/Sydney'),
  expected,
  'sanity check failed under TZ=Australia/Sydney — the expected string itself is wrong',
);

// The actual regression: a visitor whose device is NOT set to Sydney must
// still see the Sydney day/time, not their own local reading of the same
// instant (which the bug report showed as "Sat 19 Sep · 3:30 am" under
// America/Los_Angeles).
for (const tz of ['America/Los_Angeles', 'Asia/Kolkata', 'UTC']) {
  const result = runUnderTZ(tz);
  assert.equal(
    result,
    expected,
    `formatLastUpdated must render in Australia/Sydney regardless of host TZ; ` +
      `under TZ=${tz} got ${JSON.stringify(result)}, expected ${JSON.stringify(expected)}`,
  );
}

console.log('PASS: formatLastUpdated renders Australia/Sydney time regardless of host TZ');
