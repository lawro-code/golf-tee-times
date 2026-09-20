"""
HTTP for the scraper: the retries worth making, courtesy per club, and a
failure reason a human can read.

Every request the scraper makes comes through here. Four things this file is
deliberate about:

  1. **Only retry what can change.** A 5xx, a dropped connection and a timeout
     are worth asking again about. A 404 or a 403 will say exactly the same
     thing three seconds later, so asking again is noise pointed at a golf
     club that already answered.

  2. **The error string is the product.** It goes straight into
     `course_day_scrapes.error`, `public.course_freshness` aggregates it, and
     the stale-data banner a golfer reads is derived from it. `None` for a
     timeout, a 500, a 404 and a redirect to a login page alike — which is
     what the old fetch() returned — tells that golfer nothing and tells the
     person fixing it less. So the strings here are short, specific, and
     written the way a person would say them.

  3. **Courtesy is per host, not global.** Fifteen clubs are fifteen separate
     servers, and that is the entire reason the cadence in BUILD-PLAN.md is
     safe: every 20 minutes across 15 clubs is one request per club every
     seven minutes. What gets a scraper blocked is its rate at a single host,
     so that is what is throttled. Sleeping a second between two *different*
     clubs would slow the run down and protect nobody.

  4. **A 200 is not automatically a success.** MiClub answers a session it does
     not like by redirecting to a login or members page, and it does it with a
     200 and a perfectly well-formed page. A fetch that lands on one is a
     failure that says so — the same pattern discover.py already uses. An
     empty or non-HTML body is a failure too.

`requests` and the standard library, nothing else. MiClub serves plain
server-rendered HTML at a fixed URL: there is no JavaScript to execute and no
reason for a headless browser.
"""

from __future__ import annotations

import os
import random
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Optional, Tuple
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import requests

HERE = Path(__file__).resolve().parent

#: Where TEES_SCRAPE_DEBUG=1 drops the pages it fetched. Gitignored.
DEBUG_DIR = HERE / "debug"
DEBUG_ENV = "TEES_SCRAPE_DEBUG"

SYDNEY = ZoneInfo("Australia/Sydney")

#: Unchanged from discover.py, contact address included. A club that wants to
#: ask us to stop can, which is the only reason a scraper deserves to run.
USER_AGENT = "GolfTeeTimeFinder/1.0 (personal, hello@letsbundle.online)"

ACCEPT = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"

DEFAULT_TIMEOUT = 25
DEFAULT_RETRIES = 2

#: Minimum gap between two requests to the SAME host. Different hosts never
#: wait on each other — see point 3 in the module docstring.
MIN_HOST_INTERVAL = 1.0

#: Exponential backoff: 1s, 2s, 4s ... capped, plus up to 25% jitter so
#: fifteen courses failing at once do not retry in lockstep. The first retry
#: lands on the same one second the per-host floor would have imposed anyway.
BACKOFF_BASE = 1.0
BACKOFF_CAP = 8.0
BACKOFF_JITTER = 0.25

#: The longest we will sit still for a 429's Retry-After. Anything longer is
#: not a wait, it is a no: fail the day honestly and let the next run try.
RETRY_AFTER_CAP = 5.0

#: When each host was last asked for something, by the monotonic clock.
_last_request_at: dict = {}

_SHARED_SESSION: Any = None

_DATE_IN_URL = re.compile(r"selectedDate=(\d{4}-\d{2}-\d{2})")
_ERRNO_RE = re.compile(r"\[Errno -?\d+\]\s*([^'\")\]]+)")
_UNSAFE_IN_FILENAME = re.compile(r"[^A-Za-z0-9._-]+")

#: A final URL containing any of these means the club bounced us somewhere
#: that is not the public timesheet. The requested URL never contains them.
_LOGIN_MARKERS = ("login", "signin", "sign-in", "logon")

_HTML_TYPES = ("text/html", "application/xhtml+xml")

