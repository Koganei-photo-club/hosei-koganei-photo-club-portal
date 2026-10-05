-- Phase 4 Caption workflow verification。全検証データはROLLBACKされる。
begin;

do $$
<<verification>>
declare
  v_admin_email text; v_member1_id uuid; v_member2_id uuid; v_event_id uuid; v_legacy_event_id uuid; v_entry_id uuid; v_work_id uuid; v_unaccepted_work_id uuid;
  v_agreement_id uuid; v_agreement_hash text; v_work_snapshot_id uuid; v_caption1_id uuid; v_caption2_id uuid; v_caption3_id uuid; v_review_id uuid; v_case_id uuid;
  v_result jsonb; v_object_path text; v_original_application_deadline timestamptz; v_original_work_deadline timestamptz;
  v_original_revision_deadline timestamptz; v_original_caption_deadline timestamptz; v_audit_count integer; v_derivation_id uuid;
begin
  select admin.email into v_admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if v_admin_email is null then raise exception '検証にはactiveなAdminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values
    ('member-994001','__phase4_member1__@example.invalid','Phase 4検証','B3',true),
    ('member-994002','__phase4_member2__@example.invalid','別部員','B2',true);
  select member.id into v_member1_id from public.members member where member.email='__phase4_member1__@example.invalid';
  select member.id into v_member2_id from public.members member where member.email='__phase4_member2__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (v_member1_id,private.current_fiscal_year(),true),(v_member2_id,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__phase4_v2__','Phase 4検証',now()+interval '10 days',now()+interval '11 days','検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email)
  returning id into v_event_id;
  perform public.admin_activate_exhibition_workflow_v2(v_event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase4-agreement','Phase 4 Agreement','Phase 4検証');
  select agreement.id,agreement.content_hash into v_agreement_id,v_agreement_hash from public.exhibition_agreement_definitions agreement where agreement.event_id=v_event_id and agreement.active;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  v_result:=public.submit_exhibition_application_v2(v_event_id,2,'real_name','','',v_agreement_id,v_agreement_hash);
  v_entry_id:=(v_result->>'entryId')::uuid;
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'Caption対象','portrait','A3','',297,420,true,null,null);
  v_work_id:=(v_result->>'id')::uuid;
  v_object_path:=v_event_id::text||'/'||v_member1_id::text||'/'||v_work_id::text||'/phase4.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',v_object_path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work_id,'Caption対象','portrait','A3','',297,420,true,v_object_path,repeat('c',64));
  v_result:=public.submit_exhibition_work_batch_v2(v_event_id,array[v_work_id]);
  select work.current_submission_snapshot_id into v_work_snapshot_id from public.exhibition_works work where work.id=v_work_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(v_work_snapshot_id,'accepted','{}','',null);

  -- v1はPhase 4へ自動移行されない。
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__phase4_v1__','Phase 4 Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email)
  returning id into v_legacy_event_id;
  if (select event.exhibition_workflow_version from public.events event where event.id=v_legacy_event_id)<>1 then raise exception 'Legacy Eventがv2化されました。'; end if;

  -- 未確認WorkはCaption正式提出不可。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'未確認','portrait','A3','',297,420,true,null,null);
  v_unaccepted_work_id:=(v_result->>'id')::uuid;
  perform public.save_exhibition_caption_draft_v2(v_unaccepted_work_id,'Phase 4検証','organizer','','digital','','Camera','','','unnecessary','','','none','',null,'none','');
  begin perform public.submit_exhibition_caption_v2(v_unaccepted_work_id); raise exception '未確認WorkでCaption提出できました。';
  exception when others then if sqlerrm='未確認WorkでCaption提出できました。' then raise; end if; end;

  -- undecided/self英題/film条件をserver-sideで拒否する。
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','self','','digital','','Camera','','','undecided','','','none','',null,'none','');
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception '未解決Captionが提出できました。';
  exception when others then if sqlerrm='未解決Captionが提出できました。' then raise; end if; end;
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','self','','film','','Camera','','','unnecessary','','','none','',null,'none','');
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception '英題/Film不足が許可されました。';
  exception when others then if sqlerrm='英題/Film不足が許可されました。' then raise; end if; end;

  -- AI生成・大幅加工等は正式提出時に選択必須。「あり」は内容も必須。
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','organizer','','digital','','Camera','','','unnecessary','','','none','',null,null,'');
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception 'AI/加工申告の未選択が許可されました。';
  exception when others then if sqlerrm='AI/加工申告の未選択が許可されました。' then raise; end if; end;
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','organizer','','digital','','Camera','','','unnecessary','','','none','',null,'declared','');
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception 'AI/加工ありの内容不足が許可されました。';
  exception when others then if sqlerrm='AI/加工ありの内容不足が許可されました。' then raise; end if; end;

  -- organizer modeは空英題で提出可能。Snapshotはimmutable。
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','organizer','','film','','Camera','Lens','Film X','provided','説明','','none','',null,'declared','生成AIで背景の一部を補完');
  v_result:=public.submit_exhibition_caption_v2(v_work_id); v_caption1_id:=(v_result->>'snapshotId')::uuid;
  if (select snapshot.ai_processing_declaration from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_caption1_id)<>'declared'
    or (select snapshot.ai_processing_details from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_caption1_id)<>'生成AIで背景の一部を補完'
    then raise exception 'AI/加工申告がCaption Snapshotへ固定されませんでした。'; end if;
  begin update public.exhibition_caption_submission_snapshots set display_name='改ざん' where id=v_caption1_id; raise exception 'Caption Snapshotを更新できました。';
  exception when others then if sqlerrm='Caption Snapshotを更新できました。' then raise; end if; end;

  -- exact deadlineはclosed。
  begin perform public.admin_review_exhibition_caption_v2(v_caption1_id,'accepted','{}','',null); raise exception 'MemberがCaption Reviewを実行できました。';
  exception when others then if sqlerrm='MemberがCaption Reviewを実行できました。' then raise; end if; end;
  select exhibition_application_deadline,exhibition_work_submission_deadline,exhibition_revision_deadline,exhibition_caption_deadline
    into v_original_application_deadline,v_original_work_deadline,v_original_revision_deadline,v_original_caption_deadline
    from public.events event where event.id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '3 hours',
    exhibition_work_submission_deadline=now()-interval '2 hours',exhibition_revision_deadline=now()-interval '1 hour',
    exhibition_caption_deadline=now() where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  update public.exhibition_caption_working_data caption set state='draft' where caption.work_id=v_work_id;
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception 'Caption締切時刻に提出できました。';
  exception when others then if sqlerrm='Caption締切時刻に提出できました。' then raise; end if; end;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=v_original_application_deadline,
    exhibition_work_submission_deadline=v_original_work_deadline,exhibition_revision_deadline=v_original_revision_deadline,
    exhibition_caption_deadline=v_original_caption_deadline where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  update public.exhibition_caption_working_data caption set state='submitted',current_submission_snapshot_id=v_caption1_id where caption.work_id=v_work_id;

  -- 主催者英題はmember Snapshotを変更せず派生履歴になる。
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  v_result:=public.admin_set_exhibition_caption_organizer_title_v2(v_caption1_id,'Organizer Title','検証'); v_derivation_id:=(v_result->>'derivationId')::uuid;
  if (select snapshot.member_english_title from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=v_caption1_id)<>'' or v_derivation_id is null then raise exception '主催者英題のprovenanceが不正です。'; end if;
  v_result:=public.admin_review_exhibition_caption_v2(v_caption1_id,'rejected',array['description'],'説明を修正',null); v_review_id:=(v_result->>'reviewId')::uuid;
  select caption_case.id into v_case_id from public.exhibition_caption_workflow_cases caption_case where caption_case.source_review_id=v_review_id;
  if v_case_id is null then raise exception 'Caption correction Caseが作成されませんでした。'; end if;

  -- Correctionは明示再提出でversion 2、古いSnapshot Reviewは拒否。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証','self','Self Title','digital','','Camera','','','provided','修正版説明','','none','',null,'none','');
  v_result:=public.submit_exhibition_caption_v2(v_work_id); v_caption2_id:=(v_result->>'snapshotId')::uuid;
  if (v_result->>'versionNo')::integer<>2 then raise exception 'Caption versionが増加しませんでした。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  begin perform public.admin_review_exhibition_caption_v2(v_caption1_id,'accepted','{}','',null); raise exception '古いCaption SnapshotをReviewできました。';
  exception when others then if sqlerrm='古いCaption SnapshotをReviewできました。' then raise; end if; end;
  perform public.admin_review_exhibition_caption_v2(v_caption2_id,'accepted','{}','',null);

  -- Accepted再編集はpending中accepted snapshotを保持し、許可後も明示再提出が必要。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  v_result:=public.request_exhibition_caption_reedit_v2(v_work_id,'表現修正'); v_case_id:=(v_result->>'caseId')::uuid;
  if (select caption.current_accepted_snapshot_id from public.exhibition_caption_working_data caption where caption.work_id=v_work_id) is distinct from v_caption2_id then raise exception 'pendingでaccepted Captionが外れました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_caption_reedit_v2(v_case_id,true,'許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  begin perform public.submit_exhibition_caption_v2(v_work_id); raise exception '変更なしCaption再提出が許可されました。';
  exception when others then if sqlerrm='変更なしCaption再提出が許可されました。' then raise; end if; end;
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証 改','self','Self Title','digital','','Camera','','','provided','修正版説明','','none','',null,'none','');
  perform public.cancel_exhibition_caption_reedit_v2(v_case_id,'取消');
  if (select caption.display_name from public.exhibition_caption_working_data caption where caption.work_id=v_work_id)<>'Phase 4検証' then raise exception '取消でaccepted Captionへ復元されませんでした。'; end if;

  -- 再度許可→変更→version 3。Work acceptanceはCaption状態とは別に維持。
  v_result:=public.request_exhibition_caption_reedit_v2(v_work_id,'再編集'); v_case_id:=(v_result->>'caseId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_caption_reedit_v2(v_case_id,true,'許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member1__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(v_work_id,'Phase 4検証 改','self','Self Title','digital','','Camera','','','provided','修正版説明','','none','',null,'none','');
  v_result:=public.submit_exhibition_caption_v2(v_work_id); v_caption3_id:=(v_result->>'snapshotId')::uuid;
  if (v_result->>'versionNo')::integer<>3 or (select work.workflow_state from public.exhibition_works work where work.id=v_work_id)<>'accepted' then raise exception 'Caption再提出またはWork独立状態が不正です。'; end if;

  -- Review history immutable。期限処理は2回実行しても追加変化しない。
  begin update public.exhibition_caption_reviews set reason='改ざん' where id=v_review_id; raise exception 'Caption Reviewを更新できました。';
  exception when others then if sqlerrm='Caption Reviewを更新できました。' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(v_caption3_id,'rejected',array['other'],'期限検証',now()+interval '1 second');
  update public.exhibition_caption_workflow_cases caption_case set individual_deadline=now()-interval '1 second' where caption_case.work_id=v_work_id and caption_case.state='open';
  perform public.admin_process_exhibition_caption_deadlines_v2(v_event_id);
  perform public.admin_process_exhibition_caption_deadlines_v2(v_event_id);
  if (select count(*) from public.exhibition_caption_workflow_cases caption_case where caption_case.work_id=v_work_id and caption_case.state='expired')<>1 then raise exception 'SYSTEM期限処理が非idempotentです。'; end if;

  select count(*) into v_audit_count from public.exhibition_workflow_audit_logs audit where audit.event_id=v_event_id and audit.action like 'caption%';
  if v_audit_count<10 then raise exception 'Caption Auditが不足しています。'; end if;
end $$;

-- 他MemberはWorking Data/Snapshot/Review/Caseを参照・変更できない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase4_member2__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.exhibition_caption_working_data) or exists(select 1 from public.exhibition_caption_submission_snapshots) then raise exception '別MemberにCaptionが公開されています。'; end if;
  begin update public.exhibition_caption_working_data set display_name='改ざん'; raise exception 'MemberがCaption Working Dataを直接更新できました。'; exception when insufficient_privilege then null; end;
  begin insert into public.exhibition_caption_reviews(work_id,caption_snapshot_id,reviewer_identifier,result) values(gen_random_uuid(),gen_random_uuid(),'forged','accepted'); raise exception 'MemberがCaption Reviewを偽造できました。'; exception when insufficient_privilege then null; end;
end $$;
reset role;

select
  to_regprocedure('public.submit_exhibition_caption_v2(uuid)') is not null as submit_rpc_ready,
  to_regprocedure('public.admin_review_exhibition_caption_v2(uuid,text,text[],text,timestamptz)') is not null as review_rpc_ready,
  to_regclass('public.exhibition_caption_submission_snapshots') is not null as snapshots_ready,
  not exists(select 1 from public.events where genre<>'exhibition' and exhibition_workflow_version<>1) as general_events_legacy;

rollback;
