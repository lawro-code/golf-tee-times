# Tees for the Boys — iOS build plan

A native SwiftUI app on top of the tee-time scraper already in this repo.
Readable version of this plan, with tables: https://claude.ai/artifact/KPFSWAJ5o95yowNn9EJ7wB

**Status:** Stages 0–3 landed. Stage 3's red team confirmed 43 findings
(critical 4, high 20, medium 16, low 3) and all 43 are fixed — full run:
0 agent errors. Its own completeness check then found one more real bug not
in that 43 — sign-out never told `PushRegistrar` to give back the device's
token, so a second golfer sharing a phone kept getting the first golfer's
alerts — fixed the same way, with a regression test
(`AppSessionPushRetireOnSignOutTests`). One of the two gaps the red team
flagged as unverified live has since been checked and fixed: running the app
in the simulator at the largest accessibility text size found
`TeesEmptyState`'s headline and message truncating and overlapping — missing
the same `.fixedSize` every sibling state view already had. Fixed 22
September 2026, with regression tests (`TeesEmptyStateTests`). The other gap
still stands: `alert-dispatch` has never been invoked against anything real
(only mocks and sequential SQL), so "no duplicate push in a replay" is proven
on paper, not live. Migrations are live on `ipzhqvsyxyjndpbmpibw`; the app
and website both connect to it for real and correctly show empty results,
because the scraper has never written to it — that needs
`SUPABASE_SERVICE_ROLE_KEY` from the project dashboard, which nothing here has
access to.

**Found 22 September 2026, not yet fixed:** the `TeesForTheBoys` scheme's
generated test action only ever runs `TeesForTheBoysAppTests` (17 tests).
`project.yml`'s top-level `schemes.TeesForTheBoys.test.targets` lists all six
test targets, but the `TeesForTheBoys` target's own `scheme.testTargets`
block wins when XcodeGen regenerates the project — both declare a scheme
named `TeesForTheBoys`, and the target-level one is what actually gets
written. `TeesContractTests`, `TeesDesignTests`, `TeesDataTests`,
`TeesViewsTests` and `TeesPushTests` have never run via
`./scripts/build.sh TeesForTheBoys test` or the go-prompt's `xcodebuild test`
gate — only via each module's own scheme (`./scripts/build.sh TeesViews
test`, etc.). This is how a pre-existing failure sat uncaught in
`TeesDesignTests`
(`TeesPriceTierBadgeTests.testTheContractDecoderReallyCanHandTheBadgeAnInfinitePrice`)
through every prior stage's "full suite green" report. Every historical gate
report in this file that cited `xcodebuild test` verified only
`TeesForTheBoysAppTests`, not the full suite the go-prompt asked for.

Read `CONTRACT.md` before anything else — it is what Stage 0 froze and what the
five tracks build on.

---

## What exists today

- `scraper/scrape.py` — `requests` + BeautifulSoup against MiClub public timesheets.
  **Do not replace this with Playwright or a headless browser.** MiClub serves plain
  server-rendered HTML at a fixed URL; there is no JavaScript to execute and nothing
  blocking us. A headless browser would be slower, more fragile, and far more likely to
  actually get us rate-limited.
- `scraper/discover.py` — finds a club's `feeGroupId`.
- `courses.json` — **15 courses, frozen.** Do not add, remove or reorder. A researched
  backlog of ~14 more exists and is deliberately out of scope for this build.
- `.github/workflows/scrape.yml` — twice-daily cron, commits `docs/data/teetimes.json`.
- `docs/` — the existing website. It stays working, and it is the design source of truth.

MiClub timesheet URL shape:

```
https://{host}/guests/bookings/ViewPublicTimesheet.msp
  ?bookingResourceId=3000000&feeGroupId={id}&selectedDate={YYYY-MM-DD}
```

## Target architecture

```
GitHub Actions ──> scrape.py ──> Supabase ──┬──> iOS app
 (20 min, near days)                        ├──> existing website
                                            └──> alert matcher ──> Apple Push
