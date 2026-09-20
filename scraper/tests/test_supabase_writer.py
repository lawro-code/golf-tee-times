"""Writing the contract payload into Supabase.

No network, no hosted project: every test drives a fake session and asserts on
the requests the writer *would* have made. That is the only honest way to test
this until there is a branch database — writing to the hosted project needs
Will's explicit yes and would be the one mistake this module cannot take back.

The two behaviours worth breaking a build over:

  1. A course/day that FAILED closes nothing. A club returning 500 must not be
     able to blank out its own inventory, let alone anyone else's. That is the
     entire reason course_day_scrapes exists per day rather than per course.
  2. The upsert never writes opened_at, reopen_count or gone_at. Those belong
     to the private.slots_lifecycle trigger, and a writer that sets them turns
     "cancelled tee time alerts again" (CONTRACT.md section 6) back into
     silence.
"""

import ast
import json
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import urlparse

import supabase_writer
from supabase_writer import MissingCredentials, SupabaseWriter, WriteResult

URL = "https://ipzhqvsyxyjndpbmpibw.supabase.co"
KEY = "service-role-key-not-a-real-one"

DAY_ONE = "2026-09-18"
DAY_TWO = "2026-09-19"


# ---------------------------------------------------------------------------
# Payload helpers — the frozen contract shape, only as much of it as we need.
# ---------------------------------------------------------------------------

def slot(slug, tee_date, hhmm, tee="public-play", booking_type="Public Play", **over):
    row = {
        "id": "{}:{}:{}:{}".format(slug, tee_date, hhmm, tee),
        "course_slug": slug,
        "course_name": "A Golf Club",
        "region": "Eastern Suburbs",
        "drive_minutes_from_bondi": 10,
        "par": 70,
        "length_metres": None,
        "requires_registration": False,
        "tee_date": tee_date,
        "tee_time": "{}:{}:00".format(hhmm[:2], hhmm[2:]),
        "tee_at": "{}T{}:{}:00+10:00".format(tee_date, hhmm[:2], hhmm[2:]),
        "spots_available": 2,
        "total_spots": 4,
        "holes": 18,
        "price_min": None,
        "price_max": None,
        "price_tiers": [],
        "booking_type": booking_type,
        "booking_url": "https://{}.miclub.com.au/guests/bookings/x".format(slug),
    }
    row.update(over)
    return row


def course_day(slug, tee_date, ok=True, slot_count=0, error=None, last_success_at="keep"):
    if last_success_at == "keep":
        last_success_at = "2026-09-18T05:00:00+10:00" if ok else None
    return {
        "course_slug": slug,
        "tee_date": tee_date,
        "ok": ok,
        "slot_count": slot_count,
        "error": error,
        "last_attempt_at": "2026-09-18T05:00:00+10:00",
        "last_success_at": last_success_at,
    }


def payload(slots=None, course_days=None, **over):
    body = {
        "contract_version": "1.0.0",
        "generated_at": "2026-09-18T05:00:00+10:00",
        "mode": "fast",
        "days": 3,
        "courses": [],
        "slots": slots or [],
        "course_days": course_days or [],
    }
    body.update(over)
    return body


# ---------------------------------------------------------------------------
# A fake requests.Session. It records everything and answers GETs out of a
# little in-memory slots table so "was this row closed?" is a real question.
# ---------------------------------------------------------------------------

class FakeResponse:
    def __init__(self, status_code=200, body=None, text=None):
        self.status_code = status_code
        self._body = body
        self.text = text if text is not None else json.dumps(body if body is not None else [])

    def json(self):
        if self._body is None:
            raise ValueError("no json body")
        return self._body


class Recorded:
    def __init__(self, method, url, params, body, headers):
        self.method = method
        self.url = url
        self.params = params or {}
        self.body = body
        self.headers = headers or {}

    @property
    def path(self):
        return urlparse(self.url).path

    @property
    def table(self):
        return self.path.rsplit("/", 1)[-1]

    @property
    def prefer(self):
        return self.headers.get("Prefer", "")

    def __repr__(self):  # pragma: no cover - debugging aid
        return "<{} {} {}>".format(self.method, self.path, self.params)


