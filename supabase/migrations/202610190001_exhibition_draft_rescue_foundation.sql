-- Workflow v2 Draft rescue foundation (Tasks 1-3 only).
-- No submission, deadline-processing, or UI path is enabled by this migration.

create table public.exhibition_draft_rescue_campaigns (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  state text not null default 'enabled'
    check (state in ('enabled','disabled','completed')),
  ends_at timestamptz not null,
  reason text not null check (trim(reason)<>'' and char_length(reason)<=2000),
  created_by_identifier text not null
    check (trim(created_by_identifier)<>'' and char_length(created_by_identifier)<=320),
  created_at timestamptz not null default now(),
  disabled_by_identifier text
    check (disabled_by_identifier is null or (trim(disabled_by_identifier)<>'' and char_length(disabled_by_identifier)<=320)),
  disabled_at timestamptz,
  updated_at timestamptz not null default now(),
  check (ends_at>created_at),
  check ((state='enabled' and disabled_by_identifier is null and disabled_at is null)
    or (state in ('disabled','completed') and disabled_by_identifier is not null and disabled_at is not null))
);

create unique index exhibition_draft_rescue_campaigns_one_enabled_event
  on public.exhibition_draft_rescue_campaigns(event_id) where state='enabled';
create index exhibition_draft_rescue_campaigns_state_end_idx
  on public.exhibition_draft_rescue_campaigns(state,ends_at);

