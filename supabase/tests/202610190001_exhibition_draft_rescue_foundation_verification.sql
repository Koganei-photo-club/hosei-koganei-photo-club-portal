-- Draft rescue foundation Tasks 1-3 verification. All fixtures are rolled back.
begin;

do $$
<<v>>
declare
  operator_email constant text:='takayuki.fujiyoshi.2r@stu.hosei.ac.jp';
  inactive_operator_email constant text:='photo.club.at.koganei@gmail.com';
  other_admin_email constant text:='__draft_rescue_admin__@example.invalid';
  member1_email constant text:='__draft_rescue_member1__@example.invalid';
  member2_email constant text:='__draft_rescue_member2__@example.invalid';
  event_id uuid; other_event_id uuid; agreement_id uuid; agreement_hash text;
  member1 uuid; member2 uuid; entry1 uuid; entry2 uuid;
  regular1 uuid; regular2 uuid; regular3 uuid; regular4 uuid; regular5 uuid; regular6 uuid; regular_submitted uuid;
  smartphone1 uuid; campaign_id uuid; active_window uuid; expired_window uuid;
  regular_target uuid; expired_target uuid; proxy_target uuid; revoked_target uuid; mismatch_event_target uuid;
  mismatch_member_target uuid; submitted_target uuid; attempt_id uuid;
  smartphone_agreement_id uuid; smartphone_agreement_hash text; result jsonb; object_path text;
