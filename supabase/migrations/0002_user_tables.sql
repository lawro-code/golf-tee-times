-- Tees for the Boys — user-owned tables: watches, alert deliveries, push
-- tokens, bookings. Everything here hangs off auth.users.

-- ---------------------------------------------------------------------------
-- watches — a saved search. The active filters describe it completely, which is
-- why creating one is a single button and not a wizard. Columns, not jsonb:
-- the matcher runs this as a SQL predicate.
-- null on a filter column means "any".
-- ---------------------------------------------------------------------------
create table if not exists public.watches (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  label              text,
  course_slugs       text[],
  weekdays           smallint[],                    -- ISO-8601: 1=Mon .. 7=Sun
  date_from          date,
  date_to            date,
  time_from          time not null default '05:00',
  time_to            time not null default '19:00',
  min_players        smallint not null default 1 check (min_players between 1 and 4),
  holes              smallint check (holes is null or holes in (9, 18)),
  price_max          numeric(10,2) check (price_max is null or price_max >= 0),
  max_drive_minutes  integer check (max_drive_minutes is null or max_drive_minutes >= 0),
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  expires_at         timestamptz,
  constraint watches_date_order check (date_from is null or date_to is null or date_from <= date_to),
  constraint watches_time_order check (time_from <= time_to),
  constraint watches_weekdays_sane check (
    weekdays is null
    or (array_length(weekdays, 1) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[])
  ),
  constraint watches_courses_sane check (course_slugs is null or array_length(course_slugs, 1) > 0)
);

create index if not exists watches_user_idx        on public.watches (user_id);
create index if not exists watches_live_idx        on public.watches (expires_at) where active;

-- ---------------------------------------------------------------------------
-- alert_deliveries — the exactly-once ledger.
-- The unique constraint IS the guarantee. A slot that stays open across twelve
-- scrapes inserts once and conflicts eleven times. Do not remove it, and do not
-- "fix" a duplicate-key error by deleting rows.
-- ---------------------------------------------------------------------------
create table if not exists public.alert_deliveries (
  id                 bigint generated always as identity primary key,
  watch_id           uuid not null references public.watches(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  slot_id            text not null references public.slots(id) on delete cascade,
  matched_at         timestamptz not null default now(),
  sent_at            timestamptz,
  status             text not null default 'queued'
                       check (status in ('queued', 'sent', 'failed', 'suppressed')),
  suppressed_reason  text,
  apns_id            text,
  error              text,
  constraint alert_deliveries_exactly_once unique (watch_id, slot_id)
);

create index if not exists alert_deliveries_user_time_idx on public.alert_deliveries (user_id, matched_at desc);
create index if not exists alert_deliveries_queued_idx    on public.alert_deliveries (matched_at) where status = 'queued';
create index if not exists alert_deliveries_slot_idx      on public.alert_deliveries (slot_id);

-- ---------------------------------------------------------------------------
-- push_tokens — APNs device tokens. Token is the key: the same device
-- re-registering must not create a second row.
-- ---------------------------------------------------------------------------
create table if not exists public.push_tokens (
  token        text primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  platform     text not null default 'ios' check (platform in ('ios')),
  environment  text not null default 'sandbox' check (environment in ('sandbox', 'production')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

-- ---------------------------------------------------------------------------
-- bookings — "did you book?" answered yes. Course name and tee time are
-- denormalised on purpose: an upcoming round must still render after the slot
-- row is marked gone.
-- ---------------------------------------------------------------------------
create table if not exists public.bookings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  slot_id       text references public.slots(id) on delete set null,
  course_slug   text not null references public.courses(slug),
  course_name   text not null,
  tee_at        timestamptz not null,
  tee_date      date not null,
  tee_time      time not null,
  players       smallint check (players is null or players between 1 and 4),
  holes         smallint check (holes is null or holes in (9, 18)),
  price         numeric(10,2) check (price is null or price >= 0),
  booking_url   text,
  confirmed_at  timestamptz not null default now(),
  cancelled_at  timestamptz,
  constraint bookings_user_slot_once unique (user_id, slot_id)
);

create index if not exists bookings_user_tee_idx    on public.bookings (user_id, tee_at);
create index if not exists bookings_slot_idx        on public.bookings (slot_id);
create index if not exists bookings_course_idx      on public.bookings (course_slug);
