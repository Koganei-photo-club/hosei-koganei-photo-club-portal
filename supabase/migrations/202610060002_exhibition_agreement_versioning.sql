-- Workflow v2 Agreement version history, revision, and re-agreement.
-- Existing definition rows are the canonical immutable versions; the Event pointer is current.

drop index if exists public.exhibition_agreement_one_active_per_event;

alter table public.exhibition_agreement_definitions
  add column if not exists previous_version_id uuid
    references public.exhibition_agreement_definitions(id) on delete restrict,
  add column if not exists change_reason text not null default 'Workflow v2 Activation',
  add column if not exists require_reagreement boolean not null default false;

alter table public.exhibition_agreement_definitions
  drop constraint if exists exhibition_agreement_change_reason_check,
  add constraint exhibition_agreement_change_reason_check
    check (trim(change_reason) <> '' and char_length(change_reason) <= 2000),
  drop constraint if exists exhibition_agreement_previous_not_self_check,
  add constraint exhibition_agreement_previous_not_self_check
    check (previous_version_id is null or previous_version_id <> id);

-- `active` existed before version history. Keep it true for compatibility; currentness is
-- represented only by events.current_exhibition_agreement_id and never by mutating old rows.
update public.exhibition_agreement_definitions set active=true where not active;

create table public.exhibition_application_agreement_acceptances (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  application_snapshot_id uuid not null references public.exhibition_application_snapshots(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  agreement_definition_id uuid not null references public.exhibition_agreement_definitions(id) on delete restrict,
  agreement_version integer not null check (agreement_version >= 1),
  agreement_hash text not null check (agreement_hash ~ '^[0-9a-f]{64}$'),
  acceptance_type text not null check (acceptance_type in ('application_submission','reagreement')),
  accepted_at timestamptz not null default now(),
  accepted_by_identifier text not null check (trim(accepted_by_identifier) <> ''),
  created_at timestamptz not null default now(),
  unique(application_snapshot_id, agreement_definition_id),
  foreign key(entry_id,event_id,member_id)
    references public.exhibition_entries(id,event_id,member_id) on delete restrict,
  foreign key(agreement_definition_id,event_id)
    references public.exhibition_agreement_definitions(id,event_id) on delete restrict
);

create index exhibition_agreement_acceptances_member_event_idx
  on public.exhibition_application_agreement_acceptances(member_id,event_id,accepted_at desc);
create index exhibition_agreement_acceptances_entry_idx
  on public.exhibition_application_agreement_acceptances(entry_id,accepted_at desc);

-- Existing Application Snapshots remain untouched and become the initial acceptance history.
insert into public.exhibition_application_agreement_acceptances(
  event_id,entry_id,application_snapshot_id,member_id,agreement_definition_id,
  agreement_version,agreement_hash,acceptance_type,accepted_at,accepted_by_identifier
)
select snapshot.event_id,snapshot.entry_id,snapshot.id,snapshot.member_id,
  snapshot.agreement_definition_id,snapshot.agreement_version,snapshot.agreement_hash,
  'application_submission',snapshot.agreed_at,snapshot.submitted_by_identifier
from public.exhibition_application_snapshots snapshot
on conflict(application_snapshot_id,agreement_definition_id) do nothing;

create or replace function private.record_exhibition_application_agreement_acceptance()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.exhibition_application_agreement_acceptances(
    event_id,entry_id,application_snapshot_id,member_id,agreement_definition_id,
    agreement_version,agreement_hash,acceptance_type,accepted_at,accepted_by_identifier
  ) values (
    new.event_id,new.entry_id,new.id,new.member_id,new.agreement_definition_id,
    new.agreement_version,new.agreement_hash,'application_submission',new.agreed_at,new.submitted_by_identifier
  ) on conflict(application_snapshot_id,agreement_definition_id) do nothing;
  return new;
end;
$$;

drop trigger if exists record_exhibition_application_agreement_acceptance_after_insert
  on public.exhibition_application_snapshots;
create trigger record_exhibition_application_agreement_acceptance_after_insert
after insert on public.exhibition_application_snapshots
for each row execute function private.record_exhibition_application_agreement_acceptance();

create or replace function private.prevent_exhibition_agreement_version_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Agreement Versionは変更または削除できません。';
end;
$$;

drop trigger if exists exhibition_agreement_definitions_immutable
  on public.exhibition_agreement_definitions;
create trigger exhibition_agreement_definitions_immutable
before update or delete on public.exhibition_agreement_definitions
for each row execute function private.prevent_exhibition_agreement_version_mutation();

create or replace function private.prevent_exhibition_agreement_acceptance_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  raise exception 'Application Agreement同意履歴は変更または削除できません。';
end;
$$;

create trigger exhibition_agreement_acceptances_immutable
before update or delete on public.exhibition_application_agreement_acceptances
for each row execute function private.prevent_exhibition_agreement_acceptance_mutation();

create or replace function public.admin_revise_exhibition_agreement_v2(
  p_event_id uuid,
  p_reference_key text,
  p_content text,
  p_reason text,
  p_require_reagreement boolean default false
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  target_event public.events%rowtype;
  previous_definition public.exhibition_agreement_definitions%rowtype;
  new_id uuid; next_version integer; new_hash text;
  actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reference_key,''))='' or trim(coalesce(p_content,''))='' then
    raise exception '新しい規約参照と規約本文は必須です。';
  end if;
  if trim(coalesce(p_reason,''))='' then raise exception '規約の改定理由は必須です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into target_event from public.events event where event.id=p_event_id for update;
  if target_event.id is null or target_event.genre<>'exhibition'
     or target_event.exhibition_workflow_version<>2 or target_event.deleted_at is not null then
    raise exception 'Workflow v2写真展が見つかりません。';
  end if;
  select * into previous_definition from public.exhibition_agreement_definitions definition
    where definition.id=target_event.current_exhibition_agreement_id
      and definition.event_id=p_event_id;
  if previous_definition.id is null then raise exception '現在の規約が見つかりません。'; end if;
  if exists(select 1 from public.exhibition_agreement_definitions definition
    where definition.event_id=p_event_id and definition.reference_key=trim(p_reference_key)) then
    raise exception '同じ規約参照は使用できません。';
  end if;
  select coalesce(max(definition.version_no),0)+1 into next_version
    from public.exhibition_agreement_definitions definition where definition.event_id=p_event_id;
  new_hash:=encode(extensions.digest(convert_to(p_content,'UTF8'),'sha256'),'hex');
  insert into public.exhibition_agreement_definitions(
    event_id,version_no,reference_key,content,content_hash,active,created_by,
    previous_version_id,change_reason,require_reagreement
  ) values (
    p_event_id,next_version,trim(p_reference_key),p_content,new_hash,true,actor,
    previous_definition.id,trim(p_reason),coalesce(p_require_reagreement,false)
  ) returning id into new_id;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set current_exhibition_agreement_id=new_id,
    updated_at=now(),updated_by=actor where event.id=p_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  perform private.write_exhibition_workflow_audit(
    p_event_id,'agreement_definition',new_id,'agreement_version_created','admin',actor,p_reason,
    jsonb_build_object('agreementId',previous_definition.id,'versionNo',previous_definition.version_no,
      'referenceKey',previous_definition.reference_key,'contentHash',previous_definition.content_hash),
    jsonb_build_object('agreementId',new_id,'versionNo',next_version,
      'referenceKey',trim(p_reference_key),'contentHash',new_hash),
    jsonb_build_object('previousVersionId',previous_definition.id,
      'requireReagreement',coalesce(p_require_reagreement,false))
  );
  return jsonb_build_object('agreementId',new_id,'versionNo',next_version,
    'referenceKey',trim(p_reference_key),'contentHash',new_hash,
    'requireReagreement',coalesce(p_require_reagreement,false));
