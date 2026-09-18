// Turning a coalesced group of matches into one APNs payload.
//
// THIS FILE IS A CONTRACT WITH TICKET E3. The `tees` object below is what the
// iOS app decodes to route a notification tap to the right slot. Adding a key
// is safe; renaming or removing one is not, and `v` exists so a future change
// can be made without guessing.
//
// Nothing here touches the network or the database. It is pure input to
// output, which is why it is the part with the most tests.

/** One row of public.claim_alert_batch: a delivery paired with one device. */
export interface AlertRow {
  delivery_id: number;
  user_id: string;
  watch_id: string;
  slot_id: string;
  course_slug: string;
  course_name: string;
  /** The resolved instant. CONTRACT.md section 4: never recompute this. */
  tee_at: string;
  tee_date: string;
  tee_time: string;
  spots_available: number;
  holes: number;
  /** numeric(10,2). Postgres clients send it as a number or a string; null is ordinary. */
  price_min: number | string | null;
  token: string;
  environment: string;
}

/** A user's matches for one watch, with the devices to send them to. */
export interface AlertGroup {
  userId: string;
  watchId: string;
  /** Deduplicated: one entry per delivery row. */
  deliveryIds: number[];
  /** Deduplicated by token: a user signed in on one phone twice is one device. */
  devices: { token: string; environment: string }[];
  /** Every row as claimed, duplicates across devices included. */
  rows: AlertRow[];
}

export interface NotificationPayload {
  aps: {
    alert: { title: string; body: string };
    sound: string;
    "thread-id": string;
    "interruption-level": string;
  };
  tees: {
    v: number;
    watch_id: string;
    slot_ids: string[];
    primary_slot_id: string;
    course_slug: string;
    course_name: string;
    tee_at: string;
    count: number;
  };
}

export interface PreparedNotification {
  watchId: string;
  title: string;
  body: string;
  /** Distinct slots in the group. */
  count: number;
  payload: NotificationPayload;
  /** `watch:<uuid>` — APNs rejects a collapse id over 64 bytes. */
  collapseId: string;
  /** Unix seconds. APNs drops the push at this point. */
  expiration: number;
}

const SYDNEY = "Australia/Sydney";

const DAY_FORMAT = new Intl.DateTimeFormat("en-AU", {
  timeZone: SYDNEY,
  weekday: "short",
  day: "numeric",
  month: "short",
});

