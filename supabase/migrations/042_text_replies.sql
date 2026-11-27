-- Creativa CRM — every text sent to the school's Twilio number is saved, and matched to whoever has that number
-- anywhere in the CRM: the parents and contacts on a child's page (brothers and sisters too), the parent phone on the
-- child, a Pipeline card, or an online registration not added yet.
-- Run once in the Supabase SQL editor, after 041_record_keeping.sql. Safe to run again.
--
--   text_replies   one row per text received: when, from which number, what it said, STOP/START, who it is
--                  ("Maria Example (Mother) · Sam Example", as it was when the text came in), the Pipeline card and the
--                  children it belongs to. Shown on the child's page with the texts sent, on Messages → Texts received,
--                  and (as before) on the Pipeline card's timeline. Seen by the same staff who see texts sent
--                  (admins, and staff with finance "View & record"). Kept 5 years like the texts sent.
--   text_inbound   (called by netlify/functions/text-inbound.mjs) still opts STOP/START numbers out and in and still
--                  logs the text on the Pipeline card; now it also saves the text here and names the person, so the
--                  Telegram notice says who wrote.
--
-- No dollar-quoting or backslashes in this file, so it survives copy-paste intact.

create table if not exists public.text_replies (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  from_phone  text not null check (length(from_phone) between 1 and 40),
  body        text not null default '' check (length(body) <= 1600),
  action      text not null default 'message' check (action in ('message', 'opt_out', 'opt_in')),
  who         text check (length(who) <= 300),
  inquiry_id  uuid references public.inquiries(id) on delete set null,
  student_ids uuid[] not null default '{}'
);
create index if not exists text_replies_created_idx on public.text_replies (created_at desc);
create index if not exists text_replies_from_idx on public.text_replies (from_phone);
create index if not exists text_replies_students_idx on public.text_replies using gin (student_ids);

alter table public.text_replies enable row level security;
drop policy if exists text_replies_select on public.text_replies;
create policy text_replies_select on public.text_replies for select to authenticated using (public.can_message());
revoke all on public.text_replies from anon;
grant select on public.text_replies to authenticated;

-- Kept 5 years, like the texts sent (041).
do '
begin
  if to_regprocedure(''public.keep_records()'') is not null then
    drop trigger if exists keep_records on public.text_replies;
    create trigger keep_records before delete on public.text_replies for each row execute function public.keep_records(''created_at'');
  end if;
end';