end;
$$;

-- Preserve the old RPC contract for existing callers without mutating an old version.
create or replace function public.admin_create_exhibition_agreement_definition(
  p_event_id uuid,p_reference_key text,p_content text,p_reason text
)
returns jsonb language sql security definer set search_path='' as $$
  select public.admin_revise_exhibition_agreement_v2(
    p_event_id,p_reference_key,p_content,p_reason,false
  )
$$;

create or replace function public.get_current_exhibition_agreement(p_event_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'id',definition.id,'eventId',definition.event_id,'versionNo',definition.version_no,
    'referenceKey',definition.reference_key,'content',definition.content,
    'contentHash',definition.content_hash,'createdAt',definition.created_at,
    'createdBy',definition.created_by,'changeReason',definition.change_reason,
    'requireReagreement',definition.require_reagreement
  )
  from public.events event
  join public.exhibition_agreement_definitions definition
    on definition.id=event.current_exhibition_agreement_id
  where event.id=p_event_id and event.exhibition_workflow_version=2
    and (private.is_admin() or (private.is_current_member() and (
      (event.published and event.status='saved' and event.deleted_at is null)
      or exists(select 1 from public.exhibition_entries entry
        where entry.event_id=event.id and entry.member_id=private.current_member_id())
    )))
$$;