#: urllib3 wraps the real reason in several layers of repr. These are the ones
#: worth naming in a banner; everything else falls back to the errno text.
_CONNECTION_HINTS = (
    ("nodename nor servname", "dns lookup failed"),
    ("name or service not known", "dns lookup failed"),
    ("temporary failure in name resolution", "dns lookup failed"),
    ("failed to resolve", "dns lookup failed"),
    ("connection refused", "connection refused"),
    ("connection reset", "connection reset by the club"),
    ("connection aborted", "connection dropped"),
    ("certificate verify failed", "tls certificate rejected"),
    ("ssl", "tls handshake failed"),
    ("network is unreachable", "network unreachable"),
)


@dataclass(frozen=True)
class FetchResult:
    """One attempt at one page, and everything the caller needs to be honest
    about it. `error` is short and human-readable and goes straight into
    `course_day_scrapes.error`; it is None exactly when `ok` is True.
    """

    ok: bool
    html: str | None
    error: str | None
    status: int | None
    attempts: int
    elapsed_ms: int


# --------------------------------------------------------------------------
# The clock, in one place so the tests can fake it. A test suite that slept
# through real backoff would take minutes and would be lying about what it
# had done.
# --------------------------------------------------------------------------

def _now() -> float:
    return time.monotonic()


def _sleep(seconds: float) -> None:
    time.sleep(seconds)


def _elapsed_ms(started: float) -> int:
    return int(round(max(0.0, _now() - started) * 1000))


# --------------------------------------------------------------------------
# Per-host courtesy
# --------------------------------------------------------------------------

def polite_sleep(host: str) -> None:
    """Wait until `MIN_HOST_INTERVAL` has passed since the last request to
    `host`, then count this moment as one.

    Per host on purpose. Two requests to Woollahra a tenth of a second apart
    are rude; a request to Woollahra and one to Moore Park a tenth of a second
    apart are two different servers each being asked once.

    `fetch` calls this itself before every attempt, so the floor holds whether
    or not a caller remembers to be polite. `scrape.py` also calls it between
    days, which buys a second of extra headroom per request — cheap, and the
    right direction to be wrong in.
    """
    key = (host or "").strip().lower()
    last = _last_request_at.get(key)
    moment = _now()
    if last is not None:
        remaining = MIN_HOST_INTERVAL - (moment - last)
        if remaining > 0:
            _sleep(remaining)
            moment = _now()
    _last_request_at[key] = moment


def reset_throttle() -> None:
    """Forget every host's last-request time.

    For tests, and for anything long-lived that wants a clean slate. A run of
    the scraper never needs it.
    """
    _last_request_at.clear()


# --------------------------------------------------------------------------
# Reading a response honestly
# --------------------------------------------------------------------------

def _host_of(url: str) -> str:
    try:
        return (urlparse(url).hostname or "").lower()
    except ValueError:
        return ""


def _header(response: Any, name: str) -> Optional[str]:
    """Case-insensitive header lookup that survives a plain dict."""
    headers = getattr(response, "headers", None) or {}
    getter = getattr(headers, "get", None)
    if getter is None:
        return None
    value = getter(name)
    if value is not None:
        return value
    lowered = name.lower()
    items = getattr(headers, "items", None)
    if items is None:
        return None
    for key, candidate in items():
        if str(key).lower() == lowered:
            return candidate
    return None


def _trim(text: str, limit: int) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3].rstrip() + "..."


def _connection_reason(exc: BaseException) -> str:
    """The readable half of 'connection error: <reason>'."""
    text = " ".join(str(exc).split()) or type(exc).__name__
    lowered = text.lower()
    for needle, plain in _CONNECTION_HINTS:
        if needle in lowered:
            return plain
    match = _ERRNO_RE.search(text)
    if match:
        return _trim(match.group(1).lower(), 60)
    return _trim(text, 60)


