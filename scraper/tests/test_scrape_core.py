"""Per-day honesty, per-course isolation and the CLI.

The case that matters most here is the one the old scraper got wrong: a course
reached on three days out of five reported no error at all, so the stale-data
banner stayed silent while two days of inventory were missing.
"""

import contextlib
import inspect
import io
import json
import sys
import tempfile
import types
import unittest
from datetime import date, datetime
from pathlib import Path
from unittest import mock

from contract.validate import validate

import fetcher
import scrape


# --------------------------------------------------------------------------
# Fakes. Track A4 owns the real fetcher; this is the shape scrape.py consumes:
# .ok, .html and a short human-readable .error.
# --------------------------------------------------------------------------

class FakeResult:
    def __init__(self, ok, html="", error=None):
        self.ok = ok
        self.html = html
        self.error = error


def ok(html):
    return FakeResult(True, html=html)


def fail(reason):
    return FakeResult(False, error=reason)


class Sequence:
    """Returns the given results in order, one per HTTP call."""

    def __init__(self, results):
        self.results = list(results)
        self.urls = []

    def __call__(self, url):
        self.urls.append(url)
        return self.results.pop(0)


def row_html(time_text, booking_type="Public Play", tiers=(), available=2, total=4):
    fees = ""
    if tiers:
        lis = "".join(
            f'<li>{label} <span class="price">${amount:.2f}</span></li>' for label, amount in tiers
        )
        fees = f'<div class="fees-wrapper"><ul>{lis}</ul></div>'
    cells = "".join(
        f'<div class="cell {"cell-available" if i < available else "cell-booked"}"></div>'
        for i in range(total)
    )
    return (
        '<div class="row-time">'
        f'<div class="time-wrapper"><h3>{time_text}</h3><h4>{booking_type}</h4></div>'
        f'{fees}'
        f'<div class="records-wrapper">{cells}</div>'
        '</div>'
    )


def page(*rows):
    return "<html><body>" + "".join(rows) + "</body></html>"


TWO_SLOTS = page(
    row_html("6:16am", "1st Tee Social", [("Social 18", 45.0)]),
    row_html("6:24am", "1st Tee Social", [("Social 18", 45.0)]),
)

WOOLLAHRA = {
    "name": "Woollahra Golf Club",
    "slug": "woollahra",
    "host": "woollahra.miclub.com.au",
    "feeGroupId": "3050666",
    "region": "Eastern Suburbs",
    "drive_minutes_from_bondi": 10,
    "holes": 9,
    "par": 34,
    "notes": "",
}


