-- 写真展Workflow v2 Phase 4: Caption working data / snapshot / review / correction / re-edit。

create table public.exhibition_caption_working_data (
  work_id uuid primary key references public.exhibition_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  state text not null default 'draft' check(state in ('draft','submitted','accepted','rejected','reedit_pending','reedit_editing')),
  display_name text not null default '' check(char_length(display_name)<=100),
  english_title_mode text not null default 'organizer' check(english_title_mode in ('self','organizer')),
  member_english_title text not null default '' check(char_length(member_english_title)<=500),
  medium text not null default '' check(medium in ('','digital','film','instant','non_photographic','other')),
  medium_details text not null default '' check(char_length(medium_details)<=500),
  camera text not null default '' check(char_length(camera)<=200),
  lens text not null default '' check(char_length(lens)<=500),
  film text not null default '' check(char_length(film)<=500),
  description_choice text not null default 'undecided' check(description_choice in ('provided','unnecessary','undecided')),
  description_ja text not null default '' check(char_length(description_ja)<=3000),
  description_en text not null default '' check(char_length(description_en)<=3000),
  instagram_qr_choice text not null default 'none' check(instagram_qr_choice in ('none','request','provided')),
  instagram_qr_info text not null default '' check(char_length(instagram_qr_info)<=1000),
  instagram_qr_path text,
  current_submission_snapshot_id uuid,
  current_accepted_snapshot_id uuid,
  correction_rescue_count integer not null default 0 check(correction_rescue_count between 0 and 1),
  reedit_rescue_count integer not null default 0 check(reedit_rescue_count between 0 and 1),
  updated_at timestamptz not null default now()
);

create table public.exhibition_caption_submission_snapshots (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  entry_id uuid not null references public.exhibition_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  display_name text not null,
  english_title_mode text not null check(english_title_mode in ('self','organizer')),
  member_english_title text not null default '',
  medium text not null,
  medium_details text not null default '',
  camera text not null default '',
  lens text not null default '',
  film text not null default '',
  description_choice text not null check(description_choice in ('provided','unnecessary')),
  description_ja text not null default '',
  description_en text not null default '',
  instagram_qr_choice text not null check(instagram_qr_choice in ('none','request','provided')),
  instagram_qr_info text not null default '',
  instagram_qr_path text,
  submitted_at timestamptz not null default now(),
  submitted_by_member_id uuid not null references public.members(id) on delete restrict,
  submitted_by_identifier text not null,
  unique(work_id,version_no),
  check(member_id=submitted_by_member_id)
);

alter table public.exhibition_caption_working_data
  add constraint exhibition_caption_current_submission_fk foreign key(current_submission_snapshot_id)
    references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  add constraint exhibition_caption_current_accepted_fk foreign key(current_accepted_snapshot_id)
    references public.exhibition_caption_submission_snapshots(id) on delete restrict;

create table public.exhibition_caption_reviews (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  caption_snapshot_id uuid not null unique references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  reviewer_identifier text not null,
  result text not null check(result in ('accepted','rejected')),
  problem_fields text[] not null default '{}',
  reason text not null default '',
  reviewed_at timestamptz not null default now(),
  check(result='accepted' or (cardinality(problem_fields)>0 and trim(reason)<>'')),
  check(problem_fields <@ array['display_name','english_title','medium','camera','lens','film','description','instagram_qr','other']::text[])
);

create table public.exhibition_caption_workflow_cases (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  case_type text not null check(case_type in ('correction','reedit')),
  source_caption_snapshot_id uuid not null references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  source_review_id uuid references public.exhibition_caption_reviews(id) on delete restrict,
  state text not null check(state in ('pending','open','permitted','rejected','cancelled','resubmitted','expired','restored')),
  request_reason text not null default '',
  decision_reason text not null default '',
  individual_deadline timestamptz,
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  closed_at timestamptz
);
create unique index exhibition_caption_cases_one_open on public.exhibition_caption_workflow_cases(work_id)
  where state in ('pending','open','permitted');
