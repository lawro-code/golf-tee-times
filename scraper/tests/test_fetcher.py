"""What the HTTP layer promises: retries worth making, honest failures, and
per-host courtesy.

Not one of these tests touches the network. Every one passes a fake session in
through the `session` kwarg and fakes the clock, which is why the whole file
runs in milliseconds — a suite that sat there for ten seconds would be telling
you it had made real requests and slept through real backoff.

The failure strings asserted here are not decoration. They go straight into
`course_day_scrapes.error`, `public.course_freshness` aggregates them, and the
stale-data banner a golfer actually reads is derived from them. The bug this
module exists to kill is the old fetch() returning None for everything, so a
timeout, a 500, a 404 and a redirect to a login page were indistinguishable by
the time anyone looked.
"""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import requests

import fetcher


# --------------------------------------------------------------------------
# Fakes: a session with requests.Session's `.get()` shape, and a clock that
# only moves when something sleeps.
# --------------------------------------------------------------------------

TIMESHEET = (
    "https://woollahra.miclub.com.au/guests/bookings/ViewPublicTimesheet.msp"
    "?bookingResourceId=3000000&feeGroupId=3050666&selectedDate=2026-09-18"
)
OTHER_CLUB = (
    "https://moorepark.miclub.com.au/guests/bookings/ViewPublicTimesheet.msp"
    "?bookingResourceId=3000000&feeGroupId=3011111&selectedDate=2026-09-18"
)
HTML = "<html><body><div class='row-time'><h3>6:16am</h3></div></body></html>"


class FakeResponse:
    def __init__(self, status_code=200, text=HTML, url=None, headers=None):
        self.status_code = status_code
        self.text = text
        self.url = url
        self.headers = dict(headers) if headers else {"Content-Type": "text/html; charset=utf-8"}


class FakeSession:
    """Hands back scripted responses in order; an Exception in the script is
    raised instead of returned. The last entry repeats, so "a club that is
    down" is one entry rather than one per retry.
    """

    def __init__(self, *scripted, **kwargs):
        self.scripted = list(scripted) or [FakeResponse()]
        self.clock = kwargs.pop("clock", None)
        if kwargs:
            raise TypeError(f"unexpected kwargs: {sorted(kwargs)}")
        self.calls = []
        self.at = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if self.clock is not None:
            self.at.append(self.clock.now_value)
        item = self.scripted[min(len(self.calls) - 1, len(self.scripted) - 1)]
        if isinstance(item, BaseException):
            raise item
        if item.url is None:
            item.url = url
        return item

    @property
    def gaps(self):
        """Seconds between consecutive attempts, by the fake clock."""
        return [round(b - a, 6) for a, b in zip(self.at, self.at[1:])]


class FakeClock:
    def __init__(self, start=1000.0):
        self.now_value = start
        self.sleeps = []

    def now(self):
        return self.now_value

    def sleep(self, seconds):
        self.sleeps.append(round(seconds, 6))
        self.now_value += max(0.0, seconds)

    @property
    def total_slept(self):
        return sum(self.sleeps)