class FakeSession:
    """Answers PostgREST-ish requests and remembers every one of them."""

    def __init__(self, open_rows=None, fail=None, run_id=7):
        # open_rows: rows already sitting in public.slots with status 'open'.
        self.open_rows = list(open_rows or [])
        self.requests = []
        self.run_id = run_id
        # fail: callable(Recorded) -> FakeResponse or None, for injecting a
        # single bad chunk without disturbing the others.
        self.fail = fail

    def request(self, method, url, params=None, json=None, headers=None, timeout=None):
        rec = Recorded(method, url, params, json, headers)
        self.requests.append(rec)
        if self.fail is not None:
            injected = self.fail(rec)
            if injected is not None:
                return injected
        return self._answer(rec)

    def _answer(self, rec):
        if rec.table == "scrape_runs" and rec.method == "POST":
            return FakeResponse(201, [{"id": self.run_id}])
        if rec.table == "slots" and rec.method == "GET":
            return FakeResponse(200, self._select_open(rec.params))
        if rec.table == "slots" and rec.method == "PATCH":
            return FakeResponse(200, self._close(rec.params))
        return FakeResponse(204, None, text="")

    # -- the bits of PostgREST the writer actually leans on -----------------

    @staticmethod
    def _values(clause):
        """'in.("a","b")' -> ['a', 'b']"""
        inner = clause[clause.index("(") + 1:clause.rindex(")")]
        return [v.strip().strip('"') for v in inner.split(",") if v.strip()]

    def _matching(self, params):
        rows = [r for r in self.open_rows if r.get("status", "open") == "open"]
        slug = params.get("course_slug")
        if slug:
            rows = [r for r in rows if r["course_slug"] == slug.split(".", 1)[1]]
        dates = params.get("tee_date")
        if dates:
            wanted = set(self._values(dates)) if dates.startswith("in.") else {dates.split(".", 1)[1]}
            rows = [r for r in rows if r["tee_date"] in wanted]
        ids = params.get("id")
        if ids:
            wanted = set(self._values(ids)) if ids.startswith("in.") else {ids.split(".", 1)[1]}
            rows = [r for r in rows if r["id"] in wanted]
        return rows

    def _select_open(self, params):
        rows = sorted(self._matching(params), key=lambda r: r["id"])
        offset = int(params.get("offset", 0) or 0)
        limit = int(params.get("limit", len(rows)) or len(rows))
        page = rows[offset:offset + limit]
        return [
            {
                "id": r["id"],
                "tee_date": r["tee_date"],
                # Every real row has one; tests that don't care default to
                # something long enough ago to close under the old and new
                # rules alike. Tests proving the fencing set it explicitly.
                "last_seen_at": r.get("last_seen_at", "2020-01-01T00:00:00+10:00"),
            }
            for r in page
        ]

    def _close(self, params):
        hit = self._matching(params)
        for row in hit:
            row["status"] = "gone"
        return [{"id": r["id"]} for r in hit]

    # -- assertions helpers -------------------------------------------------

    def of(self, method, table):
        return [r for r in self.requests if r.method == method and r.table == table]

    def rows_sent(self, method, table):
        out = []
        for rec in self.of(method, table):
            out.extend(rec.body if isinstance(rec.body, list) else [rec.body])
        return out

    @property
    def closed_ids(self):
        return sorted(r["id"] for r in self.open_rows if r.get("status") == "gone")


def writer(session, **kw):
    return SupabaseWriter(URL, KEY, session=session, **kw)


# ---------------------------------------------------------------------------


