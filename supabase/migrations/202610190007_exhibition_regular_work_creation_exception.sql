-- One-off, DB-enforced regular Work creation allowance for member-0041.
-- The authorization is intentionally separate from Draft rescue Targets: it
-- permits at most two new logical Works, while existing Target history remains
-- untouched.

create table public.exhibition_regular_work_creation_exceptions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  max_new_works integer not null check (max_new_works between 1 and 10),
  expires_at timestamptz not null,
  state text not null default 'active' check (state in ('active','revoked','completed')),
  reason text not null check (trim(reason)<>'' and char_length(reason)<=2000),
  created_by_identifier text not null check (trim(created_by_identifier)<>''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(event_id,member_id)
);

create table public.exhibition_regular_work_creation_exception_works (
  exception_id uuid not null references public.exhibition_regular_work_creation_exceptions(id) on delete restrict,
  work_id uuid not null unique references public.exhibition_works(id) on delete restrict,
  slot_no integer not null check (slot_no>0),
  created_at timestamptz not null default now(),
  primary key(exception_id,slot_no)
);

create or replace function private.prevent_regular_work_creation_exception_usage_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception '特例で作成した作品枠の履歴は変更できません。';
end;
$$;

create trigger exhibition_regular_work_creation_exception_works_immutable
before update or delete on public.exhibition_regular_work_creation_exception_works
for each row execute function private.prevent_regular_work_creation_exception_usage_mutation();

alter table public.exhibition_regular_work_creation_exceptions enable row level security;
alter table public.exhibition_regular_work_creation_exception_works enable row level security;
revoke all on public.exhibition_regular_work_creation_exceptions,
  public.exhibition_regular_work_creation_exception_works from public,anon,authenticated;

create or replace function private.current_regular_work_creation_exception(p_event_id uuid)
returns public.exhibition_regular_work_creation_exceptions
language plpgsql stable security definer set search_path='' as $$
declare result_row public.exhibition_regular_work_creation_exceptions%rowtype;
  current_member uuid:=private.current_member_id();
begin
  if current_member is null or not private.is_current_member() then return null; end if;
  select exception_row.* into result_row
  from public.exhibition_regular_work_creation_exceptions exception_row
  join public.events event_row on event_row.id=exception_row.event_id
  join public.exhibition_entries entry_row on entry_row.event_id=exception_row.event_id
    and entry_row.member_id=exception_row.member_id
  where exception_row.event_id=p_event_id and exception_row.member_id=current_member
    and exception_row.state='active' and now()<exception_row.expires_at
    and event_row.genre='exhibition' and event_row.exhibition_workflow_version=2
    and entry_row.application_state='active'
  limit 1;
  return result_row;
end;
$$;

create or replace function private.current_member_can_edit_creation_exception_work(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.exhibition_regular_work_creation_exception_works usage_row
    join public.exhibition_regular_work_creation_exceptions exception_row on exception_row.id=usage_row.exception_id
    join public.exhibition_works work_row on work_row.id=usage_row.work_id
    join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
    where usage_row.work_id=p_work_id and exception_row.state='active'
      and now()<exception_row.expires_at
      and exception_row.member_id=private.current_member_id()
      and work_row.owner_member_id=exception_row.member_id
      and work_row.event_id=exception_row.event_id
      and work_row.workflow_state='draft'
      and entry_row.application_state='active'
      and private.is_current_member()
  )
$$;

create or replace function private.regular_work_creation_exception_protects_work(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.exhibition_regular_work_creation_exception_works usage_row
    join public.exhibition_regular_work_creation_exceptions exception_row on exception_row.id=usage_row.exception_id
    join public.exhibition_works work_row on work_row.id=usage_row.work_id
    join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
    where usage_row.work_id=p_work_id and exception_row.state='active'
      and now()<exception_row.expires_at
      and work_row.owner_member_id=exception_row.member_id
      and work_row.event_id=exception_row.event_id
      and work_row.workflow_state='draft'
      and entry_row.application_state='active'
  )
$$;

create or replace function public.get_my_exhibition_regular_work_creation_exception_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare exception_row public.exhibition_regular_work_creation_exceptions%rowtype;
  used_count integer; work_ids jsonb;
begin
  select effective.* into exception_row
  from private.current_regular_work_creation_exception(p_event_id) effective;
  if exception_row.id is null then return null; end if;
  select count(*),coalesce(jsonb_agg(usage_row.work_id order by usage_row.slot_no),'[]'::jsonb)
    into used_count,work_ids
  from public.exhibition_regular_work_creation_exception_works usage_row
  where usage_row.exception_id=exception_row.id;
  return jsonb_build_object(
    'id',exception_row.id,'eventId',exception_row.event_id,'expiresAt',exception_row.expires_at,
    'maxNewWorks',exception_row.max_new_works,'usedCount',used_count,
    'remainingCount',greatest(exception_row.max_new_works-used_count,0),'workIds',work_ids
  );
