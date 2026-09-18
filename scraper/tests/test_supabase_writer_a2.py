"""A2 acceptance tests: what the Supabase writer promises, checked against the
ways it could plausibly have been written instead.

These are the tester's tests, written from the ticket and CONTRACT.md rather
than from the implementation.

About the "must fail before the ticket" bar. Before A2 there was no writer at
all — `scraper/supabase_writer.py` does not exist at git HEAD, and `scrape.py`
at HEAD has no Supabase path. So *any* test in this file fails before the
ticket, by ImportError, which proves nothing. The honest bar, and the one every
test here clears, is stronger: each test is killed by at least one plausible
naive implementation of the same ticket. The kill matrix is in the gate notes —
mutations like "copy the whole slot dict", "sweep on last_seen_at instead of
diffing the payload", "count the ids you asked to close rather than the ones
that changed", "let the run-ledger row be load-bearing". A test no mutation
kills was cut; three were.

No network, no hosted project, no branch database. Every test drives its own
fake PostgREST and asserts on the requests the writer *would* have made.
Writing to the hosted project is the one mistake this module cannot take back,
so nothing here is allowed to need it.

Bias is towards the failure paths. A writer is only interesting on the day a
club is broken, a chunk is rejected, or the ledger row will not open.
"""

import json
import unittest
from unittest import mock
from urllib.parse import urlparse

import supabase_writer
from supabase_writer import SupabaseWriter

URL = "https://example-project.supabase.co"
KEY = "eyJhbGciOiJIUzI1NiJ9.service-role.not-a-real-key"

D1 = "2026-09-18"
D2 = "2026-09-19"
SEEN = "2026-09-18T05:00:00+10:00"


# ---------------------------------------------------------------------------
# Payload fixtures — the frozen contract shape, built here rather than imported
# from the implementer's test file so these tests stand on their own.
# ---------------------------------------------------------------------------

def a_slot(slug, tee_date, hhmm, tee="public-play", **over):
    row = {
        "id": "{}:{}:{}:{}".format(slug, tee_date, hhmm, tee),
        "course_slug": slug,
        "course_name": "A Golf Club",
        "region": "Eastern Suburbs",
        "drive_minutes_from_bondi": 12,
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
        "booking_type": "Public Play",
        "booking_url": "https://{}.miclub.com.au/guests/bookings/x".format(slug),
    }
    row.update(over)
    return row


def a_day(slug, tee_date, ok=True, **over):
    row = {
        "course_slug": slug,
        "tee_date": tee_date,
        "ok": ok,
        "slot_count": 0,
        "error": None if ok else "HTTP 500",
        "last_attempt_at": SEEN,
        "last_success_at": SEEN if ok else None,
    }
    row.update(over)
    return row


def a_payload(slots=None, days=None, **over):
    body = {
        "contract_version": "1.0.0",
        "generated_at": SEEN,
        "mode": "fast",
        "days": 3,
        "courses": [],
        "slots": list(slots or []),
        "course_days": list(days or []),
    }
    body.update(over)
    return body


def an_open_row(slug, tee_date, hhmm, tee="public-play"):
    return {
        "id": "{}:{}:{}:{}".format(slug, tee_date, hhmm, tee),
        "course_slug": slug,
        "tee_date": tee_date,
        "status": "open",
    }


# ---------------------------------------------------------------------------
# A fake PostgREST. It parses the filters the way PostgREST does — including
# the quoting in `in.(...)` — so "would this request have closed that row?" is
# a real question and not a rubber stamp.
# ---------------------------------------------------------------------------

def parse_in_list(clause):
    """`in.("a","b,c")` -> ['a', 'b,c']. Quotes protect commas; PostgREST
    splits an unquoted list on every comma, and so does this."""
    inner = clause[len("in."):]
    inner = inner[1:-1] if inner.startswith("(") else inner
    values, buf, quoted, escaped = [], [], False, False
    for ch in inner:
        if escaped:
            buf.append(ch)
            escaped = False
        elif quoted and ch == "\\":
            escaped = True
        elif ch == '"':
            quoted = not quoted
        elif ch == "," and not quoted:
            values.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    tail = "".join(buf)
    if tail or values:
        values.append(tail)
    return values


