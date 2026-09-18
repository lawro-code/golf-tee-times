"""Assembling the contract payload from scraped results.

The payload is built here rather than by transform.build_payload, so these
tests are what stop the per-day truth being flattened back into a per-course
guess — and what prove the awkward live cases from CONTRACT.md still come out
right: two-tee starts, 9-hole bookings on 18-hole courses, unpriced slots.
"""

import contextlib
import io
import json
import unittest
from datetime import date
from pathlib import Path

from contract import transform
from contract.validate import validate

import scrape

ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURES = ROOT / "contract" / "fixtures"

ROSTER = scrape.load_roster()
BY_SLUG = {c["slug"]: c for c in ROSTER}

DAY_ONE = "2026-09-18"
DAY_TWO = "2026-09-19"


def raw_slot(slug, tee_date, time_text, booking_type="Public Play", tiers=None,
             available=2, total=4, booking_url=None):
    course = BY_SLUG[slug]
    url = booking_url or scrape.timesheet_url(
        scrape.course_host(course), course["feeGroupId"], date.fromisoformat(tee_date)
    )
    return {
        "date": tee_date,
        "time": time_text,
        "spots_available": available,
        "total_spots": total,
        "price_tiers": [{"label": label, "amount": amount} for label, amount in (tiers or [])],
        "booking_type": booking_type,
        "booking_url": url,
    }


def course_result(slug, slots, day_records=None):
    course = BY_SLUG[slug]
    if day_records is None:
        counts = {}
        for s in slots:
            counts[s["date"]] = counts.get(s["date"], 0) + 1
        day_records = [scrape.day_record(d, True, slot_count=n) for d, n in sorted(counts.items())]
    failed = [d for d in day_records if not d["ok"]]
    return {
        "slug": slug, "name": course["name"], "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"), "par": course.get("par"), "notes": course.get("notes", ""),
        "host": scrape.course_host(course),
        "error": scrape._course_error(day_records, len(day_records)) if failed else None,
        "days": day_records, "slots": slots,
    }


def build(results, **kwargs):
    kwargs.setdefault("mode", "fast")
    kwargs.setdefault("days", 3)
    kwargs.setdefault("generated_at", "2026-09-18T05:00:00+10:00")
    with contextlib.redirect_stderr(io.StringIO()):
        return scrape.payload_from_results(results, ROSTER, **kwargs)


