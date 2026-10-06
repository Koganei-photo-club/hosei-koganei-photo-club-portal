-- Smartphone exhibition Phase 1: application, submission, review and deadline workflow.
-- Layout/Export/Publication/Survey/Actual/Archive are deliberately out of scope.

alter table public.events
  add column if not exists smartphone_exhibition_enabled boolean not null default false,
  add column if not exists max_smartphone_works integer not null default 0;

alter table public.events
  add constraint events_max_smartphone_works_check
    check (max_smartphone_works between 0 and 999),
  add constraint events_smartphone_feature_configuration_check
    check (not smartphone_exhibition_enabled or max_smartphone_works >= 1);

alter table public.exhibition_entries
  drop constraint if exists exhibition_entries_planned_work_count_check;
alter table public.exhibition_entries
  add constraint exhibition_entries_planned_work_count_check
    check (planned_work_count is null or planned_work_count >= 0);

alter table public.exhibition_application_snapshots
  drop constraint if exists exhibition_application_snapshots_planned_work_count_check;
alter table public.exhibition_application_snapshots
  add constraint exhibition_application_snapshots_planned_work_count_check
    check (planned_work_count >= 0);

create or replace function private.validate_exhibition_application_values(
  p_event public.events,p_member public.members,p_planned_work_count integer,
  p_display_name_type text,p_display_name_value text
)
returns text language plpgsql stable security definer set search_path='' as $$
declare resolved_name text;
begin
  if p_planned_work_count is null or p_planned_work_count < 0
     or p_planned_work_count > p_event.max_works then
    raise exception '個人枠の出展予定作品数は0点以上、出展上限以下にしてください。';
  end if;
  if p_display_name_type not in ('real_name','pseudonym') then raise exception '表示名の種類を選択してください。'; end if;
  resolved_name:=case when p_display_name_type='real_name' then trim(p_member.name) else trim(coalesce(p_display_name_value,'')) end;
  if resolved_name='' then raise exception '表示名を入力してください。'; end if;
  if char_length(resolved_name)>100 then raise exception '表示名は100文字以内で入力してください。'; end if;
  return resolved_name;
end;
$$;