class Call(object):
    def __init__(self, method, url, params, body, headers):
        self.method = method
        self.url = url
        self.params = dict(params or {})
        self.body = body
        self.headers = dict(headers or {})

    @property
    def table(self):
        return urlparse(self.url).path.rsplit("/", 1)[-1]

    @property
    def rows(self):
        return self.body if isinstance(self.body, list) else [self.body]

    def __repr__(self):  # pragma: no cover - debugging aid
        return "<{} {} {}>".format(self.method, self.table, sorted(self.params))


class Reply(object):
    def __init__(self, status_code, body=None, text=None):
        self.status_code = status_code
        self._body = body
        self.text = text if text is not None else json.dumps(body or [])

    def json(self):
        if self._body is None:
            raise ValueError("no json body")
        return self._body


class FakePostgrest(object):
    def __init__(self, open_rows=None, run_id=101, fault=None):
        self.rows = [dict(r) for r in (open_rows or [])]
        self.calls = []
        self.run_id = run_id
        self.fault = fault  # callable(Call) -> Reply or None

    # -- transport ------------------------------------------------------
    def request(self, method, url, params=None, json=None, headers=None, timeout=None):
        call = Call(method, url, params, json, headers)
        self.calls.append(call)
        if self.fault is not None:
            injected = self.fault(call)
            if injected is not None:
                return injected
        return self._answer(call)

    def _answer(self, call):
        if call.table == "scrape_runs" and call.method == "POST":
            return Reply(201, [{"id": self.run_id}])
        if call.table == "slots" and call.method == "GET":
            return Reply(200, self._select(call.params))
        if call.table == "slots" and call.method == "PATCH":
            return Reply(200, self._patch(call.params, call.body))
        if call.method == "DELETE":  # pragma: no cover - guarded by a test
            raise AssertionError("the writer must never delete rows")
        return Reply(204, None, text="")

    # -- the filters the writer leans on --------------------------------
    @staticmethod
    def _wanted(clause):
        if clause is None:
            return None
        if clause.startswith("in."):
            return set(parse_in_list(clause))
        return {clause.split(".", 1)[1]}

    def _match(self, params):
        hit = list(self.rows)
        for column, key in (("course_slug", "course_slug"), ("tee_date", "tee_date"),
                            ("id", "id"), ("status", "status")):
            wanted = self._wanted(params.get(column))
            if wanted is not None:
                hit = [r for r in hit if r[key] in wanted]
        return hit

    def _select(self, params):
        hit = sorted(self._match(params), key=lambda r: r["id"])
        offset = int(params.get("offset") or 0)
        limit = int(params.get("limit") or len(hit) or 1)
        return [{"id": r["id"], "tee_date": r["tee_date"]} for r in hit[offset:offset + limit]]

    def _patch(self, params, body):
        hit = self._match(params)
        for row in hit:
            row.update(body or {})
        return [{"id": r["id"]} for r in hit]

    # -- assertion helpers ----------------------------------------------
    def of(self, method, table):
        return [c for c in self.calls if c.method == method and c.table == table]

    def bodies(self, method, table):
        out = []
        for call in self.of(method, table):
            out.extend(call.rows)
        return out

    @property
    def gone(self):
        return sorted(r["id"] for r in self.rows if r["status"] == "gone")

    @property
    def still_open(self):
        return sorted(r["id"] for r in self.rows if r["status"] == "open")


def a_writer(db, **kw):
    return SupabaseWriter(URL, KEY, session=db, **kw)


def fault_on(method, table, status=500, text="boom", nth=None):
    """Fail the nth (1-based) matching call, or every one when nth is None."""
    state = {"n": 0}

    def fault(call):
        if call.method != method or call.table != table:
            return None
        state["n"] += 1
        if nth is None or state["n"] == nth:
            return Reply(status, None, text=text)
        return None

    return fault


# ---------------------------------------------------------------------------


