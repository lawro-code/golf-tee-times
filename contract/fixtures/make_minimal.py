"""Build contract/fixtures/minimal.json — the deterministic edge-case fixture.

golden.json is a real 15-course scrape: realistic, large, and it changes every
time it is refreshed. minimal.json is the opposite — small, fixed, and shaped
so that every awkward case the live data actually contains has exactly one
example in it. Unit tests assert against this; UI and scroll work uses golden.

Run: python3 contract/fixtures/make_minimal.py
"""
from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from contract import transform  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
ROSTER = json.loads((ROOT / "courses.json").read_text())["courses"]

URL = "https://{host}/guests/bookings/ViewPublicTimesheet.msp?bookingResourceId=3000000&feeGroupId={fee}&selectedDate={d}"


def u(slug: str, d: str) -> str:
    c = next(c for c in ROSTER if c["slug"] == slug)
    return URL.format(host=c.get("host") or f"{slug}.miclub.com.au", fee=c["feeGroupId"], d=d)


def slot(d, t, avail, total, tiers, btype, slug):
    return {
        "date": d, "time": t, "spots_available": avail, "total_spots": total,
        "price_tiers": tiers, "booking_type": btype, "booking_url": u(slug, d),
    }


# Dates chosen deliberately. 2026-10-03 is the Saturday before Sydney puts the
# clocks forward; 2026-10-04 is the changeover day itself. A decoder that gets
# the offset from the wrong place will disagree on exactly one of these two.
BEFORE_DST = "2026-10-03"
ON_DST = "2026-10-04"
AFTER_DST = "2026-10-10"

COURSES = {
    # 9-hole course, one price tier, nearly full.
    "woollahra": [
        slot(BEFORE_DST, "07:12", 1, 4, [{"label": "Weekend 2024", "amount": 45.0}], "Public Play", "woollahra"),
        slot(ON_DST, "16:30", 4, 4, [{"label": "Twilight", "amount": 25.0}], "Public Bookings", "woollahra"),
    ],
    # Two-tee start: the same minute on two tees is two bookings, not one.
    "warringah": [
        slot(BEFORE_DST, "06:16", 2, 4, [], "1st Tee Social", "warringah"),
        slot(BEFORE_DST, "06:16", 4, 4, [], "10th Tee Social", "warringah"),
    ],
    # 18-hole course selling a 9-hole tee time — the hole count lives in the
    # fee label, not in courses.json.
    "bankstown": [
        slot(BEFORE_DST, "11:20", 3, 4, [{"label": "Weekend", "amount": 32.0}], "Social Play 9 Holes Only", "bankstown"),
        slot(AFTER_DST, "08:00", 4, 4, [{"label": "Weekend", "amount": 58.0}], "Social Play", "bankstown"),
    ],
    # Three price tiers, including the longest labels the live data carries.
    "the-coast": [
        slot(BEFORE_DST, "08:00", 4, 4, [
            {"label": "Adult", "amount": 110.0},
            {"label": "Junior (U18 Only) - Proof of Age Required on Arrival", "amount": 55.0},
            {"label": "Senior Mid-Week 18 Holes", "amount": 88.0},
        ], "1st Tee", "the-coast"),
    ],
    # Needs a free public-member account before checkout.
    "bayview": [
        slot(ON_DST, "09:45", 2, 4, [{"label": "Adult (Weekend)", "amount": 70.0}], "1st Tee - Social Play", "bayview"),
    ],
    # Longest course name on the roster — the layout case.
    "brighton-lakes": [
        slot(AFTER_DST, "13:07", 1, 4, [{"label": "Social 9 Holes Weekend - Online Rate", "amount": 30.0}], "1st Tee Social", "brighton-lakes"),
    ],
    # A course that scraped fine and simply has nothing free.
    "long-reef": [],
}

# A course that failed outright. One club being down must not blank the other
# fourteen, so the fixture carries a failure that the UI has to render.
ERRORS = {"castle-cove": "all 2 day(s) failed to scrape"}

raw_courses = []
for c in ROSTER:
    slug = c["slug"]
    if slug not in COURSES and slug not in ERRORS:
        continue
    raw_courses.append({
        "slug": slug,
        "name": c["name"],
        "region": c.get("region", ""),
        "drive_minutes_from_bondi": c.get("drive_minutes_from_bondi"),
        "holes": c["holes"],
        "notes": c.get("notes", ""),
        "host": c.get("host") or f"{slug}.miclub.com.au",
        "error": ERRORS.get(slug),
        "slots": COURSES.get(slug, []),
    })

raw = {
    "generated_at": "2026-10-01T07:30:00+10:00",  # fixed: this fixture is deterministic
    "lookahead_days": 5,
    "courses": raw_courses,
}

payload = transform.build_payload(raw, ROSTER, mode="full")
out = ROOT / "contract" / "fixtures" / "minimal.json"
out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
print(f"wrote {out} — {len(payload['slots'])} slots, {len(payload['course_days'])} course-days")
for s in payload["slots"]:
    print(f"  {s['id']:<52} {s['tee_at']}  {s['holes']}h  {s['price_min']}")
