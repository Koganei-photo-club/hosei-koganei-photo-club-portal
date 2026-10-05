-- 写真展Workflow v2 Phase 3: Work submission / review / correction / re-edit / replacement。

alter table public.exhibition_works
  add column if not exists workflow_state text,
  add column if not exists occupied_width_mm numeric(10,2),
  add column if not exists occupied_height_mm numeric(10,2),
  add column if not exists original_sha256 text,
  add column if not exists current_submission_snapshot_id uuid,
  add column if not exists current_accepted_snapshot_id uuid,
  add column if not exists replacement_for_work_id uuid references public.exhibition_works(id) on delete restrict,
  add column if not exists lineage_id uuid,
  add column if not exists correction_rescue_count integer not null default 0,
  add column if not exists reedit_rescue_count integer not null default 0;

alter table public.exhibition_works
  add constraint exhibition_works_v2_state_check check (
    workflow_state is null or workflow_state in
      ('draft','submitted','accepted','rejected','reedit_pending','reedit_editing','withdrawn')
  ),
  add constraint exhibition_works_occupied_width_check check (occupied_width_mm is null or occupied_width_mm>0),
  add constraint exhibition_works_occupied_height_check check (occupied_height_mm is null or occupied_height_mm>0),
  add constraint exhibition_works_original_sha256_check check (
    original_sha256 is null or original_sha256 ~ '^[0-9a-f]{64}$'
  ),
  add constraint exhibition_works_rescue_count_check check (
    correction_rescue_count between 0 and 1 and reedit_rescue_count between 0 and 1
  );

-- LegacyではWork提出時に同じrow上のCaption項目を必須とする。
-- Workflow v2ではWork提出とCaption提出を分離するため、Captionの必須判定は
-- Phase 4の専用workflowへ委ねる。既存triggerはこの置換後の関数を参照する。
create or replace function private.validate_exhibition_work_caption_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.workflow_state is null and new.status in ('submitted', 'accepted') then
    if trim(new.artist_name) = '' then
      raise exception '作者名・ペンネームを入力してください。';
    end if;
    if trim(new.camera_name) = '' then
      raise exception 'Cameraを入力してください。';
    end if;
  end if;

  new.caption = new.description;
  return new;
end;
$$;

alter table public.exhibition_entries
  drop constraint exhibition_entries_application_state_check;
alter table public.exhibition_entries
  add constraint exhibition_entries_application_state_check check (
    application_state is null or application_state in ('draft','active','withdrawn','auto_cancelled')
  ),
  add column if not exists work_auto_cancelled_at timestamptz,
  add column if not exists work_auto_cancel_cause text,
  add column if not exists revival_count integer not null default 0 check (revival_count between 0 and 1),
  add column if not exists revival_deadline timestamptz;

create table public.exhibition_work_submission_batches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  submitted_by_identifier text not null,
  submitted_at timestamptz not null default now()
);

create table public.exhibition_work_submission_snapshots (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.exhibition_work_submission_batches(id) on delete restrict,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  original_image_path text not null check(trim(original_image_path)<>''),
  original_sha256 text not null check(original_sha256 ~ '^[0-9a-f]{64}$'),
  title text not null check(trim(title)<>''),
  orientation text not null check(orientation in ('portrait','landscape')),
  print_size text not null check(print_size in ('A4','A3','A2','composite','other')),
  print_size_detail text not null default '',
  occupied_width_mm numeric(10,2) not null check(occupied_width_mm>0),
  occupied_height_mm numeric(10,2) not null check(occupied_height_mm>0),
  publication_consent boolean not null,
  submitted_at timestamptz not null default now(),
  submitted_by_member_id uuid not null references public.members(id) on delete restrict,
  submitted_by_identifier text not null,
  unique(work_id,version_no),
  check(submitted_by_member_id=member_id)
);

alter table public.exhibition_works
  add constraint exhibition_works_current_submission_fk foreign key(current_submission_snapshot_id)
    references public.exhibition_work_submission_snapshots(id) on delete restrict,
  add constraint exhibition_works_current_accepted_fk foreign key(current_accepted_snapshot_id)
    references public.exhibition_work_submission_snapshots(id) on delete restrict;

create table public.exhibition_work_reviews (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  reviewer_identifier text not null,
  result text not null check(result in ('accepted','rejected')),
  problem_fields text[] not null default '{}',
  reason text not null default '',
  reviewed_at timestamptz not null default now(),
  unique(submission_snapshot_id),
  check(result='accepted' or (cardinality(problem_fields)>0 and trim(reason)<>'')),
  check(problem_fields <@ array['original','title','orientation','print_size','physical_dimensions','publication_consent','other']::text[])
);

create table public.exhibition_workflow_cases (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  case_type text not null check(case_type in ('correction','reedit')),
  source_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  source_review_id uuid references public.exhibition_work_reviews(id) on delete restrict,
  state text not null check(state in ('pending','open','permitted','rejected','cancelled','resubmitted','expired','withdrawn','restored')),
  request_reason text not null default '',
  decision_reason text not null default '',
  individual_deadline timestamptz,
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  closed_at timestamptz
);

create unique index exhibition_workflow_cases_one_open
  on public.exhibition_workflow_cases(work_id)
  where state in ('pending','open','permitted');
create unique index exhibition_correction_case_per_review
  on public.exhibition_workflow_cases(source_review_id) where case_type='correction';

create index exhibition_work_snapshots_work_idx on public.exhibition_work_submission_snapshots(work_id,version_no desc);
create index exhibition_work_cases_deadline_idx on public.exhibition_workflow_cases(state,individual_deadline);

create or replace function private.prevent_exhibition_work_history_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Workの正式履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_work_snapshots_immutable before update or delete on public.exhibition_work_submission_snapshots
for each row execute function private.prevent_exhibition_work_history_mutation();
create trigger exhibition_work_reviews_immutable before update or delete on public.exhibition_work_reviews
for each row execute function private.prevent_exhibition_work_history_mutation();
create trigger exhibition_work_batches_immutable before update or delete on public.exhibition_work_submission_batches
for each row execute function private.prevent_exhibition_work_history_mutation();

