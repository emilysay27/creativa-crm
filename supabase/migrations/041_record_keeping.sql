-- Creativa CRM — records are kept 5 years (child care records law): the database refuses to delete them before then.
-- Run once in the Supabase SQL editor, after 040_accountant_books.sql. Safe to run again.
--
-- Kept for 5 years (counted from the date in brackets):
--   children (from the day they left; never while enrolled or waiting), payments (paid), staff (their last day on the time
--   clock; someone who never worked or was paid can go), time clock entries (the day), paychecks (pay date), money in
--   and out (the date), food program claims (the month), online registrations and next year's registrations (sent),
--   texts sent to families (sent), activity rosters where something was decided (going or not, a permission slip, a
--   note, added by hand), and the Changes log (the change).
-- Still possible:
--   - fixing a mistake within 30 days of adding it (the Changes log keeps a copy of what was deleted);
--   - deleting anything older than 5 years;
--   - removing a pick-up person, a contact or a medicine (normal; the Changes log keeps a dated copy), reopening a pay
--     period, rebuilding a roster's untouched rows, deleting spam in the Pipeline;
--   - a real mistake older than 30 days: only from the SQL editor, on purpose, in one transaction:
--       begin; select set_config('crm.records_override', 'yes', true); delete …; commit;
--
-- No dollar-quoting or backslashes in this file, so it survives copy-paste intact.

create or replace function public.keep_records()
returns trigger language plpgsql security definer set search_path = public as '
declare
  r     jsonb := to_jsonb(old);
  added timestamptz := (r ->> ''created_at'')::timestamptz;
  since date;      -- the day the 5 years start; null = kept (still in use)
begin
  if coalesce(current_setting(''crm.records_override'', true), '''') = ''yes'' then return old; end if;
  if added is not null and added > now() - interval ''30 days'' then return old; end if;   -- a mistake fixed soon after
  if tg_table_name = ''students'' then
    since := case when r ->> ''status'' in (''withdrawn'', ''graduated'') then coalesce((r ->> ''withdrawn_on'')::date, (r ->> ''updated_at'')::date) end;
  elsif tg_table_name = ''employees'' then
    if not exists (select 1 from public.time_entries t where t.employee_id = (r ->> ''id'')::uuid)
       and (to_regclass(''public.paychecks'') is null
            or not exists (select 1 from public.paychecks p where p.employee_id = (r ->> ''id'')::uuid)) then
      return old;   -- never worked or was paid: nothing to keep
    end if;
    since := case when not coalesce((r ->> ''active'')::boolean, true)
                  then (select max(t.work_date) from public.time_entries t where t.employee_id = (r ->> ''id'')::uuid) end;
  elsif tg_table_name = ''activity_roster'' then
    if r ->> ''participation'' = ''undecided'' and r ->> ''permission'' in (''pending'', ''not_required'') and r ->> ''note'' is null
       and not coalesce((r ->> ''by_hand'')::boolean, false) and not coalesce((r ->> ''removed'')::boolean, false) then
      return old;   -- an untouched row (rebuilding a roster tidies these up)
    end if;
    since := (select e.starts_on from public.school_events e where e.id = (r ->> ''event_id'')::uuid);
  else
    since := left(r ->> tg_argv[0], 10)::date;
  end if;
  if since is not null and since < current_date - interval ''5 years'' then return old; end if;
  raise exception ''Kept for 5 years (child care records), so this can''''t be deleted. Mark it withdrawn, inactive or void instead.''
    using errcode = ''P0001'', hint = ''A real mistake can be removed by the owner from the SQL editor.'';
end';
revoke execute on function public.keep_records() from public, anon, authenticated;

do '
declare
  t record;
begin
  for t in select * from (values (''students'', ''withdrawn_on''), (''payments'', ''paid_on''), (''employees'', ''created_at''),
                                 (''time_entries'', ''work_date''), (''paychecks'', ''pay_date''), (''money_entries'', ''on_date''),
                                 (''ccfp_claims'', ''claim_month''), (''registration_forms'', ''created_at''), (''registrations'', ''created_at''),
                                 (''messages'', ''created_at''), (''message_recipients'', ''sent_at''), (''activity_roster'', ''created_at''),
                                 (''change_log'', ''at'')) as x(tbl, col) loop
    if to_regclass(''public.'' || t.tbl) is not null then
      execute format(''drop trigger if exists keep_records on public.%I'', t.tbl);
      execute format(''create trigger keep_records before delete on public.%I for each row execute function public.keep_records(%L)'', t.tbl, t.col);
    end if;
  end loop;
end';