class WhatTheUpsertIsAllowedToSay(unittest.TestCase):
    """The scraper reports what it saw. Everything else is the trigger's."""

    def test_lifecycle_columns_are_stripped_even_when_the_payload_carries_them(self):
        """The fixture matters: a slot that has never been near the database
        has no opened_at to leak. A slot round-tripped through open_slots does,
        and that is the one that breaks CONTRACT.md section 6 — silently. Twelve
        scrapes of one listing would each restamp opened_at, and every one of
        them would look like a fresh cancellation to alert_deliveries."""
        dirty = a_slot("woollahra", D1, "0700",
                       opened_at="2026-09-10T06:00:00+10:00",
                       reopen_count=4,
                       gone_at="2026-09-11T06:00:00+10:00",
                       first_seen_at="2026-09-01T06:00:00+10:00",
                       last_seen_at="2026-09-11T06:00:00+10:00",
                       status="gone")
        db = FakePostgrest()
        a_writer(db).write(a_payload(slots=[dirty], days=[a_day("woollahra", D1)]))

        row = db.bodies("POST", "slots")[0]
        for owned in ("opened_at", "reopen_count", "gone_at", "first_seen_at"):
            self.assertNotIn(owned, row, "{} belongs to private.slots_lifecycle".format(owned))
        self.assertEqual(row["last_seen_at"], SEEN, "this run's timestamp, not the old one")

    def test_a_payload_slot_marked_gone_is_still_upserted_as_open(self):
        """status is an observation of this scrape, never a value carried in.
        A slot the scrape just listed is open by definition; writing 'gone'
        from a stale field would fire the trigger's gone branch and stamp
        gone_at on live inventory."""
        db = FakePostgrest()
        a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700", status="gone")],
            days=[a_day("woollahra", D1)],
        ))

        self.assertEqual(db.bodies("POST", "slots")[0]["status"], "open")

    def test_nothing_that_belongs_to_the_courses_table_rides_along(self):
        """course_name, region, par and drive_minutes are in the payload
        because open_slots joins them in. They are not columns of slots, and a
        column PostgREST does not recognise fails the whole 500-row chunk."""
        db = FakePostgrest()
        a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1)],
        ))

        row = db.bodies("POST", "slots")[0]
        self.assertEqual(set(row), {
            "id", "course_slug", "tee_date", "tee_time", "tee_at", "spots_available",
            "total_spots", "holes", "price_min", "price_max", "price_tiers",
            "booking_type", "booking_url", "status", "last_seen_at",
        })


class ClosingIsDiffedAgainstThePayload(unittest.TestCase):
    """Why the writer reads before it closes, instead of sweeping on
    last_seen_at. The cheap version is one request; it is also the version that
    deletes live inventory on the day an upsert chunk is rejected."""

    def test_a_slot_whose_upsert_failed_is_not_closed(self):
        """The trap, stated as a test. Both tee times are still listed at the
        club and both failed to write. A sweep on `last_seen_at < run start`
        would find two rows with a stale timestamp and close them — hiding two
        bookable rounds because Supabase had a bad minute. Diffing against the
        payload cannot make that mistake by construction."""
        db = FakePostgrest(
            open_rows=[an_open_row("woollahra", D1, "0700"), an_open_row("woollahra", D1, "0708")],
            fault=fault_on("POST", "slots", 500, "upstream connect error"),
        )
        result = a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700"), a_slot("woollahra", D1, "0708")],
            days=[a_day("woollahra", D1, slot_count=2)],
        ))

        self.assertEqual(db.gone, [], "a failed upsert must never close a live slot")
        self.assertEqual(result.slots_closed, 0)
        self.assertEqual(result.slots_upserted, 0)
        self.assertEqual(len(result.errors), 1)

    def test_a_run_with_nothing_missing_sends_no_patch_at_all(self):
        """The ordinary case, 72 times a day. An empty id list must not become
        `id=in.()`, which PostgREST rejects — or worse, a PATCH with no filter."""
        db = FakePostgrest(open_rows=[an_open_row("woollahra", D1, "0700")])
        result = a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1, slot_count=1)],
        ))

        self.assertEqual(db.of("PATCH", "slots"), [])
        self.assertEqual(db.still_open, ["woollahra:{}:0700:public-play".format(D1)])
        self.assertEqual(result.slots_closed, 0)

    def test_the_day_a_club_refused_is_never_even_queried(self):
        """Per day, not per course. Woollahra's Friday scraped clean and its
        Saturday 500'd; Saturday's inventory must survive untouched, and the
        health row for it still has to be written."""
        db = FakePostgrest(open_rows=[
            an_open_row("woollahra", D1, "0700"),
            an_open_row("woollahra", D2, "0700"),
        ])
        a_writer(db).write(a_payload(
            slots=[],
            days=[a_day("woollahra", D1, ok=True), a_day("woollahra", D2, ok=False)],
        ))

        self.assertEqual(db.gone, ["woollahra:{}:0700:public-play".format(D1)])
        self.assertEqual(db.still_open, ["woollahra:{}:0700:public-play".format(D2)])
        gets = db.of("GET", "slots")
        self.assertEqual(len(gets), 1)
        self.assertEqual(parse_in_list(gets[0].params["tee_date"]), [D1])
        self.assertEqual(len(db.bodies("POST", "course_day_scrapes")), 2)

    def test_a_course_day_with_no_date_cannot_widen_the_close(self):
        """A malformed health row is a scraper bug, not a licence to close a
        course's whole week. It is skipped and the real day still goes."""
        db = FakePostgrest(open_rows=[an_open_row("woollahra", D1, "0700")])
        a_writer(db).write(a_payload(
            slots=[],
            days=[a_day("woollahra", None, ok=True), a_day("woollahra", D1, ok=True)],
        ))

        gets = db.of("GET", "slots")
        self.assertEqual(len(gets), 1)
        self.assertEqual(parse_in_list(gets[0].params["tee_date"]), [D1])
        self.assertEqual(db.gone, ["woollahra:{}:0700:public-play".format(D1)])


