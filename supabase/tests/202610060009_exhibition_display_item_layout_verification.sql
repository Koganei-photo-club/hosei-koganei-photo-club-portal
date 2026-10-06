-- Smartphone Phase 2 / Step 2: Display Item Layout verification. Fully rolled back.
begin;

do $$
<<v>>
declare
  admin_email text; member_id uuid; event_id uuid; agreement_id uuid; agreement_hash text; terms jsonb; result jsonb;
  venue_id uuid; wall_id uuid; layout1 uuid; layout2 uuid; regular_work uuid; regular_snapshot uuid; regular_item uuid;
  phone1 uuid; phone2 uuid; phone3 uuid; phone_snap1 uuid; phone_snap2 uuid; phone_snap3 uuid;
  group_id uuid; group_item uuid; final1 uuid; final2 uuid; version1 uuid; version2 uuid; preview jsonb;
  path_regular text; path_phone1 text; path_phone2 text; path_phone3 text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception '009検証にはactive Adminが必要です。';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active)
  values('member-999201','__display_layout__@example.invalid','Display Layout検証','B3',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__display_layout_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm)
  values(venue_id,'Wall',1,6000,3000) returning id into wall_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id)
  values('saved',true,'exhibition','__display_item_layout__','Display Item Layout検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"layout-slot","label":"検証枠"}]'::jsonb,admin_email,venue_id)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','display-layout-application','Application規約','009検証');
  select definition.id,definition.content_hash into agreement_id,agreement_hash
  from public.exhibition_agreement_definitions definition where definition.event_id=v.event_id and definition.active;
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  terms:=public.get_exhibition_smartphone_terms_v1();

  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Regular','portrait','A3','',297,420,true,null,null);
  regular_work:=(result->>'id')::uuid;
  path_regular:=event_id::text||'/'||member_id::text||'/'||regular_work::text||'/regular.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',path_regular,member_id,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,regular_work,'Regular','portrait','A3','',297,420,true,path_regular,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[regular_work]);
  select work.current_submission_snapshot_id into regular_snapshot from public.exhibition_works work where work.id=regular_work;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(regular_snapshot,'accepted','{}','',null);
  select item.id into regular_item from public.exhibition_display_items item where item.regular_work_id=regular_work;

  -- A Group with no dimensions or accepted works is not a Layout candidate.
  result:=public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',null,null);
  group_id:=(result#>>'{group,id}')::uuid;group_item:=(result->>'displayItemId')::uuid;
  if exists(select 1 from public.admin_get_exhibition_layout_candidates_v1(event_id) candidate where candidate.display_item_id=group_item) then
    raise exception '寸法未設定・accepted 0件のGroupが候補に出ました。';end if;

  -- Two accepted Smartphone Works are built through the formal Phase 1 flow.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);phone1:=(result->>'id')::uuid;
  path_phone1:=event_id::text||'/'||member_id::text||'/'||phone1::text||'/phone1.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',path_phone1,member_id,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone1,'portrait',true,'none','',path_phone1,repeat('1',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone1,(terms->>'id')::uuid,terms->>'contentHash');phone_snap1:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(phone_snap1,'accepted','{}','',null);
  perform public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',1200,800);
  if not exists(select 1 from public.admin_get_exhibition_layout_candidates_v1(event_id) candidate
    where candidate.display_item_id=group_item and candidate.item_type='smartphone_group' and candidate.width_mm=1200 and candidate.height_mm=800) then
    raise exception '有効なSmartphone GroupがLayout候補に出ません。';end if;

  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by)
  values(event_id,'Mixed',1,'draft',true,admin_email) returning id into layout1;
  insert into public.exhibition_placements(layout_id,display_item_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order)
  values(layout1,regular_item,regular_work,wall_id,0,2200,1),(layout1,group_item,null,wall_id,700,2200,2);
  if (select count(*) from public.exhibition_placements placement where placement.layout_id=layout1)<>2 then
    raise exception 'Regular WorkとSmartphone Groupの混在Placementに失敗しました。';end if;
  begin
    insert into public.exhibition_placements(layout_id,display_item_id,wall_id,x_mm,top_from_floor_mm,viewing_order)
    values(layout1,phone1,wall_id,2500,2200,3);
    raise exception '個別Smartphone WorkをPlacementできました。';
  exception when others then if sqlerrm='個別Smartphone WorkをPlacementできました。' then raise;end if;end;

  -- A second acceptance after Placement but before Finalization must be in the fixed Version.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'none','',null,null);phone2:=(result->>'id')::uuid;
  path_phone2:=event_id::text||'/'||member_id::text||'/'||phone2::text||'/phone2.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',path_phone2,member_id,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone2,'landscape',true,'none','',path_phone2,repeat('2',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone2,(terms->>'id')::uuid,terms->>'contentHash');phone_snap2:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(phone_snap2,'accepted','{}','',null);
  result:=public.admin_finalize_exhibition_layout_v2(layout1,'初回');final1:=(result->>'finalizationId')::uuid;
  select item.smartphone_group_version_id into version1 from public.exhibition_layout_finalization_items item
  where item.finalization_id=final1 and item.display_item_id=group_item;
  if (select count(*) from public.exhibition_smartphone_group_version_items item where item.group_version_id=version1)<>2 then
    raise exception 'Finalize直前のaccepted追加がGroup Versionへ固定されません。';end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final1
    and item.display_item_id=group_item and item.work_id is null and item.occupied_width_mm=1200 and item.occupied_height_mm=800) then
    raise exception 'Groupの確定外寸またはsource固定が不正です。';end if;
  if (select count(distinct item.display_no) from public.exhibition_layout_finalization_items item where item.finalization_id=final1)<>2
     or (select item.display_no from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.display_item_id=regular_item)<>1
     or (select item.display_no from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.display_item_id=group_item)<>2 then
    raise exception '共通display_noが鑑賞順どおり一意に採番されません。';end if;
  if exists(select 1 from public.exhibition_work_display_numbers number_row where number_row.work_id in(phone1,phone2)) then
    raise exception '個別Smartphone Workへdisplay_noが付与されました。';end if;

  begin update public.exhibition_layout_finalization_items set occupied_width_mm=999 where finalization_id=final1 and display_item_id=group_item;
    raise exception 'Smartphone Group確定履歴を更新できました。';
  exception when others then if sqlerrm='Smartphone Group確定履歴を更新できました。' then raise;end if;end;
  begin update public.exhibition_display_item_numbers set display_no=99 where display_item_id=group_item;
    raise exception '共通display_noを更新できました。';
  exception when others then if sqlerrm='共通display_noを更新できました。' then raise;end if;end;

  -- Removing an accepted work before reconfirmation creates a new exact Version; V1 remains unchanged.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
  perform public.withdraw_exhibition_smartphone_work_v1(phone2,'Finalize前減少検証');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_clone_exhibition_layout(layout1);layout2:=(result->>'layoutId')::uuid;
  result:=public.admin_finalize_exhibition_layout_v2(layout2,'accepted構成変更');final2:=(result->>'finalizationId')::uuid;
  select item.smartphone_group_version_id into version2 from public.exhibition_layout_finalization_items item
  where item.finalization_id=final2 and item.display_item_id=group_item;
  if version2=version1 or (select count(*) from public.exhibition_smartphone_group_version_items item where item.group_version_id=version2)<>1
     or (select count(*) from public.exhibition_smartphone_group_version_items item where item.group_version_id=version1)<>2 then
    raise exception 'accepted減少時の新Versionまたは旧Version不変性が不正です。';end if;
  if (select number_row.display_no from public.exhibition_display_item_numbers number_row where number_row.display_item_id=group_item)<>2 then
    raise exception '再確定でSmartphone Group番号が変わりました。';end if;

  -- A later acceptance cannot mutate either finalized Version.
  perform set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);phone3:=(result->>'id')::uuid;
  path_phone3:=event_id::text||'/'||member_id::text||'/'||phone3::text||'/phone3.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',path_phone3,member_id,'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone3,'portrait',true,'none','',path_phone3,repeat('3',64));
  result:=public.submit_exhibition_smartphone_work_v1(phone3,(terms->>'id')::uuid,terms->>'contentHash');phone_snap3:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_smartphone_work_v1(phone_snap3,'accepted','{}','',null);
  if (select count(*) from public.exhibition_smartphone_group_version_items item where item.group_version_id=version1)<>2
     or (select count(*) from public.exhibition_smartphone_group_version_items item where item.group_version_id=version2)<>1 then
    raise exception 'Finalize後のaccepted変更が過去Versionを変更しました。';end if;

  insert into public.maintenance_admins(email,name,role_name,active) values(admin_email,'009検証管理者','検証',true)
  on conflict(email) do update set active=true;
  preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
  if (preview->>'canReset')::boolean or not exists(select 1 from jsonb_array_elements_text(preview->'blockers') blocker
    where blocker like 'Smartphone Phase 2 Display Item%') then
    raise exception 'Placement/Finalization済みGroupがMaintenance Reset blockerになりません。';end if;
end $$;

-- Members cannot use admin candidate/finalize operations or mutate Layout history.
select set_config('request.jwt.claims',jsonb_build_object('email','__display_layout__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_get_exhibition_layout_candidates_v1(gen_random_uuid());raise exception 'MemberがLayout候補RPCを実行できました。';
  exception when others then if sqlerrm='MemberがLayout候補RPCを実行できました。' then raise;end if;end;
  begin perform public.admin_finalize_exhibition_layout_v2(gen_random_uuid(),'forged');raise exception 'MemberがLayoutを確定できました。';
  exception when others then if sqlerrm='MemberがLayoutを確定できました。' then raise;end if;end;
  begin
    update public.exhibition_display_item_numbers set display_no=999;
    if found then raise exception 'Memberが共通display_noを変更できました。';end if;
  exception when insufficient_privilege then null;end;
end $$;
reset role;

rollback;