-- Additional consent B: only smartphone submitters accept this immutable supplement.
create table public.exhibition_smartphone_agreement_definitions (
  id uuid primary key default gen_random_uuid(),
  version_no integer not null unique check(version_no>=1),
  reference_key text not null unique check(trim(reference_key)<>''),
  content text not null check(trim(content)<>''),
  content_hash text not null unique check(content_hash ~ '^[0-9a-f]{64}$'),
  active boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index exhibition_smartphone_agreement_one_active
  on public.exhibition_smartphone_agreement_definitions((active)) where active;

insert into public.exhibition_smartphone_agreement_definitions(version_no,reference_key,content,content_hash,active)
select 1,'smartphone-exhibition-v1',terms.content,
  encode(extensions.digest(convert_to(terms.content,'UTF8'),'sha256'),'hex'),true
from (values (
  'スマホ枠には、スマートフォンで撮影した写真のみを出展できます。スマホ枠の作品はすべて2L判で印刷し、匿名・作品タイトルなし・個別キャプションなしで、「スマートフォン撮影写真作品」として集合展示します。個々のスマホ枠作品には展示番号を付与せず、集合展示全体を1つの展示物として展示番号を付与し、投票・感想等の対象とする場合があります。個別のスマホ枠作品画像は一般向けWebサイトには掲載しません。

AIによる生成・合成その他の加工により、元画像に存在しなかった視覚的内容を新たに生成・追加した場合、または複数画像等からシーンを構成した場合は、その内容を正確に申告してください。RAW現像、露出・色・コントラスト・ホワイトバランス・彩度の調整、クロップ・回転・パース補正、ノイズ除去・シャープネス等の通常の画像調整、および既存の不要物を除去してその部分を自然に補完するのみの処理は、原則としてこの申告の対象外です。

スマホ枠への作品提出に伴う提出内容、申告内容および本同意の履歴は、写真展の運営、作品確認、展示、記録その他これらに必要な範囲で保存・利用されます。'::text
)) terms(content)
where not exists(select 1 from public.exhibition_smartphone_agreement_definitions);

create table public.exhibition_smartphone_works (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  sort_order integer not null check(sort_order>=1),
  workflow_state text not null default 'draft'
    check(workflow_state in ('draft','submitted','accepted','rejected','reedit_pending','reedit_editing','withdrawn')),
  original_image_path text,
  original_sha256 text check(original_sha256 is null or original_sha256 ~ '^[0-9a-f]{64}$'),
  orientation text check(orientation is null or orientation in ('portrait','landscape')),
  smartphone_confirmed boolean not null default false,
  ai_processing_declaration text check(ai_processing_declaration is null or ai_processing_declaration in ('none','declared')),
  ai_processing_details text not null default '' check(char_length(ai_processing_details)<=3000),
  current_submission_snapshot_id uuid,
  current_accepted_snapshot_id uuid,
  correction_rescue_count integer not null default 0 check(correction_rescue_count between 0 and 1),
  reedit_rescue_count integer not null default 0 check(reedit_rescue_count between 0 and 1),
  submitted_at timestamptz,
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(entry_id,sort_order),
  unique(id,event_id,entry_id,member_id),
  check((ai_processing_declaration='declared' and trim(ai_processing_details)<>'') or
    ai_processing_declaration is null or ai_processing_declaration='none'),
  check(ai_processing_declaration<>'none' or ai_processing_details='')
);

create table public.exhibition_smartphone_work_submission_snapshots (
  id uuid primary key default gen_random_uuid(),
  smartphone_work_id uuid not null references public.exhibition_smartphone_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  previous_snapshot_id uuid references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict,
  original_image_path text not null check(trim(original_image_path)<>''),
  original_sha256 text not null check(original_sha256 ~ '^[0-9a-f]{64}$'),
  orientation text not null check(orientation in ('portrait','landscape')),
  smartphone_confirmed boolean not null check(smartphone_confirmed),
  ai_processing_declaration text not null check(ai_processing_declaration in ('none','declared')),
  ai_processing_details text not null default '' check(char_length(ai_processing_details)<=3000),
  agreement_definition_id uuid not null references public.exhibition_smartphone_agreement_definitions(id) on delete restrict,
  agreement_version integer not null check(agreement_version>=1),
  agreement_reference text not null check(trim(agreement_reference)<>''),
  agreement_content_hash text not null check(agreement_content_hash ~ '^[0-9a-f]{64}$'),
  agreed_at timestamptz not null,
  submitted_at timestamptz not null default now(),
  submitted_by_identifier text not null check(trim(submitted_by_identifier)<>''),
  unique(smartphone_work_id,version_no),
  foreign key(smartphone_work_id,event_id,entry_id,member_id)
    references public.exhibition_smartphone_works(id,event_id,entry_id,member_id) on delete restrict,
  check((ai_processing_declaration='declared' and trim(ai_processing_details)<>'') or
    (ai_processing_declaration='none' and ai_processing_details=''))
);

alter table public.exhibition_smartphone_works
  add constraint exhibition_smartphone_current_submission_fk foreign key(current_submission_snapshot_id)
    references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict,
  add constraint exhibition_smartphone_current_accepted_fk foreign key(current_accepted_snapshot_id)
    references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict;

create table public.exhibition_smartphone_work_reviews (
  id uuid primary key default gen_random_uuid(),
  smartphone_work_id uuid not null references public.exhibition_smartphone_works(id) on delete restrict,
  submission_snapshot_id uuid not null unique references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict,
  reviewer_identifier text not null,
  result text not null check(result in ('accepted','rejected')),
  problem_fields text[] not null default '{}'
    check(problem_fields <@ array['original','orientation','smartphone_confirmation','ai_declaration','other']::text[]),
  reason text not null default '',
  reviewed_at timestamptz not null default now(),
  check(result='accepted' or (cardinality(problem_fields)>0 and trim(reason)<>''))
);

create table public.exhibition_smartphone_workflow_cases (
  id uuid primary key default gen_random_uuid(),
  smartphone_work_id uuid not null references public.exhibition_smartphone_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  case_type text not null check(case_type in ('correction','reedit')),
  source_submission_snapshot_id uuid not null references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict,
  source_review_id uuid references public.exhibition_smartphone_work_reviews(id) on delete restrict,
  state text not null check(state in ('pending','open','permitted','rejected','cancelled','resubmitted','expired','withdrawn','restored')),
  request_reason text not null default '',decision_reason text not null default '',
  individual_deadline timestamptz,requested_at timestamptz not null default now(),
  decided_at timestamptz,closed_at timestamptz
);
create unique index exhibition_smartphone_cases_one_open on public.exhibition_smartphone_workflow_cases(smartphone_work_id)
  where state in ('pending','open','permitted');
create unique index exhibition_smartphone_correction_per_review on public.exhibition_smartphone_workflow_cases(source_review_id)
  where case_type='correction';
create index exhibition_smartphone_snapshots_work_idx on public.exhibition_smartphone_work_submission_snapshots(smartphone_work_id,version_no desc);

create or replace function private.prevent_exhibition_smartphone_history_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'スマホ作品の正式履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_smartphone_snapshots_immutable before update or delete on public.exhibition_smartphone_work_submission_snapshots
for each row execute function private.prevent_exhibition_smartphone_history_mutation();
create trigger exhibition_smartphone_reviews_immutable before update or delete on public.exhibition_smartphone_work_reviews
for each row execute function private.prevent_exhibition_smartphone_history_mutation();

create or replace function private.validate_exhibition_smartphone_work()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_entry public.exhibition_entries%rowtype; target_event public.events%rowtype;
begin
  if coalesce(current_setting('app.exhibition_smartphone_work_rpc',true),'')<>'on' then
    raise exception 'スマホ枠作品は専用操作から変更してください。';
  end if;
  select * into target_entry from public.exhibition_entries where id=new.entry_id;
  select * into target_event from public.events where id=target_entry.event_id;
  if target_entry.id is null or target_entry.member_id<>new.member_id then
    raise exception '本人のApplicationが必要です。';
  end if;
  if new.workflow_state<>'withdrawn' and target_entry.application_state<>'active' then
    raise exception '有効な本人のApplicationが必要です。';
  end if;
  if target_event.exhibition_workflow_version<>2 or (new.workflow_state<>'withdrawn' and not target_event.smartphone_exhibition_enabled) then
    raise exception 'この写真展ではスマホ枠を利用できません。';
  end if;
  new.event_id:=target_entry.event_id; new.updated_at:=now();
  return new;
end;
$$;
create trigger validate_exhibition_smartphone_work_before_write before insert or update on public.exhibition_smartphone_works
for each row execute function private.validate_exhibition_smartphone_work();

create or replace function private.exhibition_smartphone_edit_deadline_open(p_work public.exhibition_smartphone_works,p_event public.events)
returns boolean language sql stable security definer set search_path='' as $$
  select case when p_work.workflow_state in ('rejected','reedit_editing') then exists(
    select 1 from public.exhibition_smartphone_workflow_cases c where c.smartphone_work_id=p_work.id
      and c.state in ('open','permitted') and now()<c.individual_deadline)
  else private.exhibition_deadline_is_open(p_work.event_id,'work_submission') end
$$;

create or replace function private.exhibition_smartphone_work_is_viable(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.exhibition_smartphone_works w join public.events e on e.id=w.event_id
    where w.id=p_work_id and w.workflow_state<>'withdrawn' and (
      w.workflow_state in ('submitted','accepted','reedit_pending')
      or (w.workflow_state in ('draft','rejected','reedit_editing') and private.exhibition_smartphone_edit_deadline_open(w,e))))
$$;

create or replace function private.auto_cancel_v2_entry_if_no_viable(p_entry_id uuid,p_cause text)
returns boolean language plpgsql security definer set search_path='' as $$
declare target public.exhibition_entries%rowtype;
begin
  select * into target from public.exhibition_entries where id=p_entry_id for update;
  if target.id is null or target.application_state<>'active' then return false; end if;
  if exists(select 1 from public.exhibition_works w where w.entry_id=p_entry_id and private.exhibition_work_is_viable(w.id))
     or exists(select 1 from public.exhibition_smartphone_works sw where sw.entry_id=p_entry_id and private.exhibition_smartphone_work_is_viable(sw.id)) then
    return false;
  end if;
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set application_state='auto_cancelled',status='withdrawn',
    work_auto_cancelled_at=now(),work_auto_cancel_cause=p_cause,application_updated_at=now() where id=p_entry_id;
  perform set_config('app.exhibition_application_rpc','off',true);
  perform private.write_exhibition_workflow_audit(target.event_id,'application',target.id,'entry_auto_cancelled','system','system',p_cause,
    jsonb_build_object('applicationState','active'),jsonb_build_object('applicationState','auto_cancelled'));
  return true;
end;
$$;

create or replace function public.get_exhibition_smartphone_terms_v1()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',d.id,'versionNo',d.version_no,'referenceKey',d.reference_key,
    'content',d.content,'contentHash',d.content_hash)
  from public.exhibition_smartphone_agreement_definitions d where d.active limit 1