class GoneSlotTests(unittest.TestCase):
    """Per course per day. This is the ticket's whole point."""

    def test_a_slot_a_successful_scrape_stopped_listing_is_closed(self):
        session = FakeSession(open_rows=[
            {"id": "woollahra:%s:0700:public-play" % DAY_ONE, "course_slug": "woollahra", "tee_date": DAY_ONE},
            {"id": "woollahra:%s:0708:public-play" % DAY_ONE, "course_slug": "woollahra", "tee_date": DAY_ONE},
        ])
        result = writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        self.assertEqual(session.closed_ids, ["woollahra:%s:0708:public-play" % DAY_ONE])
        self.assertEqual(result.slots_closed, 1)

    def test_a_slot_absent_because_that_day_failed_is_not_closed(self):
        """A club returning 500 must not blank out its own inventory."""
        session = FakeSession(open_rows=[
            {"id": "bexley:%s:0700:public-play" % DAY_ONE, "course_slug": "bexley", "tee_date": DAY_ONE},
        ])
        result = writer(session).write(payload(
            slots=[],
            course_days=[course_day("bexley", DAY_ONE, ok=False, error="HTTP 500")],
        ))

        self.assertEqual(session.closed_ids, [])
        self.assertEqual(result.slots_closed, 0)
        self.assertEqual(session.of("PATCH", "slots"), [])

    def test_a_failed_day_does_not_take_down_a_good_day_of_the_same_course(self):
        session = FakeSession(open_rows=[
            {"id": "bexley:%s:0700:public-play" % DAY_ONE, "course_slug": "bexley", "tee_date": DAY_ONE},
            {"id": "bexley:%s:0700:public-play" % DAY_TWO, "course_slug": "bexley", "tee_date": DAY_TWO},
        ])
        writer(session).write(payload(
            slots=[],
            course_days=[
                course_day("bexley", DAY_ONE, ok=False, error="HTTP 500"),
                course_day("bexley", DAY_TWO, ok=True, slot_count=0),
            ],
        ))

        self.assertEqual(session.closed_ids, ["bexley:%s:0700:public-play" % DAY_TWO])

    def test_a_failed_course_cannot_close_another_courses_slots(self):
        session = FakeSession(open_rows=[
            {"id": "bexley:%s:0700:public-play" % DAY_ONE, "course_slug": "bexley", "tee_date": DAY_ONE},
            {"id": "woollahra:%s:0700:public-play" % DAY_ONE, "course_slug": "woollahra", "tee_date": DAY_ONE},
        ])
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[
                course_day("bexley", DAY_ONE, ok=False, error="HTTP 500"),
                course_day("woollahra", DAY_ONE, ok=True, slot_count=1),
            ],
        ))

        self.assertEqual(session.closed_ids, [])

    def test_an_empty_but_successful_day_closes_everything_it_used_to_list(self):
        """Long Reef with nothing free is not Long Reef unreachable."""
        session = FakeSession(open_rows=[
            {"id": "long-reef:%s:0700:public-play" % DAY_ONE, "course_slug": "long-reef", "tee_date": DAY_ONE},
        ])
        writer(session).write(payload(
            slots=[],
            course_days=[course_day("long-reef", DAY_ONE, ok=True, slot_count=0)],
        ))

        self.assertEqual(session.closed_ids, ["long-reef:%s:0700:public-play" % DAY_ONE])

    def test_the_close_query_only_ever_asks_for_days_that_scraped_ok(self):
        session = FakeSession()
        writer(session).write(payload(
            slots=[],
            course_days=[
                course_day("bexley", DAY_ONE, ok=False, error="boom"),
                course_day("bexley", DAY_TWO, ok=True),
            ],
        ))

        gets = session.of("GET", "slots")
        self.assertEqual(len(gets), 1)
        self.assertIn(DAY_TWO, gets[0].params["tee_date"])
        self.assertNotIn(DAY_ONE, gets[0].params["tee_date"])
        self.assertEqual(gets[0].params["status"], "eq.open")

    def test_slots_are_upserted_before_anything_is_closed(self):
        """Closing first would bump reopen_count on every still-listed slot."""
        session = FakeSession(open_rows=[
            {"id": "woollahra:%s:0700:public-play" % DAY_ONE, "course_slug": "woollahra", "tee_date": DAY_ONE},
        ])
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        order = [(r.method, r.table) for r in session.requests]
        self.assertLess(order.index(("POST", "slots")), order.index(("GET", "slots")))

    def test_a_slot_a_concurrent_faster_scrape_just_reopened_is_not_closed(self):
        """TOCTOU between two independently-scheduled writers.

        A slow 'full' run's own HTML fetch for this (course, day) happened
        at 05:00 and honestly saw nothing (a genuine cancellation, or a slot
        not yet released). A 'fast' run then wrote this slot open at 05:03 —
        after full's fetch, before full gets around to closing. full's
        payload is not lying: it just fetched before fast's more current
        write landed. Closing here would flip a genuinely-open slot to
        'gone' and back to 'open' on the next scrape, minting a spurious
        opened_at and a duplicate "just opened" alert for nobody's benefit.
        """
        slug = "woollahra"
        y_id = "woollahra:%s:0700:public-play" % DAY_ONE
        session = FakeSession(open_rows=[
            {
                "id": y_id,
                "course_slug": slug,
                "tee_date": DAY_ONE,
                # The concurrent fast run's write, landed after full fetched.
                "last_seen_at": "2026-09-18T05:03:00+10:00",
            },
        ])

        full_day = course_day(slug, DAY_ONE, ok=True, slot_count=0)
        full_day["last_attempt_at"] = "2026-09-18T05:00:00+10:00"

        result = writer(session).write(payload(
            slots=[],  # full's own fetch never saw Y open
            course_days=[full_day],
            mode="full",
        ))

        self.assertEqual(session.closed_ids, [])
        self.assertEqual(result.slots_closed, 0)

    def test_a_slot_nobody_touched_since_before_the_fetch_is_still_closed(self):
        """The fence must not turn off closing altogether.

        Same shape as the race test, except the row's last_seen_at predates
        this run's own fetch of the page — an ordinary stale listing, not a
        concurrent write — so it still closes.
        """
        slug = "woollahra"
        y_id = "woollahra:%s:0700:public-play" % DAY_ONE
        session = FakeSession(open_rows=[
            {
                "id": y_id,
                "course_slug": slug,
                "tee_date": DAY_ONE,
                "last_seen_at": "2026-09-18T04:00:00+10:00",  # before the fetch
            },
        ])

        full_day = course_day(slug, DAY_ONE, ok=True, slot_count=0)
        full_day["last_attempt_at"] = "2026-09-18T05:00:00+10:00"

        result = writer(session).write(payload(
            slots=[],
            course_days=[full_day],
            mode="full",
        ))

        self.assertEqual(session.closed_ids, [y_id])
        self.assertEqual(result.slots_closed, 1)