create or replace function private.sync_v2_entry_extended_state()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.application_state='auto_cancelled' then new.status:='withdrawn'; end if;
  return new;
end;
$$;
create trigger zz_exhibition_entries_sync_v2_extended_state
before insert or update on public.exhibition_entries
for each row execute function private.sync_v2_entry_extended_state();

-- SYSTEM取消後は、通常のApplication保存/再申込RPCでは復活させない。
-- 管理者revival RPCだけが専用のtransaction-local flagを設定する。
create or replace function private.protect_v2_auto_cancelled_entry()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.application_state='auto_cancelled'
     and new.application_state is distinct from old.application_state
     and coalesce(current_setting('app.exhibition_entry_revival_rpc',true),'')<>'on' then
    raise exception '自動取消されたApplicationは管理者のRevival操作でのみ復活できます。';
  end if;
  return new;
end;
$$;
create trigger zzy_exhibition_entries_protect_auto_cancelled
before update on public.exhibition_entries
for each row execute function private.protect_v2_auto_cancelled_entry();

create or replace function private.exhibition_work_edit_deadline_open(p_work public.exhibition_works,p_event public.events)
returns boolean language sql stable security definer set search_path='' as $$
  select case
    when p_work.workflow_state in ('rejected','reedit_editing') then exists(
      select 1 from public.exhibition_workflow_cases c where c.work_id=p_work.id
        and c.state in ('open','permitted') and now()<c.individual_deadline
    )
    else now()<p_event.exhibition_work_submission_deadline
      or (exists(select 1 from public.exhibition_entries e where e.id=p_work.entry_id
        and e.application_state='active' and e.revival_deadline is not null and now()<e.revival_deadline))
  end
$$;

create or replace function private.exhibition_work_is_viable(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.exhibition_works w join public.events e on e.id=w.event_id
    where w.id=p_work_id and e.exhibition_workflow_version=2 and w.workflow_state<>'withdrawn' and (
      w.workflow_state in ('submitted','accepted','reedit_pending')
      or (w.workflow_state='draft' and private.exhibition_work_edit_deadline_open(w,e))
      or (w.workflow_state in ('rejected','reedit_editing') and private.exhibition_work_edit_deadline_open(w,e))
    )
  )
$$;

create or replace function private.auto_cancel_v2_entry_if_no_viable(p_entry_id uuid,p_cause text)
returns boolean language plpgsql security definer set search_path='' as $$
declare target public.exhibition_entries%rowtype;
begin
  select * into target from public.exhibition_entries where id=p_entry_id for update;
  if target.id is null or target.application_state<>'active' then return false; end if;
  if exists(select 1 from public.exhibition_works w where w.entry_id=p_entry_id and private.exhibition_work_is_viable(w.id)) then return false; end if;
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set application_state='auto_cancelled',status='withdrawn',
    work_auto_cancelled_at=now(),work_auto_cancel_cause=p_cause,application_updated_at=now() where id=p_entry_id;
  perform set_config('app.exhibition_application_rpc','off',true);
  perform private.write_exhibition_workflow_audit(target.event_id,'application',target.id,'entry_auto_cancelled','system','system',p_cause,
    jsonb_build_object('applicationState','active'),jsonb_build_object('applicationState','auto_cancelled'));
  return true;
end;
$$;

-- v1の既存trigger条件を維持し、v2は専用RPC以外の書込みを拒否する。
create or replace function private.validate_exhibition_work()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_entry public.exhibition_entries%rowtype; target_event public.events%rowtype; work_count integer;
  rpc_authorized boolean:=coalesce(current_setting('app.exhibition_work_rpc',true),'')='on';
begin
  select * into target_entry from public.exhibition_entries where id=new.entry_id;
  if target_entry.id is null then raise exception '出展申込が見つかりません。'; end if;
  new.event_id:=target_entry.event_id; new.owner_member_id:=target_entry.member_id;
  select * into target_event from public.events where id=target_entry.event_id;
  if target_event.exhibition_workflow_version=2 then
    if not rpc_authorized then raise exception 'Workflow v2のWorkは専用操作から変更してください。'; end if;
    if new.workflow_state is null then raise exception 'Workflow v2 Work stateがありません。'; end if;
    new.status:=case new.workflow_state when 'accepted' then 'accepted' when 'rejected' then 'rejected'
      when 'withdrawn' then 'withdrawn' when 'draft' then 'draft' else 'submitted' end;
    return new;
  end if;
  if new.workflow_state is not null or new.current_submission_snapshot_id is not null
     or new.current_accepted_snapshot_id is not null or new.replacement_for_work_id is not null then
    raise exception 'Legacy WorkではWorkflow v2項目を使用できません。';
  end if;
  if not private.is_admin() then
    if target_entry.member_id<>private.current_member_id() then raise exception '本人以外の作品は登録できません。'; end if;
    if not private.is_available_exhibition_event(target_entry.event_id) then raise exception 'この写真展は現在作品を受け付けていません。'; end if;
    if new.status not in ('draft','submitted','withdrawn') then raise exception '作品の審査状態は管理者のみ変更できます。'; end if;
    if trim(new.display_no)<>'' or new.public_release or new.public_image_path is not null or new.legacy_work_uuid is not null then
      raise exception '作品番号、公開状態、移行情報は管理者のみ設定できます。';
    end if;
    if tg_op='UPDATE' and (new.owner_member_id is distinct from old.owner_member_id or new.event_id is distinct from old.event_id or new.entry_id is distinct from old.entry_id) then
      raise exception '作品の所有者、対象写真展、出展申込は変更できません。';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(target_entry.id::text,0));
  select count(*) into work_count from public.exhibition_works w where w.entry_id=target_entry.id and w.id<>new.id and w.status<>'withdrawn';
  if new.status<>'withdrawn' and work_count>=target_event.max_works then raise exception 'この写真展の出展可能作品数を超えています。'; end if;
  if new.status='submitted' then
    if trim(new.title)='' then raise exception '作品名を入力してください。'; end if;
    if new.original_image_path is null then raise exception '原画像を登録してください。'; end if;
    if new.submitted_at is null then new.submitted_at:=now(); end if;
  elsif new.status='draft' then new.submitted_at:=null; end if;
  return new;
