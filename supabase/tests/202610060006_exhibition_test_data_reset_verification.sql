-- Maintenance Admin専用写真展テストデータReset verification。全fixtureはrollbackする。
begin;

do $$
<<v>>
declare
  maintenance_email text:='__reset_maintenance__@example.invalid'; admin_email text:='__reset_admin__@example.invalid';
  member_email text:='__reset_member__@example.invalid'; other_email text:='__reset_other__@example.invalid';
  member_id uuid;other_id uuid;event_id uuid;entry_id uuid;agreement_id uuid;agreement_hash text;
  work_id uuid;batch_id uuid;work_snapshot uuid;work_review uuid;work_case uuid;
  caption_snapshot uuid;caption_review uuid;phone_id uuid;phone_snapshot uuid;phone_review uuid;phone_case uuid;
  venue_id uuid;wall_id uuid;layout_id uuid;placement_id uuid;finalization_id uuid;final_item_id uuid;
  export_id uuid;export_item_id uuid;publication_id uuid;actual_id uuid;actual_item_id uuid;archive_id uuid;
  preview jsonb;executed jsonb;old_token text;event_audit uuid;shift_id uuid;regular_action_count integer;
begin
  insert into public.admins(email,name,role_name,active) values(admin_email,'通常管理者','幹部',true);
  insert into public.maintenance_admins(email,name,role_name,active) values
    (maintenance_email,'保守管理者','メンテナンス管理者',true),('__reset_inactive__@example.invalid','無効保守','メンテナンス管理者',false);
  insert into public.members(member_no,email,name,grade,active) values
    ('member-999701',member_email,'Reset対象','B2',true),('member-999702',other_email,'保持対象','B3',true);
  select id into member_id from public.members where email=member_email;
  select id into other_id from public.members where email=other_email;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true),(other_id,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,
    max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__reset_verification__','Reset検証展',now()+interval '20 days',now()+interval '21 days','検証会場',admin_email,
    now()+interval '1 day',3,1,'[{"id":"slot-1","label":"検証枠"}]',admin_email) returning id into event_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '2 days',now()+interval '4 days',now()+interval '6 days',now()+interval '8 days','reset-v1','Reset検証規約','Reset検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  entry_id:=(public.submit_exhibition_application_v2(event_id,1,'real_name','','Reset検証',agreement_id,agreement_hash)->>'entryId')::uuid;
  insert into public.exhibition_shift_preferences(event_id,member_id,slot_id,slot_label,preference) values(event_id,member_id,'slot-1','検証枠','preferred') returning id into shift_id;
  work_id:=(public.save_exhibition_work_draft_v2(event_id,null,'Reset作品','portrait','A4','',210,297,true,null,null)->>'id')::uuid;
  insert into public.exhibition_work_submission_batches(event_id,entry_id,member_id,submitted_by_identifier) values(event_id,entry_id,member_id,member_email) returning id into batch_id;
  insert into public.exhibition_work_submission_snapshots(batch_id,work_id,entry_id,event_id,member_id,version_no,original_image_path,original_sha256,title,orientation,print_size,occupied_width_mm,occupied_height_mm,publication_consent,submitted_by_member_id,submitted_by_identifier)
  values(batch_id,work_id,entry_id,event_id,member_id,1,event_id||'/'||member_id||'/'||work_id||'/regular.jpg',repeat('a',64),'Reset作品','portrait','A4',210,297,true,member_id,member_email) returning id into work_snapshot;
  insert into public.exhibition_work_reviews(work_id,submission_snapshot_id,reviewer_identifier,result) values(work_id,work_snapshot,admin_email,'accepted') returning id into work_review;
  insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state)
    values(work_id,event_id,member_id,'reedit',work_snapshot,work_review,'cancelled') returning id into work_case;
  perform set_config('app.exhibition_work_rpc','on',true);update public.exhibition_works set current_submission_snapshot_id=work_snapshot,current_accepted_snapshot_id=work_snapshot,workflow_state='accepted',status='accepted' where id=work_id;perform set_config('app.exhibition_work_rpc','off',true);
  insert into public.exhibition_caption_working_data(work_id,event_id,entry_id,member_id,state,display_name,english_title_mode,medium,camera,description_choice)
    values(work_id,event_id,entry_id,member_id,'accepted','Reset対象','organizer','digital','Camera','unnecessary');
  insert into public.exhibition_caption_submission_snapshots(work_id,event_id,entry_id,member_id,version_no,display_name,english_title_mode,medium,camera,description_choice,instagram_qr_choice,submitted_by_member_id,submitted_by_identifier)
    values(work_id,event_id,entry_id,member_id,1,'Reset対象','organizer','digital','Camera','unnecessary','none',member_id,member_email) returning id into caption_snapshot;
  insert into public.exhibition_caption_reviews(work_id,caption_snapshot_id,reviewer_identifier,result) values(work_id,caption_snapshot,admin_email,'accepted') returning id into caption_review;
  update public.exhibition_caption_working_data caption set current_submission_snapshot_id=v.caption_snapshot,current_accepted_snapshot_id=v.caption_snapshot where caption.work_id=v.work_id;

  phone_id:=(public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null)->>'id')::uuid;
  insert into public.exhibition_smartphone_work_submission_snapshots(smartphone_work_id,event_id,entry_id,member_id,version_no,original_image_path,original_sha256,orientation,smartphone_confirmed,ai_processing_declaration,agreement_definition_id,agreement_version,agreement_reference,agreement_content_hash,agreed_at,submitted_by_identifier)
  select phone_id,event_id,entry_id,member_id,1,event_id||'/'||member_id||'/'||phone_id||'/phone.jpg',repeat('b',64),'portrait',true,'none',d.id,d.version_no,d.reference_key,d.content_hash,now(),member_email
  from public.exhibition_smartphone_agreement_definitions d where d.active returning id into phone_snapshot;
  insert into public.exhibition_smartphone_work_reviews(smartphone_work_id,submission_snapshot_id,reviewer_identifier,result) values(phone_id,phone_snapshot,admin_email,'accepted') returning id into phone_review;
  insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state)
    values(phone_id,event_id,member_id,'reedit',phone_snapshot,phone_review,'cancelled') returning id into phone_case;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);update public.exhibition_smartphone_works set current_submission_snapshot_id=phone_snapshot,current_accepted_snapshot_id=phone_snapshot,workflow_state='accepted' where id=phone_id;perform set_config('app.exhibition_smartphone_work_rpc','off',true);

  insert into storage.objects(bucket_id,name,owner_id,metadata) values
    ('exhibition-originals',event_id||'/'||member_id||'/'||work_id||'/regular.jpg',member_id,'{}'),
    ('exhibition-originals',event_id||'/'||member_id||'/'||phone_id||'/phone.jpg',member_id,'{}');
  perform private.write_exhibition_workflow_audit(event_id,'work',work_id,'reset_target','member',member_email);
  event_audit:=private.write_exhibition_workflow_audit(event_id,'agreement_definition',agreement_id,'must_remain','admin',admin_email);

  -- 通常のimmutable DELETEは引き続き拒否。
  begin delete from public.exhibition_work_submission_snapshots where id=work_snapshot;raise exception '通常DELETEでWork Snapshotを削除できました。';
  exception when others then if sqlerrm='通常DELETEでWork Snapshotを削除できました。' then raise;end if;end;

  -- anon / 一般部員 / 通常Admin / inactive Maintenance Adminは拒否。
  foreach regular_action_count in array array[1,2,3,4] loop
    perform set_config('request.jwt.claims',case regular_action_count when 1 then jsonb_build_object('role','anon') when 2 then jsonb_build_object('email',member_email,'role','authenticated') when 3 then jsonb_build_object('email',admin_email,'role','authenticated') else jsonb_build_object('email','__reset_inactive__@example.invalid','role','authenticated') end::text,true);
    begin perform public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);raise exception '非Maintenance AdminがPreviewできました。';
    exception when others then if sqlerrm='非Maintenance AdminがPreviewできました。' then raise;end if;end;
  end loop;

  perform set_config('request.jwt.claims',jsonb_build_object('email',maintenance_email,'role','authenticated')::text,true);
  preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
  if not (preview->>'canReset')::boolean or (preview#>>'{counts,regularWorks}')::integer<>1 or (preview#>>'{counts,smartphoneWorks}')::integer<>1
     or (preview#>>'{counts,applicationSnapshots}')::integer<>1 or not (preview->>'shiftPreserved')::boolean then raise exception 'Previewの件数または判定が不正です: %',preview;end if;
  if (preview->>'auditCount')::integer<2 or jsonb_array_length(preview->'storageObjects')<>2 then raise exception 'Audit/Storage Previewが不足しています: %',preview;end if;

  -- 全downstream禁止境界を同一subtransaction内に構築し、Preview/Execute双方の拒否を確認してrollbackする。
  begin
    insert into public.exhibition_venues(name) values('Reset禁止検証会場') returning id into venue_id;
    insert into public.exhibition_walls(venue_id,name,width_mm,height_mm) values(venue_id,'壁',5000,2500) returning id into wall_id;
    perform set_config('app.exhibition_workflow_rpc','on',true);update public.events set exhibition_venue_id=venue_id where id=event_id;perform set_config('app.exhibition_workflow_rpc','off',true);
    insert into public.exhibition_layouts(event_id,name,created_by) values(event_id,'Reset禁止Layout',admin_email) returning id into layout_id;
    insert into public.exhibition_placements(layout_id,work_id,wall_id,top_from_floor_mm,accepted_work_snapshot_id,viewing_order)
      values(layout_id,work_id,wall_id,1400,work_snapshot,1) returning id into placement_id;
    insert into public.exhibition_layout_finalizations(layout_id,event_id,finalization_version,finalized_by) values(layout_id,event_id,1,admin_email) returning id into finalization_id;
    insert into public.exhibition_work_display_numbers(event_id,work_id,display_no,first_finalization_id,assigned_by) values(event_id,work_id,1,finalization_id,admin_email);
    insert into public.exhibition_layout_finalization_items(finalization_id,event_id,work_id,work_submission_snapshot_id,wall_id,viewing_order,display_no,x_mm,top_from_floor_mm,z_order,occupied_width_mm,occupied_height_mm,orientation,print_size)
      values(finalization_id,event_id,work_id,work_snapshot,wall_id,1,1,0,1400,0,210,297,'portrait','A4') returning id into final_item_id;
    insert into public.exhibition_export_versions(event_id,version_no,layout_finalization_id,layout_finalization_version,created_by) values(event_id,1,finalization_id,1,admin_email) returning id into export_id;
    insert into public.exhibition_export_items(export_version_id,event_id,work_id,display_no,viewing_order,work_submission_snapshot_id,caption_submission_snapshot_id,title_ja,display_name,effective_english_title,english_title_mode,english_title_provenance,medium,camera,description_choice,instagram_qr_choice,publication_consent,orientation,print_size,wall_id)
      values(export_id,event_id,work_id,1,1,work_snapshot,caption_snapshot,'Reset作品','Reset対象','Reset Work','self','member_snapshot','digital','Camera','unnecessary','none',true,'portrait','A4',wall_id) returning id into export_item_id;
    insert into public.exhibition_publication_versions(event_id,version_no,source_export_version_id,source_layout_finalization_id,site_title,site_description,place,created_by,published_by)
      values(event_id,1,export_id,finalization_id,'Reset検証','説明','会場',admin_email,admin_email) returning id into publication_id;
    insert into public.exhibition_publication_items(publication_version_id,source_export_item_id,event_id,work_id,display_no,public_order,work_submission_snapshot_id,caption_submission_snapshot_id,title_ja,display_name,effective_english_title,english_title_provenance,medium,camera,description_choice,instagram_qr_choice,publication_consent,image_state,public_image_path)
      values(publication_id,export_item_id,event_id,work_id,1,1,work_snapshot,caption_snapshot,'Reset作品','Reset対象','Reset Work','member_snapshot','digital','Camera','unnecessary','none',false,'no_image',null);
    insert into public.exhibition_survey_responses(event_id,respondent_hash,publication_version_id,workflow_version) values(event_id,repeat('c',64),publication_id,2) returning id into placement_id;
    insert into public.exhibition_survey_selections(response_id,work_id,position) values(placement_id,work_id,1);
    insert into public.exhibition_actual_versions(event_id,version_no,state,source_layout_finalization_id,created_by) values(event_id,1,'draft',finalization_id,admin_email) returning id into actual_id;
    insert into public.exhibition_actual_items(actual_version_id,event_id,source_layout_item_id,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,actual_state,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,updated_by)
      values(actual_id,event_id,final_item_id,work_id,1,work_snapshot,caption_snapshot,'exhibited',wall_id,0,1400,0,wall_id,0,1400,0,admin_email) returning id into actual_item_id;
    update public.exhibition_actual_versions set state='finalized',finalized_by=admin_email,finalized_at=now() where id=actual_id;
    insert into public.exhibition_archive_versions(event_id,version_no,source_actual_version_id,created_by,finalized_by) values(event_id,1,actual_id,admin_email,admin_email) returning id into archive_id;
    insert into public.exhibition_archive_items(archive_version_id,event_id,source_actual_item_id,source_actual_version_id,source_layout_finalization_id,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,title_ja,publication_consent,image_state)
      values(archive_id,event_id,actual_item_id,actual_id,finalization_id,work_id,1,work_snapshot,caption_snapshot,wall_id,0,1400,0,wall_id,0,1400,0,'Reset作品',false,'no_image');
    insert into public.exhibition_work_comments(work_id,comment) values(work_id,'第三者コメント');
    preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
    if (preview->>'canReset')::boolean or jsonb_array_length(preview->'blockers')<9 then raise exception '禁止境界の検出が不足しています: %',preview->'blockers';end if;
    begin perform public.maintenance_execute_exhibition_test_reset_v1(event_id,member_id,preview->>'previewToken','禁止境界検証');raise exception '禁止境界があるのにExecuteできました。';
    exception when others then if sqlerrm='禁止境界があるのにExecuteできました。' then raise;end if;end;
    raise exception using errcode='ZX001',message='rollback blocker fixtures';
  exception when sqlstate 'ZX001' then null; end;
  preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
  old_token:=preview->>'previewToken';
  perform set_config('app.exhibition_work_rpc','on',true);update public.exhibition_works set note='stale preview' where id=work_id;perform set_config('app.exhibition_work_rpc','off',true);
  begin perform public.maintenance_execute_exhibition_test_reset_v1(event_id,member_id,old_token,'stale検証');raise exception '古いPreview tokenで実行できました。';
  exception when others then if sqlerrm='古いPreview tokenで実行できました。' then raise;end if;end;
  preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
  executed:=public.maintenance_execute_exhibition_test_reset_v1(event_id,member_id,preview->>'previewToken','Smoke Test fixtureを削除');

  if exists(select 1 from public.exhibition_entries x where x.id=v.entry_id) or exists(select 1 from public.exhibition_works x where x.id=v.work_id)
    or exists(select 1 from public.exhibition_smartphone_works x where x.id=v.phone_id) or exists(select 1 from public.exhibition_application_snapshots x where x.entry_id=v.entry_id)
    or exists(select 1 from public.exhibition_workflow_audit_logs x where x.entity_id in(v.entry_id,v.work_id,v.phone_id)) then raise exception 'Reset対象が残っています。';end if;
  if not exists(select 1 from public.events x where x.id=v.event_id) or not exists(select 1 from public.members x where x.id=v.member_id)
    or not exists(select 1 from public.membership_years x where x.member_id=v.member_id) or not exists(select 1 from public.exhibition_shift_preferences x where x.id=v.shift_id)
    or not exists(select 1 from public.exhibition_agreement_definitions x where x.id=v.agreement_id) or not exists(select 1 from public.exhibition_workflow_audit_logs x where x.id=v.event_audit) then raise exception '保持対象を削除しました。';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  if (select count(*) from public.get_my_exhibition_required_actions_v1())<>0 then raise exception 'Reset後もMember Required Actionが残っています。';end if;
  if not exists(select 1 from public.exhibition_test_reset_jobs where id=(executed->>'jobId')::uuid and storage_cleanup_status='pending') then raise exception 'Reset Jobがありません。';end if;

  -- Reset後は通常RPCで初回Applicationを作成し、Snapshot v1 / revival_count 0となる。
  entry_id:=(public.submit_exhibition_application_v2(event_id,0,'real_name','','再申込',agreement_id,agreement_hash)->>'entryId')::uuid;
  if (select x.revival_count from public.exhibition_entries x where x.id=v.entry_id)<>0
     or (select x.version_no from public.exhibition_application_snapshots x where x.entry_id=v.entry_id)<>1 then raise exception 'Reset後の初回Application状態が不正です。';end if;
end $$;

-- Schema/security smoke checks。
select
  to_regclass('public.exhibition_test_reset_jobs') is not null as reset_job_ready,
  to_regprocedure('public.maintenance_preview_exhibition_test_reset_v1(uuid,uuid)') is not null as preview_ready,
  to_regprocedure('public.maintenance_execute_exhibition_test_reset_v1(uuid,uuid,text,text)') is not null as execute_ready;

rollback;