class ReadingWhatIsOpen(unittest.TestCase):
    """The diff is only as good as the set it diffs against."""

    def test_every_page_of_open_slots_is_read_before_deciding_what_is_gone(self):
        """PostgREST has a db-max-rows setting and Supabase defaults it to
        1000. A writer that reads one page and diffs against it leaves every
        slot past the page boundary showing as open forever — the app then
        sends a golfer to a tee time the club has already given away.
        Warringah alone puts 289 rows on one day."""
        rows = [an_open_row("warringah", D1, "%04d" % (600 + n)) for n in range(5)]
        db = FakePostgrest(open_rows=rows)
        w = a_writer(db)
        w.PAGE_SIZE = 2
        w.write(a_payload(slots=[], days=[a_day("warringah", D1)]))

        self.assertEqual(len(db.of("GET", "slots")), 3, "two full pages then a short one")
        self.assertEqual(db.gone, sorted(r["id"] for r in rows), "every page closed")

    def test_paging_is_ordered_so_a_page_boundary_cannot_skip_a_row(self):
        """limit/offset over an unordered result is allowed to return the same
        row twice and another one never — the skipped one silently stays open."""
        db = FakePostgrest(open_rows=[an_open_row("warringah", D1, "0600")])
        a_writer(db).write(a_payload(slots=[], days=[a_day("warringah", D1)]))

        params = db.of("GET", "slots")[0].params
        self.assertEqual(params.get("order"), "id.asc")
        self.assertEqual(params.get("status"), "eq.open")


class ClosingRowsSafely(unittest.TestCase):

    def test_closing_is_chunked_so_the_id_filter_stays_inside_the_url(self):
        """`id=in.(...)` lives in the query string and a slot id is ~45 bytes.
        Long Reef emptying out for a public holiday is a few hundred ids; one
        request would be a 414 and nothing would close at all."""
        rows = [an_open_row("long-reef", D1, "%04d" % (600 + n)) for n in range(5)]
        db = FakePostgrest(open_rows=rows)
        w = a_writer(db)
        w.CLOSE_CHUNK = 2
        result = w.write(a_payload(slots=[], days=[a_day("long-reef", D1)]))

        patches = db.of("PATCH", "slots")
        self.assertEqual([len(parse_in_list(p.params["id"])) for p in patches], [2, 2, 1])
        self.assertEqual(result.slots_closed, 5)
        self.assertEqual(db.gone, sorted(r["id"] for r in rows))

    def test_the_close_only_touches_rows_that_are_still_open(self):
        """Two runs can overlap. Re-closing a row that another run already
        closed would restamp it and inflate the ledger's slots_closed."""
        db = FakePostgrest(open_rows=[an_open_row("woollahra", D1, "0700")])
        a_writer(db).write(a_payload(slots=[], days=[a_day("woollahra", D1)]))

        patch = db.of("PATCH", "slots")[0]
        self.assertEqual(patch.params.get("status"), "eq.open")
        self.assertEqual(patch.body, {"status": "gone"})

    def test_slots_closed_counts_rows_that_changed_not_rows_asked_about(self):
        """The ledger is the only place a human looks after a bad night. If it
        says 40 closed when 3 closed, it is worse than no ledger."""
        def half_of_them(call):
            if call.method == "PATCH" and call.table == "slots":
                asked = parse_in_list(call.params["id"])
                return Reply(200, [{"id": asked[0]}])  # another run got the rest
            return None

        rows = [an_open_row("woollahra", D1, "%04d" % (700 + n)) for n in range(3)]
        db = FakePostgrest(open_rows=rows, fault=half_of_them)
        result = a_writer(db).write(a_payload(slots=[], days=[a_day("woollahra", D1)]))

        self.assertEqual(result.slots_closed, 1)
        self.assertEqual(db.of("PATCH", "scrape_runs")[0].body["slots_closed"], 1)

    def test_nothing_is_ever_deleted(self):
        """A deleted slot takes its opened_at with it, and alert_deliveries
        keys on (watch_id, slot_id, slot_opened_at). Deleting is how you push
        the same tee time at somebody twice."""
        db = FakePostgrest(open_rows=[an_open_row("woollahra", D1, "0700")])
        a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0708")],
            days=[a_day("woollahra", D1, slot_count=1)],
        ))

        self.assertEqual([c.method for c in db.calls if c.method == "DELETE"], [])

    def test_ids_are_quoted_in_the_filter(self):
        """A slot id is club-supplied text: `tee_slug` is the only thing
        keeping a comma out of it today. An unquoted `in.(...)` splits on that
        comma, and the two halves match nothing while the real row stays open —
        or, if a half happens to match, close the wrong row."""
        odd = "woollahra:{}:0700:9-holes,-cart".format(D1)
        db = FakePostgrest(open_rows=[{
            "id": odd, "course_slug": "woollahra", "tee_date": D1, "status": "open",
        }])
        result = a_writer(db).write(a_payload(slots=[], days=[a_day("woollahra", D1)]))

        self.assertEqual(parse_in_list(db.of("PATCH", "slots")[0].params["id"]), [odd])
        self.assertEqual(result.slots_closed, 1)


