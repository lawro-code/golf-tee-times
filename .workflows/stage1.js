export const meta = {
  name: 'tees-stage1',
  description: 'Tees for the Boys — Stage 1: five parallel build tracks (auth, search, alerts, scraper, design), each ticket reviewed and tested before it lands',
  phases: [
    { title: 'Plan', detail: 'One lead per track breaks it into tickets with exclusive file ownership' },
    { title: 'Build', detail: 'Workers implement their tickets — no two agents share a file' },
    { title: 'Review', detail: 'A reviewer reads each diff; a rejection sends the worker back to fix it' },
    { title: 'Test', detail: 'A tester writes a test that must fail before the change and pass after' },
  ],
}

// The gate is deliberately NOT a phase here. Running ./scripts/build.sh and
// reporting what it printed is a shell command, not a judgement call, and an
// agent in the middle of it can only add a chance of reporting green on a red
// build. The main session runs the verification commands itself and pastes the
// real output. This workflow's job ends at "the code is written and tested".

// ---------------------------------------------------------------------------
// Stage 1 assumes Stage 0 has already landed: Supabase schema, the frozen data
// contract, a golden fixture, the Xcode project, CI. Tracks run concurrently
// because they touch disjoint files — that is the whole reason this is safe.
// ---------------------------------------------------------------------------

const REPO = '/Users/willlawrence/golf-tee-times'

const HOUSE_RULES = `
HOUSE RULES — these override any instinct to be helpful beyond your ticket.
- You own ONLY the files listed in your ticket. Do not create, edit, rename or
  delete any file outside that list, even to fix something obviously broken.
  If you need a change elsewhere, stop and report it as a blocker instead.
- Never write to Supabase production. If a task seems to need it, report a
  blocker. Local or branch databases only.
- Do not replace the Python scraper with Playwright or any headless browser.
  MiClub serves plain server-rendered HTML at a fixed URL. Requests +
  BeautifulSoup is correct and stays.
- The repo is at ${REPO}. Read CONTRACT.md FIRST — it is the frozen Stage 0
  contract and it answers most of what you are about to guess about. Then read
  what already exists before writing anything.
- Verify your work with the real commands and paste their output:
    ./scripts/build.sh <YourScheme>          build your module
    ./scripts/build.sh <YourScheme> test     build and run your module's tests
    ./scripts/db_test.sh                     migrations + schema assertions
    python3 contract/validate.py contract/fixtures/golden.json
  NEVER run xcodegen directly — scripts/build.sh regenerates the project under
  a lock, and concurrent generations corrupt it.
- FROZEN, nobody edits during Stage 1: contract/**, ios/project.yml,
  ios/TeesForTheBoys/Contract/**, supabase/migrations/000*_*.sql, CONTRACT.md.
  If you need one changed, stop and report it as a blocker.
- Your track is its own framework target, so anything another track needs from
  you must be marked public. Swift language mode is 5 and warnings are errors.
- Course roster is FROZEN at 15 courses. Do not add, remove or reorder courses
  in courses.json. A backlog of researched additions exists and is not yours.
- Scrape cadence is settled: every 20 minutes for days 0-2 only, existing
  twice-daily cron for days 3-5. Do not raise it.
- OUT OF SCOPE for this version, do not build or scaffold for them: friend
  invites, copy-link joins, a friend graph, playing partners, saved teams,
  the team shuffle. They are a later version. Building hooks for them now
  is speculative work and counts as going outside your ticket.
`

