"""The full scrape must fire at 08:00 and 20:00 *Sydney*, all year round.

The bug these tests were written against is in the old workflow's own comment:
`cron: '0 22,10 * * *'` is 08:00/20:00 Sydney in AEST and 09:00/21:00 Sydney in
AEDT, so for roughly five months a year the twice-daily scrape ran an hour
late. GitHub cron is UTC only and cannot express a local-time schedule, so the
schedule became candidate crons plus a gate step.

That makes two things drift-prone, and both are asserted here:

  1. The gate's idea of a slot (scraper/cadence.py) must be Sydney local, not
     UTC — the AEDT tests below are the ones that fail against the old schedule.
  2. The candidate cron hours in scrape.yml must stay a superset of everything
     the gate will ever accept. A hour the gate accepts but the cron never
     fires at is a scrape that silently never happens, so the cron line is
     parsed out of the YAML here rather than restated.

Stdlib only: no PyYAML in scraper/requirements.txt, and no need for one to read
a single cron line.
"""

import io
import contextlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import cadence

ROOT = Path(__file__).resolve().parent.parent.parent
SCRAPE_YML = ROOT / ".github" / "workflows" / "scrape.yml"
SCRAPE_FAST_YML = ROOT / ".github" / "workflows" / "scrape-fast.yml"

# Days the clocks move in Sydney, picked to sit either side of a full year.
SPRING_FORWARD = date(2026, 10, 4)   # 02:00 AEST -> 03:00 AEDT, first Sun in Oct
AUTUMN_BACK = date(2027, 4, 4)       # 03:00 AEDT -> 02:00 AEST, first Sun in Apr


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def utc(year, month, day, hour=0, minute=0):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)


def syd(year, month, day, hour=0, minute=0):
    return datetime(year, month, day, hour, minute, tzinfo=cadence.SYDNEY)


def elapsed(start, end):
    """Real time between two instants.

    Plain subtraction is not it: Python ignores a shared tzinfo and subtracts
    the wall clocks, which is off by an hour across a changeover — the exact
    class of mistake this module exists to stop.
    """
    return end.astimezone(timezone.utc) - start.astimezone(timezone.utc)