class TheRunLedgerIsNotLoadBearing(unittest.TestCase):
    """Bookkeeping must never cost us the scrape it is bookkeeping for."""

    def test_the_write_still_happens_when_the_run_row_cannot_be_opened(self):
        db = FakePostgrest(fault=fault_on("POST", "scrape_runs", 503, "no capacity"))
        result = a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1, slot_count=1)],
        ))

        self.assertEqual(result.slots_upserted, 1)
        self.assertEqual(result.course_days_written, 1)
        self.assertIsNone(result.run_id)
        self.assertTrue(any("scrape_runs" in e for e in result.errors))
        self.assertEqual(db.of("PATCH", "scrape_runs"), [], "no id to close against")

    def test_the_result_survives_a_run_row_that_will_not_close(self):
        db = FakePostgrest(fault=fault_on("PATCH", "scrape_runs", 500, "nope"))
        result = a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1, slot_count=1)],
        ))

        self.assertEqual(result.slots_upserted, 1)
        self.assertEqual(result.run_id, 101)

    def test_a_crash_closes_the_run_row_with_the_work_that_did_land(self):
        """`courses_ok = 0, slots_upserted = 0` on a run that wrote 1,700 rows
        before it died sends you looking in the wrong place."""
        db = FakePostgrest()
        w = a_writer(db)
        with mock.patch.object(w, "_close_gone_slots", side_effect=RuntimeError("kaboom")):
            with self.assertRaises(RuntimeError):
                w.write(a_payload(
                    slots=[a_slot("woollahra", D1, "0700"), a_slot("woollahra", D1, "0708")],
                    days=[a_day("woollahra", D1, slot_count=2)],
                ))

        closed = db.of("PATCH", "scrape_runs")[0].body
        self.assertEqual(closed["slots_upserted"], 2)
        self.assertIn("kaboom", closed["error"])

    def test_the_run_error_is_truncated_before_it_reaches_the_column(self):
        db = FakePostgrest(fault=fault_on("POST", "slots", 400, "x" * 3000))
        w = a_writer(db)
        w.SLOT_CHUNK = 1
        w.write(a_payload(
            slots=[a_slot("woollahra", D1, "07%02d" % n) for n in range(3)],
            days=[a_day("woollahra", D1, slot_count=3)],
        ))

        error = db.of("PATCH", "scrape_runs")[0].body["error"]
        self.assertLessEqual(len(error), 4000)
        self.assertEqual(len(db.of("POST", "slots")), 3, "every chunk still attempted")