class PerDayStatusTests(unittest.TestCase):
    def scrape(self, results, days, course=None):
        fetcher = Sequence(results)
        with mock.patch.object(scrape, "fetch", fetcher), \
                mock.patch.object(scrape, "polite_sleep", lambda *a: None), \
                contextlib.redirect_stdout(io.StringIO()):
            return scrape.scrape_course(course or WOOLLAHRA, days), fetcher

    def test_three_of_five_days_reached_is_not_a_healthy_course(self):
        """The bug this ticket exists for: 3/5 days used to read as clean."""
        result, _ = self.scrape(
            [ok(TWO_SLOTS), fail("http 500"), ok(TWO_SLOTS), fail("connection timed out"), ok(TWO_SLOTS)],
            days=5,
        )

        days = result["days"]
        self.assertEqual(len(days), 5)
        self.assertEqual([d["ok"] for d in days], [True, False, True, False, True])
        self.assertEqual(sum(1 for d in days if d["ok"]), 3)
        self.assertEqual(sum(1 for d in days if not d["ok"]), 2)

        self.assertIsNotNone(result["error"])
        expected_dates = scrape.requested_dates(5)
        self.assertIn(expected_dates[1], result["error"])
        self.assertIn(expected_dates[3], result["error"])
        self.assertIn("http 500", result["error"])
        self.assertIn("connection timed out", result["error"])

        # Six slots survived, two days' worth did not.
        self.assertEqual(len(result["slots"]), 6)
        self.assertEqual([d["slot_count"] for d in days], [2, 0, 2, 0, 2])

    def test_per_day_invariants_hold(self):
        result, _ = self.scrape([ok(TWO_SLOTS), fail("http 503"), ok(TWO_SLOTS)], days=3)
        for day in result["days"]:
            self.assertEqual(set(day), {"tee_date", "ok", "slot_count", "error", "attempted_at", "succeeded_at"})
            if day["ok"]:
                self.assertIsNone(day["error"], "a day marked ok must carry no error")
                self.assertIsNotNone(day["succeeded_at"])
            else:
                self.assertIsNotNone(day["error"])
                self.assertIsNone(day["succeeded_at"], "a failed day must claim no success time")

    def test_every_day_reached_means_no_course_error(self):
        result, _ = self.scrape([ok(TWO_SLOTS)] * 3, days=3)
        self.assertIsNone(result["error"])
        self.assertTrue(all(d["ok"] for d in result["days"]))

    def test_par_and_the_frozen_keys_are_returned(self):
        result, _ = self.scrape([ok(TWO_SLOTS)], days=1)
        for key in ("slug", "name", "region", "drive_minutes_from_bondi", "holes",
                    "par", "notes", "host", "error", "slots", "days"):
            self.assertIn(key, result)
        self.assertEqual(result["par"], 34)

    def test_a_days_parse_failure_is_that_days_failure_only(self):
        broken = "<div class='row-time'><div class='time-wrapper'><h3>7:00am</h3></div></div>"
        with tempfile.TemporaryDirectory() as tmp:
            debug_dir = Path(tmp) / "debug"
            with mock.patch.object(scrape, "parse_timesheet", side_effect=[ValueError("bad markup"), []]), \
                    mock.patch.object(scrape, "DEBUG_DIR", debug_dir):
                result, _ = self.scrape([ok(broken), ok(TWO_SLOTS)], days=2)
            # The page that broke the parser is kept so it can be looked at.
            dumped = list(debug_dir.glob("woollahra_*.html"))
            self.assertEqual(len(dumped), 1)
            self.assertEqual(dumped[0].read_text(), broken)

        self.assertEqual([d["ok"] for d in result["days"]], [False, True])
        self.assertIn("bad markup", result["days"][0]["error"])

    def test_a_club_side_rename_fails_the_day_instead_of_reporting_it_clean_and_empty(self):
        """The regression this ticket exists for.

        A normal 200 OK page with two genuinely open tee times, but with the
        wrapper/cell classes renamed (a plausible club/MiClub template push:
        div.row-time -> div.tee-row, .records-wrapper .cell -> .slots-block
        .slot). Before the fix this silently produced ok=True, slot_count=0,
        error=None — indistinguishable from a real quiet day — which is
        exactly what let supabase_writer._close_gone_slots treat the day as a
        successful scrape that stopped listing every currently-open slot for
        that course/day, and mark real, still-available tee times 'gone'.
        """
        renamed_page = page("""
        <div class="tee-row">
          <div class="time-wrapper"><h3>6:16am</h3><h4>1st Tee Social</h4></div>
          <div class="slots-block">
            <div class="slot slot-available"></div>
            <div class="slot slot-available"></div>
          </div>
        </div>
        <div class="tee-row">
          <div class="time-wrapper"><h3>6:24am</h3><h4>1st Tee Social</h4></div>
          <div class="slots-block">
            <div class="slot slot-available"></div>
          </div>
        </div>
        """)
        result, _ = self.scrape([ok(renamed_page)], days=1)

        day = result["days"][0]
        self.assertFalse(day["ok"], "a page whose selectors matched nothing must not read as a clean day")
        self.assertIsNotNone(day["error"])
        self.assertIsNone(day["succeeded_at"])
        self.assertIsNotNone(result["error"])
        # No slots is the honest side effect of failing the day, not a claim
        # that the course has no availability.
        self.assertEqual(result["slots"], [])

    def test_one_request_per_requested_day(self):
        _, fetcher = self.scrape([ok(TWO_SLOTS)] * 4, days=4)
        self.assertEqual(len(fetcher.urls), 4)
        for url, tee_date in zip(fetcher.urls, scrape.requested_dates(4)):
            self.assertIn(f"selectedDate={tee_date}", url)
            self.assertTrue(url.startswith("https://woollahra.miclub.com.au/"))