def _classify_transport(exc: BaseException, timeout: int) -> Tuple[bool, str]:
    """(is it worth retrying, what to tell the golfer) for a raised request.

    Timeout is checked before ConnectionError on purpose: requests' own
    ConnectTimeout is both, and "timeout after 25s" is the more useful half.

    ChunkedEncodingError rides alongside ConnectionError on purpose too: it is
    what requests/urllib3 actually raises when a connection resets or the body
    is cut short partway through a chunked or streamed read (an
    IncompleteRead) — a sibling exception, not a subclass, but the same
    "dropped connection, worth asking again about" case the module docstring
    promises a retry for.
    """
    if isinstance(exc, requests.exceptions.Timeout):
        return True, f"timeout after {timeout}s"
    if isinstance(exc, (requests.exceptions.ConnectionError,
                        requests.exceptions.ChunkedEncodingError)):
        return True, f"connection error: {_connection_reason(exc)}"
    if isinstance(exc, requests.exceptions.TooManyRedirects):
        return False, "too many redirects"
    if isinstance(exc, (requests.exceptions.MissingSchema,
                        requests.exceptions.InvalidSchema,
                        requests.exceptions.InvalidURL)):
        return False, "invalid url"
    return False, f"request failed: {type(exc).__name__}"


def _retry_after_seconds(response: Any) -> Optional[float]:
    """Retry-After as seconds, or None when it is absent or unreadable.

    Both spellings are legal: a count of seconds, or an HTTP date.
    """
    raw = _header(response, "Retry-After")
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    try:
        return max(0.0, float(text))
    except ValueError:
        pass
    try:
        when = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return max(0.0, (when - datetime.now(timezone.utc)).total_seconds())


def _redirect_problem(requested: str, final: str) -> Optional[str]:
    """Did a 200 actually land somewhere that is not the public timesheet?

    The named markers give the specific, human-readable reason when the
    bounce target says what it is. But the timesheet URL is fixed (see the
    module docstring) and never legitimately redirects anywhere else, so any
    200 that lands on a different path is a failure regardless of whether
    the destination happens to mention login or membership — a club's own
    homepage, an access-denied page, a session-timeout notice, or anything
    else a custom-domain club or a MiClub product change bounces us to.
    """
    final_lower = (final or "").lower()
    if not final_lower:
        return None
    if any(marker in final_lower for marker in _LOGIN_MARKERS):
        return "redirected to login"
    if final_lower != (requested or "").lower() and "/member" in final_lower:
        return "redirected to member area"
    requested_path = urlparse(requested or "").path.rstrip("/")
    final_path = urlparse(final or "").path.rstrip("/")
    if final_path != requested_path:
        return f"redirected away from the timesheet (landed on {_trim(final, 80)})"
    return None


def _body_problem(html: str, content_type: Optional[str]) -> Optional[str]:
    """A 200 with nothing usable in it is a failed scrape, not an empty one.

    Section 5 of CONTRACT.md turns on this distinction: a club with no free
    tee times and a club serving us a maintenance page must not look the same.
    """
    if not html or not html.strip():
        return "empty response body"
    if content_type:
        main = str(content_type).split(";")[0].strip().lower()
        if main and main not in _HTML_TYPES:
            return f"non-html response ({main})"
        return None
    # No Content-Type at all: accept anything that is at least markup.
    if "<" not in html[:2000]:
        return "non-html response (no markup)"
    return None


def _backoff_delay(attempts_made: int) -> float:
    """Wait before attempt number `attempts_made` + 1. Jittered so fifteen
    clubs that all went down together do not come back in lockstep."""
    base = min(BACKOFF_CAP, BACKOFF_BASE * (2 ** max(0, attempts_made - 1)))
    return base + random.uniform(0.0, base * BACKOFF_JITTER)


# --------------------------------------------------------------------------
# Debug capture. Off unless TEES_SCRAPE_DEBUG=1, and never on in CI.
# --------------------------------------------------------------------------

