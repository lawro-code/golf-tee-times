-- Tees for the Boys — alert delivery: claiming, coalescing, and recording.
-- Track E, ticket E2.
--
-- E1 decides WHO should hear about WHAT and writes a 'queued' row into
-- public.alert_deliveries. Everything in this file happens after that row
-- exists: leasing it to a dispatcher, collapsing a user's matches into one
-- notification, and writing down what APNs said.
--
-- 'alerts_0020_' sorts after '000*' and after 'alerts_0010_', so the frozen
-- Stage 0 tables and E1's watch lifecycle are both in place by the time
-- anything below runs. Nothing here edits a frozen file: the new column is
-- added, not altered in, and no policy is touched.
--
-- Every statement is safe to re-run — scripts/db_test.sh applies every
-- migration twice and a rerun after a partial failure must not need a
-- hand-repaired database.

-- ---------------------------------------------------------------------------
-- claimed_at — a lease, not a status.
--
-- public.alert_deliveries.status is frozen with a check constraint allowing
-- exactly queued/sent/failed/suppressed, and adding a 'sending' state would
-- mean altering it. It would also be the wrong shape: a dispatcher that dies
-- between claiming a row and hearing back from APNs would strand the alert in
-- a state nothing ever leaves.
--
-- A lease recovers on its own. A row is claimable when it is still queued and
-- either nobody holds it or whoever held it has been gone for five minutes.
-- The worst case is a duplicate push for one listing, which is a great deal
-- better than silence about a tee time somebody is watching for.
-- ---------------------------------------------------------------------------
alter table public.alert_deliveries
  add column if not exists claimed_at timestamptz;

comment on column public.alert_deliveries.claimed_at is
  'Lease timestamp. Set when a dispatcher takes the row, cleared when it is sent or released. A lease older than five minutes is reclaimable: the dispatcher holding it died.';

-- The claim scan: queued rows, grouped by user, ordered by how stale the lease
-- is. Partial because the queue is the small end of this table — a sent row
-- stays forever as the exactly-once ledger and must not be indexed here.
create index if not exists alert_deliveries_claimable_idx
  on public.alert_deliveries (user_id, claimed_at)
  where status = 'queued';

-- The rate-limit scan: "has this user heard from us in the last ten minutes".
-- Also partial, and descending on sent_at so the answer is the first row read.
create index if not exists alert_deliveries_sent_recent_idx
  on public.alert_deliveries (user_id, sent_at desc)
  where status = 'sent';