class MidnightBoundaryTests(unittest.TestCase):
    """The regression this ticket fixes: a run's course loop can straddle
    Sydney local midnight (retries, timeouts and per-host courtesy sleeps are
    plenty of elapsed time across 15 courses). Every course scraped in the
    SAME run must anchor its day-window to the same 'today', not to whatever
    the wall clock read when that particular course's turn came up."""

    def test_a_run_uses_one_today_for_every_course_even_across_midnight(self):
        before = datetime(2026, 9, 19, 23, 58, tzinfo=scrape.SYDNEY)
        after = datetime(2026, 9, 20, 0, 3, tzinfo=scrape.SYDNEY)
        calls = {"n": 0}

        class FrozenDatetime(scrape.datetime):
            @classmethod
            def now(cls, tz=None):
                # First call is a run computing (or, pre-fix, the first
                # course computing its own) 'today' just before midnight;
                # every later now() call -- the second course's own today
                # calc, and every attempted/succeeded timestamp -- lands just
                # after it, exactly like a run that crosses local midnight
                # mid-loop.
                calls["n"] += 1
                value = before if calls["n"] == 1 else after
                return value if tz is None else value.astimezone(tz)

        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "payload.json"
            with mock.patch.object(scrape, "datetime", FrozenDatetime), \
                    mock.patch.object(scrape, "fetch", lambda url: fail("stubbed")), \
                    mock.patch.object(scrape, "polite_sleep", lambda *a: None), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                scrape.main([
                    "--course", "woollahra", "--course", "eastlake",
                    "--days", "1", "--out", str(out_path),
                ])
            payload = json.loads(out_path.read_text())

        by_course = {d["course_slug"]: d["tee_date"] for d in payload["course_days"]}
        self.assertEqual(
            by_course["woollahra"], by_course["eastlake"],
            "two courses in the same run disagreed about which date 'today' "
            "is, purely because the loop crossed local midnight between them",
        )
        self.assertEqual(by_course["woollahra"], "2026-09-19",
                         "the whole run should anchor to 'today' as of when it started")