class SlotUpsertTests(unittest.TestCase):
    def test_the_upsert_never_writes_the_lifecycle_columns(self):
        """opened_at, reopen_count and gone_at belong to the trigger."""
        session = FakeSession()
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        rows = session.rows_sent("POST", "slots")
        self.assertEqual(len(rows), 1)
        for forbidden in ("opened_at", "reopen_count", "gone_at", "first_seen_at"):
            self.assertNotIn(forbidden, rows[0])

    def test_the_upsert_writes_exactly_the_columns_the_scraper_saw(self):
        session = FakeSession()
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700", price_min=26.0, price_max=39.0,
                        price_tiers=[{"label": "Twilight", "amount": 26.0}])],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        row = session.rows_sent("POST", "slots")[0]
        self.assertEqual(set(row), {
            "id", "course_slug", "tee_date", "tee_time", "tee_at", "spots_available",
            "total_spots", "holes", "price_min", "price_max", "price_tiers",
            "booking_type", "booking_url", "status", "last_seen_at",
        })
        self.assertEqual(row["status"], "open")
        self.assertEqual(row["last_seen_at"], "2026-09-18T05:00:00+10:00")
        self.assertEqual(row["price_tiers"], [{"label": "Twilight", "amount": 26.0}])
        # course_name/region/par ride along in the payload but live on courses.
        self.assertNotIn("course_name", row)

    def test_the_upsert_merges_duplicates_on_the_primary_key(self):
        session = FakeSession()
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        post = session.of("POST", "slots")[0]
        self.assertIn("resolution=merge-duplicates", post.prefer)
        self.assertIn("return=minimal", post.prefer)
        self.assertEqual(post.params.get("on_conflict"), "id")

    def test_upserts_are_chunked_rather_than_one_request_per_slot(self):
        session = FakeSession()
        w = writer(session)
        w.SLOT_CHUNK = 2
        slots = [slot("woollahra", DAY_ONE, "07%02d" % n) for n in range(5)]
        result = w.write(payload(
            slots=slots,
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=5)],
        ))

        posts = session.of("POST", "slots")
        self.assertEqual([len(p.body) for p in posts], [2, 2, 1])
        self.assertEqual(result.slots_upserted, 5)