create or replace function public.admin_get_exhibition_agreement_versions_v2(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if not exists(select 1 from public.events event where event.id=p_event_id
    and event.exhibition_workflow_version=2) then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',definition.id,'versionNo',definition.version_no,
    'referenceKey',definition.reference_key,'content',definition.content,
    'contentHash',definition.content_hash,'createdAt',definition.created_at,
    'createdBy',definition.created_by,'changeReason',definition.change_reason,
    'previousVersionId',definition.previous_version_id,
    'requireReagreement',definition.require_reagreement,
    'current',definition.id=event.current_exhibition_agreement_id
  ) order by definition.version_no desc),'[]'::jsonb) into result
  from public.events event join public.exhibition_agreement_definitions definition
    on definition.event_id=event.id where event.id=p_event_id;
  return result;
end;
$$;

create or replace function public.get_my_exhibition_agreement_status_v2(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  target_event public.events%rowtype; target_member_id uuid; target_entry public.exhibition_entries%rowtype;
  current_definition public.exhibition_agreement_definitions%rowtype;
  history jsonb; stale boolean;
begin
  if not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  target_member_id:=private.current_member_id();
  select * into target_event from public.events event where event.id=p_event_id
    and event.exhibition_workflow_version=2 and event.deleted_at is null;
  if target_event.id is null then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  select * into target_entry from public.exhibition_entries entry
    where entry.event_id=p_event_id and entry.member_id=target_member_id;
  if not (target_event.published and target_event.status='saved') and target_entry.id is null then
    raise exception 'この写真展の規約は閲覧できません。';
  end if;
  select * into current_definition from public.exhibition_agreement_definitions definition
    where definition.id=target_event.current_exhibition_agreement_id;
  if current_definition.id is null then raise exception '現在の規約が見つかりません。'; end if;
  stale:=target_entry.id is not null and target_entry.application_state='active'
    and current_definition.require_reagreement
    and not exists(select 1 from public.exhibition_application_agreement_acceptances acceptance
      where acceptance.entry_id=target_entry.id
        and acceptance.application_snapshot_id=target_entry.current_application_snapshot_id
        and acceptance.agreement_definition_id=current_definition.id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',acceptance.id,'agreementId',definition.id,'versionNo',definition.version_no,
    'referenceKey',definition.reference_key,'contentHash',acceptance.agreement_hash,
    'acceptanceType',acceptance.acceptance_type,'acceptedAt',acceptance.accepted_at
  ) order by acceptance.accepted_at),'[]'::jsonb) into history
  from public.exhibition_application_agreement_acceptances acceptance
  join public.exhibition_agreement_definitions definition on definition.id=acceptance.agreement_definition_id
  where acceptance.member_id=target_member_id and acceptance.event_id=p_event_id
    and (target_entry.id is null or acceptance.entry_id=target_entry.id);
  return jsonb_build_object(
    'currentAgreement',jsonb_build_object('id',current_definition.id,
      'versionNo',current_definition.version_no,'referenceKey',current_definition.reference_key,
      'content',current_definition.content,'contentHash',current_definition.content_hash,
      'requireReagreement',current_definition.require_reagreement),
    'entryId',target_entry.id,'applicationSnapshotId',target_entry.current_application_snapshot_id,
    'agreementStale',stale,'acceptances',history
  );
end;
$$;

