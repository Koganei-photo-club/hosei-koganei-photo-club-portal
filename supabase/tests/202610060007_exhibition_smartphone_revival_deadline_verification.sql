-- Smartphone admin-revival deadline verification. All fixtures are rolled back.
begin;

do $$
<<v>>
declare
  admin_email text; event_id uuid; agreement_id uuid; agreement_hash text; terms jsonb; result jsonb;
  member1 uuid; member2 uuid; member3 uuid; member4 uuid; member5 uuid;
  entry1 uuid; entry2 uuid; entry3 uuid; entry4 uuid; entry5 uuid;
  smartphone1 uuid; smartphone3 uuid; smartphone4 uuid; smartphone5 uuid; snapshot4 uuid; reset_preview jsonb;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'revival検証にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active) values
    ('member-999091','__smartphone_revival_1__@example.invalid','復活部員1','B1',true),
    ('member-999092','__smartphone_revival_2__@example.invalid','復活部員2','B2',true),
    ('member-999093','__smartphone_revival_3__@example.invalid','復活部員3','B3',true),
    ('member-999094','__smartphone_revival_4__@example.invalid','復活部員4','B4',true),
    ('member-999095','__smartphone_revival_5__@example.invalid','復活部員5','M1',true);
  select id into member1 from public.members where email='__smartphone_revival_1__@example.invalid';
  select id into member2 from public.members where email='__smartphone_revival_2__@example.invalid';
  select id into member3 from public.members where email='__smartphone_revival_3__@example.invalid';
  select id into member4 from public.members where email='__smartphone_revival_4__@example.invalid';
  select id into member5 from public.members where email='__smartphone_revival_5__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member1,private.current_fiscal_year(),true),(member2,private.current_fiscal_year(),true),
    (member3,private.current_fiscal_year(),true),(member4,private.current_fiscal_year(),true),
    (member5,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__smartphone_revival__','スマホ復活期限検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"revival-slot","label":"検証枠"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','smartphone-revival-application','Application規約','スマホ復活期限検証');
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=2 where id=event_id;
  terms:=public.get_exhibition_smartphone_terms_v1();

  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_1__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry1:=(result->>'entryId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_2__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry2:=(result->>'entryId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_3__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry3:=(result->>'entryId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_4__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry4:=(result->>'entryId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_5__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash); entry5:=(result->>'entryId')::uuid;

  -- Prepare an accepted Smartphone Work and a withdrawn Smartphone Work before closing the Event deadline.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_4__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null); smartphone4:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',event_id::text||'/'||member4::text||'/'||smartphone4::text||'/accepted.jpg',member4,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone4,'portrait',true,'none','',event_id::text||'/'||member4::text||'/'||smartphone4::text||'/accepted.jpg',repeat('d',64));
  result:=public.submit_exhibition_smartphone_work_v1(smartphone4,(terms->>'id')::uuid,terms->>'contentHash'); snapshot4:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(snapshot4,'accepted','{}','',null);

  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_5__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); smartphone5:=(result->>'id')::uuid;
  perform public.withdraw_exhibition_smartphone_work_v1(smartphone5,'検証用取下げ');

  -- Close the Event deadline without changing Production semantics; verification owns this fixture.
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',exhibition_revision_deadline=now()-interval '2 hours',
    exhibition_caption_deadline=now()-interval '1 hour' where id=event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  if not private.auto_cancel_v2_entry_if_no_viable(entry1,'revival-basic')
     or not private.auto_cancel_v2_entry_if_no_viable(entry3,'revival-expiry') then
    raise exception '作品なしEntryの事前auto-cancelに失敗しました。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry5)<>'auto_cancelled' then
    raise exception 'Withdrawn作品だけのEntryが取下げ時にauto-cancelされませんでした。';
  end if;
  perform public.admin_revive_exhibition_entry_v2(entry1,'スマホ枠提出機会を付与',now()+interval '1 hour');
  perform public.admin_revive_exhibition_entry_v2(entry3,'期限切れ検証',now()+interval '1 hour');
  perform public.admin_revive_exhibition_entry_v2(entry5,'withdrawn検証',now()+interval '1 hour');

  -- A/B: Smartphone-only, planned_work_count=0: create, save and formally submit in the revival window.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_1__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); smartphone1:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',event_id::text||'/'||member1::text||'/'||smartphone1::text||'/revived.jpg',member1,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone1,'landscape',true,'declared','背景の一部を生成',
    event_id::text||'/'||member1::text||'/'||smartphone1::text||'/revived.jpg',repeat('a',64));
  result:=public.submit_exhibition_smartphone_work_v1(smartphone1,(terms->>'id')::uuid,terms->>'contentHash');
  if result->>'state'<>'submitted' then raise exception 'Revival中のFormal Submitに失敗しました。'; end if;

  -- C: another active Entry receives no exception from member1's revival.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_2__@example.invalid','role','authenticated')::text,true);
  begin
    perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
    raise exception '他Memberへrevival例外が漏れました。';
  exception when others then if sqlerrm='他Memberへrevival例外が漏れました。' then raise; end if; end;

  -- D/E: exact/expired boundary rejects create, save and submit, then processor withdraws and re-cancels.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_3__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); smartphone3:=(result->>'id')::uuid;
  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries set revival_deadline=now() where id=entry3;
  perform set_config('app.exhibition_application_rpc','off',true);
  begin perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); raise exception '期限到達後に新規作成できました。';
  exception when others then if sqlerrm='期限到達後に新規作成できました。' then raise; end if; end;
  begin perform public.save_exhibition_smartphone_work_draft_v1(event_id,smartphone3,'portrait',true,'none','',null,null); raise exception '期限到達後にDraft保存できました。';
  exception when others then if sqlerrm='期限到達後にDraft保存できました。' then raise; end if; end;
  begin perform public.submit_exhibition_smartphone_work_v1(smartphone3,(terms->>'id')::uuid,terms->>'contentHash'); raise exception '期限到達後に正式提出できました。';
  exception when others then if sqlerrm='期限到達後に正式提出できました。' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  if (select workflow_state from public.exhibition_smartphone_works where id=smartphone3)<>'withdrawn'
     or (select application_state from public.exhibition_entries where id=entry3)<>'auto_cancelled' then
    raise exception 'Revival期限後のwithdraw/再auto-cancelに失敗しました。';
  end if;

  -- G/H: accepted stays viable; withdrawn never revives or becomes viable.
  if not private.exhibition_smartphone_work_is_viable(smartphone4) then raise exception 'Acceptedスマホ作品がviableではありません。'; end if;
  if private.auto_cancel_v2_entry_if_no_viable(entry4,'accepted-check') then raise exception 'Acceptedスマホ作品があるEntryを取消しました。'; end if;
  if private.exhibition_smartphone_work_is_viable(smartphone5) then raise exception 'Withdrawnスマホ作品がviableになりました。'; end if;

  -- K/L/M: agreement, AI declaration and per-entry maximum remain enforced by the unchanged submit/save RPC contract.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__smartphone_revival_1__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  begin perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null); raise exception 'Revivalでスマホ作品上限を超過できました。';
  exception when others then if sqlerrm='Revivalでスマホ作品上限を超過できました。' then raise; end if; end;
  begin perform public.submit_exhibition_smartphone_work_v1((result->>'id')::uuid,gen_random_uuid(),repeat('0',64)); raise exception 'RevivalでAgreementを迂回できました。';
  exception when others then if sqlerrm='RevivalでAgreementを迂回できました。' then raise; end if; end;

  -- O: reset preview includes Smartphone data created after revival.
  insert into public.maintenance_admins(email,name,role_name,active) values(admin_email,'検証管理者','検証',true) on conflict(email) do update set active=true;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  reset_preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member1);
  if coalesce((reset_preview#>>'{counts,smartphoneWorks}')::integer,0)<1 then raise exception 'Maintenance Reset Previewがrevival後のスマホ作品を認識しません。'; end if;
end $$;

select to_regprocedure('private.exhibition_smartphone_edit_deadline_open(public.exhibition_smartphone_works,public.events)') is not null as revival_helper_ready,
  to_regprocedure('public.save_exhibition_smartphone_work_draft_v1(uuid,uuid,text,boolean,text,text,text,text)') is not null as revival_create_ready,
  to_regprocedure('public.admin_process_exhibition_smartphone_deadlines_v1(uuid)') is not null as revival_processor_ready;

rollback;
