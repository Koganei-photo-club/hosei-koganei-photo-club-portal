-- Phase 9 Actual Exhibition Record verification。全変更はROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text;mid uuid;eid uuid;entry_id uuid;venue_id uuid;wall1 uuid;wall2 uuid;layout_id uuid;final_id uuid;
  a uuid;b uuid;c uuid;sa uuid;sb uuid;sc uuid;ca uuid;cb uuid;cc uuid;actual1 uuid;actual2 uuid;export1 uuid;publication1 uuid;response1 uuid;
  ia uuid;ib uuid;ic uuid;result jsonb;plan_before jsonb;export_before jsonb;publication_before jsonb;survey_before jsonb;
  agreement_id uuid;agreement_hash text;path_a text;path_b text;path_c text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values('member-998002','__phase9_member__@example.invalid','Phase 9','B4',true) returning id into mid;
  insert into public.membership_years(member_id,fiscal_year,active) values(mid,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase9_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Plan Wall',1,6000,3000) returning id into wall1;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Actual Wall',2,6000,3000) returning id into wall2;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,exhibition_key,
    site_title,site_description,dm_image_path,site_status,survey_enabled,survey_opens_at,survey_closes_at)
  values('saved',true,'exhibition','__phase9_v2__','Phase 9',now()-interval '2 hours',now()+interval '2 hours','会場',admin_email,
    now()-interval '3 hours',3,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id,'2099-phase9',
    '公開展','説明','2099-phase9/dm.webp','draft',true,now()-interval '1 hour',now()+interval '1 hour') returning id into eid;
  perform public.admin_activate_exhibition_workflow_v2(eid,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase9','Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.eid and agreement.active;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase9_member__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(eid,3,'real_name','','',agreement_id,agreement_hash);
  entry_id:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(eid,null,'A','portrait','A3','',297,420,false,null,null);a:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(eid,null,'B','portrait','A3','',297,420,false,null,null);b:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(eid,null,'C','portrait','A3','',297,420,false,null,null);c:=(result->>'id')::uuid;
  path_a:=eid::text||'/'||mid::text||'/'||a::text||'/original.jpg';
  path_b:=eid::text||'/'||mid::text||'/'||b::text||'/original.jpg';
  path_c:=eid::text||'/'||mid::text||'/'||c::text||'/original.jpg';
  insert into storage.objects(bucket_id,name,metadata) values
    ('exhibition-originals',path_a,'{"mimetype":"image/jpeg"}'),('exhibition-originals',path_b,'{"mimetype":"image/jpeg"}'),
    ('exhibition-originals',path_c,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(eid,a,'A','portrait','A3','',297,420,false,path_a,repeat('a',64));
  perform public.save_exhibition_work_draft_v2(eid,b,'B','portrait','A3','',297,420,false,path_b,repeat('b',64));
  perform public.save_exhibition_work_draft_v2(eid,c,'C','portrait','A3','',297,420,false,path_c,repeat('c',64));
  perform public.submit_exhibition_work_batch_v2(eid,array[a,b,c]);
  select work.current_submission_snapshot_id into sa from public.exhibition_works work where work.id=a;
  select work.current_submission_snapshot_id into sb from public.exhibition_works work where work.id=b;
  select work.current_submission_snapshot_id into sc from public.exhibition_works work where work.id=c;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(sa,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(sb,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(sc,'accepted','{}','',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase9_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A','self','A','digital','','Camera','','','provided','説明A','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(a);ca:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(b,'作者B','self','B','digital','','Camera','','','provided','説明B','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(b);cb:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(c,'作者C','self','C','digital','','Camera','','','provided','説明C','','none','',null,'none','');
  result:=public.submit_exhibition_caption_v2(c);cc:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(ca,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(cb,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(cc,'accepted','{}','',null);
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(eid,'Main',1,'draft',true,admin_email) returning id into layout_id;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order,z_order) values
    (layout_id,a,wall1,0,2000,1,1),(layout_id,b,wall1,500,2000,2,2),(layout_id,c,wall1,1000,2000,3,3);
  result:=public.admin_finalize_exhibition_layout_v2(layout_id,'phase9');final_id:=(result->>'finalizationId')::uuid;
  select jsonb_agg(to_jsonb(item) order by item.display_no) into plan_before from public.exhibition_layout_finalization_items item where item.finalization_id=final_id;

  -- Actualとは独立したExport/Publication/Survey履歴を先に固定する。
  result:=public.admin_finalize_exhibition_export_v2(eid,'E1');export1:=(result->>'exportVersionId')::uuid;
  result:=public.admin_finalize_exhibition_publication_v2(export1,'P1');publication1:=(result->>'publicationVersionId')::uuid;
  perform public.admin_set_current_exhibition_publication_v2(publication1,'公開');
  response1:=public.submit_exhibition_survey('2099-phase9',repeat('phase9-token-',4),'ja','survey',jsonb_build_array(jsonb_build_object('work_id',a)));
  select to_jsonb(export_version) into export_before from public.exhibition_export_versions export_version where export_version.id=export1;
  select to_jsonb(publication) into publication_before from public.exhibition_publication_versions publication where publication.id=publication1;
  select to_jsonb(response) into survey_before from public.exhibition_survey_responses response where response.id=response1;

  if not exists(select 1 from public.admin_get_exhibition_actual_actions_v2(eid) action where action.action_type='actual_record_missing') then raise exception 'Actual未作成Actionが表示されません。'; end if;
  result:=public.admin_initialize_exhibition_actual_v2(final_id,null,'','draft');actual1:=(result->>'actualVersionId')::uuid;
  if (select count(*) from public.exhibition_actual_items item where item.actual_version_id=actual1 and item.actual_state='unconfirmed')<>3 then raise exception '初期Actualが全件unconfirmedではありません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_actual_actions_v2(eid) action where action.action_type='actual_unconfirmed') then raise exception 'Actual Actionが表示されません。'; end if;
  begin perform public.admin_initialize_exhibition_actual_v2(final_id,null,'','duplicate');raise exception '重複Draftを作成できました。';exception when others then if sqlerrm='重複Draftを作成できました。' then raise;end if;end;
  begin perform public.admin_finalize_exhibition_actual_v2(actual1,'invalid');raise exception 'unconfirmedを確定できました。';exception when others then if sqlerrm='unconfirmedを確定できました。' then raise;end if;end;
  if (select actual.state from public.exhibition_actual_versions actual where actual.id=actual1)<>'draft' then raise exception '失敗した確定が部分反映されました。'; end if;
  select item.id into ia from public.exhibition_actual_items item where item.actual_version_id=actual1 and item.work_id=a;
  select item.id into ib from public.exhibition_actual_items item where item.actual_version_id=actual1 and item.work_id=b;
  select item.id into ic from public.exhibition_actual_items item where item.actual_version_id=actual1 and item.work_id=c;
  perform public.admin_update_exhibition_actual_item_v2(ia,'exhibited',wall1,0,2000,1,sa,ca,false,'');
  perform public.admin_update_exhibition_actual_item_v2(ib,'not_exhibited',null,null,null,null,sb,cb,false,'欠席');
  perform public.admin_update_exhibition_actual_item_v2(ic,'exhibited',wall2,1200,1900,1,sc,null,true,'現場で壁面変更・Caption例外');
  if exists(select 1 from public.admin_get_exhibition_actual_readiness_v2(actual1) readiness where not readiness.ready) then raise exception 'Actual readinessが解消されません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_actual_actions_v2(eid) action where action.action_type='actual_finalize_ready') then raise exception 'Actual FINAL Actionが表示されません。'; end if;
  begin perform public.admin_update_exhibition_actual_item_v2(ia,'exhibited',wall1,0,2000,1,sa,cb,false,'');raise exception 'stale/mismatched Captionを設定できました。';exception when others then if sqlerrm='stale/mismatched Captionを設定できました。' then raise;end if;end;
  result:=public.admin_finalize_exhibition_actual_v2(actual1,'現場確認');
  begin perform public.admin_finalize_exhibition_actual_v2(actual1,'duplicate');raise exception 'Actualを重複確定できました。';exception when others then if sqlerrm='Actualを重複確定できました。' then raise;end if;end;
  if (result->>'exhibitedCount')::integer<>2 or (result->>'notExhibitedCount')::integer<>1 then raise exception 'Actual集計が不正です。'; end if;
  if (select count(*) from jsonb_array_elements((public.admin_get_finalized_exhibition_actual_v2(eid,null))->'items'))<>2 then raise exception 'Authoritative Actual setがA/Cの2件ではありません。'; end if;
  if exists(select 1 from jsonb_array_elements((public.admin_get_finalized_exhibition_actual_v2(eid,null))->'items')x where x->>'work_id'=b::text) then raise exception '非展示Bがauthoritative setに含まれました。'; end if;
  if not exists(select 1 from public.exhibition_work_display_numbers number where number.work_id=b and number.display_no=2) or exists(select 1 from public.exhibition_work_display_numbers number where number.event_id=eid and number.display_no=2 and number.work_id<>b) then raise exception 'Bのdisplay_no 2が再利用されました。'; end if;
  if (select jsonb_agg(to_jsonb(item) order by item.display_no) from public.exhibition_layout_finalization_items item where item.finalization_id=final_id) is distinct from plan_before then raise exception 'ActualがPlanを変更しました。'; end if;
  if (select to_jsonb(export_version) from public.exhibition_export_versions export_version where export_version.id=export1) is distinct from export_before then raise exception 'ActualがExportを変更しました。'; end if;
  if (select to_jsonb(publication) from public.exhibition_publication_versions publication where publication.id=publication1) is distinct from publication_before then raise exception 'ActualがPublicationを変更しました。'; end if;
  if (select to_jsonb(response) from public.exhibition_survey_responses response where response.id=response1) is distinct from survey_before then raise exception 'ActualがSurveyを変更しました。'; end if;
  begin update public.exhibition_actual_items item set note='改変' where item.id=ia;raise exception '確定Actual Itemを変更できました。';exception when others then if sqlerrm='確定Actual Itemを変更できました。' then raise;end if;end;
  begin update public.exhibition_actual_versions actual set note='改変' where actual.id=actual1;raise exception '確定Actual Versionを変更できました。';exception when others then if sqlerrm='確定Actual Versionを変更できました。' then raise;end if;end;
  begin perform public.admin_initialize_exhibition_actual_v2(final_id,null,'','bypass');raise exception '理由なし新Versionを作成できました。';exception when others then if sqlerrm='理由なし新Versionを作成できました。' then raise;end if;end;
  result:=public.admin_initialize_exhibition_actual_v2(final_id,actual1,'事実訂正','V2');actual2:=(result->>'actualVersionId')::uuid;
  perform public.admin_finalize_exhibition_actual_v2(actual2,'訂正確認');
  if (select actual.state from public.exhibition_actual_versions actual where actual.id=actual1)<>'finalized' or (select actual.correction_of_id from public.exhibition_actual_versions actual where actual.id=actual2)<>actual1 then raise exception '訂正版がV1を保持していません。'; end if;
  if (select count(*) from public.exhibition_workflow_audit_logs audit where audit.event_id=v.eid and audit.action in('actual_draft_initialized','actual_correction_draft_initialized','actual_finalized'))<>4 then raise exception 'Actual Auditが不足しています。'; end if;
  if exists(select 1 from public.admin_get_exhibition_actual_actions_v2(eid)) then raise exception 'Actual確定後もActionが残っています。'; end if;
end $$;

-- 一般部員はActualを操作・列挙できない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase9_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_initialize_exhibition_actual_v2(gen_random_uuid(),null,'','');raise exception 'MemberがActualを初期化できました。';exception when others then if sqlerrm='MemberがActualを初期化できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_actual_versions) or exists(select 1 from public.exhibition_actual_items) then raise exception 'MemberがActual履歴を列挙できました。'; end if;
end $$;
reset role;

-- Legacy EventにはActualを自動生成・要求しない。
do $$ begin
  if exists(select 1 from public.exhibition_actual_versions v join public.events e on e.id=v.event_id where e.exhibition_workflow_version<>2) then raise exception 'Legacy EventへActualが作成されました。'; end if;
end $$;

rollback;
