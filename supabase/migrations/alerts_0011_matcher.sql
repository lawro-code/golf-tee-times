-- Tees for the Boys — the matcher.
-- Track E, ticket E1. Runs after alerts_0010_watch_lifecycle.sql.
--
-- One statement turns "these watches exist" and "these tee times are open"
-- into rows on the exactly-once ledger. It sends nothing; E2 drains the queue.

-- Partial index on live watches, kept for per-user reads (the app listing a
-- user's running alerts, and the satisfaction trigger's lookup by user_id in
-- alerts_0010). It does NOT support the matcher below: that scan neither
-- filters nor joins on watches.user_id, so the planner cannot use this index
-- for it. It also overlaps watches_user_idx (user_id) from 0002 — the `where
-- active` clause is the only thing it adds. Do not cite it as a matcher
-- optimisation when profiling.
create index if not exists watches_active_user_idx
  on public.watches (user_id) where active;

-- ---------------------------------------------------------------------------
-- public.queue_watch_matches()
--
-- THE LEDGER IS THE DIFF. There is no watermark column, no p_since parameter,
-- and no record of which scrape was last processed, because
-- alert_deliveries_exactly_once unique (watch_id, slot_id, slot_opened_at)
-- already knows everything a watermark would have tracked, and it knows it
-- transactionally.
--
--   Twelve scrapes of one unchanged listing  -> one insert, eleven conflicts.
--   A replay of an identical scrape          -> zero inserts.
--   Booked, cancelled, relisted              -> a new opened_at from the
--                                               slots_lifecycle trigger, so a
--                                               second insert, then conflicts.
--
-- A duplicate key here means the system is working. Never delete an
-- alert_deliveries row to "retry" one — that is how a user gets the same push
-- twice, and it is what the Stage 3 red team will go looking for.
--
-- Cost: this is a nested loop over live watches x open future slots. The
-- roster is frozen at 15 courses and a full scrape is ~1755 slots, so the
-- right-hand side is small and bounded; there is nothing to optimise yet and
-- premature indexing would only hide the shape of it.
-- ---------------------------------------------------------------------------
create or replace function public.queue_watch_matches()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  queued integer;
begin
  insert into public.alert_deliveries (watch_id, user_id, slot_id, slot_opened_at)
  select w.id, w.user_id, s.id, s.opened_at
    from public.watches w
    join public.slots   s on s.status = 'open' and s.tee_at > now()
    join public.courses c on c.slug = s.course_slug and c.active
   where private.watch_is_live(w)
     -- A new watch does NOT fire for tee times that were already listed when
     -- it was created. The app's own search has just shown the user those; the
     -- watch is for what appears NEXT. Without this line, saving a watch that
     -- matches thirty open slots buries the user the moment they tap the
     -- button, and they turn notifications off for good.
     --
     -- A booked-then-relisted slot gets a brand-new opened_at from the
     -- slots_lifecycle trigger, so an older watch still fires for the
     -- cancellation. That is CONTRACT.md section 6 and it has to keep working.
     and s.opened_at >= w.created_at
     and private.watch_matches(w, s.course_slug, s.tee_date, s.tee_time, s.holes,
                               s.price_min, s.spots_available, c.drive_minutes_from_bondi)
  on conflict on constraint alert_deliveries_exactly_once do nothing;

  get diagnostics queued = row_count;
  return queued;
end $$;

comment on function public.queue_watch_matches() is
  'Queues one alert_deliveries row per (watch, slot, listing) that is new. Idempotent by construction: re-running over an unchanged scrape queues nothing. Returns the number of rows actually queued.';

-- A writer, called by the service role only. Supabase's default privileges
-- grant EXECUTE on new public functions to anon and authenticated, and
-- Postgres grants it to PUBLIC; a client that could call this could fan out
-- push notifications at will.
revoke all on function public.queue_watch_matches() from public, anon, authenticated;
grant execute on function public.queue_watch_matches() to service_role;