const TRACKS = [
  {
    key: 'A-scraper',
    title: 'Scraper hardening',
    owns: 'scraper/**, courses.json (read-only), .github/workflows/scrape*.yml',
    mandate: `Harden the existing Python scraper and point it at Supabase.
      - Write parsed slots to Supabase instead of committing docs/data/teetimes.json to git.
      - Implement the split cadence: days 0-2 every 20 minutes, days 3-5 on the existing
        twice-daily schedule. Two workflow files or one with a mode flag, your call.
      - Per-course failure isolation: one club returning 500 or malformed HTML must not
        abort the run or blank out the other 14 courses.
      - Fix the AEST/AEDT drift. The current cron comment admits it fires an hour late
        for half the year.
      - Validate output against the Stage 0 schema before writing. Add --validate.
      - Capture par and holes per course into the data written to Supabase. Note that
        a booking's hole count is NOT always the course's — read CONTRACT.md on that
        before you assume it is. The length_metres column already exists in the frozen
        schema and stays null: MiClub does not publish course length. Do not populate
        it, do not invent values, and do not scrape club websites for it.
      - Emit PER-DAY scrape status, not just per-course. Today scrape_course() only
        reports an error when ALL days failed, so a course reached on three days out of
        five reads as completely healthy and the stale-data banner stays silent. The
        contract already has the fields for this (see course_days in CONTRACT.md);
        the scraper has to fill them honestly.`,
  },
  {
    key: 'B-data',
    title: 'Swift data layer',
    owns: 'ios/TeesForTheBoys/Data/**, ios/TeesForTheBoysTests/Data/**',
    mandate: `Build the Swift data layer against the Stage 0 contract and golden fixture.
      - Supabase Auth: email and password sign-up and sign-in. Session persisted in the
        keychain, restored on launch, refreshed before expiry. Sign out clears it.
      - Watches and booking confirmations belong to the signed-in user. An unauthenticated
        user can still browse and filter — the wall goes in front of alerts, not browsing.
      - Supabase fetch, decode into the frozen model types, typed errors.
      - On-disk cache so the app opens instantly and works in airplane mode.
      - Refresh policy: what is stale, when to refetch, how to avoid a thundering herd.
      - Decoding must survive a malformed or partial payload without crashing — a bad
        course is dropped with a logged reason, not a fatal error.
      - No UI code. No SwiftUI imports in this track.`,
  },
  {
    key: 'C-ui',
    title: 'SwiftUI screens',
    owns: 'ios/TeesForTheBoys/Views/**, ios/TeesForTheBoysTests/Views/**',
    mandate: `Build the screens against the golden fixture only — no network in this track.

      SEARCH IS THE PRODUCT. The filter experience should feel like Airbnb's — fast,
      obvious, thumb-reachable, results updating as you go. Not a settings form.
      Filters: day, time of day, number of players, number of holes, price, drive time
      from Bondi. Holes DEFAULTS TO 18 and remembers what the user last chose.

      - Result list: each slot shows course, time, price, players, AND par and holes.
        Par and holes are already in courses.json — surface them, they are not optional.
      - Slot detail deep-links out to the MiClub booking page.
      - Mark courses that need a free public-member registration before checkout, so a
        tap-through is not a surprise.
      - ALERT FROM SEARCH — the important one. The active filters already describe a
        watch completely, so creating one is a SINGLE BUTTON, never a wizard. The button
        is present on every search and becomes the primary call to action when results
        are empty. "No 8am Saturdays at The Coast — alert me when one opens." A user who
        wants to adjust it before saving can, but the default path is one tap.
      - Sign in and sign up screens. Browsing works signed-out; the wall goes in front of
        alerts, not in front of search.
      - Onboarding: after first sign-in, ask for notification permission in context —
        explain what it is for before the system prompt, never cold.
      - DID YOU BOOK — when the user returns to the app after tapping out to MiClub, ask
        once whether they booked that slot. A yes cancels any alert that slot satisfied
        and adds it to an upcoming rounds list. A no or a dismiss costs them nothing and
        is not asked again for that slot.
      - Upcoming rounds: a simple list of confirmed bookings. NO playing partners, NO
        teams, NO shuffle — that is a later version, deliberately out of scope. Do not
        build toward it speculatively.
      - Empty, loading, stale and offline states are part of the work, not afterthoughts.
      - Must render correctly at max Dynamic Type and under VoiceOver.`,
  },
  {
    key: 'D-design',
    title: 'Design system',
    owns: 'ios/TeesForTheBoys/DesignSystem/**, ios/TeesForTheBoysTests/DesignSystem/**',
    mandate: `Port the existing website's visual system into SwiftUI tokens and components.
      - The source of truth is docs/style.css in the repo: the Augusta palette
        (cream #f2e6c2, royal green #013d22, gold #c9a04e, Masters red #c8102e,
        twilight #b6541c), Playfair Display for display type, Inter for body.
      - Ship colour, type, spacing and radius tokens plus the shared components track C
        needs: slot row, course header, filter chip, price tier badge, empty state.
      - Light and dark both. The dark variant should read like a Masters scoreboard —
        near-black green ground, cream text, gold accents — not a naive inversion.
      - No screens. Components and tokens only.`,
  },
  {
    key: 'E-alerts',
    title: 'Alert matcher and push',
    owns: 'supabase/functions/**, supabase/migrations/alerts_*.sql, ios/TeesForTheBoys/Push/**, ios/TeesForTheBoysTests/Push/**',
    mandate: `Build the watch matcher and the Apple Push path.
      - On each scrape, diff newly-seen slots against stored watches and queue matches.
      - Exactly-once semantics: a slot that stays open across twelve scrapes sends ONE
        push, not twelve. This is the single most important property in this track.
      - Rate limit per user so a big release window cannot fire forty notifications.
      - A watch is satisfied and stops firing when the user confirms they booked a slot
        that matches it. Nothing is more annoying than being alerted about a tee time you
        have already booked.
      - Watches expire on their own once their target date has passed.
      - APNs sender holding the key server-side. The iOS side registers for push and
        routes a tap to the right slot.
      - Local and branch databases only. Never touch Supabase production.`,
  },
]