create unique index exhibition_caption_correction_per_review on public.exhibition_caption_workflow_cases(source_review_id)
  where case_type='correction';

create table public.exhibition_caption_english_title_derivations (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  source_caption_snapshot_id uuid not null references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  english_title text not null check(trim(english_title)<>'' and char_length(english_title)<=500),
  created_by_identifier text not null,
  reason text not null default '',
  created_at timestamptz not null default now(),
  unique(work_id,version_no)
);

create or replace function private.prevent_exhibition_caption_history_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Captionの正式履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_caption_snapshots_immutable before update or delete on public.exhibition_caption_submission_snapshots
for each row execute function private.prevent_exhibition_caption_history_mutation();
create trigger exhibition_caption_reviews_immutable before update or delete on public.exhibition_caption_reviews
for each row execute function private.prevent_exhibition_caption_history_mutation();
create trigger exhibition_caption_derivations_immutable before update or delete on public.exhibition_caption_english_title_derivations
for each row execute function private.prevent_exhibition_caption_history_mutation();

create or replace function private.validate_caption_v2_values(p_caption public.exhibition_caption_working_data)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if trim(p_caption.display_name)='' then raise exception '表示名を入力してください。'; end if;
  if p_caption.english_title_mode='self' and trim(p_caption.member_english_title)='' then raise exception '英語作品名を入力してください。'; end if;
  if p_caption.medium='' then raise exception '媒体を選択してください。'; end if;
  if p_caption.medium='other' and trim(p_caption.medium_details)='' then raise exception '媒体の詳細を入力してください。'; end if;
  if p_caption.medium in ('digital','film','instant') and trim(p_caption.camera)='' then raise exception 'Cameraを入力してください。'; end if;
  if p_caption.medium='film' and trim(p_caption.film)='' then raise exception 'Filmを入力してください。'; end if;
  if p_caption.description_choice='undecided' then raise exception 'Descriptionの要否を確定してください。'; end if;
  if p_caption.description_choice='provided' and trim(p_caption.description_ja)='' then raise exception '日本語Descriptionを入力してください。'; end if;
  if p_caption.instagram_qr_choice='provided' and p_caption.instagram_qr_path is null and trim(p_caption.instagram_qr_info)='' then
    raise exception 'Instagram QRの画像または情報を入力してください。';
  end if;
end;
$$;

create or replace function private.caption_edit_is_open(p_caption public.exhibition_caption_working_data,p_event public.events)
returns boolean language sql stable security definer set search_path='' as $$
  select case when p_caption.state in ('rejected','reedit_editing') then exists(
    select 1 from public.exhibition_caption_workflow_cases c where c.work_id=p_caption.work_id
      and c.state in ('open','permitted') and now()<c.individual_deadline
  ) else now()<p_event.exhibition_caption_deadline end
$$;

