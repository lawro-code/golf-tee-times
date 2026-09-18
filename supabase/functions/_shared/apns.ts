// The APNs transport: provider JWT, one HTTP/2 POST per device, and the
// response classification that decides whether a delivery is done, doomed, or
// worth trying again.
//
// THE COST GATE. There is no Apple Developer account, no APNs key and no team
// id, and none will be bought until Stage 4 — after the app has been seen
// running. So APNS_DRY_RUN defaults to "1" and this file does not build a
// request, mint a token or touch the network in that mode. It logs what it
// would have sent and reports success.
//
// Everything is injected: the transport is a fetch-shaped function and the
// signer is replaceable. Every test uses a fake. Nothing here has ever spoken
// to Apple.

import type { NotificationPayload } from "./notification.ts";

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export type ApnsEnvironment = "sandbox" | "production";

export interface ApnsConfig {
  /** APNS_KEY_ID — the 10-character key id, the JWT's `kid`. */
  keyId: string;
  /** APNS_TEAM_ID — the 10-character team id, the JWT's `iss`. */
  teamId: string;
  /** APNS_KEY_P8 — the PKCS#8 PEM Apple issues as a .p8 file. */
  privateKeyPem: string;
  /** The app's bundle id. */
  topic: string;
  /** Default when a device row does not say; each device's own column wins. */
  environment: ApnsEnvironment;
  /** APNS_DRY_RUN — anything but "0" means log instead of send. */
  dryRun: boolean;
}

export interface ApnsMessage {
  token: string;
  environment: ApnsEnvironment;
  collapseId: string;
  /** Unix seconds; APNs stops trying at this point. */
  expiration: number;
  payload: NotificationPayload;
}

export type ApnsOutcome =
  /** Delivered to Apple. `apnsId` is their receipt and goes in the ledger. */
  | { kind: "ok"; apnsId: string }
  /** The device is gone. Delete the token, and do not blame the delivery. */
  | { kind: "retire"; status: number; reason: string }
  /** Everything else, with the one bit that matters: try again or give up. */
  | { kind: "fail"; status: number; reason: string; retryable: boolean };

export type Logger = (
  level: "info" | "warn" | "error",
  message: string,
  extra?: Record<string, unknown>,
) => void;

export const defaultLogger: Logger = (level, message, extra) => {
  const line = extra ? `${message} ${JSON.stringify(extra)}` : message;
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
};

/** Sandbox and production are different hosts AND different token namespaces. */
export function apnsHost(environment: ApnsEnvironment): string {
  return environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
}

export function isApnsEnvironment(value: unknown): value is ApnsEnvironment {
  return value === "sandbox" || value === "production";
}