create table public.exhibition_draft_rescue_member_windows (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.exhibition_draft_rescue_campaigns(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  deadline timestamptz not null,
  state text not null default 'active'
    check (state in ('active','revoked','expired','completed')),
  reason text not null check (trim(reason)<>'' and char_length(reason)<=2000),
  created_by_identifier text not null
    check (trim(created_by_identifier)<>'' and char_length(created_by_identifier)<=320),
  created_at timestamptz not null default now(),
  updated_by_identifier text
    check (updated_by_identifier is null or (trim(updated_by_identifier)<>'' and char_length(updated_by_identifier)<=320)),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (deadline>created_at),
  check ((state='revoked' and revoked_at is not null) or (state<>'revoked' and revoked_at is null))
);

create unique index exhibition_draft_rescue_member_windows_one_active
  on public.exhibition_draft_rescue_member_windows(campaign_id,member_id) where state='active';
create index exhibition_draft_rescue_member_windows_deadline_idx
  on public.exhibition_draft_rescue_member_windows(state,deadline);

create table public.exhibition_draft_rescue_targets (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.exhibition_draft_rescue_campaigns(id) on delete restrict,
  member_window_id uuid references public.exhibition_draft_rescue_member_windows(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  target_type text not null check (target_type in ('regular_work','smartphone_work')),
  regular_work_id uuid references public.exhibition_works(id) on delete restrict,
  smartphone_work_id uuid references public.exhibition_smartphone_works(id) on delete restrict,
  rescue_mode text not null check (rescue_mode in ('member_resubmit','admin_proxy_submit')),
  state text not null default 'authorized'
    check (state in ('authorized','processing','consumed','revoked','expired','failed')),
  reason text not null check (trim(reason)<>'' and char_length(reason)<=2000),
  member_intent_confirmed boolean not null default false,
  member_confirmation_method text
    check (member_confirmation_method is null or (trim(member_confirmation_method)<>'' and char_length(member_confirmation_method)<=100)),
  member_confirmed_at timestamptz,
  confirmed_by_identifier text
    check (confirmed_by_identifier is null or (trim(confirmed_by_identifier)<>'' and char_length(confirmed_by_identifier)<=320)),
  smartphone_agreement_definition_id uuid
    references public.exhibition_smartphone_agreement_definitions(id) on delete restrict,
  smartphone_agreement_content_hash text
    check (smartphone_agreement_content_hash is null or smartphone_agreement_content_hash ~ '^[0-9a-f]{64}$'),
  smartphone_agreed_at timestamptz,
  result_snapshot_id uuid,
  created_by_identifier text not null
    check (trim(created_by_identifier)<>'' and char_length(created_by_identifier)<=320),
  created_at timestamptz not null default now(),
  consumed_at timestamptz,
  revoked_at timestamptz,
  check ((rescue_mode='member_resubmit' and member_window_id is not null)
    or (rescue_mode='admin_proxy_submit' and member_window_id is null)),
  check ((target_type='regular_work' and regular_work_id is not null and smartphone_work_id is null)
    or (target_type='smartphone_work' and smartphone_work_id is not null and regular_work_id is null)),
  check (rescue_mode<>'admin_proxy_submit' or (
    member_intent_confirmed and member_confirmation_method is not null
    and member_confirmed_at is not null and confirmed_by_identifier is not null
  )),
  check (target_type<>'regular_work' or (
    smartphone_agreement_definition_id is null and smartphone_agreement_content_hash is null
    and smartphone_agreed_at is null
  )),
  check (target_type<>'smartphone_work' or rescue_mode<>'admin_proxy_submit' or (
    smartphone_agreement_definition_id is not null
    and smartphone_agreement_content_hash is not null and smartphone_agreed_at is not null
  )),
  check ((state='consumed' and consumed_at is not null) or (state<>'consumed' and consumed_at is null)),
  check ((state='revoked' and revoked_at is not null) or (state<>'revoked' and revoked_at is null))
);

create unique index exhibition_draft_rescue_targets_one_active_regular
  on public.exhibition_draft_rescue_targets(regular_work_id)
  where regular_work_id is not null and state in ('authorized','processing');
create unique index exhibition_draft_rescue_targets_one_active_smartphone
  on public.exhibition_draft_rescue_targets(smartphone_work_id)
  where smartphone_work_id is not null and state in ('authorized','processing');
create index exhibition_draft_rescue_targets_campaign_state_idx
  on public.exhibition_draft_rescue_targets(campaign_id,state);
create index exhibition_draft_rescue_targets_member_state_idx
  on public.exhibition_draft_rescue_targets(member_id,state);

create table public.exhibition_draft_rescue_attempts (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references public.exhibition_draft_rescue_targets(id) on delete restrict,
  operator_identifier text not null
    check (trim(operator_identifier)<>'' and char_length(operator_identifier)<=320),
  attempted_at timestamptz not null default now(),
  operation_type text not null
    check (operation_type in ('member_resubmit','admin_proxy_submit','mode_change','authorization','revocation')),
  succeeded boolean not null,
  error_class text not null default '' check (char_length(error_class)<=100),
  safe_error_summary text not null default '' check (char_length(safe_error_summary)<=2000),
  result_snapshot_id uuid,
  check (succeeded or trim(error_class)<>'')
);

create index exhibition_draft_rescue_attempts_target_time_idx
  on public.exhibition_draft_rescue_attempts(target_id,attempted_at desc);

create or replace function private.is_exhibition_draft_rescue_operator()
returns boolean language sql stable security definer set search_path='' as $$
  select private.is_admin()
    and lower(private.current_email())=any(array[
      'takayuki.fujiyoshi.2r@stu.hosei.ac.jp'::text,
      'photo.club.at.koganei@gmail.com'::text
    ])
$$;

create or replace function private.get_effective_exhibition_draft_rescue_target(
  p_target_type text,p_work_id uuid,p_rescue_mode text
)
returns public.exhibition_draft_rescue_targets
language plpgsql stable security definer set search_path='' as $$
declare result_row public.exhibition_draft_rescue_targets%rowtype;
begin
  if p_target_type not in ('regular_work','smartphone_work')
     or p_rescue_mode not in ('member_resubmit','admin_proxy_submit') then
    return null;
  end if;

  select target_row.* into result_row
  from public.exhibition_draft_rescue_targets target_row
  join public.exhibition_draft_rescue_campaigns campaign_row
    on campaign_row.id=target_row.campaign_id
  left join public.exhibition_draft_rescue_member_windows window_row
    on window_row.id=target_row.member_window_id
  where target_row.target_type=p_target_type
    and target_row.rescue_mode=p_rescue_mode
    and target_row.state='authorized'
    and campaign_row.state='enabled'
    and now()<campaign_row.ends_at
    and campaign_row.event_id=target_row.event_id
    and ((p_target_type='regular_work' and target_row.regular_work_id=p_work_id and exists(
      select 1 from public.exhibition_works work_row
      join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
      join public.events event_row on event_row.id=work_row.event_id
      where work_row.id=p_work_id and work_row.workflow_state='draft'
        and work_row.event_id=target_row.event_id and work_row.owner_member_id=target_row.member_id
        and entry_row.event_id=target_row.event_id and entry_row.member_id=target_row.member_id
        and entry_row.application_state='active' and event_row.genre='exhibition'
        and event_row.exhibition_workflow_version=2
    )) or (p_target_type='smartphone_work' and target_row.smartphone_work_id=p_work_id and exists(
      select 1 from public.exhibition_smartphone_works work_row
      join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
      join public.events event_row on event_row.id=work_row.event_id
      where work_row.id=p_work_id and work_row.workflow_state='draft'
        and work_row.event_id=target_row.event_id and work_row.member_id=target_row.member_id
        and entry_row.event_id=target_row.event_id and entry_row.member_id=target_row.member_id
        and entry_row.application_state='active' and event_row.genre='exhibition'
        and event_row.exhibition_workflow_version=2 and event_row.smartphone_exhibition_enabled
    )))
    and ((p_rescue_mode='member_resubmit'
      and window_row.id is not null and window_row.campaign_id=target_row.campaign_id
      and window_row.event_id=target_row.event_id and window_row.member_id=target_row.member_id
      and window_row.state='active' and now()<window_row.deadline)
    or (p_rescue_mode='admin_proxy_submit'
      and target_row.member_window_id is null and target_row.member_intent_confirmed
      and (p_target_type<>'smartphone_work' or exists(
        select 1 from public.exhibition_smartphone_agreement_definitions definition_row
        where definition_row.id=target_row.smartphone_agreement_definition_id
          and definition_row.active
          and definition_row.content_hash=target_row.smartphone_agreement_content_hash
          and target_row.smartphone_agreed_at is not null
      ))))
  order by target_row.created_at desc,target_row.id
  limit 1;
  return result_row;
end;
$$;

create or replace function private.current_member_can_use_draft_rescue(
  p_target_type text,p_work_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype;
begin
  select effective.* into target_row
  from private.get_effective_exhibition_draft_rescue_target(
    p_target_type,p_work_id,'member_resubmit'
  ) effective;
  return target_row.id is not null and private.is_current_member()
    and target_row.member_id=private.current_member_id();
end;
$$;

create or replace function private.current_operator_can_proxy_submit_draft(
  p_target_type text,p_work_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype;
begin
  if not private.is_exhibition_draft_rescue_operator() then return false; end if;
  select effective.* into target_row
  from private.get_effective_exhibition_draft_rescue_target(
    p_target_type,p_work_id,'admin_proxy_submit'
  ) effective;
  return target_row.id is not null and target_row.member_intent_confirmed;
end;
$$;

create or replace function private.exhibition_draft_rescue_protects_work(
  p_target_type text,p_work_id uuid
)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype;
begin
  select effective.* into target_row
  from private.get_effective_exhibition_draft_rescue_target(
    p_target_type,p_work_id,'member_resubmit'
  ) effective;
  if target_row.id is not null then return true; end if;
  select effective.* into target_row
  from private.get_effective_exhibition_draft_rescue_target(
    p_target_type,p_work_id,'admin_proxy_submit'
  ) effective;
  return target_row.id is not null;
end;
$$;

create or replace function private.prevent_exhibition_draft_rescue_delete()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Draft救済の履歴は削除できません。';
end;
$$;

create or replace function private.prevent_exhibition_draft_rescue_attempt_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Draft救済の試行履歴は変更または削除できません。';
end;
$$;

create trigger exhibition_draft_rescue_campaigns_no_delete
before delete on public.exhibition_draft_rescue_campaigns
for each row execute function private.prevent_exhibition_draft_rescue_delete();
create trigger exhibition_draft_rescue_member_windows_no_delete
before delete on public.exhibition_draft_rescue_member_windows
for each row execute function private.prevent_exhibition_draft_rescue_delete();
create trigger exhibition_draft_rescue_targets_no_delete
before delete on public.exhibition_draft_rescue_targets
for each row execute function private.prevent_exhibition_draft_rescue_delete();
create trigger exhibition_draft_rescue_attempts_immutable
before update or delete on public.exhibition_draft_rescue_attempts
for each row execute function private.prevent_exhibition_draft_rescue_attempt_mutation();

alter table public.exhibition_draft_rescue_campaigns enable row level security;
alter table public.exhibition_draft_rescue_member_windows enable row level security;
alter table public.exhibition_draft_rescue_targets enable row level security;
alter table public.exhibition_draft_rescue_attempts enable row level security;

revoke all on public.exhibition_draft_rescue_campaigns,
  public.exhibition_draft_rescue_member_windows,
  public.exhibition_draft_rescue_targets,
  public.exhibition_draft_rescue_attempts from public,anon,authenticated;

revoke execute on function private.is_exhibition_draft_rescue_operator() from public,anon,authenticated;
revoke execute on function private.get_effective_exhibition_draft_rescue_target(text,uuid,text) from public,anon,authenticated;
revoke execute on function private.current_member_can_use_draft_rescue(text,uuid) from public,anon,authenticated;
revoke execute on function private.current_operator_can_proxy_submit_draft(text,uuid) from public,anon,authenticated;
revoke execute on function private.exhibition_draft_rescue_protects_work(text,uuid) from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_draft_rescue_delete() from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_draft_rescue_attempt_mutation() from public,anon,authenticated;
