-- Schema assertions. Every one of these is a property the frozen contract
-- claims. If one fails the migration is wrong, not the test.
--
-- Run by scripts/db_test.sh against a throwaway local database.

\set ON_ERROR_STOP on

create or replace function private.assert(ok boolean, what text)
returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'ASSERTION FAILED: %', what;
  end if;
  raise notice '   ok  %', what;
end $$;

-- ---------------------------------------------------------------- roster
select private.assert(count(*) = 15, 'roster is frozen at 15 courses') from public.courses;
select private.assert(count(*) = 15, 'every course has a distinct sort_order')
  from (select distinct sort_order from public.courses) s;
select private.assert(count(*) = 1, 'exactly one course needs a free registration first')
  from public.courses where requires_registration;
select private.assert(count(*) = 0, 'no course has an invented length_metres')
  from public.courses where length_metres is not null;
select private.assert(count(*) = 15, 'every course has par and holes')
  from public.courses where par is not null and holes is not null;

-- ------------------------------------------------------------------- RLS
do $$
declare t text;
begin
  foreach t in array array['courses','slots','course_day_scrapes','scrape_runs',
                           'watches','alert_deliveries','push_tokens','bookings']
  loop
    perform private.assert(
      (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass),
      'RLS is enabled on public.' || t);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['watches','push_tokens','bookings']
  loop
    perform private.assert(
      (select count(*) from pg_policies where schemaname = 'public' and tablename = t) = 4,
      'public.' || t || ' has select/insert/update/delete owner policies');
  end loop;
end $$;

select private.assert(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'alert_deliveries') = 1,
  'alert_deliveries is read-only to clients (one select policy, no write policy)');

-- ----------------------------------------------------- foreign keys indexed
do $$
declare missing text;
begin
  select string_agg(format('%s.%s', conrelid::regclass, a.attname), ', ')
    into missing
  from pg_constraint c
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
  where c.contype = 'f'
    and connamespace = 'public'::regnamespace
    and not exists (
      select 1 from pg_index i
      where i.indrelid = c.conrelid and i.indkey[0] = a.attnum
    );
  perform private.assert(missing is null, 'every foreign key column is indexed' ||
    coalesce(' (missing: ' || missing || ')', ''));
end $$;

-- ------------------------------------------------------------- test fixture
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'will@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'someone.else@example.com')
on conflict do nothing;

insert into public.slots
  (id, course_slug, tee_date, tee_time, tee_at, spots_available, total_spots,
   holes, price_min, price_max, price_tiers, booking_type, booking_url)
values
  ('the-coast:2099-01-03:0800:public-play', 'the-coast', '2099-01-03', '08:00',
   '2099-01-02T21:00:00Z', 4, 4, 18, 55.00, 55.00,
   '[{"label":"Public","amount":55.0}]'::jsonb, 'Public Play', 'https://example.test/book'),
  ('the-coast:2099-01-03:0808:public-play', 'the-coast', '2099-01-03', '08:08',
   '2099-01-02T21:08:00Z', 2, 4, 18, 55.00, 55.00,
   '[{"label":"Public","amount":55.0}]'::jsonb, 'Public Play', 'https://example.test/book'),
  ('the-coast:2020-01-03:0800:public-play', 'the-coast', '2020-01-03', '08:00',
   '2020-01-02T21:00:00Z', 4, 4, 18, 45.00, 45.00,
   '[]'::jsonb, 'Public Play', 'https://example.test/book')
on conflict (id) do nothing;

-- A two-tee start: the same minute, a different tee, a separate booking. This
-- is Warringah's and Bexley's normal Saturday, not a contrived case.
insert into public.slots
  (id, course_slug, tee_date, tee_time, tee_at, spots_available, total_spots,
   holes, price_min, price_max, price_tiers, booking_type, booking_url)
values
  ('the-coast:2099-01-03:0800:10th-tee-social', 'the-coast', '2099-01-03', '08:00',
   '2099-01-02T21:00:00Z', 3, 4, 18, 55.00, 55.00,
   '[{"label":"Public","amount":55.0}]'::jsonb, '10th Tee Social', 'https://example.test/book')
on conflict (id) do nothing;

select private.assert(count(*) = 2, 'a two-tee start stores both groups at the same minute')
  from public.slots where course_slug = 'the-coast' and tee_date = '2099-01-03' and tee_time = '08:00';

update public.slots set status = 'gone', gone_at = now()
 where id = 'the-coast:2099-01-03:0808:public-play';

insert into public.watches (id, user_id, label, course_slugs, time_from, time_to, min_players, holes)
values ('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111',
        'Saturday 8am at The Coast', array['the-coast'], '07:00', '09:00', 2, 18)
on conflict (id) do nothing;

-- -------------------------------------------------------------- open_slots
select private.assert(count(*) = 2, 'open_slots hides past slots and gone slots')
  from public.open_slots;