$$;

create or replace function public.save_exhibition_smartphone_work_draft_v1(
  p_event_id uuid,p_smartphone_work_id uuid,p_orientation text,p_smartphone_confirmed boolean,
  p_ai_processing_declaration text,p_ai_processing_details text,p_original_image_path text,p_original_sha256 text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; en public.exhibition_entries%rowtype; w public.exhibition_smartphone_works%rowtype;
  mid uuid:=private.current_member_id(); next_slot integer; active_count integer; actor text:=private.current_email();
begin
  if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into e from public.events where id=p_event_id for update;
  select * into en from public.exhibition_entries where event_id=p_event_id and member_id=mid for update;
  if e.exhibition_workflow_version<>2 or not e.smartphone_exhibition_enabled or e.max_smartphone_works<1
     or en.application_state<>'active' then raise exception 'この写真展で利用可能なスマホ枠Applicationがありません。'; end if;
  if p_smartphone_work_id is null then
    if not private.exhibition_deadline_is_open(p_event_id,'work_submission') then raise exception '作品提出締切を過ぎています。'; end if;
    select count(*) into active_count from public.exhibition_smartphone_works sw where sw.entry_id=en.id and sw.workflow_state<>'withdrawn';
    if active_count>=e.max_smartphone_works then raise exception 'スマホ枠の出展可能作品数を超えています。'; end if;
    select coalesce(max(sw.sort_order),0)+1 into next_slot from public.exhibition_smartphone_works sw where sw.entry_id=en.id;
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    insert into public.exhibition_smartphone_works(event_id,entry_id,member_id,sort_order,orientation,smartphone_confirmed,
      ai_processing_declaration,ai_processing_details,original_image_path,original_sha256)
    values(p_event_id,en.id,mid,next_slot,nullif(p_orientation,''),coalesce(p_smartphone_confirmed,false),
      nullif(p_ai_processing_declaration,''),trim(coalesce(p_ai_processing_details,'')),p_original_image_path,lower(p_original_sha256)) returning * into w;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_work',w.id,'smartphone_draft_created','member',actor,'','{}',jsonb_build_object('sortOrder',w.sort_order));
  else
    select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id and event_id=p_event_id and member_id=mid for update;
    if w.id is null or w.workflow_state not in ('draft','rejected','reedit_editing') then raise exception '編集可能なスマホ作品ではありません。'; end if;
    if not private.exhibition_smartphone_edit_deadline_open(w,e) then raise exception '編集期限を過ぎています。'; end if;
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set orientation=nullif(p_orientation,''),smartphone_confirmed=coalesce(p_smartphone_confirmed,false),
      ai_processing_declaration=nullif(p_ai_processing_declaration,''),ai_processing_details=trim(coalesce(p_ai_processing_details,'')),
      original_image_path=p_original_image_path,original_sha256=lower(p_original_sha256) where id=w.id returning * into w;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_work',w.id,'smartphone_draft_updated','member',actor,'','{}',jsonb_build_object('state',w.workflow_state));
  end if;
  return to_jsonb(w);
end;
$$;

create or replace function public.submit_exhibition_smartphone_work_v1(
  p_smartphone_work_id uuid,p_expected_agreement_id uuid,p_expected_agreement_hash text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; e public.events%rowtype; d public.exhibition_smartphone_agreement_definitions%rowtype;
  old_snapshot uuid; snap_id uuid; next_version integer; actor text:=private.current_email(); mid uuid:=private.current_member_id(); c public.exhibition_smartphone_workflow_cases%rowtype;
begin
  select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id and member_id=mid for update;
  if w.id is null or w.workflow_state not in ('draft','rejected','reedit_editing') then raise exception '提出可能なスマホ作品ではありません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(w.event_id::text,0));
  select * into e from public.events where id=w.event_id for update;
  if not e.smartphone_exhibition_enabled or not private.exhibition_smartphone_edit_deadline_open(w,e) then raise exception 'スマホ作品の提出期限を過ぎています。'; end if;
  if w.original_image_path is null or w.original_sha256 is null then raise exception '原画像とSHA-256 hashが必要です。'; end if;
  if split_part(w.original_image_path,'/',1)<>w.event_id::text or split_part(w.original_image_path,'/',2)<>w.member_id::text
     or split_part(w.original_image_path,'/',3)<>w.id::text or split_part(w.original_image_path,'/',4)='' or split_part(w.original_image_path,'/',5)<>'' then
    raise exception '原画像のStorage pathがこのスマホ作品に属していません。';
  end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='exhibition-originals' and o.name=w.original_image_path) then raise exception '原画像がStorageに見つかりません。'; end if;
  if w.orientation not in ('portrait','landscape') then raise exception '作品の向きを選択してください。'; end if;
  if not w.smartphone_confirmed then raise exception 'スマートフォンで撮影した写真であることを確認してください。'; end if;
  if w.ai_processing_declaration not in ('none','declared') then raise exception 'AI生成・合成等の申告を選択してください。'; end if;
  if w.ai_processing_declaration='declared' and trim(w.ai_processing_details)='' then raise exception 'AI生成・合成等の内容を入力してください。'; end if;
  select * into d from public.exhibition_smartphone_agreement_definitions where active;
  if d.id is null or p_expected_agreement_id is distinct from d.id or lower(coalesce(p_expected_agreement_hash,''))<>d.content_hash then
    raise exception 'スマホ枠の同意内容が更新されました。再確認してください。';
  end if;
  select count(*)+1 into next_version from public.exhibition_smartphone_work_submission_snapshots where smartphone_work_id=w.id;
  old_snapshot:=w.current_submission_snapshot_id;
  insert into public.exhibition_smartphone_work_submission_snapshots(smartphone_work_id,event_id,entry_id,member_id,version_no,
    previous_snapshot_id,original_image_path,original_sha256,orientation,smartphone_confirmed,ai_processing_declaration,
    ai_processing_details,agreement_definition_id,agreement_version,agreement_reference,agreement_content_hash,agreed_at,submitted_by_identifier)
  values(w.id,w.event_id,w.entry_id,w.member_id,next_version,old_snapshot,w.original_image_path,w.original_sha256,w.orientation,true,
    w.ai_processing_declaration,w.ai_processing_details,d.id,d.version_no,d.reference_key,d.content_hash,now(),actor) returning id into snap_id;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='submitted',current_submission_snapshot_id=snap_id,submitted_at=now() where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  select * into c from public.exhibition_smartphone_workflow_cases where smartphone_work_id=w.id and state in ('open','permitted') for update;
  if c.id is not null then update public.exhibition_smartphone_workflow_cases set state='resubmitted',closed_at=now() where id=c.id; end if;
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_submission_snapshot',snap_id,
    case when next_version=1 then 'smartphone_submitted' else 'smartphone_resubmitted' end,'member',actor,'','{}',
    jsonb_build_object('smartphoneWorkId',w.id,'versionNo',next_version,'agreementVersion',d.version_no,'agreementHash',d.content_hash));
  return jsonb_build_object('smartphoneWorkId',w.id,'snapshotId',snap_id,'versionNo',next_version,'state','submitted');
