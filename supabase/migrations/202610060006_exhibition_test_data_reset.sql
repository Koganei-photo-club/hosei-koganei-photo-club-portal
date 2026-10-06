-- Maintenance Admin専用の写真展Smoke TestデータReset。
-- 通常Workflowの履歴保護は維持し、専用RPCのtransaction内だけ削除を許可する。

create table public.exhibition_test_reset_jobs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  executed_by text not null references public.maintenance_admins(email) on update cascade on delete restrict,
  reason text not null check(trim(reason)<>'' and char_length(reason)<=2000),
  preview_token text not null check(preview_token~'^[0-9a-f]{64}$'),
  preview_summary jsonb not null check(jsonb_typeof(preview_summary)='object'),
  executed_at timestamptz not null default now(),
  db_reset_status text not null default 'completed' check(db_reset_status in('completed','failed')),
  storage_cleanup_status text not null default 'pending' check(storage_cleanup_status in('pending','completed','partial','failed')),
  storage_paths jsonb not null default '[]'::jsonb check(jsonb_typeof(storage_paths)='array'),
  storage_success_paths jsonb not null default '[]'::jsonb check(jsonb_typeof(storage_success_paths)='array'),
  storage_failed_paths jsonb not null default '[]'::jsonb check(jsonb_typeof(storage_failed_paths)='array'),
  retry_count integer not null default 0 check(retry_count>=0),
  completed_at timestamptz,
  error_info text not null default '' check(char_length(error_info)<=5000)
);

alter table public.exhibition_test_reset_jobs enable row level security;
revoke all on public.exhibition_test_reset_jobs from anon,authenticated;
grant select on public.exhibition_test_reset_jobs to authenticated;
create policy exhibition_test_reset_jobs_maintenance_select on public.exhibition_test_reset_jobs
for select to authenticated using(private.is_maintenance_admin());

