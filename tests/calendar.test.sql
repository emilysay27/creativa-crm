-- Run after db.test.sql's setup (see run-db-tests.sh). Raises on failure.
\set ON_ERROR_STOP on
set client_min_messages = notice;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as 'begin
  if not coalesce(cond, false) then raise exception ''FAIL: %'', label; end if;
  raise notice ''ok - %'', label; end';

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'cal-admin@example.com', '{"full_name":"Cal Admin"}'),
  ('00000000-0000-0000-0000-0000000000c2', 'cal-staff@example.com', '{"full_name":"Cal Staff"}');
update public.profiles set role = 'admin', active = true where email = 'cal-admin@example.com';
update public.profiles set active = true where email = 'cal-staff@example.com';

-- The first weekday at least n days ahead when the school is open (tours can't be booked on a closed day).
create or replace function pg_temp.open_day(n int) returns timestamptz language sql as '
  select (d::date::text || '' 15:00+00'')::timestamptz from generate_series(current_date + n, current_date + n + 30, interval ''1 day'') d
   where extract(isodow from d) < 6 and not exists (select 1 from public.school_closures c where d::date between c.starts_on and c.ends_on)
   order by d limit 1';

insert into public.inquiries (parent_name, phone, email, child_name, child_dob, program, stage, tour_at, assigned_to) values
  ('Ana; Comma, Test', '305-555-0001', 'ana@example.com', 'Leo', '2023-05-01', 'Early 3s', 'tour_scheduled',
   pg_temp.open_day(2), '00000000-0000-0000-0000-0000000000c2'),
  ('Lost Family', '305-555-0002', null, null, null, null, 'lost', pg_temp.open_day(3), null),
  ('Old Tour', '305-555-0003', null, null, null, null, 'toured', now() - interval '90 days', null),
  ('No Tour', '305-555-0004', null, null, null, null, 'new', null, null);

\o /dev/null
select set_config('t.token', token, false) from public.calendar_feed;
select set_config('t.ics', public.tours_calendar(current_setting('t.token')), false);
\o

select pg_temp.ok(current_setting('t.ics') like 'BEGIN:VCALENDAR' || chr(13) || chr(10) || '%', 'starts with VCALENDAR + CRLF');
select pg_temp.ok(current_setting('t.ics') like '%END:VCALENDAR' || chr(13) || chr(10), 'ends with END:VCALENDAR + CRLF');
select pg_temp.ok((select count(*) from regexp_matches(current_setting('t.ics'), 'BEGIN:VEVENT', 'g'))
                 = (select count(*) from public.inquiries where tour_at > now() - interval '60 days' and stage <> 'lost'),
                 'one event per recent tour that is not lost');
select pg_temp.ok(position('SUMMARY:Tour: Ana' || chr(92) || '; Comma' || chr(92) || ', Test - Leo' || chr(92) || ', Early 3s' in current_setting('t.ics')) > 0, 'summary escapes ; and ,');
select pg_temp.ok(position('Phone: 305-555-0001' || chr(92) || 'n' in current_setting('t.ics')) > 0, 'description has phone, newlines escaped');
select pg_temp.ok(position('Assigned to: Cal Staff' in current_setting('t.ics')) > 0, 'description has assignee');
select pg_temp.ok(position('Lost Family' in current_setting('t.ics')) = 0 and position('No Tour' in current_setting('t.ics')) = 0 and position('Old Tour' in current_setting('t.ics')) = 0, 'lost, untoured and old tours excluded');
select pg_temp.ok(not exists (select 1 from regexp_split_to_table(current_setting('t.ics'), chr(13) || chr(10)) l where length(l) > 75), 'no line longer than 75 characters');

do 'begin
  perform public.tours_calendar(''wrong'');
  raise exception ''FAIL: wrong token accepted'';
exception when insufficient_privilege then null; end';

-- Who can see and reset the token
set role authenticated;
\o /dev/null
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false);
\o
select pg_temp.ok((select count(*) = 0 from public.calendar_feed), 'staff cannot read the token');
do 'begin perform public.rotate_calendar_token(); raise exception ''FAIL: staff reset the link'';
exception when others then if sqlerrm like ''FAIL:%'' then raise; end if; end';
\o /dev/null
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
\o
select pg_temp.ok((select count(*) = 1 from public.calendar_feed), 'admin can read the token');
\o /dev/null
select set_config('t.new', public.rotate_calendar_token(), false);
\o
reset role;
select pg_temp.ok(current_setting('t.new') <> current_setting('t.token') and length(current_setting('t.new')) = 48, 'admin reset gives a new token');
do 'begin
  perform public.tours_calendar(current_setting(''t.token''));
  raise exception ''FAIL: old token still works'';
exception when insufficient_privilege then null; end';
select pg_temp.ok(public.tours_calendar(current_setting('t.new')) like 'BEGIN:VCALENDAR%', 'new token works');
set role anon;
do 'begin perform count(*) from public.calendar_feed; raise exception ''FAIL: anon read token'';
exception when insufficient_privilege then null; end';
reset role;
select pg_temp.ok(convert_from(public.tours_ics(current_setting('t.new'))::bytea, 'UTF8') = public.tours_calendar(current_setting('t.new')),
                 'tours_ics returns the same calendar as bytes');
\echo ALL CALENDAR TESTS PASSED
