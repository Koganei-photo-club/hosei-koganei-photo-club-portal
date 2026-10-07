-- Move the canonical Japanese title for new Workflow v2 submissions from the
-- Work phase to the Caption phase without rewriting immutable history.

alter table public.exhibition_caption_working_data
  add column title text not null default '';
alter table public.exhibition_caption_submission_snapshots
  add column title text not null default '';

-- Mutable Working Data may safely inherit an already-entered Production Work
-- title. Caption/Work snapshots are deliberately not backfilled.
update public.exhibition_caption_working_data caption_data
set title=work_row.title,updated_at=now()
from public.exhibition_works work_row
where work_row.id=caption_data.work_id
  and trim(caption_data.title)=''
  and trim(coalesce(work_row.title,''))<>'';

-- New Work snapshots may have an empty historical title. Existing rows remain
-- unchanged; only the old non-empty CHECK is removed.
do $$
declare constraint_row record;
begin
  for constraint_row in
    select constraint_item.conname
    from pg_constraint constraint_item
    where constraint_item.conrelid='public.exhibition_work_submission_snapshots'::regclass
      and constraint_item.contype='c'
      and constraint_item.conname='exhibition_work_submission_snapshots_title_check'
  loop
    execute format(
      'alter table public.exhibition_work_submission_snapshots drop constraint %I',
      constraint_row.conname
    );
  end loop;
end $$;

-- Work Review no longer accepts title as a new problem field. NOT VALID keeps
-- historical reviews that legitimately recorded the former field immutable.
do $$
declare constraint_row record;
begin
  for constraint_row in
    select constraint_item.conname
    from pg_constraint constraint_item
    where constraint_item.conrelid='public.exhibition_work_reviews'::regclass
      and constraint_item.contype='c'
      and pg_get_constraintdef(constraint_item.oid) ilike '%problem_fields%<@%'
  loop
    execute format('alter table public.exhibition_work_reviews drop constraint %I',constraint_row.conname);
  end loop;
end $$;
alter table public.exhibition_work_reviews
  add constraint exhibition_work_reviews_problem_fields_without_title_check
  check(problem_fields <@ array['original','orientation','print_size','physical_dimensions','publication_consent','other']::text[])
  not valid;

do $$
declare constraint_row record;
begin
  for constraint_row in
    select constraint_item.conname
    from pg_constraint constraint_item
    where constraint_item.conrelid='public.exhibition_caption_reviews'::regclass
      and constraint_item.contype='c'
      and pg_get_constraintdef(constraint_item.oid) ilike '%problem_fields%<@%'
  loop
    execute format('alter table public.exhibition_caption_reviews drop constraint %I',constraint_row.conname);
  end loop;
end $$;
alter table public.exhibition_caption_reviews
  add constraint exhibition_caption_reviews_problem_fields_with_title_check
  check(problem_fields <@ array['title','display_name','english_title','medium','camera','lens','film','description','instagram_qr','other']::text[]);

create or replace function private.validate_v2_work_values(p_work public.exhibition_works)
returns void language plpgsql stable security definer set search_path='' as $$
begin
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
  if not exists(select 1 from storage.objects object_row where object_row.bucket_id='exhibition-originals' and object_row.name=p_work.original_image_path) then
    raise exception '原画像がStorageに見つかりません。';
  end if;
end;
$$;

