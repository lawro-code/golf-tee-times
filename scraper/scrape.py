"""
Scrape available tee times from MiClub-hosted Sydney public golf courses.

Reads courses.json, fetches each course's public timesheet for the requested
window, and assembles the frozen contract payload (see CONTRACT.md). The
payload can be validated, written to a file, or written to Supabase.

    python3 scraper/scrape.py --mode fast                 # days 0-2
    python3 scraper/scrape.py --mode full                 # days 0-4
    python3 scraper/scrape.py --course woollahra --days 1
    python3 scraper/scrape.py --mode fast --write supabase
    python3 scraper/scrape.py --mode full --out docs/data/teetimes.json

Three things this file is deliberate about:

  1. Status is PER DAY, not per course. A course reached on three days out of
     five is not healthy, and the stale-data banner depends on knowing that.
  2. One course is never allowed to take down a run. Every course is wrapped,
     and a course that raises is recorded as failed on every requested day
     while the other fourteen carry on.
  3. The payload is assembled here from contract/transform.py's frozen
     helpers rather than by transform.build_payload, which collapses a
     course-level error onto every one of its days.

MiClub serves plain server-rendered HTML at a fixed URL. requests +
BeautifulSoup is the right tool; do not replace it with a headless browser.
"""

from __future__ import annotations

import argparse
import inspect
import json
import re
import sys
import traceback
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional
from zoneinfo import ZoneInfo

