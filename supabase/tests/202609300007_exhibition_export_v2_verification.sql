-- Phase 7 immutable Master Export verification。全変更はROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text; member_id uuid; event_id uuid; entry_id uuid; venue_id uuid; wall_id uuid; layout1 uuid; layout2 uuid;
  work_id uuid; w1 uuid; w2 uuid; c1 uuid; c2 uuid; derivation1 uuid; derivation2 uuid;
  final1 uuid; final2 uuid; export1 uuid; export2 uuid; result jsonb; csv text; before_item jsonb;
  agreement_id uuid; agreement_hash text; object_path text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values('member-997001','__phase7_member__@example.invalid','Phase 7検証','B4',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase7_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Wall',1,5000,3000) returning id into wall_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id)
  values('saved',true,'exhibition','__phase7_v2__','Phase 7',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase7','Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.event_id and agreement.active;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  entry_id:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'夏、"光"','portrait','A3','',297,420,false,null,null);
  work_id:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_id::text||'/'||work_id::text||'/w1.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,work_id,'夏、"光"','portrait','A3','',297,420,false,object_path,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_id]);
  select work.current_submission_snapshot_id into w1 from public.exhibition_works work where work.id=work_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(w1,'accepted','{}','',null);
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(event_id,'Main',1,'draft',true,admin_email) returning id into layout1;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order) values(layout1,work_id,wall_id,0,2000,1);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'No display number'=any(readiness.reasons)) then raise exception '未採番blockがありません。'; end if;
  result:=public.admin_finalize_exhibition_layout_v2(layout1,'初回'); final1:=(result->>'finalizationId')::uuid;

  -- Captionなし・pending・rejectedはいずれもFINALを拒否する。
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where not readiness.ready and 'Caption not submitted'=any(readiness.reasons)) then raise exception 'Caption未提出blockがありません。'; end if;
  begin perform public.admin_finalize_exhibition_export_v2(event_id,'invalid'); raise exception 'CaptionなしでExportできました。'; exception when others then if sqlerrm='CaptionなしでExportできました。' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(work_id,'作者、A','organizer','','digital','','Camera','Lens','Film','provided',E'一行目\n二行目 "引用"','English, description','none','',null);
  result:=public.submit_exhibition_caption_v2(work_id); c1:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'Caption awaiting review'=any(readiness.reasons)) then raise exception 'Caption pending blockがありません。'; end if;
  perform public.admin_review_exhibition_caption_v2(c1,'rejected',array['description'],'検証Reject',null);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'Caption rejected'=any(readiness.reasons)) then raise exception 'Caption rejected blockがありません。'; end if;

  -- C1はW1基準。organizer derivation必須。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(work_id,'作者、A','organizer','','digital','','Camera','Lens','Film','provided',E'一行目\n二行目 "引用"','English, description','none','',null);
  result:=public.submit_exhibition_caption_v2(work_id); c1:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(c1,'accepted','{}','',null);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'Organizer English title missing'=any(readiness.reasons)) then raise exception '主催者英題blockがありません。'; end if;
  result:=public.admin_set_exhibition_caption_organizer_title_v2(c1,'Light, "Summer"','検証'); derivation1:=(result->>'derivationId')::uuid;
  if exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where not readiness.ready) then raise exception '有効なW1/C1/Layout L1がreadyになりません。'; end if;
  result:=public.admin_finalize_exhibition_export_v2(event_id,'V1'); export1:=(result->>'exportVersionId')::uuid;
  if (select export_version.layout_finalization_id from public.exhibition_export_versions export_version where export_version.id=export1)<>final1 then raise exception 'V1がL1を参照していません。'; end if;
  if not exists(select 1 from public.exhibition_export_items item where item.export_version_id=export1 and item.work_id=v.work_id and item.display_no=1 and item.work_submission_snapshot_id=w1 and item.caption_submission_snapshot_id=c1 and item.english_title_derivation_id=derivation1 and item.english_title_provenance='organizer_derivation' and item.publication_consent=false) then raise exception 'V1 item provenanceが不正です。'; end if;
  select to_jsonb(item) into before_item from public.exhibition_export_items item where item.export_version_id=export1;
  csv:=public.admin_get_exhibition_export_csv_v2(export1);
  if position('work_uuid,display_no' in csv)=0 or position('"作者、A"' in csv)=0 or position('"Light, ""Summer"""' in csv)=0 or position(E'"一行目\n二行目 ""引用"""' in csv)=0 then raise exception 'CSV列またはescapingが不正です。'; end if;
  begin update public.exhibition_export_items item set display_no=9 where item.export_version_id=export1; raise exception 'Export Itemを変更できました。'; exception when others then if sqlerrm='Export Itemを変更できました。' then raise; end if; end;

  -- W2へ更新するとC1とL1は古くなり、C2/L2が揃うまでblock。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_work_reedit_v2(work_id,'W2へ変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2((result->>'caseId')::uuid,true,'検証',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(event_id,work_id,'新しい作品','landscape','A3','',420,297,false,object_path,repeat('b',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_id]);
  select work.current_submission_snapshot_id into w2 from public.exhibition_works work where work.id=work_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(w2,'accepted','{}','',null);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'Layout requires reconfirmation'=any(readiness.reasons) and 'Caption belongs to older Work Snapshot'=any(readiness.reasons)) then raise exception 'W2へのstale blockがありません。'; end if;
  result:=public.admin_clone_exhibition_layout(layout1); layout2:=(result->>'layoutId')::uuid;
  perform public.admin_refresh_exhibition_placement_snapshot_v2((select placement.id from public.exhibition_placements placement where placement.layout_id=layout2 and placement.work_id=v.work_id));
  result:=public.admin_finalize_exhibition_layout_v2(layout2,'W2'); final2:=(result->>'finalizationId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
  perform public.start_stale_exhibition_caption_resubmission_v2(work_id);
  perform public.save_exhibition_caption_draft_v2(work_id,'作者B','organizer','','digital','','Camera2','','','unnecessary','','','none','',null);
  result:=public.submit_exhibition_caption_v2(work_id); c2:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(c2,'accepted','{}','',null);
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_id) readiness where 'Organizer English title missing'=any(readiness.reasons)) then raise exception '旧C1 derivationがC2を誤って満たしました。'; end if;
  result:=public.admin_set_exhibition_caption_organizer_title_v2(c2,'New Work','検証'); derivation2:=(result->>'derivationId')::uuid;
  result:=public.admin_finalize_exhibition_export_v2(event_id,'V2'); export2:=(result->>'exportVersionId')::uuid;
  if (select export_version.version_no from public.exhibition_export_versions export_version where export_version.id=export2)<>2 then raise exception 'V2採番が不正です。'; end if;
  begin
    insert into public.exhibition_export_versions(event_id,version_no,export_type,layout_finalization_id,layout_finalization_version,created_by)
      select export_version.event_id,2,export_version.export_type,export_version.layout_finalization_id,export_version.layout_finalization_version,admin_email
      from public.exhibition_export_versions export_version where export_version.id=export2;
    raise exception 'Export version番号を重複登録できました。';
  exception when unique_violation then null; end;
  if not exists(select 1 from public.exhibition_export_items item where item.export_version_id=export2 and item.work_id=v.work_id and item.display_no=1 and item.work_submission_snapshot_id=w2 and item.caption_submission_snapshot_id=c2 and item.english_title_derivation_id=derivation2) then raise exception 'V2 itemがW2/C2ではありません。'; end if;
  if (select to_jsonb(item) from public.exhibition_export_items item where item.export_version_id=export1) is distinct from before_item then raise exception 'V2作成でV1が変化しました。'; end if;
  if (select count(*) from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='master_export_finalized')<>2 then raise exception 'Export Auditが不足しています。'; end if;
