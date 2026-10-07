-- Phase 3 verification。Phase 1〜3 migration適用後、SQL Editorで実行する。
-- 検証データとStorage objectは最後にROLLBACKされる。Productionへ自動適用しない。

begin;

do $$
<<verification>>
declare
  v_admin_email text; v_member_id uuid; v_event_id uuid; v_entry_id uuid; v_agreement_id uuid; v_agreement_hash text;
  v_work1 uuid; v_work2 uuid; v_replacement_id uuid; v_snapshot1 uuid; v_snapshot2 uuid; v_case_id uuid;
  v_result jsonb; v_object_path text; v_batch_count integer; v_snapshot_count integer;
  v_application_deadline timestamptz; v_work_deadline timestamptz; v_revision_deadline timestamptz; v_caption_deadline timestamptz;
begin
  select admin.email into v_admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if v_admin_email is null then raise exception '検証にはactiveなAdminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active)
  values('member-993001','__phase3_member__@example.invalid','Phase 3検証','B3',true) returning id into v_member_id;
  insert into public.membership_years(member_id,fiscal_year,active)
  values(v_member_id,private.current_fiscal_year(),true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__phase3_v2__','Phase 3検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email)
  returning id into v_event_id;
  perform public.admin_activate_exhibition_workflow_v2(v_event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','phase3-agreement','Phase 3検証Agreement','Phase 3検証');
  select agreement.id,agreement.content_hash into v_agreement_id,v_agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v_event_id and agreement.active;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  v_result:=public.submit_exhibition_application_v2(v_event_id,3,'real_name','','',v_agreement_id,v_agreement_hash);
  v_entry_id:=(v_result->>'entryId')::uuid;

  -- ApplicationがwithdrawnならWork作成不可。同じEntryを再申込してから続行する。
  perform public.withdraw_exhibition_application_v2(v_event_id,'Work作成条件の検証');
  begin perform public.save_exhibition_work_draft_v2(v_event_id,null,'','','','',null,null,null,null,null);
    raise exception 'withdrawn ApplicationでWorkを作成できました。';
  exception when others then if sqlerrm='withdrawn ApplicationでWorkを作成できました。' then raise; end if; end;
  perform public.submit_exhibition_application_v2(v_event_id,3,'real_name','','',v_agreement_id,v_agreement_hash);

  -- DB server timeでdeadline時刻そのものはclosed。
  select exhibition_application_deadline,exhibition_work_submission_deadline,exhibition_revision_deadline,exhibition_caption_deadline
    into v_application_deadline,v_work_deadline,v_revision_deadline,v_caption_deadline from public.events event where event.id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '1 hour',exhibition_work_submission_deadline=now(),
    exhibition_revision_deadline=now()+interval '1 hour',exhibition_caption_deadline=now()+interval '2 hours' where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  begin perform public.save_exhibition_work_draft_v2(v_event_id,null,'','','','',null,null,null,null,null);
    raise exception 'deadline時刻ちょうどにWorkを作成できました。';
  exception when others then if sqlerrm='deadline時刻ちょうどにWorkを作成できました。' then raise; end if; end;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=v_application_deadline,exhibition_work_submission_deadline=v_work_deadline,
    exhibition_revision_deadline=v_revision_deadline,exhibition_caption_deadline=v_caption_deadline where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  -- 不完全Draftは保存でき、Snapshotを作らない。
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'','','','',null,null,null,null,null);
  v_work1:=(v_result->>'id')::uuid;
  if exists(select 1 from public.exhibition_work_submission_snapshots snapshot where snapshot.work_id=v_work1) then
    raise exception 'Draft保存でSnapshotが作成されました。';
  end if;
  v_result:=public.save_exhibition_work_draft_v2(v_event_id,null,'未完成','','','',null,null,null,null,null);
  v_work2:=(v_result->>'id')::uuid;

  -- Formal submit用のversioned objectを用意し、完全なWorking Dataへ更新する。
  v_object_path:=v_event_id::text||'/'||v_member_id::text||'/'||v_work1::text||'/phase3-v1.jpg';
  insert into storage.objects(bucket_id,name,metadata)
  values('exhibition-originals',v_object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work1,'作品1','portrait','A3','',297,420,true,v_object_path,repeat('a',64));

  v_result:=public.submit_exhibition_work_batch_v2(v_event_id,array[v_work1,v_work2]);
  if jsonb_array_length(v_result->'submittedWorkIds')<>1 or jsonb_array_length(v_result->'incompleteWorkIds')<>1 then
    raise exception 'Batchが提出可能/未完成を正しく分離しませんでした。';
  end if;
  select count(*) into v_batch_count from public.exhibition_work_submission_batches batch where batch.entry_id=v_entry_id;
  select count(*) into v_snapshot_count from public.exhibition_work_submission_snapshots snapshot where snapshot.work_id=v_work1;
  select snapshot.id into v_snapshot1 from public.exhibition_work_submission_snapshots snapshot
    where snapshot.work_id=v_work1 order by snapshot.version_no desc limit 1;
  if v_batch_count<>1 or v_snapshot_count<>1 then raise exception 'BatchまたはSnapshotが作成されていません。'; end if;

  -- Snapshot/Batchはimmutable。直接のWork更新も拒否する。
  begin update public.exhibition_work_submission_snapshots set title='改ざん' where id=v_snapshot1;
    raise exception 'Snapshot UPDATEが拒否されませんでした。';
  exception when others then if sqlerrm='Snapshot UPDATEが拒否されませんでした。' then raise; end if; end;
  begin update public.exhibition_works set title='直接改ざん' where id=v_work1;
    raise exception 'v2 Work直接UPDATEが拒否されませんでした。';
  exception when others then if sqlerrm='v2 Work直接UPDATEが拒否されませんでした。' then raise; end if; end;

  -- Reviewはcurrent Snapshotだけを一度処理できる。
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(v_snapshot1,'rejected',array['orientation'],'向きを修正してください',null);
  begin perform public.admin_review_exhibition_work_v2(v_snapshot1,'accepted','{}'::text[],'',null);
    raise exception '同じSnapshotの二重Reviewが拒否されませんでした。';
  exception when others then if sqlerrm='同じSnapshotの二重Reviewが拒否されませんでした。' then raise; end if; end;

  -- Reject後のSaveだけではsubmittedに戻らず、明示Resubmitでversion 2となる。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work1,'作品1 修正版','landscape','A3','',420,297,true,v_object_path,repeat('a',64));
  if (select work.workflow_state from public.exhibition_works work where work.id=v_work1)<>'rejected' then raise exception 'Correction Saveでstateが変化しました。'; end if;
  perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_work1]);
  select snapshot.id into v_snapshot2 from public.exhibition_work_submission_snapshots snapshot where snapshot.work_id=v_work1 and snapshot.version_no=2;
  if v_snapshot2 is null then raise exception 'Correction Resubmit Snapshotがありません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(v_snapshot2,'accepted','{}'::text[],'',null);

  -- Accepted取下げは理由必須。Re-edit取消は最後のaccepted Snapshotへ復元する。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  begin perform public.withdraw_exhibition_work_v2(v_work1,'');
    raise exception 'Accepted Workを理由なしで取り下げられました。';
  exception when others then if sqlerrm='Accepted Workを理由なしで取り下げられました。' then raise; end if; end;
  v_result:=public.request_exhibition_work_reedit_v2(v_work1,'作品名を再調整したい'); v_case_id:=(v_result->>'caseId')::uuid;
  if (select work.current_accepted_snapshot_id from public.exhibition_works work where work.id=v_work1) is null then
    raise exception 'Pending requestだけでaccepted referenceが外れました。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2(v_case_id,true,'再編集を許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work1,'一時的な変更','portrait','A3','',297,420,true,v_object_path,repeat('a',64));
  perform public.cancel_permitted_exhibition_work_reedit_v2(v_case_id,'変更を取りやめる');
  if (select work.workflow_state from public.exhibition_works work where work.id=v_work1)<>'accepted'
     or (select work.title from public.exhibition_works work where work.id=v_work1)<>'作品1 修正版' then
    raise exception 'Re-edit取消でaccepted Snapshotへ復元されませんでした。';
  end if;

  -- Accepted re-editは申請→許可→実変更→再提出を要求する。
  v_result:=public.request_exhibition_work_reedit_v2(v_work1,'改めて再編集したい'); v_case_id:=(v_result->>'caseId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2(v_case_id,true,'再編集を許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  begin perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_work1]);
    raise exception '変更なしRe-editが拒否されませんでした。';
  exception when others then if sqlerrm='変更なしRe-editが拒否されませんでした。' then raise; end if; end;
  perform public.save_exhibition_work_draft_v2(v_event_id,v_work1,'作品1 再編集','portrait','A3','',297,420,true,v_object_path,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_work1]);

  -- Replacement Draft作成時にはAを維持し、BのFormal submitと同時にAをwithdrawする。
  v_result:=public.start_exhibition_work_replacement_v2(v_work1); v_replacement_id:=(v_result->>'replacementWorkId')::uuid;
  if (select work.workflow_state from public.exhibition_works work where work.id=v_work1)='withdrawn' then raise exception 'Replacement Draft作成時に旧Workが取り下げられました。'; end if;
  if (select work.display_no from public.exhibition_works work where work.id=v_replacement_id)<>'' then raise exception 'Replacementへdisplay_noが継承されました。'; end if;
  v_object_path:=v_event_id::text||'/'||v_member_id::text||'/'||v_replacement_id::text||'/replacement-v1.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',v_object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(v_event_id,v_replacement_id,'差し替え作品','landscape','A3','',420,297,false,v_object_path,repeat('b',64));
  perform public.submit_exhibition_work_batch_v2(v_event_id,array[v_replacement_id]);
  if (select work.workflow_state from public.exhibition_works work where work.id=v_work1)<>'withdrawn'
     or (select work.workflow_state from public.exhibition_works work where work.id=v_replacement_id)<>'submitted' then
    raise exception 'Replacement submitのatomic state遷移に失敗しました。';
  end if;

  -- SYSTEM auto-cancel後は通常Application RPCで復活できず、Admin revivalは1回だけ。
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_withdraw_exhibition_work_v2(v_replacement_id,'Entry auto-cancel検証');
  perform public.admin_withdraw_exhibition_work_v2(v_work2,'Entry auto-cancel検証');
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',exhibition_revision_deadline=now()-interval '2 hours',
    exhibition_caption_deadline=now()-interval '1 hour' where id=v_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  perform private.auto_cancel_v2_entry_if_no_viable(v_entry_id,'phase3-deadline-no-viable-work');
  if (select entry.application_state from public.exhibition_entries entry where entry.id=v_entry_id)<>'auto_cancelled' then raise exception 'viable Work 0でauto-cancelされませんでした。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
  begin perform public.submit_exhibition_application_v2(v_event_id,1,'real_name','','',v_agreement_id,v_agreement_hash);
    raise exception '通常再申込でauto-cancelを回避できました。';
  exception when others then if sqlerrm='通常再申込でauto-cancelを回避できました。' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  perform public.admin_revive_exhibition_entry_v2(v_entry_id,'例外提出を許可',now()+interval '1 day');
  begin perform public.admin_revive_exhibition_entry_v2(v_entry_id,'2回目',now()+interval '1 day');
    raise exception '2回目のRevivalが拒否されませんでした。';
  exception when others then if sqlerrm='2回目のRevivalが拒否されませんでした。' then raise; end if; end;

  if not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v_event_id and audit.action='entry_revived') then
    raise exception 'Phase 3 Auditが不足しています。';
  end if;