class FetcherTestCase(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.patch(fetcher, "_now", self.clock.now)
        self.patch(fetcher, "_sleep", self.clock.sleep)
        fetcher.reset_throttle()
        self.addCleanup(fetcher.reset_throttle)

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def session(self, *scripted):
        return FakeSession(*scripted, clock=self.clock)


# --------------------------------------------------------------------------
# Retry only what can change
# --------------------------------------------------------------------------

class RetryPolicyTests(FetcherTestCase):
    def test_a_500_is_retried_and_a_404_is_not(self):
        """Asserted by call count, because that is what the club's server sees."""
        down = self.session(FakeResponse(500, text="server error"))
        result = fetcher.fetch(TIMESHEET, session=down, retries=2)
        self.assertEqual(len(down.calls), 3, "a 5xx is worth asking again")
        self.assertEqual(result.attempts, 3)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "http 500")
        self.assertEqual(result.status, 500)
        self.assertIsNone(result.html)

        gone = self.session(FakeResponse(404, text="not found"))
        result = fetcher.fetch(TIMESHEET, session=gone, retries=2)
        self.assertEqual(len(gone.calls), 1, "a 404 will say the same thing next time")
        self.assertEqual(result.attempts, 1)
        self.assertEqual(result.error, "http 404")
        self.assertEqual(result.status, 404)

    def test_no_4xx_is_retried(self):
        for status in (400, 401, 403, 410, 451):
            with self.subTest(status=status):
                fetcher.reset_throttle()
                session = self.session(FakeResponse(status, text="no"))
                result = fetcher.fetch(TIMESHEET, session=session, retries=2)
                self.assertEqual(len(session.calls), 1)
                self.assertEqual(result.error, f"http {status}")

    def test_every_5xx_is_retried(self):
        for status in (500, 502, 503, 504):
            with self.subTest(status=status):
                fetcher.reset_throttle()
                session = self.session(FakeResponse(status, text="no"))
                result = fetcher.fetch(TIMESHEET, session=session, retries=2)
                self.assertEqual(len(session.calls), 3)
                self.assertEqual(result.error, f"http {status}")

    def test_a_retry_that_works_is_a_success(self):
        session = self.session(FakeResponse(503, text="back soon"), FakeResponse(200, text=HTML))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertTrue(result.ok)
        self.assertEqual(result.html, HTML)
        self.assertIsNone(result.error)
        self.assertEqual(result.attempts, 2)
        self.assertEqual(len(session.calls), 2)

    def test_retries_zero_means_one_attempt(self):
        session = self.session(FakeResponse(500, text="no"))
        result = fetcher.fetch(TIMESHEET, session=session, retries=0)
        self.assertEqual(len(session.calls), 1)
        self.assertEqual(result.attempts, 1)

    def test_backoff_grows_and_never_dips_under_the_per_host_floor(self):
        session = self.session(FakeResponse(500, text="no"))
        fetcher.fetch(TIMESHEET, session=session, retries=3)
        gaps = session.gaps
        self.assertEqual(len(gaps), 3)
        for gap in gaps:
            self.assertGreaterEqual(gap, fetcher.MIN_HOST_INTERVAL)
        self.assertEqual(gaps, sorted(gaps), "backoff must not go backwards")
        self.assertGreater(gaps[-1], gaps[0], "exponential, not flat")
        # Jitter: never the same number twice in a row by construction, and
        # always inside the declared ceiling.
        for attempt, gap in enumerate(gaps, start=1):
            ceiling = min(fetcher.BACKOFF_CAP, fetcher.BACKOFF_BASE * (2 ** (attempt - 1)))
            self.assertLessEqual(gap, ceiling * (1 + fetcher.BACKOFF_JITTER) + 0.000001)


# --------------------------------------------------------------------------
# Transport failures say what happened
# --------------------------------------------------------------------------