create or replace function public.save_exhibition_caption_draft_v2(
  p_work_id uuid,p_display_name text,p_english_title_mode text,p_member_english_title text,
  p_medium text,p_medium_details text,p_camera text,p_lens text,p_film text,
  p_description_choice text,p_description_ja text,p_description_en text,
  p_instagram_qr_choice text,p_instagram_qr_info text,p_instagram_qr_path text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; e public.events%rowtype; en public.exhibition_entries%rowtype;
  c public.exhibition_caption_working_data%rowtype; mid uuid:=private.current_member_id(); actor text:=private.current_email();
begin
  select * into w from public.exhibition_works where id=p_work_id and owner_member_id=mid for update;
  select * into e from public.events where id=w.event_id;
  select * into en from public.exhibition_entries where id=w.entry_id;
  if w.id is null or e.exhibition_workflow_version<>2 or en.application_state<>'active' or w.workflow_state='withdrawn' then
    raise exception '対象のWorkflow v2 Workが見つかりません。';
  end if;
  select * into c from public.exhibition_caption_working_data where work_id=w.id for update;
  if c.work_id is not null and c.state not in ('draft','rejected','reedit_editing') then raise exception '現在Captionを編集できません。'; end if;
  if c.work_id is not null and not private.caption_edit_is_open(c,e) then raise exception 'Caption編集期限を過ぎています。'; end if;
  if c.work_id is null and not coalesce(private.exhibition_deadline_is_open(w.event_id,'caption'),false) then raise exception 'Caption締切を過ぎています。'; end if;
  insert into public.exhibition_caption_working_data(work_id,event_id,entry_id,member_id,state,display_name,english_title_mode,
    member_english_title,medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,
    instagram_qr_choice,instagram_qr_info,instagram_qr_path)
  values(w.id,w.event_id,w.entry_id,w.owner_member_id,'draft',trim(coalesce(p_display_name,'')),p_english_title_mode,
    trim(coalesce(p_member_english_title,'')),p_medium,trim(coalesce(p_medium_details,'')),trim(coalesce(p_camera,'')),
    trim(coalesce(p_lens,'')),trim(coalesce(p_film,'')),p_description_choice,trim(coalesce(p_description_ja,'')),
    trim(coalesce(p_description_en,'')),p_instagram_qr_choice,trim(coalesce(p_instagram_qr_info,'')),p_instagram_qr_path)
  on conflict(work_id) do update set display_name=excluded.display_name,english_title_mode=excluded.english_title_mode,
    member_english_title=excluded.member_english_title,medium=excluded.medium,medium_details=excluded.medium_details,
    camera=excluded.camera,lens=excluded.lens,film=excluded.film,description_choice=excluded.description_choice,
    description_ja=excluded.description_ja,description_en=excluded.description_en,instagram_qr_choice=excluded.instagram_qr_choice,
    instagram_qr_info=excluded.instagram_qr_info,instagram_qr_path=excluded.instagram_qr_path,updated_at=now()
  returning * into c;
  perform private.write_exhibition_workflow_audit(w.event_id,'caption_working_data',w.id,'caption_draft_saved','member',actor);
  return to_jsonb(c);
end;
$$;

create or replace function public.submit_exhibition_caption_v2(p_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; e public.events%rowtype; c public.exhibition_caption_working_data%rowtype;
  s public.exhibition_caption_submission_snapshots%rowtype; open_case public.exhibition_caption_workflow_cases%rowtype;
  mid uuid:=private.current_member_id(); actor text:=private.current_email(); next_version integer;
begin
  select * into w from public.exhibition_works where id=p_work_id and owner_member_id=mid for update;
  select * into e from public.events where id=w.event_id;
  select * into c from public.exhibition_caption_working_data where work_id=w.id for update;
  if w.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Workが見つかりません。'; end if;
  if w.workflow_state<>'accepted' then raise exception 'Work確認済み後にCaptionを提出できます。'; end if;
  if c.work_id is null or c.state not in ('draft','rejected','reedit_editing') or not private.caption_edit_is_open(c,e) then
    raise exception '現在Captionを正式提出できません。';
  end if;
  perform private.validate_caption_v2_values(c);
  if c.state='reedit_editing' and c.current_accepted_snapshot_id is not null and not exists(
    select 1 from public.exhibition_caption_submission_snapshots old where old.id=c.current_accepted_snapshot_id and (
      old.display_name<>c.display_name or old.english_title_mode<>c.english_title_mode or old.member_english_title<>c.member_english_title
      or old.medium<>c.medium or old.medium_details<>c.medium_details or old.camera<>c.camera or old.lens<>c.lens or old.film<>c.film
      or old.description_choice<>c.description_choice or old.description_ja<>c.description_ja or old.description_en<>c.description_en
      or old.instagram_qr_choice<>c.instagram_qr_choice or old.instagram_qr_info<>c.instagram_qr_info
      or old.instagram_qr_path is distinct from c.instagram_qr_path)) then raise exception '変更内容がありません。'; end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_caption_submission_snapshots where work_id=w.id;
  insert into public.exhibition_caption_submission_snapshots(work_id,event_id,entry_id,member_id,version_no,display_name,
    english_title_mode,member_english_title,medium,medium_details,camera,lens,film,description_choice,description_ja,
    description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,submitted_by_member_id,submitted_by_identifier)
  values(w.id,w.event_id,w.entry_id,w.owner_member_id,next_version,c.display_name,c.english_title_mode,c.member_english_title,
    c.medium,c.medium_details,c.camera,c.lens,c.film,c.description_choice,c.description_ja,c.description_en,
    c.instagram_qr_choice,c.instagram_qr_info,c.instagram_qr_path,mid,actor) returning * into s;
  update public.exhibition_caption_working_data set state='submitted',current_submission_snapshot_id=s.id,updated_at=now() where work_id=w.id;
  select * into open_case from public.exhibition_caption_workflow_cases where work_id=w.id and state in ('open','permitted') for update;
  if open_case.id is not null then update public.exhibition_caption_workflow_cases set state='resubmitted',closed_at=now() where id=open_case.id; end if;
  perform private.write_exhibition_workflow_audit(w.event_id,'caption_submission_snapshot',s.id,
    case when next_version=1 then 'caption_submitted' when open_case.case_type='correction' then 'caption_correction_resubmitted' else 'caption_reedit_resubmitted' end,
    'member',actor,'','{}',jsonb_build_object('workId',w.id,'versionNo',next_version));
  return jsonb_build_object('snapshotId',s.id,'versionNo',next_version,'state','submitted');
end;
$$;

create or replace function public.admin_review_exhibition_caption_v2(
  p_caption_snapshot_id uuid,p_result text,p_problem_fields text[],p_reason text,p_individual_deadline timestamptz default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.exhibition_caption_submission_snapshots%rowtype; c public.exhibition_caption_working_data%rowtype;
  e public.events%rowtype; review_id uuid; deadline timestamptz; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_result not in ('accepted','rejected') then raise exception 'Review結果が不正です。'; end if;
  if p_result='rejected' and (coalesce(cardinality(p_problem_fields),0)=0 or trim(coalesce(p_reason,''))='') then raise exception 'Rejectには問題項目と理由が必要です。'; end if;
  select * into s from public.exhibition_caption_submission_snapshots where id=p_caption_snapshot_id;
  select * into c from public.exhibition_caption_working_data where work_id=s.work_id for update;
  select * into e from public.events where id=s.event_id;
  if s.id is null or e.exhibition_workflow_version<>2 or c.state<>'submitted' or c.current_submission_snapshot_id is distinct from s.id then
    raise exception 'Review対象が古いか、すでに処理済みです。';
  end if;
  if p_result='rejected' then
    deadline:=case when now()<e.exhibition_caption_deadline then e.exhibition_caption_deadline else p_individual_deadline end;
    if deadline is null or deadline<=now() then raise exception 'Caption期限後のRejectには未来のIndividual Deadlineが必要です。'; end if;
  end if;
  insert into public.exhibition_caption_reviews(work_id,caption_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(s.work_id,s.id,actor,p_result,coalesce(p_problem_fields,'{}'),coalesce(p_reason,'')) returning id into review_id;
  if p_result='accepted' then
    update public.exhibition_caption_working_data set state='accepted',current_accepted_snapshot_id=s.id,updated_at=now() where work_id=s.work_id;
  else
    update public.exhibition_caption_working_data set state='rejected',updated_at=now() where work_id=s.work_id;
    insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
      values(s.work_id,s.event_id,s.member_id,'correction',s.id,review_id,'open',p_reason,deadline,now());
  end if;
  perform private.write_exhibition_workflow_audit(s.event_id,'caption_review',review_id,
    case when p_result='accepted' then 'caption_accepted' else 'caption_rejected' end,'admin',actor,p_reason,
    jsonb_build_object('snapshotId',s.id),jsonb_build_object('result',p_result,'problemFields',coalesce(p_problem_fields,'{}'),'deadline',deadline));
  return jsonb_build_object('reviewId',review_id,'result',p_result,'correctionDeadline',deadline);
end;
$$;

create or replace function public.request_exhibition_caption_reedit_v2(p_work_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_caption_working_data%rowtype; case_id uuid; actor text:=private.current_email();
begin
  if trim(coalesce(p_reason,''))='' then raise exception '再編集申請理由は必須です。'; end if;
  select cw.* into c from public.exhibition_caption_working_data cw where cw.work_id=p_work_id and cw.member_id=private.current_member_id() for update;
  if c.work_id is null or c.state<>'accepted' or c.current_accepted_snapshot_id is null then raise exception '確認済みCaptionが見つかりません。'; end if;
  insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,state,request_reason)
    values(c.work_id,c.event_id,c.member_id,'reedit',c.current_accepted_snapshot_id,'pending',p_reason) returning id into case_id;
  update public.exhibition_caption_working_data set state='reedit_pending',updated_at=now() where work_id=c.work_id;
  perform private.write_exhibition_workflow_audit(c.event_id,'caption_case',case_id,'caption_reedit_requested','member',actor,p_reason);
  return jsonb_build_object('caseId',case_id,'state','pending');
end;
$$;

create or replace function public.admin_decide_exhibition_caption_reedit_v2(p_case_id uuid,p_permit boolean,p_reason text,p_individual_deadline timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_caption_workflow_cases%rowtype; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '判断理由は必須です。'; end if;
  select * into c from public.exhibition_caption_workflow_cases where id=p_case_id for update;
  if c.id is null or c.case_type<>'reedit' or c.state<>'pending' then raise exception '判断可能なCaption再編集申請がありません。'; end if;
  if p_permit and (p_individual_deadline is null or p_individual_deadline<=now()) then raise exception '未来の個別期限が必要です。'; end if;
  update public.exhibition_caption_workflow_cases set state=case when p_permit then 'permitted' else 'rejected' end,
    decision_reason=p_reason,individual_deadline=case when p_permit then p_individual_deadline end,decided_at=now(),
    closed_at=case when p_permit then null else now() end where id=c.id;
  update public.exhibition_caption_working_data set state=case when p_permit then 'reedit_editing' else 'accepted' end,updated_at=now() where work_id=c.work_id;
  perform private.write_exhibition_workflow_audit(c.event_id,'caption_case',c.id,
    case when p_permit then 'caption_reedit_permitted' else 'caption_reedit_rejected' end,'admin',actor,p_reason,'{}',jsonb_build_object('deadline',p_individual_deadline));
  return jsonb_build_object('caseId',c.id,'state',case when p_permit then 'permitted' else 'rejected' end);
end;
$$;

create or replace function public.cancel_exhibition_caption_reedit_v2(p_case_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_caption_workflow_cases%rowtype; s public.exhibition_caption_submission_snapshots%rowtype; actor text:=private.current_email();
begin
  select * into c from public.exhibition_caption_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
  if c.id is null or c.case_type<>'reedit' or c.state not in ('pending','permitted') then raise exception '取消可能なCaption再編集申請がありません。'; end if;
  select * into s from public.exhibition_caption_submission_snapshots where id=c.source_caption_snapshot_id;
  update public.exhibition_caption_workflow_cases set state=case when c.state='pending' then 'cancelled' else 'restored' end,closed_at=now() where id=c.id;
  update public.exhibition_caption_working_data set state='accepted',display_name=s.display_name,english_title_mode=s.english_title_mode,
    member_english_title=s.member_english_title,medium=s.medium,medium_details=s.medium_details,camera=s.camera,lens=s.lens,film=s.film,
    description_choice=s.description_choice,description_ja=s.description_ja,description_en=s.description_en,
    instagram_qr_choice=s.instagram_qr_choice,instagram_qr_info=s.instagram_qr_info,instagram_qr_path=s.instagram_qr_path,updated_at=now()
  where work_id=c.work_id;
  perform private.write_exhibition_workflow_audit(c.event_id,'caption_case',c.id,'caption_reedit_cancelled_or_restored','member',actor,p_reason);
  return jsonb_build_object('caseId',c.id,'state','accepted');
end;
$$;

create or replace function public.admin_set_exhibition_caption_organizer_title_v2(p_caption_snapshot_id uuid,p_english_title text,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.exhibition_caption_submission_snapshots%rowtype; c public.exhibition_caption_working_data%rowtype;
  result_id uuid; next_version integer; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_english_title,''))='' then raise exception '英語作品名を入力してください。'; end if;
  select * into s from public.exhibition_caption_submission_snapshots where id=p_caption_snapshot_id;
  if s.id is null or s.english_title_mode<>'organizer' then raise exception '主催者英訳対象のSnapshotではありません。'; end if;
  select * into c from public.exhibition_caption_working_data where work_id=s.work_id;
  if c.current_submission_snapshot_id is distinct from s.id and c.current_accepted_snapshot_id is distinct from s.id then
    raise exception '古いCaption Snapshotへ主催者英題を追加できません。';
  end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_caption_english_title_derivations where work_id=s.work_id;
  insert into public.exhibition_caption_english_title_derivations(work_id,source_caption_snapshot_id,version_no,english_title,created_by_identifier,reason)
    values(s.work_id,s.id,next_version,trim(p_english_title),actor,coalesce(p_reason,'')) returning id into result_id;
  perform private.write_exhibition_workflow_audit(s.event_id,'caption_english_title_derivation',result_id,'organizer_english_title_derived','admin',actor,p_reason,
    '{}',jsonb_build_object('sourceCaptionSnapshotId',s.id,'versionNo',next_version));
  return jsonb_build_object('derivationId',result_id,'versionNo',next_version);
end;
$$;

create or replace function public.admin_process_exhibition_caption_deadlines_v2(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_caption_workflow_cases%rowtype; count_expired integer:=0;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  if not exists(select 1 from public.events where id=p_event_id and exhibition_workflow_version=2) then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  for c in select * from public.exhibition_caption_workflow_cases where event_id=p_event_id and state in ('open','permitted') and individual_deadline<=now() for update loop
    update public.exhibition_caption_workflow_cases set state='expired',closed_at=now() where id=c.id and state in ('open','permitted');
    if found then
      update public.exhibition_caption_working_data set state=case when current_accepted_snapshot_id is null then 'rejected' else 'accepted' end,updated_at=now() where work_id=c.work_id;
      count_expired:=count_expired+1;
      perform private.write_exhibition_workflow_audit(c.event_id,'caption_case',c.id,'caption_case_expired','system','system','individual_deadline_expired');
    end if;
  end loop;
  return jsonb_build_object('casesExpired',count_expired);
end;
$$;

create or replace function public.admin_rescue_exhibition_caption_case_v2(
  p_work_id uuid,p_case_type text,p_reason text,p_exception_deadline timestamptz
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.exhibition_caption_working_data%rowtype; s public.exhibition_caption_submission_snapshots%rowtype;
  case_id uuid; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_case_type not in ('correction','reedit') or trim(coalesce(p_reason,''))='' or p_exception_deadline<=now() then
    raise exception '救済種別、理由、未来の個別期限が必要です。';
  end if;
  select * into c from public.exhibition_caption_working_data where work_id=p_work_id for update;
  if c.work_id is null or (p_case_type='correction' and c.correction_rescue_count>=1)
     or (p_case_type='reedit' and c.reedit_rescue_count>=1) then raise exception 'このCaptionは救済できません。'; end if;
  select * into s from public.exhibition_caption_submission_snapshots where id=coalesce(c.current_submission_snapshot_id,c.current_accepted_snapshot_id);
  if s.id is null then raise exception '救済元のCaption Snapshotがありません。'; end if;
  if exists(select 1 from public.exhibition_caption_workflow_cases where work_id=p_work_id and state in ('pending','open','permitted')) then
    raise exception '未完了のCaption Caseがあります。';
  end if;
  insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,state,decision_reason,individual_deadline,decided_at)
  values(c.work_id,c.event_id,c.member_id,p_case_type,s.id,case when p_case_type='correction' then 'open' else 'permitted' end,p_reason,p_exception_deadline,now()) returning id into case_id;
  update public.exhibition_caption_working_data set state=case when p_case_type='correction' then 'rejected' else 'reedit_editing' end,
    correction_rescue_count=correction_rescue_count+case when p_case_type='correction' then 1 else 0 end,
    reedit_rescue_count=reedit_rescue_count+case when p_case_type='reedit' then 1 else 0 end,updated_at=now() where work_id=p_work_id;
  perform private.write_exhibition_workflow_audit(c.event_id,'caption_case',case_id,'caption_case_rescued','admin',actor,p_reason,'{}',
    jsonb_build_object('caseType',p_case_type,'exceptionDeadline',p_exception_deadline));
  return jsonb_build_object('caseId',case_id,'exceptionDeadline',p_exception_deadline);
end;
$$;

alter table public.exhibition_caption_working_data enable row level security;
alter table public.exhibition_caption_submission_snapshots enable row level security;
alter table public.exhibition_caption_reviews enable row level security;
alter table public.exhibition_caption_workflow_cases enable row level security;
alter table public.exhibition_caption_english_title_derivations enable row level security;

create policy caption_working_owner_or_admin_select on public.exhibition_caption_working_data for select to authenticated
using(member_id=private.current_member_id() or private.is_admin());
create policy caption_snapshots_owner_or_admin_select on public.exhibition_caption_submission_snapshots for select to authenticated
using(member_id=private.current_member_id() or private.is_admin());
create policy caption_reviews_owner_or_admin_select on public.exhibition_caption_reviews for select to authenticated
using(private.is_admin() or exists(select 1 from public.exhibition_caption_submission_snapshots s where s.id=caption_snapshot_id and s.member_id=private.current_member_id()));
create policy caption_cases_owner_or_admin_select on public.exhibition_caption_workflow_cases for select to authenticated
using(member_id=private.current_member_id() or private.is_admin());
create policy caption_derivations_owner_or_admin_select on public.exhibition_caption_english_title_derivations for select to authenticated
using(private.is_admin() or exists(select 1 from public.exhibition_works w where w.id=work_id and w.owner_member_id=private.current_member_id()));

grant select on public.exhibition_caption_working_data,public.exhibition_caption_submission_snapshots,
  public.exhibition_caption_reviews,public.exhibition_caption_workflow_cases,public.exhibition_caption_english_title_derivations to authenticated;
revoke insert,update,delete on public.exhibition_caption_working_data,public.exhibition_caption_submission_snapshots,
  public.exhibition_caption_reviews,public.exhibition_caption_workflow_cases,public.exhibition_caption_english_title_derivations from public,anon,authenticated;

revoke all on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text),
  public.submit_exhibition_caption_v2(uuid),public.admin_review_exhibition_caption_v2(uuid,text,text[],text,timestamptz),
  public.request_exhibition_caption_reedit_v2(uuid,text),public.admin_decide_exhibition_caption_reedit_v2(uuid,boolean,text,timestamptz),
  public.cancel_exhibition_caption_reedit_v2(uuid,text),public.admin_set_exhibition_caption_organizer_title_v2(uuid,text,text),
  public.admin_process_exhibition_caption_deadlines_v2(uuid),public.admin_rescue_exhibition_caption_case_v2(uuid,text,text,timestamptz) from public,anon;
grant execute on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text),
  public.submit_exhibition_caption_v2(uuid),public.admin_review_exhibition_caption_v2(uuid,text,text[],text,timestamptz),
  public.request_exhibition_caption_reedit_v2(uuid,text),public.admin_decide_exhibition_caption_reedit_v2(uuid,boolean,text,timestamptz),
  public.cancel_exhibition_caption_reedit_v2(uuid,text),public.admin_set_exhibition_caption_organizer_title_v2(uuid,text,text),
  public.admin_process_exhibition_caption_deadlines_v2(uuid),public.admin_rescue_exhibition_caption_case_v2(uuid,text,text,timestamptz) to authenticated;
grant execute on function public.admin_process_exhibition_caption_deadlines_v2(uuid) to service_role;