create or replace function public.reagree_exhibition_application_v2(
  p_event_id uuid,p_expected_agreement_id uuid,p_expected_agreement_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  target_member_id uuid; target_entry public.exhibition_entries%rowtype;
  target_event public.events%rowtype; target_agreement public.exhibition_agreement_definitions%rowtype;
  acceptance_id uuid; actor text:=private.current_email();
begin
  if not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  target_member_id:=private.current_member_id();
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into target_event from public.events event where event.id=p_event_id for update;
  if target_event.id is null or target_event.exhibition_workflow_version<>2 then
    raise exception 'Workflow v2写真展が見つかりません。';
  end if;
  select * into target_entry from public.exhibition_entries entry
    where entry.event_id=p_event_id and entry.member_id=target_member_id for update;
  if target_entry.id is null or target_entry.application_state<>'active'
     or target_entry.current_application_snapshot_id is null then
    raise exception '再同意対象の有効なApplicationがありません。';
  end if;
  select * into target_agreement from public.exhibition_agreement_definitions definition
    where definition.id=target_event.current_exhibition_agreement_id;
  if target_agreement.id is null or p_expected_agreement_id is distinct from target_agreement.id
     or lower(coalesce(p_expected_agreement_hash,''))<>target_agreement.content_hash then
    raise exception '規約が更新されました。最新の内容を再確認してください。';
  end if;
  if not target_agreement.require_reagreement then raise exception 'この規約改定では再同意は不要です。'; end if;
  insert into public.exhibition_application_agreement_acceptances(
    event_id,entry_id,application_snapshot_id,member_id,agreement_definition_id,
    agreement_version,agreement_hash,acceptance_type,accepted_at,accepted_by_identifier
  ) values (
    p_event_id,target_entry.id,target_entry.current_application_snapshot_id,target_member_id,
    target_agreement.id,target_agreement.version_no,target_agreement.content_hash,
    'reagreement',now(),actor
  ) on conflict(application_snapshot_id,agreement_definition_id) do nothing
  returning id into acceptance_id;
  if acceptance_id is null then raise exception 'この規約にはすでに再同意済みです。'; end if;
  perform private.write_exhibition_workflow_audit(
    p_event_id,'application_agreement_acceptance',acceptance_id,'application_agreement_reagreed',
    'member',actor,'','{}'::jsonb,
    jsonb_build_object('entryId',target_entry.id,'applicationSnapshotId',target_entry.current_application_snapshot_id,
      'agreementId',target_agreement.id,'agreementVersion',target_agreement.version_no,
      'agreementHash',target_agreement.content_hash)
  );
  return jsonb_build_object('acceptanceId',acceptance_id,'agreementId',target_agreement.id,
    'agreementVersion',target_agreement.version_no,'agreementStale',false);
end;
$$;

alter table public.exhibition_application_agreement_acceptances enable row level security;
revoke all on public.exhibition_application_agreement_acceptances from anon,authenticated;
grant select on public.exhibition_application_agreement_acceptances to authenticated;

drop policy if exists exhibition_agreement_admin_or_current_member_select
  on public.exhibition_agreement_definitions;
create policy exhibition_agreement_admin_current_or_own_select
on public.exhibition_agreement_definitions for select to authenticated using (
  private.is_admin()
  or exists(select 1 from public.events event
    where event.current_exhibition_agreement_id=exhibition_agreement_definitions.id
      and event.published and event.status='saved' and event.deleted_at is null)
  or exists(select 1 from public.exhibition_application_snapshots snapshot
    where snapshot.agreement_definition_id=exhibition_agreement_definitions.id
      and snapshot.member_id=private.current_member_id())
  or exists(select 1 from public.exhibition_application_agreement_acceptances acceptance
    where acceptance.agreement_definition_id=exhibition_agreement_definitions.id
      and acceptance.member_id=private.current_member_id())
);

create policy exhibition_agreement_acceptances_owner_or_admin_select
on public.exhibition_application_agreement_acceptances for select to authenticated using (
  private.is_admin() or member_id=private.current_member_id()
);

revoke all on function public.admin_revise_exhibition_agreement_v2(uuid,text,text,text,boolean) from public,anon;
revoke all on function public.admin_get_exhibition_agreement_versions_v2(uuid) from public,anon;
revoke all on function public.get_my_exhibition_agreement_status_v2(uuid) from public,anon;
revoke all on function public.reagree_exhibition_application_v2(uuid,uuid,text) from public,anon;
grant execute on function public.admin_revise_exhibition_agreement_v2(uuid,text,text,text,boolean) to authenticated;
grant execute on function public.admin_get_exhibition_agreement_versions_v2(uuid) to authenticated;
grant execute on function public.get_my_exhibition_agreement_status_v2(uuid) to authenticated;
grant execute on function public.reagree_exhibition_application_v2(uuid,uuid,text) to authenticated;

revoke execute on function private.record_exhibition_application_agreement_acceptance() from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_agreement_version_mutation() from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_agreement_acceptance_mutation() from public,anon,authenticated;

-- A Workflow v2 Event without its canonical initial/current version is an unsafe migration state.
do $$
begin
  if exists(select 1 from public.events event where event.exhibition_workflow_version=2
    and not exists(select 1 from public.exhibition_agreement_definitions definition
      where definition.id=event.current_exhibition_agreement_id and definition.event_id=event.id)) then
    raise exception 'Workflow v2 Eventの既存規約履歴を確認できません。';
  end if;
end $$;