const TIME_FORMAT = new Intl.DateTimeFormat("en-AU", {
  timeZone: SYDNEY,
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

/**
 * `Sat 20 Sep`.
 *
 * Assembled from parts rather than taken as formatted, because en-AU renders
 * this as "Sun, 20 Sept" — a comma we do not want and a four-letter month
 * abbreviation. Slicing to three characters gives the abbreviations everybody
 * in Australia actually writes: Sept -> Sep, June -> Jun, March -> Mar.
 */
export function formatSydneyDay(iso: string): string {
  const parts = DAY_FORMAT.formatToParts(new Date(iso));
  const pick = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  const weekday = pick("weekday").slice(0, 3);
  const month = pick("month").slice(0, 3);
  return `${weekday} ${pick("day")} ${month}`;
}

// Every kind of space ICU might put before am/pm. Recent versions use a
// narrow no-break space (U+202F) where older ones used a plain one, so this
// is a Unicode property escape rather than a list of literal characters —
// invisible characters in source are how this sort of thing goes wrong.
const ANY_SPACE = /[\p{Zs}\s]/gu;

/** `7:58am`. */
export function formatSydneyTime(iso: string): string {
  return TIME_FORMAT.format(new Date(iso)).replace(ANY_SPACE, "").toLowerCase();
}

/**
 * `$55`, `$55.50`, or `price at course`.
 *
 * CONTRACT.md section 3: one slot in six publishes no fee at all — 282 of the
 * 1755 in the golden scrape. An unpriced round is ordinary data, so it is
 * labelled, never rendered as `$0` and never left out of the line.
 */
export function formatPrice(price: number | string | null | undefined): string {
  if (price === null || price === undefined || price === "") return "price at course";
  const amount = typeof price === "string" ? Number(price) : price;
  if (!Number.isFinite(amount)) return "price at course";
  const rounded = Math.round(amount * 100) / 100;
  return Number.isInteger(rounded) ? `$${rounded}` : `$${rounded.toFixed(2)}`;
}

/**
 * `The Coast Golf Club` -> `The Coast`.
 *
 * Only for the "3 tee times at X" phrasing, where the full registered name
 * reads like a letter from the club. A single-slot notification keeps the full
 * name as its title: there it is the headline, not a fragment of a sentence.
 */
export function shortCourseName(name: string): string {
  return name.replace(
    /\s+(Golf(\s+&\s+Country)?\s+Club|Golf\s+Course|Golf\s+Links|Country\s+Club|Recreation\s+Club)$/i,
    "",
  )
    .trim() || name;
}

function spotsLabel(spots: number): string {
  return spots === 1 ? "1 spot" : `${spots} spots`;
}

/** `Sat 20 Sep, 7:58am · 2 spots · 18 holes · $55` */
export function slotLine(row: AlertRow): string {
  return [
    `${formatSydneyDay(row.tee_at)}, ${formatSydneyTime(row.tee_at)}`,
    spotsLabel(row.spots_available),
    `${row.holes} holes`,
    formatPrice(row.price_min),
  ].join(" · ");
}

/**
 * Collapse the rows claim_alert_batch handed back into one group per
 * (user, watch).
 *
 * claim_alert_batch already guarantees one watch per user per run, so in
 * practice this is one group per user — but grouping on both keys means a
 * change to that limit cannot silently merge two watches into one push with
 * the wrong thread-id.
 */
export function groupAlertRows(rows: AlertRow[]): AlertGroup[] {
  const groups = new Map<string, AlertGroup>();
  for (const row of rows) {
    // A uuid can never contain "|", so this cannot collide.
    const key = `${row.user_id}|${row.watch_id}`;
    let group = groups.get(key);
    if (!group) {
      group = { userId: row.user_id, watchId: row.watch_id, deliveryIds: [], devices: [], rows: [] };
      groups.set(key, group);
    }
    group.rows.push(row);
    if (!group.deliveryIds.includes(row.delivery_id)) group.deliveryIds.push(row.delivery_id);
    if (!group.devices.some((d) => d.token === row.token)) {
      group.devices.push({ token: row.token, environment: row.environment });
    }
  }
  return [...groups.values()];
}

/**
 * Which of a group's devices should actually receive this run's push.
 *
 * push_tokens is keyed (user_id, token) because two mates sharing one iPhone
 * is ordinary for this app (0002_user_tables.sql). CONTRACT.md says the sender
 * de-duplicates at send time so that device still gets one push — and the
 * second user's deliveries are NOT dropped. They are released back to the
 * queue and go out on the next run, by which point the first user is inside
 * their ten-minute cool-down and the phone is free.
 */
export function planDevices(
  group: AlertGroup,
  tokensUsedThisRun: ReadonlySet<string>,
): { send: { token: string; environment: string }[]; deferred: string[] } {
  const send: { token: string; environment: string }[] = [];
  const deferred: string[] = [];
  for (const device of group.devices) {
    if (tokensUsedThisRun.has(device.token)) deferred.push(device.token);
    else send.push(device);
  }
  return { send, deferred };
}

/**
 * One group in, one notification out.
 *
 * The group may hold the same slot several times over (once per device), so
 * slots are deduplicated here rather than trusted from the caller.
 */
export function buildNotification(rows: AlertRow[]): PreparedNotification {
  if (rows.length === 0) throw new Error("buildNotification: empty group");

  const bySlot = new Map<string, AlertRow>();
  for (const row of rows) if (!bySlot.has(row.slot_id)) bySlot.set(row.slot_id, row);

  const slots = [...bySlot.values()].sort((a, b) => {
    const t = Date.parse(a.tee_at) - Date.parse(b.tee_at);
    return t !== 0 ? t : a.slot_id.localeCompare(b.slot_id);
  });

  const primary = slots[0];
  const count = slots.length;
  const watchId = primary.watch_id;
  const singleCourse = slots.every((s) => s.course_slug === primary.course_slug);

  const title = count === 1
    ? primary.course_name
    : singleCourse
    ? `${count} tee times at ${shortCourseName(primary.course_name)}`
    : `${count} tee times matched your alert`;

  const body = count === 1 ? slotLine(primary) : `${slotLine(primary)} · +${count - 1} more`;

  // The last tee-off in the group, not the first. A push saying "3 tee times"
  // is still worth reading once the earliest has gone; it is worthless only
  // when every slot in it has teed off.
  const expiration = Math.floor(
    Math.max(...slots.map((s) => Date.parse(s.tee_at))) / 1000,
  );

  return {
    watchId,
    title,
    body,
    count,
    collapseId: collapseIdFor(watchId),
    expiration,
    payload: {
      aps: {
        alert: { title, body },
        sound: "default",
        "thread-id": `watch:${watchId}`,
        "interruption-level": "time-sensitive",
      },
      tees: {
        v: 1,
        watch_id: watchId,
        slot_ids: slots.map((s) => s.slot_id),
        primary_slot_id: primary.slot_id,
        course_slug: primary.course_slug,
        course_name: primary.course_name,
        tee_at: primary.tee_at,
        count,
      },
    },
  };
}

/**
 * `watch:<uuid>` is 42 bytes, comfortably inside the 64 APNs allows — but the
 * cap is a hard reject, not a truncation, so it is enforced here rather than
 * assumed. A second alert for the same watch REPLACES the first on the lock
 * screen instead of stacking, which is the whole point of collapsing.
 */
export function collapseIdFor(watchId: string): string {
  const id = `watch:${watchId}`;
  const bytes = new TextEncoder().encode(id);
  if (bytes.length <= 64) return id;
  return new TextDecoder().decode(bytes.slice(0, 64));
}