const TICKETS_SCHEMA = {
  type: 'object',
  properties: {
    tickets: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          detail: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
        required: ['id', 'title', 'detail', 'files'],
      },
    },
    conflicts: { type: 'array', items: { type: 'string' } },
  },
  required: ['tickets'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    ticket_id: { type: 'string' },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    complete: { type: 'boolean' },
    blocker: { type: 'string' },
  },
  required: ['ticket_id', 'summary', 'files_changed', 'complete'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    approved: { type: 'boolean' },
    critique: { type: 'string' },
    must_fix: { type: 'array', items: { type: 'string' } },
  },
  required: ['approved', 'critique'],
}

const TEST_SCHEMA = {
  type: 'object',
  properties: {
    test_files: { type: 'array', items: { type: 'string' } },
    failed_before: { type: 'boolean' },
    passes_after: { type: 'boolean' },
    notes: { type: 'string' },
  },
  required: ['test_files', 'failed_before', 'passes_after'],
}

// ---------------------------------------------------------------------------

log(`Stage 1 — ${TRACKS.length} tracks, exclusive file ownership per agent.`)

const results = await pipeline(
  TRACKS,

  // 1. Lead decomposes the track into tickets with non-overlapping file lists.
  track =>
    agent(
      `${HOUSE_RULES}

You are the track lead for ${track.key} — ${track.title}.

MANDATE
${track.mandate}

YOUR TRACK OWNS THESE PATHS AND NOTHING ELSE:
${track.owns}

Read the repo first. Then break this track into 2-4 tickets that can be built
CONCURRENTLY by different agents. The hard constraint: no two tickets may list
the same file. If two pieces of work genuinely need the same file, merge them
into one ticket rather than splitting them.

Each ticket needs a specific, unambiguous file list — real paths, not globs.
Report anything you had to leave out because it would have forced a shared file.`,
      { label: `lead:${track.key}`, phase: 'Plan', schema: TICKETS_SCHEMA }
    ),

  // 2..4. Each ticket runs build -> review -> test independently.
  (plan, track) => {
    if (!plan || !plan.tickets || !plan.tickets.length) {
      log(`${track.key}: lead returned no tickets — track skipped`)
      return []
    }
    log(`${track.key}: ${plan.tickets.length} tickets`)

    return parallel(
      plan.tickets.map(ticket => () =>
        agent(
          `${HOUSE_RULES}

You are a worker on track ${track.key} — ${track.title}.

TICKET ${ticket.id}: ${ticket.title}
${ticket.detail}

FILES YOU OWN — you may write these and ONLY these:
${ticket.files.map(f => `  ${f}`).join('\n')}

Implement it properly. Follow the conventions already in the repo rather than
importing your own. If you hit something that needs a file you do not own,
stop and report it as a blocker — do not reach outside your list.`,
          { label: `build:${ticket.id}`, phase: 'Build', schema: BUILD_SCHEMA }
        )
          .then(build => {
            if (!build) return null
            return agent(
              `${HOUSE_RULES}

You are reviewing work on track ${track.key}.

TICKET ${ticket.id}: ${ticket.title}
${ticket.detail}

The worker reports: ${build.summary}
Files it changed: ${build.files_changed.join(', ')}

Read the actual diff. Review the code that is there, not the description of it.
Check: does it do what the ticket asked; does it handle failure; does it match
the surrounding code's conventions; did it write outside its file list; is there
a simpler correct version.

Be willing to approve. Reject only for something that would actually bite —
a real defect, a missed requirement, or a file written that was not owned.`,
              { label: `review:${ticket.id}`, phase: 'Review', schema: REVIEW_SCHEMA }
            ).then(review => ({ ticket, build, review }))
          })
          .then(r => {
            if (!r) return null
            if (!r.review || r.review.approved !== false) return r
            // A rejection has to cost the worker something or it is just prose.
            // Previously `must_fix` was collected, interpolated into the
            // tester's prompt as a sentence, and then dropped — a rejected
            // ticket landed exactly like an approved one. One rework pass and
            // one re-review, bounded, so a stubborn disagreement between two
            // agents cannot loop forever.
            return agent(
              `${HOUSE_RULES}

You are back on ticket ${ticket.id} — ${ticket.title} — because the reviewer
rejected your work.

REVIEWER'S CRITIQUE
${r.review.critique}

MUST FIX
${(r.review.must_fix || []).map(m => `  - ${m}`).join('\n') || '  (see the critique above)'}

FILES YOU OWN — still these and ONLY these:
${ticket.files.map(f => `  ${f}`).join('\n')}

Fix exactly what was called out. Do not take the opportunity to redesign
anything else. If you believe the reviewer is wrong, say so plainly in your
summary rather than silently ignoring it.`,
              { label: `rework:${ticket.id}`, phase: 'Review', schema: BUILD_SCHEMA }
            ).then(rework => {
              if (!rework) return r
              return agent(
                `${HOUSE_RULES}

Re-review ticket ${ticket.id} — ${ticket.title} — after a rework pass.

It was rejected for:
${r.review.critique}

The worker now reports: ${rework.summary}
Files it changed: ${rework.files_changed.join(', ')}

Read the diff again. Has the rejection actually been addressed? Approve if it
has, even if you would have written it differently. You are checking that the
specific objection is answered, not running a fresh review.`,
                { label: `rereview:${ticket.id}`, phase: 'Review', schema: REVIEW_SCHEMA }
              ).then(rr => ({ ...r, build: rework, review: rr || r.review, reworked: true }))
            })
          })
          .then(r => {
            if (!r) return null
            return agent(
              `${HOUSE_RULES}

You are the tester for track ${track.key}, ticket ${ticket.id}: ${ticket.title}

Implementation summary: ${r.build.summary}
Files: ${r.build.files_changed.join(', ')}
Reviewer said: ${!r.review ? 'the review did not complete — judge the code on its own merits' : r.review.approved ? 'approved' : 'REJECTED — ' + r.review.critique}

Write tests that prove the behaviour this ticket claims. The discipline: each
test must FAIL against the code as it was before this ticket and PASS after.
If a test passes either way it is testing nothing — throw it out and write a
better one. Run them and report honestly, including if they do not pass.

Cover the failure paths, not just the happy one.`,
              { label: `test:${ticket.id}`, phase: 'Test', schema: TEST_SCHEMA }
            ).then(test => ({ ...r, test }))
          })
          // A dead agent anywhere in this chain used to reject the whole thunk,
          // which parallel() turns into null and .filter(Boolean) then drops —
          // so a ticket whose code was already written and on disk vanished
          // from the report entirely. It happened to four tracks at once when
          // the session limit hit mid-review. Degrade to a partial record
          // instead: the files are real whether or not the paperwork finished.
          .catch(err => ({
            ticket,
            build: null,
            review: null,
            test: null,
            error: String((err && err.message) || err),
          }))
      )
    )
  },

)