class ParserTests(unittest.TestCase):
    def test_times_normalise_to_24_hour(self):
        self.assertEqual(scrape.normalise_time("6:16am"), "06:16")
        self.assertEqual(scrape.normalise_time("12:05am"), "00:05")
        self.assertEqual(scrape.normalise_time("12:30pm"), "12:30")
        self.assertEqual(scrape.normalise_time("4:05pm"), "16:05")
        self.assertIsNone(scrape.normalise_time("Starter"))

    def test_a_full_row_is_skipped_and_a_partly_free_row_is_not(self):
        html = page(
            row_html("7:00am", "Public Play", [("Midweek", 39.0)], available=0, total=4),
            row_html("7:08am", "Public Play", [("Midweek", 39.0)], available=3, total=4),
        )
        slots = scrape.parse_timesheet(html, "https://example.test/x", date(2026, 9, 18))
        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0]["time"], "07:08")
        self.assertEqual(slots[0]["spots_available"], 3)
        self.assertEqual(slots[0]["total_spots"], 4)
        self.assertEqual(slots[0]["price_tiers"], [{"label": "Midweek", "amount": 39.0}])

    def test_a_row_with_no_fees_has_no_tiers(self):
        slots = scrape.parse_timesheet(page(row_html("8:00am", "Public Play")), "https://x.test/y", date(2026, 9, 18))
        self.assertEqual(slots[0]["price_tiers"], [])

    def test_a_fully_booked_day_is_still_zero_available_not_a_structural_error(self):
        """CONTRACT.md section 5: 'Long Reef had zero free tee times and
        scraped perfectly.' Rows are present, just none available — this must
        return [] quietly, not raise."""
        html = page(
            row_html("7:00am", "Public Play", [("Midweek", 39.0)], available=0, total=4),
            row_html("7:08am", "Public Play", [("Midweek", 39.0)], available=0, total=4),
        )
        slots = scrape.parse_timesheet(html, "https://example.test/x", date(2026, 9, 18))
        self.assertEqual(slots, [])

    def test_zero_rows_at_all_raises_instead_of_reporting_a_clean_empty_day(self):
        """The defect this ticket fixes: a club/MiClub markup rename (e.g.
        div.row-time -> div.tee-row, .records-wrapper .cell -> .slots-block
        .slot) makes the row selector match nothing at all. That must not be
        indistinguishable from a genuinely quiet day (previous test) — it has
        to surface as a structural failure so scrape_course records the day as
        failed rather than clean-and-empty."""
        renamed_markup = """
        <div class="tee-row">
          <div class="time-wrapper"><h3>6:16am</h3><h4>1st Tee Social</h4></div>
          <div class="slots-block">
            <div class="slot slot-available"></div>
            <div class="slot slot-available"></div>
          </div>
        </div>
        """
        with self.assertRaises(scrape.TimesheetStructureError):
            scrape.parse_timesheet(page(renamed_markup), "https://example.test/x", date(2026, 9, 18))

    def test_inner_selectors_renamed_also_raises_not_returns_empty(self):
        """div.row-time still matches (outer wrapper untouched), but the
        markup inside each row was renamed — .time-wrapper -> .time-box,
        .records-wrapper -> .slots-grid. Every row hits `continue` for want
        of a readable time/cell structure and the loop falls through with an
        untouched `slots = []`, which is indistinguishable from a genuinely
        quiet day unless something notices that NO row anywhere was actually
        readable."""
        inner_renamed = page("""
        <div class="row-time">
          <div class="time-box"><h3>6:16am</h3><h4>1st Tee Social</h4></div>
          <div class="slots-grid">
            <div class="cell cell-available"></div>
            <div class="cell cell-available"></div>
          </div>
        </div>
        <div class="row-time">
          <div class="time-box"><h3>6:24am</h3><h4>1st Tee Social</h4></div>
          <div class="slots-grid">
            <div class="cell cell-available"></div>
          </div>
        </div>
        """)
        with self.assertRaises(scrape.TimesheetStructureError):
            scrape.parse_timesheet(inner_renamed, "https://example.test/x", date(2026, 9, 18))

    def test_a_single_unreadable_row_among_good_rows_is_counted_not_silent(self):
        """The defect this ticket fixes: parse_timesheet's four `continue`
        points (no .time-wrapper h3, unmatched time text, no
        .records-wrapper .cell, zero available cells) increment nothing and
        print nothing. A club that mixes template types on one page -- e.g.
        a shotgun/comp row whose cells sit under a differently-named
        wrapper -- can drop ONE real, open row while the other rows on the
        page parse fine, so `recognised_rows` stays > 0 and
        TimesheetStructureError never fires. That must not be silent: it
        has to be counted and reported, the same way schema_problem's
        dropped rows are 'cheaper... but counted and reported', even though
        the row's actual availability still can't be recovered from
        markup the selectors don't recognise."""
        mixed_page = page(
            row_html("6:16am", "Public Play", [("Midweek", 39.0)], available=2, total=4),
            row_html("6:24am", "Public Play", [("Midweek", 39.0)], available=2, total=4),
            # A shotgun/comp row real-world-plausible on a MiClub site: the
            # time text carries extra words but still matches _TIME_RE, while
            # its slot cells sit under a wrapper .records-wrapper .cell
            # cannot see -- and it has open spots.
            '<div class="row-time">'
            '<div class="time-wrapper"><h3>Shotgun 12:30pm start</h3></div>'
            '<div class="slots-block">'
            '<div class="slot slot-available"></div>'
            '<div class="slot slot-available"></div>'
            '</div>'
            '</div>',
        )
        self.assertEqual(mixed_page.count('class="row-time"'), 3, "sanity: 3 rows are really on the page")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            slots = scrape.parse_timesheet(mixed_page, "https://example.test/x", date(2026, 9, 18))

        # The third row's real availability genuinely cannot be recovered --
        # its cells are unreadable under this selector -- but its loss must
        # now be visible instead of indistinguishable from "only 2 rows
        # existed".
        self.assertEqual(len(slots), 2)
        self.assertIn("1", stderr.getvalue(), "the one skipped row must be counted, not just implied")
        self.assertTrue(stderr.getvalue().strip(), "a structurally-unreadable row among good rows must leave a trace")


# --------------------------------------------------------------------------
# Per-course isolation, through main()
# --------------------------------------------------------------------------