create or replace function public.save_exhibition_work_draft_v2(
 p_event_id uuid,p_work_id uuid,p_title text,p_orientation text,p_print_size text,p_print_size_detail text,
 p_occupied_width_mm numeric,p_occupied_height_mm numeric,p_publication_consent boolean,p_original_image_path text,p_original_sha256 text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;entry_row public.exhibition_entries%rowtype;work_row public.exhibition_works%rowtype;
 v_member_id uuid:=private.current_member_id();next_slot integer;logical_count integer;actor text:=private.current_email();
begin
 if v_member_id is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
 select * into event_row from public.events event_item where event_item.id=p_event_id for update;
 select * into entry_row from public.exhibition_entries entry_item where entry_item.event_id=p_event_id and entry_item.member_id=v_member_id for update;
 if event_row.exhibition_workflow_version<>2 or entry_row.application_state<>'active' then raise exception '有効なApplicationが必要です。';end if;
 if p_work_id is null then
  if not coalesce(private.exhibition_deadline_is_open(p_event_id,'work_submission'),false) and not(entry_row.revival_deadline is not null and now()<entry_row.revival_deadline) then raise exception '作品提出締切を過ぎています。';end if;
  select count(*) into logical_count from public.exhibition_works work_item where work_item.entry_id=entry_row.id and work_item.workflow_state<>'withdrawn'
   and not exists(select 1 from public.exhibition_works replacement where replacement.replacement_for_work_id=work_item.id and replacement.workflow_state<>'withdrawn');
  if logical_count>=event_row.max_works then raise exception '出展可能作品数を超えています。';end if;
  select coalesce(max(work_item.sort_order),0)+1 into next_slot from public.exhibition_works work_item where work_item.entry_id=entry_row.id;
  perform set_config('app.exhibition_work_rpc','on',true);
  insert into public.exhibition_works(id,entry_id,event_id,owner_member_id,sort_order,title,orientation,print_size,print_size_detail,occupied_width_mm,occupied_height_mm,publication_consent,original_image_path,original_sha256,status,workflow_state,lineage_id)
  values(gen_random_uuid(),entry_row.id,p_event_id,v_member_id,next_slot,trim(coalesce(p_title,'')),coalesce(p_orientation,''),coalesce(p_print_size,''),coalesce(p_print_size_detail,''),p_occupied_width_mm,p_occupied_height_mm,p_publication_consent,p_original_image_path,lower(p_original_sha256),'draft','draft',gen_random_uuid()) returning * into work_row;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'work_draft_created','member',actor,'','{}',jsonb_build_object('workId',work_row.id));
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

-- Re-submit keeps the Work title only as historical compatibility data; it is
-- no longer a completeness condition or a re-edit change condition.
create or replace function public.submit_exhibition_work_batch_v2(p_event_id uuid,p_work_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;entry_row public.exhibition_entries%rowtype;work_row public.exhibition_works%rowtype;
 snapshot_row public.exhibition_work_submission_snapshots%rowtype;batch_id uuid;next_version integer;
 submitted_ids uuid[]:='{}';incomplete_ids uuid[]:='{}';actor text:=private.current_email();v_member_id uuid:=private.current_member_id();case_row public.exhibition_workflow_cases%rowtype;
begin
 if v_member_id is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 if coalesce(cardinality(p_work_ids),0)=0 then raise exception '提出対象を選択してください。';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
 select * into event_row from public.events where id=p_event_id for update;
 select * into entry_row from public.exhibition_entries entry_item where entry_item.event_id=p_event_id and entry_item.member_id=v_member_id for update;
 if event_row.exhibition_workflow_version<>2 or entry_row.application_state<>'active' then raise exception '有効なApplicationが必要です。';end if;
 insert into public.exhibition_work_submission_batches(event_id,entry_id,member_id,submitted_by_identifier)
 values(p_event_id,entry_row.id,v_member_id,actor) returning id into batch_id;
 for work_row in select work_item.* from public.exhibition_works work_item where work_item.id=any(p_work_ids) and work_item.event_id=p_event_id and work_item.owner_member_id=v_member_id order by work_item.sort_order for update loop
  if work_row.workflow_state not in('draft','rejected','reedit_editing') or not private.exhibition_work_edit_deadline_open(work_row,event_row) then incomplete_ids:=array_append(incomplete_ids,work_row.id);continue;end if;
  begin perform private.validate_v2_work_values(work_row);exception when others then incomplete_ids:=array_append(incomplete_ids,work_row.id);continue;end;
  if work_row.workflow_state='reedit_editing' and not exists(
   select 1 from public.exhibition_workflow_cases workflow_case
   join public.exhibition_work_submission_snapshots old_snapshot on old_snapshot.id=workflow_case.source_submission_snapshot_id
   where workflow_case.work_id=work_row.id and workflow_case.case_type='reedit' and workflow_case.state='permitted' and(
    old_snapshot.original_sha256<>work_row.original_sha256 or old_snapshot.title<>trim(work_row.title) or old_snapshot.orientation<>work_row.orientation
    or old_snapshot.print_size<>work_row.print_size or old_snapshot.print_size_detail<>work_row.print_size_detail
    or old_snapshot.occupied_width_mm<>work_row.occupied_width_mm or old_snapshot.occupied_height_mm<>work_row.occupied_height_mm
    or old_snapshot.publication_consent<>work_row.publication_consent)) then incomplete_ids:=array_append(incomplete_ids,work_row.id);continue;end if;
  select coalesce(max(snapshot.version_no),0)+1 into next_version from public.exhibition_work_submission_snapshots snapshot where snapshot.work_id=work_row.id;
  insert into public.exhibition_work_submission_snapshots(batch_id,work_id,entry_id,event_id,member_id,version_no,
   original_image_path,original_sha256,title,orientation,print_size,print_size_detail,occupied_width_mm,occupied_height_mm,
   publication_consent,submitted_by_member_id,submitted_by_identifier)
  values(batch_id,work_row.id,work_row.entry_id,work_row.event_id,work_row.owner_member_id,next_version,
   work_row.original_image_path,work_row.original_sha256,trim(coalesce(work_row.title,'')),work_row.orientation,work_row.print_size,
   work_row.print_size_detail,work_row.occupied_width_mm,work_row.occupied_height_mm,work_row.publication_consent,v_member_id,actor)
  returning * into snapshot_row;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='submitted',status='submitted',current_submission_snapshot_id=snapshot_row.id,submitted_at=now(),updated_at=now() where id=work_row.id;
  if work_row.replacement_for_work_id is not null then
   update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=work_row.replacement_for_work_id;
   perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'replacement_submitted','member',actor,'','{}',jsonb_build_object('replacedWorkId',work_row.replacement_for_work_id));
  end if;
  perform set_config('app.exhibition_work_rpc','off',true);
  select * into case_row from public.exhibition_workflow_cases workflow_case where workflow_case.work_id=work_row.id and workflow_case.state in('open','permitted') for update;
  if case_row.id is not null then
   update public.exhibition_workflow_cases set state='resubmitted',closed_at=now() where id=case_row.id;
   perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,case when case_row.case_type='correction' then 'correction_resubmitted' else 'reedit_resubmitted' end,'member',actor,'','{}',jsonb_build_object('snapshotId',snapshot_row.id));
  end if;
  submitted_ids:=array_append(submitted_ids,work_row.id);
  perform private.write_exhibition_workflow_audit(p_event_id,'work_submission_snapshot',snapshot_row.id,'work_submitted','member',actor,'','{}',jsonb_build_object('workId',work_row.id,'batchId',batch_id,'versionNo',next_version));
 end loop;
 if cardinality(submitted_ids)=0 then raise exception '提出可能な作品がありません。';end if;
 perform private.write_exhibition_workflow_audit(p_event_id,'submission_batch',batch_id,'submission_batch_created','member',actor,'','{}',jsonb_build_object('submittedWorkIds',submitted_ids,'incompleteWorkIds',incomplete_ids));
 return jsonb_build_object('batchId',batch_id,'submittedWorkIds',submitted_ids,'incompleteWorkIds',incomplete_ids);