end;
$$;

-- Extend the existing edit window only for Works created through this exact
-- exception. Existing Draft rescue and correction/re-edit rules are preserved.
create or replace function private.exhibition_work_edit_deadline_open(
  p_work public.exhibition_works,p_event public.events
)
returns boolean language sql stable security definer set search_path='' as $$
  select case
    when p_work.workflow_state in ('rejected','reedit_editing') then exists(
      select 1 from public.exhibition_workflow_cases case_row
      where case_row.work_id=p_work.id and case_row.state in ('open','permitted')
        and now()<case_row.individual_deadline
    )
    else now()<p_event.exhibition_work_submission_deadline
      or exists(select 1 from public.exhibition_entries entry_row where entry_row.id=p_work.entry_id
        and entry_row.application_state='active' and entry_row.revival_deadline is not null
        and now()<entry_row.revival_deadline)
      or (p_work.workflow_state='draft'
        and private.current_member_can_use_draft_rescue('regular_work',p_work.id))
      or (p_work.workflow_state='draft'
        and private.current_member_can_edit_creation_exception_work(p_work.id))
  end
$$;

-- Preserve existing rescue protection and add protection for the two newly
-- created Works so deadline processing cannot withdraw them before expiry.
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
  if target_row.id is not null then return true; end if;
  return p_target_type='regular_work'
    and private.regular_work_creation_exception_protects_work(p_work_id);
end;
$$;

-- Latest deployed signature, with only the new-Work deadline exception and
-- immutable quota consumption added.
create or replace function public.save_exhibition_work_draft_v2(
 p_event_id uuid,p_work_id uuid,p_title text,p_orientation text,p_print_size text,p_print_size_detail text,
 p_occupied_width_mm numeric,p_occupied_height_mm numeric,p_publication_consent boolean,p_original_image_path text,p_original_sha256 text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;entry_row public.exhibition_entries%rowtype;work_row public.exhibition_works%rowtype;
 exception_row public.exhibition_regular_work_creation_exceptions%rowtype;
 v_member_id uuid:=private.current_member_id();next_slot integer;logical_count integer;used_count integer;actor text:=private.current_email();
 ordinary_creation_open boolean;
begin
 if v_member_id is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
 select * into event_row from public.events event_item where event_item.id=p_event_id for update;
 select * into entry_row from public.exhibition_entries entry_item where entry_item.event_id=p_event_id and entry_item.member_id=v_member_id for update;
 if event_row.exhibition_workflow_version<>2 or entry_row.application_state<>'active' then raise exception '有効なApplicationが必要です。';end if;
 if p_work_id is null then
  ordinary_creation_open:=coalesce(private.exhibition_deadline_is_open(p_event_id,'work_submission'),false)
    or (entry_row.revival_deadline is not null and now()<entry_row.revival_deadline);
  if not ordinary_creation_open then
   select effective.* into exception_row from private.current_regular_work_creation_exception(p_event_id) effective;
   if exception_row.id is null then raise exception '作品提出締切を過ぎています。';end if;
   select * into exception_row from public.exhibition_regular_work_creation_exceptions
    where id=exception_row.id and state='active' and now()<expires_at for update;
   select count(*) into used_count from public.exhibition_regular_work_creation_exception_works
    where exception_id=exception_row.id;
   if used_count>=exception_row.max_new_works then raise exception '特例による新規作品登録枠を使い切っています。';end if;
  end if;
  select count(*) into logical_count from public.exhibition_works work_item where work_item.entry_id=entry_row.id and work_item.workflow_state<>'withdrawn'
   and not exists(select 1 from public.exhibition_works replacement where replacement.replacement_for_work_id=work_item.id and replacement.workflow_state<>'withdrawn');
  if logical_count>=event_row.max_works then raise exception '出展可能作品数を超えています。';end if;
  select coalesce(max(work_item.sort_order),0)+1 into next_slot from public.exhibition_works work_item where work_item.entry_id=entry_row.id;
  perform set_config('app.exhibition_work_rpc','on',true);
  insert into public.exhibition_works(id,entry_id,event_id,owner_member_id,sort_order,title,orientation,print_size,print_size_detail,occupied_width_mm,occupied_height_mm,publication_consent,original_image_path,original_sha256,status,workflow_state,lineage_id)
  values(gen_random_uuid(),entry_row.id,p_event_id,v_member_id,next_slot,trim(coalesce(p_title,'')),coalesce(p_orientation,''),coalesce(p_print_size,''),coalesce(p_print_size_detail,''),p_occupied_width_mm,p_occupied_height_mm,p_publication_consent,p_original_image_path,lower(p_original_sha256),'draft','draft',gen_random_uuid()) returning * into work_row;
  perform set_config('app.exhibition_work_rpc','off',true);
  if not ordinary_creation_open then
   insert into public.exhibition_regular_work_creation_exception_works(exception_id,work_id,slot_no)
   values(exception_row.id,work_row.id,used_count+1);
   perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,
    'exception_work_draft_created','member',actor,exception_row.reason,'{}',
    jsonb_build_object('workId',work_row.id,'exceptionId',exception_row.id,'slotNo',used_count+1));
  else
   perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'work_draft_created','member',actor,'','{}',jsonb_build_object('workId',work_row.id));
  end if;
 else
  select * into work_row from public.exhibition_works work_item where work_item.id=p_work_id and work_item.event_id=p_event_id and work_item.owner_member_id=v_member_id for update;
  if work_row.id is null or work_row.workflow_state not in('draft','rejected','reedit_editing') then raise exception '編集可能なWorkではありません。';end if;
  if not private.exhibition_work_edit_deadline_open(work_row,event_row) then raise exception '編集期限を過ぎています。';end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set title=trim(coalesce(p_title,'')),orientation=coalesce(p_orientation,''),print_size=coalesce(p_print_size,''),print_size_detail=coalesce(p_print_size_detail,''),occupied_width_mm=p_occupied_width_mm,occupied_height_mm=p_occupied_height_mm,publication_consent=p_publication_consent,original_image_path=p_original_image_path,original_sha256=lower(p_original_sha256),updated_at=now()
  where id=work_row.id returning * into work_row;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'work_draft_saved','member',actor,'','{}',jsonb_build_object('workflowState',work_row.workflow_state));
 end if;
 return to_jsonb(work_row);
