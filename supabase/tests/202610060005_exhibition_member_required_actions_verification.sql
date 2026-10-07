-- Member Required Actions verification. All fixtures are rolled back.
begin;

do $$
<<v>>
declare
  admin_email text; event_uuid uuid; member_uuid uuid; other_member_uuid uuid; entry_uuid uuid;
  agreement_uuid uuid; agreement_hash text; batch_uuid uuid; smartphone_agreement uuid;
  work_ids uuid[] := '{}'; snapshot_ids uuid[] := '{}'; smartphone_ids uuid[] := '{}'; smartphone_snapshots uuid[] := '{}';
  work_uuid uuid; snapshot_uuid uuid; smartphone_uuid uuid; review_uuid uuid; caption_snapshot uuid; second_snapshot uuid;
  action_types text[]; result jsonb; index_value integer;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'Member Required Actions検証にはactive Adminが必要です。'; end if;

  insert into public.members(member_no,email,name,grade,active) values
    ('member-999091','__member_actions__@example.invalid','Action対象部員','B2',true),
    ('member-999092','__member_actions_other__@example.invalid','別部員','B3',true);
  select id into member_uuid from public.members where email='__member_actions__@example.invalid';
  select id into other_member_uuid from public.members where email='__member_actions_other__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member_uuid,private.current_fiscal_year(),true),(other_member_uuid,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__member_required_actions__','Member Action検証展',now()+interval '20 days',now()+interval '21 days',
    '検証会場',admin_email,now()+interval '1 day',20,1,'[{"id":"slot-1","label":"検証枠"}]'::jsonb,admin_email)
  returning id into event_uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_activate_exhibition_workflow_v2(event_uuid,now()+interval '2 days',now()+interval '4 days',
    now()+interval '6 days',now()+interval '8 days','member-action-v1','検証規約','Member Required Actions検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=10 where id=event_uuid;
  select current_exhibition_agreement_id into agreement_uuid from public.events where id=event_uuid;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_uuid;
  select id into smartphone_agreement from public.exhibition_smartphone_agreement_definitions where active order by version_no desc limit 1;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__member_actions__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_uuid,20,'real_name','','',agreement_uuid,agreement_hash);
  entry_uuid:=(result->>'entryId')::uuid;
  insert into public.exhibition_work_submission_batches(event_id,entry_id,member_id,submitted_by_identifier)
    values(event_uuid,entry_uuid,member_uuid,'__member_actions__@example.invalid') returning id into batch_uuid;

  -- Eleven regular Works and their formal Work snapshots.
  for index_value in 1..11 loop
    work_uuid:=gen_random_uuid();
    perform set_config('app.exhibition_work_rpc','on',true);
    insert into public.exhibition_works(id,entry_id,event_id,owner_member_id,sort_order,title,orientation,print_size,
      occupied_width_mm,occupied_height_mm,publication_consent,original_image_path,original_sha256,workflow_state,lineage_id)
    values(work_uuid,entry_uuid,event_uuid,member_uuid,index_value,'検証作品'||index_value,'portrait','A4',210,297,true,
      event_uuid::text||'/'||member_uuid::text||'/'||work_uuid::text||'/work.jpg',repeat('a',64),'draft',gen_random_uuid());
    perform set_config('app.exhibition_work_rpc','off',true);
    insert into storage.objects(bucket_id,name,owner_id,metadata) values
      ('exhibition-originals',event_uuid::text||'/'||member_uuid::text||'/'||work_uuid::text||'/work.jpg',member_uuid,'{}');
    insert into public.exhibition_work_submission_snapshots(batch_id,work_id,entry_id,event_id,member_id,version_no,
      original_image_path,original_sha256,title,orientation,print_size,occupied_width_mm,occupied_height_mm,
      publication_consent,submitted_by_member_id,submitted_by_identifier)
    values(batch_uuid,work_uuid,entry_uuid,event_uuid,member_uuid,1,event_uuid::text||'/'||member_uuid::text||'/'||work_uuid::text||'/work.jpg',
      repeat('a',64),'検証作品'||index_value,'portrait','A4',210,297,true,member_uuid,'__member_actions__@example.invalid')
    returning id into snapshot_uuid;
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works set workflow_state='accepted',current_submission_snapshot_id=snapshot_uuid,
      current_accepted_snapshot_id=snapshot_uuid,submitted_at=now() where id=work_uuid;
    perform set_config('app.exhibition_work_rpc','off',true);
    work_ids:=array_append(work_ids,work_uuid); snapshot_ids:=array_append(snapshot_ids,snapshot_uuid);
  end loop;

  -- Regular correction / expired correction / submitted / accepted / permitted re-edit / pending re-edit.
  insert into public.exhibition_work_reviews(work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(work_ids[1],snapshot_ids[1],admin_email,'rejected',array['orientation'],'向きを確認してください') returning id into review_uuid;
  insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
    values(work_ids[1],event_uuid,member_uuid,'correction',snapshot_ids[1],review_uuid,'open','作品名を確認してください',now()+interval '1 hour',now());
  perform set_config('app.exhibition_work_rpc','on',true); update public.exhibition_works set workflow_state='rejected' where id=work_ids[1]; perform set_config('app.exhibition_work_rpc','off',true);

  insert into public.exhibition_work_reviews(work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(work_ids[2],snapshot_ids[2],admin_email,'rejected',array['other'],'期限切れ') returning id into review_uuid;
  insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
    values(work_ids[2],event_uuid,member_uuid,'correction',snapshot_ids[2],review_uuid,'open','期限切れ',now()-interval '1 minute',now());
  perform set_config('app.exhibition_work_rpc','on',true); update public.exhibition_works set workflow_state='rejected' where id=work_ids[2]; update public.exhibition_works set workflow_state='submitted',current_accepted_snapshot_id=null where id=work_ids[3]; perform set_config('app.exhibition_work_rpc','off',true);
  insert into public.exhibition_workflow_cases(work_id,event_id,member_id,case_type,source_submission_snapshot_id,state,request_reason,decision_reason,individual_deadline,requested_at,decided_at)
    values(work_ids[5],event_uuid,member_uuid,'reedit',snapshot_ids[5],'permitted','再編集希望','許可',now()+interval '2 hours',now(),now()),
      (work_ids[6],event_uuid,member_uuid,'reedit',snapshot_ids[6],'pending','判断待ち','',null,now(),null);
  perform set_config('app.exhibition_work_rpc','on',true); update public.exhibition_works set workflow_state='reedit_editing' where id=work_ids[5]; update public.exhibition_works set workflow_state='reedit_pending' where id=work_ids[6]; perform set_config('app.exhibition_work_rpc','off',true);

  -- Caption correction, permitted re-edit, stale, current accepted and expired correction.
  for index_value in 7..11 loop
    insert into public.exhibition_caption_working_data(work_id,event_id,entry_id,member_id,state,display_name,english_title_mode,
      medium,camera,description_choice,ai_processing_declaration)
    values(work_ids[index_value],event_uuid,entry_uuid,member_uuid,'submitted','Action対象部員','organizer','digital','Camera','unnecessary','none');
    insert into public.exhibition_caption_submission_snapshots(work_id,event_id,entry_id,member_id,version_no,display_name,
      english_title_mode,medium,camera,description_choice,instagram_qr_choice,ai_processing_declaration,
      submitted_by_member_id,submitted_by_identifier)
    values(work_ids[index_value],event_uuid,entry_uuid,member_uuid,1,'Action対象部員','organizer','digital','Camera','unnecessary','none','none',
      member_uuid,'__member_actions__@example.invalid') returning id into caption_snapshot;
    update public.exhibition_caption_working_data set current_submission_snapshot_id=caption_snapshot,
      current_accepted_snapshot_id=caption_snapshot,state='accepted' where work_id=work_ids[index_value];
    if index_value=7 then
      insert into public.exhibition_caption_reviews(work_id,caption_snapshot_id,reviewer_identifier,result,problem_fields,reason)
        values(work_ids[index_value],caption_snapshot,admin_email,'rejected',array['camera'],'Cameraを確認してください') returning id into review_uuid;
      insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
        values(work_ids[index_value],event_uuid,member_uuid,'correction',caption_snapshot,review_uuid,'open','Cameraを確認してください',now()+interval '90 minutes',now());
      update public.exhibition_caption_working_data set state='rejected' where work_id=work_ids[index_value];
    elsif index_value=8 then
      insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,state,request_reason,decision_reason,individual_deadline,requested_at,decided_at)
        values(work_ids[index_value],event_uuid,member_uuid,'reedit',caption_snapshot,'permitted','再編集希望','許可',now()+interval '3 hours',now(),now());
      update public.exhibition_caption_working_data set state='reedit_editing' where work_id=work_ids[index_value];
    elsif index_value=9 then
      insert into public.exhibition_work_submission_snapshots(batch_id,work_id,entry_id,event_id,member_id,version_no,
        original_image_path,original_sha256,title,orientation,print_size,occupied_width_mm,occupied_height_mm,
        publication_consent,submitted_by_member_id,submitted_by_identifier)
      values(batch_uuid,work_ids[index_value],entry_uuid,event_uuid,member_uuid,2,
        event_uuid::text||'/'||member_uuid::text||'/'||work_ids[index_value]::text||'/work.jpg',repeat('b',64),
        '更新後の作品','portrait','A4',210,297,true,member_uuid,'__member_actions__@example.invalid') returning id into second_snapshot;
      perform set_config('app.exhibition_work_rpc','on',true); update public.exhibition_works set current_submission_snapshot_id=second_snapshot,current_accepted_snapshot_id=second_snapshot where id=work_ids[index_value]; perform set_config('app.exhibition_work_rpc','off',true);
    elsif index_value=11 then
      insert into public.exhibition_caption_reviews(work_id,caption_snapshot_id,reviewer_identifier,result,problem_fields,reason)
        values(work_ids[index_value],caption_snapshot,admin_email,'rejected',array['other'],'期限切れCaption') returning id into review_uuid;
      insert into public.exhibition_caption_workflow_cases(work_id,event_id,member_id,case_type,source_caption_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
        values(work_ids[index_value],event_uuid,member_uuid,'correction',caption_snapshot,review_uuid,'open','期限切れCaption',now()-interval '1 minute',now());
      update public.exhibition_caption_working_data set state='rejected' where work_id=work_ids[index_value];
    end if;
  end loop;

  -- Six Smartphone Works: correction, permitted re-edit, submitted, accepted, withdrawn, expired correction.
  for index_value in 1..6 loop
    smartphone_uuid:=gen_random_uuid();
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    insert into public.exhibition_smartphone_works(id,event_id,entry_id,member_id,sort_order,workflow_state,original_image_path,
      original_sha256,orientation,smartphone_confirmed,ai_processing_declaration)
    values(smartphone_uuid,event_uuid,entry_uuid,member_uuid,index_value,'draft',event_uuid::text||'/'||member_uuid::text||'/'||smartphone_uuid::text||'/phone.jpg',
      repeat('c',64),'portrait',true,'none');
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    insert into public.exhibition_smartphone_work_submission_snapshots(smartphone_work_id,event_id,entry_id,member_id,version_no,
      original_image_path,original_sha256,orientation,smartphone_confirmed,ai_processing_declaration,
      agreement_definition_id,agreement_version,agreement_reference,agreement_content_hash,agreed_at,submitted_by_identifier)
    select smartphone_uuid,event_uuid,entry_uuid,member_uuid,1,event_uuid::text||'/'||member_uuid::text||'/'||smartphone_uuid::text||'/phone.jpg',
      repeat('c',64),'portrait',true,'none',terms.id,terms.version_no,terms.reference_key,terms.content_hash,now(),'__member_actions__@example.invalid'
    from public.exhibition_smartphone_agreement_definitions terms where terms.id=smartphone_agreement
    returning id into snapshot_uuid;
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='accepted',current_submission_snapshot_id=snapshot_uuid,
      current_accepted_snapshot_id=snapshot_uuid,submitted_at=now() where id=smartphone_uuid;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    smartphone_ids:=array_append(smartphone_ids,smartphone_uuid); smartphone_snapshots:=array_append(smartphone_snapshots,snapshot_uuid);
  end loop;
  insert into public.exhibition_smartphone_work_reviews(smartphone_work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(smartphone_ids[1],smartphone_snapshots[1],admin_email,'rejected',array['ai_declaration'],'AI申告を確認してください') returning id into review_uuid;
  insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
    values(smartphone_ids[1],event_uuid,member_uuid,'correction',smartphone_snapshots[1],review_uuid,'open','AI申告を確認してください',now()+interval '45 minutes',now());
  insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,state,request_reason,decision_reason,individual_deadline,requested_at,decided_at)
    values(smartphone_ids[2],event_uuid,member_uuid,'reedit',smartphone_snapshots[2],'permitted','再編集希望','許可',now()+interval '4 hours',now(),now());
  insert into public.exhibition_smartphone_work_reviews(smartphone_work_id,submission_snapshot_id,reviewer_identifier,result,problem_fields,reason)
    values(smartphone_ids[6],smartphone_snapshots[6],admin_email,'rejected',array['other'],'期限切れ') returning id into review_uuid;
  insert into public.exhibition_smartphone_workflow_cases(smartphone_work_id,event_id,member_id,case_type,source_submission_snapshot_id,source_review_id,state,decision_reason,individual_deadline,decided_at)
    values(smartphone_ids[6],event_uuid,member_uuid,'correction',smartphone_snapshots[6],review_uuid,'open','期限切れ',now()-interval '1 minute',now());
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='rejected' where id in (smartphone_ids[1],smartphone_ids[6]);
  update public.exhibition_smartphone_works set workflow_state='reedit_editing' where id=smartphone_ids[2];
  update public.exhibition_smartphone_works set workflow_state='submitted',current_accepted_snapshot_id=null where id=smartphone_ids[3];
  update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=smartphone_ids[5];
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);

  perform set_config('request.jwt.claims',jsonb_build_object('email','__member_actions__@example.invalid','role','authenticated')::text,true);
  select array_agg(action.action_type order by action.action_type) into action_types from public.get_my_exhibition_required_actions_v1() action;
  if action_types is distinct from array['caption_correction','caption_missing','caption_reedit','caption_stale',
    'regular_work_correction','regular_work_reedit','smartphone_work_correction','smartphone_work_reedit']::text[] then
    raise exception '本人Action一覧が不正です: %',action_types;
  end if;
  if not exists(select 1 from public.get_my_exhibition_required_actions_v1() action
    where action.action_type='regular_work_correction' and action.reason='向きを確認してください' and action.problem_fields=array['orientation']) then
    raise exception 'Work correctionがsource_review_idのReviewを参照していません。';
  end if;
  if not exists(select 1 from public.get_my_exhibition_required_actions_v1() action
    where action.action_type='caption_correction' and action.reason='Cameraを確認してください' and action.problem_fields=array['camera']) then
    raise exception 'Caption correctionがsource_review_idのReviewを参照していません。';
  end if;
  if not exists(select 1 from public.get_my_exhibition_required_actions_v1() action
    where action.action_type='smartphone_work_correction' and action.reason='AI申告を確認してください' and action.problem_fields=array['ai_declaration']) then
    raise exception 'Smartphone correctionがsource_review_idのReviewを参照していません。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__member_actions_other__@example.invalid','role','authenticated')::text,true);
  if exists(select 1 from public.get_my_exhibition_required_actions_v1()) then raise exception '他部員のActionが漏れています。'; end if;
  if has_function_privilege('anon','public.get_my_exhibition_required_actions_v1()','execute') then raise exception 'anonにRPC実行権限があります。'; end if;
  if not has_function_privilege('authenticated','public.get_my_exhibition_required_actions_v1()','execute') then raise exception 'authenticatedにRPC実行権限がありません。'; end if;
end $$;

select to_regprocedure('public.get_my_exhibition_required_actions_v1()') is not null as member_required_actions_rpc_ready;
rollback;