def good_result(course, days=1, slots_per_day=1, today=None):
    dates = scrape.requested_dates(days)
    host = scrape.course_host(course)
    slots = []
    records = []
    for tee_date in dates:
        url = scrape.timesheet_url(host, course["feeGroupId"], date.fromisoformat(tee_date))
        for i in range(slots_per_day):
            slots.append({
                "date": tee_date,
                "time": f"07:{i:02d}",
                "spots_available": 2,
                "total_spots": 4,
                "price_tiers": [{"label": "Social", "amount": 45.0}],
                "booking_type": "Public Play",
                "booking_url": url,
            })
        records.append(scrape.day_record(tee_date, True, slot_count=slots_per_day))
    return {
        "slug": course["slug"], "name": course["name"], "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"), "par": course.get("par"), "notes": course.get("notes", ""),
        "host": host, "error": None, "days": records, "slots": slots,
    }


class RunIsolationTests(unittest.TestCase):
    def run_main(self, argv, side_effect):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(scrape, "scrape_course", side_effect=side_effect), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = scrape.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_a_course_that_raises_does_not_stop_the_others(self):
        def side_effect(course, days, today=None):
            if course["slug"] == "woollahra":
                raise KeyError("feeGroupId")
            return good_result(course, days)

        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "payload.json"
            code, stdout, _ = self.run_main(
                ["--course", "woollahra", "--course", "eastlake", "--days", "1",
                 "--validate", "--out", str(out_path)],
                side_effect,
            )
            self.assertEqual(code, 0, stdout)
            payload = json.loads(out_path.read_text())

        self.assertEqual({s["course_slug"] for s in payload["slots"]}, {"eastlake"})

        by_slug = {d["course_slug"]: d for d in payload["course_days"]}
        self.assertFalse(by_slug["woollahra"]["ok"])
        self.assertIn("KeyError", by_slug["woollahra"]["error"])
        self.assertIsNone(by_slug["woollahra"]["last_success_at"])
        self.assertTrue(by_slug["eastlake"]["ok"])
        self.assertIsNone(by_slug["eastlake"]["error"])
        self.assertIn("CONTRACT OK", stdout)

    def test_a_course_that_raises_is_failed_on_every_requested_day(self):
        def side_effect(course, days, today=None):
            raise ValueError("courses.json entry is malformed")

        code, _, err = self.run_main(["--course", "woollahra", "--days", "5"], side_effect)
        self.assertEqual(code, 1, "a run where every course failed exits non-zero")
        self.assertIn("every course failed", err)

    def test_a_run_with_one_survivor_still_exits_zero(self):
        def side_effect(course, days, today=None):
            if course["slug"] == "woollahra":
                raise RuntimeError("boom")
            return good_result(course, days)

        code, _, _ = self.run_main(["--course", "woollahra", "--course", "eastlake", "--days", "1"], side_effect)
        self.assertEqual(code, 0)

    def test_an_unknown_course_slug_is_refused(self):
        with self.assertRaises(SystemExit):
            self.run_main(["--course", "st-andrews"], lambda c, d, today=None: good_result(c, d))