-- Any way a phone number is written (305-555-1234, (305) 555 1234, +1 305…) → +13055551234, or null.
create or replace function public._phone_e164(p_phone text)
returns text language sql immutable as '
  select public._e164(regexp_replace(coalesce(p_phone, ''''), ''[^0-9]'', '''', ''g''))';

create or replace function public.text_inbound(p_from text, p_body text)
returns table (inquiry_id uuid, parent_name text, action text)
language plpgsql security definer set search_path = public as '
declare
  v_word   text := upper(trim(both '' .!'' from coalesce(p_body, '''')));
  v_action text := ''message'';
  v_inq    record;
  v_kids   uuid[] := ''{}'';
  v_person text;
  v_names  text;
  v_who    text;
  v_reg    record;
begin
  if v_word in (''STOP'', ''STOPALL'', ''UNSUBSCRIBE'', ''CANCEL'', ''END'', ''QUIT'', ''REVOKE'', ''OPTOUT'', ''PARAR'') then
    v_action := ''opt_out'';
    insert into public.text_opt_outs (phone, source) values (p_from, ''reply'') on conflict (phone) do nothing;
  elsif v_word in (''START'', ''UNSTOP'', ''YES'') then
    v_action := ''opt_in'';
    delete from public.text_opt_outs where phone = p_from;
  end if;

  -- The Pipeline card with this number (as before: the text goes on its timeline).
  select i.id, i.parent_name into v_inq
    from public.inquiries i
   where public._e164(i.phone_digits) = p_from
   order by (i.stage in (''enrolled'', ''lost'')), i.updated_at desc nulls last, i.created_at desc
   limit 1;
  if v_inq.id is not null then
    insert into public.activities (inquiry_id, author, kind, body)
    values (v_inq.id, null, ''text'',
            case v_action
              when ''opt_out'' then ''Replied '' || v_word || '' by text: no more automatic texts''
              when ''opt_in''  then ''Replied '' || v_word || '' by text: automatic texts back on''
              else ''Text from family: '' || left(coalesce(p_body, ''''), 1500) end);
  end if;

  -- Every child whose page has this number: a parent or contact (any of their phones), or the parent phone.
  select coalesce(array_agg(distinct m.student_id), ''{}'') into v_kids
    from (select c.student_id from public.student_contacts c
           where p_from in (public._phone_e164(c.cell_phone), public._phone_e164(c.sms_phone),
                            public._phone_e164(c.home_phone), public._phone_e164(c.work_phone))
          union all
          select s.id from public.students s where public._phone_e164(s.parent_phone) = p_from) m;

  if cardinality(v_kids) > 0 then
    -- Who wrote: the contact with this number (on a child at school first), else the parent named on the child.
    select p.person into v_person
      from (select nullif(trim(concat_ws('' '', c.first_name, c.last_name)), '''')
                   || coalesce('' ('' || nullif(trim(c.relationship), '''') || '')'', '''') as person,
                   s.status, s.name, 1 as rank
              from public.student_contacts c join public.students s on s.id = c.student_id
             where p_from in (public._phone_e164(c.cell_phone), public._phone_e164(c.sms_phone),
                              public._phone_e164(c.home_phone), public._phone_e164(c.work_phone))
            union all
            select nullif(trim(s.parent_name), ''''), s.status, s.name, 2
              from public.students s where public._phone_e164(s.parent_phone) = p_from) p
     where p.person is not null
     order by (p.status = ''enrolled'') desc, p.rank, p.name
     limit 1;
    select string_agg(s.name, '', '' order by (s.status = ''enrolled'') desc, s.name) into v_names
      from public.students s where s.id = any(v_kids);
    v_who := coalesce(v_person || '' · '' || v_names, ''Family of '' || v_names);
  elsif v_inq.id is not null then
    v_who := coalesce(nullif(trim(v_inq.parent_name), ''''), ''A family'') || '' (Pipeline)'';
  elsif to_regclass(''public.registration_forms'') is not null then
    select f.parent_name, f.child_name into v_reg
      from public.registration_forms f
     where f.status = ''new'' and public._phone_e164(f.parent_phone) = p_from
     order by f.created_at desc limit 1;
    if v_reg.child_name is not null then
      v_who := coalesce(nullif(trim(v_reg.parent_name), ''''), ''A parent'') || '' (online registration for '' || v_reg.child_name || '')'';
    end if;
  end if;

  insert into public.text_replies (from_phone, body, action, who, inquiry_id, student_ids)
  values (left(coalesce(p_from, ''''), 40), left(coalesce(p_body, ''''), 1600), v_action, left(v_who, 300), v_inq.id, v_kids);

  -- Who wrote, for the Telegram notice (a Pipeline family by its name alone, as before).
  return query select v_inq.id, case when cardinality(v_kids) > 0 then v_who else coalesce(v_inq.parent_name, v_who) end, v_action;
end';
revoke execute on function public._phone_e164(text) from public, anon;
revoke execute on function public.text_inbound(text, text) from public, anon, authenticated;

-- Check (the SQL editor shows only this last result).
select 'text_replies' as item, (to_regclass('public.text_replies') is not null)::text as ready
union all select 'text_inbound saves replies', (pg_get_functiondef('public.text_inbound(text, text)'::regprocedure) like '%text_replies%')::text
union all select 'kept 5 years', exists (select 1 from pg_trigger where tgname = 'keep_records' and tgrelid = 'public.text_replies'::regclass)::text;
