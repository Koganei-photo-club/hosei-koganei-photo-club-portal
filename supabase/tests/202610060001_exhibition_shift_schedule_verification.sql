-- 出展から独立したShift Workflowと、Event募集公開境界を検証する。全データはROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text; event_id uuid; draft_event_id uuid; saved_event_id uuid;
  meeting_draft_id uuid; meeting_saved_id uuid; meeting_public_id uuid;
  shift_only_id uuid; exhibitor_id uuid; inactive_id uuid; agreement_id uuid; agreement_hash text;
  saved_agreement_id uuid; saved_agreement_hash text; version1 uuid; version2 uuid; result jsonb;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'シフト検証にはactive Adminが必要です。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values
    ('member-999061','__shift_only__@example.invalid','シフトのみ部員','B2',true),
    ('member-999062','__shift_exhibitor__@example.invalid','出展部員','B3',true),
    ('member-999063','__shift_inactive__@example.invalid','年度未登録部員','B1',true);
  select member.id into shift_only_id from public.members member where member.email='__shift_only__@example.invalid';
  select member.id into exhibitor_id from public.members member where member.email='__shift_exhibitor__@example.invalid';
  select member.id into inactive_id from public.members member where member.email='__shift_inactive__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (shift_only_id,private.current_fiscal_year(),true),(exhibitor_id,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__shift_schedule_verification__','シフト検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,2,
    '[{"id":"day1-1000","label":"11月1日 10:00〜11:00"},{"id":"day1-1100","label":"11月1日 11:00〜12:00"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','shift-verification-agreement','Shift Verification Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.event_id and agreement.active;

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__draft_exhibition__','Draft検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"draft-slot","label":"Draft slot"}]'::jsonb,admin_email)
  returning id into draft_event_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',false,'exhibition','__saved_unpublished_exhibition__','Saved未公開検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"saved-slot","label":"Saved slot"}]'::jsonb,admin_email)
  returning id into saved_event_id;
  perform public.admin_activate_exhibition_workflow_v2(saved_event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','saved-verification-agreement','Saved Verification Agreement','検証');
  select agreement.id,agreement.content_hash into saved_agreement_id,saved_agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.saved_event_id and agreement.active;

  insert into public.events(status,published,genre,subtype,title,starts_at,ends_at,place,contact,registration_deadline,updated_by)
  values('draft',false,'meeting','shooting','__draft_meeting__',now()+interval '10 days',now()+interval '10 days 2 hours','検証会場',admin_email,now()+interval '1 day',admin_email)
  returning id into meeting_draft_id;
  insert into public.events(status,published,genre,subtype,title,starts_at,ends_at,place,contact,registration_deadline,updated_by)
  values('saved',false,'meeting','shooting','__saved_meeting__',now()+interval '10 days',now()+interval '10 days 2 hours','検証会場',admin_email,now()+interval '1 day',admin_email)
  returning id into meeting_saved_id;
  insert into public.events(status,published,genre,subtype,title,starts_at,ends_at,place,contact,registration_deadline,updated_by)
  values('saved',true,'meeting','shooting','__published_meeting__',now()+interval '10 days',now()+interval '10 days 2 hours','検証会場',admin_email,now()+interval '1 day',admin_email)
  returning id into meeting_public_id;

  -- Draft/Saved未公開は、URL/RPCを直接使用しても新規参加できない。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_only__@example.invalid','role','authenticated')::text,true);
  begin perform public.submit_exhibition_application_v2(draft_event_id,1,'real_name','','',saved_agreement_id,saved_agreement_hash);raise exception 'Draft写真展へApplicationを作成できました。';
  exception when others then if sqlerrm='Draft写真展へApplicationを作成できました。' then raise;end if;end;
  begin perform public.submit_exhibition_application_v2(saved_event_id,1,'real_name','','',saved_agreement_id,saved_agreement_hash);raise exception 'Saved未公開写真展へApplicationを作成できました。';
  exception when others then if sqlerrm='Saved未公開写真展へApplicationを作成できました。' then raise;end if;end;
  begin perform public.save_my_exhibition_shift_preferences_v1(draft_event_id,'[]'::jsonb);raise exception 'Draft写真展へシフト希望を保存できました。';
  exception when others then if sqlerrm='Draft写真展へシフト希望を保存できました。' then raise;end if;end;
  begin perform public.save_my_exhibition_shift_preferences_v1(saved_event_id,'[]'::jsonb);raise exception 'Saved未公開写真展へシフト希望を保存できました。';
  exception when others then if sqlerrm='Saved未公開写真展へシフト希望を保存できました。' then raise;end if;end;

  -- 共通Event RLSでもDraft/Saved未公開は隠れ、Published一般イベントだけが見える。
  execute 'set local role authenticated';
  if exists(select 1 from public.events event where event.id in(v.draft_event_id,v.saved_event_id,v.meeting_draft_id,v.meeting_saved_id))
    or not exists(select 1 from public.events event where event.id=v.meeting_public_id)
    then raise exception 'EventのDraft/Saved/Published RLS境界が不正です。'; end if;
  execute 'reset role';

  -- 正式なv2 Applicationを作成した部員と、Applicationなし部員の双方が希望を提出できる。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_exhibitor__@example.invalid','role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  perform public.save_my_exhibition_shift_preferences_v1(event_id,'[{"slotId":"day1-1100","preference":"available","note":""}]'::jsonb);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_only__@example.invalid','role','authenticated')::text,true);
  perform public.save_my_exhibition_shift_preferences_v1(event_id,'[{"slotId":"day1-1000","preference":"preferred","note":""}]'::jsonb);
  if exists(select 1 from public.exhibition_entries entry where entry.event_id=v.event_id and entry.member_id=v.shift_only_id)
    then raise exception 'シフト希望だけでApplicationが作成されました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_exhibitor__@example.invalid','role','authenticated')::text,true);
  perform public.withdraw_exhibition_application_v2(event_id,'検証取消');
  if not exists(select 1 from public.exhibition_shift_preferences preference where preference.event_id=v.event_id and preference.member_id=v.exhibitor_id)
    then raise exception 'Application取消によりシフト希望が削除されました。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_inactive__@example.invalid','role','authenticated')::text,true);
  begin perform public.save_my_exhibition_shift_preferences_v1(event_id,'[]'::jsonb);raise exception '年度会員でない部員がシフト希望を提出できました。';
  exception when others then if sqlerrm='年度会員でない部員がシフト希望を提出できました。' then raise;end if;end;

  -- Draft→Saved。人数不足は理由なしでは公開できず、理由付きならAuditと共にPublishedになる。
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_shift_schedule_draft_v1(event_id);version1:=(result->>'versionId')::uuid;
  perform public.admin_set_exhibition_shift_assignment_v1(version1,'day1-1000',shift_only_id,true);
  perform public.admin_set_exhibition_shift_assignment_v1(version1,'day1-1100',exhibitor_id,true);
  perform public.admin_save_exhibition_shift_schedule_v1(version1);
  begin perform public.admin_publish_exhibition_shift_schedule_v1(version1,'');raise exception '人数不足のシフト版を理由なしで公開できました。';
  exception when others then if sqlerrm='人数不足のシフト版を理由なしで公開できました。' then raise;end if;end;
  perform public.admin_publish_exhibition_shift_schedule_v1(version1,'当日運営で補完するため');
  if (select event.current_exhibition_shift_schedule_version_id from public.events event where event.id=v.event_id)<>version1
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id
      and audit.action='shift_schedule_published_with_shortage' and audit.reason='当日運営で補完するため')
    then raise exception '理由付き公開またはAuditが不正です。'; end if;

  -- 希望変更は公開割当を変えず、公開後の編集はv2 Draft。Memberにはcurrent Publishedだけを見せる。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_only__@example.invalid','role','authenticated')::text,true);
  perform public.save_my_exhibition_shift_preferences_v1(event_id,'[]'::jsonb);
  result:=public.get_my_exhibition_shift_workspace_v1(event_id);
  if result#>>'{publishedVersion,id}' is distinct from version1::text
    or not exists(select 1 from jsonb_array_elements(result->'assignments') assignment where (assignment->>'memberId')::uuid=shift_only_id)
    then raise exception '希望変更により公開割当が変化しました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_shift_schedule_draft_v1(event_id);version2:=(result->>'versionId')::uuid;
  if version2=version1 or (result->>'versionNo')::integer<>2 then raise exception '公開後の編集が次版Draftになりません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_only__@example.invalid','role','authenticated')::text,true);
  execute 'set local role authenticated';
  if (select count(*) from public.exhibition_shift_schedule_versions version where version.event_id=v.event_id)<>1
    or exists(select 1 from public.exhibition_shift_schedule_versions version where version.id=v.version2)
    or exists(select 1 from public.exhibition_shift_schedule_assignments assignment where assignment.schedule_version_id=v.version2)
    then raise exception '部員に管理中Draftまたは割当が公開されています。'; end if;
  execute 'reset role';

  -- 募集締切後も既存関係は確認できるが、新規参加操作は拒否する。
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set registration_deadline=now()-interval '5 hours',exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',exhibition_revision_deadline=now()-interval '2 hours',
    exhibition_caption_deadline=now()-interval '1 hour' where id=event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_only__@example.invalid','role','authenticated')::text,true);
  if not exists(select 1 from jsonb_array_elements(public.get_my_exhibition_hub_v1()) item where (item->>'eventId')::uuid=event_id)
    or (public.get_my_exhibition_shift_workspace_v1(event_id)->>'canSubmitPreferences')::boolean
    or (public.get_my_exhibition_event_v1(event_id)->>'id')::uuid<>event_id
    then raise exception '募集終了後の既存参加内容確認が不正です。'; end if;
  begin perform public.save_my_exhibition_shift_preferences_v1(event_id,'[]'::jsonb);raise exception '募集終了後にシフト希望を新規保存できました。';
  exception when others then if sqlerrm='募集終了後にシフト希望を新規保存できました。' then raise;end if;end;
  begin perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);raise exception '募集終了後にApplicationを作成できました。';
  exception when others then if sqlerrm='募集終了後にApplicationを作成できました。' then raise;end if;end;
end $$;

select
  to_regprocedure('public.save_my_exhibition_shift_preferences_v1(uuid,jsonb)') is not null as member_shift_rpc_ready,
  to_regprocedure('public.admin_publish_exhibition_shift_schedule_v1(uuid,text)') is not null as publish_rpc_ready,
  to_regprocedure('public.get_my_exhibition_event_v1(uuid)') is not null as existing_participant_event_rpc_ready,
  to_regclass('public.exhibition_shift_schedule_versions') is not null as schedule_versions_ready;

rollback;
