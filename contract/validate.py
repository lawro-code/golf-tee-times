"""Validate a payload against the frozen data contract.

Exit 0 means the payload is contract-clean. Exit 1 means it is not, and every
violation is printed with its path. No third-party dependencies on purpose:
this runs in CI, in the scraper's --validate, and on a laptop with nothing
installed but Python.

    python3 contract/validate.py contract/fixtures/golden.json
    python3 contract/validate.py --live            # scrape 2 courses and check
    python3 contract/validate.py --live --all      # scrape all 15 and check

Two layers of checking:

  1. Structure, walked from contract/payload.schema.json — types, required
     keys, unexpected keys, patterns, bounds.
  2. Semantics, which JSON Schema cannot express — the slot id matching its own
     course/date/time, tee_at agreeing with the Sydney timezone rule, price
     bounds agreeing with the tiers, every slot pointing at a course on the
     roster, no duplicate ids.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from contract import transform  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "contract" / "payload.schema.json"

JSON_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "integer": int,
    "number": (int, float),
    "null": type(None),
}


class Problems(list):
    def add(self, path: str, message: str) -> None:
        self.append(f"{path or '$'}: {message}")


def _type_ok(value: Any, expected: str) -> bool:
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    return isinstance(value, JSON_TYPES[expected])


def check_structure(value: Any, schema: dict, defs: dict, path: str, problems: Problems) -> None:
    if "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        check_structure(value, defs[name], defs, path, problems)
        return

    if "const" in schema and value != schema["const"]:
        problems.add(path, f"expected {schema['const']!r}, got {value!r}")
        return

    if "enum" in schema and value not in schema["enum"]:
        problems.add(path, f"expected one of {schema['enum']!r}, got {value!r}")
        return

    if "type" in schema:
        expected = schema["type"]
        options = expected if isinstance(expected, list) else [expected]
        if not any(_type_ok(value, o) for o in options):
            problems.add(path, f"expected type {'|'.join(options)}, got {type(value).__name__}")
            return

    if value is None:
        return

    if isinstance(value, str):
        pattern = schema.get("pattern")
        if pattern and not re.match(pattern, value):
            problems.add(path, f"{value!r} does not match {pattern}")
        if "minLength" in schema and len(value) < schema["minLength"]:
            problems.add(path, f"{value!r} is shorter than {schema['minLength']}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.add(path, f"{value} is below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            problems.add(path, f"{value} is above maximum {schema['maximum']}")

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.add(path, f"missing required key {key!r}")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    problems.add(path, f"unexpected key {key!r}")
        for key, sub in props.items():
            if key in value:
                check_structure(value[key], sub, defs, f"{path}.{key}", problems)

    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            check_structure(item, schema["items"], defs, f"{path}[{i}]", problems)


def check_semantics(payload: dict, problems: Problems) -> None:
    roster = {c["slug"] for c in payload.get("courses", [])}
    course_by_slug = {c["slug"]: c for c in payload.get("courses", [])}

    if len(roster) != len(payload.get("courses", [])):
        problems.add("$.courses", "duplicate course slugs")

    seen: dict[str, int] = {}
    for i, slot in enumerate(payload.get("slots", [])):
        path = f"$.slots[{i}]"
        slug = slot.get("course_slug")

        if slug not in roster:
            problems.add(path, f"course_slug {slug!r} is not on the roster")
            continue

        booking_type = slot.get("booking_type", "") or ""
        expected_id = transform.slot_id(slug, slot.get("tee_date", ""), slot.get("tee_time", "00:00:00"), booking_type)
        if slot.get("id") != expected_id:
            problems.add(path, f"id {slot.get('id')!r} does not match its course/date/time (expected {expected_id!r})")

        if slot.get("id") in seen:
            problems.add(path, f"duplicate slot id {slot.get('id')!r}, first seen at index {seen[slot['id']]}")
        else:
            seen[slot["id"]] = i

        expected_tee_at = transform.tee_at(slot.get("tee_date", ""), slot.get("tee_time", "00:00:00"))
        if slot.get("tee_at") != expected_tee_at:
            problems.add(path, f"tee_at {slot.get('tee_at')!r} disagrees with the Australia/Sydney rule (expected {expected_tee_at!r})")

        if slot.get("spots_available", 0) > slot.get("total_spots", 0):
            problems.add(path, "spots_available exceeds total_spots")

        tiers = slot.get("price_tiers") or []
        amounts = [t["amount"] for t in tiers if isinstance(t, dict) and "amount" in t]
        if amounts:
            if slot.get("price_min") != min(amounts):
                problems.add(path, f"price_min {slot.get('price_min')} is not the cheapest tier {min(amounts)}")
            if slot.get("price_max") != max(amounts):
                problems.add(path, f"price_max {slot.get('price_max')} is not the dearest tier {max(amounts)}")
        elif slot.get("price_min") is not None or slot.get("price_max") is not None:
            problems.add(path, "price bounds are set but there are no price tiers")

        course = course_by_slug.get(slug, {})
        for field in ("course_name", "region", "par", "drive_minutes_from_bondi", "requires_registration"):
            course_field = "name" if field == "course_name" else field
            if field in slot and course.get(course_field) != slot[field]:
                problems.add(path, f"{field} disagrees with the course row ({slot[field]!r} vs {course.get(course_field)!r})")
        tier_labels = [t["label"] for t in tiers if isinstance(t, dict) and "label" in t]
        expected_holes = transform.holes_for_slot(course.get("holes", 18), booking_type, tier_labels)
        if slot.get("holes") != expected_holes:
            problems.add(path, f"holes {slot.get('holes')!r} disagrees with what the booking type and fee labels say ({expected_holes})")

        if slug not in slot.get("booking_url", "") and course.get("host", "") not in slot.get("booking_url", ""):
            problems.add(path, "booking_url does not point at this course's host")

    for i, day in enumerate(payload.get("course_days", [])):
        path = f"$.course_days[{i}]"
        if day.get("course_slug") not in roster:
            problems.add(path, f"course_slug {day.get('course_slug')!r} is not on the roster")
        if day.get("ok") and day.get("error") is not None:
            problems.add(path, "a day marked ok also carries an error")
        if not day.get("ok") and day.get("last_success_at") is not None:
            problems.add(path, "a failed day claims a successful scrape time")


def validate(payload: dict) -> Problems:
    schema = json.loads(SCHEMA_PATH.read_text())
    problems = Problems()
    check_structure(payload, schema, schema.get("$defs", {}), "$", problems)
    if not problems:
        check_semantics(payload, problems)
    return problems


def live_payload(all_courses: bool, days: int) -> dict:
    """Scrape for real and shape the result. Used by --live."""
    sys.path.insert(0, str(ROOT / "scraper"))
    import scrape  # noqa: E402

    roster = json.loads((ROOT / "courses.json").read_text())["courses"]
    chosen = roster if all_courses else roster[:2]
    results = [scrape.scrape_course(c, days) for c in chosen]
    raw = {
        "generated_at": transform.datetime.now(transform.SYDNEY).isoformat(timespec="seconds"),
        "lookahead_days": days,
        "courses": results,
    }
    return transform.build_payload(raw, roster, mode="full" if days > 3 else "fast")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("payload", nargs="?", help="Path to a contract payload JSON file")
    ap.add_argument("--live", action="store_true", help="Scrape live and validate the result")
    ap.add_argument("--all", action="store_true", help="With --live, scrape all 15 courses")
    ap.add_argument("--days", type=int, default=2)
    args = ap.parse_args()

    if args.live:
        payload = live_payload(args.all, args.days)
        source = f"live scrape ({'all 15' if args.all else 'first 2'} courses, {args.days} days)"
    elif args.payload:
        payload = json.loads(pathlib.Path(args.payload).read_text())
        source = args.payload
    else:
        ap.error("give a payload path or --live")
        return 2

    problems = validate(payload)
    counts = (len(payload.get("courses", [])), len(payload.get("slots", [])), len(payload.get("course_days", [])))
    print(f"contract {payload.get('contract_version')} — {source}")
    print(f"  {counts[0]} courses, {counts[1]} slots, {counts[2]} course-days")

    if problems:
        print(f"\n{len(problems)} contract violation(s):")
        for p in problems[:50]:
            print(f"  {p}")
        if len(problems) > 50:
            print(f"  ... and {len(problems) - 50} more")
        return 1

    print("\nCONTRACT OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
