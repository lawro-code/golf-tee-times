"""Turn a raw scrape into the frozen contract payload.

The raw scrape shape (what scraper/scrape.py has always produced) and the
contract shape (what Supabase stores and the app decodes) are deliberately
different. This module is the ONE place the two are reconciled, so the
timezone rule and the slot-id rule exist exactly once.

Stage 0 owns this file. Track A imports it; it does not reimplement it.
"""

from __future__ import annotations

import pathlib
import re
from datetime import datetime
from typing import Optional
from zoneinfo import ZoneInfo

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTRACT_VERSION = (ROOT / "contract" / "VERSION").read_text().strip()

SYDNEY = ZoneInfo("Australia/Sydney")

# Clubs that make you create a free public-member account before checkout.
REQUIRES_REGISTRATION = {"bayview"}


_NON_SLUG = re.compile(r"[^a-z0-9]+")
_NINE = re.compile(r"\b9\s*hole", re.I)
_EIGHTEEN = re.compile(r"\b18\s*hole", re.I)


def tee_slug(booking_type: str) -> str:
    """Normalise a MiClub booking type into an id-safe token.

    Clubs are not consistent about case ('1ST TEE' and '1st Tee' are the same
    tee), so this lowercases. An unlabelled row becomes 'default'.
    """
    token = _NON_SLUG.sub("-", (booking_type or "").strip().lower()).strip("-")
    return token or "default"


def slot_id(course_slug: str, tee_date: str, tee_time: str, booking_type: str = "") -> str:
    """course_slug:YYYY-MM-DD:HHMM:tee — deterministic and stable across scrapes.

    Stability is the whole point: it is what lets alert_deliveries hold a
    unique (watch_id, slot_id) and turn twelve scrapes into one push.

    The tee segment is not decoration. Warringah and Bexley run two-tee starts:
    a 1st Tee and a 10th Tee group go out at the same minute and are two
    separate bookings. Keying on time alone silently halved Warringah's
    inventory on the live data this contract was built from.
    """
    hh, mm = tee_time.split(":")[:2]
    return f"{course_slug}:{tee_date}:{hh}{mm}:{tee_slug(booking_type)}"


def holes_for_slot(course_holes: int, booking_type: str, tier_labels: list[str]) -> int:
    """How many holes this particular booking is for.

    A course's hole count is not always the booking's. Bankstown, Beverley Park
    and Brighton Lakes are 18-hole courses that also sell 9-hole tee times, and
    the only place that is stated is the booking type or the fee label. Holes
    defaults to 18 in the app's filters, so getting this wrong shows a golfer
    9 holes when they asked for 18.
    """
    text = " ".join([booking_type or ""] + tier_labels)
    nine, eighteen = bool(_NINE.search(text)), bool(_EIGHTEEN.search(text))
    if nine and not eighteen:
        return 9
    if eighteen and not nine:
        return 18
    # Silent, or claims both — fall back to what the course is.
    return course_holes


def tee_at(tee_date: str, tee_time: str) -> str:
    """Resolve a local Sydney wall-clock tee time to an absolute instant.

    Sydney switches offset twice a year, which makes this the single most
    bug-prone line in the system, so it lives here and nowhere else.

    DST rules, stated so nobody has to guess:
      - April changeover (03:00 -> 02:00): 02:00-02:59 happens twice. We take
        the FIRST occurrence, the one still on AEDT (fold=0).
      - October changeover (02:00 -> 03:00): 02:00-02:59 does not exist. Python
        maps it forward by an hour. No course tees off then; the rule is
        written down so the behaviour is decided rather than discovered.
    """
    y, m, d = (int(x) for x in tee_date.split("-"))
    parts = [int(x) for x in tee_time.split(":")]
    hh, mm = parts[0], parts[1]
    local = datetime(y, m, d, hh, mm, tzinfo=SYDNEY, fold=0)
    return local.isoformat(timespec="seconds")


def normalise_time(tee_time: str) -> str:
    """'08:00' or '08:00:00' -> '08:00:00', matching PostgREST's time format."""
    parts = tee_time.split(":")
    return f"{int(parts[0]):02d}:{int(parts[1]):02d}:00"


