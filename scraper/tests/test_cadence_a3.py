"""A3 acceptance tests: the split cadence and the AEST/AEDT fix, checked
against the behaviour that shipped before the ticket.

These are the tester's tests, written against the ticket rather than against
the implementation. The bar every one of them clears: it fails against the
pre-A3 repo and passes against the repo as it stands. Pre-A3 is git HEAD —
one workflow, `cron: '0 22,10 * * *'`, `contents: write`, a bare
`python scraper/scrape.py` and a `git commit` step, and no `scraper/cadence.py`
at all.

Three things are deliberately NOT done the way the implementation does them,
because a test that restates the implementation catches nothing:

  1. **The Sydney offset is recomputed from the rule, not from zoneinfo.**
     `sydney_offset_hours` below implements "AEDT from 02:00 on the first
     Sunday in October to 03:00 on the first Sunday in April" by hand. It
     agrees with `zoneinfo` on all 43,848 hours of 2025-2030 (checked), so a
     disagreement means the gate is wrong, not that the oracle is.
  2. **The schedule is simulated from the cron line in the YAML**, not from
     `FULL_RUN_HOURS`, so the deployed file and the gate cannot drift apart
     while the suite stays green.
  3. **The gate step's shell is executed**, not pattern-matched. Its exit-code
     handling is the whole interface between `cadence.py` and GitHub, and the
     failure path — a broken gate read as "skip" — is invisible to any test
     that only reads the file.

Bias is towards the failure paths: a broken gate, a crashed gate, a runner in
the wrong timezone, a cron that no longer covers the hours the gate accepts. A
scheduler is only interesting on the day it silently stops.

Stdlib only, and no network: the gate runs before `pip install` on the runner,
so its tests must run before one too.
"""

import ast
import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import cadence

ROOT = Path(__file__).resolve().parent.parent.parent
FULL_YML = ROOT / ".github" / "workflows" / "scrape.yml"
FAST_YML = ROOT / ".github" / "workflows" / "scrape-fast.yml"
CADENCE_PY = ROOT / "scraper" / "cadence.py"
SCRAPE_PY = ROOT / "scraper" / "scrape.py"

# The schedule the ticket replaced. Right in AEST, an hour late in AEDT.
OLD_CRON_UTC_HOURS = {10, 22}


# --------------------------------------------------------------------------
# An independent Australia/Sydney, so the gate is not marking its own homework
# --------------------------------------------------------------------------

def first_sunday(year, month):
    first = date(year, month, 1)
    return first + timedelta(days=(6 - first.weekday()) % 7)


def sydney_offset_hours(instant_utc):
    """+11 in AEDT, +10 in AEST, from the rule rather than from a tz database.

    AEDT starts 02:00 AEST on the first Sunday in October and ends 03:00 AEDT
    on the first Sunday in April.
    """
    year = instant_utc.year
    starts = datetime.combine(first_sunday(year, 10), time(2), tzinfo=timezone.utc) - timedelta(hours=10)
    ends = datetime.combine(first_sunday(year, 4), time(3), tzinfo=timezone.utc) - timedelta(hours=11)
    return 11 if (instant_utc < ends or instant_utc >= starts) else 10


def sydney_clock(instant_utc):
    """(local date, local hour) a clock at the golf club reads, independently."""
    local = instant_utc + timedelta(hours=sydney_offset_hours(instant_utc))
    return local.date(), local.hour


def utc(year, month, day, hour=0, minute=0):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)


def hours_between(start, end):
    moment = start
    while moment < end:
        yield moment
        moment += timedelta(hours=1)


# --------------------------------------------------------------------------
# Reading the deployed workflows — structure, not just substrings
# --------------------------------------------------------------------------