class SlotShapeTests(unittest.TestCase):
    def test_a_nine_hole_booking_on_an_eighteen_hole_course_is_nine_holes(self):
        """Bankstown is an 18-hole course selling 9-hole tee times."""
        payload = build([course_result("bankstown", [
            raw_slot("bankstown", DAY_ONE, "07:00", "Social Play 9 Holes Only", [("Social 9 Holes", 25.0)]),
            raw_slot("bankstown", DAY_ONE, "07:08", "Social Play", [("Social 18 Holes", 42.0)]),
            raw_slot("bankstown", DAY_ONE, "07:16", "Social Play", [("Midweek 9 Holes (Non-Refundable)", 25.0)]),
        ])])
        by_time = {s["tee_time"]: s for s in payload["slots"]}
        self.assertEqual(BY_SLUG["bankstown"]["holes"], 18)
        self.assertEqual(by_time["07:00:00"]["holes"], 9, "booking type says 9 holes")
        self.assertEqual(by_time["07:08:00"]["holes"], 18)
        self.assertEqual(by_time["07:16:00"]["holes"], 9, "the fee label says 9 holes")
        self.assertEqual(payload["slots"][0]["par"], BY_SLUG["bankstown"]["par"])
        self.assertEqual(validate(payload), [])

    def test_an_unpriced_slot_keeps_null_bounds_and_no_tiers(self):
        payload = build([course_result("warringah", [
            raw_slot("warringah", DAY_ONE, "06:16", "1st Tee Social"),
        ])])
        slot = payload["slots"][0]
        self.assertIsNone(slot["price_min"])
        self.assertIsNone(slot["price_max"])
        self.assertEqual(slot["price_tiers"], [])
        self.assertEqual(validate(payload), [])

    def test_a_priced_slot_takes_its_bounds_from_the_tiers(self):
        payload = build([course_result("woollahra", [
            raw_slot("woollahra", DAY_ONE, "16:05", "Public Play",
                     [("Midweek 2024", 39.0), ("Twilight", 26.0), ("Member Guest", 31.5)]),
        ])])
        slot = payload["slots"][0]
        self.assertEqual(slot["price_min"], 26.0)
        self.assertEqual(slot["price_max"], 39.0)
        self.assertEqual(len(slot["price_tiers"]), 3)
        self.assertEqual(validate(payload), [])

    def test_a_two_tee_start_at_the_same_minute_is_two_slots(self):
        """Warringah sends a 1st Tee and a 10th Tee group out at 6:16."""
        payload = build([course_result("warringah", [
            raw_slot("warringah", DAY_ONE, "06:16", "1st Tee Social"),
            raw_slot("warringah", DAY_ONE, "06:16", "10th Tee Social"),
        ])])
        ids = [s["id"] for s in payload["slots"]]
        self.assertEqual(len(ids), 2)
        self.assertEqual(len(set(ids)), 2, "the tee is what separates them")
        self.assertIn(f"warringah:{DAY_ONE}:0616:1st-tee-social", ids)
        self.assertIn(f"warringah:{DAY_ONE}:0616:10th-tee-social", ids)
        self.assertEqual(validate(payload), [])

    def test_a_genuine_duplicate_keeps_the_row_with_more_spots(self):
        payload = build([course_result("woollahra", [
            raw_slot("woollahra", DAY_ONE, "07:00", "Public Play", available=2),
            raw_slot("woollahra", DAY_ONE, "07:00", "Public Play", available=4),
        ])])
        self.assertEqual(len(payload["slots"]), 1)
        self.assertEqual(payload["slots"][0]["spots_available"], 4)


class CourseDayTests(unittest.TestCase):
    def test_every_requested_day_gets_a_row_including_empty_and_failed_ones(self):
        records = [
            scrape.day_record(DAY_ONE, True, slot_count=1),
            scrape.day_record(DAY_TWO, True, slot_count=0),
            scrape.day_record("2026-09-20", False, error="http 500"),
        ]
        payload = build([course_result(
            "long-reef", [raw_slot("long-reef", DAY_ONE, "07:00")], day_records=records,
        )])

        rows = [d for d in payload["course_days"] if d["course_slug"] == "long-reef"]
        self.assertEqual([d["tee_date"] for d in rows], [DAY_ONE, DAY_TWO, "2026-09-20"])
        self.assertEqual([d["ok"] for d in rows], [True, True, False])
        self.assertEqual([d["slot_count"] for d in rows], [1, 0, 0])

        reached_but_empty = rows[1]
        self.assertTrue(reached_but_empty["ok"], "zero free tee times is not a failure")
        self.assertIsNone(reached_but_empty["error"])

        failed = rows[2]
        self.assertEqual(failed["error"], "http 500")
        self.assertIsNone(failed["last_success_at"])
        self.assertIsNotNone(failed["last_attempt_at"])
        self.assertEqual(validate(payload), [])

    def test_a_partly_failing_course_reports_per_day_not_all_or_nothing(self):
        records = [
            scrape.day_record(DAY_ONE, True, slot_count=1),
            scrape.day_record(DAY_TWO, False, error="connection timed out"),
        ]
        result = course_result("bexley", [raw_slot("bexley", DAY_ONE, "09:00")], day_records=records)
        payload = build([result])

        rows = [d for d in payload["course_days"] if d["course_slug"] == "bexley"]
        self.assertEqual([d["ok"] for d in rows], [True, False])
        # The course-level error is pessimistic on purpose, and names the day.
        self.assertIsNotNone(result["error"])
        self.assertIn(DAY_TWO, result["error"])
        self.assertEqual(validate(payload), [])

    def test_slot_count_never_disagrees_with_the_slots_in_the_payload(self):
        payload = build([course_result("woollahra", [
            raw_slot("woollahra", DAY_ONE, "07:00"),
            raw_slot("woollahra", DAY_ONE, "07:08"),
            raw_slot("woollahra", DAY_TWO, "07:00"),
        ])])
        counted = {}
        for slot in payload["slots"]:
            counted[slot["tee_date"]] = counted.get(slot["tee_date"], 0) + 1
        for row in payload["course_days"]:
            self.assertEqual(row["slot_count"], counted.get(row["tee_date"], 0))

    def test_a_course_not_on_the_frozen_roster_is_dropped(self):
        stray = course_result("woollahra", [raw_slot("woollahra", DAY_ONE, "07:00")])
        stray["slug"] = "st-andrews"
        payload = build([stray])
        self.assertEqual(payload["slots"], [])
        self.assertEqual(payload["course_days"], [])
        self.assertEqual(len(payload["courses"]), 15)