class CourseDayTests(unittest.TestCase):
    def test_last_success_at_is_absent_from_the_body_for_a_failed_day(self):
        """Omitting the column is what stops the upsert nulling a good one."""
        session = FakeSession()
        writer(session).write(payload(
            course_days=[course_day("bexley", DAY_ONE, ok=False, error="HTTP 500",
                                    last_success_at=None)],
        ))

        rows = session.rows_sent("POST", "course_day_scrapes")
        self.assertEqual(len(rows), 1)
        self.assertNotIn("last_success_at", rows[0])
        self.assertEqual(rows[0]["ok"], False)
        self.assertEqual(rows[0]["error"], "HTTP 500")
        self.assertEqual(rows[0]["last_attempt_at"], "2026-09-18T05:00:00+10:00")

    def test_a_failed_day_carrying_an_old_success_still_omits_the_column(self):
        session = FakeSession()
        writer(session).write(payload(
            course_days=[course_day("bexley", DAY_ONE, ok=False, error="HTTP 500",
                                    last_success_at="2026-09-17T05:00:00+10:00")],
        ))

        rows = session.rows_sent("POST", "course_day_scrapes")
        self.assertNotIn("last_success_at", rows[0])

    def test_a_good_day_writes_last_success_at(self):
        session = FakeSession()
        writer(session).write(payload(
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=3)],
        ))

        rows = session.rows_sent("POST", "course_day_scrapes")
        self.assertEqual(rows[0]["last_success_at"], "2026-09-18T05:00:00+10:00")
        self.assertEqual(rows[0]["slot_count"], 3)

    def test_good_and_failed_days_go_as_separate_bodies(self):
        """PostgREST builds its column list from the batch, so they cannot mix."""
        session = FakeSession()
        result = writer(session).write(payload(
            course_days=[
                course_day("woollahra", DAY_ONE, ok=True, slot_count=3),
                course_day("bexley", DAY_ONE, ok=False, error="HTTP 500"),
            ],
        ))

        posts = session.of("POST", "course_day_scrapes")
        self.assertEqual(len(posts), 2)
        for post in posts:
            keys = {frozenset(row) for row in post.body}
            self.assertEqual(len(keys), 1, "one column list per request")
            self.assertEqual(post.params.get("on_conflict"), "course_slug,tee_date")
        self.assertEqual(result.course_days_written, 2)