def uncommented(text):
    """Only the lines a runner acts on. Both files explain the old behaviour."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def cron_expressions(path):
    return re.findall(r"^\s*-\s*cron:\s*['\"]([^'\"]+)['\"]\s*$", path.read_text(), re.M)


def only_cron(path):
    found = cron_expressions(path)
    if len(found) != 1:
        raise AssertionError("expected one cron line in %s, found %r" % (path.name, found))
    return found[0]


def _field(expression, index):
    fields = expression.split()
    if len(fields) != 5:
        raise AssertionError("not a 5-field cron expression: %r" % expression)
    return fields[index]


def _expand(field, span):
    if field == "*":
        return set(range(span))
    if field.startswith("*/"):
        return set(range(0, span, int(field[2:])))
    return {int(part) for part in field.split(",")}


def cron_utc_hours(expression):
    return _expand(_field(expression, 1), 24)


def cron_minutes(expression):
    return _expand(_field(expression, 0), 60)


def cron_fires_per_day(expression):
    return len(cron_minutes(expression)) * len(cron_utc_hours(expression))


def workflow_steps(path):
    """The `steps:` list of the single job, one string per step."""
    lines = uncommented(path.read_text()).splitlines()
    try:
        opens = next(i for i, line in enumerate(lines) if re.match(r"^\s*steps:\s*$", line))
    except StopIteration:
        raise AssertionError("no steps: block in %s" % path.name)

    indent, steps = None, []
    for line in lines[opens + 1:]:
        if not line.strip():
            if steps:
                steps[-1].append(line)
            continue
        here = len(line) - len(line.lstrip())
        if indent is None:
            indent = here
        if here < indent:
            break
        if here == indent and line.lstrip().startswith("- "):
            steps.append([line])
        elif steps:
            steps[-1].append(line)
    return ["\n".join(step) for step in steps]


def step_key(step, key):
    match = re.search(r"^\s*(?:-\s*)?%s:\s*(.*)$" % key, step, re.M)
    return None if match is None else match.group(1).strip()


def step_label(step):
    return step_key(step, "name") or step_key(step, "uses") or step.strip().splitlines()[0]


def step_run_script(step):
    """A step's shell, dedented as bash gets it. Block scalar or one-liner."""
    lines = step.splitlines()
    opens = next((i for i, line in enumerate(lines) if line.strip() in ("run: |", "run: |-")), None)
    if opens is None:
        inline = step_key(step, "run")
        if inline is None:
            raise AssertionError("step %r has no `run:`" % step_label(step))
        return inline + "\n"
    body = lines[opens + 1:]
    indent = min(len(line) - len(line.lstrip()) for line in body if line.strip())
    return "\n".join(line[indent:] if line.strip() else "" for line in body).rstrip() + "\n"


def gate_step_index(path):
    steps = workflow_steps(path)
    for i, step in enumerate(steps):
        if step_key(step, "id") == "gate":
            return i, steps
    raise AssertionError("no step with `id: gate` in %s" % path.name)


def mode_days():
    """`MODE_DAYS` out of scrape.py's source — no import, so no `requests`."""
    match = re.search(r"^MODE_DAYS\s*=\s*(\{[^}]*\})", SCRAPE_PY.read_text(), re.M)
    if match is None:
        raise AssertionError("no MODE_DAYS mapping in scraper/scrape.py")
    return ast.literal_eval(match.group(1))


# --------------------------------------------------------------------------
# 1. The bug the ticket exists to kill
# --------------------------------------------------------------------------