end;
$$;

create or replace function public.admin_review_exhibition_smartphone_work_v1(
  p_submission_snapshot_id uuid,p_result text,p_problem_fields text[],p_reason text,p_individual_deadline timestamptz default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.exhibition_smartphone_work_submission_snapshots%rowtype; w public.exhibition_smartphone_works%rowtype;
  e public.events%rowtype; rid uuid; deadline timestamptz; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_result not in ('accepted','rejected') then raise exception 'Review結果が不正です。'; end if;
  if p_result='rejected' and (coalesce(cardinality(p_problem_fields),0)=0 or trim(coalesce(p_reason,''))='') then raise exception '要修正には問題項目と理由が必要です。'; end if;
  select * into s from public.exhibition_smartphone_work_submission_snapshots where id=p_submission_snapshot_id;
  select * into w from public.exhibition_smartphone_works where id=s.smartphone_work_id for update;
  select * into e from public.events where id=s.event_id;
  if s.id is null or w.current_submission_snapshot_id is distinct from s.id or w.workflow_state<>'submitted' then raise exception 'Review対象が古いか処理済みです。'; end if;
  if p_result='rejected' then
    deadline:=case when now()<e.exhibition_revision_deadline then e.exhibition_revision_deadline else p_individual_deadline end;
    if deadline is null or deadline<=now() then raise exception 'Revision期限後の要修正には未来の個別期限が必要です。'; end if;
  end if;
  insert into public.exhibition_smartphone_work_reviews(smartphone_work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
  values(w.id,s.id,actor,p_result,coalesce(p_problem_fields,'{}'),coalesce(p_reason,'')) returning id into rid;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state=case when p_result='accepted' then 'accepted' else 'rejected' end,
    current_accepted_snapshot_id=case when p_result='accepted' then s.id else current_accepted_snapshot_id end where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  if p_result='rejected' then
    insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,
      source_review_id,state,decision_reason,individual_deadline,decided_at)
    values(w.id,w.event_id,w.member_id,'correction',s.id,rid,'open',p_reason,deadline,now());
  end if;
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_review',rid,
    case when p_result='accepted' then 'smartphone_accepted' else 'smartphone_needs_revision' end,'admin',actor,p_reason,
    jsonb_build_object('snapshotId',s.id),jsonb_build_object('problemFields',coalesce(p_problem_fields,'{}'),'deadline',deadline));
  return jsonb_build_object('reviewId',rid,'smartphoneWorkId',w.id,'result',p_result,'deadline',deadline);
