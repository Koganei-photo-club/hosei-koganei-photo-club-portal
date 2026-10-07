-- Smartphone exhibition Phase 1 verification. All fixtures are rolled back.
begin;

do $$
<<v>>
declare
  admin_email text; event_id uuid; agreement_id uuid; agreement_hash text;
  member1 uuid; member2 uuid; member3 uuid; member4 uuid; entry1 uuid; entry2 uuid; entry3 uuid; entry4 uuid;
  terms jsonb; result jsonb; smartphone1 uuid; smartphone2 uuid; snapshot1 uuid; snapshot2 uuid; case_id uuid;
  regular_work uuid; snapshot_count integer;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'スマホ枠検証にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active) values
    ('member-999081','__smartphone_1__@example.invalid','スマホ部員1','B1',true),
    ('member-999082','__smartphone_2__@example.invalid','スマホ部員2','B2',true),
    ('member-999083','__smartphone_3__@example.invalid','スマホ部員3','B3',true),
    ('member-999084','__smartphone_4__@example.invalid','スマホ部員4','B4',true);
  select id into member1 from public.members where email='__smartphone_1__@example.invalid';
  select id into member2 from public.members where email='__smartphone_2__@example.invalid';
  select id into member3 from public.members where email='__smartphone_3__@example.invalid';
  select id into member4 from public.members where email='__smartphone_4__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member1,private.current_fiscal_year(),true),(member2,private.current_fiscal_year(),true),
    (member3,private.current_fiscal_year(),true),(member4,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__smartphone_phase1__','スマホ枠検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"smartphone-slot","label":"検証枠"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','smartphone-phase1-application','Application規約','スマホ枠検証');
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  if (select smartphone_exhibition_enabled from public.events where id=event_id)
     or (select max_smartphone_works from public.events where id=event_id)<>0 then
    raise exception 'スマホ枠の安全なdefault OFFが不正です。';
  end if;
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_1__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash);
  entry1:=(result->>'entryId')::uuid;
  if not exists(select 1 from public.exhibition_application_snapshots s where s.id=(result->>'snapshotId')::uuid and s.planned_work_count=0)
    then raise exception 'planned_work_count=0がSnapshotへ保存されません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_2__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash); entry2:=(result->>'entryId')::uuid;
  if (select planned_work_count from public.exhibition_entries where id=entry2)<>1 then raise exception '既存planned_work_count>=1互換性が壊れています。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_3__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry3:=(result->>'entryId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_4__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash); entry4:=(result->>'entryId')::uuid;

  -- Draft and Formal Submission, including server-side confirmation and AI validation.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_1__@example.invalid','role','authenticated')::text,true);
  terms:=public.get_exhibition_smartphone_terms_v1();
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',false,'none','',null,null);
  smartphone1:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v1.jpg',member1,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone1,'portrait',false,'none','',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v1.jpg',repeat('a',64));
  begin
    perform public.submit_exhibition_smartphone_work_v1(smartphone1,(terms->>'id')::uuid,terms->>'contentHash');
    raise exception 'スマートフォン撮影未確認で正式提出できました。';
  exception when others then if sqlerrm='スマートフォン撮影未確認で正式提出できました。' then raise; end if; end;
  begin
    perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone1,'portrait',true,'declared','',
      event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v1.jpg',repeat('a',64));
    raise exception 'AI申告あり・詳細なしを保存できました。';
  exception when others then if sqlerrm='AI申告あり・詳細なしを保存できました。' then raise; end if; end;
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone1,'portrait',true,'declared','背景の一部を生成',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v1.jpg',repeat('a',64));
  result:=public.submit_exhibition_smartphone_work_v1(smartphone1,(terms->>'id')::uuid,terms->>'contentHash'); snapshot1:=(result->>'snapshotId')::uuid;
  if not exists(select 1 from public.exhibition_smartphone_work_submission_snapshots s where s.id=snapshot1 and s.smartphone_confirmed
    and s.ai_processing_declaration='declared' and s.agreement_content_hash=terms->>'contentHash') then raise exception 'Formal Snapshotの内容が不正です。'; end if;
  begin update public.exhibition_smartphone_work_submission_snapshots set orientation='landscape' where id=snapshot1;
    raise exception 'Smartphone Snapshotを更新できました。';
  exception when others then if sqlerrm='Smartphone Snapshotを更新できました。' then raise; end if; end;

  -- Needs Revision -> new immutable snapshot -> Accepted.
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_review_exhibition_smartphone_work_v1(snapshot1,'rejected',array['orientation'],'向きを確認してください',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_1__@example.invalid','role','authenticated')::text,true);
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v2.jpg',member1,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone1,'landscape',true,'none','',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/smartphone-v2.jpg',repeat('b',64));
  result:=public.submit_exhibition_smartphone_work_v1(smartphone1,(terms->>'id')::uuid,terms->>'contentHash'); snapshot2:=(result->>'snapshotId')::uuid;
  select count(*) into snapshot_count from public.exhibition_smartphone_work_submission_snapshots where smartphone_work_id=smartphone1;
  if snapshot_count<>2 or snapshot1=snapshot2 then raise exception '再提出で新Snapshotが作られません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(snapshot2,'accepted','{}','',null);
  if (select workflow_state from public.exhibition_smartphone_works where id=smartphone1)<>'accepted' then raise exception 'Accepted遷移に失敗しました。'; end if;
  if exists(select 1 from public.exhibition_caption_working_data c where c.work_id=smartphone1)
     or exists(select 1 from public.exhibition_placements p where p.work_id=smartphone1)
     or exists(select 1 from public.exhibition_export_items i where i.work_id=smartphone1) then
    raise exception 'スマホ作品がCaption/Layout/Exportへ混入しました。';
  end if;

  -- Accepted re-edit request, permit and restore.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_1__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_smartphone_reedit_v1(smartphone1,'向きを再確認したい'); case_id:=(result->>'caseId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_smartphone_reedit_v1(case_id,true,'修正を許可',now()+interval '1 hour');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_1__@example.invalid','role','authenticated')::text,true);
  perform public.cancel_permitted_exhibition_smartphone_reedit_v1(case_id,'変更不要');
  if (select workflow_state from public.exhibition_smartphone_works where id=smartphone1)<>'accepted' then raise exception '再編集取消でAcceptedへ戻りません。'; end if;

  -- Per-entry maximum is independent of regular max_works.
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); smartphone2:=(result->>'id')::uuid;
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  begin perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
    raise exception 'スマホ枠上限を超えてDraftを作成できました。';
  exception when others then if sqlerrm='スマホ枠上限を超えてDraftを作成できました。' then raise; end if; end;

  -- Individual deadline processing is idempotent and audited exactly once.
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',
    event_id::text||'/'||member1::text||'/'||smartphone2::text||'/deadline.jpg',member1,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone2,'portrait',true,'none','',
    event_id::text||'/'||member1::text||'/'||smartphone2::text||'/deadline.jpg',repeat('c',64));
  result:=public.submit_exhibition_smartphone_work_v1(smartphone2,(terms->>'id')::uuid,terms->>'contentHash');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1((result->>'snapshotId')::uuid,'rejected',array['other'],'期限処理検証',null);
  update public.exhibition_smartphone_workflow_cases set individual_deadline=now()-interval '1 minute'
    where smartphone_work_id=smartphone2 and state='open';
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  if (select workflow_state from public.exhibition_smartphone_works where id=smartphone2)<>'withdrawn'
     or (select count(*) from public.exhibition_workflow_audit_logs a where a.entity_id=smartphone2
       and a.action='system_smartphone_case_deadline_withdrawn')<>1 then
    raise exception 'スマホ枠SYSTEM期限処理が冪等ではありません。';
  end if;

  -- RLS: another member cannot read member1 Smartphone Work or Snapshot.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_2__@example.invalid','role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.exhibition_smartphone_works sw where sw.id=v.smartphone1)
     or exists(select 1 from public.exhibition_smartphone_work_submission_snapshots s where s.id=v.snapshot1) then
    raise exception '一般部員が他人のスマホ作品履歴を閲覧できました。';
  end if;
  execute 'reset role';

  -- Before the Work deadline, a temporary zero-work state and every viable
  -- Regular/Smartphone combination keep the Entry active.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_2__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular_work:=(result->>'id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_3__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_4__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null);
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  if private.auto_cancel_v2_entry_if_no_viable(entry1,'case-c') then
    raise exception 'Case C: スマホ作品のみのEntryが取消されました。';
  end if;
  if private.auto_cancel_v2_entry_if_no_viable(entry2,'case-b') then raise exception 'Case B: 個人作品のみのEntryが取消されました。'; end if;
  if private.auto_cancel_v2_entry_if_no_viable(entry3,'case-c') then raise exception 'Case C: スマホDraftのみのEntryが取消されました。'; end if;
  if private.auto_cancel_v2_entry_if_no_viable(entry4,'case-d') then raise exception 'Case D: 両方あるEntryが取消されました。'; end if;
  -- Dedicated Case A entry with no viable work.
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where entry_id=entry3;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  if private.auto_cancel_v2_entry_if_no_viable(entry3,'case-a-before-deadline') then
    raise exception 'Case A: 締切前の作品なしEntryが自動取消されました。';
  end if;

  if not exists(select 1 from public.exhibition_workflow_audit_logs a where a.event_id=v.event_id and a.action='smartphone_accepted') then
    raise exception 'スマホ枠Auditが不足しています。'; end if;
end $$;

select to_regclass('public.exhibition_smartphone_works') is not null as smartphone_works_ready,
  to_regclass('public.exhibition_smartphone_work_submission_snapshots') is not null as smartphone_snapshots_ready,
  to_regprocedure('public.admin_review_exhibition_smartphone_work_v1(uuid,text,text[],text,timestamptz)') is not null as smartphone_review_ready;

rollback;
