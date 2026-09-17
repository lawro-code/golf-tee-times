-- Tees for the Boys — the app-facing read surface.
-- The iOS app and the website read these views, never the base tables.

-- open_slots: one row per bookable tee time, already joined to its course so a
-- list row (course, time, price, players, par, holes) is a single query.
create or replace view public.open_slots
with (security_invoker = true) as
select
  s.id,
  s.course_slug,
  c.name                        as course_name,
  c.region,
  c.drive_minutes_from_bondi,
  c.par,
  c.length_metres,
  c.requires_registration,
  s.tee_date,
  s.tee_time,
  s.tee_at,
  s.spots_available,
  s.total_spots,
  s.holes,
  s.price_min,
  s.price_max,
  s.price_tiers,
  s.booking_type,
  s.booking_url,
  s.first_seen_at,
  s.last_seen_at
from public.slots s
join public.courses c on c.slug = s.course_slug
where s.status = 'open'
  and c.active
  and s.tee_at > now();

comment on view public.open_slots is
  'Bookable tee times, future only. Past slots and slots a successful scrape stopped listing are excluded.';

-- course_freshness: how current each course''s data is. The app needs this to
-- tell "no tee times" apart from "we have not looked in six hours".
create or replace view public.course_freshness
with (security_invoker = true) as
select
  c.slug                                as course_slug,
  c.name                                as course_name,
  max(d.last_success_at)                as last_success_at,
  max(d.last_attempt_at)                as last_attempt_at,
  bool_and(coalesce(d.ok, false))       as all_days_ok,
  count(*) filter (where not coalesce(d.ok, false)) as failing_days,
  sum(coalesce(d.slot_count, 0))::integer           as slot_count
from public.courses c
left join public.course_day_scrapes d
  on d.course_slug = c.slug and d.tee_date >= (now() at time zone 'Australia/Sydney')::date
where c.active
group by c.slug, c.name;

comment on view public.course_freshness is
  'Per-course scrape health for the days still in the future. Drives the stale-data banner.';