end;
$$;

create or replace function public.request_exhibition_smartphone_reedit_v1(p_smartphone_work_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; cid uuid; actor text:=private.current_email();
begin
  if trim(coalesce(p_reason,''))='' then raise exception '再編集理由は必須です。'; end if;
  select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id and member_id=private.current_member_id() for update;
  if w.id is null or w.workflow_state<>'accepted' or w.current_accepted_snapshot_id is null then raise exception '再編集申請可能なスマホ作品ではありません。'; end if;
  insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,state,request_reason)
    values(w.id,w.event_id,w.member_id,'reedit',w.current_accepted_snapshot_id,'pending',trim(p_reason)) returning id into cid;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='reedit_pending' where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_case',cid,'smartphone_reedit_requested','member',actor,p_reason,'{}','{}');
  return jsonb_build_object('caseId',cid,'state','pending');
end;
$$;

create or replace function public.admin_decide_exhibition_smartphone_reedit_v1(p_case_id uuid,p_permit boolean,p_reason text,p_individual_deadline timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_smartphone_workflow_cases%rowtype; w public.exhibition_smartphone_works%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '判断理由は必須です。'; end if;
  select * into c from public.exhibition_smartphone_workflow_cases where id=p_case_id for update;
  select * into w from public.exhibition_smartphone_works where id=c.smartphone_work_id for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'pending' or w.workflow_state<>'reedit_pending' then raise exception '処理可能な再編集申請ではありません。'; end if;
  if p_permit and (p_individual_deadline is null or p_individual_deadline<=now()) then raise exception '許可には未来の個別期限が必要です。'; end if;
  update public.exhibition_smartphone_workflow_cases set state=case when p_permit then 'permitted' else 'rejected' end,
    decision_reason=trim(p_reason),individual_deadline=case when p_permit then p_individual_deadline end,decided_at=now(),
    closed_at=case when p_permit then null else now() end where id=c.id;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state=case when p_permit then 'reedit_editing' else 'accepted' end where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_case',c.id,
    case when p_permit then 'smartphone_reedit_permitted' else 'smartphone_reedit_rejected' end,'admin',actor,p_reason,'{}',jsonb_build_object('deadline',p_individual_deadline));
  return jsonb_build_object('caseId',c.id,'state',case when p_permit then 'permitted' else 'rejected' end);
