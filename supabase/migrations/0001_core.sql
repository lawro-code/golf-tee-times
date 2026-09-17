-- Tees for the Boys — core schema.
-- Stage 0. Frozen contract: see CONTRACT.md. Do not edit without bumping
-- contract/VERSION and contract/payload.schema.json in the same change.

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- courses — mirrors courses.json, which stays the source of truth for the roster.
-- ---------------------------------------------------------------------------
create table if not exists public.courses (
  slug                      text primary key,
  name                      text not null,
  region                    text not null default '',
  host                      text not null,
  fee_group_id              text not null,
  booking_resource_id       text not null default '3000000',
  drive_minutes_from_bondi  integer check (drive_minutes_from_bondi is null or drive_minutes_from_bondi >= 0),
  holes                     smallint not null check (holes in (9, 18)),
  par                       smallint check (par is null or par between 27 and 80),
  -- Course length in metres is NOT on the MiClub timesheet and is not scraped.
  -- Column exists so the contract is stable; values stay null until sourced.
  length_metres             integer check (length_metres is null or length_metres between 1000 and 7500),
  requires_registration     boolean not null default false,
  address                   text,
  notes                     text not null default '',
  sort_order                smallint not null,
  active                    boolean not null default true,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

comment on column public.courses.length_metres is
  'Not available from MiClub. Null until sourced deliberately. Do not invent values.';
comment on column public.courses.requires_registration is
  'True when the club requires a free public-member account before checkout.';

-- ---------------------------------------------------------------------------
-- slots — one row per (course, date, time, tee) that has ever been seen open.
-- id is deterministic: '{course_slug}:{YYYY-MM-DD}:{HHMM}:{tee}'. The tee
-- segment is not decoration — Warringah runs two-tee starts, and keying on
-- time alone collapsed 141 of its 289 tee times. Stability of this id is what
-- makes exactly-once push possible.
-- ---------------------------------------------------------------------------
create table if not exists public.slots (
  id                text primary key,
  course_slug       text not null references public.courses(slug) on delete cascade,
  tee_date          date not null,
  tee_time          time not null,
  -- Absolute instant, resolved in Australia/Sydney by the writer. Never derive
  -- this in the client: the DST rules live in one place on purpose.
  tee_at            timestamptz not null,
  spots_available   smallint not null check (spots_available >= 0),
  total_spots       smallint not null check (total_spots > 0),
  -- Holes for THIS booking. Not always the course's hole count: three
  -- 18-hole courses also sell 9-hole tee times.
  holes             smallint not null check (holes in (9, 18)),
  price_min         numeric(10,2) check (price_min is null or price_min >= 0),
  price_max         numeric(10,2) check (price_max is null or price_max >= 0),
  price_tiers       jsonb not null default '[]'::jsonb,
  booking_type      text not null default '',
  booking_url       text not null,
  status            text not null default 'open' check (status in ('open', 'gone')),
  first_seen_at     timestamptz not null default now(),
  last_seen_at      timestamptz not null default now(),
  -- When THIS listing opened. A tee time that is booked and then cancelled is
  -- the same slot reopening, and it gets a new opened_at. That is what lets a
  -- cancellation alert a second time without twelve scrapes of one unchanged
  -- listing alerting twelve times. See the slots_lifecycle trigger below.
  opened_at         timestamptz not null default now(),
  reopen_count      smallint not null default 0 check (reopen_count >= 0),
  gone_at           timestamptz,
  -- booking_type is part of the key because two-tee starts are real: at
  -- Warringah a 1st Tee and a 10th Tee group go out at the same minute and are
  -- two separate bookings.
  constraint slots_natural_key unique (course_slug, tee_date, tee_time, booking_type),
  constraint slots_spots_sane  check (spots_available <= total_spots),
  constraint slots_price_order check (price_min is null or price_max is null or price_min <= price_max),
  -- Being gone implies a timestamp; the reverse is NOT required, because a
  -- reopened slot keeps its last gone_at as history. A biconditional here made
  -- the obvious upsert ("set status = 'open'") fail on a constraint violation.
  constraint slots_gone_stamp  check (status <> 'gone' or gone_at is not null),
  constraint slots_tiers_array check (jsonb_typeof(price_tiers) = 'array')
);

comment on column public.slots.id is
  'Deterministic: course_slug:YYYY-MM-DD:HHMM:tee. Stable across scrapes.';
comment on column public.slots.status is
  '''gone'' means a successful scrape of that course/day no longer listed it. Rows are never deleted.';

-- Slot lifecycle, handled once here so no writer has to remember it.
--
-- The scraper's upsert says only what it saw: status 'open' with the spots it
-- found, or status 'gone' for a slot a successful scrape stopped listing.
-- Everything else — stamping gone_at, clearing it on the way back, starting a
-- new opened_at for a relisted tee time — happens below.
create or replace function private.slots_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.status = 'open' and old.status = 'gone' then
      -- The cancellation case. A new listing of the same tee time.
      new.opened_at    := now();
      new.reopen_count := old.reopen_count + 1;
      new.gone_at      := null;
    elsif new.status = 'gone' and old.status = 'open' then
      new.gone_at := coalesce(new.gone_at, now());
    elsif new.status = 'open' then
      -- Still open. opened_at belongs to the listing, not to the scrape.
      new.opened_at    := old.opened_at;
      new.reopen_count := old.reopen_count;
    end if;
  elsif new.status = 'gone' then
    new.gone_at := coalesce(new.gone_at, now());
  end if;
  return new;
end $$;

drop trigger if exists slots_lifecycle on public.slots;
create trigger slots_lifecycle
  before insert or update on public.slots
  for each row execute function private.slots_lifecycle();

create index if not exists slots_open_tee_at_idx  on public.slots (tee_at) where status = 'open';
create index if not exists slots_course_date_idx  on public.slots (course_slug, tee_date);
create index if not exists slots_date_time_idx    on public.slots (tee_date, tee_time) where status = 'open';
create index if not exists slots_last_seen_idx    on public.slots (last_seen_at);

-- ---------------------------------------------------------------------------
-- Scrape health. Without these a partial scrape is indistinguishable from a
-- complete one, and stale data is indistinguishable from an empty day.
-- ---------------------------------------------------------------------------
create table if not exists public.course_day_scrapes (
  course_slug      text not null references public.courses(slug) on delete cascade,
  tee_date         date not null,
  last_attempt_at  timestamptz not null default now(),
  last_success_at  timestamptz,
  ok               boolean not null default false,
  slot_count       integer not null default 0 check (slot_count >= 0),
  error            text,
  primary key (course_slug, tee_date)
);

create table if not exists public.scrape_runs (
  id                 bigint generated always as identity primary key,
  started_at         timestamptz not null default now(),
  finished_at        timestamptz,
  mode               text not null check (mode in ('fast', 'full')),
  days_requested     smallint not null check (days_requested > 0),
  courses_attempted  smallint not null default 0,
  courses_ok         smallint not null default 0,
  courses_failed     smallint not null default 0,
  slots_upserted     integer not null default 0,
  slots_closed       integer not null default 0,
  contract_version   text not null,
  error              text
);

create index if not exists scrape_runs_started_idx on public.scrape_runs (started_at desc);
