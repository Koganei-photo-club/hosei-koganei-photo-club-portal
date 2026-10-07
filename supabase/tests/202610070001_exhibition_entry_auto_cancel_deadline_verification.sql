-- Workflow v2 Entry auto-cancel deadline verification. All fixtures roll back.
begin;

do $$
<<verification>>
declare
  admin_email text;
  event_id uuid;
  agreement_id uuid;
  agreement_hash text;
  smartphone_terms jsonb;
  member_ids uuid[]:='{}';
  entry_ids uuid[]:='{}';
  member_id uuid;
  result jsonb;
  work_case1 uuid;
  work_case3 uuid;
  work_case6 uuid;
  work_case7 uuid;
  work_case9 uuid;
  phone_case2 uuid;
  phone_case5 uuid;
  phone_case8 uuid;
  phone_case10 uuid;
  snapshot_case7 uuid;
  snapshot_case8 uuid;
  snapshot_case9 uuid;
  object_path text;
  i integer;
begin
  select admin.email into admin_email
  from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception '自動取消検証にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  for i in 1..10 loop
    insert into public.members(member_no,email,name,grade,active)
    values(
      'member-'||(998100+i)::text,
      format('__entry_auto_cancel_%s__@example.invalid',i),
      format('自動取消検証%s',i),'B'||least(i,4)::text,true
    ) returning id into member_id;
    member_ids:=array_append(member_ids,member_id);
    insert into public.membership_years(member_id,fiscal_year,active)
    values(member_id,private.current_fiscal_year(),true);
  end loop;

  insert into public.events(
    status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by
  ) values(
    'saved',true,'exhibition','__entry_auto_cancel_deadline__','Entry自動取消期限検証展',
    now()+interval '10 days',now()+interval '11 days','検証会場',admin_email,
    now()+interval '1 day',3,1,'[{"id":"test","label":"検証枠"}]'::jsonb,admin_email
  ) returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(
    event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days',
    'entry-auto-cancel-deadline','Application規約','Entry自動取消期限検証'
  );
  update public.events
  set smartphone_exhibition_enabled=true,max_smartphone_works=3
  where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash
  from public.exhibition_agreement_definitions where id=agreement_id;
  smartphone_terms:=public.get_exhibition_smartphone_terms_v1();

  for i in 1..10 loop
    perform set_config(
      'request.jwt.claims',
      jsonb_build_object('email',format('__entry_auto_cancel_%s__@example.invalid',i),'role','authenticated')::text,
      true
    );
    result:=public.submit_exhibition_application_v2(
      event_id,case when i in (2,5,8,10) then 0 else 2 end,
      'real_name','','',agreement_id,agreement_hash
    );
    entry_ids:=array_append(entry_ids,(result->>'entryId')::uuid);
  end loop;

  -- CASE 1: submitted Regular 1 -> withdraw -> 0 before the global deadline.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_1__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Case 1','portrait','A3','',297,420,true,null,null);
  work_case1:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[1]::text||'/'||work_case1::text||'/case1.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,work_case1,'Case 1','portrait','A3','',297,420,true,object_path,repeat('1',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_case1]);
  perform public.withdraw_exhibition_work_v2(work_case1,'別作品へ入れ替えるため');
  if (select application_state from public.exhibition_entries where id=entry_ids[1])<>'active' then
    raise exception 'CASE 1: 締切前のRegular取下げでEntryが取消されました。';
  end if;

  -- CASE 2: submitted Smartphone 1 -> withdraw -> 0 before the deadline.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_2__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);
  phone_case2:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[2]::text||'/'||phone_case2::text||'/case2.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,member_ids[2],'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone_case2,'portrait',true,'none','',object_path,repeat('2',64));
  perform public.submit_exhibition_smartphone_work_v1(phone_case2,(smartphone_terms->>'id')::uuid,smartphone_terms->>'contentHash');
  perform public.withdraw_exhibition_smartphone_work_v1(phone_case2,'別作品へ入れ替えるため');
  if (select application_state from public.exhibition_entries where id=entry_ids[2])<>'active' then
    raise exception 'CASE 2: 締切前のSmartphone取下げでEntryが取消されました。';
  end if;

  -- CASE 3: the CASE 1 member can create and formally submit a replacement without revival.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_1__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Case 3','landscape','A3','',420,297,true,null,null);
  work_case3:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[1]::text||'/'||work_case3::text||'/case3.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,work_case3,'Case 3','landscape','A3','',420,297,true,object_path,repeat('3',64));
  result:=public.submit_exhibition_work_batch_v2(event_id,array[work_case3]);
  if jsonb_array_length(result->'submittedWorkIds')<>1 then
    raise exception 'CASE 3: Admin revivalなしで新Regular Workを提出できませんでした。';
  end if;

  -- Prepare viable post-deadline states for CASE 5-9.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_5__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);
  phone_case5:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[5]::text||'/'||phone_case5::text||'/case5.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,member_ids[5],'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone_case5,'portrait',true,'none','',object_path,repeat('5',64));
  perform public.submit_exhibition_smartphone_work_v1(phone_case5,(smartphone_terms->>'id')::uuid,smartphone_terms->>'contentHash');

  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_6__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Case 6','portrait','A3','',297,420,true,null,null);
  work_case6:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[6]::text||'/'||work_case6::text||'/case6.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,work_case6,'Case 6','portrait','A3','',297,420,true,object_path,repeat('6',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_case6]);

  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_7__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Case 7','portrait','A3','',297,420,true,null,null);
  work_case7:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[7]::text||'/'||work_case7::text||'/case7.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,work_case7,'Case 7','portrait','A3','',297,420,true,object_path,repeat('7',64));
  result:=public.submit_exhibition_work_batch_v2(event_id,array[work_case7]);
  select id into snapshot_case7 from public.exhibition_work_submission_snapshots
  where work_id=work_case7 order by version_no desc limit 1;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_8__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'none','',null,null);
  phone_case8:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[8]::text||'/'||phone_case8::text||'/case8.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,member_ids[8],'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone_case8,'landscape',true,'none','',object_path,repeat('8',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone_case8,(smartphone_terms->>'id')::uuid,smartphone_terms->>'contentHash');
  snapshot_case8:=(result->>'snapshotId')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_9__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Case 9','portrait','A3','',297,420,true,null,null);
  work_case9:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_ids[9]::text||'/'||work_case9::text||'/case9.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}'::jsonb);
  perform public.save_exhibition_work_draft_v2(event_id,work_case9,'Case 9','portrait','A3','',297,420,true,object_path,repeat('9',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_case9]);
  select id into snapshot_case9 from public.exhibition_work_submission_snapshots
  where work_id=work_case9 order by version_no desc limit 1;

  -- Close all global deadlines while preserving their strict order.
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set
    exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',
    exhibition_revision_deadline=now()-interval '2 hours',
    exhibition_caption_deadline=now()-interval '1 hour'
  where id=event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  -- CASE 7/8: post-deadline correction rights keep rejected works viable.
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(
    snapshot_case7,'rejected',array['orientation'],'修正してください',now()+interval '1 hour'
  );
  perform public.admin_review_exhibition_smartphone_work_v1(
    snapshot_case8,'rejected',array['orientation'],'修正してください',now()+interval '1 hour'
  );
  perform public.admin_review_exhibition_work_v2(snapshot_case9,'accepted','{}'::text[],'',null);

  -- CASE 4-9: lifecycle processing uses both viability helpers.
  perform public.admin_process_exhibition_work_deadlines_v2(event_id);
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  if (select application_state from public.exhibition_entries where id=entry_ids[4])<>'auto_cancelled' then
    raise exception 'CASE 4: 締切後・viable 0のEntryが自動取消されません。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry_ids[5])<>'active' then
    raise exception 'CASE 5: Smartphone-only viable Entryが取消されました。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry_ids[6])<>'active' then
    raise exception 'CASE 6: Regular-only viable Entryが取消されました。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry_ids[7])<>'active' then
    raise exception 'CASE 7: Regular correction期限内のEntryが取消されました。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry_ids[8])<>'active' then
    raise exception 'CASE 8: Smartphone correction期限内のEntryが取消されました。';
  end if;
  if (select application_state from public.exhibition_entries where id=entry_ids[9])<>'active' then
    raise exception 'CASE 9: accepted Regularを持つEntryが取消されました。';
  end if;

  -- CASE 10: an active revival window protects the temporary zero-work state.
  if (select application_state from public.exhibition_entries where id=entry_ids[10])<>'auto_cancelled' then
    raise exception 'CASE 10: revival前提のauto-cancelに失敗しました。';
  end if;
  perform public.admin_revive_exhibition_entry_v2(entry_ids[10],'スマホ再提出機会',now()+interval '1 hour');
  if private.auto_cancel_v2_entry_if_no_viable(entry_ids[10],'case-10-revival-window') then
    raise exception 'CASE 10: revival期限内のEntryが再度取消されました。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__entry_auto_cancel_10__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  phone_case10:=(result->>'id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_process_exhibition_work_deadlines_v2(event_id);
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  if (select application_state from public.exhibition_entries where id=entry_ids[10])<>'active'
     or (select workflow_state from public.exhibition_smartphone_works where id=phone_case10)<>'draft' then
    raise exception 'CASE 10: Smartphone revival_deadline経路が後退しました。';
  end if;
end $$;

rollback;