select private.assert(
  count(*) = 2, 'open_slots carries par and holes on the row')
  from public.open_slots where par = 71 and holes = 18;

-- ------------------------------------------------------- exactly-once push
insert into public.alert_deliveries (watch_id, user_id, slot_id, slot_opened_at)
select '33333333-3333-3333-3333-333333333333',
       '11111111-1111-1111-1111-111111111111',
       id, opened_at
  from public.slots where id = 'the-coast:2099-01-03:0800:public-play';

do $$
declare opened timestamptz;
begin
  select opened_at into opened from public.slots where id = 'the-coast:2099-01-03:0800:public-play';
  -- The same watch seeing the same listing on the next scrape must not queue a
  -- second push. Twelve scrapes, one notification.
  begin
    insert into public.alert_deliveries (watch_id, user_id, slot_id, slot_opened_at)
    values ('33333333-3333-3333-3333-333333333333',
            '11111111-1111-1111-1111-111111111111',
            'the-coast:2099-01-03:0800:public-play', opened);
    raise exception 'ASSERTION FAILED: a duplicate (watch, slot, listing) delivery was accepted';
  exception when unique_violation then
    raise notice '   ok  a repeat scrape cannot queue a second push for the same listing';
  end;
end $$;

select private.assert(count(*) = 1, 'exactly one delivery row survives the duplicate attempt')
  from public.alert_deliveries
  where watch_id = '33333333-3333-3333-3333-333333333333';

-- ------------------------------------------ a cancellation alerts again
-- The case the app exists for. Somebody books the 8am, then cancels it. The
-- club relists the same tee time and the watch must fire a second time — but
-- only once for that new listing.
do $$
declare opened_before timestamptz; opened_after timestamptz; reopens smallint;
begin
  select opened_at into opened_before from public.slots where id = 'the-coast:2099-01-03:0800:public-play';

  -- booked: a successful scrape stops listing it. The scraper says only this.
  update public.slots set status = 'gone' where id = 'the-coast:2099-01-03:0800:public-play';
  perform private.assert(
    (select gone_at is not null from public.slots where id = 'the-coast:2099-01-03:0800:public-play'),
    'going gone stamps gone_at without the writer having to remember');

  -- cancelled: the club relists it. The scraper says only this.
  update public.slots set status = 'open', spots_available = 1
   where id = 'the-coast:2099-01-03:0800:public-play';

  select opened_at, reopen_count into opened_after, reopens
    from public.slots where id = 'the-coast:2099-01-03:0800:public-play';

  perform private.assert(opened_after > opened_before,
    'a relisted tee time starts a new listing');
  perform private.assert(reopens = 1, 'the reopen is counted');
  perform private.assert(
    (select gone_at is null from public.slots where id = 'the-coast:2099-01-03:0800:public-play'),
    'reopening clears gone_at instead of tripping a constraint');
  perform private.assert(
    (select count(*) = 1 from public.open_slots where id = 'the-coast:2099-01-03:0800:public-play'),
    'a relisted tee time is bookable again');

  -- ...and the watch may alert on the new listing.
  insert into public.alert_deliveries (watch_id, user_id, slot_id, slot_opened_at)
  values ('33333333-3333-3333-3333-333333333333',
          '11111111-1111-1111-1111-111111111111',
          'the-coast:2099-01-03:0800:public-play', opened_after);
  raise notice '   ok  a cancelled-and-relisted tee time alerts a second time';

  -- ...but only once for that listing.
  begin
    insert into public.alert_deliveries (watch_id, user_id, slot_id, slot_opened_at)
    values ('33333333-3333-3333-3333-333333333333',
            '11111111-1111-1111-1111-111111111111',
            'the-coast:2099-01-03:0800:public-play', opened_after);
    raise exception 'ASSERTION FAILED: the relisted tee time alerted twice';
  exception when unique_violation then
    raise notice '   ok  the relisted tee time alerts once, not once per scrape';
  end;
end $$;

-- ------------------------------------- two people, one phone, both get alerts
do $$
begin
  insert into public.push_tokens (user_id, token)
  values ('11111111-1111-1111-1111-111111111111', 'device-token-abc');
  -- Two mates sharing an iPhone is ordinary for this app. The second one to
  -- sign in must still be able to register.
  insert into public.push_tokens (user_id, token)
  values ('22222222-2222-2222-2222-222222222222', 'device-token-abc');
  raise notice '   ok  two users on one device can both register for push';
end $$;

select private.assert(count(*) = 2, 'one device token, one row per user')
  from public.push_tokens where token = 'device-token-abc';