class CliTests(unittest.TestCase):
    def run_main(self, argv):
        seen = {}

        def side_effect(course, days, today=None):
            seen["days"] = days
            return good_result(course, days)

        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "payload.json"
            with mock.patch.object(scrape, "scrape_course", side_effect=side_effect), \
                    contextlib.redirect_stdout(out):
                code = scrape.main(argv + ["--out", str(out_path)])
            payload = json.loads(out_path.read_text())
        return code, seen, payload, out.getvalue()

    def test_fast_mode_is_three_days(self):
        _, seen, payload, _ = self.run_main(["--mode", "fast", "--course", "woollahra"])
        self.assertEqual(seen["days"], 3)
        self.assertEqual(payload["mode"], "fast")
        self.assertEqual(payload["days"], 3)

    def test_full_mode_is_five_days(self):
        _, seen, payload, _ = self.run_main(["--mode", "full", "--course", "woollahra"])
        self.assertEqual(seen["days"], 5)
        self.assertEqual(payload["mode"], "full")
        self.assertEqual(payload["days"], 5)

    def test_days_overrides_the_mode_mapping(self):
        _, seen, payload, _ = self.run_main(["--mode", "fast", "--days", "1", "--course", "woollahra"])
        self.assertEqual(seen["days"], 1)
        self.assertEqual(payload["days"], 1)
        self.assertEqual(payload["mode"], "fast")

    def test_no_file_is_written_without_out(self):
        out = io.StringIO()
        with mock.patch.object(scrape, "scrape_course", side_effect=good_result), \
                contextlib.redirect_stdout(out):
            code = scrape.main(["--course", "woollahra", "--days", "1"])
        self.assertEqual(code, 0)
        self.assertNotIn("wrote", out.getvalue())

    def test_write_supabase_validates_first_and_never_writes_an_invalid_payload(self):
        def side_effect(course, days, today=None):
            result = good_result(course, days)
            result["slots"][0]["booking_url"] = "https://woollahra.miclub.com.au/x"
            result["slots"][0]["time"] = "07:00"
            return result

        # A payload the validator rejects must stop before the writer is even
        # imported, so a broken scrape can never reach Supabase.
        broken = {
            "contract_version": "0.0.1", "generated_at": "2026-09-18T07:00:00+10:00",
            "mode": "full", "days": 1, "courses": [], "slots": [], "course_days": [],
        }
        with mock.patch.object(scrape, "payload_from_results", return_value=broken), \
                mock.patch.object(scrape, "scrape_course", side_effect=side_effect), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
            code = scrape.main(["--course", "woollahra", "--days", "1", "--write", "supabase"])
        self.assertEqual(code, 1)
        self.assertIn("contract violation", err.getvalue())


# ==========================================================================
# A1 verification (tester)
#
# Every test below this line was also run against the pre-ticket scrape.py.
# That file fetched with its own requests + retry loop, counted failures per
# COURSE, set an error only when every day failed, had no payload assembly and
# no Supabase hand-off, and had a main() that took no arguments and let one bad
# course take down the whole run. Each test here fails there and passes now.
# ==========================================================================

class HttpPolicyTests(unittest.TestCase):
    """Clause 8: every request goes through track A4's fetcher, and this file
    keeps no HTTP policy of its own — no user agent, no timeout, no retries,
    no sleep it invented itself."""

    def test_scrape_py_holds_no_http_policy_of_its_own(self):
        self.assertIs(scrape.fetch, fetcher.fetch)
        self.assertIs(scrape.polite_sleep, fetcher.polite_sleep)
        for gone in ("USER_AGENT", "TIMEOUT", "SLEEP_BETWEEN_REQUESTS"):
            self.assertFalse(hasattr(scrape, gone),
                             f"{gone} is HTTP policy and belongs in fetcher.py")
        source = Path(inspect.getsourcefile(scrape)).read_text()
        self.assertNotIn("import requests", source, "scrape.py must not reach the network itself")
        self.assertNotIn("for attempt in", source, "retrying is the fetcher's job, not this file's")

    def test_every_reached_day_pays_that_hosts_courtesy_sleep(self):
        slept = []
        calls = Sequence([ok(TWO_SLOTS)] * 3)
        with mock.patch.object(scrape, "fetch", calls), \
                mock.patch.object(scrape, "polite_sleep", lambda host: slept.append(host)), \
                contextlib.redirect_stdout(io.StringIO()):
            scrape.scrape_course(WOOLLAHRA, 3)
        self.assertEqual(len(calls.urls), 3, "one request per requested day")
        self.assertEqual(slept, ["woollahra.miclub.com.au"] * 3,
                         "courtesy is per host and comes from the fetcher, not a local sleep")

    def test_the_fetchers_own_reason_is_what_the_failed_day_carries(self):
        """A timeout, a 500 and a redirect to a login page must not all read
        the same: the stale-data banner is derived from these strings."""
        with mock.patch.object(scrape, "fetch", Sequence([fail("http 503 (3 attempts)"), fail(None), ok(TWO_SLOTS)])), \
                mock.patch.object(scrape, "polite_sleep", lambda *a: None), \
                contextlib.redirect_stdout(io.StringIO()):
            result = scrape.scrape_course(WOOLLAHRA, 3)

        days = result["days"]
        self.assertEqual(days[0]["error"], "http 503 (3 attempts)", "the reason is passed through, not flattened")
        self.assertTrue(days[1]["error"], "a failed day always names a reason, even when the fetcher gave none")
        self.assertIsNone(days[2]["error"])
        self.assertIn("http 503 (3 attempts)", result["error"])