class TransportFailureTests(FetcherTestCase):
    def test_a_timeout_says_how_long_it_waited_and_is_retried(self):
        session = self.session(requests.exceptions.Timeout("read timed out"))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "timeout after 25s")
        self.assertGreater(result.attempts, 1)
        self.assertEqual(result.attempts, 3)
        self.assertEqual(len(session.calls), 3)
        self.assertIsNone(result.status)
        self.assertIsNone(result.html)

    def test_the_timeout_message_names_the_timeout_actually_used(self):
        session = self.session(requests.exceptions.ConnectTimeout("nope"))
        result = fetcher.fetch(TIMESHEET, session=session, timeout=5, retries=0)
        self.assertEqual(result.error, "timeout after 5s")
        self.assertEqual(session.calls[0][1]["timeout"], 5)

    def test_a_connection_error_names_the_reason_and_is_retried(self):
        session = self.session(requests.exceptions.ConnectionError("[Errno 61] Connection refused"))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 3)
        self.assertTrue(result.error.startswith("connection error: "), result.error)
        self.assertIn("refused", result.error)
        self.assertLess(len(result.error), 90, "this string has to fit in a banner")

    def test_a_dns_failure_reads_like_english(self):
        session = self.session(
            requests.exceptions.ConnectionError(
                "HTTPSConnectionPool(host='woollahra.miclub.com.au', port=443): Max retries exceeded "
                "(Caused by NewConnectionError('<urllib3.connection.HTTPSConnection object at 0x10a>: "
                "Failed to resolve 'woollahra.miclub.com.au' ([Errno 8] nodename nor servname provided)'))"
            )
        )
        result = fetcher.fetch(TIMESHEET, session=session, retries=0)
        self.assertEqual(result.error, "connection error: dns lookup failed")

    def test_an_exotic_request_failure_is_not_retried_forever(self):
        session = self.session(requests.exceptions.TooManyRedirects("too many redirects"))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 1)
        self.assertFalse(result.ok)
        self.assertTrue(result.error)

    def test_a_dropped_connection_mid_response_is_retried_and_can_recover(self):
        """ChunkedEncodingError is what requests/urllib3 actually raises when a
        connection resets or the body is cut short partway through a chunked
        or streamed read (an IncompleteRead). It is a sibling of
        ConnectionError, not a subclass of it — same module docstring promise
        ("a dropped connection... is worth asking again about"), so it must
        get the same retry budget a plain ConnectionError gets, and recover
        the same way.
        """
        session = self.session(
            requests.exceptions.ChunkedEncodingError(
                "Connection broken: IncompleteRead(0 bytes read)"
            ),
            FakeResponse(200, text=HTML),
        )
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 2, "worth a second try, same as a ConnectionError")
        self.assertTrue(result.ok)
        self.assertEqual(result.html, HTML)
        self.assertIsNone(result.error)

    def test_a_dropped_connection_that_never_recovers_names_itself_plainly(self):
        session = self.session(
            requests.exceptions.ChunkedEncodingError(
                "Connection broken: IncompleteRead(0 bytes read)"
            )
        )
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 3, "the same budget a ConnectionError gets")
        self.assertFalse(result.ok)
        self.assertTrue(result.error.startswith("connection error: "), result.error)
        self.assertNotIn("ChunkedEncodingError", result.error, "not a bare exception name")


# --------------------------------------------------------------------------
# 429: honour a small Retry-After, otherwise get out of the way
# --------------------------------------------------------------------------

class RateLimitTests(FetcherTestCase):
    def test_a_small_retry_after_is_honoured_once_and_then_it_works(self):
        session = self.session(
            FakeResponse(429, text="slow down", headers={"Retry-After": "2"}),
            FakeResponse(200, text=HTML),
        )
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertTrue(result.ok)
        self.assertEqual(self.clock.sleeps, [2.0], "waited exactly what the club asked for")
        self.assertEqual(result.attempts, 2)

    def test_retry_after_never_waits_longer_than_the_cap_and_stops_retrying(self):
        session = self.session(FakeResponse(429, text="slow down", headers={"Retry-After": "2"}))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(result.error, "rate limited (429)")
        self.assertEqual(result.attempts, 3, "the retry budget still applies")
        self.assertEqual(len(session.calls), 3)
        for slept in self.clock.sleeps:
            self.assertLessEqual(slept, fetcher.RETRY_AFTER_CAP)
        self.assertLessEqual(self.clock.total_slept, fetcher.RETRY_AFTER_CAP * 2)

    def test_a_big_retry_after_fails_fast_rather_than_hanging_the_run(self):
        session = self.session(FakeResponse(429, text="go away", headers={"Retry-After": "600"}))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 1)
        self.assertEqual(result.error, "rate limited (429)")
        self.assertEqual(self.clock.sleeps, [], "ten minutes is not a wait, it is a no")

    def test_429_without_retry_after_does_not_hammer(self):
        session = self.session(FakeResponse(429, text="go away", headers={}))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 1)
        self.assertEqual(result.error, "rate limited (429)")
        self.assertEqual(result.status, 429)

    def test_an_unparseable_retry_after_is_treated_as_absent(self):
        session = self.session(FakeResponse(429, text="?", headers={"Retry-After": "soon"}))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertEqual(len(session.calls), 1)
        self.assertEqual(result.error, "rate limited (429)")


# --------------------------------------------------------------------------
# A 200 is not automatically a success
# --------------------------------------------------------------------------

