-- Phase 11 integrated workflow-v2 verification。全変更はROLLBACKされる。
-- Application -> Work -> Caption -> Layout -> Export -> Publication/Survey -> Actual -> Archive
begin;

do $$
<<v>>
declare
  admin_email text; member_id uuid; event_id uuid; agreement_id uuid; agreement_hash text;
  venue_id uuid; wall_id uuid; entry_id uuid; w1 uuid; w2 uuid; ws1 uuid; ws2 uuid; ws1v2 uuid;
  c1 uuid; c2 uuid; c1v2 uuid; layout_id uuid; layout_final uuid; export1 uuid; export2 uuid;
  publication_id uuid; response_id uuid; actual_id uuid; archive_id uuid; reedit_case uuid;
  item1 uuid; item2 uuid; result jsonb; public_payload jsonb; export1_before jsonb;
  original1 text; original2 text; public1 text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'Phase 11にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active)
    values('member-999011','__phase11_member__@example.invalid','Phase 11検証','B4',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase11_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm)
    values(venue_id,'Main Wall',1,6000,3000) returning id into wall_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,
    max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,
    exhibition_key,site_title,site_title_en,site_description,site_description_en,place_en,dm_image_path,
    site_status,survey_enabled,survey_opens_at,survey_closes_at)
  values('saved',true,'exhibition','__phase11_integration__','Phase 11',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',2,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id,
    '2099-phase11','統合検証展','Integration Exhibition','統合検証','Integration verification','Test venue',
    '2099-phase11/dm.webp','draft',true,now()-interval '1 hour',now()+interval '1 hour')
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','phase11-agreement','Phase 11 Agreement','統合検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash from public.exhibition_agreement_definitions agreement
    where agreement.event_id=v.event_id and agreement.active;

  -- Application: zero-Work申込を正式に作り、以後のWorkを同じEntryへ追加する。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,2,'real_name','','',agreement_id,agreement_hash);
  entry_id:=(result->>'entryId')::uuid;
  if (select entry.planned_work_count from public.exhibition_entries entry where entry.id=v.entry_id)<>2
    or not exists(select 1 from public.exhibition_application_snapshots snapshot where snapshot.entry_id=v.entry_id) then
    raise exception 'ApplicationまたはApplication Snapshotが作成されません。';
  end if;

  -- Work: 片方は掲載同意、片方は不同意。正式提出はversioned originalを要求する。
  result:=public.save_exhibition_work_draft_v2(event_id,null,'公開作品','portrait','A3','',297,420,true,null,null);w1:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'NO IMAGE作品','landscape','A3','',420,297,false,null,null);w2:=(result->>'id')::uuid;
  original1:=event_id::text||'/'||member_id::text||'/'||w1::text||'/phase11-w1-v1.jpg';
  original2:=event_id::text||'/'||member_id::text||'/'||w2::text||'/phase11-w2-v1.jpg';
  insert into storage.objects(bucket_id,name,metadata) values
    ('exhibition-originals',original1,'{"mimetype":"image/jpeg"}'),('exhibition-originals',original2,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,w1,'公開作品','portrait','A3','',297,420,true,original1,repeat('1',64));
  perform public.save_exhibition_work_draft_v2(event_id,w2,'NO IMAGE作品','landscape','A3','',420,297,false,original2,repeat('2',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[w1,w2]);
  select work.current_submission_snapshot_id into ws1 from public.exhibition_works work where work.id=w1;
  select work.current_submission_snapshot_id into ws2 from public.exhibition_works work where work.id=w2;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(ws1,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(ws2,'accepted','{}','',null);

  -- Caption: exact accepted Work SnapshotへbindされたSelf英題を正式提出・確認する。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(w1,'作者1','self','Public Work','digital','','Camera 1','','','unnecessary','','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(w1);c1:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(w2,'作者2','self','No Image Work','digital','','Camera 2','','','unnecessary','','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(w2);c2:=(result->>'snapshotId')::uuid;
  if (select caption.work_submission_snapshot_id from public.exhibition_caption_submission_snapshots caption where caption.id=c1)<>ws1
    or (select caption.work_submission_snapshot_id from public.exhibition_caption_submission_snapshots caption where caption.id=c2)<>ws2 then
    raise exception 'Captionがexact Work Snapshotへbindされていません。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(c1,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(c2,'accepted','{}','',null);

  -- Layout / Export V1。
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by)
    values(event_id,'Main',1,'draft',true,admin_email) returning id into layout_id;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order,z_order) values
    (layout_id,w1,wall_id,0,2000,1,1),(layout_id,w2,wall_id,600,2000,2,2);
  result:=public.admin_finalize_exhibition_layout_v2(layout_id,'Phase 11');layout_final:=(result->>'finalizationId')::uuid;
  if (select number.display_no from public.exhibition_work_display_numbers number where number.work_id=w1)<>1
    or (select number.display_no from public.exhibition_work_display_numbers number where number.work_id=w2)<>2 then raise exception 'display_noが鑑賞順どおりではありません。'; end if;
  if exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where not readiness.ready) then raise exception '初回Export readinessがreadyではありません。'; end if;
  result:=public.admin_finalize_exhibition_export_v2(event_id,'E1');export1:=(result->>'exportVersionId')::uuid;
  select jsonb_build_object('version',(select to_jsonb(export_version) from public.exhibition_export_versions export_version where export_version.id=export1),
    'items',(select jsonb_agg(to_jsonb(item) order by item.display_no) from public.exhibition_export_items item where item.export_version_id=export1)) into export1_before;

  -- Cross-phase mutation: W1をtitle-onlyでW2へ更新。物理Layoutは有効だが旧Captionは無効。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_work_reedit_v2(w1,'作品名のみ訂正');reedit_case:=(result->>'caseId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2(reedit_case,true,'許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(event_id,w1,'公開作品 改','portrait','A3','',297,420,true,original1,repeat('1',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[w1]);
  select work.current_submission_snapshot_id into ws1v2 from public.exhibition_works work where work.id=w1;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(ws1v2,'accepted','{}','',null);
  if private.layout_requires_physical_reconfirmation_v2(event_id) then raise exception 'title-only変更で物理Layout再確認が要求されました。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where readiness.work_id=w1 and 'Caption belongs to older Work Snapshot'=any(readiness.reasons)) then
    raise exception '旧Captionによるstale Exportがblockされません。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
  perform public.start_stale_exhibition_caption_resubmission_v2(w1);
  perform public.save_exhibition_caption_draft_v2(w1,'作者1','self','Public Work Revised','digital','','Camera 1','','','unnecessary','','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(w1);c1v2:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(c1v2,'accepted','{}','',null);
  result:=public.admin_finalize_exhibition_export_v2(event_id,'E2');export2:=(result->>'exportVersionId')::uuid;
  if (select item.work_submission_snapshot_id from public.exhibition_export_items item where item.export_version_id=export2 and item.work_id=w1)<>ws1v2
    or (select item.caption_submission_snapshot_id from public.exhibition_export_items item where item.export_version_id=export2 and item.work_id=w1)<>c1v2
    or (select item.ai_processing_declaration from public.exhibition_export_items item where item.export_version_id=export2 and item.work_id=w1)<>'none'
    or jsonb_build_object('version',(select to_jsonb(export_version) from public.exhibition_export_versions export_version where export_version.id=export1),
      'items',(select jsonb_agg(to_jsonb(item) order by item.display_no) from public.exhibition_export_items item where item.export_version_id=export1)) is distinct from export1_before then
    raise exception 'Export V2 provenanceまたはExport V1 immutabilityが不正です。';
  end if;

  -- Publication / public NO IMAGE boundary / UUID Survey。
  public1:=event_id::text||'/'||member_id::text||'/'||w1::text||'/public-v1.webp';
  begin perform public.admin_set_exhibition_public_image_v2(w1,original1);raise exception 'Private/nonexistent pathを公開画像として登録できました。';exception when others then if sqlerrm='Private/nonexistent pathを公開画像として登録できました。' then raise;end if;end;
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-public',public1,'{"mimetype":"image/webp"}');
  perform public.admin_set_exhibition_public_image_v2(w1,public1);
  result:=public.admin_finalize_exhibition_publication_v2(export2,'P1');publication_id:=(result->>'publicationVersionId')::uuid;
  perform public.admin_set_current_exhibition_publication_v2(publication_id,'公開');
  public_payload:=public.get_public_exhibition('2099-phase11');
  if jsonb_array_length(public_payload->'works')<>2
    or not exists(select 1 from jsonb_array_elements(public_payload->'works') x where x->>'workUuid'=w1::text and x->>'publicImagePath'=public1)
    or not exists(select 1 from jsonb_array_elements(public_payload->'works') x where x->>'workUuid'=w2::text and x->>'imageState'='no_image' and x->'publicImagePath'='null'::jsonb)
    or public_payload::text like '%exhibition-originals%' or public_payload::text like '%phase11-w2-v1.jpg%' then raise exception 'Public Publicationの画像境界が不正です。'; end if;
  response_id:=public.submit_exhibition_survey('2099-phase11',repeat('phase11-token-',4),'ja','統合Survey',
    jsonb_build_array(jsonb_build_object('work_id',w2,'comment','NO IMAGEにもUUID投票')));
  if not exists(select 1 from public.exhibition_survey_responses response where response.id=v.response_id and response.respondent_hash=encode(extensions.digest(repeat('phase11-token-',4),'sha256'),'hex') and response.publication_version_id=publication_id)
    or not exists(select 1 from public.exhibition_survey_selections selection where selection.response_id=v.response_id and selection.work_id=w2) then raise exception 'UUID Survey/hash provenanceが不正です。'; end if;

  -- Actual / Archive: W1のみ展示。W2はLayout/Publication/Surveyに残るがArchiveから除外。
  result:=public.admin_initialize_exhibition_actual_v2(layout_final,null,'','A1');actual_id:=(result->>'actualVersionId')::uuid;
  select item.id into item1 from public.exhibition_actual_items item where item.actual_version_id=actual_id and item.work_id=w1;
  select item.id into item2 from public.exhibition_actual_items item where item.actual_version_id=actual_id and item.work_id=w2;
  perform public.admin_update_exhibition_actual_item_v2(item1,'exhibited',wall_id,10,1990,1,ws1v2,c1v2,false,'');
  perform public.admin_update_exhibition_actual_item_v2(item2,'not_exhibited',null,null,null,null,ws2,c2,false,'欠席');
  perform public.admin_finalize_exhibition_actual_v2(actual_id,'現場確認');
  result:=public.admin_finalize_exhibition_archive_v2(actual_id,'Archive A1');archive_id:=(result->>'archiveVersionId')::uuid;
  if (select count(*) from public.exhibition_archive_items item where item.archive_version_id=archive_id)<>1
    or not exists(select 1 from public.exhibition_archive_items item where item.archive_version_id=archive_id and item.work_id=w1 and item.display_no=1
      and item.work_submission_snapshot_id=ws1v2 and item.caption_submission_snapshot_id=c1v2
      and item.ai_processing_declaration='none' and item.actual_x_mm=10)
    or exists(select 1 from public.exhibition_archive_items item where item.archive_version_id=archive_id and item.work_id=w2) then
    raise exception 'Archive authoritative exhibited set/provenanceが不正です。';
  end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=layout_final and item.work_id=w2)
    or not exists(select 1 from public.exhibition_publication_items item where item.publication_version_id=publication_id and item.work_id=w2)
    or not exists(select 1 from public.exhibition_survey_selections selection where selection.response_id=v.response_id and selection.work_id=w2) then
    raise exception '非展示W2のLayout/Publication/Survey履歴が失われました。';
  end if;
  perform public.admin_set_current_exhibition_archive_v2(archive_id,'Current');

  if not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='application_submitted')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='work_accepted')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='caption_accepted')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='layout_finalized')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='master_export_finalized')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='public_publication_finalized')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='actual_finalized')
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='archive_finalized') then
    raise exception '統合Audit chainが不足しています。';
  end if;
