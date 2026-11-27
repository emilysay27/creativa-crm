-- Migration 042: every text to the school's number is saved and matched to whoever has that number in the CRM.
-- Runs after messages.test.sql (users from db.test.sql: owner = admin, teacher = staff, books = finance edit).
\set ON_ERROR_STOP on
set client_min_messages = notice;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as 'begin
  if not coalesce(cond, false) then raise exception ''FAIL: %'', label; end if;
  raise notice ''ok - %'', label; end';
create or replace function pg_temp.as_user(uid uuid) returns void language plpgsql as 'begin
  perform set_config(''request.jwt.claim.sub'', coalesce(uid::text, ''''), false); end';
\ir ../supabase/migrations/042_text_replies.sql
\ir ../supabase/migrations/042_text_replies.sql
select pg_temp.as_user(null);
update public.profiles set finance = 'edit' where email = 'books@creativaacademy.com';   -- can send (and see) texts

-- Two brothers with the same mother (her cell on both pages), a child known only by the parent phone, a Pipeline family.
insert into public.students (name, status) values ('Rp Older', 'enrolled'), ('Rp Younger', 'enrolled'), ('Rp Parent Phone', 'withdrawn');
insert into public.student_contacts (student_id, role, relationship, first_name, last_name, cell_phone, work_phone)
  select id, 'primary', 'Mother', 'Rp', 'Mom', '(305) 555-0701', '305.555.0709' from public.students where name in ('Rp Older', 'Rp Younger');
insert into public.student_contacts (student_id, role, relationship, first_name, last_name, sms_phone)
  select id, 'emergency', 'Grandmother', 'Rp', 'Grandma', '1 305 555 0702' from public.students where name = 'Rp Older';
update public.students set parent_name = 'Rp Dad', parent_phone = '305-555-0703' where name = 'Rp Parent Phone';
insert into public.inquiries (parent_name, phone, stage) values ('Rp Pipeline', '305 555 0704', 'new');

-- The mother: saved once, on both brothers, named as on their pages.
create temp table r1 as select * from public.text_inbound('+13055550701', 'Running late today');
select pg_temp.ok((select inquiry_id is null and action = 'message' and parent_name = 'Rp Mom (Mother) · Rp Older, Rp Younger' from r1),
  'a parent on two children''s pages is named, with both children, for the Telegram notice');
select pg_temp.ok((select count(*) = 1 from public.text_replies where from_phone = '+13055550701'), 'the text is saved once');
select pg_temp.ok((select cardinality(student_ids) = 2 and body = 'Running late today' and who like 'Rp Mom (Mother)%'
                     from public.text_replies where from_phone = '+13055550701'), 'on both brothers');
select pg_temp.ok((select student_ids @> array[(select id from public.students where name = 'Rp Older')]
                     from public.text_replies where from_phone = '+13055550701'), 'found from the child''s page');
-- Her work phone, the grandmother's texting phone, the parent phone on a withdrawn child.
select pg_temp.ok((select parent_name like 'Rp Mom (Mother)%' from public.text_inbound('+13055550709', 'From work')), 'any of a contact''s phones');
select pg_temp.ok((select parent_name = 'Rp Grandma (Grandmother) · Rp Older' from public.text_inbound('+13055550702', 'Hi')), 'an emergency contact');
select pg_temp.ok((select parent_name = 'Rp Dad · Rp Parent Phone' from public.text_inbound('+13055550703', 'Hello')), 'the parent phone on the child');

-- Pipeline: as before (named alone, on the card's timeline), and saved too.
select pg_temp.ok((select parent_name = 'Rp Pipeline' and inquiry_id is not null from public.text_inbound('+13055550704', 'Is Friday ok?')),
  'a Pipeline family: named as before');
select pg_temp.ok((select count(*) = 1 from public.activities a join public.inquiries i on i.id = a.inquiry_id
                    where i.parent_name = 'Rp Pipeline' and a.body = 'Text from family: Is Friday ok?'), 'still on the card''s timeline');
select pg_temp.ok((select who = 'Rp Pipeline (Pipeline)' and cardinality(student_ids) = 0 from public.text_replies where from_phone = '+13055550704'),
  'and saved with the card');

-- A number nobody has: saved, unnamed. STOP: saved and opted out, as before.
select pg_temp.ok((select inquiry_id is null and parent_name is null from public.text_inbound('+13055550799', 'Who is this?')), 'unknown number: no name');
select pg_temp.ok((select who is null and body = 'Who is this?' from public.text_replies where from_phone = '+13055550799'), 'but the text is kept');
select pg_temp.ok((select action = 'opt_out' from public.text_inbound('+13055550701', 'Stop')), 'STOP from a parent');
select pg_temp.ok(exists (select 1 from public.text_opt_outs where phone = '+13055550701')
                  and exists (select 1 from public.text_replies where from_phone = '+13055550701' and action = 'opt_out'), 'opted out, and the STOP is saved');
select pg_temp.ok((select action = 'opt_in' from public.text_inbound('+13055550701', 'START')), 'START');
delete from public.text_opt_outs where phone = '+13055550701';

-- Who sees them: the same staff who see texts sent. Nobody can write or change them; the website can't call it.
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.ok((select count(*) >= 7 from public.text_replies where from_phone like '+1305555070%' or from_phone = '+13055550799'),
  'finance editor sees texts received');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select pg_temp.ok((select count(*) >= 7 from public.text_replies), 'the owner sees them');
do 'begin insert into public.text_replies (from_phone, body) values (''+13055550700'', ''fake''); raise exception ''FAIL: staff wrote a reply'';
exception when insufficient_privilege then null; end';
do 'begin perform * from public.text_inbound(''+13055550700'', ''fake''); raise exception ''FAIL: staff faked a reply'';
exception when insufficient_privilege then null; end';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.ok((select count(*) = 0 from public.text_replies), 'a teacher doesn''t see them');
reset role;
set role anon;
do 'begin perform count(*) from public.text_replies; raise exception ''FAIL: the website read texts'';
exception when insufficient_privilege then null; end';
do 'begin perform * from public.text_inbound(''+13055550700'', ''fake''); raise exception ''FAIL: the website faked a reply'';
exception when insufficient_privilege then null; end';
reset role;

-- Kept 5 years.
update public.text_replies set created_at = now() - interval '2 months' where from_phone = '+13055550799';
do 'begin delete from public.text_replies where from_phone = ''+13055550799''; raise exception ''FAIL: deleted a text from 2 months ago'';
exception when raise_exception then if sqlerrm not like ''Kept for 5 years%'' then raise; end if; end';
select pg_temp.ok(exists (select 1 from public.text_replies where from_phone = '+13055550799'), 'texts received are kept 5 years');

-- Clean up (on purpose, as the owner would from the SQL editor).
begin;
select set_config('crm.records_override', 'yes', true);
delete from public.text_replies where from_phone like '+1305555070%' or from_phone = '+13055550799';
delete from public.activities a using public.inquiries i where i.id = a.inquiry_id and i.parent_name = 'Rp Pipeline';
delete from public.inquiries where parent_name = 'Rp Pipeline';
delete from public.student_contacts c using public.students s where s.id = c.student_id and s.name like 'Rp %';
delete from public.students where name like 'Rp %';
commit;
\echo ALL TEXT REPLY TESTS PASSED