class HealthRowsAndErrors(unittest.TestCase):

    def test_a_clubs_error_page_is_truncated_before_it_reaches_the_column(self):
        """MiClub answers a bad request with a full HTML page. Pasting 40 KB of
        it into course_day_scrapes.error is how one broken course makes the
        stale-data banner query slow for all fifteen."""
        db = FakePostgrest()
        a_writer(db).write(a_payload(
            days=[a_day("bexley", D1, ok=False, error="<html>" + "e" * 5000)],
        ))

        row = db.bodies("POST", "course_day_scrapes")[0]
        self.assertLessEqual(len(row["error"]), 2000)
        self.assertTrue(row["error"].endswith("…"), "cut, and visibly cut")

    def test_no_error_anywhere_carries_the_service_role_key(self):
        """Every one of these strings ends up in a GitHub Actions log."""
        db = FakePostgrest(fault=fault_on("POST", "slots", 401, '{"message":"JWT expired"}'))
        result = a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1, slot_count=1)],
        ))

        blob = json.dumps([result.errors, db.of("PATCH", "scrape_runs")[0].body])
        self.assertNotIn(KEY, blob)
        self.assertNotIn("Bearer", blob)
        self.assertIn("JWT expired", blob, "the useful part is still there")


class OneRunOneTimestamp(unittest.TestCase):

    def test_every_row_in_a_run_shares_the_instant_the_scrape_saw_them(self):
        """last_seen_at drives the freshness banner and, one ticket over, the
        alert matcher. Per-row now() means rows from the same scrape disagree
        about when the scrape was, and a diff on that timestamp stops meaning
        anything."""
        ticks = ["t{}".format(n) for n in range(1, 20)]
        with mock.patch.object(supabase_writer, "_now_iso", side_effect=ticks):
            db = FakePostgrest()
            w = a_writer(db)
            w.SLOT_CHUNK = 1
            result = w.write(a_payload(
                slots=[a_slot("woollahra", D1, "0700"), a_slot("woollahra", D1, "0708")],
                days=[a_day("woollahra", D1, slot_count=2, last_attempt_at=None,
                            last_success_at=None)],
                generated_at=None,
            ))

        self.assertEqual(
            sorted({r["last_seen_at"] for r in db.bodies("POST", "slots")}), ["t1"])
        day_row = db.bodies("POST", "course_day_scrapes")[0]
        self.assertEqual(day_row["last_attempt_at"], "t1")
        self.assertEqual(day_row["last_success_at"], "t1")
        self.assertEqual(db.of("POST", "scrape_runs")[0].body["started_at"], "t1")
        # And the clock really was ticking: finishing is a later instant.
        self.assertEqual(db.of("PATCH", "scrape_runs")[0].body["finished_at"], "t2")
        self.assertEqual(result.slots_upserted, 2)


class DryRunTouchesNothing(unittest.TestCase):

    def test_a_dry_run_never_reaches_for_a_session(self):
        """`--write supabase --dry-run` has to work on a laptop with no
        service role key and, on a runner, before requests is installed. A
        session built eagerly in __init__ is a network client one typo away
        from a real write."""
        def explode(self):  # pragma: no cover - the assertion is that it is not called
            raise AssertionError("a dry run must not build a session")

        with mock.patch.object(SupabaseWriter, "session", property(explode)):
            with mock.patch.dict("os.environ", {}, clear=True):
                w = SupabaseWriter.from_env(dry_run=True)
                result = w.write(a_payload(
                    slots=[a_slot("woollahra", D1, "0700")],
                    days=[a_day("woollahra", D1, slot_count=1)],
                ))

        self.assertEqual(result.slots_upserted, 1)
        self.assertEqual(result.slots_closed, 0, "closing needs a database to ask")
        self.assertIsNone(result.run_id)


class StayingInsideTheTicket(unittest.TestCase):

    def test_the_frozen_course_roster_is_never_written(self):
        """courses.json is frozen at 15 and seeded by migration 0005. A writer
        that syncs it is one bad scrape away from renaming or deactivating a
        course, and slots cascade on delete from courses."""
        db = FakePostgrest()
        a_writer(db).write(a_payload(
            slots=[a_slot("woollahra", D1, "0700")],
            days=[a_day("woollahra", D1, slot_count=1)],
            courses=[{"slug": "woollahra", "name": "Woollahra Golf Club", "active": True}],
        ))

        self.assertEqual([c.table for c in db.calls if c.table == "courses"], [])
        self.assertEqual(sorted({c.table for c in db.calls}),
                         ["course_day_scrapes", "scrape_runs", "slots"])


if __name__ == "__main__":
    unittest.main()
