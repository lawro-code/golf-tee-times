"""A4 acceptance tests: the promises the HTTP layer makes, checked against the
behaviour that shipped before it.

These are the tester's tests, written against the ticket rather than against
the implementation. The bar every one of them clears: it fails against the
pre-A4 code and passes against the code as it stands. The pre-A4 code is
`scraper/scrape.py::fetch` at git HEAD — two fixed attempts, a flat two-second
sleep, no per-host throttle, and `None` returned for a timeout, a 500, a 404
and a login page alike. A test that would also have passed against that is
testing nothing and is not in this file; two candidates were cut for exactly
that reason (see the gate notes).

Nothing here touches the network. Every test injects a fake session and fakes
the clock, so the file runs in milliseconds — which is itself the evidence
that no real request was made and no real backoff was slept through.

Bias is towards the failure paths. A fetch layer is only interesting on the
day a club is broken.
"""

import os
import unittest
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

import requests

import fetcher


TIMESHEET = (
    "https://woollahra.miclub.com.au/guests/bookings/ViewPublicTimesheet.msp"
    "?bookingResourceId=3000000&feeGroupId=3050666&selectedDate=2026-09-18"
)
OTHER_CLUB = (
    "https://bexley.miclub.com.au/guests/bookings/ViewPublicTimesheet.msp"
    "?bookingResourceId=3000000&feeGroupId=3011111&selectedDate=2026-09-18"
)
PAGE = "<html><body><div class='row-time'><h3>6:16am</h3></div></body></html>"

HTML_HEADERS = {"Content-Type": "text/html; charset=utf-8"}


class Reply:
    """Something with requests.Response's shape, as far as fetch() looks."""

    def __init__(self, status_code=200, text=PAGE, url=None, headers=None):
        self.status_code = status_code
        self.text = text
        self.url = url
        self.headers = dict(HTML_HEADERS if headers is None else headers)


class Club:
    """A scripted club. Entries are replies or exceptions to raise; the last
    entry repeats, so "down all afternoon" is one entry, not one per retry."""

    def __init__(self, *script, clock=None):
        self.script = list(script) or [Reply()]
        self.clock = clock
        self.calls = []
        self.asked_at = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if self.clock is not None:
            self.asked_at.append(self.clock.t)
        item = self.script[min(len(self.calls) - 1, len(self.script) - 1)]
        if isinstance(item, BaseException):
            raise item
        if item.url is None:
            item.url = url
        return item

    @property
    def gaps(self):
        return [round(b - a, 6) for a, b in zip(self.asked_at, self.asked_at[1:])]


class Clock:
    """Time only moves when something sleeps."""

    def __init__(self, start=5000.0):
        self.t = start
        self.sleeps = []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(round(seconds, 6))
        self.t += max(0.0, seconds)


