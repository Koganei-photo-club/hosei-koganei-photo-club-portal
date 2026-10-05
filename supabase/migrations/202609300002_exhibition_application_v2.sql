-- 写真展Workflow v2 Phase 2: ApplicationをWork提出から分離する。

alter table public.exhibition_entries
  add column if not exists application_state text,
  add column if not exists planned_work_count integer,
  add column if not exists display_name_type text,
  add column if not exists display_name_value text,
  add column if not exists working_agreement_definition_id uuid
    references public.exhibition_agreement_definitions(id) on delete restrict,
  add column if not exists application_updated_at timestamptz;

alter table public.exhibition_entries
  add constraint exhibition_entries_application_state_check
    check (application_state is null or application_state in ('draft', 'active', 'withdrawn')),
  add constraint exhibition_entries_planned_work_count_check
    check (planned_work_count is null or planned_work_count >= 1),
  add constraint exhibition_entries_display_name_type_check
    check (display_name_type is null or display_name_type in ('real_name', 'pseudonym')),
  add constraint exhibition_entries_display_name_value_check
    check (display_name_value is null or char_length(display_name_value) <= 100),
  add constraint exhibition_entries_v2_working_data_check check (
    application_state is null
    or (
      planned_work_count is not null
      and display_name_type is not null
      and trim(coalesce(display_name_value, '')) <> ''
      and application_updated_at is not null
    )
  );

alter table public.exhibition_entries
  add constraint exhibition_entries_id_event_member_unique unique(id,event_id,member_id);
alter table public.exhibition_agreement_definitions
  add constraint exhibition_agreement_id_event_unique unique(id,event_id);
alter table public.exhibition_entries
  add constraint exhibition_entries_working_agreement_event_fk
    foreign key(working_agreement_definition_id,event_id)
    references public.exhibition_agreement_definitions(id,event_id) on delete restrict;

create table public.exhibition_application_snapshots (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  version_no integer not null check (version_no >= 1),
  planned_work_count integer not null check (planned_work_count >= 1),
  display_name_type text not null check (display_name_type in ('real_name', 'pseudonym')),
  display_name_value text not null check (trim(display_name_value) <> '' and char_length(display_name_value) <= 100),
  note text not null default '',
  agreement_definition_id uuid not null references public.exhibition_agreement_definitions(id) on delete restrict,
  agreement_version integer not null check (agreement_version >= 1),
  agreement_hash text not null check (agreement_hash ~ '^[0-9a-f]{64}$'),
  agreed_at timestamptz not null,
  submitted_at timestamptz not null,
  submitted_by_member_id uuid not null references public.members(id) on delete restrict,
  submitted_by_identifier text not null check (trim(submitted_by_identifier) <> ''),
  created_at timestamptz not null default now(),
  unique(entry_id, version_no),
  check (submitted_by_member_id = member_id),
  foreign key(entry_id,event_id,member_id)
    references public.exhibition_entries(id,event_id,member_id) on delete restrict,
  foreign key(agreement_definition_id,event_id)
    references public.exhibition_agreement_definitions(id,event_id) on delete restrict
);

alter table public.exhibition_entries
  add column if not exists current_application_snapshot_id uuid
    references public.exhibition_application_snapshots(id) on delete restrict;

create index exhibition_application_snapshots_event_idx
  on public.exhibition_application_snapshots(event_id, submitted_at desc);
create index exhibition_application_snapshots_member_idx
  on public.exhibition_application_snapshots(member_id, submitted_at desc);

create or replace function private.validate_exhibition_application_values(
  p_event public.events,
  p_member public.members,
  p_planned_work_count integer,
  p_display_name_type text,
  p_display_name_value text
)
returns text language plpgsql stable security definer set search_path = '' as $$
declare resolved_name text;
begin
  if p_planned_work_count is null or p_planned_work_count < 1
     or p_planned_work_count > p_event.max_works then
    raise exception '出展予定作品数は1点以上、出展上限以下にしてください。';
  end if;
  if p_display_name_type not in ('real_name', 'pseudonym') then
    raise exception '表示名の種類を選択してください。';
  end if;
  if p_display_name_type = 'real_name' then
    resolved_name := trim(p_member.name);
  else
    resolved_name := trim(coalesce(p_display_name_value, ''));
  end if;
  if resolved_name = '' then raise exception '表示名を入力してください。'; end if;
  if char_length(resolved_name) > 100 then raise exception '表示名は100文字以内で入力してください。'; end if;
  return resolved_name;
end;
$$;