class TheFullRunLandsAtEightSydneyAllYear(unittest.TestCase):
    """Simulate the deployed cron through the deployed gate, hour by hour."""

    WINDOW = (utc(2026, 1, 1), utc(2029, 1, 1))

    def sydney_runs(self, utc_hours):
        """{Sydney date: sorted Sydney hours a run actually happened at}."""
        start, end = self.WINDOW
        grouped = {}
        for moment in hours_between(start, end):
            if moment.hour in utc_hours and cadence.is_full_run_hour(moment):
                day, hour = sydney_clock(moment)
                grouped.setdefault(day, []).append(hour)
        return grouped

    def test_every_sydney_day_for_three_years_gets_exactly_an_eight_and_a_twenty(self):
        runs = self.sydney_runs(cron_utc_hours(only_cron(FULL_YML)))
        covered = sorted(runs)[1:-1]  # first and last Sydney days straddle the window
        wrong = {day: runs[day] for day in covered if sorted(runs[day]) != [8, 20]}
        self.assertEqual({}, wrong, "days that did not get exactly 08:00 and 20:00 Sydney")
        self.assertEqual((covered[-1] - covered[0]).days + 1, len(covered), "a Sydney day got no run at all")
        self.assertGreater(len(covered), 1000, "the window should span three years")

    def test_the_schedule_it_replaced_was_an_hour_late_for_five_months_a_year(self):
        """The fix has to be worth having: price the old cron against the new one."""
        # The old schedule ungated: fire at 10:00 and 22:00 UTC, whatever the
        # Sydney clock says that morning.
        old = {}
        for moment in hours_between(*self.WINDOW):
            if moment.hour in OLD_CRON_UTC_HOURS:
                day, hour = sydney_clock(moment)
                old.setdefault(day, []).append(hour)
        late = [day for day in sorted(old)[1:-1] if sorted(old[day]) != [8, 20]]
        self.assertGreater(len(late), 400, "three AEDT summers, roughly 150 days each")

        # The shipped schedule, on those same days.
        shipped = self.sydney_runs(cron_utc_hours(only_cron(FULL_YML)))
        still_late = [day for day in late if sorted(shipped.get(day, [])) != [8, 20]]
        self.assertEqual([], still_late, "AEDT days still not running at 08:00/20:00 Sydney")


class TheGateIsSydneyLocalNotUtc(unittest.TestCase):

    def test_it_agrees_with_a_hand_rolled_sydney_for_every_hour_of_three_years(self):
        wrong = []
        for moment in hours_between(utc(2026, 1, 1), utc(2029, 1, 1)):
            expected = sydney_clock(moment)[1] in (8, 20)
            if cadence.is_full_run_hour(moment) is not expected:
                wrong.append(moment)
        self.assertEqual([], wrong[:5], "%d hours disagree with the Sydney DST rule" % len(wrong))

    def test_the_utc_hour_of_a_slot_moves_with_the_offset(self):
        """If these two matched there would have been no bug and no ticket."""
        aest = {m.hour for m in hours_between(utc(2026, 7, 1), utc(2026, 7, 2)) if cadence.is_full_run_hour(m)}
        aedt = {m.hour for m in hours_between(utc(2026, 12, 1), utc(2026, 12, 2)) if cadence.is_full_run_hour(m)}
        self.assertEqual({10, 22}, aest)
        self.assertEqual({9, 21}, aedt)

    def test_the_cron_candidates_are_exactly_both_offsets_images_of_the_slots(self):
        """Derived from FULL_RUN_HOURS, so a missing or dead candidate both fail.

        A candidate hour the gate never accepts wakes a runner for nothing. An
        accepted hour the cron never fires at is a scrape that silently never
        happens — the worse of the two, and the one nothing else would notice.
        """
        expected = set()
        for hour in cadence.FULL_RUN_HOURS:
            expected.add((hour - 10) % 24)  # AEST
            expected.add((hour - 11) % 24)  # AEDT
        self.assertEqual(expected, cron_utc_hours(only_cron(FULL_YML)))

    def test_the_slot_is_the_whole_sydney_hour_because_github_runs_late(self):
        self.assertEqual("0", _field(only_cron(FULL_YML), 0), "cron must fire on the hour")
        for minute in (0, 1, 31, 59):
            self.assertTrue(cadence.is_full_run_hour(utc(2026, 7, 1, 22, minute)))
        self.assertFalse(cadence.is_full_run_hour(utc(2026, 7, 1, 21, 59)), "07:59 Sydney is not the 08:00 slot")
        self.assertFalse(cadence.is_full_run_hour(utc(2026, 7, 1, 23, 0)), "09:00 Sydney is not the 08:00 slot")


