// The service-role database client.
//
// Four RPCs is the whole surface — expire_watches, queue_watch_matches,
// claim_alert_batch, and the three mark/retire writers — so this calls
// PostgREST directly instead of pulling in supabase-js. That is deliberate:
// no dependency to pin or audit, nothing to fetch at check or test time, and a
// cold start that does not import a client library to POST four times. If a
// later ticket needs table queries, filters or realtime, swap this for
// supabase-js and keep the interface.
//
// The URL and the key are read from the environment and nothing else. A
// project ref hardcoded here would be a project ref in the repo forever.

export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export type EnvReader = (key: string) => string | undefined;

export interface ServiceClient {
  /** Calls public.<fn>(args) as the service role and returns its JSON result. */
  rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T>;
}

export class ServiceClientError extends Error {
  constructor(
    readonly fn: string,
    readonly status: number,
    readonly body: string,
  ) {
    super(`public.${fn} failed: HTTP ${status} ${body.slice(0, 300)}`);
    this.name = "ServiceClientError";
  }
}

export interface CreateServiceClientOptions {
  getEnv?: EnvReader;
  transport?: FetchLike;
  timeoutMs?: number;
}

export function createServiceClient(options: CreateServiceClientOptions = {}): ServiceClient {
  const getEnv = options.getEnv ?? ((key: string) => Deno.env.get(key));
  const transport = options.transport ?? ((url, init) => fetch(url, init));
  const timeoutMs = options.timeoutMs ?? 30_000;

  const url = (getEnv("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  const serviceRoleKey = getEnv("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  // Fail here, loudly, rather than at the first RPC with a 401 that reads like
  // a permissions bug.
  if (!url) throw new Error("SUPABASE_URL is not set");
  if (!serviceRoleKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is not set");

  return {
    async rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      // An AbortController rather than AbortSignal.timeout so the timer is
      // always cleared; a stray timer keeps the worker alive after the reply.
      const controller = new AbortController();
      const timer = timeoutMs > 0
        ? setTimeout(() => controller.abort(new Error(`public.${fn} timed out`)), timeoutMs)
        : undefined;

      let response: Response;
      try {
        response = await transport(`${url}/rest/v1/rpc/${fn}`, {
          method: "POST",
          headers: {
            apikey: serviceRoleKey,
            authorization: `Bearer ${serviceRoleKey}`,
            "content-type": "application/json",
            accept: "application/json",
          },
          body: JSON.stringify(args),
          signal: controller.signal,
        });
      } finally {
        if (timer !== undefined) clearTimeout(timer);
      }

      const text = await response.text();
      if (!response.ok) throw new ServiceClientError(fn, response.status, text);
      if (text.trim() === "") return null as T;
      return JSON.parse(text) as T;
    },
  };
}