end $$;

-- 一般部員はPreview、FINAL作成、履歴列挙、CSV取得ができない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase7_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_get_exhibition_export_readiness_v2((select event.id from public.events event where event.title='__phase7_v2__')); raise exception 'Memberがreadinessを取得できました。'; exception when others then if sqlerrm='Memberがreadinessを取得できました。' then raise; end if; end;
  begin perform public.admin_finalize_exhibition_export_v2((select event.id from public.events event where event.title='__phase7_v2__'),'forged'); raise exception 'MemberがExportを作成できました。'; exception when others then if sqlerrm='MemberがExportを作成できました。' then raise; end if; end;
  begin perform public.admin_get_exhibition_export_csv_v2(gen_random_uuid()); raise exception 'MemberがCSVを取得できました。'; exception when others then if sqlerrm='MemberがCSVを取得できました。' then raise; end if; end;
  if exists(select 1 from public.exhibition_export_versions) then raise exception 'MemberがExport履歴を列挙できました。'; end if;
end $$;
reset role;

-- v1既存CSV/Export用データにはPhase 7の必須値を課さない。
select set_config('request.jwt.claims',jsonb_build_object('email',(select admin.email from public.admins admin where admin.active order by admin.created_at limit 1),'role','authenticated')::text,true);
do $$ declare eid uuid; begin
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__phase7_v1__','Phase 7 Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場','test',now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,'test')
  returning id into eid;
  if (select event.exhibition_workflow_version from public.events event where event.id=eid)<>1 then raise exception 'v1 Eventが維持されません。'; end if;
end $$;

rollback;