class FetcherCase(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self._patch(fetcher, "_now", self.clock.now)
        self._patch(fetcher, "_sleep", self.clock.sleep)
        fetcher.reset_throttle()
        self.addCleanup(fetcher.reset_throttle)

    def _patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def club(self, *script):
        return Club(*script, clock=self.clock)


# --------------------------------------------------------------------------
# The reason this module exists: a failure that says which failure it was.
# --------------------------------------------------------------------------

class FailuresAreDistinguishableTests(FetcherCase):
    """Pre-A4 every one of these was `None`. `course_day_scrapes.error` held
    nothing, `course_freshness` aggregated nothing, and the stale-data banner
    could only ever say "something went wrong"."""

    def scenarios(self):
        return {
            "timeout": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(requests.exceptions.Timeout("read timed out")),
                retries=0),
            "server error": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(Reply(500, text="boom")), retries=0),
            "not found": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(Reply(404, text="gone")), retries=0),
            "forbidden": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(Reply(403, text="no")), retries=0),
            "rate limited": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(Reply(429, text="slow down", headers={})),
                retries=0),
            "login page": lambda: fetcher.fetch(
                TIMESHEET, retries=0, session=self.club(Reply(
                    200, text="<html><form id='login'></form></html>",
                    url="https://woollahra.miclub.com.au/security/login.msp"))),
            "empty body": lambda: fetcher.fetch(
                TIMESHEET, session=self.club(Reply(200, text="")), retries=0),
            "maintenance json": lambda: fetcher.fetch(
                TIMESHEET, retries=0, session=self.club(Reply(
                    200, text='{"maintenance":true}',
                    headers={"Content-Type": "application/json"}))),
            "connection refused": lambda: fetcher.fetch(
                TIMESHEET, retries=0, session=self.club(
                    requests.exceptions.ConnectionError("[Errno 61] Connection refused"))),
        }

    def test_nine_ways_to_fail_produce_nine_different_reasons(self):
        seen = {}
        for name, run in self.scenarios().items():
            fetcher.reset_throttle()
            result = run()
            self.assertFalse(result.ok, f"{name} is not a success")
            self.assertIsNotNone(result.error, f"{name} must say what happened")
            seen[name] = result.error

        self.assertEqual(
            len(set(seen.values())), len(seen),
            f"two failures are indistinguishable: {seen}",
        )

    def test_every_failure_reason_is_fit_for_the_stale_data_banner(self):
        for name, run in self.scenarios().items():
            with self.subTest(scenario=name):
                fetcher.reset_throttle()
                error = run().error
                self.assertTrue(error and error.strip(), "a blank reason is no reason")
                self.assertEqual(error, error.strip())
                self.assertNotIn("\n", error)
                self.assertLessEqual(len(error), 80, f"too long for a banner: {error!r}")
                self.assertNotIn("Traceback", error)
                self.assertNotIn("object at 0x", error, "no reprs leaking to a golfer")
                self.assertNotIn("None", error)

    def test_ok_and_error_are_exact_opposites_in_every_scenario(self):
        for name, run in self.scenarios().items():
            with self.subTest(scenario=name):
                fetcher.reset_throttle()
                result = run()
                self.assertFalse(result.ok)
                self.assertIsNotNone(result.error)
                self.assertIsNone(result.html, "a failed fetch hands back no html")

        fetcher.reset_throttle()
        good = fetcher.fetch(TIMESHEET, session=self.club(Reply(200, text=PAGE)))
        self.assertTrue(good.ok)
        self.assertIsNone(good.error, "error is None exactly when ok is True")
        self.assertEqual(good.html, PAGE)


# --------------------------------------------------------------------------
# Retries: more than one, exponential, jittered, capped.
# --------------------------------------------------------------------------