-- Legacy条件を保持し、v2 Entryだけを専用RPC管理にする。
create or replace function private.validate_exhibition_entry()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target_event public.events%rowtype;
  active_work_count integer;
  incomplete_work_count integer;
  rpc_authorized boolean := coalesce(current_setting('app.exhibition_application_rpc', true), '') = 'on';
begin
  select * into target_event from public.events e where e.id = new.event_id;
  if target_event.id is null or target_event.genre <> 'exhibition' then
    raise exception '対象の予定は写真展ではありません。';
  end if;

  if not private.is_admin() then
    if new.member_id <> private.current_member_id() then raise exception '本人以外の出展申込は登録できません。'; end if;
    if tg_op = 'UPDATE' and (new.member_id is distinct from old.member_id or new.event_id is distinct from old.event_id) then
      raise exception '出展者と対象写真展は変更できません。';
    end if;
    if not private.is_current_member() then raise exception '現在有効な部員のみ出展申込を登録できます。'; end if;
    if target_event.exhibition_workflow_version = 1
       and not private.is_available_exhibition_event(new.event_id) then
      raise exception 'この写真展は現在出展を受け付けていません。';
    end if;
    if target_event.exhibition_workflow_version = 2
       and (target_event.status <> 'saved' or not target_event.published or target_event.deleted_at is not null) then
      raise exception 'この写真展は現在出展を受け付けていません。';
    end if;
  end if;

  if target_event.exhibition_workflow_version = 2 then
    if not rpc_authorized then raise exception 'Workflow v2のApplicationは専用操作から変更してください。'; end if;
    if new.application_state is null or new.planned_work_count is null
       or new.display_name_type is null or trim(coalesce(new.display_name_value, '')) = '' then
      raise exception 'Workflow v2のApplication情報が不足しています。';
    end if;
    if new.planned_work_count > target_event.max_works then raise exception '出展可能作品数を超えています。'; end if;
    if new.application_state = 'active' then
      new.status = 'submitted';
      if new.submitted_at is null then new.submitted_at = now(); end if;
    elsif new.application_state = 'withdrawn' then
      new.status = 'withdrawn';
    else
      new.status = 'draft';
      new.submitted_at = null;
    end if;
    return new;
  end if;

  -- Workflow v1: 従来のWork必須条件を変更しない。
  if new.application_state is not null or new.planned_work_count is not null
     or new.display_name_type is not null or new.display_name_value is not null
     or new.working_agreement_definition_id is not null
     or new.current_application_snapshot_id is not null then
    raise exception 'Legacy写真展ではWorkflow v2のApplication項目を使用できません。';
  end if;
  if new.status = 'submitted' then
    if tg_op = 'INSERT' then raise exception '出展申込を下書きとして作成してから作品を登録してください。'; end if;
    select
      count(*) filter (where work.status <> 'withdrawn'),
      count(*) filter (where work.status <> 'withdrawn' and (
        work.status not in ('submitted', 'accepted') or trim(work.title) = '' or work.original_image_path is null
      ))
    into active_work_count, incomplete_work_count
    from public.exhibition_works work where work.entry_id = new.id;
    if active_work_count < 1 then raise exception '提出する作品を1件以上登録してください。'; end if;
    if incomplete_work_count > 0 then raise exception '作品名と原画像を登録し、すべての作品を提出済みにしてください。'; end if;
    if new.submitted_at is null then new.submitted_at = now(); end if;
  elsif new.status = 'draft' then
    new.submitted_at = null;
  end if;
  return new;
end;
$$;

create or replace function private.prevent_exhibition_application_snapshot_mutation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'Application Snapshotは変更または削除できません。';
end;
$$;

create trigger exhibition_application_snapshots_immutable
before update or delete on public.exhibition_application_snapshots
for each row execute function private.prevent_exhibition_application_snapshot_mutation();