from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent
for _p in (str(ROOT), str(HERE)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from contract import transform  # noqa: E402

try:
    # scraper/fetcher.py is track A4's: retries, timeouts, per-host courtesy.
    # This file owns no HTTP policy of its own.
    from fetcher import fetch, polite_sleep  # noqa: E402

    _FETCHER_ERROR: Optional[BaseException] = None
except ImportError as exc:  # pragma: no cover - only until A4 lands
    # Fail at the first HTTP call with something actionable rather than at
    # import, so the parsers, the payload builder and their tests stay
    # runnable. There is deliberately no local fallback fetcher.
    fetch = None  # type: ignore[assignment]
    polite_sleep = None  # type: ignore[assignment]
    _FETCHER_ERROR = exc

COURSES_PATH = ROOT / "courses.json"
DEBUG_DIR = HERE / "debug"
SYDNEY = ZoneInfo("Australia/Sydney")

# fast is the every-20-minutes cadence for the days people actually chase
# cancellations in; full is the twice-daily sweep. See BUILD-PLAN.md.
MODE_DAYS = {"fast": 3, "full": 5}
DEFAULT_MODE = "full"

# The frozen schema's bounds. A club that changes its HTML must not be able to
# produce a payload that fails validation and kills the whole run.
MIN_SPOTS = 1
MAX_SPOTS = 8


def now_iso() -> str:
    return datetime.now(SYDNEY).isoformat(timespec="seconds")


def course_host(course: dict) -> str:
    """Match transform.course_row's host rule exactly, or booking_url and the
    course row will disagree about where a slot lives."""
    return course.get("host") or f"{course['slug']}.miclub.com.au"


def timesheet_url(host: str, fee_group_id: str, selected_date: date) -> str:
    return (
        f"https://{host}/guests/bookings/ViewPublicTimesheet.msp"
        f"?bookingResourceId=3000000"
        f"&feeGroupId={fee_group_id}"
        f"&selectedDate={selected_date.isoformat()}"
    )


def _fetch(url: str):
    """Every HTTP call in this file goes through track A4's fetcher."""
    if fetch is None:  # pragma: no cover - only until A4 lands
        raise RuntimeError(
            "scraper/fetcher.py (track A4) is not importable, so no HTTP call "
            f"can be made: {_FETCHER_ERROR}"
        )
    return fetch(url)


def _polite_sleep(host: str) -> None:
    sleeper = polite_sleep
    if sleeper is None:  # pragma: no cover - only until A4 lands
        return
    try:
        takes_host = bool(inspect.signature(sleeper).parameters)
    except (TypeError, ValueError):  # pragma: no cover - exotic callables
        takes_host = False
    if takes_host:
        sleeper(host)
    else:
        sleeper()


# --------------------------------------------------------------------------
# Parsing. requests + BeautifulSoup, and it stays that way.
# --------------------------------------------------------------------------

_TIME_RE = re.compile(r"(\d{1,2}):(\d{2})\s*([ap])m", re.IGNORECASE)


def normalise_time(text: str) -> Optional[str]:
    """'6:16am' -> '06:16'. None when the row has no readable time."""
    m = _TIME_RE.search(text)
    if not m:
        return None
    hour = int(m.group(1))
    minute = int(m.group(2))
    meridiem = m.group(3).lower()
    if meridiem == "p" and hour != 12:
        hour += 12
    elif meridiem == "a" and hour == 12:
        hour = 0
    return f"{hour:02d}:{minute:02d}"


_PRICE_RE = re.compile(r"\$\s*([\d,]+(?:\.\d{1,2})?)")


def parse_price_tiers(fees_wrapper) -> list:
    """Fee lines for one row. An unpriced row returns [] — one live slot in
    six publishes no fee at all, and that is ordinary data, not an error."""
    tiers = []
    if not fees_wrapper:
        return tiers
    for li in fees_wrapper.select("li"):
        full_text = li.get_text(" ", strip=True)
        price_el = li.select_one(".price")
        amount = None
        if price_el:
            m = _PRICE_RE.search(price_el.get_text())
            if m:
                amount = float(m.group(1).replace(",", ""))
        label = full_text
        if price_el:
            label = label.replace(price_el.get_text(strip=True), "").strip()
        label = re.sub(r"\s+", " ", label).strip(" -")
        if amount is not None:
            tiers.append({"label": label or "Standard", "amount": amount})
    return tiers


class TimesheetStructureError(ValueError):
    """The page has zero rows our selectors recognise at all.

    Not the same thing as a day with zero AVAILABLE spots: CONTRACT.md section
    5 is explicit that "Long Reef had zero free tee times and scraped
    perfectly" — a real timesheet lists every tee time for the day, available
    or not, so a genuinely quiet day still has `div.row-time` rows, just none
    with a `cell-available` cell. Finding NO rows at all on an otherwise
    well-formed page (reached, non-empty, not a login/member redirect — those
    are fetcher.py's job) means the selectors no longer match this page's
    markup, which a club or MiClub template/theme push can do without
    changing the HTTP status at all. Raising here — instead of quietly
    returning [] — is what stops that from being recorded as a clean, empty
    day: scrape_course's existing per-day except turns this into a failed
    day, and a failed (course, day) is the one thing
    supabase_writer._close_gone_slots is never allowed to touch, so real
    still-open tee times cannot be marked 'gone' just because a rename made
    the page look silently empty.
    """


def parse_timesheet(html: str, booking_url: str, selected_date: date) -> list:
    """One MiClub public timesheet page -> the rows that still have a spot.

    The booking type (h4) is carried through even when it is blank: it is what
    separates a 1st Tee group from a 10th Tee group going out the same minute.

    Raises TimesheetStructureError when zero rows match at all, or when rows
    match but not one of them yields a readable time + cell structure — see
    that class's docstring for why that must never be treated as an ordinary
    empty day.
    """
    soup = BeautifulSoup(html, "html.parser")
    rows = soup.select("div.row-time")
    if not rows:
        raise TimesheetStructureError(
            "0 rows matched div.row-time — selectors may no longer match "
            "this page's markup (a genuinely empty day still has rows, "
            "just none available; see CONTRACT.md section 5)"
        )
    slots = []
    recognised_rows = 0  # rows whose time + cell structure was readable at
    # all, regardless of how many spots (if any) were available in them.
    unreadable_rows = 0  # rows that matched div.row-time but got no
    # foothold at all (no .time-wrapper h3, unparsable time text, or no
    # .records-wrapper .cell) — distinct from a recognised row that simply
    # has zero available spots today. A page mixing template types (e.g. a
    # shotgun/comp row alongside ordinary public-play rows) can have some of
    # these while recognised_rows stays > 0, so the raise below never fires
    # — that drop must still be counted and reported, never silent.
    for row in rows:
        time_h3 = row.select_one(".time-wrapper h3")
        if not time_h3:
            unreadable_rows += 1
            continue
        t = normalise_time(time_h3.get_text(strip=True))
        if not t:
            unreadable_rows += 1
            continue
        price_tiers = parse_price_tiers(row.select_one(".fees-wrapper"))
        cells = row.select(".records-wrapper .cell")
        if not cells:
            unreadable_rows += 1
            continue
        recognised_rows += 1
        spots_available = sum(1 for c in cells if "cell-available" in (c.get("class") or []))
        if spots_available <= 0:
            continue
        booking_type = ""
        h4 = row.select_one(".time-wrapper h4")
        if h4:
            booking_type = h4.get_text(strip=True)
        slots.append({
            "date": selected_date.isoformat(),
            "time": t,
            "spots_available": spots_available,
            "total_spots": len(cells),
            "price_tiers": price_tiers,
            "booking_type": booking_type,
            "booking_url": booking_url,
        })
    if recognised_rows == 0:
        raise TimesheetStructureError(
            f"{len(rows)} row(s) matched div.row-time but none yielded a "
            "readable .time-wrapper h3 time + .records-wrapper .cell "
            "structure — those selectors may no longer match this page's "
            "markup (a genuinely empty or fully-booked day still has "
            "readable rows, just none available; see CONTRACT.md section 5)"
        )
    if unreadable_rows:
        # Cheaper and kinder than raising over the whole page for the sake
        # of one odd row (see schema_problem's docstring for the same
        # trade-off) — but silently doing nothing here is what let a mixed
        # template page lose a real, bookable row with zero observability.
        print(
            f"  {unreadable_rows} of {len(rows)} row-time row(s) skipped — "
            "no readable .time-wrapper h3 time or .records-wrapper .cell "
            "structure (possible mixed template on this page); any real "
            "availability in those rows is missing from this count",
            file=sys.stderr,
        )
    return slots


# --------------------------------------------------------------------------
# Scraping one course, honestly, day by day
# --------------------------------------------------------------------------

def day_record(
    tee_date: str,
    ok: bool,
    slot_count: int = 0,
    error: Optional[str] = None,
    attempted_at: Optional[str] = None,
    succeeded_at: Optional[str] = None,
) -> dict:
    """One (course, day) outcome.

    Two invariants the frozen validator enforces on the rows built from these,
    so they are enforced here at the source: a day that is ok carries no
    error, and a day that failed claims no success time.
    """
    attempted_at = attempted_at or now_iso()
    return {
        "tee_date": tee_date,
        "ok": bool(ok),
        "slot_count": int(slot_count),
        "error": None if ok else (error or "unknown failure"),
        "attempted_at": attempted_at,
        "succeeded_at": (succeeded_at or attempted_at) if ok else None,
    }


def requested_dates(days: int, today: Optional[date] = None) -> list:
    today = today or datetime.now(SYDNEY).date()
    return [(today + timedelta(days=offset)).isoformat() for offset in range(days)]


def _course_error(day_records: Iterable[dict], days: int) -> Optional[str]:
    """Non-null when ANY day failed, naming the dates.

    Deliberately pessimistic: this is the field the legacy
    transform.build_payload path collapses onto every day, and being
    pessimistic there is the safe direction. The per-day records carry the
    honest picture and are what the Supabase write path uses.
    """
    failed = [d for d in day_records if not d["ok"]]
    if not failed:
        return None
    detail = ", ".join(f"{d['tee_date']} ({d['error']})" for d in failed)
    return f"{len(failed)} of {days} day(s) failed: {detail}"


def scrape_course(course: dict, days: int, today: Optional[date] = None) -> dict:
    """Scrape one course over `days` days from today, Sydney time.

    FROZEN SIGNATURE for the first two (positional) arguments.
    contract/validate.py:live_payload calls this positionally and feeds the
    result to transform.build_payload, which reads slug, slots and error.
    Keys may be added to the returned dict; none may be removed.

    `today` defaults to "right now" when omitted, but a run that scrapes
    several courses in a loop must compute it ONCE and pass the same value to
    every call — otherwise a loop that happens to straddle Sydney local
    midnight hands different courses in the same payload a different
    day-window (see main()).
    """
    host = course_host(course)
    today = today or datetime.now(SYDNEY).date()
    all_slots: list = []
    day_records: list = []

    # Most clubs sell every tee time off one fee group and one URL covers a
    # whole day. A few (Eastlake first) now split the day into time bands —
    # MON-FRI before 3pm, weekend after 3pm, etc — each billed under its own
    # feeGroupId, so no single URL returns the whole day any more. Those
    # clubs carry `feeGroupIds` (a list) in courses.json instead of
    # `feeGroupId`; everyone else keeps the single-URL path unchanged.
    fee_group_ids = course.get("feeGroupIds") or [course["feeGroupId"]]

    # Fetched but not yet turned into day_records: a day with zero rows on
    # every band is ambiguous until every day for this course has been
    # fetched — see the comment below.
    pending: list = []

    for offset in range(days):
        target = today + timedelta(days=offset)
        tee_date = target.isoformat()
        attempted_at = now_iso()

        day_slots: list = []
        band_errors: list = []
        structure_empty = True  # stays True only if every band's failure was
        # specifically "zero div.row-time rows matched" — never a fetch
        # failure or any other parse exception.
        for fee_group_id in fee_group_ids:
            url = timesheet_url(host, fee_group_id, target)
            result = _fetch(url)
            if not getattr(result, "ok", False):
                reason = (getattr(result, "error", None) or "fetch failed").strip()
                band_errors.append(reason)
                structure_empty = False
                continue

            html = getattr(result, "html", None) or ""
            try:
                day_slots.extend(parse_timesheet(html, url, target))
            except TimesheetStructureError as e:
                band_errors.append(f"parse error: {type(e).__name__}: {e}")
                continue
            except Exception as e:
                reason = f"parse error: {type(e).__name__}: {e}"
                band_errors.append(reason)
                structure_empty = False
                try:
                    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
                    suffix = f"_{fee_group_id}" if len(fee_group_ids) > 1 else ""
                    (DEBUG_DIR / f"{course['slug']}_{tee_date}{suffix}.html").write_text(html)
                except OSError:
                    pass
                continue
            if len(fee_group_ids) > 1:
                _polite_sleep(host)

        pending.append({
            "tee_date": tee_date,
            "attempted_at": attempted_at,
            "slots": day_slots,
            "band_errors": band_errors,
            "structure_empty": structure_empty and not day_slots,
        })
        _polite_sleep(host)

    # A day where every band comes back with zero div.row-time rows
    # (TimesheetStructureError) is genuinely ambiguous on its own: it is
    # what a dead feeGroupId looks like (Eastlake, Long Reef both did this
    # before their IDs were fixed) AND what a club's own "nothing public
    # published for this date" page looks like (a Saturday competition
    # locking out guest play, say) — both render byte-for-byte the same
    # zero-row shell, with no HTML marker that tells the two apart; MiClub's
    # own "#no-rows" placeholder and hidden error template sit in both
    # equally. Another day in THIS SAME RUN for THIS SAME COURSE settles it:
    # if any other requested day actually produced real rows, the
    # feeGroupId plainly still works, so a zero-row day is the club's own
    # choice, not a broken scraper, and is recorded as a clean, empty day.
    # Only when EVERY requested day comes back empty does the ambiguity
    # stay unresolved, and the day is reported failed — exactly as before.
    saw_real_rows = any(d["slots"] for d in pending)

    for d in pending:
        tee_date = d["tee_date"]
        print(f"  {course['slug']} {tee_date} -> ", end="", flush=True)
        if d["slots"]:
            print(f"{len(d['slots'])} slot(s)")
            all_slots.extend(d["slots"])
            day_records.append(day_record(
                tee_date, True, slot_count=len(d["slots"]),
                attempted_at=d["attempted_at"], succeeded_at=now_iso(),
            ))
        elif not d["band_errors"]:
            # Every band ran clean and simply found no available spots on a
            # page that otherwise parsed fine (parse_timesheet's ordinary,
            # unambiguous "ok" result) — no reclassification needed, this
            # was never in question.
            print("0 slot(s)")
            day_records.append(day_record(
                tee_date, True, slot_count=0,
                attempted_at=d["attempted_at"], succeeded_at=now_iso(),
            ))
        elif d["structure_empty"] and saw_real_rows:
            print("0 slot(s) (nothing published for this date)")
            day_records.append(day_record(
                tee_date, True, slot_count=0,
                attempted_at=d["attempted_at"], succeeded_at=now_iso(),
            ))
        else:
            reason = "; ".join(d["band_errors"]) or "unknown failure"
            label = "PARSE ERROR" if "parse error" in reason else "FAIL"
            print(f"{label} ({reason})")
            day_records.append(day_record(tee_date, False, error=reason, attempted_at=d["attempted_at"]))

    return {
        "slug": course["slug"],
        "name": course["name"],
        "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"),
        "par": course.get("par"),
        "notes": course.get("notes", ""),
        "host": host,
        "error": _course_error(day_records, days),
        "days": day_records,
        "slots": all_slots,
    }