class SuspiciousSuccessTests(FetcherTestCase):
    def test_a_200_that_landed_on_a_login_page_is_a_failure(self):
        session = self.session(FakeResponse(
            200,
            text="<html><body><form id='login'>Members login</form></body></html>",
            url="https://woollahra.miclub.com.au/security/login.msp?next=/guests/bookings",
        ))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "redirected to login")
        self.assertIsNone(result.html)
        self.assertEqual(result.status, 200)
        self.assertEqual(len(session.calls), 1, "asking again gets the same login page")

    def test_a_200_that_landed_in_the_members_area_is_a_failure(self):
        session = self.session(FakeResponse(
            200,
            text="<html><body>Members only</body></html>",
            url="https://woollahra.miclub.com.au/members/bookings/ViewTimesheet.msp",
        ))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertIn("member", result.error)
        self.assertEqual(len(session.calls), 1)

    def test_an_empty_body_is_a_failure(self):
        session = self.session(FakeResponse(200, text="   \n  "))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertEqual(result.error, "empty response body")
        self.assertEqual(len(session.calls), 1)

    def test_a_non_html_body_is_a_failure(self):
        session = self.session(FakeResponse(
            200, text='{"status":"maintenance"}', headers={"Content-Type": "application/json"},
        ))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertIn("non-html", result.error)
        self.assertIn("application/json", result.error)

    def test_html_without_a_content_type_header_is_still_accepted(self):
        session = self.session(FakeResponse(200, text=HTML, headers={}))
        result = fetcher.fetch(TIMESHEET, session=session, retries=0)
        self.assertTrue(result.ok, result.error)

    def test_a_200_that_bounced_to_the_clubs_own_homepage_is_a_failure(self):
        """The login/member markers are not the only way a bad session gets
        bounced. Five of the fifteen courses front MiClub through their own
        custom domain, and MiClub itself lands a rejected session on the
        club's ordinary public homepage for several failure modes (a timed
        out session, "timesheet unavailable", a login flow MiClub changed)
        that have nothing to do with "login"/"signin"/"sign-in"/"logon"/
        "/member" in the URL. A 200 that lands anywhere other than the
        timesheet it asked for is a failure, not a quiet success.
        """
        session = self.session(FakeResponse(
            200,
            text=(
                "<html><head><title>Woollahra Golf Club</title></head>"
                "<body><nav>Home | Membership | Contact</nav>"
                "<h1>Welcome to Woollahra Golf Club</h1>"
                "<p>Book online or call the pro shop.</p></body></html>"
            ),
            url="https://woollahra.miclub.com.au/",
        ))
        result = fetcher.fetch(TIMESHEET, session=session, retries=2)
        self.assertFalse(result.ok)
        self.assertIsNotNone(result.error)
        self.assertIsNone(result.html)
        self.assertEqual(len(session.calls), 1, "asking again gets the same homepage")


# --------------------------------------------------------------------------
# The happy path, and what it sends
# --------------------------------------------------------------------------

class SuccessTests(FetcherTestCase):
    def test_a_successful_fetch_returns_the_body_and_no_error(self):
        session = self.session(FakeResponse(200, text=HTML))
        result = fetcher.fetch(TIMESHEET, session=session)
        self.assertTrue(result.ok)
        self.assertEqual(result.html, HTML)
        self.assertIsNone(result.error)
        self.assertEqual(result.status, 200)
        self.assertEqual(result.attempts, 1)
        self.assertIsInstance(result.elapsed_ms, int)
        self.assertGreaterEqual(result.elapsed_ms, 0)

    def test_the_user_agent_still_carries_the_contact_address(self):
        session = self.session(FakeResponse(200, text=HTML))
        fetcher.fetch(TIMESHEET, session=session)
        headers = session.calls[0][1]["headers"]
        self.assertEqual(headers["User-Agent"], fetcher.USER_AGENT)
        self.assertIn("hello@letsbundle.online", headers["User-Agent"])

    def test_redirects_are_followed_and_the_default_timeout_is_sent(self):
        session = self.session(FakeResponse(200, text=HTML))
        fetcher.fetch(TIMESHEET, session=session)
        kwargs = session.calls[0][1]
        self.assertIs(kwargs["allow_redirects"], True)
        self.assertEqual(kwargs["timeout"], fetcher.DEFAULT_TIMEOUT)

    def test_the_result_is_frozen(self):
        result = fetcher.fetch(TIMESHEET, session=self.session(FakeResponse(200, text=HTML)))
        with self.assertRaises(Exception):
            result.ok = False


