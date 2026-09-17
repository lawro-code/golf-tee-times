export const meta = {
  name: 'tees-stage3-redteam',
  description: 'Tees for the Boys — Stage 3: red team attacks the built app, findings survive adversarial verification before they count',
  phases: [
    { title: 'Attack', detail: 'Each agent attacks one surface and tries to break it' },
    { title: 'Verify', detail: 'Three independent lenses try to refute each finding' },
    { title: 'Fix', detail: 'Confirmed defects get fixed and re-tested' },
    { title: 'Sweep', detail: 'A critic looks for what the attack surfaces missed' },
  ],
}

const REPO = '/Users/willlawrence/golf-tee-times'

const RULES = `
The repo is at ${REPO}. Read the code before claiming anything about it.
Never write to Supabase production — local or branch databases only.
Course roster is frozen at 15. Do not add or remove courses.
A finding you cannot reproduce is not a finding. Say so rather than padding.
`

// Each surface is a distinct way the app can fail. Deliberately not one generic
// "find bugs" prompt — a shared lens finds a shared subset.
const SURFACES = [
  { key: 'empty-data', brief: 'The feed is empty, or a course returns zero slots, or every course does. Does the app show a sensible empty state or a blank screen? Does a filter that matches nothing look broken or look empty-on-purpose?' },
  { key: 'stale-data', brief: 'The scraper has not run for six hours, or a day, or a week. Does the app tell the user the data is old, or silently show tee times that no longer exist? What does a slot that has already passed look like?' },
  { key: 'no-network', brief: 'Airplane mode, flaky connection, request timeout, Supabase down, DNS failure. Cold launch offline with no cache. Cold launch offline WITH a cache. Connection dropping mid-refresh.' },
  { key: 'bad-upstream', brief: 'A club returns HTTP 500, or 403, or a login redirect, or HTML whose structure changed. Does one broken club break the run for the other fourteen? Does a partial scrape silently look like a complete one?' },
  { key: 'timezone', brief: 'The AEST/AEDT boundary — Sydney switches in April and October. A tee time at 2am on the changeover night. A scrape that runs across the boundary. Dates near midnight. The existing GitHub Actions cron already drifts an hour for half the year; check what that does to displayed times.' },
  { key: 'alert-dupes', brief: 'Exactly-once push delivery. A slot that stays open across twelve consecutive scrapes must send ONE notification. A slot that closes and reopens. Two watches matching the same slot. A watch matching forty slots at once during a release window. A user with twenty watches.' },
  { key: 'scale', brief: 'A course with 200 slots in a day. All 15 courses full. A course name long enough to wrap three lines. A price tier list with eight entries. Scroll performance and memory with a full dataset.' },
  { key: 'accessibility', brief: 'Maximum Dynamic Type on every screen — does anything clip, overlap or become unreachable? VoiceOver on the slot list and the filter controls. Colour contrast in both light and dark. Tap target sizes.' },
  { key: 'decoder-fuzz', brief: 'Malformed, truncated, null-filled and type-shifted payloads against the decoder. Missing required fields. Unexpected extra fields. A price that is a string where a number is expected. Empty arrays where objects are expected. The app must degrade, never crash.' },
  { key: 'deep-link', brief: 'The tap-through to MiClub. A club whose booking page needs a free public-member registration first. A slot that sold out between scrape and tap. A malformed or missing booking URL. Push notification tapped when the app is cold, backgrounded, and foregrounded.' },
]

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          file: { type: 'string' },
          repro: { type: 'string' },
          consequence: { type: 'string' },
        },
        required: ['id', 'title', 'severity', 'repro', 'consequence'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
  },
  required: ['refuted', 'reasoning'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    fixed: { type: 'boolean' },
    files_changed: { type: 'array', items: { type: 'string' } },
    test_added: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['fixed', 'files_changed'],
}

const LENSES = [
  'correctness — is the described behaviour actually wrong, or is it the intended design?',
  'reproducibility — read the real code path and decide whether these exact steps produce this exact result',
  'consequence — even if real, does this matter to someone using the app, or is it theoretical?',
]

const seen = new Set()
const confirmed = []
let dryRounds = 0
let round = 0