def without_comments(text):
    """Only the lines a runner acts on, so prose about the old behaviour is free."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def cron_lines(path):
    """Every `- cron: '...'` expression in a workflow file, in order."""
    return re.findall(r"^\s*-\s*cron:\s*['\"]([^'\"]+)['\"]\s*$", path.read_text(), re.M)


def cron_field(expression, index):
    fields = expression.split()
    if len(fields) != 5:
        raise AssertionError(f"not a 5-field cron expression: {expression!r}")
    return fields[index]


def cron_hours(expression):
    """The set of UTC hours a cron expression fires at. Lists and '*' only."""
    hours = cron_field(expression, 1)
    if hours == "*":
        return set(range(24))
    return {int(part) for part in hours.split(",")}


def hourly_fires(start_utc, end_utc, hours):
    """Simulate the real cron: every whole UTC hour in `hours`, in [start, end)."""
    moment = start_utc
    step = timedelta(hours=1)
    while moment < end_utc:
        if moment.hour in hours:
            yield moment
        moment += step


def runs_by_sydney_date(start_utc, end_utc, hours):
    """{Sydney local date: [Sydney hours the gate let through]} for that cron."""
    grouped = {}
    for moment in hourly_fires(start_utc, end_utc, hours):
        if cadence.is_full_run_hour(moment):
            local = cadence.sydney_now(moment)
            grouped.setdefault(local.date(), []).append(local.hour)
    return grouped


def step_run_script(path, step_name):
    """The shell body of the named step, dedented — what the runner executes.

    A hand parse of one block scalar rather than PyYAML, which this repo does
    not depend on and would not be worth depending on for this.
    """
    lines = path.read_text().splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == f"- name: {step_name}")
        opens = next(i for i in range(start, len(lines)) if lines[i].strip() in ("run: |", "run: |-"))
    except StopIteration:
        raise AssertionError(f"no step named {step_name!r} with a `run: |` block in {path.name}") from None

    indent = len(lines[opens + 1]) - len(lines[opens + 1].lstrip())
    body = []
    for line in lines[opens + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:] if line.strip() else "")
    return "\n".join(body).rstrip() + "\n"


def scrape_cron_hours():
    expressions = cron_lines(SCRAPE_YML)
    if len(expressions) != 1:
        raise AssertionError(f"expected exactly one cron line in scrape.yml, found {expressions}")
    return cron_hours(expressions[0])


# --------------------------------------------------------------------------
# The gate itself: Sydney local, whatever the offset is doing
# --------------------------------------------------------------------------

class FullRunHourTests(unittest.TestCase):

    def accepted_sydney_hours(self, day):
        """Which of a Sydney day's 24 local hours the gate accepts."""
        return {h for h in range(24) if cadence.is_full_run_hour(syd(day.year, day.month, day.day, h))}

    def accepted_utc_hours(self, day):
        """Which of a UTC day's 24 hours the gate accepts."""
        return {h for h in range(24) if cadence.is_full_run_hour(utc(day.year, day.month, day.day, h))}

    def test_an_aest_day_fires_at_exactly_eight_and_twenty_sydney(self):
        self.assertEqual({8, 20}, self.accepted_sydney_hours(date(2026, 7, 1)))

    def test_an_aedt_day_fires_at_exactly_eight_and_twenty_sydney(self):
        # The failing-first test. Sydney is UTC+11 here, so a schedule built
        # on fixed UTC hours lands on 09:00/21:00 local instead.
        self.assertEqual({8, 20}, self.accepted_sydney_hours(date(2026, 12, 1)))

    def test_the_firing_utc_hour_moves_with_the_offset_but_the_sydney_hour_does_not(self):
        aest = self.accepted_utc_hours(date(2026, 7, 1))
        aedt = self.accepted_utc_hours(date(2026, 12, 1))

        self.assertEqual({10, 22}, aest, "AEST is UTC+10: 20:00 Sydney is 10:00 UTC")
        self.assertEqual({9, 21}, aedt, "AEDT is UTC+11: 20:00 Sydney is 09:00 UTC")
        self.assertNotEqual(aest, aedt, "if these matched there would be no bug to fix")

        # ...and every one of them is the same pair of Sydney hours.
        for day, utc_hours in ((date(2026, 7, 1), aest), (date(2026, 12, 1), aedt)):
            for hour in utc_hours:
                local = cadence.sydney_now(utc(day.year, day.month, day.day, hour))
                self.assertIn(local.hour, cadence.FULL_RUN_HOURS)

    def test_a_slot_is_the_whole_sydney_hour_not_just_the_minute_it_opens(self):
        # GitHub's scheduler is routinely minutes late and occasionally worse.
        for minute in (0, 1, 17, 59):
            self.assertTrue(cadence.is_full_run_hour(syd(2026, 7, 1, 8, minute)))
            self.assertTrue(cadence.is_full_run_hour(syd(2026, 7, 1, 20, minute)))
        self.assertFalse(cadence.is_full_run_hour(syd(2026, 7, 1, 7, 59)))
        self.assertFalse(cadence.is_full_run_hour(syd(2026, 7, 1, 21, 0)))

    def test_a_naive_instant_is_read_as_utc(self):
        self.assertTrue(cadence.is_full_run_hour(datetime(2026, 7, 1, 10, 0)))
        self.assertFalse(cadence.is_full_run_hour(datetime(2026, 7, 1, 9, 0)))


class SydneyNowTests(unittest.TestCase):

    def test_it_converts_an_instant_to_sydney_wall_clock(self):
        self.assertEqual(20, cadence.sydney_now(utc(2026, 7, 1, 10)).hour)
        self.assertEqual(20, cadence.sydney_now(utc(2026, 12, 1, 9)).hour)

    def test_the_same_instant_in_any_offset_gives_the_same_sydney_time(self):
        instant = utc(2026, 12, 1, 9)
        self.assertEqual(
            cadence.sydney_now(instant),
            cadence.sydney_now(instant.astimezone(timezone(timedelta(hours=-5)))),
        )

    def test_it_defaults_to_now(self):
        moment = cadence.sydney_now()
        self.assertEqual(cadence.SYDNEY, moment.tzinfo)
        self.assertLess(
            abs(moment - datetime.now(timezone.utc)), timedelta(minutes=1)
        )