# --------------------------------------------------------------------------
# Courtesy is per host. Fifteen clubs are fifteen separate servers.
# --------------------------------------------------------------------------

class PoliteSleepTests(FetcherTestCase):
    def test_polite_sleep_waits_for_the_same_club_and_not_a_different_one(self):
        fetcher.polite_sleep("woollahra.miclub.com.au")
        self.assertEqual(self.clock.sleeps, [], "nothing is owed on the first request to a host")

        fetcher.polite_sleep("moorepark.miclub.com.au")
        self.assertEqual(self.clock.sleeps, [], "a different club is a different server")

        fetcher.polite_sleep("woollahra.miclub.com.au")
        self.assertEqual(self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL])

    def test_a_host_that_has_gone_quiet_owes_nothing(self):
        fetcher.polite_sleep("woollahra.miclub.com.au")
        self.clock.now_value += 60.0
        fetcher.polite_sleep("woollahra.miclub.com.au")
        self.assertEqual(self.clock.sleeps, [])

    def test_the_host_is_matched_case_insensitively(self):
        fetcher.polite_sleep("Woollahra.MiClub.com.au")
        fetcher.polite_sleep("woollahra.miclub.com.au")
        self.assertEqual(self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL])

    def test_fetch_throttles_itself_without_being_asked(self):
        """The floor cannot depend on every caller remembering to be polite."""
        session = self.session(FakeResponse(200, text=HTML))
        fetcher.fetch(TIMESHEET, session=session)
        fetcher.fetch(OTHER_CLUB, session=session)
        self.assertEqual(self.clock.sleeps, [], "two clubs do not wait on each other")
        fetcher.fetch(TIMESHEET, session=session)
        self.assertEqual(self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL])

    def test_an_explicit_host_overrides_the_one_in_the_url(self):
        session = self.session(FakeResponse(200, text=HTML))
        fetcher.fetch(TIMESHEET, host="shared-edge.example", session=session)
        fetcher.fetch(OTHER_CLUB, host="shared-edge.example", session=session)
        self.assertEqual(self.clock.sleeps, [fetcher.MIN_HOST_INTERVAL])


# --------------------------------------------------------------------------
# Debug capture: off unless asked for
# --------------------------------------------------------------------------

class DebugCaptureTests(FetcherTestCase):
    def test_nothing_is_written_unless_the_env_var_is_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            debug_dir = Path(tmp) / "debug"
            self.patch(fetcher, "DEBUG_DIR", debug_dir)
            env = dict(os.environ)
            env.pop(fetcher.DEBUG_ENV, None)
            with mock.patch.dict(os.environ, env, clear=True):
                fetcher.fetch(TIMESHEET, session=self.session(FakeResponse(200, text=HTML)))
            self.assertFalse(debug_dir.exists(), "debug capture must be off by default")

    def test_the_page_is_kept_named_by_host_and_date_when_asked_for(self):
        with tempfile.TemporaryDirectory() as tmp:
            debug_dir = Path(tmp) / "debug"
            self.patch(fetcher, "DEBUG_DIR", debug_dir)
            with mock.patch.dict(os.environ, {fetcher.DEBUG_ENV: "1"}):
                fetcher.fetch(TIMESHEET, session=self.session(FakeResponse(200, text=HTML)))
            dumped = sorted(debug_dir.glob("*.html"))
            self.assertEqual(len(dumped), 1)
            self.assertEqual(dumped[0].read_text(), HTML)
            self.assertIn("woollahra.miclub.com.au", dumped[0].name)
            self.assertIn("2026-09-18", dumped[0].name, "the date is the one the page is for")


if __name__ == "__main__":
    unittest.main()
