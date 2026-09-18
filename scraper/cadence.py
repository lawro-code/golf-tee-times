"""When the full scrape is supposed to run, in Sydney local time.

The bug this file exists to kill: GitHub Actions cron is UTC only, and Sydney
is UTC+10 in AEST and UTC+11 in AEDT. No single cron line can mean "08:00 and
20:00 Sydney" all year. The old `cron: '0 22,10 * * *'` was right for AEST and
an hour late for the roughly five months of AEDT.

The fix is candidate crons plus a gate. `.github/workflows/scrape.yml` fires at
every UTC hour that *could* be a full-run slot — 10 and 22 in AEST, 09 and 21
in AEDT — and its first step asks this module which of those it is. Half of
every day's fires are meant to do nothing.

    python3 scraper/cadence.py --gate full     # exit 0 = run, exit 1 = skip

Two things this module is deliberate about:

  1. The gate is hour-wide, not minute-exact. GitHub's scheduler runs late,
     sometimes by ten minutes or more, and a slot that only accepted :00 would
     throw away real runs. Anywhere inside the Sydney 08:00 or 20:00 hour
     counts.
  2. There is no gate for the fast cadence and there should not be one. An
     interval is offset-agnostic: every 20 minutes is every 20 minutes in both
     AEST and AEDT, so `scrape-fast.yml` needs no DST handling at all.

Stdlib only, on purpose — the gate step runs before `pip install`.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

#: The course clubs, the golfers and the cron comment all talk in Sydney local
#: time, so this module does too. Everything crossing the boundary is an
#: absolute instant.
SYDNEY = ZoneInfo("Australia/Sydney")

#: The two Sydney local hours the full (5-day) scrape runs in. Twice daily is
#: settled in BUILD-PLAN.md; days 0-2 are covered separately and far more
#: often by the fast cadence.
FULL_RUN_HOURS = (8, 20)

#: How far ahead next_full_run_after is willing to look. Two days is already
#: twice what it can ever need with two slots a day; it exists so a mangled
#: FULL_RUN_HOURS raises instead of looping forever.
_MAX_LOOKAHEAD_DAYS = 2


def _aware_utc(instant: datetime) -> datetime:
    """Every entry point takes an instant; a naive one is read as UTC.

    Naive-means-UTC matches what the callers hand us: `datetime.utcnow()`
    output and the UTC timestamps GitHub puts in the environment. A datetime
    that already carries an offset is left alone and converted properly.
    """
    if instant.tzinfo is None:
        return instant.replace(tzinfo=timezone.utc)
    return instant


def sydney_now(now_utc: datetime | None = None) -> datetime:
    """The given instant (default: right now) as Sydney wall-clock time.

    The returned datetime is aware and in `Australia/Sydney`, so `.hour` is
    what a clock at the golf club reads.
    """
    instant = datetime.now(timezone.utc) if now_utc is None else _aware_utc(now_utc)
    return instant.astimezone(SYDNEY)


def is_full_run_hour(instant: datetime) -> bool:
    """Is this instant inside one of the intended Sydney full-run hours?

    Hour-wide by design — see the module docstring. 20:37 Sydney is still the
    20:00 slot; 21:00 Sydney is not.
    """
    return sydney_now(instant).hour in FULL_RUN_HOURS


def next_full_run_after(instant: datetime) -> datetime:
    """The first full-run slot strictly after `instant`, in Sydney time.

    Returned at the top of the hour, which is when the slot opens rather than
    when a late cron might actually deliver it. Strictly after, so calling it
    from inside a slot gives you the next one rather than the current one.
    """
    local = sydney_now(instant)
    for offset in range(_MAX_LOOKAHEAD_DAYS + 1):
        day = local.date() + timedelta(days=offset)
        for hour in sorted(FULL_RUN_HOURS):
            # 08:00 and 20:00 exist unambiguously on every Sydney day: the
            # spring-forward gap and the autumn-back repeat are both 02:00-02:59.
            candidate = datetime(day.year, day.month, day.day, hour, tzinfo=SYDNEY)
            if candidate > local:
                return candidate
    raise ValueError(
        f"no full run found within {_MAX_LOOKAHEAD_DAYS} days of {local:%Y-%m-%d %H:%M %Z} "
        f"— FULL_RUN_HOURS={FULL_RUN_HOURS!r} is not a usable schedule"
    )


# --------------------------------------------------------------------------
# CLI — the gate step in .github/workflows/scrape.yml
# --------------------------------------------------------------------------

def _describe(moment: datetime) -> str:
    return f"{moment:%Y-%m-%d %H:%M %Z} ({moment.astimezone(timezone.utc):%H:%M UTC})"


def _iso_instant(value: str) -> datetime:
    """argparse type for --at. Bad input exits 2, which no gate result uses."""
    try:
        return _aware_utc(datetime.fromisoformat(value.strip().replace("Z", "+00:00")))
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an ISO 8601 timestamp: {value!r}") from None


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Decide whether now is an intended Sydney scrape slot.",
        epilog="Exit 0 means run, exit 1 means skip. Only the full cadence is gated; "
               "the fast cadence is an interval and needs no gate.",
    )
    ap.add_argument("--gate", choices=("full",), required=True,
                    help="which cadence to test now against")
    ap.add_argument("--at", type=_iso_instant, metavar="ISO8601",
                    help="test this instant instead of now (naive is read as UTC)")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    instant = datetime.now(timezone.utc) if args.at is None else args.at
    local = sydney_now(instant)

    if is_full_run_hour(instant):
        print(f"full run: {_describe(local)} is inside the {local.hour:02d}:00 Sydney slot")
        return 0

    upcoming = next_full_run_after(instant)
    print(
        f"skip: {_describe(local)} is not an "
        f"{'/'.join(f'{h:02d}:00' for h in sorted(FULL_RUN_HOURS))} Sydney slot "
        f"— next is {_describe(upcoming)}"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
