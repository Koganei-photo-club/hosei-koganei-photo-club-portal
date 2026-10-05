-- 写真展Workflow v2 Phase 1
-- Legacy lifecycleを変更せず、明示的に有効化した写真展だけに適用する基盤。

alter table public.events
  add column if not exists exhibition_workflow_version smallint not null default 1,
  add column if not exists exhibition_application_deadline timestamptz,
  add column if not exists exhibition_work_submission_deadline timestamptz,
  add column if not exists exhibition_revision_deadline timestamptz,
  add column if not exists exhibition_caption_deadline timestamptz,
  add column if not exists exhibition_workflow_started_at timestamptz;

alter table public.events
  drop constraint if exists events_exhibition_workflow_version_check,
  drop constraint if exists events_exhibition_v2_genre_check,
  drop constraint if exists events_exhibition_v2_deadlines_check;

alter table public.events
  add constraint events_exhibition_workflow_version_check
    check (exhibition_workflow_version in (1, 2)),
  add constraint events_exhibition_v2_genre_check
    check (exhibition_workflow_version = 1 or genre = 'exhibition'),
  add constraint events_exhibition_v2_deadlines_check check (
    exhibition_workflow_version = 1
    or (
      exhibition_application_deadline is not null
      and exhibition_work_submission_deadline is not null
      and exhibition_revision_deadline is not null
      and exhibition_caption_deadline is not null
      and exhibition_application_deadline < exhibition_work_submission_deadline
      and exhibition_work_submission_deadline < exhibition_revision_deadline
      and exhibition_revision_deadline < exhibition_caption_deadline
    )
  );

comment on column public.events.exhibition_workflow_version is
  '1=Legacy, 2=Snapshot/Review based workflow. v2への切替は専用RPCのみ。';
comment on column public.events.registration_deadline is
  '既存イベントおよびLegacy写真展の申込締切。Workflow v2の4締切とは別。';

create table public.exhibition_agreement_definitions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  version_no integer not null check (version_no >= 1),
  reference_key text not null check (trim(reference_key) <> '' and char_length(reference_key) <= 200),
  content text not null check (trim(content) <> ''),
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now(),
  unique(event_id, version_no),
  unique(event_id, reference_key)
);

create unique index exhibition_agreement_one_active_per_event
  on public.exhibition_agreement_definitions(event_id) where active;

alter table public.events
  add column if not exists current_exhibition_agreement_id uuid
    references public.exhibition_agreement_definitions(id) on delete restrict;

create table public.exhibition_workflow_audit_logs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  entity_type text not null check (trim(entity_type) <> '' and char_length(entity_type) <= 100),
  entity_id uuid,
  action text not null check (trim(action) <> '' and char_length(action) <= 150),
  actor_type text not null check (actor_type in ('member', 'admin', 'system')),
  actor_identifier text not null check (trim(actor_identifier) <> '' and char_length(actor_identifier) <= 320),
  reason text not null default '' check (char_length(reason) <= 2000),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  performed_at timestamptz not null default now(),
  check (jsonb_typeof(before_state) = 'object'),
  check (jsonb_typeof(after_state) = 'object'),
  check (jsonb_typeof(metadata) = 'object'),
  check (pg_column_size(before_state) <= 65536),
  check (pg_column_size(after_state) <= 65536),
  check (pg_column_size(metadata) <= 65536)
);

create index exhibition_workflow_audit_event_time_idx
  on public.exhibition_workflow_audit_logs(event_id, performed_at desc);
create index exhibition_workflow_audit_entity_idx
  on public.exhibition_workflow_audit_logs(entity_type, entity_id, performed_at desc);

-- 後続Phaseの冪等なSYSTEM締切処理が、処理済みGlobal Deadlineを書き換えさせないための基盤。
create table public.exhibition_deadline_processing (
  event_id uuid not null references public.events(id) on delete restrict,
  deadline_type text not null check (deadline_type in ('application', 'work_submission', 'revision', 'caption')),
  deadline_value timestamptz not null,
  processed_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  primary key(event_id, deadline_type)
);