// ---------------------------------------------------------------------------
// The provider token.
// ---------------------------------------------------------------------------

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeJson(value: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

/**
 * Apple hands out a .p8 file. Stored as a secret it usually arrives either
 * with real newlines or with the newlines escaped, so both are accepted.
 */
export function pkcs8FromPem(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  if (body.length === 0) throw new Error("APNS_KEY_P8 is empty or not a PEM private key");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Signs the ES256 provider JWT. `iat` in seconds. */
export async function signProviderToken(config: ApnsConfig, iat: number): Promise<string> {
  if (!config.keyId) throw new Error("APNS_KEY_ID is not set");
  if (!config.teamId) throw new Error("APNS_TEAM_ID is not set");

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8FromPem(config.privateKeyPem) as unknown as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const signingInput = `${base64UrlEncodeJson({ alg: "ES256", kid: config.keyId })}.${
    base64UrlEncodeJson({ iss: config.teamId, iat })
  }`;

  // WebCrypto returns the raw r||s pair, which is exactly the JWS encoding —
  // no DER unwrapping needed.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/**
 * Holds one provider JWT and reuses it.
 *
 * Both halves matter. APNs rejects a token older than an hour with 403
 * ExpiredProviderToken, and it rate-limits a client that mints a fresh one for
 * every request — so "sign every time" is not a safe simplification, it is the
 * thing Apple throttles. Fifty minutes leaves ten minutes of headroom.
 */
export class ProviderTokenCache {
  #token: string | null = null;
  #issuedAt = 0;
  #signCount = 0;

  constructor(
    private readonly sign: (iat: number) => Promise<string>,
    private readonly now: () => number = Date.now,
    private readonly ttlSeconds = 50 * 60,
  ) {}

  /** How many times a token has actually been minted. Tests assert on it. */
  get signCount(): number {
    return this.#signCount;
  }

  async token(): Promise<string> {
    const nowSeconds = Math.floor(this.now() / 1000);
    if (this.#token !== null && nowSeconds - this.#issuedAt < this.ttlSeconds) {
      return this.#token;
    }
    this.#token = await this.sign(nowSeconds);
    this.#issuedAt = nowSeconds;
    this.#signCount++;
    return this.#token;
  }
}

export function createProviderTokenCache(
  config: ApnsConfig,
  now: () => number = Date.now,
): ProviderTokenCache {
  return new ProviderTokenCache((iat) => signProviderToken(config, iat), now);
}

// ---------------------------------------------------------------------------
// Sending.
// ---------------------------------------------------------------------------

/**
 * What Apple's answer means. This is the part that actually matters: get it
 * wrong in the safe-looking direction and every delivery retries forever
 * against a device that no longer exists.
 */
export function classifyApnsResponse(status: number, reason: string, apnsId: string): ApnsOutcome {
  if (status === 200) return { kind: "ok", apnsId };

  // The app was deleted, or this token was never ours. Apple requires we stop.
  if (status === 410) return { kind: "retire", status, reason: reason || "Unregistered" };
  if (status === 400 && reason === "BadDeviceToken") return { kind: "retire", status, reason };

  // Bad key, wrong topic, expired JWT. Not a bad device — a misconfiguration,
  // and retrying it just burns the rate limit until somebody reads the logs.
  if (status === 403) return { kind: "fail", status, reason: reason || "Forbidden", retryable: false };

  // Apple is throttling us or having a bad day. The rows stay queued.
  if (status === 429) return { kind: "fail", status, reason: reason || "TooManyRequests", retryable: true };
  if (status >= 500) return { kind: "fail", status, reason: reason || "ServiceUnavailable", retryable: true };

  // 400 for any other reason, 404, 405, 413: our request is wrong and will be
  // wrong again next time.
  return { kind: "fail", status, reason: reason || `HTTP ${status}`, retryable: false };
}

export interface SendPushOptions {
  config: ApnsConfig;
  /** Usually a ProviderTokenCache's `token` method. Not called in dry run. */
  providerToken: () => Promise<string>;
  log?: Logger;
  timeoutMs?: number;
}

/**
 * One push, one device.
 *
 * `transport` is fetch-shaped and always injected, so a test never needs a
 * network and this repo has never made a real APNs request.
 */
export async function sendPush(
  transport: FetchLike,
  message: ApnsMessage,
  options: SendPushOptions,
): Promise<ApnsOutcome> {
  const { config } = options;
  const log = options.log ?? defaultLogger;

  if (config.dryRun) {
    // Deliberately before anything that would need a key: in dry run there is
    // no key to have, and no request is ever constructed.
    const apnsId = `dry-run-${crypto.randomUUID()}`;
    log("info", "APNS_DRY_RUN: not sending", {
      apnsId,
      host: apnsHost(message.environment),
      topic: config.topic,
      token: `${message.token.slice(0, 8)}…`,
      collapseId: message.collapseId,
      expiration: message.expiration,
      title: message.payload.aps.alert.title,
      body: message.payload.aps.alert.body,
      slots: message.payload.tees.count,
    });
    return { kind: "ok", apnsId };
  }

  let jwt: string;
  try {
    jwt = await options.providerToken();
  } catch (error) {
    // No usable key is a misconfiguration, not a device problem.
    return { kind: "fail", status: 0, reason: `provider token: ${errorMessage(error)}`, retryable: false };
  }

  // An AbortController rather than AbortSignal.timeout so the timer is always
  // cleared: a stray timer keeps a Deno worker (and a test) alive.
  const controller = new AbortController();
  const timeoutMs = options.timeoutMs ?? 10_000;
  const timer = timeoutMs > 0
    ? setTimeout(() => controller.abort(new Error("APNs request timed out")), timeoutMs)
    : undefined;

  let response: Response;
  try {
    response = await transport(`https://${apnsHost(message.environment)}/3/device/${message.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": message.collapseId,
        // An alert about a tee time is worthless once it has teed off.
        "apns-expiration": String(message.expiration),
        "content-type": "application/json",
      },
      body: JSON.stringify(message.payload),
      signal: controller.signal,
    });
  } catch (error) {
    // A socket hangup or a timeout says nothing about the device.
    return { kind: "fail", status: 0, reason: `transport: ${errorMessage(error)}`, retryable: true };
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }

  const apnsId = response.headers.get("apns-id") ?? "";
  let reason = "";
  if (response.status !== 200) {
    const text = await response.text().catch(() => "");
    reason = parseReason(text);
  } else {
    // Drain so the connection can be reused.
    await response.text().catch(() => "");
  }

  const outcome = classifyApnsResponse(response.status, reason, apnsId);

  if (outcome.kind === "retire") {
    log("warn", "APNs retired a device token", { status: outcome.status, reason: outcome.reason });
  } else if (outcome.kind === "fail" && !outcome.retryable) {
    log("error", "APNs rejected the push and will not accept a retry", {
      status: outcome.status,
      reason: outcome.reason,
      topic: config.topic,
      environment: message.environment,
    });
  } else if (outcome.kind === "fail") {
    log("warn", "APNs is unavailable; leaving the delivery queued", {
      status: outcome.status,
      reason: outcome.reason,
    });
  }

  return outcome;
}

function parseReason(body: string): string {
  if (!body) return "";
  try {
    const parsed = JSON.parse(body) as { reason?: unknown };
    return typeof parsed.reason === "string" ? parsed.reason : "";
  } catch {
    return body.slice(0, 200);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// ---------------------------------------------------------------------------
// Configuration.
// ---------------------------------------------------------------------------

export type EnvReader = (key: string) => string | undefined;

/**
 * Reads the deployment's APNs settings.
 *
 * Dry run is the DEFAULT, not a flag you remember to set: unset APNS_DRY_RUN
 * means log-and-succeed. Only a literal "0" turns on real sending, and only
 * then are the key, key id and team id required.
 */
export function apnsConfigFromEnv(getEnv: EnvReader): ApnsConfig {
  const dryRun = (getEnv("APNS_DRY_RUN") ?? "1") !== "0";
  const environmentRaw = getEnv("APNS_ENVIRONMENT") ?? "sandbox";
  if (!isApnsEnvironment(environmentRaw)) {
    throw new Error(`APNS_ENVIRONMENT must be "sandbox" or "production", got "${environmentRaw}"`);
  }

  const config: ApnsConfig = {
    keyId: getEnv("APNS_KEY_ID") ?? "",
    teamId: getEnv("APNS_TEAM_ID") ?? "",
    privateKeyPem: getEnv("APNS_KEY_P8") ?? "",
    topic: getEnv("APNS_TOPIC") ?? "code.lawro.TeesForTheBoys",
    environment: environmentRaw,
    dryRun,
  };

  if (!dryRun) {
    const missing = (["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_KEY_P8"] as const).filter((k) => !getEnv(k));
    if (missing.length > 0) {
      throw new Error(
        `APNS_DRY_RUN=0 asks for real delivery but ${missing.join(", ")} ${
          missing.length === 1 ? "is" : "are"
        } not set. No Apple Developer account exists yet — see supabase/functions/README.md.`,
      );
    }
  }

  return config;
}