// Keep attacking until two consecutive rounds surface nothing new. A fixed
// round count misses the tail; this does not.
while (dryRounds < 2 && round < 4) {
  round++
  log(`Attack round ${round} — ${SURFACES.length} surfaces`)

  const found = (
    await parallel(
      SURFACES.map(s => () =>
        agent(
          `${RULES}

You are red-teaming "Tees for the Boys", a SwiftUI iOS app over a Python
scraper and Supabase. Your assigned surface is ${s.key}.

${s.brief}

${seen.size ? `Already known — do NOT report these again:\n${[...seen].join('\n')}` : ''}

Break it. Read the real code, construct the real failing case, and only report
what you can actually reproduce. For each finding give steps concrete enough
that someone else can follow them, and say what the user experiences.

Finding nothing is a legitimate and useful result. Do not invent problems to
look thorough.`,
          { label: `attack:${s.key}:r${round}`, phase: 'Attack', schema: FINDINGS_SCHEMA }
        )
      )
    )
  )
    .filter(Boolean)
    .flatMap(r => r.findings || [])

  const fresh = found.filter(f => !seen.has(f.title))
  if (!fresh.length) {
    dryRounds++
    log(`Round ${round}: nothing new (${dryRounds}/2 dry)`)
    continue
  }
  dryRounds = 0
  fresh.forEach(f => seen.add(f.title))
  log(`Round ${round}: ${fresh.length} new — verifying`)

  // Three different lenses, not three identical skeptics. Survives on 2 of 3.
  const judged = await parallel(
    fresh.map(f => () =>
      parallel(
        LENSES.map(lens => () =>
          agent(
            `${RULES}

Try to REFUTE this finding. Default to refuted:true when you are uncertain —
a wrong finding wastes more time than a missed one at this stage.

Lens for your judgement: ${lens}

FINDING: ${f.title}
Severity claimed: ${f.severity}
Where: ${f.file || 'unspecified'}
Steps: ${f.repro}
Claimed consequence: ${f.consequence}

Read the actual code path. Decide.`,
            { label: `verify:${f.id}`, phase: 'Verify', schema: VERDICT_SCHEMA }
          )
        )
      ).then(votes => {
        const v = votes.filter(Boolean)
        const survives = v.length && v.filter(x => !x.refuted).length >= 2
        return survives ? f : null
      })
    )
  )

  const survivors = judged.filter(Boolean)
  log(`Round ${round}: ${survivors.length}/${fresh.length} survived verification`)
  confirmed.push(...survivors)
}

// Fix what survived, worst first.
const RANK = { critical: 0, high: 1, medium: 2, low: 3 }
const toFix = confirmed.sort((a, b) => RANK[a.severity] - RANK[b.severity])

log(`${toFix.length} confirmed defects — fixing`)

const fixes = await parallel(
  toFix.map(f => () =>
    agent(
      `${RULES}

Fix this confirmed defect, then prove it is fixed.

${f.title} [${f.severity}]
Where: ${f.file || 'unspecified'}
Steps to reproduce: ${f.repro}
Consequence: ${f.consequence}

Write a regression test that fails against the current code and passes after
your fix — verify it fails first, or you have not proven anything. Make the
smallest correct change. Do not refactor around it.`,
      { label: `fix:${f.id}`, phase: 'Fix', schema: FIX_SCHEMA }
    ).then(fix => ({ finding: f, fix }))
  )
)

// What did the ten surfaces fail to look at?
const sweep = await agent(
  `${RULES}

You are the completeness critic for the Stage 3 red team.

These surfaces were attacked: ${SURFACES.map(s => s.key).join(', ')}
Over ${round} rounds, ${confirmed.length} defects were confirmed and fixed:
${toFix.map(f => `  [${f.severity}] ${f.title}`).join('\n') || '  (none)'}

Your job is to name what was NOT examined. A failure mode no surface covers.
A claim in the fixes above that was asserted rather than verified. A part of
the system nobody read. Something specific to this app — Sydney timezones,
MiClub's HTML, Apple's push semantics, Supabase row limits — that a generic
checklist would skip.

Be concrete. "More testing would help" is not an answer.`,
  { label: 'sweep', phase: 'Sweep' }
)

const applied = fixes.filter(Boolean).filter(x => x.fix && x.fix.fixed)

return {
  rounds: round,
  confirmed: confirmed.length,
  fixed: applied.length,
  unfixed: fixes.filter(Boolean).filter(x => !x.fix || !x.fix.fixed).map(x => x.finding.title),
  by_severity: {
    critical: confirmed.filter(f => f.severity === 'critical').length,
    high: confirmed.filter(f => f.severity === 'high').length,
    medium: confirmed.filter(f => f.severity === 'medium').length,
    low: confirmed.filter(f => f.severity === 'low').length,
  },
  gaps: sweep,
}