// No gate stage. The main session runs ./scripts/build.sh, ./scripts/db_test.sh
// and contract/validate.py itself and reports their real output. What this
// returns is the paperwork the gate needs: what got built, what a reviewer
// still objects to, and which tests prove nothing.

const byTrack = TRACKS.map((track, i) => ({
  track: track.key,
  title: track.title,
  tickets: (results[i] || []).filter(Boolean).map(d => ({
    id: d.ticket.id,
    title: d.ticket.title,
    approved: d.review ? d.review.approved : null,
    reworked: !!d.reworked,
    must_fix: d.review && !d.review.approved ? d.review.must_fix || [] : [],
    tests_pass: d.test ? d.test.passes_after : null,
    failed_before: d.test ? d.test.failed_before : null,
    files: (d.build && d.build.files_changed) || [],
    blocker: (d.build && d.build.blocker) || null,
    error: d.error || null,
  })),
}))

const all = byTrack.flatMap(t => t.tickets)

log(
  `Stage 1 build complete — ${all.length} tickets across ${TRACKS.length} tracks. ` +
    `${all.filter(t => t.reworked).length} reworked after rejection, ` +
    `${all.filter(t => t.approved === false).length} still rejected, ` +
    `${all.filter(t => t.tests_pass === false).length} with failing tests.`
)
log('Verification commands are not run here — the main session runs them.')

return {
  tracks: byTrack,
  // Still rejected after a rework pass: a human decides these, not an agent.
  unapproved: all
    .filter(t => t.approved === false)
    .map(t => `${t.id}: ${t.must_fix.join('; ') || 'see review critique'}`),
  failing_tests: all.filter(t => t.tests_pass === false).map(t => t.id),
  // failed_before === false means the test passed against the OLD code too, so
  // it is testing nothing. House rule 3 exists precisely for this.
  tests_that_prove_nothing: all.filter(t => t.failed_before === false).map(t => t.id),
  blockers: all.filter(t => t.blocker).map(t => `${t.id}: ${t.blocker}`),
}