begin
  insert into public.admins(email,name,role_name,active)
  values(operator_email,'Draft救済指定管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.admins(email,name,role_name,active)
  values(inactive_operator_email,'Draft救済無効管理者','管理者',false)
  on conflict(email) do update set active=false;
  insert into public.admins(email,name,role_name,active)
  values(other_admin_email,'Draft救済対象外管理者','管理者',true)
  on conflict(email) do update set active=true;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  if not private.is_exhibition_draft_rescue_operator() then raise exception '指定管理者が許可されません。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',inactive_operator_email,'role','authenticated')::text,true);
  if private.is_exhibition_draft_rescue_operator() then raise exception 'inactiveな指定メールが許可されました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',other_admin_email,'role','authenticated')::text,true);
  if private.is_exhibition_draft_rescue_operator() then raise exception '指定外Adminが許可されました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',member1_email,'role','authenticated')::text,true);
  if private.is_exhibition_draft_rescue_operator() then raise exception '一般Memberが指定管理者と判定されました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true);
  if private.is_exhibition_draft_rescue_operator() then raise exception 'anonが指定管理者と判定されました。'; end if;
  if has_function_privilege('anon','private.is_exhibition_draft_rescue_operator()','execute')
     or has_function_privilege('authenticated','private.is_exhibition_draft_rescue_operator()','execute') then
    raise exception 'private operator helperが外部Roleへ公開されています。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values
    ('member-999801',member1_email,'救済検証部員1','B1',true),
    ('member-999802',member2_email,'救済検証部員2','B2',true);
  select id into member1 from public.members where email=member1_email;
  select id into member2 from public.members where email=member2_email;
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member1,private.current_fiscal_year(),true),(member2,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__draft_rescue__','Draft救済検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',operator_email,now()+interval '1 day',6,1,'[{"id":"rescue-slot","label":"検証枠"}]'::jsonb,operator_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','draft-rescue-application','Application規約','Draft救済検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  select id,content_hash into smartphone_agreement_id,smartphone_agreement_hash
  from public.exhibition_smartphone_agreement_definitions where active;

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,
    max_works,min_shift_people,shift_slots,updated_by)
  values('saved',false,'exhibition','__draft_rescue_other__','別写真展',now()+interval '10 days',now()+interval '11 days',
    '別会場',operator_email,now()+interval '1 day',3,1,'[{"id":"other","label":"別枠"}]'::jsonb,operator_email)
  returning id into other_event_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member1_email,'role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  entry1:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular1:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular_submitted:=(result->>'id')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member2_email,'role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,6,'real_name','','',agreement_id,agreement_hash);
  entry2:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular2:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular3:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular4:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular5:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular6:=(result->>'id')::uuid;
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); smartphone1:=(result->>'id')::uuid;

  insert into public.exhibition_draft_rescue_campaigns(event_id,state,ends_at,reason,created_by_identifier,created_at)
  values(event_id,'enabled',now()+interval '2 hours','検証用救済',operator_email,now()-interval '1 minute') returning id into campaign_id;
  insert into public.exhibition_draft_rescue_member_windows(campaign_id,event_id,member_id,deadline,state,reason,created_by_identifier)
  values(campaign_id,event_id,member1,now()+interval '1 hour','active','期限内検証',operator_email) returning id into active_window;
  insert into public.exhibition_draft_rescue_member_windows(campaign_id,event_id,member_id,deadline,state,reason,created_by_identifier,created_at)
  values(campaign_id,event_id,member2,now()-interval '1 hour','active','期限超過検証',operator_email,now()-interval '2 hours') returning id into expired_window;

  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier)
  values(campaign_id,active_window,event_id,member1,'regular_work',regular1,'member_resubmit','authorized','本人再登録',operator_email)
  returning id into regular_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier)
  values(campaign_id,expired_window,event_id,member2,'regular_work',regular2,'member_resubmit','authorized','期限超過',operator_email)
  returning id into expired_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,event_id,member_id,target_type,smartphone_work_id,
    rescue_mode,state,reason,member_intent_confirmed,member_confirmation_method,member_confirmed_at,
    confirmed_by_identifier,smartphone_agreement_definition_id,smartphone_agreement_content_hash,smartphone_agreed_at,created_by_identifier)
  values(campaign_id,event_id,member2,'smartphone_work',smartphone1,'admin_proxy_submit','authorized','代理提出',true,
    'direct',now(),operator_email,smartphone_agreement_id,smartphone_agreement_hash,now(),operator_email)
  returning id into proxy_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier,revoked_at)
  values(campaign_id,expired_window,event_id,member2,'regular_work',regular3,'member_resubmit','revoked','取消検証',operator_email,now())
  returning id into revoked_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier)
  values(campaign_id,expired_window,other_event_id,member2,'regular_work',regular4,'member_resubmit','authorized','Event不一致',operator_email)
  returning id into mismatch_event_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier)
  values(campaign_id,active_window,event_id,member1,'regular_work',regular6,'member_resubmit','authorized','Member不一致',operator_email)
  returning id into mismatch_member_target;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,rescue_mode,state,reason,created_by_identifier)
  values(campaign_id,active_window,event_id,member1,'regular_work',regular_submitted,'member_resubmit','authorized','Submitted検証',operator_email)
  returning id into submitted_target;

  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular1,'member_resubmit')).id is null then
    raise exception '期限内Member Targetが有効になりません。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular2,'member_resubmit')).id is not null then
    raise exception '期限超過Member Windowが有効になりました。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular3,'member_resubmit')).id is not null then
    raise exception '取消Targetが有効になりました。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular4,'member_resubmit')).id is not null then
    raise exception 'Event不一致Targetが有効になりました。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular6,'member_resubmit')).id is not null then
    raise exception 'Member不一致Targetが有効になりました。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',gen_random_uuid(),'member_resubmit')).id is not null then
    raise exception 'Work ID不一致Targetが有効になりました。';
  end if;
  if (private.get_effective_exhibition_draft_rescue_target('smartphone_work',smartphone1,'admin_proxy_submit')).id is null then
    raise exception 'Member期限超過がProxy Targetを妨げました。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member1_email,'role','authenticated')::text,true);
  if not private.current_member_can_use_draft_rescue('regular_work',regular1) then raise exception '所有MemberがTargetを利用できません。'; end if;
  if private.current_member_can_use_draft_rescue('smartphone_work',smartphone1) then raise exception 'MemberがProxy Targetを利用できました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',other_admin_email,'role','authenticated')::text,true);
  if private.current_operator_can_proxy_submit_draft('smartphone_work',smartphone1) then raise exception '指定外AdminがProxy操作可能です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  if not private.current_operator_can_proxy_submit_draft('smartphone_work',smartphone1) then raise exception '指定管理者がProxy操作できません。'; end if;
  if not private.exhibition_draft_rescue_protects_work('regular_work',regular1)
     or not private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone1) then
    raise exception '有効Targetが期限処理保護対象になりません。';
  end if;

  -- Work state changes invalidate an otherwise authorized Target.
  perform set_config('request.jwt.claims',jsonb_build_object('email',member1_email,'role','authenticated')::text,true);
  object_path:=event_id::text||'/'||member1::text||'/'||regular_submitted::text||'/draft-rescue-submitted.jpg';
  insert into storage.objects(bucket_id,name,metadata)
  values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,regular_submitted,'','portrait','A3','',297,420,true,
    object_path,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[regular_submitted]);
  if (private.get_effective_exhibition_draft_rescue_target('regular_work',regular_submitted,'member_resubmit')).id is not null then
    raise exception 'Submitted WorkのTargetが有効です。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);

  -- The exact Campaign deadline is closed for both modes, independent of persisted state.
  update public.exhibition_draft_rescue_campaigns set ends_at=now() where id=campaign_id;
  if private.exhibition_draft_rescue_protects_work('regular_work',regular1)
     or private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone1) then
    raise exception 'Campaign終了時刻にTargetが有効です。';
  end if;
  update public.exhibition_draft_rescue_campaigns set ends_at=now()+interval '2 hours' where id=campaign_id;

  -- Explicit disabling also closes both modes before the deadline.
  update public.exhibition_draft_rescue_campaigns
  set state='disabled',disabled_by_identifier=operator_email,disabled_at=now()
  where id=campaign_id;
  if private.exhibition_draft_rescue_protects_work('regular_work',regular1)
     or private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone1) then
    raise exception '無効化CampaignのTargetが有効です。';
  end if;
  update public.exhibition_draft_rescue_campaigns
  set state='enabled',disabled_by_identifier=null,disabled_at=null
  where id=campaign_id;

  begin
    insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
      regular_work_id,rescue_mode,state,reason,created_by_identifier)
    values(campaign_id,active_window,event_id,member1,'regular_work',regular1,'member_resubmit','authorized','重複',operator_email);
    raise exception '同一Workへ有効Targetを重複作成できました。';
  exception when others then if sqlerrm='同一Workへ有効Targetを重複作成できました。' then raise; end if; end;
  begin
    insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
      regular_work_id,smartphone_work_id,rescue_mode,state,reason,created_by_identifier)
    values(campaign_id,active_window,event_id,member1,'regular_work',regular2,smartphone1,'member_resubmit','failed','不正FK',operator_email);
    raise exception 'Work種別とFKの不一致を登録できました。';
  exception when others then if sqlerrm='Work種別とFKの不一致を登録できました。' then raise; end if; end;
  begin
    insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
      regular_work_id,rescue_mode,state,reason,member_intent_confirmed,member_confirmation_method,member_confirmed_at,confirmed_by_identifier,created_by_identifier)
    values(campaign_id,active_window,event_id,member1,'regular_work',regular2,'admin_proxy_submit','failed','不正Window',true,'direct',now(),operator_email,operator_email);
    raise exception 'Proxy TargetへMember Windowを設定できました。';
  exception when others then if sqlerrm='Proxy TargetへMember Windowを設定できました。' then raise; end if; end;
  begin
    insert into public.exhibition_draft_rescue_targets(campaign_id,event_id,member_id,target_type,
      regular_work_id,rescue_mode,state,reason,created_by_identifier)
    values(campaign_id,event_id,member1,'regular_work',regular2,'member_resubmit','failed','Windowなし',operator_email);
    raise exception 'Member TargetをWindowなしで登録できました。';
  exception when others then if sqlerrm='Member TargetをWindowなしで登録できました。' then raise; end if; end;

  insert into public.exhibition_draft_rescue_attempts(target_id,operator_identifier,operation_type,succeeded)
  values(regular_target,operator_email,'authorization',true) returning id into attempt_id;
  begin
    update public.exhibition_draft_rescue_attempts set safe_error_summary='改変' where id=attempt_id;
    raise exception 'Attempt履歴を更新できました。';
  exception when others then if sqlerrm='Attempt履歴を更新できました。' then raise; end if; end;

  if has_table_privilege('authenticated','public.exhibition_draft_rescue_targets','select')
     or has_table_privilege('authenticated','public.exhibition_draft_rescue_targets','insert')
     or has_table_privilege('anon','public.exhibition_draft_rescue_targets','select') then
    raise exception '救済テーブルが外部Roleへ公開されています。';
  end if;
end $$;

rollback;