end;
$$;

create or replace function public.cancel_exhibition_smartphone_reedit_request_v1(p_case_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_smartphone_workflow_cases%rowtype; w public.exhibition_smartphone_works%rowtype; actor text:=private.current_email();
begin
  select * into c from public.exhibition_smartphone_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
  select * into w from public.exhibition_smartphone_works where id=c.smartphone_work_id for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'pending' or w.workflow_state<>'reedit_pending' then
    raise exception '取消可能なスマホ作品の再編集申請がありません。';
  end if;
  update public.exhibition_smartphone_workflow_cases set state='cancelled',closed_at=now() where id=c.id;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='accepted' where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_case',c.id,'smartphone_reedit_request_cancelled','member',actor,'','{}','{}');
  return jsonb_build_object('caseId',c.id,'state','cancelled');
end;
$$;

create or replace function public.cancel_permitted_exhibition_smartphone_reedit_v1(p_case_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_smartphone_workflow_cases%rowtype; w public.exhibition_smartphone_works%rowtype;
  s public.exhibition_smartphone_work_submission_snapshots%rowtype; actor text:=private.current_email();
begin
  select * into c from public.exhibition_smartphone_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
  select * into w from public.exhibition_smartphone_works where id=c.smartphone_work_id for update;
  select * into s from public.exhibition_smartphone_work_submission_snapshots where id=c.source_submission_snapshot_id;
  if c.id is null or c.state<>'permitted' or w.workflow_state<>'reedit_editing' or s.id is null then raise exception '取りやめ可能な再編集ではありません。'; end if;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set original_image_path=s.original_image_path,original_sha256=s.original_sha256,
    orientation=s.orientation,smartphone_confirmed=s.smartphone_confirmed,ai_processing_declaration=s.ai_processing_declaration,
    ai_processing_details=s.ai_processing_details,workflow_state='accepted',current_submission_snapshot_id=s.id,current_accepted_snapshot_id=s.id where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  update public.exhibition_smartphone_workflow_cases set state='restored',closed_at=now() where id=c.id;
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work_case',c.id,'smartphone_reedit_cancelled_restored','member',actor,p_reason,'{}',jsonb_build_object('snapshotId',s.id));
  return jsonb_build_object('smartphoneWorkId',w.id,'state','accepted');
end;
$$;

create or replace function public.withdraw_exhibition_smartphone_work_v1(p_smartphone_work_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; actor text:=private.current_email();
begin
  select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id and member_id=private.current_member_id() for update;
  if w.id is null or w.workflow_state='withdrawn' then raise exception '取り下げ可能なスマホ作品がありません。'; end if;
  if not private.exhibition_deadline_is_open(w.event_id,'work_submission') then raise exception '作品提出締切後は本人による取り下げができません。'; end if;
  if w.workflow_state='accepted' and trim(coalesce(p_reason,''))='' then raise exception '確認済み作品の取り下げ理由は必須です。'; end if;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  update public.exhibition_smartphone_workflow_cases set state='withdrawn',closed_at=now() where smartphone_work_id=w.id and state in ('pending','open','permitted');
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,'smartphone_withdrawn','member',actor,p_reason,'{}','{}');
  perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'smartphone_withdrawal_no_viable_work');
  return jsonb_build_object('smartphoneWorkId',w.id,'state','withdrawn');
end;
$$;

create or replace function public.admin_withdraw_exhibition_smartphone_work_v1(p_smartphone_work_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '管理者取り下げ理由は必須です。'; end if;
  select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id for update;
  if w.id is null or w.workflow_state='withdrawn' then raise exception '取り下げ可能なスマホ作品がありません。'; end if;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=w.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  update public.exhibition_smartphone_workflow_cases set state='withdrawn',closed_at=now() where smartphone_work_id=w.id and state in ('pending','open','permitted');
  perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,'smartphone_withdrawn','admin',actor,p_reason,'{}','{}');
  perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'admin_smartphone_withdrawal_no_viable_work');
  return jsonb_build_object('smartphoneWorkId',w.id,'state','withdrawn');
end;
$$;