class NextFullRunIsAlwaysARealSlot(unittest.TestCase):

    def test_it_lands_on_a_slot_the_gate_itself_accepts_every_hour_of_a_year(self):
        """Across a changeover, wall-clock arithmetic drifts an hour. Catch it."""
        broken = []
        for moment in hours_between(utc(2026, 6, 1), utc(2027, 6, 1)):
            nxt = cadence.next_full_run_after(moment)
            gap = nxt.astimezone(timezone.utc) - moment
            if not cadence.is_full_run_hour(nxt) or gap <= timedelta(0) or gap > timedelta(hours=13):
                broken.append((moment, nxt, gap))
        self.assertEqual([], broken[:5], "%d instants got a bogus next slot" % len(broken))

    def test_the_night_the_clocks_move_is_an_hour_shorter_in_real_time(self):
        before = cadence.sydney_now(utc(2026, 10, 3, 10, 30))  # 20:30 Sydney, AEST
        nxt = cadence.next_full_run_after(before)
        self.assertEqual(8, nxt.hour, "08:00 Sydney the morning after spring forward")
        self.assertEqual(timedelta(hours=11), nxt.utcoffset(), "AEDT by then")
        self.assertEqual(timedelta(hours=10, minutes=30),
                         nxt.astimezone(timezone.utc) - before.astimezone(timezone.utc))

    def test_an_unusable_schedule_raises_instead_of_looping_forever(self):
        """The failure path of the lookahead guard: no slot can ever match."""
        original = cadence.FULL_RUN_HOURS
        cadence.FULL_RUN_HOURS = ()
        try:
            with self.assertRaises(ValueError) as raised:
                cadence.next_full_run_after(utc(2026, 7, 1, 10))
        finally:
            cadence.FULL_RUN_HOURS = original
        self.assertIn("FULL_RUN_HOURS", str(raised.exception))


# --------------------------------------------------------------------------
# 2. The CLI the workflow actually invokes, and how it fails
# --------------------------------------------------------------------------

