"""
Write the frozen contract payload (CONTRACT.md, "The payload") into Supabase.

The payload is the only thing this module knows about. It never parses HTML,
never talks to a golf club, and never reaches back into the scraper — which is
what lets the scraper and the writer be built and tested apart.

Transport is PostgREST over HTTPS with the service role key. Deliberately not
psycopg and deliberately not the `supabase` pip package: the writes here are
four plain REST calls per run, and a direct connection would mean managing a
pool from a GitHub Actions runner for no gain. Note the module name — anything
called `supabase.py` in this directory would shadow the real package, because
scraper/ goes on sys.path.

Four things it does, in this order:

  1. Open a `scrape_runs` row, so a run that dies half way is visible as a run
     that died half way rather than as a quiet gap in the data.
  2. Upsert every slot the scrape saw, chunked. Only the columns the scraper
     observed: `opened_at`, `reopen_count` and `gone_at` belong to the
     private.slots_lifecycle trigger. Writing them from here would break the
     "a cancelled tee time alerts again" behaviour in CONTRACT.md section 6,
     and it would break it silently.
  3. Close slots that a SUCCESSFUL scrape of that course and that day stopped
     listing. Per course per day, never wider. A club returning 500 closes
     nothing at all — that is the entire reason course_day_scrapes is keyed
     per day, and the reason step 2 runs before step 3 (closing first would
     reopen every still-listed slot and bump its reopen_count).
  4. Record per-day scrape health, then close the run row.

Failure isolation runs all the way through: a chunk that fails is recorded in
WriteResult.errors and the rest still go, so one bad course never costs us the
other fourteen. Rows are never deleted.

Usage:

    from supabase_writer import SupabaseWriter
    result = SupabaseWriter.from_env(dry_run=False).write(payload)
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
from zoneinfo import ZoneInfo

SYDNEY = ZoneInfo("Australia/Sydney")

ENV_URL = "SUPABASE_URL"
ENV_KEY = "SUPABASE_SERVICE_ROLE_KEY"

# Exactly what the scraper observed, and nothing else. first_seen_at defaults
# in the database and is left alone on update; opened_at, reopen_count and
# gone_at are the trigger's. See the module docstring.
SLOT_COLUMNS: Tuple[str, ...] = (
    "id",
    "course_slug",
    "tee_date",
    "tee_time",
    "tee_at",
    "spots_available",
    "total_spots",
    "holes",
    "price_min",
    "price_max",
    "price_tiers",
    "booking_type",
    "booking_url",
)

# Never write these, whatever a caller hands us.
TRIGGER_OWNED: Tuple[str, ...] = ("opened_at", "reopen_count", "gone_at", "first_seen_at")


@dataclass
class WriteResult:
    slots_upserted: int
    slots_closed: int
    course_days_written: int
    run_id: "Optional[int]"
    errors: "List[str]" = field(default_factory=list)


class MissingCredentials(RuntimeError):
    """SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not set."""


class PostgrestError(RuntimeError):
    """A REST call came back 4xx/5xx. Carries no credentials in its message."""


class SupabaseWriter:
    """Writes one contract payload per `write()` call.

    Pass `session` anything with requests.Session's `.request()` signature.
    Tests pass a fake and assert on what would have been sent; nothing in this
    module is allowed to need a real database to be proved correct.
    """

    # Body chunking: 500 rows keeps a 1755-slot run to four requests instead
    # of 1755, while staying well inside PostgREST's request body limits.
    SLOT_CHUNK = 500
    COURSE_DAY_CHUNK = 500
    # Closing is filtered by `id=in.(...)`, which lives in the URL, so it gets
    # a much smaller chunk — a few hundred 45-character ids would blow past
    # the proxy's URL length limit.
    CLOSE_CHUNK = 100
    # Paging the open-slot query, so a `db-max-rows` setting cannot silently
    # truncate the set we diff against and mass-close live inventory.
    PAGE_SIZE = 1000

    def __init__(
        self,
        url: str,
        service_role_key: str,
        *,
        dry_run: bool = False,
        timeout: int = 30,
        session: Any = None,
    ) -> None:
        self.url = (url or "").rstrip("/")
        self.service_role_key = service_role_key or ""
        self.dry_run = dry_run
        self.timeout = timeout
        self.base_url = self.url + "/rest/v1"
        self._session = session
        self._owns_session = session is None

    @classmethod
    def from_env(cls, *, dry_run: bool = False) -> "SupabaseWriter":
        """Build from SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

        A dry run makes no network calls, so it deliberately does not need
        credentials: `--write supabase --dry-run` has to work on a laptop that
        has never seen the service role key.
        """
        url = os.environ.get(ENV_URL, "").strip()
        key = os.environ.get(ENV_KEY, "").strip()
        if not dry_run and not (url and key):
            missing = [name for name, value in ((ENV_URL, url), (ENV_KEY, key)) if not value]
            raise MissingCredentials(", ".join(missing) + " not set")
        return cls(url, key, dry_run=dry_run)

    # -- transport ----------------------------------------------------------

    @property
    def session(self) -> Any:
        if self._session is None:
            import requests  # imported here so a dry run needs nothing installed

            self._session = requests.Session()
        return self._session

    def _headers(self, prefer: Optional[str]) -> Dict[str, str]:
        headers = {
            "apikey": self.service_role_key,
            "Authorization": "Bearer " + self.service_role_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if prefer:
            headers["Prefer"] = prefer
        return headers

    def _call(
        self,
        method: str,
        table: str,
        *,
        params: Optional[Dict[str, str]] = None,
        body: Any = None,
        prefer: Optional[str] = None,
    ) -> Any:
        url = "{}/{}".format(self.base_url, table)
        response = self.session.request(
            method,
            url,
            params=params,
            json=body,
            headers=self._headers(prefer),
            timeout=self.timeout,
        )
        status = getattr(response, "status_code", 0)
        if status >= 400:
            raise PostgrestError(
                "{} {} -> {} {}".format(method, table, status, _response_text(response))
            )
        return _response_json(response)

    # -- the run ledger -----------------------------------------------------

    def write(self, payload: dict) -> WriteResult:
        slots = list(payload.get("slots") or [])
        course_days = list(payload.get("course_days") or [])
        seen_at = _seen_at(payload)

        if self.dry_run:
            # Accurate for what a dry run can know: every slot would be
            # upserted and every course-day written. Nothing can be closed
            # without asking the database what is currently open, and asking
            # is a network call.
            return WriteResult(
                slots_upserted=len(slots),
                slots_closed=0,
                course_days_written=len(course_days),
                run_id=None,
                errors=[],
            )

        errors: List[str] = []
        run_id = None
        try:
            run_id = self._open_run(payload, seen_at)
        except Exception as exc:
            # The ledger row is useful, not load-bearing. Losing it must not
            # cost us the scrape itself.
            errors.append("scrape_runs open: {}".format(exc))

        upserted = closed = days_written = 0
        try:
            upserted, errs = self._upsert_slots(slots, seen_at)
            errors.extend(errs)
            closed, errs = self._close_gone_slots(slots, course_days, seen_at)
            errors.extend(errs)
            days_written, errs = self._upsert_course_days(course_days, seen_at)
            errors.extend(errs)
        except BaseException as exc:  # noqa: BLE001 - the run row must close
            self._try_close_run(
                run_id, course_days, upserted, closed,
                error="{}: {}".format(type(exc).__name__, exc),
            )
            raise

        self._try_close_run(
            run_id, course_days, upserted, closed,
            error="; ".join(errors) if errors else None,
        )
        return WriteResult(
            slots_upserted=upserted,
            slots_closed=closed,
            course_days_written=days_written,
            run_id=run_id,
            errors=errors,
        )

    def _open_run(self, payload: dict, seen_at: str) -> Optional[int]:
        rows = self._call(
            "POST",
            "scrape_runs",
            body={
                "mode": payload.get("mode") or "full",
                "days_requested": payload.get("days") or 1,
                "contract_version": payload.get("contract_version") or "",
                "started_at": seen_at,
            },
            prefer="return=representation",
        )
        if isinstance(rows, list) and rows:
            return rows[0].get("id")
        return None

    def _try_close_run(
        self,
        run_id: Optional[int],
        course_days: Sequence[dict],
        upserted: int,
        closed: int,
        *,
        error: Optional[str],
    ) -> None:
        if run_id is None:
            return
        attempted, ok, failed = _course_tallies(course_days)
        try:
            self._call(
                "PATCH",
                "scrape_runs",
                params={"id": "eq.{}".format(run_id)},
                body={
                    "finished_at": _now_iso(),
                    "courses_attempted": attempted,
                    "courses_ok": ok,
                    "courses_failed": failed,
                    "slots_upserted": upserted,
                    "slots_closed": closed,
                    "error": _truncate(error, 4000),
                },
                prefer="return=minimal",
            )
        except Exception:
            # Nothing useful left to do with it: the caller already has the
            # counts and the errors in its WriteResult.
            pass

    # -- slots --------------------------------------------------------------

    def _upsert_slots(self, slots: Sequence[dict], seen_at: str) -> Tuple[int, List[str]]:
        rows = [_slot_row(s, seen_at) for s in slots]
        written = 0
        errors: List[str] = []
        chunks = _chunks(rows, self.SLOT_CHUNK)
        for index, chunk in enumerate(chunks, start=1):
            try:
                self._call(
                    "POST",
                    "slots",
                    params={"on_conflict": "id"},
                    body=chunk,
                    prefer="resolution=merge-duplicates,return=minimal",
                )
                written += len(chunk)
            except Exception as exc:
                # One bad chunk, fourteen good courses. Keep going.
                errors.append(
                    "slots chunk {}/{} ({} row(s)): {}".format(index, len(chunks), len(chunk), exc)
                )
        return written, errors

    def _close_gone_slots(
        self, slots: Sequence[dict], course_days: Sequence[dict], seen_at: str
    ) -> Tuple[int, List[str]]:
        """Close what a successful scrape stopped listing. Nothing else.

        A (course, day) that failed is not in `ok_days`, is never queried, and
        therefore cannot lose a single row. That asymmetry is the point.

        Fencing against a second, TOCTOU race: a slow 'full' run's in-memory
        payload for a (course, day) reflects the instant it fetched that
        page (`last_attempt_at`), not the instant it gets around to closing.
        A faster, narrower run (or any other writer) can legitimately write a
        slot open AFTER that fetch but BEFORE this run's close step runs —
        full's own 'seen' set then omits it honestly, but the row is not
        actually gone, this run's snapshot of it is just older than the
        current truth. A row is only closed when its own `last_seen_at` is
        no newer than the fetch it is being judged against; a row someone
        else has touched more recently is left alone rather than closed and
        immediately reopened with a fresh (spurious) opened_at.
        """
        ok_days: Dict[str, List[str]] = {}
        fetched_at: Dict[Tuple[str, str], str] = {}
        for day in course_days:
            if not day.get("ok"):
                continue
            slug = day.get("course_slug")
            tee_date = day.get("tee_date")
            if not slug or not tee_date:
                continue
            ok_days.setdefault(slug, [])
            if tee_date not in ok_days[slug]:
                ok_days[slug].append(tee_date)
            # Per-day fetch time when available (it always is from scrape.py);
            # the run's own overall timestamp is the safe fallback, since it
            # is still captured before this run's own writes go out.
            fetched_at[(slug, tee_date)] = day.get("last_attempt_at") or seen_at

        seen: Dict[Tuple[str, str], set] = {}
        for slot in slots:
            key = (slot.get("course_slug"), slot.get("tee_date"))
            seen.setdefault(key, set()).add(slot.get("id"))

        closed = 0
        errors: List[str] = []
        for slug in sorted(ok_days):
            dates = sorted(ok_days[slug])
            try:
                open_rows = self._open_slot_ids(slug, dates)
            except Exception as exc:
                errors.append("open slots for {}: {}".format(slug, exc))
                continue

            stale = [
                row["id"]
                for row in open_rows
                if row.get("id") not in seen.get((slug, row.get("tee_date")), set())
                and _not_fresher_than(
                    row.get("last_seen_at"), fetched_at.get((slug, row.get("tee_date")))
                )
            ]
            for chunk in _chunks(sorted(stale), self.CLOSE_CHUNK):
                try:
                    closed += len(self._close_ids(chunk))
                except Exception as exc:
                    errors.append("close {} slot(s) for {}: {}".format(len(chunk), slug, exc))
        return closed, errors

    def _open_slot_ids(self, slug: str, dates: Sequence[str]) -> List[dict]:
        rows: List[dict] = []
        offset = 0
        while True:
            page = self._call(
                "GET",
                "slots",
                params={
                    "select": "id,tee_date,last_seen_at",
                    "course_slug": "eq.{}".format(slug),
                    "tee_date": _in_list(dates),
                    "status": "eq.open",
                    # Ordered because the paging below is limit/offset; an
                    # unordered page boundary would skip rows and leave gone
                    # slots showing as open.
                    "order": "id.asc",
                    "limit": str(self.PAGE_SIZE),
                    "offset": str(offset),
                },
            )
            page = page or []
            rows.extend(page)
            if len(page) < self.PAGE_SIZE:
                return rows
            offset += self.PAGE_SIZE

    def _close_ids(self, ids: Sequence[str]) -> List[dict]:
        # status=eq.open in the filter as well as in the diff: if another run
        # closed the row in between, this one should not touch it again.
        # return=representation so slots_closed is what actually changed.
        rows = self._call(
            "PATCH",
            "slots",
            params={"id": _in_list(ids), "status": "eq.open", "select": "id"},
            body={"status": "gone"},
            prefer="return=representation",
        )
        return rows or []

    # -- per-day scrape health ---------------------------------------------

    def _upsert_course_days(
        self, course_days: Sequence[dict], seen_at: str
    ) -> Tuple[int, List[str]]:
        """Good days and failed days go as separate requests on purpose.

        PostgREST builds one column list per request and DO UPDATE only touches
        the columns in it. Omitting last_success_at from the failed batch is
        what stops a club having a bad afternoon from erasing the timestamp
        that tells the app when we last actually reached it.
        """
        good = [_course_day_row(d, seen_at, include_success=True) for d in course_days if d.get("ok")]
        bad = [_course_day_row(d, seen_at, include_success=False) for d in course_days if not d.get("ok")]

        written = 0
        errors: List[str] = []
        for label, rows in (("ok", good), ("failed", bad)):
            for index, chunk in enumerate(_chunks(rows, self.COURSE_DAY_CHUNK), start=1):
                try:
                    self._call(
                        "POST",
                        "course_day_scrapes",
                        params={"on_conflict": "course_slug,tee_date"},
                        body=chunk,
                        prefer="resolution=merge-duplicates,return=minimal",
                    )
                    written += len(chunk)
                except Exception as exc:
                    errors.append(
                        "course_day_scrapes {} chunk {} ({} row(s)): {}".format(
                            label, index, len(chunk), exc
                        )
                    )
        return written, errors


# ---------------------------------------------------------------------------
# Row building
# ---------------------------------------------------------------------------

def _slot_row(slot: dict, seen_at: str) -> Dict[str, Any]:
    row = {column: slot.get(column) for column in SLOT_COLUMNS}
    row["price_tiers"] = slot.get("price_tiers") or []
    # The scraper says only what it saw. 'open' with the spots it found; the
    # trigger decides whether that is a new listing or the same one again.
    row["status"] = "open"
    row["last_seen_at"] = seen_at
    for column in TRIGGER_OWNED:
        row.pop(column, None)
    return row


def _course_day_row(day: dict, seen_at: str, *, include_success: bool) -> Dict[str, Any]:
    attempt = day.get("last_attempt_at") or seen_at
    row = {
        "course_slug": day.get("course_slug"),
        "tee_date": day.get("tee_date"),
        "ok": bool(day.get("ok")),
        "slot_count": int(day.get("slot_count") or 0),
        "error": _truncate(day.get("error"), 2000),
        "last_attempt_at": attempt,
    }
    if include_success:
        # We reached the club this run, so now is a success even if the
        # payload did not carry the timestamp forward.
        row["last_success_at"] = day.get("last_success_at") or attempt
    return row


def _course_tallies(course_days: Sequence[dict]) -> Tuple[int, int, int]:
    """A course is clean only if every one of its days was reached.

    Matches scrape.py's own "N/15 course(s) clean" line: three days out of five
    is a course with a problem, not a course that is fine.
    """
    by_course: Dict[str, bool] = {}
    for day in course_days:
        slug = day.get("course_slug")
        if not slug:
            continue
        by_course[slug] = by_course.get(slug, True) and bool(day.get("ok"))
    attempted = len(by_course)
    ok = sum(1 for clean in by_course.values() if clean)
    return attempted, ok, attempted - ok


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _chunks(rows: Sequence[Any], size: int) -> List[List[Any]]:
    return [list(rows[i:i + size]) for i in range(0, len(rows), size)]


def _not_fresher_than(last_seen_at: Optional[str], fetched_at: Optional[str]) -> bool:
    """True unless `last_seen_at` is strictly after `fetched_at`.

    This is the fence: `fetched_at` is when a run looked at a (course, day)
    page, `last_seen_at` is when the row now sitting in the DB was last
    written by anyone. If that write happened after this run's own look at
    the page, it knows something this run's payload cannot — closing on the
    strength of an older fetch would clobber newer, real information. Unknown
    or unparseable timestamps fail open (closable), matching the pre-fence
    behaviour: every real row from the database has both fields set.
    """
    if not fetched_at:
        return True
    seen = _parse_instant(last_seen_at)
    fetched = _parse_instant(fetched_at)
    if seen is None or fetched is None:
        return True
    return seen <= fetched


def _parse_instant(value: Optional[str]) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None


def _in_list(values: Iterable[str]) -> str:
    """PostgREST `in.("a","b")`. Quoted because slot ids contain colons."""
    quoted = ['"{}"'.format(str(v).replace('\\', '\\\\').replace('"', '\\"')) for v in values]
    return "in.({})".format(",".join(quoted))


def _seen_at(payload: dict) -> str:
    """When the scrape saw what it saw. Keeps one run's timestamps consistent."""
    generated = payload.get("generated_at")
    if isinstance(generated, str) and generated.strip():
        return generated.strip()
    return _now_iso()


def _now_iso() -> str:
    return datetime.now(SYDNEY).isoformat(timespec="seconds")


def _truncate(text: Optional[str], limit: int) -> Optional[str]:
    if text is None:
        return None
    text = str(text)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _response_json(response: Any) -> Any:
    if getattr(response, "status_code", 0) == 204:
        return None
    try:
        return response.json()
    except Exception:
        return None


def _response_text(response: Any) -> str:
    text = getattr(response, "text", "") or ""
    try:
        text = json.dumps(response.json())
    except Exception:
        pass
    return _truncate(text, 500) or ""