create or replace function public.admin_process_exhibition_smartphone_deadlines_v1(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; withdrawn_count integer:=0; expired_count integer:=0;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  for w in select sw.* from public.exhibition_smartphone_works sw join public.events e on e.id=sw.event_id
    where sw.event_id=p_event_id and sw.workflow_state='draft' and now()>=e.exhibition_work_submission_deadline for update of sw loop
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=w.id;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    withdrawn_count:=withdrawn_count+1;
    perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,'system_deadline_smartphone_withdrawn','system','system','work_submission_deadline','{}','{}');
  end loop;
  for w in select sw.* from public.exhibition_smartphone_works sw join public.exhibition_smartphone_workflow_cases c on c.smartphone_work_id=sw.id
    where sw.event_id=p_event_id and c.state in ('open','permitted') and c.individual_deadline<=now() for update of sw loop
    update public.exhibition_smartphone_workflow_cases set state='expired',closed_at=now() where smartphone_work_id=w.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=w.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    if found then
      expired_count:=expired_count+1;
      perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,
        'system_smartphone_case_deadline_withdrawn','system','system','individual_deadline_expired','{}','{}');
      perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'smartphone_case_deadline_no_viable_work');
    end if;
  end loop;
  return jsonb_build_object('draftSmartphoneWorksWithdrawn',withdrawn_count,'smartphoneCasesExpired',expired_count);
end;
$$;

-- Extend private original-object ownership without changing the path contract.
create or replace function private.current_member_can_write_exhibition_object_path(target_path text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.exhibition_works w join public.events e on e.id=w.event_id
    where w.event_id::text=split_part(target_path,'/',1) and w.owner_member_id::text=split_part(target_path,'/',2)
      and w.id::text=split_part(target_path,'/',3) and w.owner_member_id=private.current_member_id()
      and split_part(target_path,'/',4)<>'' and split_part(target_path,'/',5)='' and private.is_current_member()
      and not exists(select 1 from public.exhibition_work_submission_snapshots s where s.original_image_path=target_path)
      and ((e.exhibition_workflow_version=1 and private.is_available_exhibition_event(w.event_id))
        or (e.exhibition_workflow_version=2 and exists(select 1 from public.exhibition_entries en where en.id=w.entry_id and en.application_state='active')
          and private.exhibition_work_edit_deadline_open(w,e))))
  or exists(select 1 from public.exhibition_smartphone_works sw join public.events e on e.id=sw.event_id
    join public.exhibition_entries en on en.id=sw.entry_id
    where sw.event_id::text=split_part(target_path,'/',1) and sw.member_id::text=split_part(target_path,'/',2)
      and sw.id::text=split_part(target_path,'/',3) and sw.member_id=private.current_member_id()
      and split_part(target_path,'/',4)<>'' and split_part(target_path,'/',5)='' and private.is_current_member()
      and en.application_state='active' and e.smartphone_exhibition_enabled
      and not exists(select 1 from public.exhibition_smartphone_work_submission_snapshots s where s.original_image_path=target_path)
      and private.exhibition_smartphone_edit_deadline_open(sw,e))
$$;

create or replace function public.admin_get_exhibition_smartphone_actions_v1(p_event_id uuid default null)
returns table(priority integer,action_type text,event_id uuid,entry_id uuid,smartphone_work_id uuid,member_id uuid,
  member_name text,snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,workflow_state text,occurred_at timestamptz,reason text)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query
  select * from (
    select 10,'smartphone_review'::text,sw.event_id,sw.entry_id,sw.id,sw.member_id,m.name,
      sw.current_submission_snapshot_id,null::uuid,null::timestamptz,sw.workflow_state,sw.submitted_at,''::text
    from public.exhibition_smartphone_works sw join public.members m on m.id=sw.member_id where sw.workflow_state='submitted'
    union all
    select 20,'smartphone_reedit_decision',sw.event_id,sw.entry_id,sw.id,sw.member_id,m.name,
      c.source_submission_snapshot_id,c.id,c.individual_deadline,sw.workflow_state,c.requested_at,c.request_reason
    from public.exhibition_smartphone_works sw join public.members m on m.id=sw.member_id
      join public.exhibition_smartphone_workflow_cases c on c.smartphone_work_id=sw.id where c.case_type='reedit' and c.state='pending'
  ) action_rows where p_event_id is null or action_rows.event_id=p_event_id order by priority,occurred_at;
end;
$$;

alter table public.exhibition_smartphone_agreement_definitions enable row level security;
alter table public.exhibition_smartphone_works enable row level security;
alter table public.exhibition_smartphone_work_submission_snapshots enable row level security;
alter table public.exhibition_smartphone_work_reviews enable row level security;
alter table public.exhibition_smartphone_workflow_cases enable row level security;
revoke all on public.exhibition_smartphone_agreement_definitions,public.exhibition_smartphone_works,
  public.exhibition_smartphone_work_submission_snapshots,public.exhibition_smartphone_work_reviews,
  public.exhibition_smartphone_workflow_cases from anon,authenticated;
grant select on public.exhibition_smartphone_works,public.exhibition_smartphone_work_submission_snapshots,
  public.exhibition_smartphone_work_reviews,public.exhibition_smartphone_workflow_cases to authenticated;

create policy smartphone_works_owner_admin_select on public.exhibition_smartphone_works for select to authenticated
  using(member_id=private.current_member_id() or private.is_admin());