create or replace function private.validate_exhibition_v2_deadlines(
  p_application timestamptz,
  p_work_submission timestamptz,
  p_revision timestamptz,
  p_caption timestamptz,
  p_require_future boolean default true
)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if p_application is null or p_work_submission is null
     or p_revision is null or p_caption is null then
    raise exception 'Workflow v2では4つの締切がすべて必須です。';
  end if;
  if not (p_application < p_work_submission
          and p_work_submission < p_revision
          and p_revision < p_caption) then
    raise exception '締切は、出展申込 < 作品提出 < 修正 < キャプションの順にしてください。';
  end if;
  if p_require_future and p_application <= now() then
    raise exception '変更後の締切はすべて未来である必要があります。';
  end if;
end;
$$;

create or replace function private.exhibition_deadline_is_open(
  p_event_id uuid,
  p_deadline_type text
)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_deadline_type
    when 'application' then now() < e.exhibition_application_deadline
    when 'work_submission' then now() < e.exhibition_work_submission_deadline
    when 'revision' then now() < e.exhibition_revision_deadline
    when 'caption' then now() < e.exhibition_caption_deadline
    else false
  end
  from public.events e
  where e.id = p_event_id and e.genre = 'exhibition'
    and e.exhibition_workflow_version = 2
$$;