def _debug_filename(host: str, url: str) -> str:
    match = _DATE_IN_URL.search(url or "")
    when = match.group(1) if match else datetime.now(SYDNEY).date().isoformat()
    safe_host = _UNSAFE_IN_FILENAME.sub("-", host or "unknown-host")
    return f"{safe_host}_{when}.html"


def _capture_debug(host: str, url: str, html: str) -> None:
    """Keep the page we fetched so it can be looked at later.

    Never allowed to fail a scrape: a full disk is not a reason to lose
    fourteen other clubs.
    """
    if os.environ.get(DEBUG_ENV) != "1" or not html:
        return
    try:
        DEBUG_DIR.mkdir(parents=True, exist_ok=True)
        (DEBUG_DIR / _debug_filename(host, url)).write_text(html)
    except OSError:
        pass


def _shared_session() -> Any:
    """One keep-alive session for the whole run. Five days at one club is five
    requests to the same server; reusing the connection is both faster and
    less work for the club."""
    global _SHARED_SESSION
    if _SHARED_SESSION is None:
        _SHARED_SESSION = requests.Session()
    return _SHARED_SESSION


# --------------------------------------------------------------------------
# The one public entry point
# --------------------------------------------------------------------------

def fetch(
    url: str,
    *,
    host: str | None = None,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
    session: Any = None,
) -> FetchResult:
    """GET `url` and say plainly what happened.

    `host` defaults to the one in the URL and is only worth passing when two
    URLs share a server. `retries` is retries, not attempts: the default 2
    means up to three requests. `session` takes anything with
    `requests.Session.get`'s signature, which is how the tests stay offline.

    Never raises for a network or HTTP problem — that is what `FetchResult.ok`
    and `FetchResult.error` are for. One club having a bad day must not cost
    the other fourteen.
    """
    target_host = host if host is not None else _host_of(url)
    transport = session if session is not None else _shared_session()
    headers = {"User-Agent": USER_AGENT, "Accept": ACCEPT}
    budget = max(0, int(retries)) + 1

    started = _now()
    attempts = 0
    status: Optional[int] = None
    error = "no attempt made"

    while attempts < budget:
        polite_sleep(target_host)
        attempts += 1
        status = None

        try:
            response = transport.get(
                url, headers=headers, timeout=timeout, allow_redirects=True,
            )
        except (requests.exceptions.RequestException, OSError) as exc:
            retryable, error = _classify_transport(exc, timeout)
            if not retryable or attempts >= budget:
                break
            _sleep(_backoff_delay(attempts))
            continue

        raw_status = getattr(response, "status_code", None)
        if not isinstance(raw_status, int):
            error = "malformed response (no status)"
            break
        status = raw_status

        if status == 429:
            # Honour a small Retry-After; anything else, get out of the way.
            error = "rate limited (429)"
            wait = _retry_after_seconds(response)
            if wait is None or wait > RETRY_AFTER_CAP or attempts >= budget:
                break
            _sleep(min(wait, RETRY_AFTER_CAP))
            continue

        if not 200 <= status < 300:
            error = f"http {status}"
            if not 500 <= status < 600 or attempts >= budget:
                break
            _sleep(_backoff_delay(attempts))
            continue

        html = getattr(response, "text", None) or ""
        final_url = getattr(response, "url", None) or url
        _capture_debug(target_host, url, html)

        problem = (
            _redirect_problem(url, final_url)
            or _body_problem(html, _header(response, "Content-Type"))
        )
        if problem:
            # Asking again gets the same login page or the same empty body.
            error = problem
            break

        return FetchResult(
            ok=True,
            html=html,
            error=None,
            status=status,
            attempts=attempts,
            elapsed_ms=_elapsed_ms(started),
        )

    return FetchResult(
        ok=False,
        html=None,
        error=error,
        status=status,
        attempts=attempts,
        elapsed_ms=_elapsed_ms(started),
    )
