-- Smartphone Phase 2 / Step 4 verification. Fully rolled back.
begin;

do $$
<<v>>
declare
 admin_email text;member_id uuid;event_id uuid;agreement_id uuid;agreement_hash text;terms jsonb;result jsonb;
 venue_id uuid;wall_id uuid;layout_id uuid;regular_work uuid;regular_snapshot uuid;caption_snapshot uuid;regular_item uuid;
 phone1 uuid;phone2 uuid;phone_snap1 uuid;phone_snap2 uuid;group_item uuid;final_id uuid;group_version uuid;
 export_id uuid;publication_id uuid;survey_id uuid;actual_id uuid;archive_id uuid;regular_actual uuid;group_actual uuid;
 original_path text;phone_path1 text;phone_path2 text;public_path text;survey_before jsonb;actual_before jsonb;archive_group jsonb;preview jsonb;
begin
 select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
 if admin_email is null then raise exception '011検証にはactive Adminが必要です。';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 insert into public.members(member_no,email,name,grade,active) values('member-999302','__display_actual__@example.invalid','非公開スマホ作者','B3',true) returning id into member_id;
 insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
 insert into public.exhibition_venues(name) values('__display_actual_venue__') returning id into venue_id;
 insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Wall',1,6000,3000) returning id into wall_id;
 insert into public.events(status,published,genre,title,exhibition_title,exhibition_key,site_title,site_title_en,site_description,
  starts_at,ends_at,place,contact,registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,
  dm_image_path,survey_enabled,survey_opens_at,survey_closes_at)
 values('saved',true,'exhibition','__display_actual_archive__','Display Actual検証展','2099-display-actual','公開検証展','Actual Test','検証説明',
  now()+interval '10 days',now()+interval '11 days','検証会場',admin_email,now()+interval '1 day',2,1,
  '[{"id":"actual-slot","label":"検証枠"}]'::jsonb,admin_email,venue_id,'2099-display-actual/dm.webp',true,now()-interval '1 hour',now()+interval '1 day')
 returning id into event_id;
 perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days',
  'display-actual-application','Application規約','011検証');
 select definition.id,definition.content_hash into agreement_id,agreement_hash from public.exhibition_agreement_definitions definition
 where definition.event_id=v.event_id and definition.active;
 update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
 terms:=public.get_exhibition_smartphone_terms_v1();

 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_actual__@example.invalid','role','authenticated')::text,true);
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
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_actual__@example.invalid','role','authenticated')::text,true);
 perform public.save_exhibition_caption_draft_v2(regular_work,'公開作者','self','Regular EN','digital','','Camera','','','provided','通常作品説明','Regular description','none','',null,'none','');
 result:=public.submit_exhibition_caption_v2(regular_work);caption_snapshot:=(result->>'snapshotId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_caption_v2(caption_snapshot,'accepted','{}','',null);

 result:=public.admin_upsert_exhibition_smartphone_display_group_v1(event_id,'スマートフォン撮影写真作品',1200,800);
 group_item:=(result->>'displayItemId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_actual__@example.invalid','role','authenticated')::text,true);
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
 result:=public.admin_finalize_exhibition_layout_v2(layout_id,'011');final_id:=(result->>'finalizationId')::uuid;
 select item.smartphone_group_version_id into group_version from public.exhibition_layout_finalization_items item where item.finalization_id=final_id and item.display_item_id=group_item;
 result:=public.admin_finalize_exhibition_export_v2(event_id,'011 Export');export_id:=(result->>'exportVersionId')::uuid;
 public_path:=event_id::text||'/'||member_id::text||'/'||regular_work::text||'/public.webp';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-public',public_path,member_id,'{}');
 perform public.admin_set_exhibition_public_image_v2(regular_work,public_path);
 result:=public.admin_finalize_exhibition_publication_v2(export_id,'011 Publication');publication_id:=(result->>'publicationVersionId')::uuid;
 perform public.admin_set_current_exhibition_publication_v2(publication_id,'011 current');
 survey_id:=public.submit_exhibition_survey('2099-display-actual',repeat('t',40),'ja','',jsonb_build_array(jsonb_build_object('display_item_id',group_item,'comment','group')));
 select to_jsonb(response) into survey_before from public.exhibition_survey_responses response where response.id=survey_id;

 result:=public.admin_initialize_exhibition_actual_v2(final_id,null,'','011');actual_id:=(result->>'actualVersionId')::uuid;
 if (select count(*) from public.exhibition_actual_items item where item.actual_version_id=actual_id)<>2 then raise exception 'Regular + Smartphone Group Actualが2件ではありません。';end if;
 select item.id into regular_actual from public.exhibition_actual_items item where item.actual_version_id=actual_id and item.display_item_id=regular_item;
 select item.id into group_actual from public.exhibition_actual_items item where item.actual_version_id=actual_id and item.display_item_id=group_item;
 if not exists(select 1 from public.exhibition_actual_items item where item.id=group_actual and item.display_item_type='smartphone_group'
  and item.work_id is null and item.work_submission_snapshot_id is null and item.caption_submission_snapshot_id is null
  and item.smartphone_group_version_id=group_version and item.smartphone_work_count=1) then raise exception 'Smartphone Group Actualの固定が不正です。';end if;
 perform public.admin_update_exhibition_actual_item_v2(regular_actual,'exhibited',wall_id,0,2200,1,regular_snapshot,caption_snapshot,false,'');
 perform public.admin_update_exhibition_actual_item_v2(group_actual,'exhibited',wall_id,700,2200,2,null,null,false,'');
 if exists(select 1 from public.admin_get_exhibition_actual_readiness_v2(actual_id) readiness where not readiness.ready) then raise exception 'Actual readinessが解消されません。';end if;
 perform public.admin_finalize_exhibition_actual_v2(actual_id,'011 finalize');
 select to_jsonb(item) into actual_before from public.exhibition_actual_items item where item.id=group_actual;

 -- accepted構成を後から増やしても、確定Actualは元のGroup Versionのまま。
 perform set_config('request.jwt.claims',jsonb_build_object('email','__display_actual__@example.invalid','role','authenticated')::text,true);
 result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'none','',null,null);phone2:=(result->>'id')::uuid;
 phone_path2:=event_id::text||'/'||member_id::text||'/'||phone2::text||'/phone2.jpg';
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',phone_path2,member_id,'{}');
 perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone2,'landscape',true,'none','',phone_path2,repeat('2',64));
 result:=public.submit_exhibition_smartphone_work_v1(phone2,(terms->>'id')::uuid,terms->>'contentHash');phone_snap2:=(result->>'snapshotId')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 perform public.admin_review_exhibition_smartphone_work_v1(phone_snap2,'accepted','{}','',null);
 if (select to_jsonb(item) from public.exhibition_actual_items item where item.id=group_actual) is distinct from actual_before then raise exception 'accepted増加が確定Actualを変更しました。';end if;

 result:=public.admin_finalize_exhibition_archive_v2(actual_id,'011 Archive');archive_id:=(result->>'archiveVersionId')::uuid;
 if (select count(*) from public.exhibition_archive_items item where item.archive_version_id=archive_id)<>2
  or (select count(*) from public.exhibition_archive_items item where item.archive_version_id=archive_id and item.display_item_type='smartphone_group')<>1 then raise exception 'Archiveが集合展示1件になりません。';end if;
 select to_jsonb(item) into archive_group from public.exhibition_archive_items item where item.archive_version_id=archive_id and item.display_item_id=group_item;
 if archive_group->>'smartphone_group_version_id'<>group_version::text or (archive_group->>'smartphone_work_count')::integer<>1
  or archive_group->>'work_id' is not null or archive_group->>'work_submission_snapshot_id' is not null
  or archive_group->>'title_ja'<>'スマートフォン撮影写真作品' or archive_group->>'image_state'<>'no_image'
  or archive_group->>'public_image_path' is not null then raise exception 'Smartphone Group Archiveの固定・privacyが不正です。';end if;
 if archive_group::text like '%'||phone1::text||'%' or archive_group::text like '%'||phone_snap1::text||'%'
  or archive_group::text like '%'||member_id::text||'%' or archive_group::text like '%非公開スマホ作者%' then raise exception 'Archive集合行に個別情報が漏れています。';end if;
 if exists(select 1 from public.exhibition_archive_items item where item.work_id in(phone1,phone2)) then raise exception '個別Smartphone WorkがArchiveされました。';end if;
 if (select to_jsonb(response) from public.exhibition_survey_responses response where response.id=survey_id) is distinct from survey_before
  or not exists(select 1 from public.exhibition_survey_selections selection where selection.response_id=survey_id and selection.display_item_id=group_item and selection.publication_item_id is not null) then raise exception 'ArchiveがSurvey履歴を変更しました。';end if;
 begin update public.exhibition_actual_items set note='改変' where id=group_actual;raise exception '確定Actualを変更できました。';exception when others then if sqlerrm='確定Actualを変更できました。' then raise;end if;end;
 begin update public.exhibition_archive_items set title_ja='改変' where archive_version_id=archive_id and display_item_id=group_item;raise exception 'Archiveを変更できました。';exception when others then if sqlerrm='Archiveを変更できました。' then raise;end if;end;
 insert into public.maintenance_admins(email,name,role_name,active) values(admin_email,'011検証管理者','検証',true) on conflict(email) do update set active=true;
 preview:=public.maintenance_preview_exhibition_test_reset_v1(event_id,member_id);
 if (preview->>'canReset')::boolean then raise exception 'Actual/Archive到達後もMaintenance Reset可能です。';end if;
end $$;

-- Member/anon cannot operate or enumerate internal Actual/Archive rows.
select set_config('request.jwt.claims',jsonb_build_object('email','__display_actual__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
 begin perform public.admin_initialize_exhibition_actual_v2(gen_random_uuid(),null,'','');raise exception 'MemberがActualを初期化できました。';exception when others then if sqlerrm='MemberがActualを初期化できました。' then raise;end if;end;
 if exists(select 1 from public.exhibition_actual_items) or exists(select 1 from public.exhibition_archive_items) then raise exception 'MemberがActual/Archiveを列挙できました。';end if;
end $$;
reset role;

rollback;
