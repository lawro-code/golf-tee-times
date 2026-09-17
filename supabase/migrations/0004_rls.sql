-- Tees for the Boys — row level security.
--
-- Shape of the rules:
--   Reference and scraped data  -> world readable, service_role writes.
--   Anything owned by a user    -> that user only, enforced in the database.
--
-- Browsing works signed out on purpose. The wall is in front of alerts, not
-- in front of search.

-- --------------------------------------------------------------- public data
alter table public.courses            enable row level security;
alter table public.slots              enable row level security;
alter table public.course_day_scrapes enable row level security;
alter table public.scrape_runs        enable row level security;

drop policy if exists courses_public_read on public.courses;
create policy courses_public_read on public.courses
  for select to anon, authenticated using (true);

drop policy if exists slots_public_read on public.slots;
create policy slots_public_read on public.slots
  for select to anon, authenticated using (true);

drop policy if exists course_day_scrapes_public_read on public.course_day_scrapes;
create policy course_day_scrapes_public_read on public.course_day_scrapes
  for select to anon, authenticated using (true);

drop policy if exists scrape_runs_public_read on public.scrape_runs;
create policy scrape_runs_public_read on public.scrape_runs
  for select to anon, authenticated using (true);

-- No policy grants write on these, so no client can write them regardless of
-- table grants. The scraper writes with the service role, which bypasses RLS.
revoke insert, update, delete on public.courses            from anon, authenticated;
revoke insert, update, delete on public.slots              from anon, authenticated;
revoke insert, update, delete on public.course_day_scrapes from anon, authenticated;
revoke insert, update, delete on public.scrape_runs        from anon, authenticated;

-- ----------------------------------------------------------------- user data
alter table public.watches           enable row level security;
alter table public.alert_deliveries  enable row level security;
alter table public.push_tokens       enable row level security;
alter table public.bookings          enable row level security;

-- auth.uid() is wrapped in a select so it is evaluated once per statement
-- rather than once per row.
drop policy if exists watches_owner_select on public.watches;
create policy watches_owner_select on public.watches
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists watches_owner_insert on public.watches;
create policy watches_owner_insert on public.watches
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists watches_owner_update on public.watches;
create policy watches_owner_update on public.watches
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists watches_owner_delete on public.watches;
create policy watches_owner_delete on public.watches
  for delete to authenticated using (user_id = (select auth.uid()));

-- Deliveries are written by the matcher (service role). A user may read their
-- own history and nothing else.
drop policy if exists alert_deliveries_owner_select on public.alert_deliveries;
create policy alert_deliveries_owner_select on public.alert_deliveries
  for select to authenticated using (user_id = (select auth.uid()));

revoke insert, update, delete on public.alert_deliveries from anon, authenticated;

drop policy if exists push_tokens_owner_select on public.push_tokens;
create policy push_tokens_owner_select on public.push_tokens
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists push_tokens_owner_insert on public.push_tokens;
create policy push_tokens_owner_insert on public.push_tokens
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists push_tokens_owner_update on public.push_tokens;
create policy push_tokens_owner_update on public.push_tokens
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists push_tokens_owner_delete on public.push_tokens;
create policy push_tokens_owner_delete on public.push_tokens
  for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists bookings_owner_select on public.bookings;
create policy bookings_owner_select on public.bookings
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists bookings_owner_insert on public.bookings;
create policy bookings_owner_insert on public.bookings
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists bookings_owner_update on public.bookings;
create policy bookings_owner_update on public.bookings
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists bookings_owner_delete on public.bookings;
create policy bookings_owner_delete on public.bookings
  for delete to authenticated using (user_id = (select auth.uid()));

-- anon can browse and nothing else.
revoke all on public.watches          from anon;
revoke all on public.alert_deliveries from anon;
revoke all on public.push_tokens      from anon;
revoke all on public.bookings         from anon;