def failed_course(course: dict, days: int, reason: str, today: Optional[date] = None) -> dict:
    """A course that blew up before it could report for itself."""
    records = [day_record(d, False, error=reason) for d in requested_dates(days, today)]
    return {
        "slug": course.get("slug", ""),
        "name": course.get("name", course.get("slug", "unknown course")),
        "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"),
        "par": course.get("par"),
        "notes": course.get("notes", ""),
        "host": course.get("host", ""),
        "error": _course_error(records, days),
        "days": records,
        "slots": [],
    }


# --------------------------------------------------------------------------
# Assembling the contract payload
# --------------------------------------------------------------------------

def schema_problem(row: dict) -> Optional[str]:
    """Why this slot row would fail the frozen schema, or None.

    Cheaper and kinder than letting one club's changed HTML fail validation
    for the whole run: the row is dropped, counted and reported.
    """
    for field in ("spots_available", "total_spots"):
        value = row.get(field)
        if not isinstance(value, int) or isinstance(value, bool):
            return f"{field} is not an integer ({value!r})"
        if not MIN_SPOTS <= value <= MAX_SPOTS:
            return f"{field}={value} is outside {MIN_SPOTS}-{MAX_SPOTS}"
    if row["spots_available"] > row["total_spots"]:
        return f"spots_available={row['spots_available']} exceeds total_spots={row['total_spots']}"
    if not str(row.get("booking_url", "")).startswith("https://"):
        return f"booking_url {row.get('booking_url')!r} is not https"
    return None


