-- Smartphone Phase 2 / Step 3 verification. Fully rolled back.
begin;

do $$
<<v>>
declare
 admin_email text;member_id uuid;event_id uuid;agreement_id uuid;agreement_hash text;terms jsonb;result jsonb;
 venue_id uuid;wall_id uuid;layout_id uuid;regular_work uuid;regular_snapshot uuid;caption_snapshot uuid;regular_item uuid;
 phone1 uuid;phone2 uuid;phone_snap1 uuid;phone_snap2 uuid;group_item uuid;final_id uuid;group_version uuid;
 export_id uuid;publication_id uuid;response_regular uuid;response_group uuid;payload jsonb;smartphone_public_item jsonb;preview jsonb;
 original_path text;phone_path1 text;phone_path2 text;public_path text;legacy_selection_count integer;
begin
 select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
 if admin_email is null then raise exception '010検証にはactive Adminが必要です。';end if;
 select count(*) into legacy_selection_count from public.exhibition_survey_selections;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 insert into public.members(member_no,email,name,grade,active) values('member-999301','__display_public__@example.invalid','非公開の個人名','B3',true) returning id into member_id;
 insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
 insert into public.exhibition_venues(name) values('__display_public_venue__') returning id into venue_id;
 insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Wall',1,6000,3000) returning id into wall_id;
 insert into public.events(status,published,genre,title,exhibition_title,exhibition_key,site_title,site_title_en,site_description,
  starts_at,ends_at,place,contact,registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,
  dm_image_path,survey_enabled,survey_opens_at,survey_closes_at)
 values('saved',true,'exhibition','__display_publication__','Display Publication検証展','2099-display-publication-test','公開検証展','Publication Test','検証説明',
  now()+interval '10 days',now()+interval '11 days','検証会場',admin_email,now()+interval '1 day',2,1,
  '[{"id":"public-slot","label":"検証枠"}]'::jsonb,admin_email,venue_id,'2099-display-publication-test/dm.webp',true,now()-interval '1 hour',now()+interval '1 day')
 returning id into event_id;
 perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days',
  'display-publication-application','Application規約','010検証');
 select definition.id,definition.content_hash into agreement_id,agreement_hash from public.exhibition_agreement_definitions definition
 where definition.event_id=v.event_id and definition.active;
 update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
 terms:=public.get_exhibition_smartphone_terms_v1();

 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_public__@example.invalid','role','authenticated')::text,true);
 perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
 result:=public.save_exhibition_work_draft_v2(event_id,null,'Regular','portrait','A3','',297,420,true,null,null);regular_work:=(result->>'id')::uuid;
 original_path:=event_id::text||'/'||member_id::text||'/'||regular_work::text||'/regular.jpg';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',original_path,member_id,'{}');
 perform public.save_exhibition_work_draft_v2(event_id,regular_work,'Regular','portrait','A3','',297,420,true,original_path,repeat('a',64));
 perform public.submit_exhibition_work_batch_v2(event_id,array[regular_work]);
 select work.current_submission_snapshot_id into regular_snapshot from public.exhibition_works work where work.id=regular_work;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_work_v2(regular_snapshot,'accepted','{}','',null);
 select item.id into regular_item from public.exhibition_display_items item where item.regular_work_id=regular_work;
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_public__@example.invalid','role','authenticated')::text,true);
 perform public.save_exhibition_caption_draft_v2(regular_work,'公開作者','self','Regular EN','digital','','Camera','','','provided','通常作品説明','Regular description','none','',null,'none','');
 result:=public.submit_exhibition_caption_v2(regular_work);caption_snapshot:=(result->>'snapshotId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_caption_v2(caption_snapshot,'accepted','{}','',null);

 result:=public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',1200,800);
 group_item:=(result->>'displayItemId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_public__@example.invalid','role','authenticated')::text,true);
 result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);phone1:=(result->>'id')::uuid;
 phone_path1:=event_id::text||'/'||member_id::text||'/'||phone1::text||'/phone1.jpg';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',phone_path1,member_id,'{}');
 perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone1,'portrait',true,'none','',phone_path1,repeat('1',64));
 result:=public.submit_exhibition_smartphone_work_v1(phone1,(terms->>'id')::uuid,terms->>'contentHash');phone_snap1:=(result->>'snapshotId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_smartphone_work_v1(phone_snap1,'accepted','{}','',null);

 insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(event_id,'Mixed',1,'draft',true,admin_email) returning id into layout_id;
 insert into public.exhibition_placements(layout_id,display_item_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order)
 values(layout_id,regular_item,regular_work,wall_id,0,2200,1),(layout_id,group_item,null,wall_id,700,2200,2);
 result:=public.admin_finalize_exhibition_layout_v2(layout_id,'初回');final_id:=(result->>'finalizationId')::uuid;
 select item.smartphone_group_version_id into group_version from public.exhibition_layout_finalization_items item
 where item.finalization_id=final_id and item.display_item_id=group_item;

 result:=public.admin_finalize_exhibition_export_v2(event_id,'010 Export');export_id:=(result->>'exportVersionId')::uuid;
 if (select count(*) from public.exhibition_export_items item where item.export_version_id=export_id)<>2
  or (select count(*) from public.exhibition_export_items item where item.export_version_id=export_id and item.display_item_type='smartphone_group')<>1 then
  raise exception 'Regular + Smartphone Group Exportが2件になりません。';end if;
 if exists(select 1 from public.exhibition_export_items item where item.export_version_id=export_id and item.work_id in(phone1)) then
  raise exception '個別Smartphone WorkがExportされました。';end if;
 if not exists(select 1 from public.exhibition_export_items item where item.export_version_id=export_id and item.display_item_id=group_item
  and item.smartphone_group_version_id=group_version and item.smartphone_work_count=1 and item.work_id is null and item.caption_submission_snapshot_id is null) then
  raise exception 'Exportがexact Group Versionを固定していません。';end if;

 public_path:=event_id::text||'/'||member_id::text||'/'||regular_work::text||'/public.webp';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-public',public_path,member_id,'{}');
 perform public.admin_set_exhibition_public_image_v2(regular_work,public_path);
 result:=public.admin_finalize_exhibition_publication_v2(export_id,'010 Publication');publication_id:=(result->>'publicationVersionId')::uuid;
 perform public.admin_set_current_exhibition_publication_v2(publication_id,'010 current');
 if (select count(*) from public.exhibition_publication_items item where item.publication_version_id=publication_id)<>2
  or not exists(select 1 from public.exhibition_publication_items item where item.publication_version_id=publication_id
    and item.display_item_id=group_item and item.display_item_type='smartphone_group' and item.image_state='no_image'
    and item.public_image_path is null and item.work_id is null and item.smartphone_group_version_id=group_version) then
  raise exception 'Smartphone Group Publicationの固定またはNO IMAGEが不正です。';end if;

 payload:=public.get_public_exhibition('2099-display-publication-test');
 select item into smartphone_public_item from jsonb_array_elements(payload->'works') item
 where item->>'displayItemUuid'=group_item::text;
 if jsonb_array_length(payload->'works')<>2
  or smartphone_public_item is null or smartphone_public_item->>'displayItemType'<>'smartphone_group'
  or smartphone_public_item->>'workUuid' is not null or smartphone_public_item->>'imageState'<>'no_image' then
  raise exception 'Public payloadにDisplay Item識別子がありません。';end if;
 if payload::text like '%'||phone1::text||'%' or payload::text like '%'||phone_snap1::text||'%'
  or smartphone_public_item::text like '%'||member_id::text||'%'
  or smartphone_public_item::text like '%非公開の個人名%' then
  raise exception 'Smartphone個別UUID・作者情報がPublic payloadへ漏れています。';end if;

 result:=jsonb_build_object('x',1);
 response_regular:=public.submit_exhibition_survey('2099-display-publication-test',repeat('r',40),'ja','',
  jsonb_build_array(jsonb_build_object('display_item_id',regular_item,'comment','regular')));
 response_group:=public.submit_exhibition_survey('2099-display-publication-test',repeat('s',40),'ja','',
  jsonb_build_array(jsonb_build_object('display_item_id',group_item,'comment','group')));
 if not exists(select 1 from public.exhibition_survey_selections selection where selection.response_id=response_regular
   and selection.display_item_id=regular_item and selection.work_id=regular_work and selection.publication_item_id is not null)
  or not exists(select 1 from public.exhibition_survey_selections selection where selection.response_id=response_group
   and selection.display_item_id=group_item and selection.work_id is null and selection.publication_item_id is not null) then
  raise exception 'Regular/Smartphone Group Survey回答の固定が不正です。';end if;
 if exists(select 1 from public.exhibition_survey_selections selection where selection.work_id=phone1) then
  raise exception '個別Smartphone WorkがSurvey対象になりました。';end if;

 -- Publication after accepted composition changes remains exactly Version 1.
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_public__@example.invalid','role','authenticated')::text,true);
 result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'none','',null,null);phone2:=(result->>'id')::uuid;
 phone_path2:=event_id::text||'/'||member_id::text||'/'||phone2::text||'/phone2.jpg';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',phone_path2,member_id,'{}');
 perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone2,'landscape',true,'none','',phone_path2,repeat('2',64));
 result:=public.submit_exhibition_smartphone_work_v1(phone2,(terms->>'id')::uuid,terms->>'contentHash');phone_snap2:=(result->>'snapshotId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_smartphone_work_v1(phone_snap2,'accepted','{}','',null);
 payload:=public.get_public_exhibition('2099-display-publication-test');
 if (select (item->>'smartphoneWorkCount')::integer from jsonb_array_elements(payload->'works') item where item->>'displayItemUuid'=group_item::text)<>1
  or payload::text like '%'||phone2::text||'%' or payload::text like '%'||phone_snap2::text||'%' then
  raise exception 'accepted増加が既存Publicationの意味を変更しました。';end if;
 if (select count(*) from public.exhibition_survey_selections)<legacy_selection_count+2 then raise exception '既存Survey回答が失われました。';end if;

 insert into public.maintenance_admins(email,name,role_name,active) values(admin_email,'010検証管理者','検証',true)
 on conflict(email) do update set active=true;
 preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
 if (preview->>'canReset')::boolean then raise exception 'Export/Publication/Survey到達後もMaintenance Reset可能です。';end if;
end $$;

-- Public RPC is available, while anon cannot read immutable internal rows directly.
select set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true);
set local role anon;
do $$ begin
 if public.get_public_exhibition('2099-display-publication-test') is not null then null;end if;
 begin perform 1 from public.exhibition_export_items limit 1;raise exception 'anonがExport Itemを直接参照できました。';
 exception when insufficient_privilege then null;end;
 begin perform 1 from public.exhibition_publication_items limit 1;raise exception 'anonがPublication Itemを直接参照できました。';
 exception when insufficient_privilege then null;end;
end $$;
reset role;

rollback;
