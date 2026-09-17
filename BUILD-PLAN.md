# Tees for the Boys — iOS build plan

A native SwiftUI app on top of the tee-time scraper already in this repo.
Readable version of this plan, with tables: https://claude.ai/artifact/KPFSWAJ5o95yowNn9EJ7wB

**Status:** planned and armed. Nothing built yet.

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
| **0** | Supabase schema, the frozen data contract, a golden fixture from a live scrape, Xcode project, CI | 1 agent, solo | `xcodebuild build` → 0; migration applies clean; fixture matches live scrape |
| **1** | Five parallel tracks — see `.workflows/stage1.js` | 5 leads, ~15 workers | each track builds and tests green |
| **2** | Integration — live Supabase, point the website at it | 1 agent, solo | app launches in sim with live data; website still renders |
| **3** | Red team — see `.workflows/stage3.js` | ~12 testers | full suite green; no duplicate push in a replay |
| **4** | **COST GATE.** Demo in the simulator with screenshots *before* any Apple purchase. | Stops for Will | Will decides, then TestFlight |

Stage 0 is deliberately solo: everything that fans out afterwards depends on the contract
it freezes. Get that wrong and fifteen agents build on sand.

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

```
ultracode — build Tees for the Boys.

Read BUILD-PLAN.md first. Supabase project ref: ipzhqvsyxyjndpbmpibw

Run stages 0 through 3. Stop at the cost gate before anything is paid to
Apple. Use .workflows/stage1.js and .workflows/stage3.js for the fan-out
stages. Report at each stage gate with the command output, not a summary.
```
