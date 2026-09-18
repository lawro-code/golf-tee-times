# The scraper

Fetches the public MiClub timesheets for the 15 frozen courses in
`courses.json`, turns them into the payload `CONTRACT.md` describes, and writes
it to Supabase.

MiClub serves plain server-rendered HTML at a fixed URL. `requests` +
BeautifulSoup is the right tool and it stays — **do not replace it with
Playwright or any headless browser.** There is no JavaScript to execute, and a
headless browser would be slower, more fragile and far more likely to get us
rate-limited.

---

## Read this first if you are picking up Stage 2

**`docs/data/teetimes.json` is no longer produced or committed.** The old
workflow ran the scraper and pushed that file back into git on every run; at a
20-minute cadence that would add thousands of commits and tens of megabytes a
month, so slots now go to Supabase instead and both workflows are read-only.

The consequence is immediate and visible: **the public site under `docs/` is
frozen at its last committed scrape** and will quietly go staler every day
until Stage 2 repoints it at Supabase. The site still renders — it is just
showing tee times from the day the split landed. Nothing warns a visitor about
that yet. Repointing `docs/` is Stage 2's job, not the scraper's.

If you need a JSON file for anything in the meantime, `--out PATH` still writes
one. Nothing commits it for you, and nothing should.

---

## The two workflows

| | `.github/workflows/scrape.yml` | `.github/workflows/scrape-fast.yml` |
|---|---|---|
| Called | full | fast |
| Window | days 0–4 (5 days) | days 0–2 (3 days) |
| Cron | `0 9,10,21,22 * * *` UTC | `*/20 * * * *` |
| Actually runs | twice a day, 08:00 and 20:00 **Sydney** | every 20 minutes |
| DST gate | yes — `scraper/cadence.py` | no, and it must not grow one |
| Concurrency group | `scrape` | `scrape-fast` |
| Permissions | `contents: read` | `contents: read` |

Separate groups on purpose, both with `cancel-in-progress: false`: the two
cadences must not queue behind each other, and a run part way through writing
slots has to be allowed to finish.

### Why the full run needs a gate

GitHub Actions cron is UTC only. Sydney is UTC+10 in AEST and UTC+11 in AEDT,
so no single cron line can mean "08:00 and 20:00 Sydney" all year. The old
schedule, `0 22,10 * * *`, was right in AEST and an hour late for the roughly
five months of AEDT — its own comment admitted it.

So `scrape.yml` fires at **every UTC hour that could be a slot** — 10 and 22 in
AEST, 09 and 21 in AEDT — and its first step asks `scraper/cadence.py` which
this one is. Half of every day's four fires are meant to do nothing, and the
gate step records that as a skip rather than a failure: a red tick on a
deliberate no-op teaches everyone to ignore red ticks.

```bash
python3 scraper/cadence.py --gate full     # exit 0 = run, exit 1 = skip
python3 scraper/cadence.py --gate full --at 2026-12-01T09:00:00Z   # test any instant
```

Stdlib only, because the gate runs before `pip install`.

The exit code is the whole interface, and **only 1 means skip**. Anything else —
a syntax error in `cadence.py`, a bad argument (exit 2) — fails the job on
purpose. Read as a skip it would quietly turn every scheduled full run into a
no-op with nothing ever going red to say so.

Two things to know before you touch either file:

- The gate is **hour-wide**, not minute-exact. GitHub's scheduler runs late,
  routinely by minutes and occasionally by more, and a slot that only accepted
  `:00` would throw away real runs. Anything inside the Sydney 08:00 or 20:00
  hour counts. A fire delayed past the end of the hour is skipped, and the next
  candidate picks it up.
- `scraper/tests/test_cadence.py` **parses the cron line straight out of
  `scrape.yml`** and asserts the candidate hours stay a superset of everything
  the gate accepts, on both changeover days and through a full year. Editing
  one without the other fails the suite, which is the point. Run it.

