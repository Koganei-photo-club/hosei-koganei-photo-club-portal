-- Phase 5 Action Center / SYSTEM / Work-Caption consistency verification。全変更はROLLBACKされる。
begin;

do $$
declare
  v_admin_email text; v_member_id uuid; v_event_id uuid; v_entry_id uuid; v_work_id uuid; v_draft_work uuid;
  v_agreement_id uuid; v_agreement_hash text; v_object_path text; v_result jsonb; v_w1 uuid; v_w2 uuid; v_c1 uuid; v_c2 uuid;
  v_caption_case uuid; v_before_audit integer; v_after_audit integer;
begin
  select admin.email into v_admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if v_admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active)
    values('member-995001','__phase5_member__@example.invalid','Phase 5検証','B3',true) returning id into v_member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(v_member_id,private.current_fiscal_year(),true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
    values('saved',true,'exhibition','__phase5_v2__','Phase 5検証',now()+interval '10 days',now()+interval '11 days','検証',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email)
    returning id into v_event_id;
  perform public.admin_activate_exhibition_workflow_v2(v_event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase5','Phase 5 Agreement','検証');
  select agreement.id,agreement.content_hash into v_agreement_id,v_agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v_event_id and agreement.active;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  v_result:=public.submit_exhibition_application_v2(v_event_id,3,'real_name','','',v_agreement_id,v_agreement_hash); v_entry_id:=(v_result->>'entryId')::uuid;
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'W1','portrait','A3','',297,420,true,null,null); v_work_id:=(v_result->>'id')::uuid;
  v_object_path:=v_event_id::text||'/'||v_member_id::text||'/'||v_work_id::text||'/w1.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',v_object_path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work_id,'W1','portrait','A3','',297,420,true,v_object_path,repeat('d',64));
  perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_work_id]);
  select work.current_submission_snapshot_id into v_w1 from public.exhibition_works work where work.id=v_work_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='work_review' and action.snapshot_id=v_w1) then raise exception 'Work review actionがありません。'; end if;
  perform public.admin_review_exhibition_work_v2(v_w1,'accepted','{}','',null);
  if exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='work_review' and action.work_id=v_work_id) then raise exception 'Review済みWork actionが残っています。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_missing' and action.work_id=v_work_id) then raise exception 'Caption missing actionがありません。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 5','organizer','','digital','','Camera','','','unnecessary','','','none','',null);
  v_result:=public.submit_exhibition_caption_v2(v_work_id); v_c1:=(v_result->>'snapshotId')::uuid;
  if (select snapshot.work_submission_snapshot_id from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_c1) is distinct from v_w1 then raise exception 'C1がW1へ固定されていません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_review' and action.snapshot_id=v_c1) then raise exception 'Caption review actionがありません。'; end if;
  perform public.admin_review_exhibition_caption_v2(v_c1,'accepted','{}','',null);
  if exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type in ('caption_missing','caption_stale','caption_review') and action.work_id=v_work_id) then raise exception 'C1 accept後もCaption actionが残っています。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='organizer_english_title' and action.snapshot_id=v_c1) then raise exception 'Organizer title actionがありません。'; end if;
  perform public.admin_set_exhibition_caption_organizer_title_v2(v_c1,'Title for C1','検証');
  if exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='organizer_english_title' and action.snapshot_id=v_c1) then raise exception 'Organizer title actionが消えません。'; end if;

  -- Work accepted re-edit decision → member pending → W2 accepted。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  v_result:=public.request_exhibition_work_reedit_v2(v_work_id,'W2へ変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='work_reedit_decision') then raise exception 'Work decision actionがありません。'; end if;
  perform public.admin_decide_exhibition_work_reedit_v2((v_result->>'caseId')::uuid,true,'許可',now()+interval '1 day');
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='work_reedit_resubmission_pending' and action.category='member_action_pending') then raise exception 'Work member pendingが区別されません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work_id,'W2','portrait','A3','',297,420,true,v_object_path,repeat('d',64));
  perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_work_id]);
  select work.current_submission_snapshot_id into v_w2 from public.exhibition_works work where work.id=v_work_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(v_w2,'accepted','{}','',null);
  if v_w2=v_w1 or not exists(select 1 from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_c1 and snapshot.work_submission_snapshot_id=v_w1) then raise exception 'W1+C1履歴が保持されていません。'; end if;
  if coalesce(private.caption_pair_is_current_v2(v_work_id),false) then raise exception 'C1がW2のcurrent Captionとして扱われました。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_stale' and action.work_id=v_work_id) then raise exception 'Stale Caption actionがありません。'; end if;

  -- C2はW2へ固定され、C1のOrganizer titleはC2を満たさない。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  perform public.start_stale_exhibition_caption_resubmission_v2(v_work_id);
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 5','organizer','','digital','','Camera','','','unnecessary','','','none','',null);
  v_result:=public.submit_exhibition_caption_v2(v_work_id); v_c2:=(v_result->>'snapshotId')::uuid;
  if (select snapshot.work_submission_snapshot_id from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_c2) is distinct from v_w2 then raise exception 'C2がW2へ固定されていません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  if exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_stale' and action.work_id=v_work_id) then raise exception 'C2提出後もStale Caption actionが残っています。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_review' and action.snapshot_id=v_c2) then raise exception 'C2のCaption review actionがありません。'; end if;
  perform public.admin_review_exhibition_caption_v2(v_c2,'accepted','{}','',null);
  if not coalesce(private.caption_pair_is_current_v2(v_work_id),false) then raise exception 'W2+C2がcurrent pairになりません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='organizer_english_title' and action.snapshot_id=v_c2) then raise exception 'C1 derivationがC2を誤って満たしました。'; end if;
  if not exists(select 1 from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_c1 and snapshot.work_submission_snapshot_id=v_w1) then raise exception 'W1+C1履歴が失われました。'; end if;

  -- Caption re-edit decisionとmember pending。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  v_result:=public.request_exhibition_caption_reedit_v2(v_work_id,'Caption変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_reedit_decision') then raise exception 'Caption decision actionがありません。'; end if;
  perform public.admin_decide_exhibition_caption_reedit_v2((v_result->>'caseId')::uuid,true,'許可',now()+interval '1 second');
  v_caption_case:=(v_result->>'caseId')::uuid;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_reedit_resubmission_pending' and action.category='member_action_pending') then raise exception 'Caption member pendingが区別されません。'; end if;
  update public.exhibition_caption_workflow_cases caption_case set individual_deadline=now() where caption_case.id=v_caption_case;
  if not exists(select 1 from public.admin_get_exhibition_action_center_v2(v_event_id) action where action.action_type='caption_case_due') then raise exception 'Deadline boundary actionがありません。'; end if;
  select count(*) into v_before_audit from public.exhibition_workflow_audit_logs audit where audit.event_id=v_event_id and audit.action='caption_case_expired';
  perform public.admin_process_due_exhibition_workflows_v2(v_event_id);
  perform public.admin_process_due_exhibition_workflows_v2(v_event_id);
  select count(*) into v_after_audit from public.exhibition_workflow_audit_logs audit where audit.event_id=v_event_id and audit.action='caption_case_expired';
  if v_after_audit<>v_before_audit+1 then raise exception 'SYSTEM rerunでCaption expiry Auditが重複しました。'; end if;

  -- Work deadline consequenceも同じorchestratorで処理。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'期限Draft','portrait','A3','',297,420,true,null,null); v_draft_work:=(v_result->>'id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '4 hours',exhibition_work_submission_deadline=now(),
    exhibition_revision_deadline=now()+interval '1 hour',exhibition_caption_deadline=now()+interval '2 hours' where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  perform public.admin_process_due_exhibition_workflows_v2(v_event_id);
  if (select work.workflow_state from public.exhibition_works work where work.id=v_draft_work)<>'withdrawn' then raise exception 'SYSTEMが期限到達Work Draftを処理しませんでした。'; end if;
end $$;

-- MemberはAction Centerとmanual SYSTEM processorを利用できない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase5_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_get_exhibition_action_center_v2(null); raise exception 'MemberがAction Centerを参照できました。';
  exception when others then if sqlerrm='MemberがAction Centerを参照できました。' then raise; end if; end;
  begin perform public.admin_process_due_exhibition_workflows_v2(null); raise exception 'MemberがSYSTEM processorを実行できました。';
  exception when others then if sqlerrm='MemberがSYSTEM processorを実行できました。' then raise; end if; end;
end $$;
reset role;

-- 一般Event / workflow v1は対象外。
do $$ declare v_legacy_id uuid; v_before_count integer; v_after_count integer; v_admin_email text;
begin
  select admin.email into v_admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__phase5_legacy__','Phase 5 Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email)
  returning id into v_legacy_id;
  select count(*) into v_before_count from public.admin_get_exhibition_action_center_v2(null) action where action.event_id=v_legacy_id;
  perform public.admin_process_due_exhibition_workflows_v2(v_legacy_id);
  select count(*) into v_after_count from public.admin_get_exhibition_action_center_v2(null) action where action.event_id=v_legacy_id;
  if v_before_count<>0 or v_after_count<>0 then raise exception 'workflow v1がPhase 5対象になりました。'; end if;
end $$;

rollback;
