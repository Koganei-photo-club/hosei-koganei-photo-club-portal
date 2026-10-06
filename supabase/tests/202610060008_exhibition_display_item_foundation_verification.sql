-- Display Item / Smartphone Group foundation verification. Rolled back in full.
begin;

do $$
<<v>>
declare
  admin_email text; event_id uuid; empty_event_id uuid; agreement_id uuid; agreement_hash text; terms jsonb; result jsonb;
  member1 uuid; member2 uuid; member3 uuid; member4 uuid; entry_id uuid;
  phone1 uuid; phone2 uuid; phone3 uuid; phone4 uuid; snap1 uuid; snap2 uuid; snap3 uuid;
  group_id uuid; display_item_id uuid; version1 uuid; version2 uuid; preview jsonb; regular_work uuid;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'Display Item検証にはactive Adminが必要です。';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  -- Migration backfill covers every pre-existing Regular Work.
  if exists(select 1 from public.exhibition_works work_row left join public.exhibition_display_items item_row
    on item_row.regular_work_id=work_row.id and item_row.item_type='regular_work' where item_row.id is null) then
    raise exception '既存Regular WorkのDisplay Item backfillが不足しています。';
  end if;

  insert into public.members(member_no,email,name,grade,active) values
    ('member-999101','__display_item_1__@example.invalid','表示部員1','B1',true),
    ('member-999102','__display_item_2__@example.invalid','表示部員2','B2',true),
    ('member-999103','__display_item_3__@example.invalid','表示部員3','B3',true),
    ('member-999104','__display_item_4__@example.invalid','表示部員4','B4',true);
  select id into member1 from public.members where email='__display_item_1__@example.invalid';
  select id into member2 from public.members where email='__display_item_2__@example.invalid';
  select id into member3 from public.members where email='__display_item_3__@example.invalid';
  select id into member4 from public.members where email='__display_item_4__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member1,private.current_fiscal_year(),true),(member2,private.current_fiscal_year(),true),
    (member3,private.current_fiscal_year(),true),(member4,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__display_item_foundation__','Display Item検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"display-slot","label":"検証枠"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','display-item-application','Application規約','Display Item検証');
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  terms:=public.get_exhibition_smartphone_terms_v1();

  -- Admin creates one Event-scoped Group and exactly one common Display Item.
  result:=public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',1200,800);
  group_id:=(result#>>'{group,id}')::uuid; display_item_id:=(result->>'displayItemId')::uuid;
  if not exists(select 1 from public.exhibition_display_items item_row where item_row.id=v.display_item_id
    and item_row.event_id=v.event_id and item_row.item_type='smartphone_group' and item_row.smartphone_group_id=v.group_id) then
    raise exception 'Smartphone GroupのDisplay Itemが作成されません。';end if;
  perform public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',1300,900);
  if (select count(*) from public.exhibition_smartphone_display_groups group_row where group_row.event_id=v.event_id)<>1
     or (select count(*) from public.exhibition_display_items item_row where item_row.smartphone_group_id=v.group_id)<>1 then
    raise exception 'EventごとのGroupまたはDisplay Itemが重複しました。';end if;
  begin
    insert into public.exhibition_smartphone_display_groups(event_id) values(v.event_id);
    raise exception '同一EventへGroupを重複作成できました。';
  exception when others then if sqlerrm='同一EventへGroupを重複作成できました。' then raise;end if;end;

  -- accepted=0 never creates a Group Version.
  begin
    perform public.admin_create_exhibition_smartphone_group_version_v1(event_id);
    raise exception 'accepted 0件でGroup Versionを作成できました。';
  exception when others then if sqlerrm='accepted 0件でGroup Versionを作成できました。' then raise;end if;end;

  -- Member management operation is rejected.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_item_1__@example.invalid','role','authenticated')::text,true);
  begin
    perform public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'不正変更',100,100);
    raise exception '一般MemberがGroupを変更できました。';
  exception when others then if sqlerrm='一般MemberがGroupを変更できました。' then raise;end if;end;

  -- Create four formal Applications and Smartphone states: accepted, submitted, rejected, withdrawn.
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash); entry_id:=(result->>'entryId')::uuid;
  -- A newly inserted Regular Work receives one Display Item automatically.
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null); regular_work:=(result->>'id')::uuid;
  if (select count(*) from public.exhibition_display_items item_row where item_row.regular_work_id=v.regular_work)<>1 then
    raise exception '新規Regular WorkのDisplay Item自動作成に失敗しました。';end if;
  begin
    insert into public.exhibition_display_items(event_id,item_type,regular_work_id) values(v.event_id,'regular_work',v.regular_work);
    raise exception '同一Regular WorkへDisplay Itemを重複作成できました。';
  exception when others then if sqlerrm='同一Regular WorkへDisplay Itemを重複作成できました。' then raise;end if;end;
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null); phone1:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',event_id::text||'/'||member1::text||'/'||phone1::text||'/one.jpg',member1,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone1,'portrait',true,'none','',event_id::text||'/'||member1::text||'/'||phone1::text||'/one.jpg',repeat('1',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone1,(terms->>'id')::uuid,terms->>'contentHash');snap1:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(snap1,'accepted','{}','',null);

  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_item_2__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'none','',null,null);phone2:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',event_id::text||'/'||member2::text||'/'||phone2::text||'/two.jpg',member2,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone2,'landscape',true,'none','',event_id::text||'/'||member2::text||'/'||phone2::text||'/two.jpg',repeat('2',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone2,(terms->>'id')::uuid,terms->>'contentHash');snap2:=(result->>'snapshotId')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_item_3__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);phone3:=(result->>'id')::uuid;
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',event_id::text||'/'||member3::text||'/'||phone3::text||'/three.jpg',member3,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone3,'portrait',true,'none','',event_id::text||'/'||member3::text||'/'||phone3::text||'/three.jpg',repeat('3',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone3,(terms->>'id')::uuid,terms->>'contentHash');snap3:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(snap3,'rejected',array['orientation'],'検証要修正',now()+interval '1 hour');

  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_item_4__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,0,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);phone4:=(result->>'id')::uuid;
  perform public.withdraw_exhibition_smartphone_work_v1(phone4,'検証取下げ');

  -- Version 1 contains only the currently accepted Work and its exact accepted Snapshot.
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_smartphone_group_version_v1(event_id);version1:=(result->>'groupVersionId')::uuid;
  if (result->>'reused')::boolean or (result->>'itemCount')::integer<>1
     or not exists(select 1 from public.exhibition_smartphone_group_version_items item_row
       where item_row.group_version_id=v.version1 and item_row.smartphone_work_id=v.phone1 and item_row.smartphone_submission_snapshot_id=v.snap1)
     or exists(select 1 from public.exhibition_smartphone_group_version_items item_row
       where item_row.group_version_id=v.version1 and item_row.smartphone_work_id in(v.phone2,v.phone3,v.phone4)) then
    raise exception 'Version 1のaccepted構成またはSnapshot固定が不正です。';end if;
  result:=public.admin_create_exhibition_smartphone_group_version_v1(event_id);
  if not (result->>'reused')::boolean or (result->>'groupVersionId')::uuid<>version1 then
    raise exception '同一構成で無意味なVersionが増えました。';end if;

  begin update public.exhibition_smartphone_group_versions set created_by='changed' where id=v.version1;raise exception 'Group Versionを更新できました。';
  exception when others then if sqlerrm='Group Versionを更新できました。' then raise;end if;end;
  begin delete from public.exhibition_smartphone_group_version_items where group_version_id=v.version1;raise exception 'Group Version Itemを削除できました。';
  exception when others then if sqlerrm='Group Version Itemを削除できました。' then raise;end if;end;
  begin
    insert into public.exhibition_smartphone_group_version_items(group_version_id,smartphone_work_id,smartphone_submission_snapshot_id,item_order)
    values(v.version1,v.phone2,v.snap2,2);
    raise exception 'submitted SmartphoneをVersionへ追加できました。';
  exception when others then if sqlerrm='submitted SmartphoneをVersionへ追加できました。' then raise;end if;end;

  -- Accepting another Work creates Version 2 and leaves Version 1 unchanged.
  perform public.admin_review_exhibition_smartphone_work_v1(snap2,'accepted','{}','',null);
  result:=public.admin_create_exhibition_smartphone_group_version_v1(event_id);version2:=(result->>'groupVersionId')::uuid;
  if version2=version1 or (result->>'versionNo')::integer<>2 or (result->>'itemCount')::integer<>2
     or (select count(*) from public.exhibition_smartphone_group_version_items item_row where item_row.group_version_id=v.version1)<>1
     or (select count(*) from public.exhibition_smartphone_group_version_items item_row where item_row.group_version_id=v.version2)<>2 then
    raise exception '構成変更後のVersion追加または旧Version不変性が不正です。';end if;

  -- 006 compatibility: an immutable Group Version is a visible Reset blocker.
  insert into public.maintenance_admins(email,name,role_name,active) values(admin_email,'Display検証管理者','検証',true)
    on conflict(email) do update set active=true;
  preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member1);
  if (preview->>'canReset')::boolean
     or not exists(select 1 from jsonb_array_elements_text(preview->'blockers') blocker
       where blocker like 'Smartphone Phase 2 Display Item%') then
    raise exception 'Maintenance ResetがGroup Version参照をblockerとして検出しません。';end if;

  -- A second Event can own its own empty Group, but still cannot create a Version.
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__display_item_empty__','空Group検証展',now()+interval '12 days',now()+interval '13 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"empty-slot","label":"検証枠"}]'::jsonb,admin_email)
  returning id into empty_event_id;
  perform public.admin_activate_exhibition_workflow_v2(empty_event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','empty-group-application','Application規約','空Group検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=1 where id=empty_event_id;
  perform public.admin_upsert_exhibition_smartphone_display_group_v1(empty_event_id,'スマートフォン撮影写真作品',null,null);
  begin perform public.admin_create_exhibition_smartphone_group_version_v1(empty_event_id);raise exception '空GroupからVersionを作成できました。';
  exception when others then if sqlerrm='空GroupからVersionを作成できました。' then raise;end if;end;
end $$;

select to_regclass('public.exhibition_display_items') is not null as display_items_ready,
  to_regclass('public.exhibition_smartphone_display_groups') is not null as smartphone_groups_ready,
  to_regclass('public.exhibition_smartphone_group_versions') is not null as group_versions_ready,
  to_regprocedure('public.admin_create_exhibition_smartphone_group_version_v1(uuid)') is not null as group_version_rpc_ready;

rollback;