end $$;

-- 一般部員/AnonymousはAdmin最終成果物を操作・列挙できない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase11_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_finalize_exhibition_export_v2(gen_random_uuid(),'forged');raise exception 'MemberがExportを作成できました。';exception when others then if sqlerrm='MemberがExportを作成できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_export_versions) or exists(select 1 from public.exhibition_actual_versions) or exists(select 1 from public.exhibition_archive_versions) then raise exception 'Memberが内部最終履歴を列挙できました。';end if;
end $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true);
set local role anon;
do $$ declare d jsonb;begin
  begin perform public.admin_get_exhibition_archive_actions_v2(null);raise exception 'AnonymousがAdmin RPCを実行できました。';exception when others then if sqlerrm='AnonymousがAdmin RPCを実行できました。' then raise;end if;end;
  d:=public.get_public_exhibition('2099-phase11');
  if d is null or d->>'publicationVersionNo'<>'1' or jsonb_array_length(d->'works')<>2 then
    raise exception 'AnonymousがCurrent Publicationを公開RPCから取得できません。';
  end if;
  if d::text like '%exhibition-originals%' or d::text like '%caption_submission_snapshot_id%'
    or not exists(select 1 from jsonb_array_elements(d->'works') work where work->>'imageState'='no_image' and work->'publicImagePath'='null'::jsonb) then
    raise exception 'Anonymous向け公開RPCの画像・provenance境界が不正です。';
  end if;
end $$;
reset role;

rollback;