create or replace function public.save_exhibition_application_draft_v2(
  p_event_id uuid,
  p_planned_work_count integer,
  p_display_name_type text,
  p_display_name_value text,
  p_note text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target_event public.events%rowtype; target_member public.members%rowtype;
  target_agreement public.exhibition_agreement_definitions%rowtype;
  target_entry public.exhibition_entries%rowtype; resolved_name text;
  actor text:=private.current_email(); next_state text;
begin
  if not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  if char_length(coalesce(p_note,''))>3000 then raise exception '備考は3000文字以内で入力してください。'; end if;
  select * into target_member from public.members where id=private.current_member_id() and active;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into target_event from public.events where id=p_event_id for update;
  if target_event.id is null or target_event.genre<>'exhibition' or target_event.exhibition_workflow_version<>2
     or target_event.status<>'saved' or not target_event.published or target_event.deleted_at is not null then
    raise exception '現在申込可能なWorkflow v2写真展ではありません。';
  end if;
  if not coalesce(private.exhibition_deadline_is_open(p_event_id,'application'),false) then
    raise exception '出展申込締切を過ぎています。';
  end if;
  resolved_name:=private.validate_exhibition_application_values(
    target_event,target_member,p_planned_work_count,p_display_name_type,p_display_name_value
  );
  select * into target_agreement from public.exhibition_agreement_definitions
    where id=target_event.current_exhibition_agreement_id and event_id=p_event_id and active;
  if target_agreement.id is null then raise exception '現在有効なApplication Agreementがありません。'; end if;
  select * into target_entry from public.exhibition_entries
    where event_id=p_event_id and member_id=target_member.id for update;
  if target_entry.id is not null and target_entry.application_state='active' then
    raise exception '申込済みApplicationは申込内容の更新操作を使用してください。';
  end if;
  if target_entry.id is not null and target_entry.application_state is null then
    raise exception 'Legacy EntryとWorkflow v2 Applicationが衝突しています。管理者へ連絡してください。';
  end if;
  next_state:=case when target_entry.application_state='withdrawn' then 'withdrawn' else 'draft' end;
  perform set_config('app.exhibition_application_rpc','on',true);
  if target_entry.id is null then
    insert into public.exhibition_entries(
      event_id,member_id,status,note,application_state,planned_work_count,display_name_type,
      display_name_value,working_agreement_definition_id,application_updated_at
    ) values(
      p_event_id,target_member.id,'draft',coalesce(p_note,''),'draft',p_planned_work_count,p_display_name_type,
      resolved_name,target_agreement.id,now()
    ) returning * into target_entry;
  else
    update public.exhibition_entries set note=coalesce(p_note,''),application_state=next_state,
      planned_work_count=p_planned_work_count,display_name_type=p_display_name_type,
      display_name_value=resolved_name,working_agreement_definition_id=target_agreement.id,
      application_updated_at=now()
    where id=target_entry.id returning * into target_entry;
  end if;
  perform set_config('app.exhibition_application_rpc','off',true);
  perform private.write_exhibition_workflow_audit(
    p_event_id,'application',target_entry.id,'application_draft_saved','member',actor,'',
    '{}'::jsonb,jsonb_build_object('applicationState',target_entry.application_state,
      'plannedWorkCount',target_entry.planned_work_count,'displayNameType',target_entry.display_name_type,
      'workingAgreementDefinitionId',target_agreement.id)
  );
  return jsonb_build_object('entryId',target_entry.id,'applicationState',target_entry.application_state,'saved',true);
end;
$$;

create or replace function public.submit_exhibition_application_v2(
  p_event_id uuid,
  p_planned_work_count integer,
  p_display_name_type text,
  p_display_name_value text,
  p_note text,
  p_expected_agreement_id uuid,
  p_expected_agreement_hash text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target_event public.events%rowtype;
  target_member public.members%rowtype;
  target_agreement public.exhibition_agreement_definitions%rowtype;
  target_entry public.exhibition_entries%rowtype;
  resolved_name text; snapshot_id uuid; next_version integer; action_name text;
  actor text := private.current_email(); submitted_time timestamptz := now();
begin
  if not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  if char_length(coalesce(p_note,'')) > 3000 then raise exception '備考は3000文字以内で入力してください。'; end if;
  select * into target_member from public.members where id = private.current_member_id() and active;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
  select * into target_event from public.events where id = p_event_id for update;
  if target_event.id is null or target_event.genre <> 'exhibition' or target_event.exhibition_workflow_version <> 2
     or target_event.status <> 'saved' or not target_event.published or target_event.deleted_at is not null then
    raise exception '現在申込可能なWorkflow v2写真展ではありません。';
  end if;
  if not coalesce(private.exhibition_deadline_is_open(p_event_id, 'application'), false) then
    raise exception '出展申込締切を過ぎています。';
  end if;
  resolved_name := private.validate_exhibition_application_values(
    target_event, target_member, p_planned_work_count, p_display_name_type, p_display_name_value
  );
  select * into target_agreement from public.exhibition_agreement_definitions
    where id = target_event.current_exhibition_agreement_id and event_id = p_event_id and active;
  if target_agreement.id is null then raise exception '現在有効なApplication Agreementがありません。'; end if;
  if p_expected_agreement_id is distinct from target_agreement.id
     or lower(coalesce(p_expected_agreement_hash, '')) <> target_agreement.content_hash then
    raise exception 'Application Agreementが更新されました。内容を再確認してから同意してください。';
  end if;

  select * into target_entry from public.exhibition_entries
    where event_id = p_event_id and member_id = target_member.id for update;
  if target_entry.id is not null and target_entry.application_state = 'active' then
    raise exception 'この写真展にはすでに申込済みです。';
  end if;
  if target_entry.id is not null and target_entry.application_state is null then
    raise exception 'Legacy EntryとWorkflow v2 Applicationが衝突しています。管理者へ連絡してください。';
  end if;

  perform set_config('app.exhibition_application_rpc', 'on', true);
  if target_entry.id is null then
    insert into public.exhibition_entries(
      event_id, member_id, status, note, application_state, planned_work_count,
      display_name_type, display_name_value, working_agreement_definition_id,
      application_updated_at, submitted_at
    ) values (
      p_event_id, target_member.id, 'draft', coalesce(p_note, ''), 'draft', p_planned_work_count,
      p_display_name_type, resolved_name, target_agreement.id, submitted_time, null
    ) returning * into target_entry;
  else
    update public.exhibition_entries set
      note = coalesce(p_note, ''), application_state = 'draft', planned_work_count = p_planned_work_count,
      display_name_type = p_display_name_type, display_name_value = resolved_name,
      working_agreement_definition_id = target_agreement.id, application_updated_at = submitted_time
    where id = target_entry.id returning * into target_entry;
  end if;

  select coalesce(max(version_no), 0) + 1 into next_version
  from public.exhibition_application_snapshots where entry_id = target_entry.id;
  insert into public.exhibition_application_snapshots(
    entry_id,event_id,member_id,version_no,planned_work_count,display_name_type,
    display_name_value,note,agreement_definition_id,agreement_version,agreement_hash,
    agreed_at,submitted_at,submitted_by_member_id,submitted_by_identifier
  ) values (
    target_entry.id,p_event_id,target_member.id,next_version,p_planned_work_count,p_display_name_type,
    resolved_name,coalesce(p_note,''),target_agreement.id,target_agreement.version_no,target_agreement.content_hash,
    submitted_time,submitted_time,target_member.id,actor
  ) returning id into snapshot_id;

  update public.exhibition_entries set
    application_state='active', status='submitted', planned_work_count=p_planned_work_count,
    display_name_type=p_display_name_type, display_name_value=resolved_name, note=coalesce(p_note,''),
    working_agreement_definition_id=target_agreement.id, current_application_snapshot_id=snapshot_id,
    application_updated_at=submitted_time, submitted_at=submitted_time
  where id=target_entry.id;
  perform set_config('app.exhibition_application_rpc', 'off', true);

  action_name := case when next_version = 1 then 'application_submitted' else 'application_reapplied' end;
  perform private.write_exhibition_workflow_audit(
    p_event_id,'application_snapshot',snapshot_id,action_name,'member',actor,
    '', '{}'::jsonb,
    jsonb_build_object('entryId',target_entry.id,'snapshotId',snapshot_id,'versionNo',next_version,
      'plannedWorkCount',p_planned_work_count,'displayNameType',p_display_name_type,
      'agreementDefinitionId',target_agreement.id,'agreementVersion',target_agreement.version_no,
      'agreementHash',target_agreement.content_hash)
  );
  return jsonb_build_object('entryId',target_entry.id,'snapshotId',snapshot_id,
    'versionNo',next_version,'applicationState','active');
end;
$$;

create or replace function public.update_exhibition_application_working_data_v2(
  p_event_id uuid,
  p_planned_work_count integer,
  p_display_name_type text,
  p_display_name_value text,
  p_note text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target_event public.events%rowtype; target_member public.members%rowtype;
  target_entry public.exhibition_entries%rowtype; resolved_name text; actor text := private.current_email();
begin
  if not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  if char_length(coalesce(p_note,'')) > 3000 then raise exception '備考は3000文字以内で入力してください。'; end if;
  select * into target_member from public.members where id=private.current_member_id() and active;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into target_event from public.events where id=p_event_id for update;
  if target_event.id is null or target_event.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  select * into target_entry from public.exhibition_entries
    where event_id=p_event_id and member_id=target_member.id for update;
  if target_entry.id is null or target_entry.application_state <> 'active' then raise exception '有効なApplicationがありません。'; end if;
  if not coalesce(private.exhibition_deadline_is_open(p_event_id,'work_submission'),false) then
    raise exception '作品提出締切後はApplication情報を変更できません。';
  end if;
  resolved_name := private.validate_exhibition_application_values(
    target_event,target_member,p_planned_work_count,p_display_name_type,p_display_name_value
  );
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set planned_work_count=p_planned_work_count,
    display_name_type=p_display_name_type,display_name_value=resolved_name,note=coalesce(p_note,''),
    application_updated_at=now()
  where id=target_entry.id;
  perform set_config('app.exhibition_application_rpc','off',true);
  if target_entry.planned_work_count is distinct from p_planned_work_count then
    perform private.write_exhibition_workflow_audit(
      p_event_id,'application',target_entry.id,'planned_work_count_changed','member',actor,'',
      jsonb_build_object('plannedWorkCount',target_entry.planned_work_count),
      jsonb_build_object('plannedWorkCount',p_planned_work_count)
    );
  end if;
  if target_entry.display_name_type is distinct from p_display_name_type
     or target_entry.display_name_value is distinct from resolved_name then
    perform private.write_exhibition_workflow_audit(
      p_event_id,'application',target_entry.id,'application_display_name_changed','member',actor,'',
      jsonb_build_object('displayNameType',target_entry.display_name_type,'displayNameValue',target_entry.display_name_value),
      jsonb_build_object('displayNameType',p_display_name_type,'displayNameValue',resolved_name)
    );
  end if;
  if target_entry.note is distinct from coalesce(p_note,'') then
    perform private.write_exhibition_workflow_audit(
      p_event_id,'application',target_entry.id,'application_note_changed','member',actor,'',
      jsonb_build_object('note',target_entry.note),jsonb_build_object('note',coalesce(p_note,''))
    );
  end if;
  return jsonb_build_object('entryId',target_entry.id,'applicationState','active','updated',true);
end;
$$;

create or replace function public.withdraw_exhibition_application_v2(p_event_id uuid, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target_event public.events%rowtype; target_entry public.exhibition_entries%rowtype;
  actor text:=private.current_email(); v_member_id uuid:=private.current_member_id();
begin
  if v_member_id is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into target_event from public.events where id=p_event_id for update;
  if target_event.id is null or target_event.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  if not coalesce(private.exhibition_deadline_is_open(p_event_id,'application'),false) then raise exception '出展申込締切後は申込を取り消せません。'; end if;
  select entry.* into target_entry from public.exhibition_entries entry
    where entry.event_id=p_event_id and entry.member_id=v_member_id for update;
  if target_entry.id is null or target_entry.application_state<>'active' then raise exception '取り消せるApplicationがありません。'; end if;
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set application_state='withdrawn',status='withdrawn',application_updated_at=now()
    where id=target_entry.id;
  perform set_config('app.exhibition_application_rpc','off',true);
  perform private.write_exhibition_workflow_audit(
    p_event_id,'application',target_entry.id,'application_withdrawn','member',actor,coalesce(p_reason,''),
    jsonb_build_object('applicationState','active','currentSnapshotId',target_entry.current_application_snapshot_id),
    jsonb_build_object('applicationState','withdrawn','currentSnapshotId',target_entry.current_application_snapshot_id)
  );
  return jsonb_build_object('entryId',target_entry.id,'applicationState','withdrawn');
end;
$$;

alter table public.exhibition_application_snapshots enable row level security;
revoke all on public.exhibition_application_snapshots from anon, authenticated;
grant select on public.exhibition_application_snapshots to authenticated;

create policy exhibition_application_snapshots_owner_or_admin_select
on public.exhibition_application_snapshots for select to authenticated
using (member_id=private.current_member_id() or private.is_admin());

revoke all on function public.submit_exhibition_application_v2(uuid,integer,text,text,text,uuid,text) from public,anon;
revoke all on function public.save_exhibition_application_draft_v2(uuid,integer,text,text,text) from public,anon;
revoke all on function public.update_exhibition_application_working_data_v2(uuid,integer,text,text,text) from public,anon;
revoke all on function public.withdraw_exhibition_application_v2(uuid,text) from public,anon;
grant execute on function public.submit_exhibition_application_v2(uuid,integer,text,text,text,uuid,text) to authenticated;
grant execute on function public.save_exhibition_application_draft_v2(uuid,integer,text,text,text) to authenticated;
grant execute on function public.update_exhibition_application_working_data_v2(uuid,integer,text,text,text) to authenticated;
grant execute on function public.withdraw_exhibition_application_v2(uuid,text) to authenticated;

revoke execute on function private.validate_exhibition_application_values(public.events,public.members,integer,text,text) from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_application_snapshot_mutation() from public,anon,authenticated;

select
  to_regclass('public.exhibition_application_snapshots') is not null as application_snapshots_ready,
  to_regprocedure('public.submit_exhibition_application_v2(uuid,integer,text,text,text,uuid,text)') is not null as submit_rpc_ready,
  to_regprocedure('public.withdraw_exhibition_application_v2(uuid,text)') is not null as withdraw_rpc_ready;
