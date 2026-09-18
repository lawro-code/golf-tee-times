# Edge Functions

One function so far: `alert-dispatch`, which turns queued alert deliveries into
push notifications. Track E, ticket E2.

## What is deliberately NOT wired

Read this before wondering why nothing is happening.

- **There is no Apple Developer account, no APNs key, no team id.** None will be
  bought until Stage 4, after the app has been seen running. `APNS_DRY_RUN`
  therefore defaults to `1`: the sender logs the push it would have made and
  reports success without building a request or minting a token. No code in
  this repo has ever made a real APNs request.
- **Nothing has been deployed.** `supabase functions deploy` has not been run
  and no hosted Supabase project has been touched.
- **Nothing invokes this function.** There is no schedule. `pg_cron` cannot go
  in a migration (the local Postgres 17 the gate runs against has neither
  `pg_cron` nor `pg_net`), and `.github/workflows/` belongs to Track A. Wiring
  an invoker is a Stage 2 item.
- **`public.queue_watch_matches()` is ticket E1's**, not this one's. The
  dispatcher calls it and carries on if it is missing, so what is already
  queued still goes out.

## The run

```
POST /functions/v1/alert-dispatch
  Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
    — or —
  X-Dispatch-Secret: <DISPATCH_SECRET>
```

Anything else gets 401. The anon key reaches every deployed function by
default, so without that check anybody holding the app's public key could drain
the queue.

The run, in order:

1. `select public.expire_watches()` — housekeeping.
2. `select public.queue_watch_matches()` — E1's matcher queues what the last
   scrape opened up.
3. Loop: `claim_alert_batch` → group → send → `mark_alert_sent` /
   `mark_alert_failed`, until nothing is claimable or the run budget is spent.

The reply is a JSON summary and the handler never throws:

```json
{
  "ok": true,
  "dry_run": true,
  "expired": 0, "queued": 7, "groups": 2, "sent": 7,
  "failed": 0, "deferred": 1, "retired_tokens": 0, "errors": []
}
```

`deferred` is rows put back on the queue for the next run — a throttled device,
or the second of two users sharing one iPhone. Nothing is ever dropped:
`claim_alert_batch` coalesces and delays, and never writes a `suppressed` row.

## Secrets

| Name | What it is | Needed when |
|---|---|---|
| `SUPABASE_URL` | Project URL. Injected by the platform. | always |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key. Injected by the platform. | always |
| `DISPATCH_SECRET` | Shared secret for whatever ends up invoking this. | optional |
| `APNS_DRY_RUN` | `1` (default) logs instead of sending. Only `0` sends. | always |
| `APNS_ENVIRONMENT` | `sandbox` (default) or `production`. Fallback only — each device's own `push_tokens.environment` wins. | always |
| `APNS_TOPIC` | Bundle id. Defaults to `code.lawro.TeesForTheBoys`. | always |
| `APNS_KEY_ID` | The 10-character key id, the JWT's `kid`. | `APNS_DRY_RUN=0` |
| `APNS_TEAM_ID` | The 10-character team id, the JWT's `iss`. | `APNS_DRY_RUN=0` |
| `APNS_KEY_P8` | The PKCS#8 PEM from Apple's `.p8`. Escaped newlines are accepted. | `APNS_DRY_RUN=0` |

No project ref, URL or key is hardcoded anywhere. With `APNS_DRY_RUN=0` and any
of the three APNs secrets missing, the function refuses the run with a message
saying which — it does not quietly fall back to pretending.

## Checking it

```bash
cd supabase/functions
deno task check     # type check
deno task test      # 33 tests, no network, no Apple account
deno task lint
deno task fmt       # code only; README.md is excluded, deno fmt reflows its
                    # tables to 110 columns and makes them harder to read
```

Every test injects a fake transport. Between them they cover: the provider JWT
is minted once and reused inside the hour; a real ES256 signature verifies
against its public key; 410 and 400 BadDeviceToken retire the device; 429 and
5xx leave the rows queued; 403 fails non-retryably because it is a
misconfiguration and not a bad device; a five-slot group renders one
notification saying `count: 5` and `+4 more`; an unpriced slot renders
`price at course`; two users sharing one iPhone produce one push, with the
second user's rows released rather than dropped; and a push Apple has already
accepted is never released back to the queue just because the ledger write
failed, because that would push the same tee time again seconds later.

The SQL side is checked separately, by `./scripts/db_test.sh` from the repo
root.

## Why there is no supabase-js

The whole database surface is four RPCs, so `_shared/supabase.ts` calls
PostgREST with `fetch` instead. That means no dependency to pin or audit,
nothing to download at check or test time, and a cold start that is not
importing a client library to make four POSTs. If a later ticket needs table
queries, filters or realtime, swap the implementation and keep the
`ServiceClient` interface.

## Files

| File | What it does |
|---|---|
| `alert-dispatch/index.ts` | The run loop, the auth check and the HTTP handler. |
| `_shared/apns.ts` | Provider JWT, the injectable transport, response classification. |
| `_shared/notification.ts` | A coalesced group → the wire payload. **A contract with ticket E3.** |
| `_shared/supabase.ts` | Service-role RPC client. |

`Deno.serve` is behind `import.meta.main` so the tests can import `runDispatch`
without starting a server. The entry module of a deployed function is the main
module, so this serves normally once deployed.
