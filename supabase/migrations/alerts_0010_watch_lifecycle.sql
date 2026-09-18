-- Tees for the Boys — watch lifecycle: eligibility, expiry and satisfaction.
-- Track E, ticket E1.
--
-- This file applies after the frozen Stage 0 migrations: 'alerts_' sorts after
-- '000' in the glob scripts/db_test.sh walks, so public.watches and
-- public.bookings already exist by the time anything below runs.
--
-- Nothing here sends a notification. This file answers one question — is this
-- watch still allowed to fire — and alerts_0011_matcher.sql turns the answer
-- into queued rows. Delivery is E2's.

-- ---------------------------------------------------------------------------
-- Satisfaction columns.
--
-- 0002_user_tables.sql is frozen, so "the user told us they booked this" is
-- bolted on here rather than edited in. Both columns are additive and both
-- statements are safe to re-run: db_test.sh applies every migration twice.
-- ---------------------------------------------------------------------------
alter table public.watches
  add column if not exists satisfied_at timestamptz;

alter table public.watches
  add column if not exists satisfied_by_booking_id uuid
    references public.bookings(id) on delete set null;

comment on column public.watches.satisfied_at is
  'When the user confirmed a booking that matches this watch. Null means the watch has never been satisfied.';
comment on column public.watches.satisfied_by_booking_id is
  'The booking that satisfied it. Cancelling that booking reverses the satisfaction — see the bookings_satisfy_watches trigger.';

-- Every foreign key column in public has to be the leading column of an index.
-- supabase/local/01_assertions.sql walks pg_constraint and fails the whole gate
-- if one is not, so this index is load-bearing, not an optimisation.
create index if not exists watches_satisfied_by_booking_idx
  on public.watches (satisfied_by_booking_id);

-- ---------------------------------------------------------------------------
-- private.watch_matches — the one predicate.
--
-- Deliberately shared: the matcher asks it about a scraped slot and the
-- bookings trigger asks it about a round the user says they booked. One
-- definition means a booking can never "not count" against a watch that the
-- same round would have fired.
--
-- Every filter column on public.watches is nullable and null means ANY.
-- ---------------------------------------------------------------------------
create or replace function private.watch_matches(
  w               public.watches,
  p_course_slug   text,
  p_tee_date      date,
  p_tee_time      time,
  p_holes         smallint,
  p_price         numeric,
  p_spots         smallint,
  p_drive_minutes integer
)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select
    -- course: no list means every course on the roster
    (w.course_slugs is null or p_course_slug = any (w.course_slugs))
    -- weekday: ISO-8601, 1 = Monday .. 7 = Sunday, matching the column comment
    and (w.weekdays is null or extract(isodow from p_tee_date)::smallint = any (w.weekdays))
    -- date window, inclusive at both ends
    and (w.date_from is null or p_tee_date >= w.date_from)
    and (w.date_to   is null or p_tee_date <= w.date_to)
    -- time window. time_from/time_to are not null and constrained from <= to.
    and p_tee_time between w.time_from and w.time_to
    -- players: the group has to fit
    and p_spots >= w.min_players
    -- holes for THIS booking, which is not always the course's hole count
    and (w.holes is null or p_holes = w.holes)
    -- drive time: a course with no measured drive cannot satisfy a drive cap
    and (w.max_drive_minutes is null
         or (p_drive_minutes is not null and p_drive_minutes <= w.max_drive_minutes))
    -- Price, and READ THIS BEFORE "FIXING" IT.
    --
    -- An UNPRICED slot MATCHES a price-capped watch. That is the product rule,
    -- not an oversight: 282 of 1755 slots in the golden scrape publish no fee
    -- at all (CONTRACT.md section 3), and a price filter that silently dropped
    -- them would hide one listing in six. The push labels an unpriced round
    -- "price at course" instead. Tightening this to
    -- `p_price is not null and p_price <= w.price_max` would delete Warringah
    -- and Bexley from every price-filtered alert.
    and (w.price_max is null or p_price is null or p_price <= w.price_max)
$$;

comment on function private.watch_matches(public.watches, text, date, time, smallint, numeric, smallint, integer) is
  'Does this watch cover this round? One predicate, asked of scraped slots by the matcher and of confirmed bookings by the satisfaction trigger. Null on a filter column means any. An unpriced round matches a price cap on purpose.';

-- ---------------------------------------------------------------------------
-- Expiry, written twice on purpose.
--
-- private.watch_horizon_passed is the single definition of "this watch's target
-- date is behind us". private.watch_is_live is what actually stops a stale
-- watch from firing — it is evaluated by the matcher on every run and does not
-- depend on any scheduled job existing. public.expire_watches() is
-- housekeeping: it flips the flag so the user's own list of watches is honest.
--
-- Nothing is wired to a cron yet. The predicate is correct whether or not one
-- ever is.
-- ---------------------------------------------------------------------------
create or replace function private.watch_horizon_passed(w public.watches)
returns boolean
language sql
stable
parallel safe
set search_path = ''
as $$
  select case
    -- date_to is a wall-clock calendar date at the course, so "has it passed"
    -- is asked in Australia/Sydney and never in UTC. In the ten hours either
    -- side of UTC midnight the two answers differ, and a UTC answer would kill
    -- a watch for today's golf. CONTRACT.md section 4.
    when w.date_to is not null
      then w.date_to < (now() at time zone 'Australia/Sydney')::date
    -- expires_at is an absolute instant and already carries its own offset.
    when w.expires_at is not null
      then w.expires_at <= now()
    -- No date_to and no expires_at: the watch runs until the user stops it.
    else false
  end
