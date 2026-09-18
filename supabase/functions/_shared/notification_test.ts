import { assert, assertEquals, assertThrows } from "@std/assert";
import {
  type AlertRow,
  buildNotification,
  collapseIdFor,
  formatPrice,
  formatSydneyDay,
  formatSydneyTime,
  groupAlertRows,
  planDevices,
  shortCourseName,
  slotLine,
} from "./notification.ts";

const WATCH = "7f1b3c5e-0000-4000-8000-000000000001";

function row(over: Partial<AlertRow> = {}): AlertRow {
  return {
    delivery_id: 1,
    user_id: "11111111-1111-1111-1111-111111111111",
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

// --------------------------------------------------------------- formatting

Deno.test("dates and times render in Australia/Sydney", () => {
  // 19 Sep 2026 is a Saturday. AEST, +10:00.
  assertEquals(formatSydneyDay("2026-09-19T07:58:00+10:00"), "Sat 19 Sep");
  assertEquals(formatSydneyTime("2026-09-19T07:58:00+10:00"), "7:58am");

  // The same instant expressed in UTC has to render identically: tee_at comes
  // back from Supabase with +00:00 and from a fixture with +10:00.
  assertEquals(formatSydneyDay("2026-09-18T21:58:00Z"), "Sat 19 Sep");
  assertEquals(formatSydneyTime("2026-09-18T21:58:00Z"), "7:58am");

  // Month abbreviations ICU gets long-winded about.
  assertEquals(formatSydneyDay("2026-06-20T06:00:00+10:00"), "Sat 20 Jun");
  assertEquals(formatSydneyDay("2026-03-07T06:00:00+11:00"), "Sat 7 Mar");

  // Daylight saving. Sydney is +11:00 in January, so 21:00Z is the next morning.
  assertEquals(formatSydneyDay("2027-01-01T21:00:00Z"), "Sat 2 Jan");
  assertEquals(formatSydneyTime("2027-01-01T21:00:00Z"), "8:00am");

  assertEquals(formatSydneyTime("2026-09-19T12:05:00+10:00"), "12:05pm");
  assertEquals(formatSydneyTime("2026-09-19T00:30:00+10:00"), "12:30am");
});

Deno.test("an unpriced slot says 'price at course', never $0", () => {
  assertEquals(formatPrice(null), "price at course");
  assertEquals(formatPrice(undefined), "price at course");
  assertEquals(formatPrice(""), "price at course");
  assertEquals(formatPrice(55), "$55");
  assertEquals(formatPrice("55.00"), "$55");
  assertEquals(formatPrice("55.50"), "$55.50");
  assertEquals(formatPrice(0), "$0");
});

Deno.test("the club's registered name is trimmed only in the 'at X' phrase", () => {
  assertEquals(shortCourseName("The Coast Golf Club"), "The Coast");
  assertEquals(shortCourseName("Castle Cove Country Club"), "Castle Cove");
  assertEquals(shortCourseName("Brighton Lakes Recreation Club"), "Brighton Lakes");
  assertEquals(shortCourseName("Long Reef Golf Club"), "Long Reef");
  assertEquals(shortCourseName("Bondi"), "Bondi");
});

Deno.test("one slot reads as a single line with every field", () => {
  assertEquals(slotLine(row()), "Sat 19 Sep, 7:58am · 2 spots · 18 holes · $55");
  assertEquals(
    slotLine(row({ spots_available: 1, holes: 9, price_min: null })),
    "Sat 19 Sep, 7:58am · 1 spot · 9 holes · price at course",
  );
});

// ------------------------------------------------------------ notifications

Deno.test("a single match uses the club's full name as the title", () => {
  const n = buildNotification([row()]);
  assertEquals(n.count, 1);
  assertEquals(n.title, "The Coast Golf Club");
  assertEquals(n.body, "Sat 19 Sep, 7:58am · 2 spots · 18 holes · $55");
  assertEquals(n.payload.tees.count, 1);
  assertEquals(n.payload.tees.slot_ids, ["the-coast:2026-09-19:0758:public-play"]);
});

Deno.test("five slots at one club become ONE notification saying five", () => {
  const times = ["0700", "0708", "0716", "0724", "0758"];
  const rows = times.map((hhmm, i) =>
    row({
      delivery_id: 100 + i,
      slot_id: `the-coast:2026-09-19:${hhmm}:public-play`,
      tee_at: `2026-09-19T${hhmm.slice(0, 2)}:${hhmm.slice(2)}:00+10:00`,
    })
  );

  // Deliberately out of order: the payload must sort, not trust the caller.
  const n = buildNotification([rows[4], rows[0], rows[3], rows[1], rows[2]]);

  assertEquals(n.count, 5);
  assertEquals(n.payload.tees.count, 5);
  assertEquals(n.title, "5 tee times at The Coast");
  assertEquals(n.body, "Sat 19 Sep, 7:00am · 2 spots · 18 holes · $55 · +4 more");
  assertEquals(n.payload.tees.primary_slot_id, "the-coast:2026-09-19:0700:public-play");
  assertEquals(n.payload.tees.slot_ids.length, 5);
  assertEquals(n.payload.tees.slot_ids[0], "the-coast:2026-09-19:0700:public-play");
  assertEquals(n.payload.tees.tee_at, "2026-09-19T07:00:00+10:00");
});

Deno.test("an unpriced slot in a group still renders 'price at course'", () => {
  const rows = [
    row({
      delivery_id: 1,
      slot_id: "bexley:2026-09-19:0930:social",
      course_slug: "bexley",
      course_name: "Bexley Golf Club",
      price_min: null,
      tee_at: "2026-09-19T09:30:00+10:00",
      holes: 9,
      spots_available: 3,
    }),
    row({
      delivery_id: 2,
      slot_id: "bexley:2026-09-19:1000:social",
      course_slug: "bexley",
      course_name: "Bexley Golf Club",
      price_min: null,
      tee_at: "2026-09-19T10:00:00+10:00",
      holes: 9,
      spots_available: 3,
    }),
  ];
  const n = buildNotification(rows);
  assertEquals(n.title, "2 tee times at Bexley");
  assertEquals(n.body, "Sat 19 Sep, 9:30am · 3 spots · 9 holes · price at course · +1 more");
  assert(!n.body.includes("$0"), "an unpriced slot must never render as $0");
});

Deno.test("a group spanning clubs does not claim one club's name", () => {
  const rows = [
    row({
      delivery_id: 1,
      tee_at: "2026-09-19T07:00:00+10:00",
      slot_id: "the-coast:2026-09-19:0700:public-play",
    }),
    row({
      delivery_id: 2,
      slot_id: "bexley:2026-09-19:0930:social",
      course_slug: "bexley",
      course_name: "Bexley Golf Club",
      tee_at: "2026-09-19T09:30:00+10:00",
    }),
  ];
  const n = buildNotification(rows);
  assertEquals(n.title, "2 tee times matched your alert");
  // tees.course_* describe the primary slot, which is the one in the body.
  assertEquals(n.payload.tees.course_slug, "the-coast");
  assertEquals(n.payload.tees.primary_slot_id, "the-coast:2026-09-19:0700:public-play");
});

Deno.test("the payload carries exactly the keys ticket E3 decodes", () => {
  const n = buildNotification([row()]);
  assertEquals(Object.keys(n.payload).sort(), ["aps", "tees"]);
  assertEquals(Object.keys(n.payload.aps).sort(), ["alert", "interruption-level", "sound", "thread-id"]);
  assertEquals(Object.keys(n.payload.tees).sort(), [
    "count",
    "course_name",
    "course_slug",
    "primary_slot_id",
    "slot_ids",
    "tee_at",
    "v",
    "watch_id",
  ]);
  assertEquals(n.payload.aps.sound, "default");
  assertEquals(n.payload.aps["thread-id"], `watch:${WATCH}`);
  assertEquals(n.payload.aps["interruption-level"], "time-sensitive");
  assertEquals(n.payload.tees.v, 1);
  assertEquals(n.payload.tees.watch_id, WATCH);
});

Deno.test("the collapse id is watch-scoped and inside the 64-byte limit", () => {
  const id = collapseIdFor(WATCH);
  assertEquals(id, `watch:${WATCH}`);
  assert(new TextEncoder().encode(id).length <= 64);
  assert(new TextEncoder().encode(collapseIdFor("x".repeat(200))).length <= 64);
});

Deno.test("the push expires when the LAST slot in it has teed off", () => {
  const rows = [
    row({ delivery_id: 1, slot_id: "a", tee_at: "2026-09-19T07:00:00+10:00" }),
    row({ delivery_id: 2, slot_id: "b", tee_at: "2026-09-19T11:00:00+10:00" }),
  ];
  const n = buildNotification(rows);
  assertEquals(n.expiration, Math.floor(Date.parse("2026-09-19T11:00:00+10:00") / 1000));
});

Deno.test("an empty group is a programming error, not an empty push", () => {
  assertThrows(() => buildNotification([]));
});

// ----------------------------------------------------------------- grouping

Deno.test("rows collapse into one group per (user, watch), deduplicated", () => {
  const rows = [
    row({ delivery_id: 1, token: "phone-1" }),
    row({ delivery_id: 1, token: "phone-2" }),
    row({ delivery_id: 2, slot_id: "the-coast:2026-09-19:0806:public-play", token: "phone-1" }),
    row({ delivery_id: 2, slot_id: "the-coast:2026-09-19:0806:public-play", token: "phone-2" }),
    row({ delivery_id: 9, user_id: "22222222-2222-2222-2222-222222222222", token: "phone-3" }),
  ];

  const groups = groupAlertRows(rows);
  assertEquals(groups.length, 2);
  assertEquals(groups[0].deliveryIds, [1, 2]);
  assertEquals(groups[0].devices.map((d) => d.token), ["phone-1", "phone-2"]);

  // Two devices, one notification: the slot count is not doubled by the join.
  assertEquals(buildNotification(groups[0].rows).count, 2);
});

Deno.test("two users sharing one iPhone: one push, the loser is deferred not dropped", () => {
  const rows = [
    row({ delivery_id: 1, user_id: "user-a", token: "shared-phone" }),
    row({ delivery_id: 2, user_id: "user-b", watch_id: "watch-b", token: "shared-phone" }),
  ];
  const [first, second] = groupAlertRows(rows);

  const used = new Set<string>();
  const planA = planDevices(first, used);
  assertEquals(planA.send.map((d) => d.token), ["shared-phone"]);
  assertEquals(planA.deferred, []);
  for (const d of planA.send) used.add(d.token);

  const planB = planDevices(second, used);
  assertEquals(planB.send, [], "the device must not receive a second push in the same run");
  assertEquals(planB.deferred, ["shared-phone"]);
});

Deno.test("a second device the sharer alone owns still receives the push", () => {
  const rows = [
    row({ delivery_id: 2, user_id: "user-b", token: "shared-phone" }),
    row({ delivery_id: 2, user_id: "user-b", token: "own-phone" }),
  ];
  const [group] = groupAlertRows(rows);
  const plan = planDevices(group, new Set(["shared-phone"]));
  assertEquals(plan.send.map((d) => d.token), ["own-phone"]);
  assertEquals(plan.deferred, ["shared-phone"]);
});