end;
$$;

-- v2はversioned keyを許可し、v1の既存命名規則は維持する。
create or replace function private.validate_exhibition_work_print_specifications()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_entry public.exhibition_entries%rowtype; target_event public.events%rowtype;
  target_member public.members%rowtype; changed boolean; actual text; ext text; expected text;
begin
  select * into target_entry from public.exhibition_entries where id=new.entry_id;
  select * into target_event from public.events where id=target_entry.event_id;
  if new.status in ('submitted','accepted') then
    if new.orientation not in ('portrait','landscape') then raise exception '作品の向きを選択してください。'; end if;
    if new.print_size not in ('A4','A3','A2','composite','other') then raise exception '出展サイズを選択してください。'; end if;
    if new.print_size in ('composite','other') and trim(new.print_size_detail)='' then raise exception '組み写真・その他のサイズ詳細を入力してください。'; end if;
  end if;
  if target_event.exhibition_workflow_version=2 then return new; end if;
  changed:=tg_op='INSERT' or (tg_op='UPDATE' and new.original_image_path is distinct from old.original_image_path);
  if new.original_image_path is not null and changed then
    select * into target_member from public.members where id=target_entry.member_id;
    actual:=regexp_replace(new.original_image_path,'^.*/',''); ext:=lower(regexp_replace(actual,'^.*\.',''));
    expected:=regexp_replace(target_member.member_no,'[^A-Za-z0-9_-]','_','g')||'_work-'||new.sort_order::text||'.'||ext;
    if actual<>expected then raise exception '原画像の内部保存名は「%」にしてください。',expected; end if;
  end if;
  return new;
end;
$$;

create or replace function private.validate_v2_work_values(p_work public.exhibition_works)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if trim(p_work.title)='' then raise exception '作品名を入力してください。'; end if;
  if p_work.original_image_path is null or p_work.original_sha256 is null then raise exception '原画像とSHA-256 hashが必要です。'; end if;
  if split_part(p_work.original_image_path,'/',1)<>p_work.event_id::text
     or split_part(p_work.original_image_path,'/',2)<>p_work.owner_member_id::text
     or split_part(p_work.original_image_path,'/',3)<>p_work.id::text
     or split_part(p_work.original_image_path,'/',4)=''
     or split_part(p_work.original_image_path,'/',5)<>'' then
    raise exception '原画像のStorage pathがこのWorkに属していません。';
  end if;
  if p_work.orientation not in ('portrait','landscape') then raise exception '作品の向きを選択してください。'; end if;
  if p_work.print_size not in ('A4','A3','A2','composite','other') then raise exception '出展サイズを選択してください。'; end if;
  if p_work.print_size in ('composite','other') and trim(coalesce(p_work.print_size_detail,''))='' then
    raise exception '組み写真・その他のサイズ詳細を入力してください。';
  end if;
  if p_work.occupied_width_mm is null or p_work.occupied_height_mm is null then raise exception '作品が占有する幅と高さを入力してください。'; end if;
  if p_work.publication_consent is null then raise exception '写真展サイトへの掲載可否を選択してください。'; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='exhibition-originals' and o.name=p_work.original_image_path) then
    raise exception '原画像がStorageに見つかりません。';
  end if;
end;
$$;