end;$$;

-- A Draft created through the exception may be withdrawn during the same
-- exception window. Its immutable usage row remains, so the slot never revives.
create or replace function public.withdraw_exhibition_work_v2(p_work_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare work_row public.exhibition_works%rowtype; event_row public.events%rowtype; actor text:=private.current_email();
begin
  select * into work_row from public.exhibition_works
  where id=p_work_id and owner_member_id=private.current_member_id() for update;
  if work_row.id is null or work_row.workflow_state='withdrawn' then raise exception '取り下げ可能なWorkがありません。'; end if;
  select * into event_row from public.events where id=work_row.event_id;
  if event_row.exhibition_workflow_version<>2 or not (
    coalesce(private.exhibition_deadline_is_open(work_row.event_id,'work_submission'),false)
    or private.current_member_can_edit_creation_exception_work(work_row.id)
  ) then raise exception '作品提出締切後は本人による取り下げができません。'; end if;
  if work_row.workflow_state='accepted' and trim(coalesce(p_reason,''))='' then raise exception '確認済みWorkの取り下げ理由は必須です。'; end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=work_row.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  update public.exhibition_workflow_cases set state='withdrawn',closed_at=now()
  where work_id=work_row.id and state in ('pending','open','permitted');
  perform private.write_exhibition_workflow_audit(work_row.event_id,'work',work_row.id,'work_withdrawn',
    'member',actor,coalesce(p_reason,''),'{}',jsonb_build_object('previousState',work_row.workflow_state));
  perform private.auto_cancel_v2_entry_if_no_viable(work_row.entry_id,'work_withdrawal_no_viable_work');
  return jsonb_build_object('workId',work_row.id,'state','withdrawn');
end;
$$;

-- Seed only when both immutable IDs still describe the Production records that
-- were confirmed read-only before this migration was authored.
insert into public.exhibition_regular_work_creation_exceptions(
  event_id,member_id,max_new_works,expires_at,state,reason,created_by_identifier
)
select event_row.id,member_row.id,2,'2026-10-25 23:59:00+09'::timestamptz,'active',
  '2026年度学祭写真展：member-0041 個人枠作品2件の期限付き追加登録特例',
  'migration:202610190007'
from public.events event_row
join public.members member_row on member_row.id='4741a418-609d-4c7a-8cea-fd3db89f41b0'::uuid
where event_row.id='45a6cf08-228f-48bf-9e50-dfe2ef9ad583'::uuid
  and event_row.title='2026年度学祭写真展' and event_row.genre='exhibition'
  and event_row.exhibition_workflow_version=2 and event_row.max_works=3
  and member_row.member_no='member-0041' and member_row.active
  and exists(select 1 from public.exhibition_entries entry_row
    where entry_row.event_id=event_row.id and entry_row.member_id=member_row.id
      and entry_row.application_state='active')
on conflict(event_id,member_id) do nothing;

revoke all on function public.get_my_exhibition_regular_work_creation_exception_v1(uuid) from public,anon;
grant execute on function public.get_my_exhibition_regular_work_creation_exception_v1(uuid) to authenticated;
revoke execute on function private.current_regular_work_creation_exception(uuid),
  private.current_member_can_edit_creation_exception_work(uuid),
  private.regular_work_creation_exception_protects_work(uuid),
  private.prevent_regular_work_creation_exception_usage_mutation() from public,anon,authenticated;