def all_days_failed_result(course, days, reason="http 500"):
    """A course that reported for itself and had nothing to report — every day
    failed, but scrape_course returned normally rather than raising."""
    records = [scrape.day_record(d, False, error=reason) for d in scrape.requested_dates(days)]
    return {
        "slug": course["slug"], "name": course["name"], "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"), "par": course.get("par"), "notes": course.get("notes", ""),
        "host": scrape.course_host(course), "error": scrape._course_error(records, days),
        "days": records, "slots": [],
    }


class RunOutcomeTests(unittest.TestCase):
    """Clause 3: what a run's exit code means, and what a failed course leaves
    behind in the payload."""

    def run_main(self, argv, side_effect):
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "payload.json"
            with mock.patch.object(scrape, "scrape_course", side_effect=side_effect), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = scrape.main(list(argv) + ["--out", str(out_path)])
            payload = json.loads(out_path.read_text()) if out_path.exists() else None
        return code, payload, out.getvalue(), err.getvalue()

    def test_a_course_that_fails_every_day_without_raising_still_fails_the_run(self):
        code, payload, _, err = self.run_main(
            ["--course", "woollahra", "--days", "3"],
            lambda course, days, today=None: all_days_failed_result(course, days, "http 500"),
        )
        self.assertEqual(code, 1, "no course was reached on any day")
        self.assertIn("every course failed", err)
        rows = payload["course_days"]
        self.assertEqual(len(rows), 3, "a day we could not reach still gets a row")
        self.assertTrue(all(not r["ok"] for r in rows))
        self.assertTrue(all(r["error"] == "http 500" for r in rows))
        self.assertTrue(all(r["last_success_at"] is None for r in rows))

    def test_one_reached_day_anywhere_is_enough_for_a_zero_exit(self):
        def side_effect(course, days, today=None):
            if course["slug"] == "woollahra":
                return all_days_failed_result(course, days, "connection timed out")
            return good_result(course, days)

        code, payload, _, _ = self.run_main(
            ["--course", "woollahra", "--course", "eastlake", "--days", "2"], side_effect)

        self.assertEqual(code, 0, "fourteen good courses are not a failed run")
        by_slug = {}
        for row in payload["course_days"]:
            by_slug.setdefault(row["course_slug"], []).append(row)
        self.assertEqual([r["ok"] for r in by_slug["woollahra"]], [False, False])
        self.assertEqual([r["ok"] for r in by_slug["eastlake"]], [True, True])
        self.assertEqual({s["course_slug"] for s in payload["slots"]}, {"eastlake"})

    def test_a_raising_course_is_failed_on_every_requested_day_with_its_reason(self):
        def side_effect(course, days, today=None):
            if course["slug"] == "woollahra":
                raise RuntimeError("kaboom")
            return good_result(course, days)

        code, payload, _, _ = self.run_main(
            ["--course", "woollahra", "--course", "eastlake", "--days", "5"], side_effect)

        self.assertEqual(code, 0)
        dead = [r for r in payload["course_days"] if r["course_slug"] == "woollahra"]
        self.assertEqual([r["tee_date"] for r in dead], scrape.requested_dates(5),
                         "a course that blew up is still accounted for on all five days")
        self.assertTrue(all(not r["ok"] for r in dead))
        self.assertTrue(all("RuntimeError: kaboom" in r["error"] for r in dead))
        self.assertTrue(all(r["last_success_at"] is None for r in dead))
        alive = [r for r in payload["course_days"] if r["course_slug"] == "eastlake"]
        self.assertEqual(len(alive), 5)
        self.assertTrue(all(r["ok"] for r in alive))


class DayWindowTests(unittest.TestCase):
    def test_a_day_count_the_schema_cannot_hold_is_refused_before_any_scraping(self):
        for bad in ("0", "15", "-1"):
            with self.subTest(days=bad):
                reached = []
                with mock.patch.object(scrape, "scrape_course", side_effect=lambda c, d, today=None: reached.append(c)), \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        scrape.main(["--course", "woollahra", "--days", bad])
                self.assertEqual(reached, [], "no club is contacted for a window that could not validate")

    def test_both_edges_of_the_window_are_allowed(self):
        for good in ("1", "14"):
            with self.subTest(days=good):
                with mock.patch.object(scrape, "scrape_course", side_effect=good_result), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(scrape.main(["--course", "woollahra", "--days", good]), 0)