class RunLedgerTests(unittest.TestCase):
    def test_the_run_row_is_opened_first_and_closed_last(self):
        session = FakeSession(run_id=42)
        result = writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        self.assertEqual(result.run_id, 42)
        self.assertEqual(session.requests[0].table, "scrape_runs")
        self.assertEqual(session.requests[0].method, "POST")
        opened = session.requests[0].body
        self.assertEqual(opened["mode"], "fast")
        self.assertEqual(opened["days_requested"], 3)
        self.assertEqual(opened["contract_version"], "1.0.0")
        self.assertIn("started_at", opened)

        closed = session.requests[-1]
        self.assertEqual((closed.method, closed.table), ("PATCH", "scrape_runs"))
        self.assertEqual(closed.params["id"], "eq.42")
        self.assertEqual(closed.body["slots_upserted"], 1)
        self.assertIsNone(closed.body["error"])
        self.assertIn("finished_at", closed.body)

    def test_the_run_row_counts_courses_by_whether_every_day_reached_them(self):
        session = FakeSession()
        writer(session).write(payload(course_days=[
            course_day("woollahra", DAY_ONE, ok=True),
            course_day("woollahra", DAY_TWO, ok=True),
            course_day("bexley", DAY_ONE, ok=True),
            course_day("bexley", DAY_TWO, ok=False, error="HTTP 500"),
        ]))

        closed = session.of("PATCH", "scrape_runs")[0].body
        self.assertEqual(closed["courses_attempted"], 2)
        self.assertEqual(closed["courses_ok"], 1)
        self.assertEqual(closed["courses_failed"], 1)

    def test_a_crash_still_closes_the_run_row(self):
        session = FakeSession()
        w = writer(session)
        with mock.patch.object(w, "_upsert_slots", side_effect=RuntimeError("kaboom")):
            with self.assertRaises(RuntimeError):
                w.write(payload(course_days=[course_day("woollahra", DAY_ONE)]))

        closed = session.of("PATCH", "scrape_runs")
        self.assertEqual(len(closed), 1)
        self.assertIn("kaboom", closed[0].body["error"])
        self.assertIn("finished_at", closed[0].body)

    def test_chunk_errors_are_recorded_on_the_run_row(self):
        def fail(rec):
            if rec.table == "slots" and rec.method == "POST":
                return FakeResponse(400, None, text="duplicate key value")
            return None

        session = FakeSession(fail=fail)
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        closed = session.of("PATCH", "scrape_runs")[0].body
        self.assertIn("duplicate key value", closed["error"])


class FailureIsolationTests(unittest.TestCase):
    def test_a_failing_chunk_does_not_abort_the_remaining_chunks(self):
        state = {"n": 0}

        def fail(rec):
            if rec.table == "slots" and rec.method == "POST":
                state["n"] += 1
                if state["n"] == 2:
                    return FakeResponse(500, None, text="upstream timeout")
            return None

        session = FakeSession(fail=fail)
        w = writer(session)
        w.SLOT_CHUNK = 2
        result = w.write(payload(
            slots=[slot("woollahra", DAY_ONE, "07%02d" % n) for n in range(6)],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=6)],
        ))

        self.assertEqual(len(session.of("POST", "slots")), 3, "all three chunks attempted")
        self.assertEqual(result.slots_upserted, 4, "the two good chunks landed")
        self.assertEqual(len(result.errors), 1)
        self.assertIn("upstream timeout", result.errors[0])
        # And the rest of the write still happened.
        self.assertEqual(len(session.of("POST", "course_day_scrapes")), 1)
        self.assertEqual(result.course_days_written, 1)

    def test_one_course_failing_to_close_does_not_lose_the_others(self):
        def fail(rec):
            if rec.table == "slots" and rec.method == "GET" and "bexley" in rec.params.get("course_slug", ""):
                return FakeResponse(503, None, text="service unavailable")
            return None

        session = FakeSession(fail=fail, open_rows=[
            {"id": "bexley:%s:0700:public-play" % DAY_ONE, "course_slug": "bexley", "tee_date": DAY_ONE},
            {"id": "woollahra:%s:0700:public-play" % DAY_ONE, "course_slug": "woollahra", "tee_date": DAY_ONE},
        ])
        result = writer(session).write(payload(
            slots=[],
            course_days=[
                course_day("bexley", DAY_ONE, ok=True),
                course_day("woollahra", DAY_ONE, ok=True),
            ],
        ))

        self.assertEqual(session.closed_ids, ["woollahra:%s:0700:public-play" % DAY_ONE])
        self.assertEqual(result.slots_closed, 1)
        self.assertEqual(len(result.errors), 1)
        self.assertIn("service unavailable", result.errors[0])

    def test_a_course_day_chunk_failing_does_not_stop_the_run_closing(self):
        def fail(rec):
            if rec.table == "course_day_scrapes":
                return FakeResponse(500, None, text="nope")
            return None

        session = FakeSession(fail=fail)
        result = writer(session).write(payload(
            course_days=[course_day("woollahra", DAY_ONE, ok=True)],
        ))

        self.assertEqual(result.course_days_written, 0)
        self.assertEqual(len(result.errors), 1)
        self.assertEqual(len(session.of("PATCH", "scrape_runs")), 1)


