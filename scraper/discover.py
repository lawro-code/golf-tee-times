"""
Find the feeGroupId for a MiClub-hosted golf club.

Usage:
    python3 discover.py <host>

Examples:
    python3 discover.py woollahra.miclub.com.au
    python3 discover.py www.eastlakegolfclub.com.au
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from typing import Optional

import requests

USER_AGENT = "GolfTeeTimeFinder/1.0 (personal, hello@letsbundle.online)"
TIMEOUT = 20


def normalise_host(host: str) -> str:
    host = host.strip().lower()
    host = re.sub(r"^https?://", "", host)
    host = host.rstrip("/")
    if "." not in host:
        host = f"{host}.miclub.com.au"
    return host


def discover_fee_group_id(host_or_subdomain: str) -> Optional[str]:
    host = normalise_host(host_or_subdomain)
    url = (
        f"https://{host}/guests/bookings/"
        f"ViewPublicCalendar.msp?booking_resource_id=3000000"
    )
    resp = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=TIMEOUT, allow_redirects=True)
    if resp.status_code != 200:
        print(f"  http {resp.status_code} for {url}", file=sys.stderr)
        return None

    patterns = [
        r'data-feeid=["\'](\d+)["\']',
        r'feeGroupId-(\d+)',
        r'feeGroupId\s*=\s*["\']?(\d+)',
    ]
    matches: list[str] = []
    for pat in patterns:
        matches.extend(re.findall(pat, resp.text))
    if not matches:
        if "login" in resp.url.lower():
            print(f"  page redirected to login: {resp.url}", file=sys.stderr)
        else:
            print(f"  no feeGroupId found in HTML", file=sys.stderr)
        return None

    most_common, _ = Counter(matches).most_common(1)[0]
    return most_common


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    result = discover_fee_group_id(sys.argv[1])
    if result is None:
        sys.exit(1)
    print(result)


if __name__ == "__main__":
    main()