-- --------------------------------------- clients hold SELECT and nothing else
do $$
declare extra text;
begin
  select string_agg(format('%s:%s:%s', table_name, grantee, privilege_type), ', ')
    into extra
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon', 'authenticated')
    and privilege_type <> 'SELECT'
    and table_name in ('courses', 'slots', 'course_day_scrapes', 'scrape_runs',
                       'alert_deliveries', 'open_slots', 'course_freshness');
  -- TRUNCATE is never checked against RLS, so a leftover grant would let any
  -- signed-in client empty a table in one statement whatever the policies say.
  perform private.assert(extra is null,
    'read-only tables and views grant clients SELECT only' ||
    coalesce(' (also held: ' || extra || ')', ''));
end $$;

-- ------------------------------------------------- constraints actually bite
do $$
begin
  begin
    insert into public.slots (id, course_slug, tee_date, tee_time, tee_at,
      spots_available, total_spots, holes, booking_url)
    values ('the-coast:2099-01-04:0800:public-play', 'the-coast', '2099-01-04', '08:00',
            '2099-01-03T21:00:00Z', 9, 4, 18, 'https://example.test/book');
    raise exception 'ASSERTION FAILED: spots_available > total_spots was accepted';
  exception when check_violation then
    raise notice '   ok  a slot cannot claim more free spots than it has';
  end;

  begin
    insert into public.slots (id, course_slug, tee_date, tee_time, tee_at,
      spots_available, total_spots, holes, booking_type, booking_url)
    values ('dupe', 'the-coast', '2099-01-03', '08:00',
            '2099-01-02T21:00:00Z', 4, 4, 18, 'Public Play', 'https://example.test/book');
    raise exception 'ASSERTION FAILED: a second row for the same course/date/time/tee was accepted';
  exception when unique_violation then
    raise notice '   ok  one row per course, date, time and tee';
  end;


  begin
    insert into public.watches (user_id, time_from, time_to)
    values ('11111111-1111-1111-1111-111111111111', '18:00', '06:00');
    raise exception 'ASSERTION FAILED: a watch with time_from after time_to was accepted';
  exception when check_violation then
    raise notice '   ok  a watch cannot end before it starts';
  end;

  begin
    insert into public.watches (user_id, weekdays)
    values ('11111111-1111-1111-1111-111111111111', array[0,8]::smallint[]);
    raise exception 'ASSERTION FAILED: weekdays outside 1-7 were accepted';
  exception when check_violation then
    raise notice '   ok  weekdays are ISO 1-7';
  end;
end $$;

-- ------------------------------------------ RLS actually isolates two users
-- private.assert is not callable as anon/authenticated on purpose, so the
-- counts are read under the impersonated role and asserted after reset role.
begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
  select count(*) as other_watches from public.watches \gset
  select count(*) as other_slots   from public.open_slots \gset
  reset role;
  select private.assert(:other_watches = 0, 'a signed-in user cannot read another user''s watches');
  select private.assert(:other_slots  = 2, 'a signed-in user can still browse open slots');
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  select count(*) as own_watches from public.watches \gset
  reset role;
  select private.assert(:own_watches = 1, 'a signed-in user reads their own watches');
rollback;

begin;
  set local role anon;
  select count(*) as anon_slots from public.open_slots \gset
  reset role;
  select private.assert(:anon_slots = 2, 'a signed-out visitor can browse open slots');
rollback;

begin;
  set local role anon;
  do $$
  declare n integer;
  begin
    select count(*) into n from public.watches;
    raise exception 'ASSERTION FAILED: an anonymous client read the watches table';
  exception when insufficient_privilege then
    raise notice '   ok  a signed-out visitor cannot read the watches table at all';
  end $$;
rollback;

begin;
  set local role anon;
  do $$
  begin
    insert into public.slots (id, course_slug, tee_date, tee_time, tee_at,
      spots_available, total_spots, holes, booking_url)
    values ('anon-write', 'the-coast', '2099-02-01', '08:00',
            '2099-01-31T21:00:00Z', 4, 4, 18, 'https://example.test/book');
    raise exception 'ASSERTION FAILED: an anonymous client wrote to public.slots';
  exception when insufficient_privilege then
    raise notice '   ok  an anonymous client cannot write tee times';
  end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  do $$
  begin
    insert into public.watches (user_id, label)
    values ('22222222-2222-2222-2222-222222222222', 'a watch on someone else''s account');
    raise exception 'ASSERTION FAILED: a user created a watch owned by someone else';
  exception when insufficient_privilege then
    raise notice '   ok  a user cannot create a watch owned by someone else';
  end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  do $$
  begin
    update public.alert_deliveries set status = 'sent';
    raise exception 'ASSERTION FAILED: a user rewrote their own alert history';
  exception when insufficient_privilege then
    raise notice '   ok  a user cannot rewrite their own alert history';
  end $$;
rollback;

-- ------------------------------------------------------------- freshness
select private.assert(count(*) = 15, 'course_freshness reports every active course')
  from public.course_freshness;