create or replace function public.save_exhibition_work_draft_v2(
  p_event_id uuid,p_work_id uuid,p_title text,p_orientation text,p_print_size text,p_print_size_detail text,
  p_occupied_width_mm numeric,p_occupied_height_mm numeric,p_publication_consent boolean,
  p_original_image_path text,p_original_sha256 text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; en public.exhibition_entries%rowtype; w public.exhibition_works%rowtype;
  mid uuid:=private.current_member_id(); next_slot integer; logical_count integer; actor text:=private.current_email();
begin
  if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into e from public.events where id=p_event_id for update;
  select * into en from public.exhibition_entries where event_id=p_event_id and member_id=mid for update;
  if e.exhibition_workflow_version<>2 or en.application_state<>'active' then raise exception '有効なApplicationが必要です。'; end if;
  if p_work_id is null then
    if not coalesce(private.exhibition_deadline_is_open(p_event_id,'work_submission'),false)
       and not (en.revival_deadline is not null and now()<en.revival_deadline) then raise exception '作品提出締切を過ぎています。'; end if;
    select count(*) into logical_count from public.exhibition_works x where x.entry_id=en.id and x.workflow_state<>'withdrawn'
      and not exists(select 1 from public.exhibition_works r where r.replacement_for_work_id=x.id and r.workflow_state<>'withdrawn');
    if logical_count>=e.max_works then raise exception '出展可能作品数を超えています。'; end if;
    select coalesce(max(sort_order),0)+1 into next_slot from public.exhibition_works where entry_id=en.id;
    perform set_config('app.exhibition_work_rpc','on',true);
    insert into public.exhibition_works(id,entry_id,event_id,owner_member_id,sort_order,title,orientation,print_size,print_size_detail,
      occupied_width_mm,occupied_height_mm,publication_consent,original_image_path,original_sha256,status,workflow_state,lineage_id)
    values(gen_random_uuid(),en.id,p_event_id,mid,next_slot,trim(coalesce(p_title,'')),coalesce(p_orientation,''),coalesce(p_print_size,''),coalesce(p_print_size_detail,''),
      p_occupied_width_mm,p_occupied_height_mm,p_publication_consent,p_original_image_path,lower(p_original_sha256),'draft','draft',gen_random_uuid()) returning * into w;
    perform set_config('app.exhibition_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'work_draft_created','member',actor,'','{}',jsonb_build_object('workId',w.id));
  else
    select * into w from public.exhibition_works where id=p_work_id and event_id=p_event_id and owner_member_id=mid for update;
    if w.id is null or w.workflow_state not in ('draft','rejected','reedit_editing') then raise exception '編集可能なWorkではありません。'; end if;
    if not private.exhibition_work_edit_deadline_open(w,e) then raise exception '編集期限を過ぎています。'; end if;
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works set title=trim(coalesce(p_title,'')),orientation=coalesce(p_orientation,''),print_size=coalesce(p_print_size,''),
      print_size_detail=coalesce(p_print_size_detail,''),occupied_width_mm=p_occupied_width_mm,occupied_height_mm=p_occupied_height_mm,
      publication_consent=p_publication_consent,original_image_path=p_original_image_path,original_sha256=lower(p_original_sha256),updated_at=now()
    where id=w.id returning * into w;
    perform set_config('app.exhibition_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'work_draft_saved','member',actor,'','{}',jsonb_build_object('workflowState',w.workflow_state));
  end if;
  return to_jsonb(w);
end;
$$;

create or replace function public.submit_exhibition_work_batch_v2(p_event_id uuid,p_work_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; en public.exhibition_entries%rowtype; w public.exhibition_works%rowtype;
  snap public.exhibition_work_submission_snapshots%rowtype; batch_id uuid; next_version integer;
  submitted_ids uuid[]:='{}'; incomplete_ids uuid[]:='{}'; actor text:=private.current_email(); mid uuid:=private.current_member_id(); case_row public.exhibition_workflow_cases%rowtype;
begin
  if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  if coalesce(cardinality(p_work_ids),0)=0 then raise exception '提出対象を選択してください。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into e from public.events where id=p_event_id for update;
  select * into en from public.exhibition_entries where event_id=p_event_id and member_id=mid for update;
  if e.exhibition_workflow_version<>2 or en.application_state<>'active' then raise exception '有効なApplicationが必要です。'; end if;
  insert into public.exhibition_work_submission_batches(event_id,entry_id,member_id,submitted_by_identifier)
    values(p_event_id,en.id,mid,actor) returning id into batch_id;
  for w in select * from public.exhibition_works where id=any(p_work_ids) and event_id=p_event_id and owner_member_id=mid order by sort_order for update loop
    if w.workflow_state not in ('draft','rejected','reedit_editing') or not private.exhibition_work_edit_deadline_open(w,e) then
      incomplete_ids:=array_append(incomplete_ids,w.id); continue;
    end if;
    begin perform private.validate_v2_work_values(w);
    exception when others then incomplete_ids:=array_append(incomplete_ids,w.id); continue; end;
    if w.workflow_state='reedit_editing' and not exists(
      select 1 from public.exhibition_workflow_cases rc
      join public.exhibition_work_submission_snapshots old on old.id=rc.source_submission_snapshot_id
      where rc.work_id=w.id and rc.case_type='reedit' and rc.state='permitted' and (
        old.original_sha256<>w.original_sha256 or old.title<>trim(w.title) or old.orientation<>w.orientation
        or old.print_size<>w.print_size or old.print_size_detail<>w.print_size_detail
        or old.occupied_width_mm<>w.occupied_width_mm or old.occupied_height_mm<>w.occupied_height_mm
        or old.publication_consent<>w.publication_consent)) then
      incomplete_ids:=array_append(incomplete_ids,w.id); continue;
    end if;
    select coalesce(max(version_no),0)+1 into next_version from public.exhibition_work_submission_snapshots where work_id=w.id;
    insert into public.exhibition_work_submission_snapshots(batch_id,work_id,entry_id,event_id,member_id,version_no,
      original_image_path,original_sha256,title,orientation,print_size,print_size_detail,occupied_width_mm,occupied_height_mm,
      publication_consent,submitted_by_member_id,submitted_by_identifier)
    values(batch_id,w.id,w.entry_id,w.event_id,w.owner_member_id,next_version,w.original_image_path,w.original_sha256,trim(w.title),w.orientation,
      w.print_size,w.print_size_detail,w.occupied_width_mm,w.occupied_height_mm,w.publication_consent,mid,actor) returning * into snap;
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works set workflow_state='submitted',status='submitted',current_submission_snapshot_id=snap.id,
      submitted_at=now(),updated_at=now() where id=w.id;
    if w.replacement_for_work_id is not null then
      update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.replacement_for_work_id;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'replacement_submitted','member',actor,'','{}',jsonb_build_object('replacedWorkId',w.replacement_for_work_id));
    end if;
    perform set_config('app.exhibition_work_rpc','off',true);
    select * into case_row from public.exhibition_workflow_cases where work_id=w.id and state in ('open','permitted') for update;
    if case_row.id is not null then
      update public.exhibition_workflow_cases set state='resubmitted',closed_at=now() where id=case_row.id;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,
        case when case_row.case_type='correction' then 'correction_resubmitted' else 'reedit_resubmitted' end,'member',actor,'','{}',jsonb_build_object('snapshotId',snap.id));
    end if;
    submitted_ids:=array_append(submitted_ids,w.id);
    perform private.write_exhibition_workflow_audit(p_event_id,'work_submission_snapshot',snap.id,'work_submitted','member',actor,'','{}',jsonb_build_object('workId',w.id,'batchId',batch_id,'versionNo',next_version));
  end loop;
  if cardinality(submitted_ids)=0 then raise exception '提出可能な作品がありません。'; end if;
  perform private.write_exhibition_workflow_audit(p_event_id,'submission_batch',batch_id,'submission_batch_created','member',actor,'','{}',jsonb_build_object('submittedWorkIds',submitted_ids,'incompleteWorkIds',incomplete_ids));
  return jsonb_build_object('batchId',batch_id,'submittedWorkIds',submitted_ids,'incompleteWorkIds',incomplete_ids);
end;
$$;

create or replace function public.admin_review_exhibition_work_v2(
  p_submission_snapshot_id uuid,p_result text,p_problem_fields text[],p_reason text,p_individual_deadline timestamptz default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.exhibition_work_submission_snapshots%rowtype; w public.exhibition_works%rowtype;
  e public.events%rowtype; review_id uuid; deadline timestamptz; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_result not in ('accepted','rejected') then raise exception 'Review結果が不正です。'; end if;
  if p_result='rejected' and (coalesce(cardinality(p_problem_fields),0)=0 or trim(coalesce(p_reason,''))='') then
    raise exception 'Rejectには問題項目と理由が必要です。';
  end if;
  select * into s from public.exhibition_work_submission_snapshots where id=p_submission_snapshot_id;
  if s.id is null then raise exception 'Submission Snapshotが見つかりません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(s.event_id::text,0));
  select * into w from public.exhibition_works where id=s.work_id for update;
  select * into e from public.events where id=s.event_id for update;
  if e.exhibition_workflow_version<>2 or w.current_submission_snapshot_id is distinct from s.id or w.workflow_state<>'submitted' then
    raise exception 'Review対象が古いか、すでに処理済みです。';
  end if;
  if exists(select 1 from public.exhibition_work_reviews where submission_snapshot_id=s.id) then raise exception 'このSnapshotはすでにReview済みです。'; end if;
  if p_result='rejected' then
    deadline:=case when now()<e.exhibition_revision_deadline then e.exhibition_revision_deadline else p_individual_deadline end;
    if deadline is null or deadline<=now() then raise exception 'Revision期限後のRejectには未来のIndividual Deadlineが必要です。'; end if;
  end if;
  insert into public.exhibition_work_reviews(work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(w.id,s.id,actor,p_result,coalesce(p_problem_fields,'{}'),coalesce(p_reason,'')) returning id into review_id;
  perform set_config('app.exhibition_work_rpc','on',true);
  if p_result='accepted' then
    update public.exhibition_works set workflow_state='accepted',status='accepted',current_accepted_snapshot_id=s.id,updated_at=now() where id=w.id;
  else
    update public.exhibition_works set workflow_state='rejected',status='rejected',updated_at=now() where id=w.id;
    insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
      values(w.id,w.event_id,w.owner_member_id,'correction',s.id,review_id,'open',p_reason,deadline,now());
  end if;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work_review',review_id,
    case when p_result='accepted' then 'work_accepted' else 'work_rejected' end,'admin',actor,p_reason,
    jsonb_build_object('submissionSnapshotId',s.id),jsonb_build_object('result',p_result,'problemFields',coalesce(p_problem_fields,'{}'),'deadline',deadline));
  return jsonb_build_object('reviewId',review_id,'workId',w.id,'result',p_result,'correctionDeadline',deadline);
end;
$$;

create or replace function public.request_exhibition_work_reedit_v2(p_work_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; case_id uuid; actor text:=private.current_email(); mid uuid:=private.current_member_id();
begin
  if trim(coalesce(p_reason,''))='' then raise exception '再編集申請理由は必須です。'; end if;
  select * into w from public.exhibition_works where id=p_work_id and owner_member_id=mid for update;
  if w.id is null or w.workflow_state<>'accepted' or w.current_accepted_snapshot_id is null then raise exception '確認済みWorkが見つかりません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(w.event_id::text,0));
  if exists(select 1 from public.exhibition_workflow_cases where work_id=w.id and state in ('pending','open','permitted')) then raise exception '未完了のCaseがあります。'; end if;
  insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,state,request_reason)
    values(w.id,w.event_id,w.owner_member_id,'reedit',w.current_accepted_snapshot_id,'pending',p_reason) returning id into case_id;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='reedit_pending',updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work_case',case_id,'reedit_requested','member',actor,p_reason,'{}',jsonb_build_object('workId',w.id));
  return jsonb_build_object('caseId',case_id,'state','pending');
end;
$$;

create or replace function public.cancel_exhibition_work_reedit_request_v2(p_case_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_workflow_cases%rowtype; w public.exhibition_works%rowtype; actor text:=private.current_email();
begin
  select * into c from public.exhibition_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'pending' then raise exception '取消可能な再編集申請がありません。'; end if;
  select * into w from public.exhibition_works where id=c.work_id for update;
  update public.exhibition_workflow_cases set state='cancelled',closed_at=now() where id=c.id;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='accepted',status='accepted',updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work_case',c.id,'reedit_request_cancelled','member',actor,'','{}','{}');
  return jsonb_build_object('caseId',c.id,'state','cancelled');
end;
$$;

create or replace function public.admin_decide_exhibition_work_reedit_v2(
  p_case_id uuid,p_permit boolean,p_reason text,p_individual_deadline timestamptz default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_workflow_cases%rowtype; w public.exhibition_works%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '判断理由は必須です。'; end if;
  select * into c from public.exhibition_workflow_cases where id=p_case_id for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'pending' then raise exception '処理可能な再編集申請がありません。'; end if;
  select * into w from public.exhibition_works where id=c.work_id for update;
  if w.workflow_state<>'reedit_pending' or w.current_accepted_snapshot_id is distinct from c.source_submission_snapshot_id then raise exception '再編集申請が古くなっています。'; end if;
  if p_permit and (p_individual_deadline is null or p_individual_deadline<=now()) then raise exception '許可には未来のIndividual Deadlineが必要です。'; end if;
  update public.exhibition_workflow_cases set state=case when p_permit then 'permitted' else 'rejected' end,
    decision_reason=p_reason,individual_deadline=case when p_permit then p_individual_deadline else null end,
    decided_at=now(),closed_at=case when p_permit then null else now() end where id=c.id;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state=case when p_permit then 'reedit_editing' else 'accepted' end,
    status=case when p_permit then 'submitted' else 'accepted' end,
    current_accepted_snapshot_id=case when p_permit then null else current_accepted_snapshot_id end,updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work_case',c.id,
    case when p_permit then 'reedit_permitted' else 'reedit_rejected' end,'admin',actor,p_reason,'{}',jsonb_build_object('deadline',p_individual_deadline));
  return jsonb_build_object('caseId',c.id,'state',case when p_permit then 'permitted' else 'rejected' end);
end;
$$;

create or replace function public.cancel_permitted_exhibition_work_reedit_v2(p_case_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_workflow_cases%rowtype; w public.exhibition_works%rowtype; s public.exhibition_work_submission_snapshots%rowtype; actor text:=private.current_email();
begin
  select * into c from public.exhibition_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'permitted' then raise exception '取りやめ可能な再編集Caseがありません。'; end if;
  select * into w from public.exhibition_works where id=c.work_id for update;
  select * into s from public.exhibition_work_submission_snapshots where id=c.source_submission_snapshot_id;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set title=s.title,orientation=s.orientation,print_size=s.print_size,print_size_detail=s.print_size_detail,
    occupied_width_mm=s.occupied_width_mm,occupied_height_mm=s.occupied_height_mm,publication_consent=s.publication_consent,
    original_image_path=s.original_image_path,original_sha256=s.original_sha256,workflow_state='accepted',status='accepted',
    current_submission_snapshot_id=s.id,current_accepted_snapshot_id=s.id,updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  update public.exhibition_workflow_cases set state='restored',closed_at=now() where id=c.id;
  perform private.write_exhibition_workflow_audit(w.event_id,'work_case',c.id,'reedit_cancelled_restored','member',actor,coalesce(p_reason,''),'{}',jsonb_build_object('restoredSnapshotId',s.id));
  return jsonb_build_object('workId',w.id,'restoredSnapshotId',s.id);
end;
$$;

create or replace function public.withdraw_exhibition_work_v2(p_work_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; e public.events%rowtype; actor text:=private.current_email();
begin
  select * into w from public.exhibition_works where id=p_work_id and owner_member_id=private.current_member_id() for update;
  if w.id is null or w.workflow_state='withdrawn' then raise exception '取り下げ可能なWorkがありません。'; end if;
  select * into e from public.events where id=w.event_id;
  if e.exhibition_workflow_version<>2 or not coalesce(private.exhibition_deadline_is_open(w.event_id,'work_submission'),false) then raise exception '作品提出締切後は本人による取り下げができません。'; end if;
  if w.workflow_state='accepted' and trim(coalesce(p_reason,''))='' then raise exception '確認済みWorkの取り下げ理由は必須です。'; end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  update public.exhibition_workflow_cases set state='withdrawn',closed_at=now() where work_id=w.id and state in ('pending','open','permitted');
  perform private.write_exhibition_workflow_audit(w.event_id,'work',w.id,'work_withdrawn','member',actor,coalesce(p_reason,''),'{}',jsonb_build_object('previousState',w.workflow_state));
  perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'work_withdrawal_no_viable_work');
  return jsonb_build_object('workId',w.id,'state','withdrawn');
end;
$$;

create or replace function public.start_exhibition_work_replacement_v2(p_old_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare oldw public.exhibition_works%rowtype; neww public.exhibition_works%rowtype; e public.events%rowtype; actor text:=private.current_email(); next_slot integer;
begin
  select * into oldw from public.exhibition_works where id=p_old_work_id and owner_member_id=private.current_member_id() for update;
  if oldw.id is null or oldw.workflow_state='withdrawn' then raise exception '差し替え元Workがありません。'; end if;
  select * into e from public.events where id=oldw.event_id;
  if e.exhibition_workflow_version<>2 or not coalesce(private.exhibition_deadline_is_open(oldw.event_id,'work_submission'),false) then raise exception '作品提出締切後はReplacementできません。'; end if;
  if exists(select 1 from public.exhibition_works where replacement_for_work_id=oldw.id and workflow_state<>'withdrawn') then raise exception '進行中のReplacementがあります。'; end if;
  select coalesce(max(sort_order),0)+1 into next_slot from public.exhibition_works where entry_id=oldw.entry_id;
  perform set_config('app.exhibition_work_rpc','on',true);
  insert into public.exhibition_works(entry_id,event_id,owner_member_id,sort_order,status,workflow_state,replacement_for_work_id,lineage_id)
    values(oldw.entry_id,oldw.event_id,oldw.owner_member_id,next_slot,'draft','draft',oldw.id,oldw.lineage_id) returning * into neww;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(oldw.event_id,'work',neww.id,'replacement_started','member',actor,'','{}',jsonb_build_object('oldWorkId',oldw.id));
  return jsonb_build_object('oldWorkId',oldw.id,'replacementWorkId',neww.id);
end;
$$;

create or replace function public.cancel_exhibition_work_replacement_v2(p_replacement_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; actor text:=private.current_email();
begin
  select * into w from public.exhibition_works where id=p_replacement_work_id and owner_member_id=private.current_member_id() for update;
  if w.id is null or w.replacement_for_work_id is null or w.workflow_state<>'draft' or w.current_submission_snapshot_id is not null then raise exception '取消可能なReplacement Draftがありません。'; end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'work',w.id,'replacement_cancelled','member',actor,'','{}',jsonb_build_object('oldWorkId',w.replacement_for_work_id));
  return jsonb_build_object('replacementWorkId',w.id,'state','withdrawn');
end;
$$;

create or replace function public.admin_withdraw_exhibition_work_v2(p_work_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '管理者取り下げ理由は必須です。'; end if;
  select * into w from public.exhibition_works where id=p_work_id for update;
  if w.id is null or w.workflow_state='withdrawn' then raise exception '取り下げ可能なWorkがありません。'; end if;
  if not exists(select 1 from public.events where id=w.event_id and exhibition_workflow_version=2) then raise exception 'Workflow v2 Workではありません。'; end if;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id;
  perform set_config('app.exhibition_work_rpc','off',true);
  update public.exhibition_workflow_cases set state='withdrawn',closed_at=now() where work_id=w.id and state in ('pending','open','permitted');
  perform private.write_exhibition_workflow_audit(w.event_id,'work',w.id,'work_withdrawn','admin',actor,p_reason,'{}',jsonb_build_object('previousState',w.workflow_state));
  perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'admin_work_withdrawal_no_viable_work');
  return jsonb_build_object('workId',w.id,'state','withdrawn');
end;
$$;

create or replace function public.admin_revive_exhibition_entry_v2(p_entry_id uuid,p_reason text,p_exception_deadline timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare en public.exhibition_entries%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Revival理由は必須です。'; end if;
  if p_exception_deadline is null or p_exception_deadline<=now() then raise exception '未来のException Submission Deadlineが必要です。'; end if;
  select * into en from public.exhibition_entries where id=p_entry_id for update;
  if en.id is null or en.application_state<>'auto_cancelled' or en.revival_count>=1 then raise exception 'このEntryはreviveできません。'; end if;
  perform set_config('app.exhibition_entry_revival_rpc','on',true);
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set application_state='active',status='submitted',revival_count=1,
    revival_deadline=p_exception_deadline,application_updated_at=now() where id=en.id;
  perform set_config('app.exhibition_application_rpc','off',true);
  perform set_config('app.exhibition_entry_revival_rpc','off',true);
  perform private.write_exhibition_workflow_audit(en.event_id,'application',en.id,'entry_revived','admin',actor,p_reason,
    jsonb_build_object('applicationState','auto_cancelled'),jsonb_build_object('applicationState','active','exceptionDeadline',p_exception_deadline));
  return jsonb_build_object('entryId',en.id,'revivalCount',1,'exceptionDeadline',p_exception_deadline);
end;
$$;

create or replace function public.admin_process_exhibition_work_deadlines_v2(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; w public.exhibition_works%rowtype; en public.exhibition_entries%rowtype;
  work_withdrawn integer:=0; entries_cancelled integer:=0; cases_expired integer:=0; first_processing boolean;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then
    raise exception '管理者またはSYSTEM実行権限がありません。';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into e from public.events where id=p_event_id for update;
  if e.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  if now()>=e.exhibition_work_submission_deadline then
    first_processing:=private.mark_exhibition_deadline_processed(p_event_id,'work_submission',e.exhibition_work_submission_deadline,jsonb_build_object('processor','admin_rpc'));
    for w in
      select x.* from public.exhibition_works x join public.exhibition_entries owner_entry on owner_entry.id=x.entry_id
      where x.event_id=p_event_id and x.workflow_state='draft'
        and not (owner_entry.revival_deadline is not null and now()<owner_entry.revival_deadline)
      for update of x
    loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'system_deadline_work_withdrawn','system','system','work_submission_deadline','{}','{}');
    end loop;
    for en in select * from public.exhibition_entries where event_id=p_event_id and application_state='active'
      and not (revival_deadline is not null and now()<revival_deadline) for update loop
      if not exists(select 1 from public.exhibition_work_submission_snapshots s where s.entry_id=en.id) then
        if private.auto_cancel_v2_entry_if_no_viable(en.id,'zero_formal_work_at_submission_deadline') then entries_cancelled:=entries_cancelled+1; end if;
      end if;
    end loop;
  end if;
  for w in
    select x.* from public.exhibition_works x join public.exhibition_workflow_cases c on c.work_id=x.id
    where x.event_id=p_event_id and c.state in ('open','permitted') and c.individual_deadline<=now() for update of x
  loop
    update public.exhibition_workflow_cases set state='expired',closed_at=now() where work_id=w.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_work_rpc','off',true);
    if found then
      cases_expired:=cases_expired+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'system_case_deadline_withdrawn','system','system','individual_deadline_expired','{}','{}');
      perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'case_deadline_no_viable_work');
    end if;
  end loop;
  for en in select * from public.exhibition_entries where event_id=p_event_id and application_state='active' and revival_deadline is not null and revival_deadline<=now() for update loop
    for w in select * from public.exhibition_works where entry_id=en.id and workflow_state='draft' for update loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=w.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',w.id,'system_deadline_work_withdrawn','system','system','revival_deadline','{}','{}');
    end loop;
    if private.auto_cancel_v2_entry_if_no_viable(en.id,'revival_deadline_expired') then
      entries_cancelled:=entries_cancelled+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'application',en.id,'entry_revival_expired','system','system','revival_deadline_expired','{}','{}');
    end if;
  end loop;
  return jsonb_build_object('draftWorksWithdrawn',work_withdrawn,'casesExpired',cases_expired,'entriesAutoCancelled',entries_cancelled);
end;
$$;

-- event.max_worksを既存logical slot数未満へ縮小させない。
create or replace function private.protect_v2_event_max_works()
returns trigger language plpgsql security definer set search_path='' as $$
declare occupied integer;
begin
  if tg_op='UPDATE' and old.exhibition_workflow_version=2 and new.max_works<old.max_works then
    select coalesce(max(slot_count),0) into occupied from (
      select count(*) as slot_count from public.exhibition_works w where w.event_id=old.id and w.workflow_state<>'withdrawn'
        and not exists(select 1 from public.exhibition_works r where r.replacement_for_work_id=w.id and r.workflow_state<>'withdrawn') group by w.entry_id
    ) counts;
    if new.max_works<occupied then raise exception '現在のlogical active slots未満へ出展上限を減らせません。'; end if;
  end if;
  return new;
end;
$$;
create trigger protect_v2_event_max_works_before_update before update of max_works on public.events
for each row execute function private.protect_v2_event_max_works();

-- Snapshotが参照するoriginalはMemberによるUPDATE/DELETEを拒否する。v1は従来条件。
create or replace function private.current_member_can_write_exhibition_object_path(target_path text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.exhibition_works w join public.events e on e.id=w.event_id
    where w.event_id::text=split_part(target_path,'/',1) and w.owner_member_id::text=split_part(target_path,'/',2)
      and w.id::text=split_part(target_path,'/',3) and w.owner_member_id=private.current_member_id()
      and split_part(target_path,'/',4)<>'' and split_part(target_path,'/',5)=''
      and private.is_current_member()
      and not exists(select 1 from public.exhibition_work_submission_snapshots s where s.original_image_path=target_path)
      and (
        (e.exhibition_workflow_version=1 and private.is_available_exhibition_event(w.event_id))
        or (e.exhibition_workflow_version=2 and exists(select 1 from public.exhibition_entries en where en.id=w.entry_id and en.application_state='active')
          and private.exhibition_work_edit_deadline_open(w,e))
      )
  )
$$;

alter table public.exhibition_work_submission_batches enable row level security;
alter table public.exhibition_work_submission_snapshots enable row level security;
alter table public.exhibition_work_reviews enable row level security;
alter table public.exhibition_workflow_cases enable row level security;
revoke all on public.exhibition_work_submission_batches,public.exhibition_work_submission_snapshots,
  public.exhibition_work_reviews,public.exhibition_workflow_cases from anon,authenticated;
grant select on public.exhibition_work_submission_batches,public.exhibition_work_submission_snapshots,
  public.exhibition_work_reviews,public.exhibition_workflow_cases to authenticated;
create policy work_batches_owner_admin on public.exhibition_work_submission_batches for select to authenticated using(member_id=private.current_member_id() or private.is_admin());
create policy work_snapshots_owner_admin on public.exhibition_work_submission_snapshots for select to authenticated using(member_id=private.current_member_id() or private.is_admin());
create policy work_reviews_owner_admin on public.exhibition_work_reviews for select to authenticated using(private.is_admin() or exists(select 1 from public.exhibition_works w where w.id=work_id and w.owner_member_id=private.current_member_id()));
create policy work_cases_owner_admin on public.exhibition_workflow_cases for select to authenticated using(member_id=private.current_member_id() or private.is_admin());

revoke all on function public.save_exhibition_work_draft_v2(uuid,uuid,text,text,text,text,numeric,numeric,boolean,text,text) from public,anon;
revoke all on function public.submit_exhibition_work_batch_v2(uuid,uuid[]) from public,anon;
revoke all on function public.admin_review_exhibition_work_v2(uuid,text,text[],text,timestamptz) from public,anon;
revoke all on function public.request_exhibition_work_reedit_v2(uuid,text) from public,anon;
revoke all on function public.cancel_exhibition_work_reedit_request_v2(uuid) from public,anon;
revoke all on function public.admin_decide_exhibition_work_reedit_v2(uuid,boolean,text,timestamptz) from public,anon;
revoke all on function public.cancel_permitted_exhibition_work_reedit_v2(uuid,text) from public,anon;
revoke all on function public.withdraw_exhibition_work_v2(uuid,text) from public,anon;
revoke all on function public.start_exhibition_work_replacement_v2(uuid) from public,anon;
revoke all on function public.cancel_exhibition_work_replacement_v2(uuid) from public,anon;
revoke all on function public.admin_withdraw_exhibition_work_v2(uuid,text) from public,anon;
revoke all on function public.admin_revive_exhibition_entry_v2(uuid,text,timestamptz) from public,anon;
revoke all on function public.admin_process_exhibition_work_deadlines_v2(uuid) from public,anon;
grant execute on function public.save_exhibition_work_draft_v2(uuid,uuid,text,text,text,text,numeric,numeric,boolean,text,text) to authenticated;
grant execute on function public.submit_exhibition_work_batch_v2(uuid,uuid[]) to authenticated;
grant execute on function public.admin_review_exhibition_work_v2(uuid,text,text[],text,timestamptz) to authenticated;
grant execute on function public.request_exhibition_work_reedit_v2(uuid,text) to authenticated;
grant execute on function public.cancel_exhibition_work_reedit_request_v2(uuid) to authenticated;
grant execute on function public.admin_decide_exhibition_work_reedit_v2(uuid,boolean,text,timestamptz) to authenticated;
grant execute on function public.cancel_permitted_exhibition_work_reedit_v2(uuid,text) to authenticated;
grant execute on function public.withdraw_exhibition_work_v2(uuid,text) to authenticated;
grant execute on function public.start_exhibition_work_replacement_v2(uuid) to authenticated;
grant execute on function public.cancel_exhibition_work_replacement_v2(uuid) to authenticated;
grant execute on function public.admin_withdraw_exhibition_work_v2(uuid,text) to authenticated;
grant execute on function public.admin_revive_exhibition_entry_v2(uuid,text,timestamptz) to authenticated;
grant execute on function public.admin_process_exhibition_work_deadlines_v2(uuid) to authenticated;
grant execute on function public.admin_process_exhibition_work_deadlines_v2(uuid) to service_role;

revoke execute on function private.exhibition_work_edit_deadline_open(public.exhibition_works,public.events) from public,anon,authenticated;
revoke execute on function private.exhibition_work_is_viable(uuid) from public,anon,authenticated;
revoke execute on function private.auto_cancel_v2_entry_if_no_viable(uuid,text) from public,anon,authenticated;
revoke execute on function private.validate_v2_work_values(public.exhibition_works) from public,anon,authenticated;
revoke execute on function private.prevent_exhibition_work_history_mutation() from public,anon,authenticated;
revoke execute on function private.protect_v2_event_max_works() from public,anon,authenticated;
revoke execute on function private.sync_v2_entry_extended_state() from public,anon,authenticated;
revoke execute on function private.protect_v2_auto_cancelled_entry() from public,anon,authenticated;

select to_regclass('public.exhibition_work_submission_snapshots') is not null as snapshots_ready,
  to_regclass('public.exhibition_work_reviews') is not null as reviews_ready,
  to_regclass('public.exhibition_workflow_cases') is not null as cases_ready,
  to_regprocedure('public.submit_exhibition_work_batch_v2(uuid,uuid[])') is not null as batch_rpc_ready;