create policy smartphone_snapshots_owner_admin_select on public.exhibition_smartphone_work_submission_snapshots for select to authenticated
  using(member_id=private.current_member_id() or private.is_admin());
create policy smartphone_reviews_owner_admin_select on public.exhibition_smartphone_work_reviews for select to authenticated
  using(private.is_admin() or exists(select 1 from public.exhibition_smartphone_works sw where sw.id=smartphone_work_id and sw.member_id=private.current_member_id()));
create policy smartphone_cases_owner_admin_select on public.exhibition_smartphone_workflow_cases for select to authenticated
  using(member_id=private.current_member_id() or private.is_admin());

revoke all on function public.get_exhibition_smartphone_terms_v1() from public,anon;
revoke all on function public.save_exhibition_smartphone_work_draft_v1(uuid,uuid,text,boolean,text,text,text,text) from public,anon;
revoke all on function public.submit_exhibition_smartphone_work_v1(uuid,uuid,text) from public,anon;
revoke all on function public.admin_review_exhibition_smartphone_work_v1(uuid,text,text[],text,timestamptz) from public,anon;
revoke all on function public.request_exhibition_smartphone_reedit_v1(uuid,text) from public,anon;
revoke all on function public.cancel_exhibition_smartphone_reedit_request_v1(uuid) from public,anon;
revoke all on function public.admin_decide_exhibition_smartphone_reedit_v1(uuid,boolean,text,timestamptz) from public,anon;
revoke all on function public.cancel_permitted_exhibition_smartphone_reedit_v1(uuid,text) from public,anon;
revoke all on function public.withdraw_exhibition_smartphone_work_v1(uuid,text) from public,anon;
revoke all on function public.admin_withdraw_exhibition_smartphone_work_v1(uuid,text) from public,anon;
revoke all on function public.admin_process_exhibition_smartphone_deadlines_v1(uuid) from public,anon;
revoke all on function public.admin_get_exhibition_smartphone_actions_v1(uuid) from public,anon;
grant execute on function public.get_exhibition_smartphone_terms_v1(),
  public.save_exhibition_smartphone_work_draft_v1(uuid,uuid,text,boolean,text,text,text,text),
  public.submit_exhibition_smartphone_work_v1(uuid,uuid,text),
  public.request_exhibition_smartphone_reedit_v1(uuid,text),
  public.cancel_exhibition_smartphone_reedit_request_v1(uuid),
  public.cancel_permitted_exhibition_smartphone_reedit_v1(uuid,text),
  public.withdraw_exhibition_smartphone_work_v1(uuid,text) to authenticated;
grant execute on function public.admin_review_exhibition_smartphone_work_v1(uuid,text,text[],text,timestamptz),
  public.admin_decide_exhibition_smartphone_reedit_v1(uuid,boolean,text,timestamptz),
  public.admin_withdraw_exhibition_smartphone_work_v1(uuid,text),
  public.admin_process_exhibition_smartphone_deadlines_v1(uuid),
  public.admin_get_exhibition_smartphone_actions_v1(uuid) to authenticated;
grant execute on function public.admin_process_exhibition_smartphone_deadlines_v1(uuid) to service_role;

revoke execute on function private.validate_exhibition_smartphone_work(),private.prevent_exhibition_smartphone_history_mutation(),
  private.exhibition_smartphone_work_is_viable(uuid),private.exhibition_smartphone_edit_deadline_open(public.exhibition_smartphone_works,public.events)
  from public,anon,authenticated;

-- Event settings cannot be changed by ordinary members even if future table grants broaden.
create or replace function private.protect_exhibition_smartphone_event_settings()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if (new.smartphone_exhibition_enabled is distinct from old.smartphone_exhibition_enabled
      or new.max_smartphone_works is distinct from old.max_smartphone_works) and not private.is_admin() then
    raise exception 'スマホ枠設定は管理者のみ変更できます。';
  end if;
  if old.smartphone_exhibition_enabled and new.max_smartphone_works<old.max_smartphone_works
     and new.max_smartphone_works<(select coalesce(max(item_count),0) from (
       select count(*) item_count from public.exhibition_smartphone_works sw
       where sw.event_id=old.id and sw.workflow_state<>'withdrawn' group by sw.entry_id
     ) counts) then
    raise exception '現在のスマホ枠作品数未満へ上限を減らせません。';
  end if;
  return new;
end;
$$;
create trigger protect_exhibition_smartphone_event_settings_before_update
before update of smartphone_exhibition_enabled,max_smartphone_works on public.events
for each row execute function private.protect_exhibition_smartphone_event_settings();
revoke execute on function private.protect_exhibition_smartphone_event_settings() from public,anon,authenticated;

select to_regclass('public.exhibition_smartphone_works') is not null as smartphone_works_ready,
  to_regclass('public.exhibition_smartphone_work_submission_snapshots') is not null as smartphone_snapshots_ready,
  to_regprocedure('public.submit_exhibition_smartphone_work_v1(uuid,uuid,text)') is not null as smartphone_submit_ready;