$$;

comment on function private.watch_horizon_passed(public.watches) is
  'True once the watch''s target date is behind us. date_to is compared against today in Australia/Sydney; expires_at is an instant.';

create or replace function private.watch_is_live(w public.watches)
returns boolean
language sql
stable
parallel safe
set search_path = ''
as $$
  select w.active
     and w.satisfied_at is null
     and not private.watch_horizon_passed(w)
$$;

comment on function private.watch_is_live(public.watches) is
  'May this watch still fire? Active, unsatisfied, and inside its horizon. This is the gate the matcher uses; expire_watches() is only housekeeping.';

create or replace function public.expire_watches()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_count integer;
begin
  with expired as (
    select w.id
      from public.watches w
     where w.active
       and private.watch_horizon_passed(w)
  )
  update public.watches t
     set active     = false,
         updated_at = now()
    from expired e
   where t.id = e.id;

  get diagnostics expired_count = row_count;
  return expired_count;
end $$;

comment on function public.expire_watches() is
  'Housekeeping: deactivates watches whose target date has passed so the user''s list is honest. Returns the count. Safe to run at any cadence, or never — private.watch_is_live() already stops a stale watch firing.';

-- Supabase's default privileges grant EXECUTE on new functions in public to
-- anon and authenticated, and Postgres grants it to PUBLIC. This is a writer;
-- only the service role calls it.
revoke all on function public.expire_watches() from public, anon, authenticated;
grant execute on function public.expire_watches() to service_role;

-- ---------------------------------------------------------------------------
-- Satisfaction: "did you book?" answered yes.
--
-- A watch stops firing once the user confirms a booking it covers, and starts
-- again if they cancel that booking. The second half is not a nicety — a
-- cancelled tee time being relisted is the entire reason this app exists
-- (CONTRACT.md section 6), and the person who cancelled is the likeliest to
-- want the alert back.
--
-- security definer because it writes public.watches on behalf of whoever
-- inserted the booking, and RLS on watches is owner-only. It only ever touches
-- rows belonging to the booking's own user.
-- ---------------------------------------------------------------------------
create or replace function private.bookings_satisfy_watches()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_drive_minutes integer;
  v_now_live      boolean;
  v_was_live      boolean;
begin
  -- Branch on whether the BOOKING just became live, never on tg_op.
  --
  -- "They booked it" does not only arrive as an INSERT. The app's
  -- confirmBooking (ios/TeesForTheBoys/Data/BookingRepository.swift) is an
  -- upsert on (user_id, slot_id) that always writes cancelled_at, explicitly
  -- null when the user says yes — saying yes after saying you cancelled means
  -- you have the round after all. A second yes therefore lands as an UPDATE
  -- with cancelled_at in the SET list, fires `update of cancelled_at`, and is
  -- a not-null -> null transition. Branching on tg_op skipped it: the booking
  -- was live again and the watch stayed armed, so the user got pushed every
  -- other matching tee time while holding the round they had just rebooked.
  --
  -- Two booleans instead, and every transition falls out of them:
  --   insert live, or un-cancel          -> satisfy the watches it covers
  --   cancel                             -> reverse that satisfaction
  --   insert already cancelled, re-cancel,
  --   or a write that changes nothing    -> do nothing
  --
  -- `update of cancelled_at` fires whenever the column is in the SET list,
  -- unchanged value included, which is exactly why the guards are on the
  -- values and not on the operation.
  v_now_live := new.cancelled_at is null;
  v_was_live := (tg_op = 'UPDATE' and old.cancelled_at is null);

  if v_now_live and not v_was_live then
    select c.drive_minutes_from_bondi
      into v_drive_minutes
      from public.courses c
     where c.slug = new.course_slug;

    update public.watches t
       set active                  = false,
           satisfied_at            = now(),
           satisfied_by_booking_id = new.id,
           updated_at              = now()
     where t.id in (
       select w.id
         from public.watches w
        where w.user_id = new.user_id
          and private.watch_is_live(w)
          -- p_spots is the watch's own min_players, not a spot count off the
          -- booking: the user has the tee time. Rejecting their own confirmed
          -- round for spot count would leave the watch firing at them forever.
          --
          -- holes is passed as recorded. bookings.holes is nullable, so a
          -- booking captured without it will not satisfy a holes-specific
          -- watch; every booking made from a slot carries it.
          and private.watch_matches(w, new.course_slug, new.tee_date, new.tee_time,
                                    new.holes, new.price, w.min_players, v_drive_minutes)
     );

  elsif v_was_live and not v_now_live then
    update public.watches t
       set active                  = true,
           satisfied_at            = null,
           satisfied_by_booking_id = null,
           updated_at              = now()
     where t.id in (
       select w.id
         from public.watches w
        where w.satisfied_by_booking_id = new.id
          -- A watch whose date has since passed stays off. Reviving it would
          -- fire alerts for golf that has already been played.
          and not private.watch_horizon_passed(w)
     );
  end if;

  return new;
end $$;

comment on function private.bookings_satisfy_watches() is
  'A booking becoming live — a fresh confirm or a re-confirm after cancelling — deactivates the watches it satisfies; cancelling it brings them back if their date has not passed.';

drop trigger if exists bookings_satisfy_watches on public.bookings;
create trigger bookings_satisfy_watches
  after insert or update of cancelled_at on public.bookings
  for each row execute function private.bookings_satisfy_watches();
