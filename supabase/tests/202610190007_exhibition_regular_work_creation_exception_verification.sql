-- One-off regular Work creation exception verification. All fixtures roll back.
begin;

do $$
<<v>>
declare
  admin_email constant text:='takayuki.fujiyoshi.2r@stu.hosei.ac.jp';
  member_email constant text:='__creation_exception_member__@example.invalid';
  other_email constant text:='__creation_exception_other__@example.invalid';
  member_id uuid; other_member_id uuid; event_id uuid; agreement_id uuid; agreement_hash text;
  v_entry_id uuid; v_exception_id uuid; existing_work uuid; first_work uuid; second_work uuid; result jsonb; path text;
begin
  insert into public.admins(email,name,role_name,active) values(admin_email,'特例検証管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.members(member_no,email,name,grade,active)
  values('member-998701',member_email,'特例対象','B2',true) returning id into member_id;
  insert into public.members(member_no,email,name,grade,active)
  values('member-998702',other_email,'特例対象外','B2',true) returning id into other_member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.membership_years(member_id,fiscal_year,active) values(other_member_id,private.current_fiscal_year(),true);

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__regular_creation_exception__','個人枠追加特例検証',now()+interval '10 days',
    now()+interval '11 days','検証会場',admin_email,now()+interval '1 day',3,1,
    '[{"id":"exception","label":"特例検証枠"}]'::jsonb,admin_email) returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','creation-exception','Application規約','個人枠追加特例検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,3,'real_name','','',agreement_id,agreement_hash);
  v_entry_id:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','portrait','A3','',297,420,true,null,null);
  existing_work:=(result->>'id')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email',other_email,'role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);

  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',exhibition_revision_deadline=now()+interval '2 hours',
    exhibition_caption_deadline=now()+interval '3 hours' where id=event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  insert into public.exhibition_regular_work_creation_exceptions(
    event_id,member_id,max_new_works,expires_at,state,reason,created_by_identifier
  ) values(event_id,member_id,2,now()+interval '2 hours','active','verification',admin_email)
  returning id into v_exception_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',other_email,'role','authenticated')::text,true);
  begin
    perform public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null);
    raise exception '対象外部員が期限後に新規Workを作成できました。';
  exception when others then
    if sqlerrm='対象外部員が期限後に新規Workを作成できました。' then raise; end if;
  end;
  begin
    perform public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
    raise exception '個人枠特例がスマホ枠へ適用されました。';
  exception when others then
    if sqlerrm='個人枠特例がスマホ枠へ適用されました。' then raise; end if;
  end;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','portrait','A3','',297,420,true,null,null);
  first_work:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','landscape','A3','',420,297,false,null,null);
  second_work:=(result->>'id')::uuid;
  if (select count(*) from public.exhibition_regular_work_creation_exception_works usage_row where usage_row.exception_id=v_exception_id)<>2 then
    raise exception '特例作成数が2件として記録されません。';
  end if;
  begin
    perform public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null);
    raise exception '特例上限を超えて新規Workを作成できました。';
  exception when others then
    if sqlerrm='特例上限を超えて新規Workを作成できました。' then raise; end if;
  end;

  -- Deadline processing must keep both exception Works while the exception is active.
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_process_exhibition_work_deadlines_v2(event_id);
  if exists(select 1 from public.exhibition_works where id=any(array[first_work,second_work]) and workflow_state<>'draft') then
    raise exception '有効な追加特例Workが期限処理で変更されました。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  path:=event_id||'/'||member_id||'/'||first_work||'/exception.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,first_work,'','portrait','A3','',297,420,true,path,repeat('a',64));
  result:=public.submit_exhibition_work_batch_v2(event_id,array[first_work]);
  if (select workflow_state from public.exhibition_works where id=first_work)<>'submitted'
     or (select current_submission_snapshot_id from public.exhibition_works where id=first_work) is null then
    raise exception '特例Workを通常のSnapshot経路で正式提出できません。';
  end if;

  perform public.withdraw_exhibition_work_v2(second_work,'特例枠消費確認');
  begin
    perform public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null);
    raise exception '取り下げ後に消費済み特例枠が復活しました。';
  exception when others then
    if sqlerrm='取り下げ後に消費済み特例枠が復活しました。' then raise; end if;
  end;

  update public.exhibition_regular_work_creation_exceptions set expires_at=now()-interval '1 minute'
  where id=v_exception_id;
  begin
    perform public.save_exhibition_work_draft_v2(event_id,second_work,'','portrait','A3','',297,420,true,null,null);
    raise exception '期限切れ後に特例Workを編集できました。';
  exception when others then
    if sqlerrm='期限切れ後に特例Workを編集できました。' then raise; end if;
  end;

  if (select count(*) from public.exhibition_works work_row where work_row.entry_id=v_entry_id)<>3 then
    raise exception '既存1件と特例2件の合計が3件ではありません。';
  end if;
end;
$$;

rollback;