class NextFullRunTests(unittest.TestCase):

    def test_it_returns_the_next_slot_on_the_same_day(self):
        self.assertEqual(syd(2026, 7, 1, 8), cadence.next_full_run_after(syd(2026, 7, 1, 7, 59)))
        self.assertEqual(syd(2026, 7, 1, 20), cadence.next_full_run_after(syd(2026, 7, 1, 8, 30)))

    def test_it_is_strictly_after_so_it_never_returns_the_slot_you_are_in(self):
        self.assertEqual(syd(2026, 7, 1, 20), cadence.next_full_run_after(syd(2026, 7, 1, 8, 0)))

    def test_it_rolls_over_to_tomorrow(self):
        self.assertEqual(syd(2026, 7, 2, 8), cadence.next_full_run_after(syd(2026, 7, 1, 20, 30)))

    def test_it_crosses_the_spring_forward_night_on_the_new_offset(self):
        before = syd(2026, 10, 3, 20, 30)
        following = cadence.next_full_run_after(before)
        self.assertEqual(syd(2026, 10, 4, 8), following)
        self.assertEqual(timedelta(hours=11), following.utcoffset(), "AEDT by then")
        # An hour is lost overnight, so the real wait is 10.5h, not the 11.5h
        # the wall clocks claim. (Subtracting two datetimes that share a tzinfo
        # gives the wall-clock difference, hence the trip through UTC.)
        self.assertEqual(timedelta(hours=10, minutes=30), elapsed(before, following))

    def test_it_crosses_the_autumn_back_night_on_the_new_offset(self):
        before = syd(2027, 4, 3, 20, 30)
        following = cadence.next_full_run_after(before)
        self.assertEqual(syd(2027, 4, 4, 8), following)
        self.assertEqual(timedelta(hours=10), following.utcoffset(), "AEST by then")
        # An hour is gained overnight: 12.5h of real waiting.
        self.assertEqual(timedelta(hours=12, minutes=30), elapsed(before, following))


# --------------------------------------------------------------------------
# The deployed schedule: the real cron line driving the real gate
# --------------------------------------------------------------------------

class DeployedScheduleTests(unittest.TestCase):
    """Everything here reads scrape.yml, so the yml and the gate cannot drift."""

    def test_the_spring_forward_day_fires_exactly_twice(self):
        runs = runs_by_sydney_date(utc(2026, 10, 1), utc(2026, 10, 8), scrape_cron_hours())
        self.assertEqual([8, 20], sorted(runs.get(SPRING_FORWARD, [])))

    def test_the_autumn_back_day_fires_exactly_twice(self):
        runs = runs_by_sydney_date(utc(2027, 4, 1), utc(2027, 4, 8), scrape_cron_hours())
        self.assertEqual([8, 20], sorted(runs.get(AUTUMN_BACK, [])))

    def test_every_sydney_day_across_both_changeovers_fires_exactly_twice(self):
        start, end = utc(2026, 9, 1), utc(2027, 5, 1)
        runs = runs_by_sydney_date(start, end, scrape_cron_hours())

        # The first and last Sydney dates are only partly inside the UTC window.
        covered = sorted(runs)[1:-1]
        self.assertIn(SPRING_FORWARD, covered)
        self.assertIn(AUTUMN_BACK, covered)

        wrong = {day: sorted(runs[day]) for day in covered if sorted(runs[day]) != [8, 20]}
        self.assertEqual({}, wrong, "every Sydney day gets exactly one 08:00 and one 20:00 run")

        # No day inside the window is missing altogether.
        expected_days = (covered[-1] - covered[0]).days + 1
        self.assertEqual(expected_days, len(covered))

    def test_the_cron_candidates_are_a_superset_of_what_the_gate_ever_accepts(self):
        """A UTC hour the gate accepts but the cron never fires at is a lost scrape."""
        accepted = set()
        moment, end = utc(2026, 1, 1), utc(2028, 1, 1)
        while moment < end:
            if cadence.is_full_run_hour(moment):
                accepted.add(moment.hour)
            moment += timedelta(hours=1)

        candidates = scrape_cron_hours()
        self.assertEqual(
            set(), accepted - candidates,
            f"scrape.yml fires at {sorted(candidates)} UTC but the gate also accepts "
            f"{sorted(accepted - candidates)} — those runs would never happen",
        )

    def test_no_candidate_cron_hour_is_dead(self):
        """The mirror of the superset test: a candidate the gate never accepts wakes a runner for nothing."""
        accepted = set()
        moment, end = utc(2026, 1, 1), utc(2028, 1, 1)
        while moment < end:
            if cadence.is_full_run_hour(moment):
                accepted.add(moment.hour)
            moment += timedelta(hours=1)

        self.assertEqual(set(), scrape_cron_hours() - accepted)

    def test_the_full_cron_fires_on_the_hour_every_day(self):
        expression = cron_lines(SCRAPE_YML)[0]
        self.assertEqual("0", cron_field(expression, 0), "minute must be 0 — the gate is hour-wide")
        self.assertEqual(["*", "*", "*"], [cron_field(expression, i) for i in (2, 3, 4)])