class FakeWriteResult:
    def __init__(self, errors=None):
        self.run_id = 7
        self.slots_upserted = 3
        self.slots_closed = 1
        self.course_days_written = 2
        self.errors = errors or []


class FakeMissingCredentials(RuntimeError):
    pass


def fake_writer_module(write_result=None, from_env_raises=None):
    """Stands in for track A2's scraper/supabase_writer.py."""
    calls = {"from_env": [], "written": []}

    class FakeWriter:
        @classmethod
        def from_env(cls, *, dry_run=False):
            calls["from_env"].append(dry_run)
            if from_env_raises is not None:
                raise from_env_raises
            return cls()

        def write(self, payload):
            calls["written"].append(payload)
            return write_result or FakeWriteResult()

    module = types.ModuleType("supabase_writer")
    module.SupabaseWriter = FakeWriter
    module.MissingCredentials = FakeMissingCredentials
    return module, calls


class SupabaseHandoffTests(unittest.TestCase):
    """Clauses 6 and 9: validation gates the write, and the writer is A2's —
    this file only hands it a payload and reports what came back."""

    def run_write(self, argv, module, payload_override=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(sys.modules, {"supabase_writer": module}))
            stack.enter_context(mock.patch.object(scrape, "scrape_course", side_effect=good_result))
            if payload_override is not None:
                stack.enter_context(mock.patch.object(scrape, "payload_from_results", return_value=payload_override))
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            code = scrape.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_write_validates_unasked_and_hands_over_the_payload_it_validated(self):
        module, calls = fake_writer_module()
        code, out, _ = self.run_write(
            ["--course", "woollahra", "--days", "1", "--write", "supabase", "--dry-run"], module)

        self.assertEqual(code, 0)
        self.assertIn("CONTRACT OK", out, "--write validates without being asked to")
        self.assertEqual(calls["from_env"], [True], "--dry-run has to reach the writer")
        self.assertEqual(len(calls["written"]), 1)
        written = calls["written"][0]
        self.assertEqual(validate(written), [], "what reached the writer is the payload that was validated")
        self.assertTrue(written["slots"])
        self.assertIn("supabase (dry run)", out, "a dry run says so rather than looking like a write")
        self.assertIn("3 slot(s) upserted", out, "what the writer reported is what the run prints")

    def test_an_invalid_payload_never_reaches_the_writer(self):
        broken = {
            "contract_version": "0.0.1", "generated_at": "2026-09-18T07:00:00+10:00",
            "mode": "full", "days": 1, "courses": [], "slots": [], "course_days": [],
        }
        module, calls = fake_writer_module()
        code, _, err = self.run_write(
            ["--course", "woollahra", "--days", "1", "--write", "supabase"], module, payload_override=broken)

        self.assertEqual(code, 1)
        self.assertIn("contract violation", err)
        self.assertEqual(calls["from_env"], [], "a rejected payload does not even open a connection")
        self.assertEqual(calls["written"], [])

    def test_missing_credentials_reads_as_a_sentence_not_a_traceback(self):
        module, calls = fake_writer_module(
            from_env_raises=FakeMissingCredentials("SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY not set"))
        code, _, err = self.run_write(
            ["--course", "woollahra", "--days", "1", "--write", "supabase"], module)

        self.assertEqual(code, 1)
        self.assertIn("supabase credentials missing", err)
        self.assertIn("SUPABASE_URL", err)
        self.assertNotIn("Traceback", err)
        self.assertEqual(calls["written"], [])

    def test_a_write_error_fails_the_run_and_says_what_it_was(self):
        module, calls = fake_writer_module(write_result=FakeWriteResult(errors=["slots upsert: 409 conflict"]))
        code, _, err = self.run_write(
            ["--course", "woollahra", "--days", "1", "--write", "supabase"], module)

        self.assertEqual(code, 1, "a partial write is not a successful run")
        self.assertIn("409 conflict", err)
        self.assertEqual(len(calls["written"]), 1)


if __name__ == "__main__":
    unittest.main()