class RetryBudgetTests(FetcherCase):
    def test_a_club_that_recovers_on_the_third_attempt_is_still_a_success(self):
        """Pre-A4 stopped at two attempts, so this club was recorded as down."""
        club = self.club(
            requests.exceptions.Timeout("read timed out"),
            requests.exceptions.ConnectionError("[Errno 54] Connection reset by peer"),
            Reply(200, text=PAGE),
        )
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.attempts, 3)
        self.assertEqual(len(club.calls), 3)
        self.assertEqual(result.html, PAGE)
        self.assertIsNone(result.error)

    def test_backoff_is_exponential_and_stops_growing_at_the_cap(self):
        club = self.club(Reply(503, text="back soon"))
        fetcher.fetch(TIMESHEET, session=club, retries=6)
        gaps = club.gaps
        self.assertEqual(len(gaps), 6, "retries means retries, not attempts")

        # Doubling, while doubling is still under the cap. Jitter is 25%, so
        # each of these is strictly clear of the one before it.
        for earlier, later in zip(gaps, gaps[1:4]):
            self.assertGreater(later, earlier, "flat sleeps are not exponential")

        # Past the cap it plateaus rather than doubling towards a minute. It
        # does not stay ordered up here, and should not: that is the jitter.
        ceiling = fetcher.BACKOFF_CAP * (1 + fetcher.BACKOFF_JITTER) + 1e-6
        for gap in gaps:
            self.assertGreaterEqual(gap, fetcher.MIN_HOST_INTERVAL)
            self.assertLessEqual(gap, ceiling, "an uncapped backoff hangs the run")
        for gap in gaps[-2:]:
            self.assertGreaterEqual(gap, fetcher.BACKOFF_CAP)

    def test_fifteen_clubs_failing_together_do_not_retry_in_lockstep(self):
        """Jitter is the whole point: a synchronised stampede is what gets a
        scraper blocked."""
        first_waits = set()
        for _ in range(8):
            fetcher.reset_throttle()
            club = self.club(Reply(503, text="back soon"))
            fetcher.fetch(TIMESHEET, session=club, retries=1)
            first_waits.add(club.gaps[0])
        self.assertGreater(
            len(first_waits), 1, "no jitter: every club's retry lands on the same tick"
        )
        ceiling = fetcher.BACKOFF_BASE * (1 + fetcher.BACKOFF_JITTER) + 1e-6
        for wait in first_waits:
            self.assertGreaterEqual(wait, fetcher.BACKOFF_BASE)
            self.assertLessEqual(wait, ceiling)

    def test_the_whole_ordeal_is_timed_including_the_waiting(self):
        club = self.club(Reply(500, text="boom"))
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.attempts, 3, "the full budget was spent on this club")
        slept_ms = int(round(sum(self.clock.sleeps) * 1000))
        self.assertGreater(slept_ms, 0, "three attempts cannot have taken no time")
        self.assertGreaterEqual(result.elapsed_ms, slept_ms)
        self.assertEqual(result.status, 500, "the last status seen is reported")


# --------------------------------------------------------------------------
# Courtesy survives the failure path.
# --------------------------------------------------------------------------

class ThrottleOnFailureTests(FetcherCase):
    def test_a_club_that_timed_out_is_still_owed_a_second_before_we_ask_again(self):
        """The floor is about what the club's server sees, and it saw the
        request that timed out. Pre-A4 had no per-host floor at all."""
        fetcher.fetch(TIMESHEET, session=self.club(requests.exceptions.Timeout("x")), retries=0)
        self.clock.sleeps.clear()

        fetcher.fetch(TIMESHEET, session=self.club(Reply(200, text=PAGE)), retries=0)
        self.assertEqual(self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL])

    def test_a_club_having_a_bad_day_never_delays_the_other_fourteen(self):
        broken = self.club(Reply(500, text="boom"))
        fetcher.fetch(TIMESHEET, session=broken, retries=1)
        backoff_sleeps = list(self.clock.sleeps)
        self.assertTrue(backoff_sleeps, "a 5xx is retried, so something was slept")

        self.clock.sleeps.clear()
        healthy = self.club(Reply(200, text=PAGE))
        result = fetcher.fetch(OTHER_CLUB, session=healthy, retries=0)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(self.clock.sleeps, [], "a different club is a different server")

        self.clock.sleeps.clear()
        fetcher.fetch(TIMESHEET, session=self.club(Reply(200, text=PAGE)), retries=0)
        self.assertEqual(
            self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL],
            "the failing club is still owed its second",
        )


# --------------------------------------------------------------------------
# 429: honour a small ask, refuse a long one.
# --------------------------------------------------------------------------

