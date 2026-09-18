import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import {
  type ApnsConfig,
  apnsConfigFromEnv,
  apnsHost,
  classifyApnsResponse,
  type FetchLike,
  pkcs8FromPem,
  ProviderTokenCache,
  sendPush,
  signProviderToken,
} from "./apns.ts";
import { type AlertRow, buildNotification } from "./notification.ts";
import { runDispatch } from "../alert-dispatch/index.ts";
import type { ServiceClient } from "./supabase.ts";

// No Apple Developer account exists, so every test here fakes the transport.
// Nothing in this file has ever opened a socket to Apple.

const LIVE_CONFIG: ApnsConfig = {
  keyId: "ABCDE12345",
  teamId: "TEAM123456",
  privateKeyPem: "",
  topic: "code.lawro.TeesForTheBoys",
  environment: "sandbox",
  dryRun: false,
};

const WATCH = "7f1b3c5e-0000-4000-8000-000000000001";

function row(over: Partial<AlertRow> = {}): AlertRow {
  return {
    delivery_id: 1,
    user_id: "user-a",
    watch_id: WATCH,
    slot_id: "the-coast:2026-09-19:0758:public-play",
    course_slug: "the-coast",
    course_name: "The Coast Golf Club",
    tee_at: "2026-09-19T07:58:00+10:00",
    tee_date: "2026-09-19",
    tee_time: "07:58:00",
    spots_available: 2,
    holes: 18,
    price_min: 55,
    token: "token-a",
    environment: "sandbox",
    ...over,
  };
}

function message() {
  const n = buildNotification([row()]);
  return {
    token: "token-a",
    environment: "sandbox" as const,
    collapseId: n.collapseId,
    expiration: n.expiration,
    payload: n.payload,
  };
}

function reply(status: number, body: unknown = {}, apnsId = "apns-1234"): Response {
  return new Response(status === 200 ? "" : JSON.stringify(body), {
    status,
    headers: { "apns-id": apnsId },
  });
}

const silent = () => {};

// --------------------------------------------------------- the provider JWT

Deno.test("the provider JWT is minted once and reused inside the hour", async () => {
  let clock = 1_700_000_000_000;
  const cache = new ProviderTokenCache(
    (iat) => Promise.resolve(`jwt-at-${iat}`),
    () => clock,
  );

  const first = await cache.token();
  assertEquals(cache.signCount, 1);

  // Ten calls, forty-nine minutes later: still the same token, still one
  // signature. APNs rate-limits a client that mints one per request.
  clock += 49 * 60 * 1000;
  for (let i = 0; i < 10; i++) assertEquals(await cache.token(), first);
  assertEquals(cache.signCount, 1);

  // Past fifty minutes it is re-minted, well before Apple's one-hour cutoff.
  clock += 2 * 60 * 1000;
  const second = await cache.token();
  assert(second !== first);
  assertEquals(cache.signCount, 2);
});