-- ---------------------------------------------------------------------------
-- claim_alert_batch — the rate limit, and it coalesces rather than drops.
--
-- A release window at one club can open forty slots at once. Forty separate
-- pushes would be the app uninstalling itself. So a run hands a user ONE
-- group, the group becomes ONE notification that says forty, and everything
-- that does not fit stays queued for the next run.
--
-- What it deliberately does NOT do is insert 'suppressed' rows to shed load.
-- A suppressed row consumes the (watch, slot, opened_at) unique key forever,
-- so the user would silently never hear about that listing — and a relisted
-- cancellation is the entire reason this app exists (CONTRACT.md section 6).
-- Everything E1 queues eventually goes out. Collapsed, delayed, but never
-- dropped.
--
-- The three limits:
--   * one watch per user per run   — one notification, whatever matched
--   * p_max_slots_per_user slots   — the remainder stay queued
--   * ten minutes between pushes   — a busy user is not machine-gunned
--
-- "Per run" holds across overlapping runs too, not only within one: a user
-- with a claim still in flight (claimed, not yet sent) is untouchable by any
-- OTHER call to this function until that claim is sent, fails, or its lease
-- goes stale — see the claimed_at check below. Without that, two overlapping
-- dispatcher invocations could each claim a different watch for the same
-- user and both push before either recorded sent_at.
--
-- And one freshness gate, re-checked at claim time rather than trusted from
-- queue time: the slot has to still be open and still be in the future.
--
-- Returns one row per (delivery, device token): a user with two phones gets
-- two rows per delivery and the sender pushes to both.
-- ---------------------------------------------------------------------------
create or replace function public.claim_alert_batch(
  p_max_users          integer default 200,
  p_max_slots_per_user integer default 12
)
returns table (
  delivery_id      bigint,
  user_id          uuid,
  watch_id         uuid,
  slot_id          text,
  course_slug      text,
  course_name      text,
  tee_at           timestamptz,
  tee_date         date,
  tee_time         time,
  spots_available  smallint,
  holes            smallint,
  price_min        numeric,
  token            text,
  environment      text
)
language sql
security definer
set search_path = ''
as $$
  with claimable as (
    select d.id, d.user_id, d.watch_id, d.slot_id, s.tee_at
      from public.alert_deliveries d
      join public.slots s on s.id = d.slot_id
     where d.status = 'queued'
       and (d.claimed_at is null or d.claimed_at < now() - interval '5 minutes')
       -- The slot must STILL be worth pushing about. E1's queue_watch_matches
       -- applies exactly this pair at queue time and then never runs again,
       -- but a queued row can sit here a long while: p_max_slots_per_user
       -- plus the ten-minute cool-down means a user matching a forty-slot
       -- release window waits ten minutes for slots 13-24 and twenty for
       -- 25-36 — and a release window is precisely when slots get booked out
       -- in minutes. Any 429, 5xx or dispatcher outage widens the gap. A
       -- stale slot also has the EARLIEST tee_at, so it wins both the group
       -- ordering and primary_slot_id: it becomes the headline and the slot
       -- the app routes the notification tap to. Nobody else re-checks this.
       --
       -- Safe against a scrape outage: 'gone' is only ever set by a
       -- successful scrape that stopped listing the slot (0001_core.sql), so
       -- a failed scrape cannot silence anyone. It just leaves rows queued.
       --
       -- Rows filtered out here stay 'queued' and are never picked up again.
       -- That is deliberate, not a leak — alert_deliveries_exactly_once means
       -- E1 will never re-queue that (watch, slot, listing) either, and a
       -- booked-then-relisted slot arrives as a NEW row with a fresh
       -- slot_opened_at. A queued row against a dead slot is the ledger
       -- remembering we decided not to send it.
       and s.status = 'open'
       and s.tee_at > now()
       -- A user with no registered device is not a candidate at all. Skipping
       -- them here rather than losing them to an inner join further down
       -- means they never consume one of p_max_users on a run that could
       -- never have pushed to them. Their rows stay queued and go out on the
       -- first run after they register a phone.
       and exists (
         select 1 from public.push_tokens t where t.user_id = d.user_id
       )
       -- Ten-minute cool-down. Their rows stay queued; nothing is discarded.
       and not exists (
         select 1
           from public.alert_deliveries r
          where r.user_id = d.user_id
            and r.status = 'sent'
            and r.sent_at > now() - interval '10 minutes'
       )
       -- A claim already in flight for this user counts too, not only a sent
       -- one. sent_at is written by mark_alert_sent only AFTER the outbound
       -- APNs call completes, so a user whose first claim is still sitting
       -- between "claimed" and "sent" would otherwise look untouched to a
       -- second, overlapping call -- a scheduler retry, a second dispatcher
       -- instance -- and that call would happily hand out this user's OTHER
       -- watch, or another batch of the SAME watch's remaining slots, before
       -- the first push has even reached Apple. Same five-minute lease
       -- threshold as the claimable check above: once a lease goes stale the
       -- row becomes reclaimable and so does the rest of this user's queue.
       and not exists (
         select 1
           from public.alert_deliveries r
          where r.user_id = d.user_id
            and r.claimed_at is not null
            and r.claimed_at > now() - interval '5 minutes'
       )
  ),
  -- One watch per user. The watch chosen is the one holding the soonest
  -- tee-off, because a tee time is perishable: an alert about 7am tomorrow is
  -- worth more than one about Sunday week. Ties break on delivery id so two
  -- dispatchers make the same choice.
  ranked_watches as (
    select c.user_id,
           c.watch_id,
           min(c.tee_at) as soonest,
           min(c.id)     as first_id,
           row_number() over (
             partition by c.user_id
             order by min(c.tee_at), min(c.id)
           ) as rn
      from claimable c
     group by c.user_id, c.watch_id
  ),
  chosen_watch as (
    select r.user_id, r.watch_id
      from ranked_watches r
     where r.rn = 1
     order by r.soonest, r.first_id
     limit greatest(coalesce(p_max_users, 0), 0)
  ),
  numbered as (
    select c.id,
           row_number() over (
             partition by c.user_id
             order by c.tee_at, c.id
           ) as rn
      from claimable c
      join chosen_watch w
        on w.user_id = c.user_id
       and w.watch_id = c.watch_id
  ),
  -- Lock only what we are about to hand out. skip locked means a second
  -- dispatcher running at the same time takes different rows instead of
  -- blocking behind this one.
  locked as (
    select d.id
      from public.alert_deliveries d
     where d.id in (
             select n.id
               from numbered n
              where n.rn <= greatest(coalesce(p_max_slots_per_user, 0), 0)
           )
       for update skip locked
  ),
  claimed as (
    update public.alert_deliveries d
       set claimed_at = now()
      from locked l
     where d.id = l.id
    returning d.id, d.user_id, d.watch_id, d.slot_id
  )
  select cl.id,
         cl.user_id,
         cl.watch_id,
         cl.slot_id,
         s.course_slug,
         c.name,
         s.tee_at,
         s.tee_date,
         s.tee_time,
         s.spots_available,
         s.holes,
         s.price_min,
         t.token,
         t.environment
    from claimed cl
    join public.slots       s on s.id      = cl.slot_id
    join public.courses     c on c.slug    = s.course_slug
    join public.push_tokens t on t.user_id = cl.user_id
   order by cl.user_id, s.tee_at, cl.id, t.token