class RetryAfterTests(FetcherCase):
    @staticmethod
    def http_date(offset_seconds):
        return format_datetime(
            datetime.now(timezone.utc) + timedelta(seconds=offset_seconds), usegmt=True
        )

    def test_a_retry_after_written_as_an_http_date_is_honoured(self):
        """Both spellings are legal and MiClub's front end is not ours to choose."""
        club = self.club(
            Reply(429, text="slow down", headers={"Retry-After": self.http_date(4)}),
            Reply(200, text=PAGE),
        )
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(len(club.calls), 2)
        self.assertEqual(len(self.clock.sleeps), 1)
        slept = self.clock.sleeps[0]
        self.assertGreaterEqual(slept, 3.0)
        self.assertLessEqual(slept, fetcher.RETRY_AFTER_CAP)

    def test_a_retry_after_date_ten_minutes_out_fails_fast_instead_of_hanging(self):
        club = self.club(Reply(429, text="go away", headers={"Retry-After": self.http_date(600)}))
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "rate limited (429)")
        self.assertEqual(result.status, 429)
        self.assertEqual(len(club.calls), 1, "ten minutes is a no, not a wait")
        self.assertEqual(self.clock.sleeps, [])

    def test_a_retry_after_already_in_the_past_never_becomes_a_negative_sleep(self):
        club = self.club(
            Reply(429, text="slow down", headers={"Retry-After": self.http_date(-120)}),
            Reply(200, text=PAGE),
        )
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertTrue(result.ok, result.error)
        for slept in self.clock.sleeps:
            self.assertGreaterEqual(slept, 0.0, "a negative sleep is a crash or a no-op")
        self.assertLessEqual(sum(self.clock.sleeps), fetcher.RETRY_AFTER_CAP)

    def test_retry_after_zero_retries_straight_away(self):
        club = self.club(
            Reply(429, text="slow down", headers={"Retry-After": "0"}),
            Reply(200, text=PAGE),
        )
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertTrue(result.ok, result.error)
        self.assertEqual(result.attempts, 2)
        self.assertEqual(self.clock.sleeps[0], 0.0, "nothing was asked for, so nothing is owed")
        # The per-host floor still applies on top — a club saying "now" does
        # not license two requests in the same instant.
        self.assertLessEqual(sum(self.clock.sleeps), fetcher.MIN_HOST_INTERVAL + 1e-6)


# --------------------------------------------------------------------------
# A 200 is not automatically a success.
# --------------------------------------------------------------------------

class SuspiciousTwoHundredTests(FetcherCase):
    def test_content_type_decides_whether_a_200_is_a_timesheet(self):
        accepted = ("text/html", "text/html; charset=utf-8", "application/xhtml+xml")
        for content_type in accepted:
            with self.subTest(accept=content_type):
                fetcher.reset_throttle()
                result = fetcher.fetch(
                    TIMESHEET, retries=0,
                    session=self.club(Reply(200, text=PAGE,
                                            headers={"Content-Type": content_type})))
                self.assertTrue(result.ok, result.error)
                self.assertEqual(result.html, PAGE)

        rejected = {
            "application/json": '{"maintenance":true}',
            "text/plain": "Site down for maintenance",
            "application/pdf": "%PDF-1.4 ...",
        }
        for content_type, body in rejected.items():
            with self.subTest(reject=content_type):
                fetcher.reset_throttle()
                club = self.club(Reply(200, text=body,
                                       headers={"Content-Type": content_type}))
                result = fetcher.fetch(TIMESHEET, session=club, retries=2)
                self.assertFalse(result.ok, f"{content_type} is not a timesheet")
                self.assertIn(content_type, result.error)
                self.assertIsNone(result.html)
                self.assertEqual(len(club.calls), 1, "asking again gets the same page")

    def test_a_200_carrying_no_markup_and_no_content_type_is_a_failure(self):
        club = self.club(Reply(200, text="Service temporarily unavailable", headers={}))
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertFalse(result.ok)
        self.assertIn("non-html", result.error)
        self.assertEqual(len(club.calls), 1)

    def test_a_club_that_bounced_us_to_login_is_a_failure_not_an_empty_day(self):
        """CONTRACT.md section 5: a club with nothing free and a club we never
        reached must not look the same. Pre-A4 handed the login page's HTML
        back to the parser, which found no rows, which read as 'no tee times'."""
        club = self.club(Reply(
            200,
            text="<html><body><form id='login'>Members login</form></body></html>",
            url="https://woollahra.miclub.com.au/security/login.msp?next=/guests",
        ))
        result = fetcher.fetch(TIMESHEET, session=club, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "redirected to login")
        self.assertIsNone(result.html, "the login page must never reach the parser")
        self.assertEqual(result.status, 200)


