"""
Scrape available tee times from MiClub-hosted Sydney public golf courses.

Reads courses.json, fetches each course's public timesheet for the next 5 days,
writes data/teetimes.json.

Usage:
    python3 scraper/scrape.py
    python3 scraper/scrape.py --course woollahra        # single course
    python3 scraper/scrape.py --days 3                  # override day count
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional
from zoneinfo import ZoneInfo

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent.parent
COURSES_PATH = ROOT / "courses.json"
OUTPUT_PATH = ROOT / "docs" / "data" / "teetimes.json"
DEBUG_DIR = ROOT / "scraper" / "debug"

USER_AGENT = "GolfTeeTimeFinder/1.0 (personal, hello@letsbundle.online)"
TIMEOUT = 25
SLEEP_BETWEEN_REQUESTS = 1.0
DEFAULT_LOOKAHEAD_DAYS = 5
SYDNEY = ZoneInfo("Australia/Sydney")


def timesheet_url(host: str, fee_group_id: str, selected_date: date) -> str:
    return (
        f"https://{host}/guests/bookings/ViewPublicTimesheet.msp"
        f"?bookingResourceId=3000000"
        f"&feeGroupId={fee_group_id}"
        f"&selectedDate={selected_date.isoformat()}"
    )


def fetch(url: str) -> Optional[str]:
    headers = {"User-Agent": USER_AGENT}
    for attempt in (1, 2):
        try:
            resp = requests.get(url, headers=headers, timeout=TIMEOUT, allow_redirects=True)
        except requests.RequestException as e:
            if attempt == 2:
                print(f"    request failed: {e}", file=sys.stderr)
                return None
            time.sleep(2)
            continue
        if 500 <= resp.status_code < 600 and attempt == 1:
            time.sleep(2)
            continue
        if resp.status_code != 200:
            print(f"    http {resp.status_code} for {url}", file=sys.stderr)
            return None
        return resp.text
    return None


_TIME_RE = re.compile(r"(\d{1,2}):(\d{2})\s*([ap])m", re.IGNORECASE)


def normalise_time(text: str) -> Optional[str]:
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


def parse_price_tiers(fees_wrapper) -> list[dict]:
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


def parse_timesheet(html: str, booking_url: str, selected_date: date) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    slots = []
    for row in soup.select("div.row-time"):
        time_h3 = row.select_one(".time-wrapper h3")
        if not time_h3:
            continue
        t = normalise_time(time_h3.get_text(strip=True))
        if not t:
            continue
        price_tiers = parse_price_tiers(row.select_one(".fees-wrapper"))
        cells = row.select(".records-wrapper .cell")
        if not cells:
            continue
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
    return slots


def scrape_course(course: dict, days: int) -> dict:
    today = datetime.now(SYDNEY).date()
    all_slots: list[dict] = []
    error: Optional[str] = None
    failures = 0

    host = course.get("host") or f"{course['subdomain']}.miclub.com.au"

    for offset in range(days):
        target_date = today + timedelta(days=offset)
        url = timesheet_url(host, course["feeGroupId"], target_date)
        print(f"  {course['slug']} {target_date.isoformat()} -> ", end="", flush=True)
        html = fetch(url)
        if html is None:
            print("FAIL")
            failures += 1
            continue
        try:
            slots = parse_timesheet(html, url, target_date)
        except Exception as e:
            print(f"PARSE ERROR: {e}")
            DEBUG_DIR.mkdir(parents=True, exist_ok=True)
            (DEBUG_DIR / f"{course['slug']}_{target_date.isoformat()}.html").write_text(html)
            failures += 1
            continue
        print(f"{len(slots)} slot(s)")
        all_slots.extend(slots)
        time.sleep(SLEEP_BETWEEN_REQUESTS)

    if failures == days:
        error = f"all {days} day(s) failed to scrape"

    return {
        "slug": course["slug"],
        "name": course["name"],
        "region": course.get("region", ""),
        "drive_minutes_from_bondi": course.get("drive_minutes_from_bondi"),
        "holes": course.get("holes"),
        "notes": course.get("notes", ""),
        "host": host,
        "error": error,
        "slots": all_slots,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--course", help="Only scrape this course slug")
    ap.add_argument("--days", type=int, default=DEFAULT_LOOKAHEAD_DAYS)
    args = ap.parse_args()

    with COURSES_PATH.open() as f:
        config = json.load(f)
    courses = config.get("courses", [])
    if args.course:
        courses = [c for c in courses if c["slug"] == args.course]
        if not courses:
            print(f"course '{args.course}' not in courses.json", file=sys.stderr)
            sys.exit(1)

    if not courses:
        print("no courses configured in courses.json — nothing to scrape", file=sys.stderr)
        sys.exit(1)

    print(f"scraping {len(courses)} course(s), {args.days} day(s) each")
    results = []
    for course in courses:
        print(f"--- {course['name']} ---")
        results.append(scrape_course(course, args.days))

    output = {
        "generated_at": datetime.now(SYDNEY).isoformat(timespec="seconds"),
        "lookahead_days": args.days,
        "courses": results,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(output, indent=2))
    total_slots = sum(len(c["slots"]) for c in results)
    print(f"\nwrote {OUTPUT_PATH} — {total_slots} total slot(s) across {len(results)} course(s)")


if __name__ == "__main__":
    main()