`workflow_dispatch` skips the gate entirely, so a manual run always scrapes.

### Two things GitHub does to scheduled workflows

Neither is in our control, and both bite this repo specifically:

- **Scheduled runs are best-effort.** GitHub queues them at low priority and
  drops them outright under load. The fast cadence absorbs that — the next one
  is 20 minutes away — but a dropped full run means no days 3–4 refresh until
  the next slot, twelve hours later. If days 3–4 ever go visibly stale, check
  the Actions run history before suspecting the scraper.
- **60 days without a commit disables every scheduled workflow in a public
  repo.** GitHub emails first. Both workflows stop until someone re-enables
  them in the Actions tab. Worth knowing before a quiet stretch, because
  nothing in the app will say the data stopped arriving.

### Why the fast run does not

An interval is offset-agnostic. Every 20 minutes is every 20 minutes in AEST
and in AEDT alike, so there is nothing for a DST gate to fix.

### Cadence is settled — do not raise it

`BUILD-PLAN.md` decided this and it is not a knob:

| Cadence | Per club per day | Reads like |
|---|---|---|
| Twice daily, 5 days | 10 | nothing |
| **Every 20 min, 3 days** | **216 — one every 7 min** | one keen golfer refreshing |
| Every 5 min, 3 days | 864 — one every 100s | a bot |

What gets a scraper blocked is its request rate at a single host, not its
total; fifteen clubs are fifteen separate servers. Polling exists for
cancellations, and a cancellation only matters inside 48 hours — which is why
fast covers days 0–2 and stops. New timesheet releases happen on a fixed
per-club schedule and want a scheduled burst, not faster polling.

**Do not raise the fast cadence above every 20 minutes, and do not extend it
past day 2.**

---

## Secrets

Both workflows need these two repository secrets under
**Settings → Secrets and variables → Actions**:

| Secret | What it is |
|---|---|
| `SUPABASE_URL` | the project's API URL, e.g. `https://<ref>.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | the service role key — the scraper writes through RLS |

They are read from the environment under exactly those names. The service role
key bypasses RLS, so it lives in Actions secrets and in nothing else — never in
a file, never in the iOS app, never in `docs/`.

Until both exist, a run reaches `--write supabase`, prints
`supabase credentials missing: …` and exits 1 with nothing written.

---

## Running it locally

```bash
pip install -r scraper/requirements.txt

# Fetch and print a summary. Writes nowhere.
python3 scraper/scrape.py --mode fast

# One course, one day — the fastest loop while working on a parser.
python3 scraper/scrape.py --course woollahra --days 1

# Check the payload against the frozen contract without writing it.
python3 scraper/scrape.py --mode full --validate

# Everything a real run does except the writes themselves. Needs the two
# env vars set; use it to prove credentials and shape before going live.
SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… \
  python3 scraper/scrape.py --mode fast --validate --write supabase --dry-run

# Write a payload JSON to a file instead (nothing commits it).
python3 scraper/scrape.py --mode full --out /tmp/teetimes.json
```

| Flag | Does |
|---|---|
| `--mode fast\|full` | `fast` = days 0–2, `full` = days 0–4 (default) |
| `--days N` | override the day count the mode implies |
| `--course SLUG` | one course only; repeatable |
| `--validate` | check against the frozen contract; always on for `--write` |
| `--write supabase\|none` | where the payload goes (default `none`) |
| `--dry-run` | with `--write supabase`, do everything but the writes |
| `--out PATH` | also write the payload JSON there |

Validation gates every write: a payload that fails the contract is never sent.
A run is only a failure when **no** course was reached on any day — one club
changing its HTML must not cost the other fourteen.

### Tests

```bash
python3 -m unittest discover -s scraper/tests -t . -v
```

Run from the repo root. `scraper/` is not a package; `scraper/tests/__init__.py`
puts it on `sys.path` so the tests can `import scrape` the same way the scraper
and `contract/validate.py` do.