class SchemaBoundsTests(unittest.TestCase):
    def test_out_of_bounds_rows_are_dropped_counted_and_the_rest_survive(self):
        slots = [
            raw_slot("woollahra", DAY_ONE, "07:00", available=2, total=4),          # fine
            raw_slot("woollahra", DAY_ONE, "07:08", available=9, total=12),         # too many spots
            raw_slot("woollahra", DAY_ONE, "07:16", available=5, total=4),          # more free than exist
            raw_slot("woollahra", DAY_ONE, "07:24", booking_url="http://woollahra.miclub.com.au/x"),
        ]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            payload = scrape.payload_from_results(
                [course_result("woollahra", slots)], ROSTER,
                mode="fast", days=3, generated_at="2026-09-18T05:00:00+10:00",
            )
        self.assertEqual(len(payload["slots"]), 1)
        self.assertEqual(payload["slots"][0]["tee_time"], "07:00:00")
        self.assertIn("dropped 3 slot(s)", err.getvalue())
        self.assertEqual(validate(payload), [], "one club's bad HTML must not fail the whole payload")

    def test_a_zero_spot_row_is_dropped_rather_than_published(self):
        payload = build([course_result("woollahra", [
            raw_slot("woollahra", DAY_ONE, "07:00", available=0, total=4),
        ])])
        self.assertEqual(payload["slots"], [])


class LiveFixtureTests(unittest.TestCase):
    """The real 15-course, 5-day scrape golden.json was built from."""

    @classmethod
    def setUpClass(cls):
        cls.raw = json.loads((FIXTURES / "raw_live.json").read_text())
        with contextlib.redirect_stderr(io.StringIO()):
            cls.payload = scrape.payload_from_results(
                cls.raw["courses"], ROSTER, mode="full",
                days=cls.raw["lookahead_days"], generated_at=cls.raw["generated_at"],
            )

    def test_the_assembled_payload_is_contract_clean(self):
        problems = validate(self.payload)
        self.assertEqual(problems, [], "\n".join(problems[:20]))

    def test_it_holds_the_same_slots_the_golden_fixture_does(self):
        golden = json.loads((FIXTURES / "golden.json").read_text())
        self.assertEqual(
            [s["id"] for s in self.payload["slots"]],
            [s["id"] for s in golden["slots"]],
        )

    def test_every_course_and_day_is_accounted_for(self):
        pairs = {(d["course_slug"], d["tee_date"]) for d in self.payload["course_days"]}
        self.assertEqual(len(pairs), len(self.payload["course_days"]), "no duplicate course-day rows")
        self.assertEqual(len(pairs), 15 * 5, "15 courses x 5 days, including the day nothing was free")
        long_reef = [d for d in self.payload["course_days"] if d["course_slug"] == "long-reef"]
        self.assertEqual(len(long_reef), 5)
        self.assertTrue(all(d["ok"] and d["slot_count"] == 0 for d in long_reef),
                        "Long Reef scraped perfectly and had nothing free")

    def test_nine_hole_bookings_survive_the_round_trip(self):
        nine = [s for s in self.payload["slots"] if s["holes"] == 9]
        on_eighteen_hole_courses = [
            s for s in nine if BY_SLUG[s["course_slug"]]["holes"] == 18
        ]
        self.assertEqual(len(on_eighteen_hole_courses), 125)
        self.assertEqual(
            {s["course_slug"] for s in on_eighteen_hole_courses},
            {"bankstown", "beverley-park", "brighton-lakes"},
        )

    def test_unpriced_slots_are_kept_not_dropped(self):
        unpriced = [s for s in self.payload["slots"] if s["price_min"] is None]
        self.assertEqual(len(unpriced), 282)
        self.assertTrue(all(s["price_tiers"] == [] and s["price_max"] is None for s in unpriced))