# --------------------------------------------------------------------------
# The CLI the workflow actually invokes
# --------------------------------------------------------------------------

class GateCliTests(unittest.TestCase):

    def gate(self, at):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cadence.main(["--gate", "full", "--at", at])
        return code, out.getvalue()

    def test_it_exits_zero_inside_an_aest_slot_and_one_outside(self):
        code, output = self.gate("2026-07-01T10:00:00Z")
        self.assertEqual(0, code, output)
        code, output = self.gate("2026-07-01T09:00:00Z")
        self.assertEqual(1, code, output)

    def test_it_exits_zero_inside_an_aedt_slot_and_one_outside(self):
        # Exactly mirrored: the UTC hour that ran in July is the one that skips
        # in December, and vice versa.
        code, output = self.gate("2026-12-01T09:00:00Z")
        self.assertEqual(0, code, output)
        code, output = self.gate("2026-12-01T10:00:00Z")
        self.assertEqual(1, code, output)

    def test_it_prints_exactly_one_plain_line_either_way(self):
        for at in ("2026-07-01T10:00:00Z", "2026-07-01T09:00:00Z"):
            _, output = self.gate(at)
            self.assertEqual(1, len(output.strip().splitlines()), output)

    def test_a_skip_says_when_the_next_run_is(self):
        _, output = self.gate("2026-07-01T09:00:00Z")
        self.assertIn("2026-07-01 20:00", output)

    def test_a_bad_instant_exits_two_so_it_is_never_read_as_a_skip(self):
        with self.assertRaises(SystemExit) as raised:
            with contextlib.redirect_stderr(io.StringIO()):
                cadence.main(["--gate", "full", "--at", "yesterday"])
        self.assertEqual(2, raised.exception.code)

    def test_the_script_runs_standalone_on_stdlib_alone(self):
        """This is the command the workflow runs, before pip install has happened."""
        done = subprocess.run(
            [sys.executable, str(ROOT / "scraper" / "cadence.py"), "--gate", "full"],
            capture_output=True, text=True, cwd=ROOT,
        )
        self.assertIn(done.returncode, (0, 1), done.stderr)
        self.assertEqual(1, len(done.stdout.strip().splitlines()), done.stdout)
        self.assertEqual("", done.stderr)


# --------------------------------------------------------------------------
# The gate step's own shell, run the way the runner runs it
# --------------------------------------------------------------------------

