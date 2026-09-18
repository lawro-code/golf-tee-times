// alert-dispatch — the run that turns queued matches into notifications.
//
// One invocation: expire stale watches, ask E1's matcher to queue what the
// last scrape opened up, then claim, coalesce, send and record until the queue
// is empty or the run budget is spent.
//
// NOTHING INVOKES THIS YET. There is no schedule, no deployment and no APNs
// key — see README.md. It runs correctly against a local database in dry run,
// which is all Stage 1 asks of it.
//
// Two rules the loop is built around:
//   * a failure on one user must never abort the run
//   * the handler never throws; the worst case is a 500 with a JSON reason

import {
  type ApnsConfig,
  apnsConfigFromEnv,
  type ApnsOutcome,
  createProviderTokenCache,
  defaultLogger,
  type FetchLike,
  isApnsEnvironment,
  type Logger,
  sendPush,
} from "../_shared/apns.ts";
import {
  type AlertGroup,
  type AlertRow,
  buildNotification,
  groupAlertRows,
  planDevices,
} from "../_shared/notification.ts";
import { createServiceClient, type EnvReader, type ServiceClient } from "../_shared/supabase.ts";

export interface DispatchSummary {
  /** Watches deactivated because their date has passed. */
  expired: number;
  /** Deliveries E1 queued on this run. */
  queued: number;
  /** Coalesced groups sent — one notification each. */
  groups: number;
  /** Delivery rows moved to 'sent'. */
  sent: number;
  /** Delivery rows moved to 'failed'. Retryable ones stay queued and are not counted. */
  failed: number;
  /** Delivery rows released back to the queue for a later run. */
  deferred: number;
  /** push_tokens rows deleted after a 410 or a BadDeviceToken. */
  retired_tokens: number;
  /** Anything that went wrong without stopping the run. */
  errors: string[];
}

export interface DispatchOptions {
  db: ServiceClient;
  apns: ApnsConfig;
  transport: FetchLike;
  providerToken: () => Promise<string>;
  log?: Logger;
  maxUsers?: number;
  maxSlotsPerUser?: number;
  /** Stop claiming after this many batches, however much is left. */
  maxBatches?: number;
  /** Stop claiming once the run has taken this long. */
  budgetMs?: number;
  now?: () => number;
}