# --------------------------------------------------------------------------
# Nothing a club can do is allowed to raise.
# --------------------------------------------------------------------------

class NeverRaisesTests(FetcherCase):
    def test_a_bare_oserror_is_caught_like_any_other_broken_socket(self):
        """requests does not wrap everything. Pre-A4 caught RequestException
        only, so a bare OSError killed the run and took the other clubs' days
        with it."""
        club = self.club(OSError("[Errno 54] Connection reset by peer"))
        result = fetcher.fetch(TIMESHEET, session=club, retries=1)
        self.assertFalse(result.ok)
        self.assertTrue(result.error)
        self.assertIsNone(result.html)

    def test_a_reply_with_no_status_code_is_a_failure_not_a_crash(self):
        class Nonsense:
            headers = {}
            text = PAGE
            url = TIMESHEET

        result = fetcher.fetch(TIMESHEET, session=self.club(Nonsense()), retries=0)
        self.assertFalse(result.ok)
        self.assertIn("malformed", result.error)
        self.assertIsNone(result.status)

    def test_an_invalid_url_fails_once_and_says_so(self):
        club = self.club(requests.exceptions.MissingSchema("No scheme supplied"))
        result = fetcher.fetch("woollahra.miclub.com.au/timesheet", session=club, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(len(club.calls), 1, "a bad url is bad the second time too")
        self.assertTrue(result.error)


# --------------------------------------------------------------------------
# Debug capture: gated, useful when on, never fatal.
# --------------------------------------------------------------------------

class DebugCaptureTests(FetcherCase):
    def test_the_page_is_kept_when_asked_for_and_a_bad_path_never_costs_a_scrape(self):
        with TemporaryDirectory() as tmp:
            good = Path(tmp) / "debug"
            self._patch(fetcher, "DEBUG_DIR", good)
            with mock.patch.dict(os.environ, {fetcher.DEBUG_ENV: "1"}):
                result = fetcher.fetch(TIMESHEET, session=self.club(Reply(200, text=PAGE)))
            self.assertTrue(result.ok, result.error)
            kept = sorted(good.glob("*.html"))
            self.assertEqual(len(kept), 1)
            self.assertEqual(kept[0].read_text(), PAGE)

            # A file where the directory should be: mkdir raises, and the
            # scrape carries on regardless.
            blocked_parent = Path(tmp) / "not-a-dir"
            blocked_parent.write_text("i am a file")
            self._patch(fetcher, "DEBUG_DIR", blocked_parent / "debug")
            fetcher.reset_throttle()
            with mock.patch.dict(os.environ, {fetcher.DEBUG_ENV: "1"}):
                result = fetcher.fetch(TIMESHEET, session=self.club(Reply(200, text=PAGE)))
            self.assertTrue(result.ok, "a full disk is not a reason to lose a club")

    def test_a_failed_fetch_leaves_no_debug_page_to_mislead_anyone(self):
        with TemporaryDirectory() as tmp:
            debug = Path(tmp) / "debug"
            self._patch(fetcher, "DEBUG_DIR", debug)
            with mock.patch.dict(os.environ, {fetcher.DEBUG_ENV: "1"}):
                result = fetcher.fetch(
                    TIMESHEET, session=self.club(Reply(500, text="boom")), retries=1)
            self.assertFalse(result.ok)
            self.assertEqual(result.error, "http 500")
            self.assertFalse(
                debug.exists() and list(debug.glob("*.html")),
                "there is no page to keep, so keeping one would be a lie",
            )


if __name__ == "__main__":
    unittest.main()
