-- Tees for the Boys — exactly-once is per user, not per watch.
-- Track E, hotfix for the E1/E2 handoff.
--
-- alert_deliveries_exactly_once (0002_user_tables.sql) was
-- unique (watch_id, slot_id, slot_opened_at). That is one push per WATCH that
-- notices a listing, not one push per USER — so a user running two watches
-- that both cover the same tee time (an entirely ordinary pattern: a broad
-- watch plus a narrower "early bird" one) got queue_watch_matches() to insert
-- two independent rows for the identical slot. claim_alert_batch's "one watch
-- per user per run" only bounds a single call, so the second row just waited
-- out the ten-minute cooldown and went out as its own push a few minutes
-- later — two banners, on two different collapse-ids
-- (supabase/functions/_shared/notification.ts: `watch:<watch_id>`), for the
-- same club at the same time. Nothing downstream (the matcher, the claim
-- function, or the iOS payload decoder) collapses across watches.
--
-- The ledger has to promise exactly one push per (user, slot, listing) — a
-- user does not care how many of their own watches noticed it. Re-keying the
-- constraint on user_id instead of watch_id is enough: queue_watch_matches'
-- existing `on conflict on constraint alert_deliveries_exactly_once do
-- nothing` then collapses two watches matching the same slot down to a
-- single row within that very insert (Postgres applies ON CONFLICT DO
-- NOTHING against rows proposed earlier in the same command, not only
-- against rows already committed), exactly the way it already collapses
-- twelve repeated scrapes of one listing.
--
-- watch_id stays on the table (still the FK to public.watches, still what
-- the notification is attributed to and what claim_alert_batch groups slots
-- by) — only the uniqueness key changes. Which watch "wins" when two match
-- the same slot is arbitrary and does not matter: the point is that only one
-- of them ever gets to.
--
-- Safe to re-run: db_test.sh applies every migration twice, and this file
-- only acts when the constraint does not already have the new shape.
do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.alert_deliveries'::regclass
       and conname  = 'alert_deliveries_exactly_once'
       and pg_get_constraintdef(oid) = 'UNIQUE (user_id, slot_id, slot_opened_at)'
  ) then

    if exists (
      select 1 from pg_constraint
       where conrelid = 'public.alert_deliveries'::regclass
         and conname  = 'alert_deliveries_exactly_once'
    ) then
      -- Resolve whatever the old, too-narrow constraint already let in
      -- before the new, correct one can be added. A row sharing
      -- (user_id, slot_id, slot_opened_at) with another at this point is not
      -- a legitimate case to preserve — it IS the bug (the same user pushed
      -- twice about the identical listing). Keep one row per group: a row
      -- already sent outranks a merely queued one (the push already
      -- happened; do not manufacture a second one behind it), and among
      -- rows with the same status keep the oldest.
      with ranked as (
        select id,
               row_number() over (
                 partition by user_id, slot_id, slot_opened_at
                 order by (status = 'sent') desc, id
               ) as rn
          from public.alert_deliveries
      )
      delete from public.alert_deliveries d
       using ranked r
       where d.id = r.id
         and r.rn > 1;

      alter table public.alert_deliveries
        drop constraint alert_deliveries_exactly_once;
    end if;

    alter table public.alert_deliveries
      add constraint alert_deliveries_exactly_once
      unique (user_id, slot_id, slot_opened_at);
  end if;
end $$;

comment on constraint alert_deliveries_exactly_once on public.alert_deliveries is
  'Exactly one delivery per (user, slot, listing) — scoped to the user, not the watch, so two of a user''s own watches matching the same tee time still produce one push, not two. See alerts_0021_exactly_once_per_user.sql.';

-- watch_id is still a foreign key (public.watches), but it was only ever
-- indexed as a side effect of being the old constraint's leading column.
-- Re-keying the constraint on user_id dropped that index along with it —
-- supabase/local/01_assertions.sql fails the whole gate if any foreign key
-- column is not the leading column of some index, and this one is load-
-- bearing for that reason, not an optimisation.
create index if not exists alert_deliveries_watch_idx on public.alert_deliveries (watch_id);