const DEFAULTS = {
  maxUsers: 200,
  maxSlotsPerUser: 12,
  maxBatches: 25,
  budgetMs: 45_000,
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * The whole run. Exported so it can be driven by a test with a fake database
 * and a fake transport; nothing in here reads the environment.
 */
export async function runDispatch(options: DispatchOptions): Promise<DispatchSummary> {
  const log = options.log ?? defaultLogger;
  const now = options.now ?? Date.now;
  const maxUsers = options.maxUsers ?? DEFAULTS.maxUsers;
  const maxSlotsPerUser = options.maxSlotsPerUser ?? DEFAULTS.maxSlotsPerUser;
  const maxBatches = options.maxBatches ?? DEFAULTS.maxBatches;
  const budgetMs = options.budgetMs ?? DEFAULTS.budgetMs;

  const summary: DispatchSummary = {
    expired: 0,
    queued: 0,
    groups: 0,
    sent: 0,
    failed: 0,
    deferred: 0,
    retired_tokens: 0,
    errors: [],
  };

  // Housekeeping, then E1's matcher. Either can fail without the queue that is
  // already there becoming undeliverable, so neither stops the run.
  try {
    summary.expired = (await options.db.rpc<number>("expire_watches")) ?? 0;
  } catch (error) {
    summary.errors.push(`expire_watches: ${errorMessage(error)}`);
    log("error", "expire_watches failed", { error: errorMessage(error) });
  }

  try {
    summary.queued = (await options.db.rpc<number>("queue_watch_matches")) ?? 0;
  } catch (error) {
    summary.errors.push(`queue_watch_matches: ${errorMessage(error)}`);
    log("error", "queue_watch_matches failed", { error: errorMessage(error) });
  }

  const startedAt = now();

  // One device gets one push per run even if two users on it both matched.
  const tokensUsedThisRun = new Set<string>();
  // A user gets one group per run. Without this, a group we released (a shared
  // device, a 429) would be claimed again on the next pass round the loop and
  // the loop would never end.
  const usersHandledThisRun = new Set<string>();

  for (let batch = 0; batch < maxBatches; batch++) {
    if (now() - startedAt > budgetMs) {
      log("warn", "run budget spent; the rest stays queued", { batch });
      break;
    }

    let rows: AlertRow[];
    try {
      rows = (await options.db.rpc<AlertRow[]>("claim_alert_batch", {
        p_max_users: maxUsers,
        p_max_slots_per_user: maxSlotsPerUser,
      })) ?? [];
    } catch (error) {
      summary.errors.push(`claim_alert_batch: ${errorMessage(error)}`);
      log("error", "claim_alert_batch failed", { error: errorMessage(error) });
      break;
    }

    if (rows.length === 0) break;

    const groups = groupAlertRows(rows);
    const fresh = groups.filter((g) => !usersHandledThisRun.has(g.userId));
    const repeats = groups.filter((g) => usersHandledThisRun.has(g.userId));

    for (const group of repeats) {
      await release(options, summary, group, "deferred: already handled in this run", log);
    }

    if (fresh.length === 0) break;

    for (const group of fresh) {
      usersHandledThisRun.add(group.userId);
      try {
        await handleGroup(options, summary, group, tokensUsedThisRun, log);
      } catch (error) {
        // One user's group must never take the run down with it.
        summary.errors.push(`user ${group.userId}: ${errorMessage(error)}`);
        log("error", "group failed", { user: group.userId, error: errorMessage(error) });
        await release(options, summary, group, `dispatcher error: ${errorMessage(error)}`, log);
      }
    }
  }

  return summary;
}

async function handleGroup(
  options: DispatchOptions,
  summary: DispatchSummary,
  group: AlertGroup,
  tokensUsedThisRun: Set<string>,
  log: Logger,
): Promise<void> {
  const { send, deferred } = planDevices(group, tokensUsedThisRun);

  if (send.length === 0) {
    // Every device this user has already took a push this run — two mates on
    // one iPhone. Their rows are released, not dropped: next run the other
    // user is inside their ten-minute cool-down and the phone is free.
    log("info", "every device for this user already had a push this run", {
      user: group.userId,
      tokens: deferred.length,
    });
    await release(
      options,
      summary,
      group,
      "deferred: another user on this device was pushed in the same run",
      log,
    );
    return;
  }

  const notification = buildNotification(group.rows);

  let apnsId: string | null = null;
  let retryableReason: string | null = null;
  let fatalReason: string | null = null;
  let retiredAll = true;

  for (const device of send) {
    tokensUsedThisRun.add(device.token);

    const environment = isApnsEnvironment(device.environment) ? device.environment : options.apns.environment;

    const outcome: ApnsOutcome = await sendPush(
      options.transport,
      {
        token: device.token,
        environment,
        collapseId: notification.collapseId,
        expiration: notification.expiration,
        payload: notification.payload,
      },
      { config: options.apns, providerToken: options.providerToken, log },
    );

    if (outcome.kind === "ok") {
      retiredAll = false;
      apnsId ??= outcome.apnsId;
    } else if (outcome.kind === "retire") {
      try {
        summary.retired_tokens += (await options.db.rpc<number>("retire_push_token", {
          p_token: device.token,
        })) ?? 0;
      } catch (error) {
        summary.errors.push(`retire_push_token: ${errorMessage(error)}`);
      }
    } else {
      retiredAll = false;
      if (outcome.retryable) retryableReason ??= `APNs ${outcome.status} ${outcome.reason}`;
      else fatalReason ??= `APNs ${outcome.status} ${outcome.reason}`;
    }
  }

  if (apnsId !== null) {
    // One apns-id across every delivery in the group. That is the record
    // proving one push covered N matches.
    //
    // Guarded, and the catch is the point. The push is already with Apple by
    // now, so the one thing this must NOT do is fall through to the caller's
    // handler and release the lease — that would re-claim the same rows on the
    // next pass and push the user a second time within seconds. Leaving the
    // lease in place costs five minutes, by which time a transient PostgREST
    // blip has usually cleared; and if it has not, the collapse id means the
    // repeat REPLACES the first notification rather than stacking on it.
    try {
      const moved = (await options.db.rpc<number>("mark_alert_sent", {
        p_ids: group.deliveryIds,
        p_apns_id: apnsId,
      })) ?? 0;
      summary.groups++;
      summary.sent += moved;
      log("info", "sent", {
        user: group.userId,
        watch: group.watchId,
        slots: notification.count,
        devices: send.length,
        apnsId,
      });
    } catch (error) {
      summary.errors.push(`mark_alert_sent ${group.userId}: ${errorMessage(error)}`);
      log("error", "the push went out but the ledger did not record it; letting the lease expire", {
        user: group.userId,
        watch: group.watchId,
        apnsId,
        error: errorMessage(error),
      });
    }
    return;
  }

  // Retryable beats fatal on purpose. A mixed group — one device throttled,
  // another misconfigured — is worth another run; giving up would lose the
  // alert for the device that might have worked.
  if (retryableReason !== null) {
    await release(options, summary, group, retryableReason, log);
    return;
  }

  if (retiredAll) {
    // Every device we knew about is gone. Leave the rows queued: the user has
    // no token now, so claim_alert_batch will not pick them up again until
    // they register a phone, and then the alert goes out.
    await release(options, summary, group, "every device token was retired; waiting for a new device", log);
    return;
  }

  const reason = fatalReason ?? "no device accepted the push";
  const moved = (await options.db.rpc<number>("mark_alert_failed", {
    p_ids: group.deliveryIds,
    p_error: reason,
    p_retryable: false,
  })) ?? 0;
  summary.failed += moved;
  log("error", "gave up on a group", { user: group.userId, watch: group.watchId, reason });
}

/** Clears the lease and leaves the rows queued for the next run. */
async function release(
  options: DispatchOptions,
  summary: DispatchSummary,
  group: AlertGroup,
  reason: string,
  log: Logger,
): Promise<void> {
  try {
    const moved = (await options.db.rpc<number>("mark_alert_failed", {
      p_ids: group.deliveryIds,
      p_error: reason,
      p_retryable: true,
    })) ?? 0;
    summary.deferred += moved;
  } catch (error) {
    // The lease expires by itself after five minutes, so a failure here costs
    // a delay, not a delivery.
    summary.errors.push(`release ${group.userId}: ${errorMessage(error)}`);
    log("error", "could not release a claim; the lease will expire instead", {
      user: group.userId,
      error: errorMessage(error),
    });
  }
}

// ---------------------------------------------------------------------------
// The HTTP surface.
// ---------------------------------------------------------------------------

function constantTimeEquals(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

/**
 * Only the service role, or whoever holds DISPATCH_SECRET, may start a run.
 *
 * The anon key reaches every deployed function by default, so without this
 * anybody with the app's public key could drain the queue.
 */
export function isAuthorised(req: Request, getEnv: EnvReader): boolean {
  const serviceRoleKey = getEnv("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const dispatchSecret = getEnv("DISPATCH_SECRET") ?? "";

  const header = req.headers.get("authorization") ?? "";
  const bearer = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (serviceRoleKey && constantTimeEquals(bearer, serviceRoleKey)) return true;

  const provided = req.headers.get("x-dispatch-secret") ?? "";
  return dispatchSecret !== "" && constantTimeEquals(provided, dispatchSecret);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handler(req: Request, getEnv: EnvReader = (k) => Deno.env.get(k)): Promise<Response> {
  try {
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    if (!isAuthorised(req, getEnv)) return json({ error: "unauthorised" }, 401);

    const apns = apnsConfigFromEnv(getEnv);
    const db = createServiceClient({ getEnv });
    const tokenCache = createProviderTokenCache(apns);

    const summary = await runDispatch({
      db,
      apns,
      transport: (url, init) => fetch(url, init),
      providerToken: () => tokenCache.token(),
    });

    return json({ ok: summary.errors.length === 0, dry_run: apns.dryRun, ...summary }, 200);
  } catch (error) {
    // Nothing escapes. A dispatcher that 500s with an HTML stack trace tells
    // whoever is looking at the logs nothing.
    return json({ ok: false, error: errorMessage(error) }, 500);
  }
}

if (import.meta.main) {
  Deno.serve((req) => handler(req));
}