Deno.test("a real ES256 JWT is produced from a PKCS#8 key", async () => {
  // A throwaway P-256 key stands in for Apple's .p8. This proves the signing
  // path without anybody owning an APNs key.
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8));
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    b64.match(/.{1,64}/g)!.join("\n")
  }\n-----END PRIVATE KEY-----\n`;

  const jwt = await signProviderToken({ ...LIVE_CONFIG, privateKeyPem: pem }, 1_700_000_000);
  const [headerB64, claimsB64, signatureB64] = jwt.split(".");
  assertEquals(jwt.split(".").length, 3);

  const decode = (s: string) => JSON.parse(atob(s.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(decode(headerB64), { alg: "ES256", kid: "ABCDE12345" });
  assertEquals(decode(claimsB64), { iss: "TEAM123456", iat: 1_700_000_000 });

  const raw = Uint8Array.from(
    atob(signatureB64.replace(/-/g, "+").replace(/_/g, "/")),
    (c) => c.charCodeAt(0),
  );
  assertEquals(raw.length, 64, "JWS wants the raw r||s pair, not DER");
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      raw,
      new TextEncoder().encode(`${headerB64}.${claimsB64}`),
    ),
    "the signature must verify against the public key",
  );

  // Apple's .p8 often arrives as a secret with its newlines escaped.
  assertEquals(pkcs8FromPem(pem.replace(/\n/g, "\\n")), pkcs8);
});

// -------------------------------------------------------------- classifying

Deno.test("Apple's answers are classified the way the queue needs", () => {
  assertEquals(classifyApnsResponse(200, "", "id-1"), { kind: "ok", apnsId: "id-1" });
  assertEquals(classifyApnsResponse(410, "Unregistered", ""), {
    kind: "retire",
    status: 410,
    reason: "Unregistered",
  });
  assertEquals(classifyApnsResponse(400, "BadDeviceToken", ""), {
    kind: "retire",
    status: 400,
    reason: "BadDeviceToken",
  });
  // A different 400 is our bug, not a dead device.
  assertEquals(classifyApnsResponse(400, "PayloadTooLarge", ""), {
    kind: "fail",
    status: 400,
    reason: "PayloadTooLarge",
    retryable: false,
  });
  assertEquals(classifyApnsResponse(403, "InvalidProviderToken", ""), {
    kind: "fail",
    status: 403,
    reason: "InvalidProviderToken",
    retryable: false,
  });
  assertEquals(classifyApnsResponse(429, "TooManyRequests", ""), {
    kind: "fail",
    status: 429,
    reason: "TooManyRequests",
    retryable: true,
  });
  assertEquals(classifyApnsResponse(503, "", ""), {
    kind: "fail",
    status: 503,
    reason: "ServiceUnavailable",
    retryable: true,
  });
});

Deno.test("sandbox and production are different hosts", () => {
  assertEquals(apnsHost("sandbox"), "api.sandbox.push.apple.com");
  assertEquals(apnsHost("production"), "api.push.apple.com");
});

// ------------------------------------------------------------------ sending

Deno.test("dry run never builds a request and never needs a key", async () => {
  let called = 0;
  const transport: FetchLike = () => {
    called++;
    return Promise.reject(new Error("dry run must not reach the transport"));
  };

  const outcome = await sendPush(transport, message(), {
    config: { ...LIVE_CONFIG, dryRun: true },
    providerToken: () => Promise.reject(new Error("dry run must not mint a token")),
    log: silent,
  });

  assertEquals(called, 0);
  assertEquals(outcome.kind, "ok");
  if (outcome.kind === "ok") assertStringIncludes(outcome.apnsId, "dry-run-");
});

Deno.test("a live send carries the headers the contract specifies", async () => {
  let seen: { url: string; init: RequestInit } | null = null;
  const transport: FetchLike = (url, init) => {
    seen = { url, init };
    return Promise.resolve(reply(200));
  };

  const msg = message();
  const outcome = await sendPush(transport, msg, {
    config: LIVE_CONFIG,
    providerToken: () => Promise.resolve("jwt-abc"),
    log: silent,
  });

  assertEquals(outcome, { kind: "ok", apnsId: "apns-1234" });
  const sent = seen as unknown as { url: string; init: RequestInit };
  assertEquals(sent.url, "https://api.sandbox.push.apple.com/3/device/token-a");
  const headers = sent.init.headers as Record<string, string>;
  assertEquals(headers["apns-topic"], "code.lawro.TeesForTheBoys");
  assertEquals(headers["apns-push-type"], "alert");
  assertEquals(headers["apns-priority"], "10");
  assertEquals(headers["apns-collapse-id"], `watch:${WATCH}`);
  assertEquals(headers["apns-expiration"], String(msg.expiration));
  assertEquals(headers.authorization, "bearer jwt-abc");
  assertEquals(JSON.parse(sent.init.body as string).tees.watch_id, WATCH);
});

Deno.test("a production device goes to the production host", async () => {
  let url = "";
  await sendPush(
    (u) => {
      url = u;
      return Promise.resolve(reply(200));
    },
    { ...message(), environment: "production" },
    {
      config: LIVE_CONFIG,
      providerToken: () => Promise.resolve("jwt"),
      log: silent,
    },
  );
  assertStringIncludes(url, "https://api.push.apple.com/");
});

Deno.test("a network failure is retryable, not a dead device", async () => {
  const outcome = await sendPush(() => Promise.reject(new Error("connection reset")), message(), {
    config: LIVE_CONFIG,
    providerToken: () => Promise.resolve("jwt"),
    log: silent,
  });
  assertEquals(outcome.kind, "fail");
  if (outcome.kind === "fail") assertEquals(outcome.retryable, true);
});

// ----------------------------------------------------------- configuration

Deno.test("dry run is the default and real sending demands the key", () => {
  const empty = apnsConfigFromEnv(() => undefined);
  assertEquals(empty.dryRun, true);
  assertEquals(empty.environment, "sandbox");
  assertEquals(empty.topic, "code.lawro.TeesForTheBoys");

  const live: Record<string, string> = { APNS_DRY_RUN: "0" };
  try {
    apnsConfigFromEnv((k) => live[k]);
    throw new Error("expected apnsConfigFromEnv to refuse to send without a key");
  } catch (error) {
    assertStringIncludes((error as Error).message, "APNS_KEY_ID");
  }
});

// -------------------------------------------------- the run, end to end

interface Call {
  fn: string;
  args: Record<string, unknown>;
}

function fakeDb(batches: AlertRow[][], counts: Record<string, number> = {}): {
  client: ServiceClient;
  calls: Call[];
} {
  const calls: Call[] = [];
  let batch = 0;
  const client: ServiceClient = {
    // deno-lint-ignore require-await
    async rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      calls.push({ fn, args });
      if (fn === "claim_alert_batch") return (batches[batch++] ?? []) as unknown as T;
      if (fn === "expire_watches") return (counts.expired ?? 0) as unknown as T;
      if (fn === "queue_watch_matches") return (counts.queued ?? 0) as unknown as T;
      // The mark/retire writers return how many rows they moved.
      const ids = args.p_ids as number[] | undefined;
      return (ids ? ids.length : 1) as unknown as T;
    },
  };
  return { client, calls };
}

function runOptions(db: ServiceClient, transport: FetchLike) {
  return {
    db,
    apns: LIVE_CONFIG,
    transport,
    providerToken: () => Promise.resolve("jwt"),
    log: silent,
  };
}

Deno.test("a 410 retires the token and the delivery waits for a new device", async () => {
  const { client, calls } = fakeDb([[row()]]);
  const summary = await runDispatch(
    runOptions(client, () => Promise.resolve(reply(410, { reason: "Unregistered" }))),
  );

  const retire = calls.find((c) => c.fn === "retire_push_token");
  assert(retire, "the dead token must be deleted");
  assertEquals(retire.args.p_token, "token-a");
  assertEquals(summary.retired_tokens, 1);

  // Not 'failed': the match is still real, there is just nowhere to send it.
  const marked = calls.find((c) => c.fn === "mark_alert_failed");
  assert(marked);
  assertEquals(marked.args.p_retryable, true);
  assertEquals(summary.sent, 0);
  assertEquals(summary.failed, 0);
  assertEquals(calls.some((c) => c.fn === "mark_alert_sent"), false);
});

Deno.test("a 429 leaves the rows queued for the next run", async () => {
  const { client, calls } = fakeDb([[row()]]);
  const summary = await runDispatch(
    runOptions(client, () => Promise.resolve(reply(429, { reason: "TooManyRequests" }))),
  );

  const marked = calls.find((c) => c.fn === "mark_alert_failed");
  assert(marked);
  assertEquals(marked.args.p_retryable, true);
  assertStringIncludes(marked.args.p_error as string, "429");
  assertEquals(summary.failed, 0);
  assertEquals(summary.deferred, 1);
  assertEquals(calls.some((c) => c.fn === "retire_push_token"), false);
});

Deno.test("a 403 fails non-retryably — it is a misconfiguration, not a device", async () => {
  const { client, calls } = fakeDb([[row()]]);
  const summary = await runDispatch(
    runOptions(client, () => Promise.resolve(reply(403, { reason: "InvalidProviderToken" }))),
  );

  const marked = calls.find((c) => c.fn === "mark_alert_failed");
  assert(marked);
  assertEquals(marked.args.p_retryable, false);
  assertStringIncludes(marked.args.p_error as string, "InvalidProviderToken");
  assertEquals(summary.failed, 1);
  assertEquals(summary.deferred, 0);
});

Deno.test("a five-slot group is one push, and every delivery gets the same apns-id", async () => {
  const rows = ["0700", "0708", "0716", "0724", "0758"].map((hhmm, i) =>
    row({
      delivery_id: 500 + i,
      slot_id: `the-coast:2026-09-19:${hhmm}:public-play`,
      tee_at: `2026-09-19T${hhmm.slice(0, 2)}:${hhmm.slice(2)}:00+10:00`,
    })
  );

  const sends: RequestInit[] = [];
  const { client, calls } = fakeDb([rows]);
  const summary = await runDispatch(runOptions(client, (_url, init) => {
    sends.push(init);
    return Promise.resolve(reply(200, {}, "apns-group-1"));
  }));

  assertEquals(sends.length, 1, "five matches, one notification");
  const payload = JSON.parse(sends[0].body as string);
  assertEquals(payload.tees.count, 5);
  assertEquals(payload.aps.alert.title, "5 tee times at The Coast");
  assertStringIncludes(payload.aps.alert.body, "+4 more");

  const sent = calls.find((c) => c.fn === "mark_alert_sent");
  assert(sent);
  assertEquals(sent.args.p_ids, [500, 501, 502, 503, 504]);
  assertEquals(sent.args.p_apns_id, "apns-group-1");
  assertEquals(summary.groups, 1);
  assertEquals(summary.sent, 5);
});

Deno.test("two users on one iPhone: one push, the other user's rows are released", async () => {
  const rows = [
    row({ delivery_id: 1, user_id: "user-a", token: "shared-phone" }),
    row({ delivery_id: 2, user_id: "user-b", watch_id: "watch-b", token: "shared-phone" }),
  ];

  const sends: string[] = [];
  const { client, calls } = fakeDb([rows]);
  const summary = await runDispatch(runOptions(client, (url) => {
    sends.push(url);
    return Promise.resolve(reply(200));
  }));

  assertEquals(sends.length, 1, "the device must receive exactly one push");
  assertEquals(summary.groups, 1);
  assertEquals(summary.sent, 1);

  // The loser is deferred, never suppressed and never dropped.
  const released = calls.find((c) => c.fn === "mark_alert_failed");
  assert(released, "the second user's rows must be released back to the queue");
  assertEquals(released.args.p_ids, [2]);
  assertEquals(released.args.p_retryable, true);
  assertStringIncludes(released.args.p_error as string, "same run");
  assertEquals(summary.deferred, 1);
});

Deno.test("one user's failure does not abort the run", async () => {
  const rows = [
    row({ delivery_id: 1, user_id: "user-a", token: "token-a" }),
    row({ delivery_id: 2, user_id: "user-b", watch_id: "watch-b", token: "token-b" }),
  ];

  const { client } = fakeDb([rows]);
  const summary = await runDispatch(
    runOptions(
      client,
      (url) =>
        url.endsWith("token-a") ? Promise.reject(new Error("socket hangup")) : Promise.resolve(reply(200)),
    ),
  );

  assertEquals(summary.sent, 1, "user-b still gets their push");
  assertEquals(summary.deferred, 1, "user-a's rows go back on the queue");
});

Deno.test("the loop stops instead of re-claiming rows it just released", async () => {
  // Same rows handed back on every claim, which is what happens when a group
  // is released: without the per-run guard the loop would never end.
  const rows = [
    row({ delivery_id: 1, user_id: "user-a", token: "shared" }),
    row({
      delivery_id: 2,
      user_id: "user-b",
      watch_id: "watch-b",
      token: "shared",
    }),
  ];

  const { client, calls } = fakeDb([rows, rows, rows, rows]);
  const summary = await runDispatch(runOptions(client, () => Promise.resolve(reply(200))));

  assertEquals(calls.filter((c) => c.fn === "claim_alert_batch").length, 2);
  assertEquals(summary.sent, 1);
});

Deno.test("a push that went out is never released just because the ledger write failed", async () => {
  // The worst thing to do after Apple has accepted a push is to clear the
  // lease: the next pass round the loop would claim the same rows and push the
  // user again seconds later. Let the five-minute lease expire instead.
  const { client, calls } = fakeDb([[row()]]);
  const flaky: ServiceClient = {
    rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      if (fn === "mark_alert_sent") {
        calls.push({ fn, args });
        return Promise.reject(new Error("public.mark_alert_sent failed: HTTP 503"));
      }
      return client.rpc<T>(fn, args);
    },
  };

  const summary = await runDispatch(runOptions(flaky, () => Promise.resolve(reply(200))));

  assertEquals(calls.some((c) => c.fn === "mark_alert_sent"), true);
  assertEquals(
    calls.some((c) => c.fn === "mark_alert_failed"),
    false,
    "releasing the lease here would push the same tee time twice",
  );
  assertEquals(summary.sent, 0);
  assertEquals(summary.deferred, 0);
  assertEquals(summary.errors.length, 1);
  assertStringIncludes(summary.errors[0], "mark_alert_sent");
});

Deno.test("a matcher that is not deployed yet does not stop delivery", async () => {
  const { client } = fakeDb([[row()]]);
  const failing: ServiceClient = {
    rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      if (fn === "queue_watch_matches") {
        return Promise.reject(new Error("public.queue_watch_matches failed: HTTP 404"));
      }
      return client.rpc<T>(fn, args);
    },
  };

  const summary = await runDispatch(runOptions(failing, () => Promise.resolve(reply(200))));
  assertEquals(summary.sent, 1, "what is already queued still goes out");
  assertEquals(summary.errors.length, 1);
  assertStringIncludes(summary.errors[0], "queue_watch_matches");
});