end $$;

-- Memberは履歴を読めるのは本人分だけで、直接INSERT/UPDATE/DELETEできない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase3_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin insert into public.exhibition_work_reviews(work_id,submission_snapshot_id,reviewer_identifier,result)
    values(gen_random_uuid(),gen_random_uuid(),'forged','accepted');
    raise exception 'MemberがReviewを偽造できました。';
  exception when insufficient_privilege then null; end;
  begin delete from public.exhibition_work_submission_snapshots;
    raise exception 'MemberがSnapshotを削除できました。';
  exception when insufficient_privilege then null; end;
  delete from storage.objects o where o.bucket_id='exhibition-originals'
    and o.name=(select s.original_image_path from public.exhibition_work_submission_snapshots s order by s.submitted_at limit 1);
  if not exists(
    select 1 from storage.objects o where o.bucket_id='exhibition-originals'
      and o.name=(select s.original_image_path from public.exhibition_work_submission_snapshots s order by s.submitted_at limit 1)
  ) then raise exception 'Formal Snapshot参照中のoriginalをMemberが削除できました。'; end if;
end $$;
reset role;

select
  to_regprocedure('public.submit_exhibition_work_batch_v2(uuid,uuid[])') is not null as batch_rpc_ready,
  to_regprocedure('public.admin_review_exhibition_work_v2(uuid,text,text[],text,timestamptz)') is not null as review_rpc_ready,
  to_regclass('public.exhibition_work_submission_snapshots') is not null as snapshots_ready,
  exists(select 1 from public.events where title='__phase3_v2__' and exhibition_workflow_version=2) as v2_preserved,
  not exists(select 1 from public.events where title<>'__phase3_v2__' and genre<>'exhibition' and exhibition_workflow_version<>1) as general_events_not_promoted,
  to_regprocedure('public.get_public_exhibition(text)') is not null as legacy_public_rpc_preserved,
  to_regclass('public.exhibition_layouts') is not null as legacy_layout_preserved,
  to_regclass('public.archive_works') is not null as legacy_archive_preserved;

rollback;