# ==========================================================================
# A1 verification (tester)
#
# Before this ticket there was no payload assembly in the scraper at all:
# transform.build_payload was the only path, and it copies a course-level
# error onto every day. Each test below fails against the pre-ticket scraper
# and passes now; the first one runs the same scrape through both paths so the
# difference is stated rather than asserted.
# ==========================================================================

def legacy_raw(results, generated_at="2026-09-18T05:00:00+10:00", days=3):
    """The raw shape transform.build_payload consumes — the pre-ticket path."""
    return {"generated_at": generated_at, "lookahead_days": days, "courses": results}


class PerDayTruthSurvivesAssemblyTests(unittest.TestCase):
    def test_the_frozen_build_payload_flattens_a_partly_failed_course_and_this_one_does_not(self):
        records = [
            scrape.day_record(DAY_ONE, True, slot_count=1),
            scrape.day_record(DAY_TWO, False, error="http 500"),
        ]
        result = course_result("bexley", [raw_slot("bexley", DAY_ONE, "09:00")], day_records=records)

        payload = build([result])
        rows = [d for d in payload["course_days"] if d["course_slug"] == "bexley"]
        self.assertEqual([(d["tee_date"], d["ok"]) for d in rows], [(DAY_ONE, True), (DAY_TWO, False)])
        self.assertIsNone(rows[0]["error"], "the day we reached carries no error")
        self.assertEqual(rows[1]["error"], "http 500")
        self.assertIsNotNone(rows[0]["last_success_at"])
        self.assertIsNone(rows[1]["last_success_at"])
        self.assertEqual(validate(payload), [])

        # The same scrape down the old path, for the record.
        legacy = transform.build_payload(legacy_raw([result]), ROSTER, mode="fast")
        legacy_rows = [(d["tee_date"], d["ok"]) for d in legacy["course_days"] if d["course_slug"] == "bexley"]
        self.assertEqual(legacy_rows, [(DAY_ONE, False)],
                         "the old path failed the day that scraped fine and lost the day that did not")

    def test_a_day_reached_with_nothing_free_is_not_an_error_even_when_another_day_failed(self):
        records = [
            scrape.day_record(DAY_ONE, True, slot_count=0),
            scrape.day_record(DAY_TWO, False, error="connection timed out"),
        ]
        payload = build([course_result("long-reef", [], day_records=records)])

        rows = [d for d in payload["course_days"] if d["course_slug"] == "long-reef"]
        self.assertEqual(
            [(d["ok"], d["slot_count"], d["error"]) for d in rows],
            [(True, 0, None), (False, 0, "connection timed out")],
            "an empty course and an unreachable one must not render the same way",
        )
        self.assertEqual(validate(payload), [])

    def test_one_courses_total_failure_leaves_another_courses_days_alone(self):
        dead = course_result("warringah", [], day_records=[
            scrape.day_record(DAY_ONE, False, error="http 502"),
            scrape.day_record(DAY_TWO, False, error="http 502"),
        ])
        alive = course_result("woollahra", [
            raw_slot("woollahra", DAY_ONE, "07:00"),
            raw_slot("woollahra", DAY_TWO, "07:00"),
        ])
        payload = build([dead, alive])

        by_slug = {}
        for row in payload["course_days"]:
            by_slug.setdefault(row["course_slug"], []).append(row)
        self.assertEqual([r["ok"] for r in by_slug["warringah"]], [False, False])
        self.assertEqual([r["ok"] for r in by_slug["woollahra"]], [True, True])
        self.assertTrue(all(r["error"] is None for r in by_slug["woollahra"]))
        self.assertEqual({s["course_slug"] for s in payload["slots"]}, {"woollahra"})
        self.assertEqual(validate(payload), [])