class DryRunTests(unittest.TestCase):
    def test_dry_run_makes_no_calls_at_all(self):
        session = FakeSession()
        result = writer(session, dry_run=True).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700"), slot("woollahra", DAY_ONE, "0708")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=2)],
        ))

        self.assertEqual(session.requests, [])
        self.assertEqual(result.slots_upserted, 2)
        self.assertEqual(result.course_days_written, 1)
        self.assertEqual(result.slots_closed, 0)
        self.assertIsNone(result.run_id)
        self.assertEqual(result.errors, [])

    def test_dry_run_needs_no_credentials(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            w = SupabaseWriter.from_env(dry_run=True)
        self.assertTrue(w.dry_run)
        self.assertIsInstance(w.write(payload()), WriteResult)


class CredentialTests(unittest.TestCase):
    def test_from_env_reads_the_documented_variables(self):
        env = {"SUPABASE_URL": URL + "/", "SUPABASE_SERVICE_ROLE_KEY": KEY}
        with mock.patch.dict("os.environ", env, clear=True):
            w = SupabaseWriter.from_env()
        self.assertEqual(w.base_url, URL + "/rest/v1")

    def test_from_env_raises_missing_credentials_when_a_variable_is_absent(self):
        for env in ({"SUPABASE_URL": URL}, {"SUPABASE_SERVICE_ROLE_KEY": KEY}, {}):
            with mock.patch.dict("os.environ", env, clear=True):
                with self.assertRaises(MissingCredentials):
                    SupabaseWriter.from_env()

    def test_missing_credentials_is_a_runtime_error(self):
        self.assertTrue(issubclass(MissingCredentials, RuntimeError))

    def test_every_request_carries_the_service_role_key(self):
        session = FakeSession()
        writer(session).write(payload(
            slots=[slot("woollahra", DAY_ONE, "0700")],
            course_days=[course_day("woollahra", DAY_ONE, ok=True, slot_count=1)],
        ))

        self.assertTrue(session.requests)
        for rec in session.requests:
            self.assertEqual(rec.headers["apikey"], KEY)
            self.assertEqual(rec.headers["Authorization"], "Bearer " + KEY)
            self.assertTrue(rec.url.startswith(URL + "/rest/v1/"))
            # The key never leaks into a URL or a query string.
            self.assertNotIn(KEY, rec.url)
            self.assertNotIn(KEY, json.dumps(rec.params))


class ModuleShapeTests(unittest.TestCase):
    def test_it_does_not_shadow_the_real_supabase_package(self):
        """scraper/ goes on sys.path, so a supabase.py here would shadow it."""
        self.assertEqual(supabase_writer.__name__, "supabase_writer")

    def test_it_uses_postgrest_over_requests_not_psycopg(self):
        """Imports, not prose — the docstring names both to say why not."""
        tree = ast.parse(Path(supabase_writer.__file__).read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module)

        roots = {name.split(".")[0] for name in imported}
        self.assertNotIn("psycopg", roots)
        self.assertNotIn("psycopg2", roots)
        self.assertNotIn("supabase", roots)
        # This ticket owns requirements.txt, so pin the dependency surface:
        # stdlib plus requests, which is already pinned there.
        stdlib = {"__future__", "json", "os", "dataclasses", "datetime", "typing", "zoneinfo"}
        self.assertEqual(roots - stdlib, {"requests"})


if __name__ == "__main__":
    unittest.main()
