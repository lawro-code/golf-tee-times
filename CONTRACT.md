# The frozen contract — v1.0.0

Stage 0 froze this. Five tracks build on it concurrently in Stage 1, so it does
not move while they are running. If it has to move, everything in the list
below changes in one commit or none of it does:

```
contract/VERSION
contract/payload.schema.json
contract/transform.py
ios/TeesForTheBoys/Contract/*.swift
supabase/migrations/*.sql
contract/fixtures/*.json        (regenerate, do not hand-edit)
```

---

## How to check your work

Three commands. Paste their output at a gate; do not describe it.

```bash
./scripts/db_test.sh                              # migrations + 46 schema assertions
python3 contract/validate.py contract/fixtures/golden.json
./scripts/build.sh <Scheme> [test]                # your module only
```

`scripts/build.sh` regenerates the Xcode project first, under a lock. **Never
run `xcodegen` directly** — five agents generating at once corrupts the project.

Schemes, one per track, so your gate is not hostage to another track's build:

| Track | Scheme | Source you own | Tests you own |
|---|---|---|---|
| — (Stage 0) | `TeesContract` | `ios/TeesForTheBoys/Contract/` | `ios/TeesForTheBoysTests/Contract/` |
| B data | `TeesData` | `ios/TeesForTheBoys/Data/` | `ios/TeesForTheBoysTests/Data/` |
| C screens | `TeesViews` | `ios/TeesForTheBoys/Views/` | `ios/TeesForTheBoysTests/Views/` |
| D design | `TeesDesign` | `ios/TeesForTheBoys/DesignSystem/` | `ios/TeesForTheBoysTests/DesignSystem/` |
| E push | `TeesPush` | `ios/TeesForTheBoys/Push/` | `ios/TeesForTheBoysTests/Push/` |
| A scraper | — | `scraper/`, `.github/workflows/scrape*.yml` | `scraper/tests/` |

Each track is a real framework target. Anything another track needs from you
has to be `public` — the compiler enforces the module boundary, so the seams
are visible instead of accidental. `ios/project.yml` is Stage 0's; if you need
a build setting changed, report it as a blocker.

---

## Six things the live data taught us

These are not hypotheticals. Every one came out of the 15-course scrape on
17 September 2026 that `contract/fixtures/golden.json` is a snapshot of.

### 1. Two-tee starts are real, so time alone does not identify a slot

Warringah sends a 1st Tee group and a 10th Tee group out at the same minute.
They are two separate bookings. Keying on `(course, date, time)` silently
collapsed 141 of Warringah's 289 tee times.

A slot id is therefore:

```
{course_slug}:{YYYY-MM-DD}:{HHMM}:{tee}
warringah:2026-09-18:0616:1st-tee-social
warringah:2026-09-18:0616:10th-tee-social
```

`tee` is the club's booking type, lowercased and hyphenated; an unlabelled row
becomes `default`. The database enforces the same thing:
`unique (course_slug, tee_date, tee_time, booking_type)`.

**The id is stable across scrapes, and that is load-bearing.** It is what lets
`alert_deliveries` hold `unique (watch_id, slot_id)` and turn twelve scrapes of
the same open slot into one push.

### 2. A course's hole count is not always the booking's

Bankstown, Beverley Park and Brighton Lakes are 18-hole courses that also sell
9-hole tee times — 125 slots in the golden fixture. The only place it is stated
is the booking type or the fee label (`"Social Play 9 Holes Only"`,
`"Midweek 9 Holes (Non-Refundable)"`).

`slot.holes` is derived per slot by `transform.holes_for_slot`, not copied from
the course. Holes defaults to 18 in the app's filters, so getting this wrong
shows a golfer 9 holes when they asked for 18.

### 3. One slot in six has no price at all

282 of 1755 slots publish no fee (Warringah 243, Bexley 39). `price_min` and
`price_max` are null and `price_tiers` is empty. That is ordinary data.

**Product rule:** a price filter never silently drops an unpriced slot. Show it,
label it ("price at course"), and sort it last within the filter. Hiding 17% of
the inventory is worse than showing a round whose price we do not know.

### 4. Sydney changes offset twice a year, so the server resolves the instant

`tee_at` is the absolute instant, resolved once in `contract/transform.py` using
`Australia/Sydney`. **Clients never recompute it.** `tee_date` and `tee_time`
are the wall-clock values at the course, for display and grouping.

The two awkward nights, decided rather than discovered:

- **April, clocks back** (03:00 → 02:00): 02:00–02:59 happens twice. We take the
  first occurrence, still on AEDT (`fold=0`).
- **October, clocks forward** (02:00 → 03:00): 02:00–02:59 does not exist.
  Python maps it forward an hour.

No course tees off at 2am. The rule is written down so nobody has to guess.

### 5. Failure and emptiness are different, and the data says which

`course_day_scrapes` records, per course per day, whether we actually reached
the club. Long Reef had zero free tee times and scraped perfectly; a club
returning 500 has none either. The app must not render those the same way.

`public.course_freshness` aggregates this for the stale-data banner.

### 6. A cancelled tee time is a new listing, and it alerts again

Somebody books the 8am at The Coast; two days later they cancel and the club
relists it. That cancellation is the reason this app exists, so it has to reach
the person watching for it.

The naive ledger — one push per `(watch, slot)` forever — swallows every
cancellation after the first, because the slot id is deliberately stable. So
`slots` carries `opened_at`, bumped by the `slots_lifecycle` trigger whenever a
gone slot comes back, and the ledger is keyed on
`(watch_id, slot_id, slot_opened_at)`:

| What happens | Result |
|---|---|
| One listing seen across twelve scrapes | One push — same `opened_at` |
| Booked, then cancelled, then relisted | A second push — new `opened_at` |
| Relisted slot seen across twelve more scrapes | Still just that one push |

The trigger means a writer never has to remember any of this. The scraper says
only what it saw — `status = 'open'` with the spots it found, or
`status = 'gone'` for a slot a successful scrape stopped listing — and
`opened_at`, `reopen_count` and `gone_at` look after themselves.

### 7. `length_metres` is null and stays null

MiClub does not publish course length. The column and the field exist so adding
it later is not a contract break. **Do not invent values and do not scrape club
websites for it** without a ticket that says so.

---

## The payload

One shape, whether it came from a fixture file or from Supabase. Key names and
string formats match exactly what PostgREST returns for `public.open_slots`, so
one decoder serves both.

```jsonc
{
  "contract_version": "1.0.0",
  "generated_at": "2026-09-17T18:29:07+10:00",
  "mode": "full",                  // "fast" = days 0-2, "full" = days 0-5
  "days": 5,
  "courses":     [ /* 15, frozen */ ],
  "slots":       [ /* bookable tee times */ ],
  "course_days": [ /* per course per day: did we reach it */ ]
}
```

A slot:

```jsonc
{
  "id": "warringah:2026-09-18:0616:1st-tee-social",
  "course_slug": "warringah",
  "course_name": "Warringah Golf Club",
  "region": "Northern Beaches",
  "drive_minutes_from_bondi": 32,
  "par": 70,
  "length_metres": null,
  "requires_registration": false,
  "tee_date": "2026-09-18",        // local calendar date at the course
  "tee_time": "06:16:00",          // HH:MM:SS, wall clock, seconds always 00
  "tee_at": "2026-09-18T06:16:00+10:00",
  "spots_available": 2,
  "total_spots": 4,
  "holes": 18,                     // THIS booking, not the course
  "price_min": null,               // null is ordinary
  "price_max": null,
  "price_tiers": [],
  "booking_type": "1st Tee Social",
  "booking_url": "https://warringah.miclub.com.au/guests/bookings/..."
}
```

Serialisation details that will bite if you assume otherwise:

- `tee_time` is `HH:MM:SS`, not `HH:MM` — that is how PostgREST renders a
  Postgres `time`.
- `tee_at` may come back with `+00:00` and fractional seconds from Supabase and
  with `+10:00` from a fixture. `ContractDate` parses both.
- `price_min` is a JSON number, but some Postgres clients send `numeric` as a
  string. The Swift decoder accepts both.
- `booking_url` decodes to a **String**, not a `URL`. A malformed url must not
  fail the decode; use `slot.bookingURL` (optional) to navigate.

Decoding is lenient by design: a malformed row is dropped into
`payload.issues` and the rest survives. One club changing its HTML must not
blank out the other fourteen.

## Fixtures

| File | What it is | Use it for |
|---|---|---|
| `contract/fixtures/golden.json` | A real 15-course, 5-day scrape. 1755 slots. | UI, scrolling, performance, realistic previews |
| `contract/fixtures/minimal.json` | 9 slots, fixed dates, regenerable | Unit tests. Every awkward case above has exactly one example |
| `contract/fixtures/raw_live.json` | The raw scrape golden was built from | Testing the scraper's own transform |

`minimal.json` is deterministic — regenerate with
`python3 contract/fixtures/make_minimal.py`. It deliberately contains: a
two-tee start, a 9-hole booking on an 18-hole course, an unpriced slot, a slot
with three price tiers, a club needing free registration, a club that scraped
fine with nothing free, a club that failed outright, and slots either side of
the October DST changeover.

## Database

| Table | Holds | Who writes |
|---|---|---|
| `courses` | the frozen 15 | seed migration, from `courses.json` |
| `slots` | every tee time ever seen open | scraper (service role) |
| `course_day_scrapes` | per course per day: did we reach it | scraper |
| `scrape_runs` | one row per scrape | scraper |
| `watches` | a saved search | the owning user |
| `alert_deliveries` | the exactly-once ledger | the matcher (service role) |
| `push_tokens` | APNs device tokens | the owning user |
| `bookings` | "did you book?" answered yes | the owning user |

Read through the views, not the base tables: `public.open_slots` (future,
still-listed tee times joined to their course) and `public.course_freshness`.

RLS is on everywhere. Reference and scraped data is world-readable — browsing
works signed out, the wall is in front of alerts. Everything user-owned is
visible only to its owner, enforced in the database, and `alert_deliveries` is
read-only to clients so nobody can rewrite their own alert history.

`scripts/db_test.sh` proves all of that against a throwaway local Postgres 17.
It never touches a hosted project.

## Gotchas already paid for

- **Two builds must never share a DerivedData directory.** Three concurrent
  builds into one cold directory failed 3 of 3 — "Could not resolve package
  dependencies", "database is locked", "the Xcode build system has crashed".
  `scripts/build.sh` gives every invocation its own, seeded from a sibling's
  resolved packages so it is still warm. Set `TEES_WORKER` to your ticket id to
  keep yours between runs, and `./scripts/build.sh --gc` reclaims old ones
  (they run 175-450MB each).
- An **empty directory inside the .app** makes `simctl install` fail with
  "Missing bundle ID". Do not add folder references for directories that might
  be empty.
- Framework targets need `GENERATE_INFOPLIST_FILE: YES` or the app fails to
  embed them.
- `UIRequiredDeviceCapabilities: [armv7]` makes an arm64 simulator refuse the
  install.
- Swift language mode is **5**, with minimal strict concurrency, and warnings
  are errors. A Swift 6 concurrency migration is a later version's problem; do
  not start one inside a ticket.