class RosterIsTheSourceOfTruthTests(unittest.TestCase):
    def test_par_and_holes_come_from_the_roster_not_the_scraped_course_dict(self):
        """Clause 4: slot_row is handed the courses.json entry. A scrape that
        disagrees with the frozen roster does not get to publish its version."""
        result = course_result("bankstown", [
            raw_slot("bankstown", DAY_ONE, "07:00", "Social Play", [("Social", 42.0)]),
        ])
        result["holes"], result["par"] = 9, 99

        payload = build([result])
        slot = payload["slots"][0]
        self.assertEqual(BY_SLUG["bankstown"]["holes"], 18)
        self.assertEqual(slot["holes"], 18, "no 9-hole wording anywhere, so the roster's hole count stands")
        self.assertEqual(slot["par"], BY_SLUG["bankstown"]["par"])
        self.assertNotEqual(slot["par"], 99)
        self.assertEqual(validate(payload), [])


class DroppedRowTests(unittest.TestCase):
    """One club's changed HTML must cost that club's row, not the run."""

    def test_an_unparseable_slot_is_dropped_by_name_and_the_rest_of_the_course_survives(self):
        good = raw_slot("woollahra", DAY_ONE, "07:00")
        broken = raw_slot("woollahra", DAY_ONE, "07:08")
        del broken["time"]

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            payload = scrape.payload_from_results(
                [course_result("woollahra", [good, broken])], ROSTER,
                mode="fast", days=3, generated_at="2026-09-18T05:00:00+10:00",
            )

        self.assertEqual(len(payload["slots"]), 1)
        self.assertEqual(payload["slots"][0]["tee_time"], "07:00:00")
        self.assertIn("woollahra", err.getvalue())
        self.assertIn("unparseable slot", err.getvalue())
        self.assertIn("KeyError", err.getvalue(), "the reason is named, not swallowed")
        self.assertEqual(validate(payload), [])

    def test_a_boolean_where_a_spot_count_should_be_is_not_an_integer(self):
        problem = scrape.schema_problem({
            "spots_available": True, "total_spots": 4,
            "booking_url": "https://woollahra.miclub.com.au/x",
        })
        self.assertIsNotNone(problem)
        self.assertIn("spots_available", problem)

        slot = raw_slot("woollahra", DAY_ONE, "07:00")
        slot["spots_available"] = True
        payload = build([course_result("woollahra", [slot])])
        self.assertEqual(payload["slots"], [], "a boolean is not a spot count, whatever Python thinks")

    def test_the_drop_rule_uses_the_frozen_schemas_own_bounds(self):
        """If the schema tightens and this rule does not, a row it would reject
        sails through and fails the whole payload instead of just itself."""
        schema = json.loads((FIXTURES.parent / "payload.schema.json").read_text())
        spots = schema["$defs"]["slot"]["properties"]["spots_available"]
        self.assertEqual((scrape.MIN_SPOTS, scrape.MAX_SPOTS), (spots["minimum"], spots["maximum"]))
        self.assertTrue(
            schema["$defs"]["slot"]["properties"]["booking_url"]["pattern"].startswith("^https://"))

    def test_course_day_slot_count_counts_survivors_not_what_the_scrape_claimed(self):
        slots = [
            raw_slot("woollahra", DAY_ONE, "07:00"),
            raw_slot("woollahra", DAY_ONE, "07:08"),
            raw_slot("woollahra", DAY_ONE, "07:16", available=9, total=12),
            raw_slot("woollahra", DAY_ONE, "07:24", booking_url="http://woollahra.miclub.com.au/x"),
        ]
        records = [scrape.day_record(DAY_ONE, True, slot_count=4)]  # what the scrape thought it found
        payload = build([course_result("woollahra", slots, day_records=records)])

        row = [d for d in payload["course_days"] if d["course_slug"] == "woollahra"][0]
        self.assertEqual(len(payload["slots"]), 2)
        self.assertEqual(row["slot_count"], 2, "course_days and slots can never disagree")
        self.assertEqual(validate(payload), [])


if __name__ == "__main__":
    unittest.main()