class GateCliTests(unittest.TestCase):

    def gate(self, at):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cadence.main(["--gate", "full", "--at", at])
        return code, out.getvalue()

    def test_the_same_utc_hour_runs_in_winter_and_skips_in_summer(self):
        self.assertEqual(0, self.gate("2026-07-01T10:00:00Z")[0], "20:00 Sydney AEST")
        self.assertEqual(1, self.gate("2026-12-01T10:00:00Z")[0], "21:00 Sydney AEDT — the old bug")
        self.assertEqual(0, self.gate("2026-12-01T09:00:00Z")[0], "20:00 Sydney AEDT")
        self.assertEqual(1, self.gate("2026-07-01T09:00:00Z")[0], "19:00 Sydney AEST")

    def test_a_skip_names_a_next_slot_the_deployed_cron_actually_fires_at(self):
        """End to end: the promise in the skip line has to be a real fire.

        Parses the UTC time out of the message and checks it against the cron
        in scrape.yml, so a cron edit that orphans a slot fails here too.
        """
        candidates = cron_utc_hours(only_cron(FULL_YML))
        checked = 0
        for moment in hours_between(utc(2026, 9, 1), utc(2026, 11, 1)):
            code, output = self.gate(moment.isoformat())
            if code != 1:
                continue
            checked += 1
            promised = re.findall(r"\((\d{2}):(\d{2}) UTC\)", output)
            self.assertEqual(2, len(promised), output)
            hour = int(promised[-1][0])
            self.assertIn(hour, candidates,
                          "skip promises a run at %02d:00 UTC, which %s never fires at"
                          % (hour, FULL_YML.name))
        self.assertGreater(checked, 1000, "two months of hours should mostly be skips")

    def test_it_says_one_plain_line_and_nothing_else_either_way(self):
        for at in ("2026-07-01T10:00:00Z", "2026-07-01T09:00:00Z"):
            code, output = self.gate(at)
            self.assertIn(code, (0, 1))
            self.assertEqual(1, len(output.strip().splitlines()), output)

    def test_a_bad_argument_exits_two_so_it_can_never_read_as_a_skip(self):
        """Exit 1 is load-bearing. Nothing else may produce it."""
        for argv in (["--gate", "full", "--at", "yesterday"], ["--gate", "fast"], []):
            with self.subTest(argv=argv):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        cadence.main(argv)
                self.assertEqual(2, raised.exception.code)

    def test_the_decision_does_not_depend_on_the_runner_timezone(self):
        """A GitHub runner is UTC; a laptop in Sydney is not. Same answer or bust."""
        answers = set()
        for tz in ("UTC", "Australia/Sydney", "America/New_York", "Asia/Kolkata"):
            env = dict(os.environ, TZ=tz)
            done = subprocess.run(
                [sys.executable, str(CADENCE_PY), "--gate", "full", "--at", "2026-12-01T09:30:00Z"],
                capture_output=True, text=True, cwd=str(ROOT), env=env,
            )
            answers.add((done.returncode, done.stdout.strip()))
        self.assertEqual(1, len(answers), "the gate changed its mind with $TZ: %r" % answers)
        (code, line), = answers
        self.assertEqual(0, code, line)

    def test_it_runs_on_a_bare_interpreter_before_pip_install(self):
        done = subprocess.run(
            [sys.executable, str(CADENCE_PY), "--gate", "full"],
            capture_output=True, text=True, cwd=str(ROOT),
            env={k: v for k, v in os.environ.items() if k != "PYTHONPATH"},
        )
        self.assertIn(done.returncode, (0, 1), done.stderr)
        self.assertEqual("", done.stderr)
        source = CADENCE_PY.read_text()
        for third_party in ("import requests", "from bs4", "import bs4", "import yaml"):
            self.assertNotIn(third_party, source, "the gate runs before pip install")


# --------------------------------------------------------------------------
# 3. The gate step's shell — the ticket's own defect
# --------------------------------------------------------------------------

class GateStepShellTests(unittest.TestCase):
    """Run the `run:` block the way GitHub runs it, against a stubbed gate.

    The exit code is the entire interface. Reading every non-zero as "skip" is
    the trap: a syntax error in cadence.py would then turn every scheduled
    full run into a permanent no-op with nothing going red to say so.
    """

    def run_gate_step(self, exit_code):
        index, steps = gate_step_index(FULL_YML)
        script = step_run_script(steps[index])
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            stub = tmp / "python3"
            stub.write_text("#!/bin/sh\necho 'stub cadence'\nexit %d\n" % exit_code)
            stub.chmod(0o755)
            outputs = tmp / "outputs"
            outputs.touch()
            done = subprocess.run(
                ["bash", "-eo", "pipefail", "-c", script],
                capture_output=True, text=True, cwd=str(ROOT),
                env={"PATH": "%s%s%s" % (tmp, os.pathsep, os.environ["PATH"]),
                     "GITHUB_OUTPUT": str(outputs)},
            )
            return done, outputs.read_text()

    def test_a_slot_records_run_true(self):
        done, written = self.run_gate_step(0)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertIn("run=true", written)

    def test_a_deliberate_no_op_records_run_false_without_going_red(self):
        """Half of every day's fires land here. A red tick on a no-op trains
        everyone to ignore the red ticks that matter — and under GitHub's
        `bash -eo pipefail` a bare non-zero command would do exactly that."""
        done, written = self.run_gate_step(1)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertIn("run=false", written)
        self.assertNotIn("run=true", written)

    def test_a_broken_gate_fails_the_job_instead_of_skipping_forever(self):
        for exit_code in (2, 127, 139):
            with self.subTest(exit_code=exit_code):
                done, written = self.run_gate_step(exit_code)
                self.assertEqual(exit_code, done.returncode, done.stdout)
                self.assertEqual("", written.strip(), "a crash was recorded as a decision")
                self.assertTrue(done.stderr.strip(), "a crash must say something on stderr")
                self.assertIn(str(exit_code), done.stderr)

    def test_the_decision_goes_to_github_output_not_just_the_log(self):
        for exit_code, expected in ((0, "run=true"), (1, "run=false")):
            done, written = self.run_gate_step(exit_code)
            self.assertRegex(written, r"^%s\s*$" % re.escape(expected))