def course_row(course: dict, sort_order: int) -> dict:
    host = course.get("host") or f"{course['slug']}.miclub.com.au"
    return {
        "slug": course["slug"],
        "name": course["name"],
        "region": course.get("region", ""),
        "host": host,
        "fee_group_id": str(course["feeGroupId"]),
        "holes": course["holes"],
        "par": course.get("par"),
        # MiClub does not publish course length. Null, deliberately.
        "length_metres": None,
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "requires_registration": course["slug"] in REQUIRES_REGISTRATION,
        "address": course.get("address"),
        "notes": course.get("notes", ""),
        "sort_order": sort_order,
    }


def _price_bounds(tiers: list[dict]) -> tuple[Optional[float], Optional[float]]:
    amounts = [t["amount"] for t in tiers if t.get("amount") is not None]
    if not amounts:
        return None, None
    return min(amounts), max(amounts)


def slot_row(raw_slot: dict, course: dict) -> dict:
    tee_time = normalise_time(raw_slot["time"])
    tiers = [
        {"label": t.get("label") or "Standard", "amount": float(t["amount"])}
        for t in raw_slot.get("price_tiers", [])
        if t.get("amount") is not None
    ]
    lo, hi = _price_bounds(tiers)
    booking_type = raw_slot.get("booking_type", "") or ""
    return {
        "id": slot_id(course["slug"], raw_slot["date"], tee_time, booking_type),
        "course_slug": course["slug"],
        "course_name": course["name"],
        "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "par": course.get("par"),
        "length_metres": None,
        "requires_registration": course["slug"] in REQUIRES_REGISTRATION,
        "tee_date": raw_slot["date"],
        "tee_time": tee_time,
        "tee_at": tee_at(raw_slot["date"], tee_time),
        "spots_available": raw_slot["spots_available"],
        "total_spots": raw_slot["total_spots"],
        "holes": holes_for_slot(course["holes"], booking_type, [t["label"] for t in tiers]),
        "price_min": lo,
        "price_max": hi,
        "price_tiers": tiers,
        "booking_type": booking_type,
        "booking_url": raw_slot["booking_url"],
    }


def build_payload(raw: dict, roster: list[dict], mode: str = "full") -> dict:
    """raw scrape output + courses.json roster -> contract payload."""
    by_slug = {c["slug"]: c for c in roster}
    order = {c["slug"]: i for i, c in enumerate(roster)}
    generated_at = raw.get("generated_at") or datetime.now(SYDNEY).isoformat(timespec="seconds")
    days = raw.get("lookahead_days", 5)

    slots: list[dict] = []
    course_days: list[dict] = []
    seen_ids: set[str] = set()

    for scraped in raw.get("courses", []):
        slug = scraped["slug"]
        course = by_slug.get(slug)
        if course is None:
            # A course in the scrape that is not on the frozen roster is
            # dropped rather than invented into existence.
            continue

        per_day: dict[str, list[dict]] = {}
        for raw_slot in scraped.get("slots", []):
            row = slot_row(raw_slot, course)
            # Two rows sharing an id after the tee is taken into account is a
            # genuine duplicate. Keep the one offering more spots rather than
            # letting parse order decide.
            if row["id"] in seen_ids:
                for i, existing in enumerate(slots):
                    if existing["id"] == row["id"]:
                        if row["spots_available"] > existing["spots_available"]:
                            slots[i] = row
                        break
            else:
                seen_ids.add(row["id"])
                slots.append(row)
            per_day.setdefault(row["tee_date"], []).append(row)

        course_error = scraped.get("error")
        for offset_date in sorted({s["tee_date"] for s in slots if s["course_slug"] == slug} | set(per_day)):
            course_days.append({
                "course_slug": slug,
                "tee_date": offset_date,
                "ok": course_error is None,
                "slot_count": len(per_day.get(offset_date, [])),
                "error": course_error,
                "last_attempt_at": generated_at,
                "last_success_at": None if course_error else generated_at,
            })

        if not per_day:
            # A course with zero slots still reports whether we reached it.
            course_days.append({
                "course_slug": slug,
                "tee_date": generated_at[:10],
                "ok": course_error is None,
                "slot_count": 0,
                "error": course_error,
                "last_attempt_at": generated_at,
                "last_success_at": None if course_error else generated_at,
            })

    slots.sort(key=lambda s: (s["tee_at"], s["course_slug"]))
    course_days.sort(key=lambda d: (d["course_slug"], d["tee_date"]))

    return {
        "contract_version": CONTRACT_VERSION,
        "generated_at": generated_at,
        "mode": mode,
        "days": days,
        "courses": [course_row(c, order[c["slug"]]) for c in roster],
        "slots": slots,
        "course_days": course_days,
    }