$$;

comment on function public.claim_alert_batch(integer, integer) is
  'Leases a batch of queued alert deliveries whose slot is still open and still in the future: at most one watch per user per run, at most p_max_slots_per_user slots in it, and nothing at all for a user pushed in the last ten minutes or with a claim still in flight from an overlapping run. Returns one row per (delivery, device token). Rows that do not fit stay queued — this coalesces, it never drops.';

-- ---------------------------------------------------------------------------
-- mark_alert_sent — one apns-id across the whole coalesced group.
--
-- Every delivery in a group carries the same apns_id on purpose: that is the
-- record proving one push covered N matches, and it is what makes an APNs
-- support question answerable months later.
--
-- Only queued rows move. A row somebody else already marked sent or failed is
-- left where it is rather than rewritten.
-- ---------------------------------------------------------------------------
create or replace function public.mark_alert_sent(
  p_ids     bigint[],
  p_apns_id text
)
returns integer
language sql
security definer
set search_path = ''
as $$
  with moved as (
    update public.alert_deliveries d
       set status     = 'sent',
           sent_at    = now(),
           apns_id    = p_apns_id,
           claimed_at = null,
           -- A retryable failure on an earlier run left a note here. It is
           -- not true any more.
           error      = null
     where d.id = any (coalesce(p_ids, '{}'::bigint[]))
       and d.status = 'queued'
    returning 1
  )
  select count(*)::integer from moved
$$;

comment on function public.mark_alert_sent(bigint[], text) is
  'Marks a coalesced group sent, all of it stamped with the one apns_id that covered it. Returns how many rows moved.';

-- ---------------------------------------------------------------------------
-- mark_alert_failed — the difference between "try again" and "give up".
--
-- Retryable (APNs 429, any 5xx, a device we cannot reach yet): clear the lease
-- and LEAVE the row queued. The next run picks it up. The error text is kept
-- as a note and is cleared when the row finally goes out.
--
-- Non-retryable (a 403 misconfiguration, a malformed payload): status 'failed'
-- and the error text stays. Nothing will retry it, and the ledger says why.
-- ---------------------------------------------------------------------------
create or replace function public.mark_alert_failed(
  p_ids       bigint[],
  p_error     text,
  p_retryable boolean
)
returns integer
language sql
security definer
set search_path = ''
as $$
  with moved as (
    update public.alert_deliveries d
       set status     = case when coalesce(p_retryable, false) then 'queued' else 'failed' end,
           claimed_at = null,
           error      = p_error
     where d.id = any (coalesce(p_ids, '{}'::bigint[]))
       and d.status = 'queued'
    returning 1
  )
  select count(*)::integer from moved
$$;

comment on function public.mark_alert_failed(bigint[], text, boolean) is
  'Records a delivery failure. Retryable releases the lease and leaves the row queued for the next run; non-retryable marks it failed with the reason. Returns how many rows moved.';

-- ---------------------------------------------------------------------------
-- retire_push_token — a device that no longer exists.
--
-- APNs answers 410 Unregistered (or 400 BadDeviceToken) when the app has been
-- deleted or the token is not ours. Apple requires we stop sending to it.
--
-- Deletes EVERY row holding that token, across users. push_tokens is keyed
-- (user_id, token) because two mates sharing one iPhone is ordinary for this
-- app (0002_user_tables.sql), but the thing Apple just told us is dead is the
-- device, not one person's claim on it. Anyone still signed in there re-
-- registers on next launch.
-- ---------------------------------------------------------------------------
create or replace function public.retire_push_token(p_token text)
returns integer
language sql
security definer
set search_path = ''
as $$
  with gone as (
    delete from public.push_tokens t
     where t.token = p_token
    returning 1
  )
  select count(*)::integer from gone
$$;

comment on function public.retire_push_token(text) is
  'Deletes every push_tokens row holding this token, across all users on that device. For an APNs 410 Unregistered or 400 BadDeviceToken.';

-- ---------------------------------------------------------------------------
-- Grants.
--
-- Postgres grants EXECUTE on a new function to PUBLIC, and Supabase's default
-- privileges add anon and authenticated on top. All four of these are writers
-- behind security definer; only the dispatcher's service role may call them.
-- ---------------------------------------------------------------------------
revoke all on function public.claim_alert_batch(integer, integer)    from public, anon, authenticated;
revoke all on function public.mark_alert_sent(bigint[], text)        from public, anon, authenticated;
revoke all on function public.mark_alert_failed(bigint[], text, boolean) from public, anon, authenticated;
revoke all on function public.retire_push_token(text)                from public, anon, authenticated;

grant execute on function public.claim_alert_batch(integer, integer)    to service_role;
grant execute on function public.mark_alert_sent(bigint[], text)        to service_role;
grant execute on function public.mark_alert_failed(bigint[], text, boolean) to service_role;
grant execute on function public.retire_push_token(text)                to service_role;