end;$$;

create or replace function private.validate_caption_v2_values(p_caption public.exhibition_caption_working_data)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if trim(p_caption.title)='' then raise exception '作品タイトルを入力してください。'; end if;
  if trim(p_caption.display_name)='' then raise exception '表示名を入力してください。'; end if;
  if p_caption.english_title_mode='self' and trim(p_caption.member_english_title)='' then raise exception '英語作品名を入力してください。'; end if;
  if p_caption.medium='' then raise exception '媒体を選択してください。'; end if;
  if p_caption.medium='other' and trim(p_caption.medium_details)='' then raise exception '媒体の詳細を入力してください。'; end if;
  if p_caption.medium in ('digital','film','instant') and trim(p_caption.camera)='' then raise exception 'Cameraを入力してください。'; end if;
  if p_caption.medium='film' and trim(p_caption.film)='' then raise exception 'Filmを入力してください。'; end if;
  if p_caption.description_choice='undecided' then raise exception 'Descriptionの要否を確定してください。'; end if;
  if p_caption.description_choice='provided' and trim(p_caption.description_ja)='' then raise exception '日本語Descriptionを入力してください。'; end if;
  if p_caption.instagram_qr_choice='provided' and p_caption.instagram_qr_path is null and trim(p_caption.instagram_qr_info)='' then raise exception 'Instagram QRの画像または情報を入力してください。'; end if;
  if p_caption.ai_processing_declaration is null then raise exception 'AI生成・大幅加工等の有無を選択してください。'; end if;
  if p_caption.ai_processing_declaration='declared' and trim(p_caption.ai_processing_details)='' then raise exception 'AI生成・大幅加工等の内容を入力してください。'; end if;
