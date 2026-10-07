-- Workflow v2 title timing verification. All fixtures roll back.
begin;

do $$
<<verification>>
declare
  admin_email text; member_id uuid; event_id uuid; agreement_id uuid; agreement_hash text;
  result jsonb; work_id uuid; work_snapshot_id uuid; caption_snapshot_id uuid;
  inherited_work_id uuid; inherited_work_snapshot_id uuid; object_path text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'タイトル移行検証にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active)
  values('member-999402','__caption_title__@example.invalid','タイトル検証部員','B3',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__caption_title__','タイトル移行検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"検証枠"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','caption-title','Application規約','タイトル移行検証');
  select definition.id,definition.content_hash into agreement_id,agreement_hash
  from public.exhibition_agreement_definitions definition where definition.event_id=verification.event_id and definition.active;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__caption_title__@example.invalid','role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,2,'real_name','','',agreement_id,agreement_hash);

  -- CASE 1-3: an empty title is valid through Work draft, submission and immutable Work Snapshot.
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','portrait','A3','',297,420,true,null,null);
  work_id:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_id::text||'/'||work_id::text||'/untitled.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,member_id,'{}');
  perform public.save_exhibition_work_draft_v2(event_id,work_id,'','portrait','A3','',297,420,true,object_path,repeat('1',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[work_id]);
  select work.current_submission_snapshot_id into work_snapshot_id from public.exhibition_works work where work.id=work_id;
  if (select snapshot.title from public.exhibition_work_submission_snapshots snapshot where snapshot.id=work_snapshot_id)<>'' then
    raise exception 'CASE 1-3: titleなしWork Snapshotが作成されません。';
  end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(work_snapshot_id,'accepted','{}','',null);

  -- CASE 4-6: title lives in Caption, is required at submit, and is snapshotted.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__caption_title__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(work_id,'作者','self','Untitled','digital','','Camera','','',
    'unnecessary','','','none','',null,'none','','');
  begin
    perform public.submit_exhibition_caption_v2(work_id);
    raise exception 'CASE 5: titleなしCaptionを提出できました。';
  exception when others then
    if sqlerrm='CASE 5: titleなしCaptionを提出できました。' then raise; end if;
  end;
  perform public.save_exhibition_caption_draft_v2(work_id,'作者','self','A New Title','digital','','Camera','','',
    'unnecessary','','','none','',null,'none','','Captionで決めた作品タイトル');
  result:=public.submit_exhibition_caption_v2(work_id); caption_snapshot_id:=(result->>'snapshotId')::uuid;
  if (select snapshot.title from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=caption_snapshot_id)<>'Captionで決めた作品タイトル' then
    raise exception 'CASE 6: Caption Snapshotに作品タイトルが固定されません。';
  end if;

  -- CASE 7: title is a Caption review field, not a new Work review field.
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(caption_snapshot_id,'rejected',array['title'],'作品タイトルを修正してください',null);
  begin
    perform public.admin_review_exhibition_work_v2(work_snapshot_id,'rejected',array['title'],'不正な旧経路',null);
    raise exception 'CASE 7: Work Reviewでtitleを新規指定できました。';
  exception when others then
    if sqlerrm='CASE 7: Work Reviewでtitleを新規指定できました。' then raise; end if;
  end;

  -- CASE 8/14: pre-existing Work titles initialize Caption without mutating Work or its Snapshot.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__caption_title__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'既存作品タイトル','landscape','A3','',420,297,true,null,null);
  inherited_work_id:=(result->>'id')::uuid;
  object_path:=event_id::text||'/'||member_id::text||'/'||inherited_work_id::text||'/existing.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,member_id,'{}');
  perform public.save_exhibition_work_draft_v2(event_id,inherited_work_id,'既存作品タイトル','landscape','A3','',420,297,true,object_path,repeat('2',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[inherited_work_id]);
  select work.current_submission_snapshot_id into inherited_work_snapshot_id from public.exhibition_works work where work.id=inherited_work_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(inherited_work_snapshot_id,'accepted','{}','',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__caption_title__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(inherited_work_id,'作者','organizer','','digital','','Camera','','',
    'unnecessary','','','none','',null,'none','');
  if (select caption.title from public.exhibition_caption_working_data caption where caption.work_id=inherited_work_id)<>'既存作品タイトル'
     or (select work.title from public.exhibition_works work where work.id=inherited_work_id)<>'既存作品タイトル'
     or (select snapshot.title from public.exhibition_work_submission_snapshots snapshot where snapshot.id=inherited_work_snapshot_id)<>'既存作品タイトル' then
    raise exception 'CASE 8/14: 既存タイトルの引継ぎまたは履歴保全に失敗しました。';
  end if;

  -- CASE 11-13: regular-work changes do not alter smartphone contracts.
  if not exists(select 1 from pg_proc where proname='submit_exhibition_smartphone_work_v1')
     or not exists(select 1 from public.exhibition_smartphone_agreement_definitions definition where definition.active) then
    raise exception 'CASE 11-13: Smartphone Workflowが後退しました。';
  end if;
end $$;

rollback;