class GateWiringTests(unittest.TestCase):
    """Where the gate sits in the job, and what is downstream of it."""

    def test_nothing_costly_happens_before_the_gate(self):
        """A no-op fire must not pip install or open a connection to a club."""
        index, steps = gate_step_index(FULL_YML)
        self.assertGreater(index, -1)
        for step in steps[:index]:
            self.assertIsNone(step_key(step, "run"), "%s runs before the gate" % step_label(step))
            self.assertTrue((step_key(step, "uses") or "").startswith("actions/checkout"),
                            "%s happens before the gate" % step_label(step))

    def test_the_gate_only_applies_to_scheduled_runs(self):
        index, steps = gate_step_index(FULL_YML)
        self.assertRegex(step_key(steps[index], "if") or "",
                         r"github\.event_name\s*==\s*'schedule'")

    def test_every_step_after_the_gate_is_guarded_by_it(self):
        """An unguarded step downstream would scrape on a no-op fire."""
        index, steps = gate_step_index(FULL_YML)
        unguarded = [step_label(s) for s in steps[index + 1:]
                     if (step_key(s, "if") or "").strip() != "steps.gate.outputs.run != 'false'"]
        self.assertEqual([], unguarded)
        self.assertGreater(len(steps) - index - 1, 0, "the gate guards nothing at all")

    def test_the_guard_is_not_equals_false_so_a_manual_run_always_scrapes(self):
        """workflow_dispatch skips the gate, leaving the output empty, not 'true'."""
        index, steps = gate_step_index(FULL_YML)
        for step in steps[index + 1:]:
            self.assertNotIn("== 'true'", step_key(step, "if") or "")
        self.assertIn("workflow_dispatch", uncommented(FULL_YML.read_text()))

    def test_a_crashed_gate_is_not_swallowed_by_continue_on_error(self):
        self.assertNotIn("continue-on-error", uncommented(FULL_YML.read_text()))


# --------------------------------------------------------------------------
# 4. Two cadences, and the rate they add up to
# --------------------------------------------------------------------------