create or replace function private.write_exhibition_workflow_audit(
  p_event_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_actor_type text,
  p_actor_identifier text,
  p_reason text default '',
  p_before_state jsonb default '{}'::jsonb,
  p_after_state jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result_id uuid;
begin
  insert into public.exhibition_workflow_audit_logs(
    event_id, entity_type, entity_id, action, actor_type, actor_identifier,
    reason, before_state, after_state, metadata
  ) values (
    p_event_id, trim(p_entity_type), p_entity_id, trim(p_action), p_actor_type,
    trim(p_actor_identifier), coalesce(p_reason, ''),
    coalesce(p_before_state, '{}'::jsonb), coalesce(p_after_state, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  ) returning id into result_id;
  return result_id;
end;
$$;

create or replace function private.mark_exhibition_deadline_processed(
  p_event_id uuid,
  p_deadline_type text,
  p_deadline_value timestamptz,
  p_metadata jsonb default '{}'::jsonb
)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  insert into public.exhibition_deadline_processing(event_id, deadline_type, deadline_value, metadata)
  values(p_event_id, p_deadline_type, p_deadline_value, coalesce(p_metadata, '{}'::jsonb))
  on conflict(event_id, deadline_type) do nothing;
  return found;
end;
$$;

create or replace function private.protect_exhibition_workflow_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
declare rpc_authorized boolean := coalesce(current_setting('app.exhibition_workflow_rpc', true), '') = 'on';
begin
  if tg_op = 'INSERT' then
    if new.exhibition_workflow_version <> 1
       or new.exhibition_application_deadline is not null
       or new.exhibition_work_submission_deadline is not null
       or new.exhibition_revision_deadline is not null
       or new.exhibition_caption_deadline is not null
       or new.current_exhibition_agreement_id is not null
       or new.exhibition_workflow_started_at is not null then
      raise exception 'Workflow v2は予定保存後に専用RPCで有効化してください。';
    end if;
    return new;
  end if;

  if old.exhibition_workflow_version = 2 and new.exhibition_workflow_version <> 2 then
    raise exception '正式運用を開始したWorkflow v2写真展をLegacyへ戻すことはできません。';
  end if;
  if old.exhibition_workflow_version = 2 and new.genre <> 'exhibition' then
    raise exception 'Workflow v2写真展のジャンルは変更できません。';
  end if;
  if not rpc_authorized and (
    new.exhibition_workflow_version is distinct from old.exhibition_workflow_version
    or new.exhibition_application_deadline is distinct from old.exhibition_application_deadline
    or new.exhibition_work_submission_deadline is distinct from old.exhibition_work_submission_deadline
    or new.exhibition_revision_deadline is distinct from old.exhibition_revision_deadline
    or new.exhibition_caption_deadline is distinct from old.exhibition_caption_deadline
    or new.current_exhibition_agreement_id is distinct from old.current_exhibition_agreement_id
    or new.exhibition_workflow_started_at is distinct from old.exhibition_workflow_started_at
  ) then
    raise exception 'Workflow Version・締切・Agreementは専用RPCから変更してください。';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_exhibition_workflow_fields_before_write on public.events;
create trigger protect_exhibition_workflow_fields_before_write
before insert or update on public.events
for each row execute function private.protect_exhibition_workflow_fields();

create or replace function public.admin_activate_exhibition_workflow_v2(
  p_event_id uuid,
  p_application_deadline timestamptz,
  p_work_submission_deadline timestamptz,
  p_revision_deadline timestamptz,
  p_caption_deadline timestamptz,
  p_agreement_reference text,
  p_agreement_content text,
  p_reason text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target public.events%rowtype; agreement_id uuid; actor text := private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Workflow v2有効化理由は必須です。'; end if;
  if trim(coalesce(p_agreement_reference, '')) = '' or trim(coalesce(p_agreement_content, '')) = '' then
    raise exception 'Agreementの参照名と同意内容は必須です。';
  end if;
  perform private.validate_exhibition_v2_deadlines(
    p_application_deadline, p_work_submission_deadline, p_revision_deadline, p_caption_deadline, true
  );
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
  select * into target from public.events where id = p_event_id for update;
  if target.id is null or target.genre <> 'exhibition' or target.deleted_at is not null then
    raise exception '対象の写真展が見つかりません。';
  end if;
  if target.exhibition_workflow_version = 2 then raise exception 'この写真展はすでにWorkflow v2です。'; end if;
  if exists(select 1 from public.exhibition_entries where event_id = p_event_id)
     or exists(select 1 from public.exhibition_works where event_id = p_event_id)
     or exists(select 1 from public.exhibition_layouts where event_id = p_event_id)
     or exists(select 1 from public.exhibition_survey_responses where event_id = p_event_id)
     or target.site_status in ('published', 'ended') then
    raise exception 'Entry・Work・Layout・Survey・公開履歴がある写真展は自動的にv2へ切り替えられません。';
  end if;

  insert into public.exhibition_agreement_definitions(
    event_id, version_no, reference_key, content, content_hash, active, created_by
  ) values (
    p_event_id, 1, trim(p_agreement_reference), p_agreement_content,
    encode(extensions.digest(convert_to(p_agreement_content, 'UTF8'), 'sha256'), 'hex'), true, actor
  ) returning id into agreement_id;

  perform set_config('app.exhibition_workflow_rpc', 'on', true);
  update public.events set
    exhibition_workflow_version = 2,
    exhibition_application_deadline = p_application_deadline,
    exhibition_work_submission_deadline = p_work_submission_deadline,
    exhibition_revision_deadline = p_revision_deadline,
    exhibition_caption_deadline = p_caption_deadline,
    current_exhibition_agreement_id = agreement_id,
    exhibition_workflow_started_at = now(),
    updated_at = now(), updated_by = actor
  where id = p_event_id;
  perform set_config('app.exhibition_workflow_rpc', 'off', true);

  perform private.write_exhibition_workflow_audit(
    p_event_id, 'event', p_event_id, 'workflow_v2_activated', 'admin', actor, p_reason,
    jsonb_build_object('workflowVersion', 1),
    jsonb_build_object(
      'workflowVersion', 2, 'applicationDeadline', p_application_deadline,
      'workSubmissionDeadline', p_work_submission_deadline,
      'revisionDeadline', p_revision_deadline, 'captionDeadline', p_caption_deadline,
      'agreementId', agreement_id
    )
  );
  return jsonb_build_object('eventId', p_event_id, 'workflowVersion', 2, 'agreementId', agreement_id);
end;
$$;

create or replace function public.admin_update_exhibition_workflow_deadlines(
  p_event_id uuid,
  p_application_deadline timestamptz,
  p_work_submission_deadline timestamptz,
  p_revision_deadline timestamptz,
  p_caption_deadline timestamptz,
  p_reason text default ''
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target public.events%rowtype; actor text := private.current_email(); shortened boolean;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  perform private.validate_exhibition_v2_deadlines(
    p_application_deadline, p_work_submission_deadline, p_revision_deadline, p_caption_deadline, true
  );
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
  select * into target from public.events where id = p_event_id for update;
  if target.id is null or target.genre <> 'exhibition' or target.exhibition_workflow_version <> 2 then
    raise exception 'Workflow v2写真展が見つかりません。';
  end if;
  if exists(
    select 1 from public.exhibition_deadline_processing processing
    where processing.event_id = p_event_id and (
      (processing.deadline_type = 'application' and p_application_deadline is distinct from target.exhibition_application_deadline)
      or (processing.deadline_type = 'work_submission' and p_work_submission_deadline is distinct from target.exhibition_work_submission_deadline)
      or (processing.deadline_type = 'revision' and p_revision_deadline is distinct from target.exhibition_revision_deadline)
      or (processing.deadline_type = 'caption' and p_caption_deadline is distinct from target.exhibition_caption_deadline)
    )
  ) then raise exception 'SYSTEM処理済みのGlobal Deadlineは変更できません。'; end if;

  shortened := p_application_deadline < target.exhibition_application_deadline
    or p_work_submission_deadline < target.exhibition_work_submission_deadline
    or p_revision_deadline < target.exhibition_revision_deadline
    or p_caption_deadline < target.exhibition_caption_deadline;
  if shortened and trim(coalesce(p_reason, '')) = '' then raise exception '締切を短縮する場合は理由が必須です。'; end if;

  perform set_config('app.exhibition_workflow_rpc', 'on', true);
  update public.events set
    exhibition_application_deadline = p_application_deadline,
    exhibition_work_submission_deadline = p_work_submission_deadline,
    exhibition_revision_deadline = p_revision_deadline,
    exhibition_caption_deadline = p_caption_deadline,
    updated_at = now(), updated_by = actor
  where id = p_event_id;
  perform set_config('app.exhibition_workflow_rpc', 'off', true);
  perform private.write_exhibition_workflow_audit(
    p_event_id, 'event', p_event_id, 'global_deadlines_updated', 'admin', actor, p_reason,
    jsonb_build_object(
      'applicationDeadline', target.exhibition_application_deadline,
      'workSubmissionDeadline', target.exhibition_work_submission_deadline,
      'revisionDeadline', target.exhibition_revision_deadline,
      'captionDeadline', target.exhibition_caption_deadline
    ),
    jsonb_build_object(
      'applicationDeadline', p_application_deadline,
      'workSubmissionDeadline', p_work_submission_deadline,
      'revisionDeadline', p_revision_deadline,
      'captionDeadline', p_caption_deadline
    ), jsonb_build_object('shortened', shortened)
  );
  return jsonb_build_object('eventId', p_event_id, 'updated', true, 'shortened', shortened);
end;
$$;

create or replace function public.admin_create_exhibition_agreement_definition(
  p_event_id uuid,
  p_reference_key text,
  p_content text,
  p_reason text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target public.events%rowtype; old_definition public.exhibition_agreement_definitions%rowtype;
  new_id uuid; next_version integer; actor text := private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reference_key, '')) = '' or trim(coalesce(p_content, '')) = '' then raise exception 'Agreementの参照名と内容は必須です。'; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Agreement変更理由は必須です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
  select * into target from public.events where id = p_event_id for update;
  if target.id is null or target.exhibition_workflow_version <> 2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  select * into old_definition from public.exhibition_agreement_definitions where id = target.current_exhibition_agreement_id;
  select coalesce(max(version_no), 0) + 1 into next_version from public.exhibition_agreement_definitions where event_id = p_event_id;
  update public.exhibition_agreement_definitions set active = false where event_id = p_event_id and active;
  insert into public.exhibition_agreement_definitions(event_id, version_no, reference_key, content, content_hash, active, created_by)
  values(p_event_id, next_version, trim(p_reference_key), p_content,
    encode(extensions.digest(convert_to(p_content, 'UTF8'), 'sha256'), 'hex'), true, actor)
  returning id into new_id;
  perform set_config('app.exhibition_workflow_rpc', 'on', true);
  update public.events set current_exhibition_agreement_id = new_id, updated_at = now(), updated_by = actor where id = p_event_id;
  perform set_config('app.exhibition_workflow_rpc', 'off', true);
  perform private.write_exhibition_workflow_audit(
    p_event_id, 'agreement_definition', new_id, 'agreement_definition_activated', 'admin', actor, p_reason,
    jsonb_build_object('agreementId', old_definition.id, 'versionNo', old_definition.version_no, 'contentHash', old_definition.content_hash),
    jsonb_build_object('agreementId', new_id, 'versionNo', next_version,
      'contentHash', encode(extensions.digest(convert_to(p_content, 'UTF8'), 'sha256'), 'hex'))
  );
  return jsonb_build_object('agreementId', new_id, 'versionNo', next_version);
end;
$$;

create or replace function public.get_current_exhibition_agreement(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', definition.id, 'eventId', definition.event_id, 'versionNo', definition.version_no,
    'referenceKey', definition.reference_key, 'content', definition.content,
    'contentHash', definition.content_hash, 'createdAt', definition.created_at
  )
  from public.events event
  join public.exhibition_agreement_definitions definition
    on definition.id = event.current_exhibition_agreement_id and definition.active
  where event.id = p_event_id and event.exhibition_workflow_version = 2
    and (private.is_admin() or (private.is_current_member() and event.published and event.status = 'saved' and event.deleted_at is null))
$$;

alter table public.exhibition_agreement_definitions enable row level security;
alter table public.exhibition_workflow_audit_logs enable row level security;
alter table public.exhibition_deadline_processing enable row level security;

revoke all on public.exhibition_agreement_definitions from anon, authenticated;
revoke all on public.exhibition_workflow_audit_logs from anon, authenticated;
revoke all on public.exhibition_deadline_processing from anon, authenticated;
grant select on public.exhibition_agreement_definitions to authenticated;
grant select on public.exhibition_workflow_audit_logs to authenticated;

create policy exhibition_agreement_admin_or_current_member_select
on public.exhibition_agreement_definitions for select to authenticated using (
  private.is_admin() or (
    active and private.is_current_member() and exists(
      select 1 from public.events event
      where event.id = exhibition_agreement_definitions.event_id
        and event.published and event.status = 'saved'
        and event.deleted_at is null and event.exhibition_workflow_version = 2
    )
  )
);

create policy exhibition_workflow_audit_admin_select
on public.exhibition_workflow_audit_logs for select to authenticated
using (private.is_admin());

revoke all on function public.admin_activate_exhibition_workflow_v2(uuid,timestamptz,timestamptz,timestamptz,timestamptz,text,text,text) from public, anon;
revoke all on function public.admin_update_exhibition_workflow_deadlines(uuid,timestamptz,timestamptz,timestamptz,timestamptz,text) from public, anon;
revoke all on function public.admin_create_exhibition_agreement_definition(uuid,text,text,text) from public, anon;
revoke all on function public.get_current_exhibition_agreement(uuid) from public, anon;
grant execute on function public.admin_activate_exhibition_workflow_v2(uuid,timestamptz,timestamptz,timestamptz,timestamptz,text,text,text) to authenticated;
grant execute on function public.admin_update_exhibition_workflow_deadlines(uuid,timestamptz,timestamptz,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.admin_create_exhibition_agreement_definition(uuid,text,text,text) to authenticated;
grant execute on function public.get_current_exhibition_agreement(uuid) to authenticated;

revoke execute on function private.validate_exhibition_v2_deadlines(timestamptz,timestamptz,timestamptz,timestamptz,boolean) from public, anon, authenticated;
revoke execute on function private.exhibition_deadline_is_open(uuid,text) from public, anon, authenticated;
revoke execute on function private.write_exhibition_workflow_audit(uuid,text,uuid,text,text,text,text,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke execute on function private.mark_exhibition_deadline_processed(uuid,text,timestamptz,jsonb) from public, anon, authenticated;
revoke execute on function private.protect_exhibition_workflow_fields() from public, anon, authenticated;

select
  count(*) filter (where event.genre = 'exhibition' and event.exhibition_workflow_version = 1) as legacy_exhibitions,
  count(*) filter (where event.genre <> 'exhibition' and event.exhibition_workflow_version <> 1) as invalid_general_events,
  to_regclass('public.exhibition_agreement_definitions') is not null as agreement_ready,
  to_regclass('public.exhibition_workflow_audit_logs') is not null as audit_ready,
  to_regprocedure('public.admin_activate_exhibition_workflow_v2(uuid,timestamptz,timestamptz,timestamptz,timestamptz,text,text,text)') is not null as activation_rpc_ready
from public.events event;