create or replace function private.exhibition_test_reset_preview_data_v1(p_event_id uuid,p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ev public.events%rowtype; mem public.members%rowtype; en public.exhibition_entries%rowtype;
  result jsonb; blockers jsonb:='[]'::jsonb; storage_items jsonb:='[]'::jsonb;
  target_ids jsonb; token text; bad_paths integer:=0; phase2_count integer:=0;
begin
  select * into ev from public.events where id=p_event_id;
  select * into mem from public.members where id=p_member_id;
  if ev.id is null then raise exception '対象Eventが見つかりません。'; end if;
  if mem.id is null then raise exception '対象Memberが見つかりません。'; end if;
  if ev.genre<>'exhibition' then raise exception '対象Eventは写真展ではありません。'; end if;
  select * into en from public.exhibition_entries where event_id=p_event_id and member_id=p_member_id;

  with works as(select id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id),
  smartphones as(select id from public.exhibition_smartphone_works where event_id=p_event_id and member_id=p_member_id),
  app_snaps as(select id from public.exhibition_application_snapshots where event_id=p_event_id and member_id=p_member_id),
  accepts as(select id from public.exhibition_application_agreement_acceptances where event_id=p_event_id and member_id=p_member_id),
  batches as(select id from public.exhibition_work_submission_batches where event_id=p_event_id and member_id=p_member_id),
  work_snaps as(select id from public.exhibition_work_submission_snapshots where event_id=p_event_id and member_id=p_member_id),
  work_reviews as(select r.id from public.exhibition_work_reviews r join works w on w.id=r.work_id),
  work_cases as(select id from public.exhibition_workflow_cases where event_id=p_event_id and member_id=p_member_id),
  captions as(select work_id id from public.exhibition_caption_working_data where event_id=p_event_id and member_id=p_member_id),
  caption_snaps as(select id from public.exhibition_caption_submission_snapshots where event_id=p_event_id and member_id=p_member_id),
  caption_reviews as(select r.id from public.exhibition_caption_reviews r join works w on w.id=r.work_id),
  caption_cases as(select id from public.exhibition_caption_workflow_cases where event_id=p_event_id and member_id=p_member_id),
  derivations as(select d.id from public.exhibition_caption_english_title_derivations d join works w on w.id=d.work_id),
  phone_snaps as(select id from public.exhibition_smartphone_work_submission_snapshots where event_id=p_event_id and member_id=p_member_id),
  phone_reviews as(select r.id from public.exhibition_smartphone_work_reviews r join smartphones w on w.id=r.smartphone_work_id),
  phone_cases as(select id from public.exhibition_smartphone_workflow_cases where event_id=p_event_id and member_id=p_member_id)
  select jsonb_build_object(
    'entryIds',coalesce((select jsonb_agg(id order by id) from (select en.id where en.id is not null)x),'[]'::jsonb),
    'applicationSnapshotIds',coalesce((select jsonb_agg(id order by id) from app_snaps),'[]'::jsonb),
    'agreementAcceptanceIds',coalesce((select jsonb_agg(id order by id) from accepts),'[]'::jsonb),
    'regularWorkIds',coalesce((select jsonb_agg(id order by id) from works),'[]'::jsonb),
    'workBatchIds',coalesce((select jsonb_agg(id order by id) from batches),'[]'::jsonb),
    'workSnapshotIds',coalesce((select jsonb_agg(id order by id) from work_snaps),'[]'::jsonb),
    'workReviewIds',coalesce((select jsonb_agg(id order by id) from work_reviews),'[]'::jsonb),
    'workCaseIds',coalesce((select jsonb_agg(id order by id) from work_cases),'[]'::jsonb),
    'captionWorkingIds',coalesce((select jsonb_agg(id order by id) from captions),'[]'::jsonb),
    'captionSnapshotIds',coalesce((select jsonb_agg(id order by id) from caption_snaps),'[]'::jsonb),
    'captionReviewIds',coalesce((select jsonb_agg(id order by id) from caption_reviews),'[]'::jsonb),
    'captionCaseIds',coalesce((select jsonb_agg(id order by id) from caption_cases),'[]'::jsonb),
    'englishTitleDerivationIds',coalesce((select jsonb_agg(id order by id) from derivations),'[]'::jsonb),
    'smartphoneWorkIds',coalesce((select jsonb_agg(id order by id) from smartphones),'[]'::jsonb),
    'smartphoneSnapshotIds',coalesce((select jsonb_agg(id order by id) from phone_snaps),'[]'::jsonb),
    'smartphoneReviewIds',coalesce((select jsonb_agg(id order by id) from phone_reviews),'[]'::jsonb),
    'smartphoneCaseIds',coalesce((select jsonb_agg(id order by id) from phone_cases),'[]'::jsonb),
    'stateSignatures',jsonb_build_object(
      'entry',case when en.id is null then null else encode(extensions.digest(convert_to(to_jsonb(en)::text,'UTF8'),'sha256'),'hex') end,
      'works',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(w)::text,'UTF8'),'sha256'),'hex') order by w.id) from public.exhibition_works w where w.event_id=p_event_id and w.owner_member_id=p_member_id),'[]'::jsonb),
      'smartphoneWorks',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(w)::text,'UTF8'),'sha256'),'hex') order by w.id) from public.exhibition_smartphone_works w where w.event_id=p_event_id and w.member_id=p_member_id),'[]'::jsonb),
      'captions',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(c)::text,'UTF8'),'sha256'),'hex') order by c.work_id) from public.exhibition_caption_working_data c where c.event_id=p_event_id and c.member_id=p_member_id),'[]'::jsonb),
      'workCases',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(c)::text,'UTF8'),'sha256'),'hex') order by c.id) from public.exhibition_workflow_cases c where c.event_id=p_event_id and c.member_id=p_member_id),'[]'::jsonb),
      'captionCases',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(c)::text,'UTF8'),'sha256'),'hex') order by c.id) from public.exhibition_caption_workflow_cases c where c.event_id=p_event_id and c.member_id=p_member_id),'[]'::jsonb),
      'smartphoneCases',coalesce((select jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(c)::text,'UTF8'),'sha256'),'hex') order by c.id) from public.exhibition_smartphone_workflow_cases c where c.event_id=p_event_id and c.member_id=p_member_id),'[]'::jsonb)
    )
  ) into target_ids;
  target_ids:=target_ids||jsonb_build_object('allEntityIds',
    (target_ids->'entryIds')||(target_ids->'applicationSnapshotIds')||(target_ids->'agreementAcceptanceIds')||
    (target_ids->'regularWorkIds')||(target_ids->'workBatchIds')||(target_ids->'workSnapshotIds')||
    (target_ids->'workReviewIds')||(target_ids->'workCaseIds')||(target_ids->'captionSnapshotIds')||
    (target_ids->'captionReviewIds')||(target_ids->'captionCaseIds')||(target_ids->'englishTitleDerivationIds')||
    (target_ids->'smartphoneWorkIds')||(target_ids->'smartphoneSnapshotIds')||(target_ids->'smartphoneReviewIds')||(target_ids->'smartphoneCaseIds'));

  with paths as(
    select 'exhibition-originals' bucket,original_image_path path,id work_id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id
    union select 'exhibition-previews',preview_image_path,id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id
    union select 'exhibition-previews',instagram_qr_path,id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id
    union select 'exhibition-public',public_image_path,id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id
    union select 'exhibition-originals',s.original_image_path,s.work_id from public.exhibition_work_submission_snapshots s where s.event_id=p_event_id and s.member_id=p_member_id
    union select 'exhibition-previews',c.instagram_qr_path,c.work_id from public.exhibition_caption_working_data c where c.event_id=p_event_id and c.member_id=p_member_id
    union select 'exhibition-previews',c.instagram_qr_path,c.work_id from public.exhibition_caption_submission_snapshots c where c.event_id=p_event_id and c.member_id=p_member_id
    union select 'exhibition-originals',w.original_image_path,w.id from public.exhibition_smartphone_works w where w.event_id=p_event_id and w.member_id=p_member_id
    union select 'exhibition-originals',s.original_image_path,s.smartphone_work_id from public.exhibition_smartphone_work_submission_snapshots s where s.event_id=p_event_id and s.member_id=p_member_id
  ), clean as(select distinct bucket,path,work_id from paths where path is not null and trim(path)<>'')
  select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket,'path',path,'workId',work_id) order by bucket,path),'[]'::jsonb),
    count(*) filter(where split_part(path,'/',1)<>p_event_id::text or split_part(path,'/',2)<>p_member_id::text or split_part(path,'/',3)<>work_id::text or split_part(path,'/',4)='' or split_part(path,'/',5)<>'')
  into storage_items,bad_paths from clean;

  if en.id is null then blockers:=blockers||jsonb_build_array('対象MemberのEntryがありません。'); end if;
  if exists(select 1 from public.exhibition_placements p join public.exhibition_works w on w.id=p.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Layout Placementが存在します。'); end if;
  if exists(select 1 from public.exhibition_work_display_numbers n join public.exhibition_works w on w.id=n.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('展示番号が存在します。'); end if;
  if exists(select 1 from public.exhibition_layout_finalization_items i join public.exhibition_works w on w.id=i.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Layout Finalizationが存在します。'); end if;
  if exists(select 1 from public.exhibition_export_items i join public.exhibition_works w on w.id=i.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Exportが存在します。'); end if;
  if exists(select 1 from public.exhibition_publication_items i join public.exhibition_works w on w.id=i.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Publicationが存在します。'); end if;
  if exists(select 1 from public.exhibition_survey_selections s join public.exhibition_works w on w.id=s.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('第三者のSurvey回答が存在します。'); end if;
  if exists(select 1 from public.exhibition_actual_items i join public.exhibition_works w on w.id=i.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Actual記録が存在します。'); end if;
  if exists(select 1 from public.exhibition_archive_items i join public.exhibition_works w on w.id=i.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('Archiveが存在します。'); end if;
  -- コメントには投稿者列がないため、安全上すべて第三者由来として扱う。
  if exists(select 1 from public.exhibition_work_comments c join public.exhibition_works w on w.id=c.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id) then blockers:=blockers||jsonb_build_array('投稿者を特定できない作品コメントが存在します。'); end if;
  if bad_paths>0 then blockers:=blockers||jsonb_build_array('対象Event・Member・Workに一致しないStorage pathがあります。'); end if;
  if to_regclass('public.exhibition_smartphone_display_items') is not null then
    execute 'select count(*) from public.exhibition_smartphone_display_items where event_id=$1 and member_id=$2' into phase2_count using p_event_id,p_member_id;
    if phase2_count>0 then blockers:=blockers||jsonb_build_array('Smartphone Phase 2 Display Itemが存在します。'); end if;
  end if;

  result:=jsonb_build_object(
    'eventId',ev.id,'eventName',ev.title,'memberId',mem.id,'memberNo',mem.member_no,'email',mem.email,
    'entryId',en.id,'targets',target_ids,'storageObjects',storage_items,'shiftPreserved',true,
    'counts',jsonb_build_object(
      'applicationSnapshots',jsonb_array_length(target_ids->'applicationSnapshotIds'),'agreementAcceptances',jsonb_array_length(target_ids->'agreementAcceptanceIds'),
      'regularWorks',jsonb_array_length(target_ids->'regularWorkIds'),'workSubmissionBatches',jsonb_array_length(target_ids->'workBatchIds'),
      'workSnapshots',jsonb_array_length(target_ids->'workSnapshotIds'),'workReviews',jsonb_array_length(target_ids->'workReviewIds'),'workWorkflowCases',jsonb_array_length(target_ids->'workCaseIds'),
      'workComments',(select count(*) from public.exhibition_work_comments c join public.exhibition_works w on w.id=c.work_id where w.event_id=p_event_id and w.owner_member_id=p_member_id),
      'captionWorkingData',jsonb_array_length(target_ids->'captionWorkingIds'),'captionSnapshots',jsonb_array_length(target_ids->'captionSnapshotIds'),
      'captionReviews',jsonb_array_length(target_ids->'captionReviewIds'),'captionWorkflowCases',jsonb_array_length(target_ids->'captionCaseIds'),
      'englishTitleDerivations',jsonb_array_length(target_ids->'englishTitleDerivationIds'),'smartphoneWorks',jsonb_array_length(target_ids->'smartphoneWorkIds'),
      'smartphoneSnapshots',jsonb_array_length(target_ids->'smartphoneSnapshotIds'),'smartphoneReviews',jsonb_array_length(target_ids->'smartphoneReviewIds'),
      'smartphoneWorkflowCases',jsonb_array_length(target_ids->'smartphoneCaseIds')),
    'auditCount',(select count(*) from public.exhibition_workflow_audit_logs a where a.event_id=p_event_id and a.entity_id in(select (value#>>'{}')::uuid from jsonb_array_elements(target_ids->'allEntityIds'))),
    'canReset',jsonb_array_length(blockers)=0,'blockers',blockers
  );
  token:=encode(extensions.digest(convert_to(result::text,'UTF8'),'sha256'),'hex');
  return result||jsonb_build_object('previewToken',token);
end;$$;

create or replace function public.maintenance_preview_exhibition_test_reset_v1(p_event_id uuid,p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin perform private.require_maintenance_admin();return private.exhibition_test_reset_preview_data_v1(p_event_id,p_member_id);end;$$;

create or replace function public.maintenance_list_exhibition_reset_targets_v1()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_maintenance_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
    'eventId',e.id,'eventName',e.title,'memberId',m.id,'memberNo',m.member_no,'email',m.email,'name',m.name,
    'entryId',en.id,'applicationState',en.application_state,'revivalCount',en.revival_count
  ) order by e.starts_at desc,m.member_no)
  from public.exhibition_entries en join public.events e on e.id=en.event_id join public.members m on m.id=en.member_id
  where e.genre='exhibition'),'[]'::jsonb);
end;$$;

-- immutable関数は専用transaction flagかつMaintenance Adminの場合だけDELETEを許す。
create or replace function private.exhibition_test_reset_delete_allowed_v1()
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce(current_setting('app.exhibition_test_reset_rpc',true),'')='on' and private.is_maintenance_admin()
$$;
drop trigger exhibition_entries_validate_before_write on public.exhibition_entries;
create trigger exhibition_entries_validate_before_write before insert or update on public.exhibition_entries
for each row when (not private.exhibition_test_reset_delete_allowed_v1()) execute function private.validate_exhibition_entry();
create or replace function private.prevent_exhibition_application_snapshot_mutation() returns trigger language plpgsql security definer set search_path='' as $$begin if tg_op='DELETE' and private.exhibition_test_reset_delete_allowed_v1() then return old;end if;raise exception 'Application Snapshotは変更または削除できません。';end;$$;
create or replace function private.prevent_exhibition_work_history_mutation() returns trigger language plpgsql security definer set search_path='' as $$begin if tg_op='DELETE' and private.exhibition_test_reset_delete_allowed_v1() then return old;end if;raise exception 'Workの正式履歴は変更または削除できません。';end;$$;
create or replace function private.prevent_exhibition_caption_history_mutation() returns trigger language plpgsql security definer set search_path='' as $$begin if tg_op='DELETE' and private.exhibition_test_reset_delete_allowed_v1() then return old;end if;raise exception 'Captionの正式履歴は変更または削除できません。';end;$$;
create or replace function private.prevent_exhibition_smartphone_history_mutation() returns trigger language plpgsql security definer set search_path='' as $$begin if tg_op='DELETE' and private.exhibition_test_reset_delete_allowed_v1() then return old;end if;raise exception 'スマホ作品の正式履歴は変更または削除できません。';end;$$;
create or replace function private.prevent_exhibition_agreement_acceptance_mutation() returns trigger language plpgsql security definer set search_path='' as $$begin if tg_op='DELETE' and private.exhibition_test_reset_delete_allowed_v1() then return old;end if;raise exception 'Application Agreement同意履歴は変更または削除できません。';end;$$;

create or replace function public.maintenance_execute_exhibition_test_reset_v1(p_event_id uuid,p_member_id uuid,p_preview_token text,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text; preview jsonb; en_id uuid; job_id uuid; ids uuid[];
begin
  actor:=private.require_maintenance_admin();
  if trim(coalesce(p_reason,''))='' then raise exception '実行理由は必須です。';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text||':'||p_member_id::text,0));
  perform 1 from public.events where id=p_event_id for update;
  perform 1 from public.members where id=p_member_id for update;
  preview:=private.exhibition_test_reset_preview_data_v1(p_event_id,p_member_id);
  if preview->>'previewToken' is distinct from lower(trim(coalesce(p_preview_token,''))) then raise exception 'Preview後に対象データが変更されました。もう一度Previewしてください。';end if;
  if not (preview->>'canReset')::boolean then raise exception 'Reset禁止条件があります: %',preview->'blockers';end if;
  en_id:=(preview->>'entryId')::uuid;
  insert into public.exhibition_test_reset_jobs(event_id,member_id,executed_by,reason,preview_token,preview_summary,storage_paths)
  values(p_event_id,p_member_id,actor,trim(p_reason),p_preview_token,preview,preview->'storageObjects') returning id into job_id;
  perform set_config('app.exhibition_test_reset_rpc','on',true);
  perform set_config('app.exhibition_application_rpc','on',true);
  perform set_config('app.exhibition_work_rpc','on',true);
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);

  update public.exhibition_entries set current_application_snapshot_id=null where id=en_id;
  update public.exhibition_works set current_submission_snapshot_id=null,current_accepted_snapshot_id=null,replacement_for_work_id=null
    where event_id=p_event_id and owner_member_id=p_member_id;
  update public.exhibition_caption_working_data set current_submission_snapshot_id=null,current_accepted_snapshot_id=null
    where event_id=p_event_id and member_id=p_member_id;
  update public.exhibition_smartphone_works set current_submission_snapshot_id=null,current_accepted_snapshot_id=null
    where event_id=p_event_id and member_id=p_member_id;

  -- 対象UUIDに紐づくAuditだけを削除し、Event全体Auditは保持する。
  select array_agg((value#>>'{}')::uuid) into ids from jsonb_array_elements(preview#>'{targets,allEntityIds}');
  delete from public.exhibition_workflow_audit_logs where event_id=p_event_id and entity_id=any(coalesce(ids,'{}'::uuid[]));

  delete from public.exhibition_smartphone_workflow_cases where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_smartphone_work_reviews where smartphone_work_id in(select id from public.exhibition_smartphone_works where event_id=p_event_id and member_id=p_member_id);
  delete from public.exhibition_smartphone_work_submission_snapshots where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_smartphone_works where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_caption_workflow_cases where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_caption_reviews where work_id in(select id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id);
  delete from public.exhibition_caption_english_title_derivations where work_id in(select id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id);
  delete from public.exhibition_caption_submission_snapshots where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_caption_working_data where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_workflow_cases where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_work_reviews where work_id in(select id from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id);
  delete from public.exhibition_work_submission_snapshots where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_work_submission_batches where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_works where event_id=p_event_id and owner_member_id=p_member_id;
  delete from public.exhibition_application_agreement_acceptances where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_application_snapshots where event_id=p_event_id and member_id=p_member_id;
  delete from public.exhibition_entries where id=en_id;
  perform set_config('app.exhibition_test_reset_rpc','off',true);
  return jsonb_build_object('jobId',job_id,'dbResetStatus','completed','storageCleanupStatus','pending','storageObjects',preview->'storageObjects');
end;$$;

create or replace function public.maintenance_update_exhibition_reset_storage_v1(p_job_id uuid,p_success_paths jsonb,p_failed_paths jsonb,p_error text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=private.require_maintenance_admin();job public.exhibition_test_reset_jobs%rowtype; status text;
begin
  select * into job from public.exhibition_test_reset_jobs where id=p_job_id for update;
  if job.id is null or job.executed_by<>actor then raise exception '対象Reset Jobを更新できません。';end if;
  if jsonb_typeof(coalesce(p_success_paths,'[]'))<>'array' or jsonb_typeof(coalesce(p_failed_paths,'[]'))<>'array' then raise exception 'Storage結果の形式が不正です。';end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_success_paths,'[]'))x where not job.storage_paths@>jsonb_build_array(x.value))
     or exists(select 1 from jsonb_array_elements(coalesce(p_failed_paths,'[]'))x where not job.storage_paths@>jsonb_build_array(x.value)) then raise exception 'Job対象外のStorage pathです。';end if;
  status:=case when jsonb_array_length(coalesce(p_failed_paths,'[]'))=0 then 'completed' when jsonb_array_length(coalesce(p_success_paths,'[]'))=0 then 'failed' else 'partial' end;
  update public.exhibition_test_reset_jobs set storage_success_paths=job.storage_success_paths||coalesce(p_success_paths,'[]'),storage_failed_paths=coalesce(p_failed_paths,'[]'),
    storage_cleanup_status=status,retry_count=retry_count+case when storage_cleanup_status in('failed','partial') then 1 else 0 end,
    completed_at=case when status='completed' then now() else null end,error_info=left(coalesce(p_error,''),5000) where id=job.id;
  return jsonb_build_object('jobId',job.id,'storageCleanupStatus',status);
end;$$;

-- Storage APIから削除できるのは、本人が実行した未完了Jobに列挙済みのobjectだけ。
create policy exhibition_test_reset_original_cleanup on storage.objects for delete to authenticated using(
  bucket_id='exhibition-originals' and private.is_maintenance_admin() and exists(
    select 1 from public.exhibition_test_reset_jobs j cross join lateral jsonb_array_elements(j.storage_paths) p
    where j.executed_by=private.current_email() and j.storage_cleanup_status in('pending','partial','failed')
      and p->>'bucket'=storage.objects.bucket_id and p->>'path'=storage.objects.name));
create policy exhibition_test_reset_preview_cleanup on storage.objects for delete to authenticated using(
  bucket_id='exhibition-previews' and private.is_maintenance_admin() and exists(
    select 1 from public.exhibition_test_reset_jobs j cross join lateral jsonb_array_elements(j.storage_paths) p
    where j.executed_by=private.current_email() and j.storage_cleanup_status in('pending','partial','failed')
      and p->>'bucket'=storage.objects.bucket_id and p->>'path'=storage.objects.name));
create policy exhibition_test_reset_public_cleanup on storage.objects for delete to authenticated using(
  bucket_id='exhibition-public' and private.is_maintenance_admin() and exists(
    select 1 from public.exhibition_test_reset_jobs j cross join lateral jsonb_array_elements(j.storage_paths) p
    where j.executed_by=private.current_email() and j.storage_cleanup_status in('pending','partial','failed')
      and p->>'bucket'=storage.objects.bucket_id and p->>'path'=storage.objects.name));

revoke all on function public.maintenance_list_exhibition_reset_targets_v1(),public.maintenance_preview_exhibition_test_reset_v1(uuid,uuid),public.maintenance_execute_exhibition_test_reset_v1(uuid,uuid,text,text),public.maintenance_update_exhibition_reset_storage_v1(uuid,jsonb,jsonb,text) from public,anon;
grant execute on function public.maintenance_list_exhibition_reset_targets_v1(),public.maintenance_preview_exhibition_test_reset_v1(uuid,uuid),public.maintenance_execute_exhibition_test_reset_v1(uuid,uuid,text,text),public.maintenance_update_exhibition_reset_storage_v1(uuid,jsonb,jsonb,text) to authenticated;
revoke execute on function private.exhibition_test_reset_preview_data_v1(uuid,uuid),private.exhibition_test_reset_delete_allowed_v1() from public,anon,authenticated;
