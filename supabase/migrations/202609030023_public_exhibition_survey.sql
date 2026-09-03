-- 新規写真展の一般来場者アンケート。
-- 個人情報や端末識別子そのものは保存せず、重複防止用のSHA-256ハッシュだけを保持する。

alter table public.events
  add column if not exists survey_enabled boolean not null default false;

create table if not exists public.exhibition_survey_responses (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  respondent_hash text not null,
  response_language text not null default 'ja'
    check (response_language in ('ja', 'en')),
  overall_comment text not null default '',
  submitted_at timestamptz not null default now(),
  unique (event_id, respondent_hash),
  check (char_length(respondent_hash) = 64),
  check (char_length(overall_comment) <= 2000)
);

create table if not exists public.exhibition_survey_selections (
  response_id uuid not null
    references public.exhibition_survey_responses(id) on delete cascade,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  comment text not null default '',
  position smallint not null check (position between 1 and 3),
  primary key (response_id, work_id),
  unique (response_id, position),
  check (char_length(comment) <= 1000)
);

create index if not exists exhibition_survey_responses_event_submitted_idx
  on public.exhibition_survey_responses(event_id, submitted_at);
create index if not exists exhibition_survey_selections_work_idx
  on public.exhibition_survey_selections(work_id);

alter table public.exhibition_survey_responses enable row level security;
alter table public.exhibition_survey_selections enable row level security;

revoke all on public.exhibition_survey_responses from anon, authenticated;
revoke all on public.exhibition_survey_selections from anon, authenticated;
grant select, delete on public.exhibition_survey_responses to authenticated;
grant select, delete on public.exhibition_survey_selections to authenticated;

drop policy if exists exhibition_survey_responses_admin_select
  on public.exhibition_survey_responses;
create policy exhibition_survey_responses_admin_select
on public.exhibition_survey_responses for select to authenticated
using (private.is_admin());

drop policy if exists exhibition_survey_responses_admin_delete
  on public.exhibition_survey_responses;
create policy exhibition_survey_responses_admin_delete
on public.exhibition_survey_responses for delete to authenticated
using (private.is_admin());

drop policy if exists exhibition_survey_selections_admin_select
  on public.exhibition_survey_selections;
create policy exhibition_survey_selections_admin_select
on public.exhibition_survey_selections for select to authenticated
using (private.is_admin());

drop policy if exists exhibition_survey_selections_admin_delete
  on public.exhibition_survey_selections;
create policy exhibition_survey_selections_admin_delete
on public.exhibition_survey_selections for delete to authenticated
using (private.is_admin());

create or replace function public.submit_exhibition_survey(
  p_exhibition_key text,
  p_respondent_token text,
  p_language text,
  p_overall_comment text,
  p_selections jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_event public.events%rowtype;
  v_response_id uuid;
  selection_count integer;
  distinct_count integer;
  invalid_count integer;
  respondent_hash text;
begin
  if char_length(coalesce(p_respondent_token, '')) < 32
     or char_length(p_respondent_token) > 200 then
    raise exception 'invalid respondent token' using errcode = '22023';
  end if;
  if p_language not in ('ja', 'en') then
    raise exception 'invalid language' using errcode = '22023';
  end if;
  if jsonb_typeof(p_selections) <> 'array' then
    raise exception 'selections must be an array' using errcode = '22023';
  end if;
  if char_length(coalesce(p_overall_comment, '')) > 2000 then
    raise exception 'overall comment is too long' using errcode = '22023';
  end if;

  select * into target_event
  from public.events event
  where event.exhibition_key = p_exhibition_key
    and event.genre = 'exhibition'
    and event.status = 'saved'
    and event.deleted_at is null
  for share;

  if target_event.id is null then
    raise exception 'unknown exhibition' using errcode = '22023';
  end if;
  if target_event.site_status <> 'published'
     or not target_event.survey_enabled
     or target_event.survey_opens_at is null
     or target_event.survey_closes_at is null
     or now() < target_event.survey_opens_at
     or now() > target_event.survey_closes_at then
    raise exception 'survey is closed' using errcode = '55000';
  end if;

  select count(*), count(distinct item->>'work_id')
  into selection_count, distinct_count
  from jsonb_array_elements(p_selections) item;
  if selection_count < 1 or selection_count > 3
     or selection_count <> distinct_count then
    raise exception 'select between one and three distinct works'
      using errcode = '22023';
  end if;

  select count(*) into invalid_count
  from jsonb_array_elements(p_selections) item
  left join public.exhibition_works work
    on work.id::text = item->>'work_id'
  where work.id is null
     or work.event_id <> target_event.id
     or work.status <> 'accepted'
     or nullif(trim(work.display_no), '') is null
     or char_length(coalesce(item->>'comment', '')) > 1000;
  if invalid_count > 0 then
    raise exception 'invalid work or comment' using errcode = '22023';
  end if;

  respondent_hash := encode(
    extensions.digest(p_respondent_token, 'sha256'),
    'hex'
  );

  insert into public.exhibition_survey_responses (
    event_id, respondent_hash, response_language, overall_comment
  ) values (
    target_event.id,
    respondent_hash,
    p_language,
    coalesce(p_overall_comment, '')
  ) returning id into v_response_id;

  insert into public.exhibition_survey_selections (
    response_id, work_id, comment, position
  )
  select
    v_response_id,
    (item->>'work_id')::uuid,
    coalesce(item->>'comment', ''),
    ordinality::smallint
  from jsonb_array_elements(p_selections)
    with ordinality as selection(item, ordinality);

  return v_response_id;
end;
$$;

create or replace function public.get_exhibition_survey_state(
  p_exhibition_key text
)
returns table (
  state text,
  opens_at timestamptz,
  closes_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    case
      when event.site_status <> 'published' or not event.survey_enabled
        then 'unavailable'
      when event.survey_opens_at is null or event.survey_closes_at is null
        then 'unavailable'
      when now() < event.survey_opens_at then 'upcoming'
      when now() <= event.survey_closes_at then 'open'
      else 'closed'
    end,
    event.survey_opens_at,
    event.survey_closes_at
  from public.events event
  where event.exhibition_key = p_exhibition_key
    and event.genre = 'exhibition'
    and event.status = 'saved'
    and event.deleted_at is null;
$$;

revoke all on function public.submit_exhibition_survey(text, text, text, text, jsonb)
  from public;
grant execute
  on function public.submit_exhibition_survey(text, text, text, text, jsonb)
  to anon, authenticated;

revoke all on function public.get_exhibition_survey_state(text) from public;
grant execute on function public.get_exhibition_survey_state(text)
  to anon, authenticated;

select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'events'
      and column_name = 'survey_enabled'
  ) as survey_switch_ready,
  to_regclass('public.exhibition_survey_responses') is not null
    as survey_responses_ready,
  to_regclass('public.exhibition_survey_selections') is not null
    as survey_selections_ready,
  to_regprocedure(
    'public.submit_exhibition_survey(text,text,text,text,jsonb)'
  ) is not null as survey_submit_api_ready,
  to_regprocedure('public.get_exhibition_survey_state(text)') is not null
    as survey_state_api_ready;