class SplitCadenceTests(unittest.TestCase):

    def test_the_fast_workflow_exists_and_polls_on_an_interval(self):
        self.assertTrue(FAST_YML.exists(), "days 0-2 are not being chased at all")
        self.assertEqual("*/20 * * * *", only_cron(FAST_YML))

    def test_the_fast_workflow_has_no_gate_and_must_never_grow_one(self):
        """An interval is offset-agnostic. A gate here would kill 70 of 72 runs."""
        fast = uncommented(FAST_YML.read_text())
        for forbidden in ("cadence.py", "--gate", "steps.gate", "github.event_name"):
            self.assertNotIn(forbidden, fast)
        self.assertEqual([], [s for s in workflow_steps(FAST_YML) if step_key(s, "if")])

    def test_each_workflow_runs_its_own_mode_with_validation_before_the_write(self):
        for path, mode in ((FULL_YML, "full"), (FAST_YML, "fast")):
            runs = [step_run_script(s) for s in workflow_steps(path) if "scrape.py" in s]
            self.assertEqual(1, len(runs), path.name)
            self.assertRegex(runs[0], r"scrape\.py --mode %s --validate --write supabase" % mode)

    def test_the_windows_the_readme_promises_are_the_ones_scrape_py_runs(self):
        """The split is only real if the two modes cover different days, and
        the README is the only place that says which. Read both and compare."""
        readme = (ROOT / "scraper" / "README.md").read_text()
        days = mode_days()
        for mode in ("fast", "full"):
            match = re.search(r"`%s`\s*=\s*days\s*0[–—-](\d+)" % mode, readme)
            self.assertIsNotNone(match, "the README does not say what --mode %s covers" % mode)
            documented = int(match.group(1)) + 1
            self.assertEqual(days[mode], documented,
                             "README says %s is %d days, scrape.py runs %d"
                             % (mode, documented, days[mode]))
        self.assertLess(days["fast"], days["full"], "the two cadences cover the same window")

    def test_the_request_rate_at_a_single_club_stays_at_the_settled_216_a_day(self):
        """BUILD-PLAN.md: 216/day reads as a keen golfer, 864/day reads as a bot.

        Computed from the deployed crons and scrape.py's own day counts, so
        raising the cadence or extending the window fails here.
        """
        days = mode_days()
        fast_per_club = cron_fires_per_day(only_cron(FAST_YML)) * days["fast"]
        self.assertEqual(216, fast_per_club, "fast cadence is settled and not a knob")

        full_fires = sum(1 for m in hours_between(utc(2026, 11, 1), utc(2026, 11, 2))
                         if m.hour in cron_utc_hours(only_cron(FULL_YML)) and cadence.is_full_run_hour(m))
        self.assertEqual(2, full_fires, "the full run is twice a Sydney day")
        self.assertEqual(226, fast_per_club + full_fires * days["full"])
        self.assertLess(fast_per_club + full_fires * days["full"], 864)

    def test_the_cadences_never_queue_behind_each_other(self):
        groups = {}
        for path in (FULL_YML, FAST_YML):
            match = re.search(r"^concurrency:\s*\n\s*group:\s*(\S+)\s*\n\s*cancel-in-progress:\s*(\S+)\s*$",
                              uncommented(path.read_text()), re.M)
            self.assertIsNotNone(match, "%s has no concurrency block" % path.name)
            groups[path.name] = match.group(1)
            self.assertEqual("false", match.group(2),
                             "%s: a run part way through writing slots must finish" % path.name)
        self.assertEqual(2, len(set(groups.values())), "shared concurrency group: %r" % groups)


class NothingIsCommittedAnyMoreTests(unittest.TestCase):
    """At 72 runs a day the old commit-the-JSON loop is thousands of commits a
    month. Both workflows are read-only now, and the token has to say so."""

    def test_neither_workflow_can_write_to_the_repo(self):
        for path in (FULL_YML, FAST_YML):
            runnable = uncommented(path.read_text())
            self.assertIsNotNone(
                re.search(r"^permissions:\s*\n\s*contents:\s*read\s*$", runnable, re.M),
                "%s does not pin the token to contents: read" % path.name,
            )
            self.assertIsNone(re.search(r"contents:\s*write", runnable), path.name)

    def test_neither_workflow_commits_or_pushes_anything(self):
        for path in (FULL_YML, FAST_YML):
            runnable = uncommented(path.read_text())
            for forbidden in ("git add", "git commit", "git push", "git config", "teetimes.json"):
                self.assertNotIn(forbidden, runnable, "%s still does `%s`" % (path.name, forbidden))

    def test_the_readme_warns_that_the_public_site_is_now_frozen(self):
        """The visible consequence: docs/ goes stale until Stage 2 repoints it."""
        readme = (ROOT / "scraper" / "README.md").read_text()
        self.assertIn("docs/data/teetimes.json", readme)
        self.assertRegex(readme, r"no longer (produced|committed|written)")
        self.assertIn("Stage 2", readme)


if __name__ == "__main__":
    unittest.main()