def _legacy_day_records(scraped: dict, fallback_dates: Iterable[str], generated_at: str) -> list:
    """Day records for a raw course dict from before per-day status existed.

    contract/fixtures/raw_live.json is that older shape, and it is the fixture
    the payload assembly is tested against.
    """
    error = scraped.get("error")
    dates = sorted(set(fallback_dates) | {s["date"] for s in scraped.get("slots", [])})
    return [
        day_record(d, error is None, error=error, attempted_at=generated_at, succeeded_at=generated_at)
        for d in dates
    ]


def payload_from_results(
    results: list,
    roster: list,
    mode: str = DEFAULT_MODE,
    days: Optional[int] = None,
    generated_at: Optional[str] = None,
) -> dict:
    """Scraped courses + the frozen roster -> a contract payload.

    Not transform.build_payload: that one copies the course-level error onto
    every day, which is exactly the dishonesty this ticket removes. The
    per-slot work still goes through transform's frozen helpers so the slot id
    rule, the Sydney timezone rule and the per-booking hole count live in one
    place.
    """
    by_slug = {c["slug"]: c for c in roster}
    order = {c["slug"]: i for i, c in enumerate(roster)}
    generated_at = generated_at or now_iso()
    days = days or MODE_DAYS.get(mode, MODE_DAYS[DEFAULT_MODE])

    slots: list = []
    course_days: list = []
    index_by_id: dict = {}
    dropped: list = []

    fallback_dates = sorted({s["date"] for r in results for s in r.get("slots", [])})
    if not fallback_dates:
        fallback_dates = [generated_at[:10]]

    for scraped in results:
        slug = scraped.get("slug")
        course = by_slug.get(slug)
        if course is None:
            # A course that is not on the frozen roster is dropped rather than
            # invented into existence.
            continue

        counts: dict = {}
        for raw_slot in scraped.get("slots", []):
            try:
                # The ROSTER entry, not the scraped dict: it is how par and the
                # course hole count reach the slot, and holes_for_slot then
                # derives THIS booking's hole count from the booking type and
                # the fee labels.
                row = transform.slot_row(raw_slot, course)
            except Exception as e:
                dropped.append(f"{slug}: unparseable slot ({type(e).__name__}: {e})")
                continue

            problem = schema_problem(row)
            if problem:
                dropped.append(f"{slug} {row['tee_date']} {row['tee_time']}: {problem}")
                continue

            existing = index_by_id.get(row["id"])
            if existing is not None:
                # Two rows sharing an id once the tee is taken into account is
                # a real duplicate. Keep the one offering more spots rather
                # than letting parse order decide.
                if row["spots_available"] > slots[existing]["spots_available"]:
                    slots[existing] = row
                continue

            index_by_id[row["id"]] = len(slots)
            slots.append(row)
            counts[row["tee_date"]] = counts.get(row["tee_date"], 0) + 1

        records = scraped.get("days") or _legacy_day_records(scraped, fallback_dates, generated_at)
        for rec in records:
            ok = bool(rec.get("ok"))
            course_days.append({
                "course_slug": slug,
                "tee_date": rec["tee_date"],
                "ok": ok,
                # The count of slots that actually made it into this payload,
                # so course_days and slots can never disagree.
                "slot_count": counts.get(rec["tee_date"], 0),
                "error": None if ok else (rec.get("error") or "unknown failure"),
                "last_attempt_at": rec.get("attempted_at") or generated_at,
                "last_success_at": (rec.get("succeeded_at") or generated_at) if ok else None,
            })

    if dropped:
        print(f"dropped {len(dropped)} slot(s) that would have violated the schema:", file=sys.stderr)
        for line in dropped[:10]:
            print(f"  {line}", file=sys.stderr)
        if len(dropped) > 10:
            print(f"  ... and {len(dropped) - 10} more", file=sys.stderr)

    slots.sort(key=lambda s: (s["tee_at"], s["course_slug"]))
    course_days.sort(key=lambda d: (d["course_slug"], d["tee_date"]))

    return {
        "contract_version": transform.CONTRACT_VERSION,
        "generated_at": generated_at,
        "mode": mode,
        "days": days,
        "courses": [transform.course_row(c, order[c["slug"]]) for c in roster],
        "slots": slots,
        "course_days": course_days,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def load_roster(path: Path = COURSES_PATH) -> list:
    return json.loads(Path(path).read_text())["courses"]


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Scrape MiClub public timesheets into the contract payload.")
    ap.add_argument("--mode", choices=sorted(MODE_DAYS), default=DEFAULT_MODE,
                    help="fast = days 0-2 (the 20-minute cadence), full = days 0-4 (default)")
    ap.add_argument("--days", type=int, help="override the day count the mode implies")
    ap.add_argument("--course", action="append", dest="courses", metavar="SLUG",
                    help="only this course slug; repeatable")
    ap.add_argument("--validate", action="store_true",
                    help="validate against the frozen contract before writing anything (always on for --write)")
    ap.add_argument("--write", choices=("supabase", "none"), default="none",
                    help="where to write the payload (default: none)")
    ap.add_argument("--dry-run", action="store_true", help="with --write supabase, do everything but the writes")
    ap.add_argument("--out", metavar="PATH", help="also write the payload JSON here (default: no file)")
    return ap


def _select_courses(roster: list, wanted: Optional[list]) -> list:
    if not wanted:
        return roster
    chosen = [c for c in roster if c["slug"] in set(wanted)]
    missing = sorted(set(wanted) - {c["slug"] for c in chosen})
    if missing:
        raise SystemExit(f"not in courses.json: {', '.join(missing)}")
    return chosen


def main(argv: Optional[list] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    days = args.days if args.days is not None else MODE_DAYS[args.mode]
    # The frozen schema caps the window at 14 days; refuse rather than build a
    # payload that cannot validate.
    if not 1 <= days <= 14:
        raise SystemExit("--days must be between 1 and 14")

    roster = load_roster()
    courses = _select_courses(roster, args.courses)
    if not courses:
        raise SystemExit("no courses configured in courses.json — nothing to scrape")

    print(f"scraping {len(courses)} course(s), {days} day(s) each ({args.mode} mode)")
    # Computed once, here, and handed to every course: 15 courses x up to
    # `days` fetches each, with the fetcher's own retries/backoff, is enough
    # elapsed time for a run to cross Sydney local midnight mid-loop. Every
    # course in this run must agree on what day "today" is, or the courses on
    # either side of midnight end up with different day-windows in the same
    # payload.
    today = datetime.now(SYDNEY).date()
    results: list = []
    for course in courses:
        label = course.get("name") or course.get("slug") or "unknown course"
        print(f"--- {label} ---")
        try:
            results.append(scrape_course(course, days, today=today))
        except Exception as e:
            # One malformed roster entry, one club's markup blowing up
            # BeautifulSoup, one socket doing something exotic — none of it is
            # allowed to cost us the other fourteen courses.
            reason = f"{type(e).__name__}: {e}"
            print(f"  course failed: {reason}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            results.append(failed_course(course, days, reason, today=today))

    payload = payload_from_results(results, roster, mode=args.mode, days=days)

    ok_courses = [r for r in results if r.get("error") is None]
    reached = [r for r in results if any(d.get("ok") for d in r.get("days", []))]
    ok_days = sum(1 for d in payload["course_days"] if d["ok"])
    print(
        f"\n{len(payload['slots'])} slot(s) — "
        f"{len(ok_courses)}/{len(results)} course(s) clean, "
        f"{ok_days}/{len(payload['course_days'])} course-day(s) reached"
    )
    for r in results:
        if r.get("error"):
            print(f"  {r['slug']}: {r['error']}")

    # Validation gates every write. Nothing is written when it fails.
    if args.validate or args.write != "none":
        from contract.validate import validate  # noqa: E402

        problems = validate(payload)
        if problems:
            print(f"\n{len(problems)} contract violation(s):", file=sys.stderr)
            for p in problems:
                print(f"  {p}", file=sys.stderr)
            return 1
        print("CONTRACT OK")

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2))
        print(f"wrote {out_path}")

    if args.write == "supabase":
        try:
            # scraper/supabase_writer.py is track A2's.
            from supabase_writer import MissingCredentials, SupabaseWriter  # noqa: E402
        except ImportError as e:  # pragma: no cover - only until A2 lands
            print(f"cannot write to supabase: {e}", file=sys.stderr)
            return 1

        try:
            writer = SupabaseWriter.from_env(dry_run=args.dry_run)
        except MissingCredentials as e:
            print(f"supabase credentials missing: {e}", file=sys.stderr)
            return 1
        result = writer.write(payload)
        print(
            f"supabase{' (dry run)' if args.dry_run else ''}: "
            f"run {result.run_id} — {result.slots_upserted} slot(s) upserted, "
            f"{result.slots_closed} closed, {result.course_days_written} course-day(s)"
        )
        for err in result.errors or []:
            print(f"  write error: {err}", file=sys.stderr)
        if result.errors:
            return 1

    # A run is only a failure when not one course was reached on any day.
    if results and not reached:
        print(f"every course failed ({len(results)} attempted)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
