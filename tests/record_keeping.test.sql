-- Migration 041: records are kept 5 years. Deleting works for a mistake in the first 30 days, for records older than
-- 5 years, and on purpose from the SQL editor; otherwise the database refuses.
\set ON_ERROR_STOP on
set client_min_messages = notice;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as 'begin
  if not coalesce(cond, false) then raise exception ''FAIL: %'', label; end if;
  raise notice ''ok - %'', label; end';
-- true when the delete was refused with the 5-year message
create or replace function pg_temp.kept(sql text) returns boolean language plpgsql as 'begin
  execute sql; return false;
exception when raise_exception then
  if sqlerrm like ''Kept for 5 years%'' then return true; end if; raise;
end';
\ir ../supabase/migrations/041_record_keeping.sql
\ir ../supabase/migrations/041_record_keeping.sql

insert into public.students (name, status, created_at) values ('Keep Kid Now', 'enrolled', now() - interval '2 months');
insert into public.students (name, status, created_at) values ('Keep Kid Mistake', 'enrolled', now() - interval '2 days');
insert into public.students (name, status, withdrawn_on, created_at) values ('Keep Kid Left Long Ago', 'withdrawn', current_date - interval '6 years', now() - interval '8 years');
insert into public.students (name, status, withdrawn_on, created_at) values ('Keep Kid Left Last Year', 'withdrawn', current_date - interval '1 year', now() - interval '3 years');
select pg_temp.ok(pg_temp.kept('delete from public.students where name = ''Keep Kid Now'''), 'a child at school can''t be deleted');
select pg_temp.ok(pg_temp.kept('delete from public.students where name = ''Keep Kid Left Last Year'''), 'nor one who left a year ago');
delete from public.students where name in ('Keep Kid Mistake', 'Keep Kid Left Long Ago');
select pg_temp.ok((select count(*) = 0 from public.students where name in ('Keep Kid Mistake', 'Keep Kid Left Long Ago')),
  'a mistake from this week, and a child who left 6 years ago, can');

insert into public.money_entries (on_date, kind, category, amount, created_at) values
  (current_date - 400, 'out', 'Keep test', 10, now() - interval '400 days'), (current_date - 2300, 'out', 'Keep test', 11, now() - interval '2300 days');
select pg_temp.ok(pg_temp.kept('delete from public.money_entries where category = ''Keep test'' and amount = 10'), 'money from last year is kept');
delete from public.money_entries where category = 'Keep test' and amount = 11;
select pg_temp.ok((select count(*) = 1 from public.money_entries where category = 'Keep test'), 'money from over 5 years ago can go');

-- Rosters: untouched rows can be tidied up (rebuilding a roster); a decision or a slip is kept.
insert into public.school_events (kind, title, starts_on, needs_permission) values ('event', 'Keep Trip', current_date - 90, true);
insert into public.activity_roster (event_id, student_id, permission, created_at)
select e.id, s.id, 'pending', now() - interval '90 days' from public.school_events e, public.students s where e.title = 'Keep Trip' and s.name = 'Keep Kid Now';
insert into public.students (name, status, created_at) values ('Keep Kid Slip', 'enrolled', now() - interval '2 months');
insert into public.activity_roster (event_id, student_id, permission, permission_on, participation, created_at)
select e.id, s.id, 'received', current_date - 85, 'going', now() - interval '90 days' from public.school_events e, public.students s where e.title = 'Keep Trip' and s.name = 'Keep Kid Slip';
delete from public.activity_roster r using public.students s where s.id = r.student_id and s.name = 'Keep Kid Now';
select pg_temp.ok((select count(*) = 1 from public.activity_roster r join public.school_events e on e.id = r.event_id where e.title = 'Keep Trip'), 'an untouched roster row can go');
select pg_temp.ok(pg_temp.kept('delete from public.activity_roster r using public.students s where s.id = r.student_id and s.name = ''Keep Kid Slip'''),
  'a permission slip received is kept');
select pg_temp.ok(pg_temp.kept('delete from public.school_events where title = ''Keep Trip'''), 'so is the activity it belongs to');

-- The Changes log is kept too.
insert into public.change_log (at, area, table_name, row_id, action, data) values (now() - interval '1 year', 'enrollment', 'students', 'x', 'update', '{}');
select pg_temp.ok(pg_temp.kept('delete from public.change_log where row_id = ''x'''), 'the Changes log is kept');

-- On purpose, from the SQL editor: allowed.
begin;
select set_config('crm.records_override', 'yes', true);
delete from public.change_log where row_id = 'x';
delete from public.activity_roster r using public.school_events e where e.id = r.event_id and e.title = 'Keep Trip';
delete from public.school_events where title = 'Keep Trip';
delete from public.students where name like 'Keep Kid%';
delete from public.money_entries where category = 'Keep test';
commit;
select pg_temp.ok((select count(*) = 0 from public.students where name like 'Keep Kid%') and current_setting('crm.records_override', true) is distinct from 'yes',
  'the owner can remove a real mistake on purpose (only inside that one transaction)');
\echo ALL RECORD KEEPING TESTS PASSED