end;$$;

-- New signature used by the updated Portal. The previous signature remains as
-- a compatibility path during deployment and continues to preserve Work.title.
create function public.save_exhibition_caption_draft_v2(
 p_work_id uuid,p_display_name text,p_english_title_mode text,p_member_english_title text,
 p_medium text,p_medium_details text,p_camera text,p_lens text,p_film text,
 p_description_choice text,p_description_ja text,p_description_en text,
 p_instagram_qr_choice text,p_instagram_qr_info text,p_instagram_qr_path text,
 p_ai_processing_declaration text,p_ai_processing_details text,p_title text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare work_row public.exhibition_works%rowtype;event_row public.events%rowtype;entry_row public.exhibition_entries%rowtype;
 caption_row public.exhibition_caption_working_data%rowtype;v_member_id uuid:=private.current_member_id();actor text:=private.current_email();
begin
 if v_member_id is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 select * into work_row from public.exhibition_works work_item where work_item.id=p_work_id and work_item.owner_member_id=v_member_id for update;
 select * into event_row from public.events where id=work_row.event_id;select * into entry_row from public.exhibition_entries where id=work_row.entry_id;
 if work_row.id is null or event_row.exhibition_workflow_version<>2 or entry_row.application_state<>'active' or work_row.workflow_state='withdrawn' then raise exception '対象のWorkflow v2 Workが見つかりません。';end if;
 if p_ai_processing_declaration is not null and p_ai_processing_declaration not in('none','declared') then raise exception 'AI生成・大幅加工等の選択が不正です。';end if;
 select * into caption_row from public.exhibition_caption_working_data where work_id=work_row.id for update;
 if caption_row.work_id is not null and caption_row.state not in('draft','rejected','reedit_editing') then raise exception '現在Captionを編集できません。';end if;
 if caption_row.work_id is not null and not private.caption_edit_is_open(caption_row,event_row) then raise exception 'Caption編集期限を過ぎています。';end if;
 if caption_row.work_id is null and not coalesce(private.exhibition_deadline_is_open(work_row.event_id,'caption'),false) then raise exception 'Caption締切を過ぎています。';end if;
 insert into public.exhibition_caption_working_data(work_id,event_id,entry_id,member_id,state,title,display_name,english_title_mode,member_english_title,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,
  ai_processing_declaration,ai_processing_details)
 values(work_row.id,work_row.event_id,work_row.entry_id,work_row.owner_member_id,'draft',trim(coalesce(p_title,work_row.title,'')),trim(coalesce(p_display_name,'')),p_english_title_mode,trim(coalesce(p_member_english_title,'')),
  p_medium,trim(coalesce(p_medium_details,'')),trim(coalesce(p_camera,'')),trim(coalesce(p_lens,'')),trim(coalesce(p_film,'')),p_description_choice,
  trim(coalesce(p_description_ja,'')),trim(coalesce(p_description_en,'')),p_instagram_qr_choice,trim(coalesce(p_instagram_qr_info,'')),p_instagram_qr_path,
  p_ai_processing_declaration,trim(coalesce(p_ai_processing_details,'')))
 on conflict(work_id) do update set title=excluded.title,display_name=excluded.display_name,english_title_mode=excluded.english_title_mode,
  member_english_title=excluded.member_english_title,medium=excluded.medium,medium_details=excluded.medium_details,camera=excluded.camera,lens=excluded.lens,
  film=excluded.film,description_choice=excluded.description_choice,description_ja=excluded.description_ja,description_en=excluded.description_en,
  instagram_qr_choice=excluded.instagram_qr_choice,instagram_qr_info=excluded.instagram_qr_info,instagram_qr_path=excluded.instagram_qr_path,
  ai_processing_declaration=excluded.ai_processing_declaration,ai_processing_details=excluded.ai_processing_details,updated_at=now()
 returning * into caption_row;
 perform private.write_exhibition_workflow_audit(work_row.event_id,'caption_working_data',work_row.id,'caption_draft_saved','member',actor);
 return to_jsonb(caption_row);
end;$$;

-- Keep the deployed signature usable while Portal assets roll over. Legacy
-- callers inherit the immutable Work title (when present) into Caption data.
create or replace function public.save_exhibition_caption_draft_v2(
 p_work_id uuid,p_display_name text,p_english_title_mode text,p_member_english_title text,
 p_medium text,p_medium_details text,p_camera text,p_lens text,p_film text,
 p_description_choice text,p_description_ja text,p_description_en text,
 p_instagram_qr_choice text,p_instagram_qr_info text,p_instagram_qr_path text,
 p_ai_processing_declaration text,p_ai_processing_details text
)
returns jsonb language sql security definer set search_path='' as $$
 select public.save_exhibition_caption_draft_v2(
  p_work_id,p_display_name,p_english_title_mode,p_member_english_title,
  p_medium,p_medium_details,p_camera,p_lens,p_film,p_description_choice,
  p_description_ja,p_description_en,p_instagram_qr_choice,p_instagram_qr_info,
  p_instagram_qr_path,p_ai_processing_declaration,p_ai_processing_details,null
 );
$$;

create or replace function public.submit_exhibition_caption_v2(p_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare work_row public.exhibition_works%rowtype;event_row public.events%rowtype;caption_row public.exhibition_caption_working_data%rowtype;
 snapshot_row public.exhibition_caption_submission_snapshots%rowtype;open_case public.exhibition_caption_workflow_cases%rowtype;
 v_member_id uuid:=private.current_member_id();actor text:=private.current_email();next_version integer;
begin
 select * into work_row from public.exhibition_works work_item where work_item.id=p_work_id and work_item.owner_member_id=v_member_id for update;
 select * into event_row from public.events where id=work_row.event_id;
 select * into caption_row from public.exhibition_caption_working_data where work_id=work_row.id for update;
 if work_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Workが見つかりません。';end if;
 if work_row.workflow_state<>'accepted' then raise exception 'Work確認済み後にCaptionを提出できます。';end if;
 if caption_row.work_id is null or caption_row.state not in('draft','rejected','reedit_editing') or not private.caption_edit_is_open(caption_row,event_row) then raise exception '現在Captionを正式提出できません。';end if;
 perform private.validate_caption_v2_values(caption_row);
 if caption_row.state='reedit_editing' and caption_row.current_accepted_snapshot_id is not null and not exists(
  select 1 from public.exhibition_caption_submission_snapshots old_snapshot where old_snapshot.id=caption_row.current_accepted_snapshot_id and(
   old_snapshot.title<>caption_row.title or old_snapshot.display_name<>caption_row.display_name or old_snapshot.english_title_mode<>caption_row.english_title_mode
   or old_snapshot.member_english_title<>caption_row.member_english_title or old_snapshot.medium<>caption_row.medium
   or old_snapshot.medium_details<>caption_row.medium_details or old_snapshot.camera<>caption_row.camera or old_snapshot.lens<>caption_row.lens
   or old_snapshot.film<>caption_row.film or old_snapshot.description_choice<>caption_row.description_choice
   or old_snapshot.description_ja<>caption_row.description_ja or old_snapshot.description_en<>caption_row.description_en
   or old_snapshot.instagram_qr_choice<>caption_row.instagram_qr_choice or old_snapshot.instagram_qr_info<>caption_row.instagram_qr_info
   or old_snapshot.instagram_qr_path is distinct from caption_row.instagram_qr_path
   or old_snapshot.ai_processing_declaration is distinct from caption_row.ai_processing_declaration
   or old_snapshot.ai_processing_details<>caption_row.ai_processing_details)) then raise exception '変更内容がありません。';end if;
 select coalesce(max(snapshot.version_no),0)+1 into next_version from public.exhibition_caption_submission_snapshots snapshot where snapshot.work_id=work_row.id;
 insert into public.exhibition_caption_submission_snapshots(work_id,event_id,entry_id,member_id,version_no,title,display_name,english_title_mode,member_english_title,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,
  ai_processing_declaration,ai_processing_details,submitted_by_member_id,submitted_by_identifier)
 values(work_row.id,work_row.event_id,work_row.entry_id,work_row.owner_member_id,next_version,caption_row.title,caption_row.display_name,
  caption_row.english_title_mode,caption_row.member_english_title,caption_row.medium,caption_row.medium_details,caption_row.camera,caption_row.lens,
  caption_row.film,caption_row.description_choice,caption_row.description_ja,caption_row.description_en,caption_row.instagram_qr_choice,
  caption_row.instagram_qr_info,caption_row.instagram_qr_path,caption_row.ai_processing_declaration,caption_row.ai_processing_details,v_member_id,actor)
 returning * into snapshot_row;
 update public.exhibition_caption_working_data set state='submitted',current_submission_snapshot_id=snapshot_row.id,updated_at=now() where work_id=work_row.id;
 select * into open_case from public.exhibition_caption_workflow_cases workflow_case where workflow_case.work_id=work_row.id and workflow_case.state in('open','permitted') for update;
 if open_case.id is not null then update public.exhibition_caption_workflow_cases set state='resubmitted',closed_at=now() where id=open_case.id;end if;
 perform private.write_exhibition_workflow_audit(work_row.event_id,'caption_submission_snapshot',snapshot_row.id,
  case when next_version=1 then 'caption_submitted' when open_case.case_type='correction' then 'caption_correction_resubmitted' else 'caption_reedit_resubmitted' end,
  'member',actor,'','{}',jsonb_build_object('workId',work_row.id,'versionNo',next_version));
 return jsonb_build_object('snapshotId',snapshot_row.id,'versionNo',next_version,'state','submitted');
end;$$;

create or replace function public.cancel_exhibition_caption_reedit_v2(p_case_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare workflow_case public.exhibition_caption_workflow_cases%rowtype;snapshot_row public.exhibition_caption_submission_snapshots%rowtype;
 work_row public.exhibition_works%rowtype;actor text:=private.current_email();
begin
 select * into workflow_case from public.exhibition_caption_workflow_cases where id=p_case_id and member_id=private.current_member_id() for update;
 if workflow_case.id is null or workflow_case.case_type<>'reedit' or workflow_case.state not in('pending','permitted') then raise exception '取消可能なCaption再編集申請がありません。';end if;
 select * into snapshot_row from public.exhibition_caption_submission_snapshots where id=workflow_case.source_caption_snapshot_id;
 select * into work_row from public.exhibition_works where id=workflow_case.work_id;
 update public.exhibition_caption_workflow_cases set state=case when workflow_case.state='pending' then 'cancelled' else 'restored' end,closed_at=now() where id=workflow_case.id;
 update public.exhibition_caption_working_data set state='accepted',title=coalesce(nullif(snapshot_row.title,''),work_row.title,''),
  display_name=snapshot_row.display_name,english_title_mode=snapshot_row.english_title_mode,member_english_title=snapshot_row.member_english_title,
  medium=snapshot_row.medium,medium_details=snapshot_row.medium_details,camera=snapshot_row.camera,lens=snapshot_row.lens,film=snapshot_row.film,
  description_choice=snapshot_row.description_choice,description_ja=snapshot_row.description_ja,description_en=snapshot_row.description_en,
  instagram_qr_choice=snapshot_row.instagram_qr_choice,instagram_qr_info=snapshot_row.instagram_qr_info,instagram_qr_path=snapshot_row.instagram_qr_path,updated_at=now()
 where work_id=workflow_case.work_id;
 perform private.write_exhibition_workflow_audit(workflow_case.event_id,'caption_case',workflow_case.id,'caption_reedit_cancelled_or_restored','member',actor,p_reason);
 return jsonb_build_object('caseId',workflow_case.id,'state','accepted');
end;$$;

-- Canonicalize newly-created downstream immutable items without touching any
-- existing Export/Archive history. Older Caption snapshots fall back to their
-- immutable Work snapshot title.
create or replace function private.populate_exhibition_caption_title_v2()
returns trigger language plpgsql security definer set search_path='' as $$
declare caption_title text;
begin
  if new.display_item_type='regular_work' and new.caption_submission_snapshot_id is not null then
    select snapshot.title into caption_title
    from public.exhibition_caption_submission_snapshots snapshot
    where snapshot.id=new.caption_submission_snapshot_id;
    if trim(coalesce(caption_title,''))<>'' then new.title_ja:=caption_title;end if;
  end if;
  return new;
end;$$;
create trigger exhibition_export_items_caption_title_before_insert
before insert on public.exhibition_export_items
for each row execute function private.populate_exhibition_caption_title_v2();
create trigger exhibition_archive_items_caption_title_before_insert
before insert on public.exhibition_archive_items
for each row execute function private.populate_exhibition_caption_title_v2();

revoke all on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text)
  from public,anon;
grant execute on function public.save_exhibition_caption_draft_v2(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text)
  to authenticated;
revoke execute on function private.populate_exhibition_caption_title_v2() from public,anon,authenticated;