```

Supabase project: **`ipzhqvsyxyjndpbmpibw`** ("Tees for the boys", ap-southeast-2).
It lives in a separate free org, not the Bundle org. It was empty at plan time.

The tee-time data stops being a JSON file committed to git — at a 20-minute cadence that
would bloat the repo. Supabase holds slots, watches and alert history.

---

## Version one scope

| Area | Decision |
|---|---|
| Accounts | Supabase Auth, email + password. Browsing works signed out; the wall is in front of alerts, not search. |
| Search | Airbnb-grade filters: day, time of day, players, holes, price, drive time from Bondi. **Holes defaults to 18** and remembers the last choice. |
| Slot display | Course, time, price, players, **par and holes**. Par and holes are already in `courses.json`. |
| Booking | Deep link out to MiClub. Courses needing a free public-member registration first are marked. |
| Alerts | **One button, never a wizard.** The active filters already describe a watch completely. Present on every search; becomes the primary call to action when results are empty. |
| Notifications | Permission asked in context after first sign-in, with an explanation before the system prompt. Never cold. |
| Did you book? | Asked once on return from MiClub. A yes cancels any alert that slot satisfied and adds it to a simple upcoming rounds list. |

### Explicitly out of scope — do not build, do not scaffold toward

Friend invites, copy-link joins, a friend graph, playing partners, saved teams, the team
shuffle. These are version two. Half-built hooks for undesigned features are worse than
nothing.

---

## Scrape cadence — settled, not negotiable

**Every 20 minutes for days 0–2 only. Days 3–5 stay on the existing twice-daily cron.**

What gets a scraper blocked is its request rate at a single host, not its total. Fifteen
clubs are fifteen separate servers.

| Cadence | Per club | Reads like |
|---|---|---|
| Today — twice daily, 5 days | 10/day | nothing |
| **Every 20 min, next 3 days** | **216/day — one every 7 min** | one keen golfer refreshing |
| Every 5 min, next 3 days | 864/day — one every 100s | a bot |

New timesheet releases happen on a fixed per-club schedule — handle those with a scheduled
burst, not by polling faster. Polling exists for cancellations, and cancellations only
matter inside 48 hours.

---

## Stages

Stages do not overlap.

| Stage | Work | Shape | Gate |
|---|---|---|---|
| ~~**0**~~ | ~~Supabase schema, the frozen data contract, a golden fixture from a live scrape, Xcode project, CI~~ | **DONE** | all green — see below |
| **1** | Five parallel tracks — see `.workflows/stage1.js` | 5 leads, ~15 workers | each track builds and tests green |
| **2** | Integration — live Supabase, point the website at it | 1 agent, solo | app launches in sim with live data; website still renders |
| ~~**3**~~ | ~~Red team — see `.workflows/stage3.js`~~ | **DONE, with 2 known gaps** | 43/43 confirmed findings fixed; "no duplicate push in a replay" and all a11y fixes are unverified against anything live — see Status above |
| **4** | **COST GATE.** Demo in the simulator with screenshots *before* any Apple purchase. | Stops for Will | Will decides, then TestFlight |

Stage 0 is deliberately solo: everything that fans out afterwards depends on the contract
it freezes. Get that wrong and fifteen agents build on sand.

### What Stage 0 actually settled

Gate output, 18 September 2026:

```
./scripts/db_test.sh            46 assertions, migrations apply twice clean   SCHEMA OK
contract/validate.py golden     15 courses, 1755 slots                        CONTRACT OK
contract/validate.py --live     all 15 courses reached live                   CONTRACT OK
./scripts/build.sh <6 schemes>  exit 0, no warnings
xcodebuild test                 20 contract tests + 4 module bundles          TEST SUCCEEDED
```

Five things the live data and a red-team pass changed before the freeze. All
five are written up properly in `CONTRACT.md`; the short version:

1. **Two-tee starts are real.** Warringah runs a 1st Tee and a 10th Tee group
   at the same minute. Keying a slot on time alone lost 141 of its 289 tee
   times, so the tee is part of the slot id.
2. **A course's hole count is not the booking's.** Three 18-hole courses also
   sell 9-hole tee times — 125 slots — and holes defaults to 18 in the filters.
3. **One slot in six has no published price.** Not an error; a price filter
   must not silently drop 17% of the inventory.
4. **A cancelled tee time is a new listing and alerts again.** The obvious
   ledger — one push per (watch, slot) forever — swallows every cancellation
   after the first, which is the thing this app exists for.
5. **Concurrent agents corrupted each other's builds.** Measured: three
   concurrent builds, three failures. `scripts/build.sh` now gives each
   invocation its own build directory. Set `TEES_WORKER` to your ticket id.

### Next up after Stage 3

- **UI sweep.** Requested by Will, 20 September 2026. A separate visual/UX
  pass over the built screens, after Stage 3's bug-hardening lands green and
  before Stage 4's cost gate. Not part of Stage 3's fix scope.
  **Goal, confirmed by Will: fidelity to the existing website, not new taste.**
  Compare every app screen against `docs/style.css` and the live site —
  colour, type, spacing, component shapes — and flag drift from that, not
  from a generic design opinion.

### Decisions still open

- **Supabase.** Branching needs a paid plan and the org is free, so there is no
  branch database. Everything through Stage 1 is checked against a throwaway
  local Postgres (`scripts/db_test.sh`) and never touches a hosted project.
  Stage 2 cannot happen without one. The plan is to treat `ipzhqvsyxyjndpbmpibw`
  — empty, separate free org, no users — as the dev database. **Will has to say
  yes before anything is written to it.**
- **Secrets.** The scraper will need `SUPABASE_URL` and
  `SUPABASE_SERVICE_ROLE_KEY` as GitHub Actions secrets before Stage 2.
- **CI has never run.** `.github/workflows/ci.yml` was written in Stage 0 and
  nothing has pushed since. Assume nothing about it until it goes green once.

### Stage 1 tracks

- **A — scraper**: harden, write to Supabase, split cadence, per-course failure isolation,
  fix the AEST/AEDT drift, `--validate`.
- **B — data layer**: Supabase Auth, keychain session, fetch/decode/cache/offline.
- **C — UI**: the search experience, sign-in, onboarding, alert-from-search, did-you-book,
  upcoming rounds.
- **D — design system**: port `docs/style.css` to SwiftUI tokens and components.
- **E — alerts**: watch matcher, exactly-once push, rate limiting, APNs sender.

---

## House rules

These are what make a parallel agent build work rather than produce a pile of conflicting
edits.

1. **File ownership is exclusive.** Before any fan-out, publish the file list each agent
   owns. No two concurrent agents write the same file. An agent needing a file it does not
   own asks its track lead instead of editing it.
2. **Gates are machine-checked, never agent opinion.** `xcodebuild` exits 0 with zero
   warnings, tests exit 0, the schema validator exits 0, and a simulator screenshot shows a
   populated list. Paste the command output; do not summarise it.
3. **Nothing merges without a review and a failing test first.** The tester writes a test
   that fails against the old code and passes against the new. A test that passes either
   way is testing nothing.
4. **Questions batch to the stage gate.** Do not interrupt mid-stage; do not guess on
   anything that would waste a stage if wrong.
5. **Never write to Supabase production.** Local or branch databases only.

---

## Cost

| | |
|---|---|
| GitHub Actions | Free — public repo |
| Supabase | Free tier, separate org |
| Apple Developer Program | ~$149 AUD/year — **only at Stage 4, after Will has seen it running** |

---

## The go prompt

Stage 0 is done. To pick up from Stage 1:

```
ultracode — continue building Tees for the Boys.

Read BUILD-PLAN.md and then CONTRACT.md. Stage 0 is done and green; do not
redo it. Supabase project ref: ipzhqvsyxyjndpbmpibw

Run stages 1 through 3, stopping at the cost gate before anything is paid to
Apple. Use .workflows/stage1.js and .workflows/stage3.js for the fan-out
stages. Report at each stage gate with the command output, not a summary.

Do not write to any hosted Supabase project without asking me first.
```

The original prompt, for the record:

```
ultracode — build Tees for the Boys.

Read BUILD-PLAN.md first. Supabase project ref: ipzhqvsyxyjndpbmpibw

Run stages 0 through 3. Stop at the cost gate before anything is paid to
Apple. Use .workflows/stage1.js and .workflows/stage3.js for the fan-out
stages. Report at each stage gate with the command output, not a summary.
```