class GateStepScriptTests(unittest.TestCase):
    """Lift the `run:` block out of scrape.yml and execute it against a stub.

    The exit code is the whole interface between cadence.py and the workflow,
    and reading every non-zero as 'skip' is the trap here: a syntax error in
    cadence.py would then turn every scheduled full run into a silent no-op
    with nothing going red to say so. Only 1 is a skip.

    `bash -eo pipefail` is what GitHub gives a `run:` block, so the script is
    tested under the same settings it will meet in production.
    """

    def run_gate_step(self, cadence_exit):
        script = step_run_script(SCRAPE_YML, "Sydney cadence gate")
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            stub = tmp / "python3"
            stub.write_text(f"#!/bin/sh\necho 'stubbed cadence.py'\nexit {cadence_exit}\n")
            stub.chmod(0o755)
            github_output = tmp / "github_output"
            github_output.touch()

            done = subprocess.run(
                ["bash", "-eo", "pipefail", "-c", script],
                capture_output=True, text=True, cwd=ROOT,
                env={"PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}",
                     "GITHUB_OUTPUT": str(github_output)},
            )
            return done, github_output.read_text()

    def test_exit_zero_sets_run_true(self):
        done, output = self.run_gate_step(0)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertIn("run=true", output)

    def test_exit_one_sets_run_false_without_failing_the_job(self):
        # Half of every day's scheduled fires land here on purpose.
        done, output = self.run_gate_step(1)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertIn("run=false", output)

    def test_a_broken_gate_fails_the_job_instead_of_skipping_silently(self):
        for cadence_exit in (2, 127):
            with self.subTest(cadence_exit=cadence_exit):
                done, output = self.run_gate_step(cadence_exit)
                self.assertEqual(cadence_exit, done.returncode, done.stdout)
                self.assertNotIn("run=", output, "a crash must not be recorded as a decision")

    def test_the_later_steps_key_off_the_output_the_gate_writes(self):
        """`!= 'false'` is deliberate: workflow_dispatch skips the gate, leaving it empty."""
        guards = re.findall(r"if:\s*(steps\.gate\.outputs\.run[^\n]*)", SCRAPE_YML.read_text())
        self.assertEqual(3, len(guards), guards)
        for guard in guards:
            self.assertEqual("steps.gate.outputs.run != 'false'", guard.strip())


# --------------------------------------------------------------------------
# What the two workflows are, and what they must never do again
# --------------------------------------------------------------------------

class WorkflowShapeTests(unittest.TestCase):

    def setUp(self):
        self.full = SCRAPE_YML.read_text()
        self.fast = SCRAPE_FAST_YML.read_text()

    def test_the_full_workflow_gates_scheduled_runs_and_bypasses_manual_ones(self):
        self.assertIn("scraper/cadence.py --gate full", self.full)
        self.assertIn("workflow_dispatch", self.full)
        self.assertRegex(self.full, r"if:\s*github\.event_name\s*==\s*'schedule'")

    def test_the_full_workflow_runs_five_days_into_supabase(self):
        self.assertIn("--mode full --validate --write supabase", self.full)

    def test_the_fast_workflow_runs_three_days_into_supabase(self):
        self.assertIn("--mode fast --validate --write supabase", self.fast)

    def test_the_fast_cadence_is_every_twenty_minutes_and_needs_no_gate(self):
        self.assertEqual(["*/20 * * * *"], cron_lines(SCRAPE_FAST_YML))
        self.assertNotIn("--gate", self.fast)

    def test_neither_workflow_writes_to_git_any_more(self):
        # Slots go to Supabase; docs/data/teetimes.json is no longer produced.
        # Comments are stripped first — both files explain the old behaviour.
        for name, text in (("scrape.yml", self.full), ("scrape-fast.yml", self.fast)):
            runnable = without_comments(text)
            for forbidden in ("git commit", "git push", "git add", "teetimes.json"):
                self.assertNotIn(forbidden, runnable, f"{name} still does `{forbidden}`")
            self.assertRegex(text, r"permissions:\s*\n\s*contents:\s*read", name)

    def test_both_workflows_take_the_supabase_secrets(self):
        for name, text in (("scrape.yml", self.full), ("scrape-fast.yml", self.fast)):
            self.assertIn("secrets.SUPABASE_URL", text, name)
            self.assertIn("secrets.SUPABASE_SERVICE_ROLE_KEY", text, name)

    def test_the_two_cadences_have_separate_concurrency_groups(self):
        self.assertRegex(self.full, r"concurrency:\s*\n\s*group:\s*scrape\s*\n\s*cancel-in-progress:\s*false")
        self.assertRegex(self.fast, r"concurrency:\s*\n\s*group:\s*scrape-fast\s*\n\s*cancel-in-progress:\s*false")


if __name__ == "__main__":
    unittest.main()
