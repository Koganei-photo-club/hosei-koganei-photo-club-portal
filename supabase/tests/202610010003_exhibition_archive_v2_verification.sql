-- Phase 10 immutable Archive verification。全変更はROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text;mid uuid;eid uuid;entry_id uuid;venue_id uuid;wall1 uuid;wall2 uuid;layout_id uuid;final_id uuid;
  a uuid;b uuid;c uuid;sa uuid;sb uuid;sc uuid;ca uuid;ca_other uuid;cb uuid;cc uuid;derivation_a uuid;actual1 uuid;actual2 uuid;archive1 uuid;archive2 uuid;export1 uuid;publication1 uuid;publication2 uuid;response1 uuid;response2 uuid;legacy_archive uuid;legacy_event uuid;
  ia uuid;ib uuid;ic uuid;ib2 uuid;result jsonb;plan_before jsonb;export_before jsonb;publication_before jsonb;survey_before jsonb;archive1_before jsonb;
  agreement_id uuid;agreement_hash text;caption_case uuid;path_a text;path_b text;path_c text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values('member-998003','__phase10_member__@example.invalid','Phase 10','B4',true) returning id into mid;
  insert into public.membership_years(member_id,fiscal_year,active) values(mid,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase10_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Plan Wall',1,6000,3000) returning id into wall1;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Actual Wall',2,6000,3000) returning id into wall2;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,exhibition_key,
    site_title,site_description,dm_image_path,site_status,survey_enabled,survey_opens_at,survey_closes_at)
  values('saved',true,'exhibition','__phase10_v2__','Phase 10',now()-interval '2 hours',now()+interval '2 hours','会場',admin_email,
    now()-interval '3 hours',3,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id,'2099-phase10',
    '公開展','説明','2099-phase10/dm.webp','draft',true,now()-interval '1 hour',now()+interval '1 hour') returning id into eid;
  perform public.admin_activate_exhibition_workflow_v2(eid,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase10','Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.eid and agreement.active;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase10_member__@example.invalid','role','authenticated')::text,true);
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

  -- AはActual/Archive用Snapshotと、Export用の最新Snapshotを正式な再編集経路で分ける。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase10_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A','organizer','','digital','','Camera','','','provided','説明A','','none','',null);
  result:=public.submit_exhibition_caption_v2(a);ca:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(b,'作者B','self','B','digital','','Camera','','','provided','説明B','','none','',null);
  result:=public.submit_exhibition_caption_v2(b);cb:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(c,'作者C','self','C','digital','','Camera','','','provided','説明C','','none','',null);
  result:=public.submit_exhibition_caption_v2(c);cc:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(ca,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(cb,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(cc,'accepted','{}','',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase10_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_caption_reedit_v2(a,'Export用別案');caption_case:=(result->>'caseId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_caption_reedit_v2(caption_case,true,'許可',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase10_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A別案','organizer','','digital','','Camera','','','provided','説明A別案','','none','',null);
  result:=public.submit_exhibition_caption_v2(a);ca_other:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(ca_other,'accepted','{}','',null);
  perform public.admin_set_exhibition_caption_organizer_title_v2(ca_other,'Wrong snapshot title','別Caption Snapshot用');
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(eid,'Main',1,'draft',true,admin_email) returning id into layout_id;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order,z_order) values
    (layout_id,a,wall1,0,2000,1,1),(layout_id,b,wall1,500,2000,2,2),(layout_id,c,wall1,1000,2000,3,3);
  result:=public.admin_finalize_exhibition_layout_v2(layout_id,'phase10');final_id:=(result->>'finalizationId')::uuid;
  select jsonb_agg(to_jsonb(i) order by display_no) into plan_before from public.exhibition_layout_finalization_items i where finalization_id=final_id;

  -- Actualとは独立したExport/Publication/Survey履歴を先に固定する。
  result:=public.admin_finalize_exhibition_export_v2(eid,'E1');export1:=(result->>'exportVersionId')::uuid;
  result:=public.admin_finalize_exhibition_publication_v2(export1,'P1');publication1:=(result->>'publicationVersionId')::uuid;
  perform public.admin_set_current_exhibition_publication_v2(publication1,'公開');
  response1:=public.submit_exhibition_survey('2099-phase10',repeat('phase10-token-',4),'ja','survey',jsonb_build_array(jsonb_build_object('work_id',b)));
  select to_jsonb(x) into export_before from public.exhibition_export_versions x where id=export1;
  select to_jsonb(x) into publication_before from public.exhibition_publication_versions x where id=publication1;
  select to_jsonb(x) into survey_before from public.exhibition_survey_responses x where id=response1;

  if exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid)) then raise exception 'Actual確定前にArchive Actionが表示されました。'; end if;
  result:=public.admin_initialize_exhibition_actual_v2(final_id,null,'','draft');actual1:=(result->>'actualVersionId')::uuid;
  begin perform public.admin_get_exhibition_archive_readiness_v2(actual1);raise exception '未確定Actualのreadinessを取得できました。';exception when others then if sqlerrm='未確定Actualのreadinessを取得できました。' then raise;end if;end;
  begin perform public.admin_finalize_exhibition_archive_v2(actual1,'invalid');raise exception '未確定ActualをArchive化できました。';exception when others then if sqlerrm='未確定ActualをArchive化できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_archive_versions where event_id=eid) then raise exception '失敗したArchive作成が部分反映されました。'; end if;
  select id into ia from public.exhibition_actual_items where actual_version_id=actual1 and work_id=a;
  select id into ib from public.exhibition_actual_items where actual_version_id=actual1 and work_id=b;
  select id into ic from public.exhibition_actual_items where actual_version_id=actual1 and work_id=c;
  begin perform public.admin_update_exhibition_actual_item_v2(ic,'exhibited',wall2,1200,1900,1,sc,null,false,'');raise exception 'Captionなし・例外なしをActualへ設定できました。';exception when others then if sqlerrm='Captionなし・例外なしをActualへ設定できました。' then raise;end if;end;
  begin perform public.admin_update_exhibition_actual_item_v2(ia,'exhibited',wall1,0,2000,1,sb,cb,false,'');raise exception '別WorkのSnapshotをActualへ設定できました。';exception when others then if sqlerrm='別WorkのSnapshotをActualへ設定できました。' then raise;end if;end;
  perform public.admin_update_exhibition_actual_item_v2(ia,'exhibited',wall1,0,2000,1,sa,ca,false,'');
  perform public.admin_update_exhibition_actual_item_v2(ib,'not_exhibited',null,null,null,null,sb,cb,false,'欠席');
  perform public.admin_update_exhibition_actual_item_v2(ic,'exhibited',wall2,1200,1900,1,sc,null,true,'Captionなしで展示・現場確認');
  if exists(select 1 from public.admin_get_exhibition_actual_readiness_v2(actual1) where not ready) then raise exception 'Actual readinessが解消されません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_actual_actions_v2(eid) where action_type='actual_finalize_ready') then raise exception 'Actual FINAL Actionが表示されません。'; end if;
  begin perform public.admin_update_exhibition_actual_item_v2(ia,'exhibited',wall1,0,2000,1,sa,cb,false,'');raise exception 'stale/mismatched Captionを設定できました。';exception when others then if sqlerrm='stale/mismatched Captionを設定できました。' then raise;end if;end;
  result:=public.admin_finalize_exhibition_actual_v2(actual1,'現場確認');
  if (result->>'exhibitedCount')::integer<>2 or (result->>'notExhibitedCount')::integer<>1 then raise exception 'Actual集計が不正です。'; end if;
  if (select count(*) from public.exhibition_actual_items where actual_version_id=actual1)<>3
    or not exists(select 1 from public.exhibition_actual_items where actual_version_id=actual1 and work_id=a and actual_state='exhibited')
    or not exists(select 1 from public.exhibition_actual_items where actual_version_id=actual1 and work_id=b and actual_state='not_exhibited')
    or not exists(select 1 from public.exhibition_actual_items where actual_version_id=actual1 and work_id=c and actual_state='exhibited') then raise exception 'Actual V1のA/B/C明示結果が不正です。'; end if;
  if (select count(*) from jsonb_array_elements((public.admin_get_finalized_exhibition_actual_v2(eid,null))->'items'))<>2 then raise exception 'Authoritative Actual setがA/Cの2件ではありません。'; end if;
  if exists(select 1 from jsonb_array_elements((public.admin_get_finalized_exhibition_actual_v2(eid,null))->'items')x where x->>'work_id'=b::text) then raise exception '非展示Bがauthoritative setに含まれました。'; end if;
  if not exists(select 1 from public.exhibition_work_display_numbers where work_id=b and display_no=2) or exists(select 1 from public.exhibition_work_display_numbers where event_id=eid and display_no=2 and work_id<>b) then raise exception 'Bのdisplay_no 2が再利用されました。'; end if;
  if (select jsonb_agg(to_jsonb(i) order by display_no) from public.exhibition_layout_finalization_items i where finalization_id=final_id) is distinct from plan_before then raise exception 'ActualがPlanを変更しました。'; end if;
  if (select to_jsonb(x) from public.exhibition_export_versions x where id=export1) is distinct from export_before then raise exception 'ActualがExportを変更しました。'; end if;
  if (select to_jsonb(x) from public.exhibition_publication_versions x where id=publication1) is distinct from publication_before then raise exception 'ActualがPublicationを変更しました。'; end if;
  if (select to_jsonb(x) from public.exhibition_survey_responses x where id=response1) is distinct from survey_before then raise exception 'ActualがSurveyを変更しました。'; end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items where finalization_id=final_id and work_id=b and display_no=2)
    or not exists(select 1 from public.exhibition_actual_items where actual_version_id=actual1 and work_id=b and actual_state='not_exhibited')
    or not exists(select 1 from public.exhibition_publication_items where publication_version_id=publication1 and work_id=b)
    or not exists(select 1 from public.exhibition_survey_selections where response_id=response1 and work_id=b) then raise exception 'BのLayout/Actual/Publication/Survey provenanceを明示確認できません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid) where action_type='archive_refresh_available' and snapshot_id=actual1) then raise exception 'Archive作成Actionが表示されません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_archive_readiness_v2(actual1) where work_id=a and not ready and 'Organizer English title derivation is missing'=any(reasons)) then raise exception '運営英題derivation欠落をreadinessが検出しません。'; end if;
  begin perform public.admin_finalize_exhibition_archive_v2(actual1,'invalid');raise exception 'derivation欠落ActualをArchive化できました。';exception when others then if sqlerrm='derivation欠落ActualをArchive化できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_archive_versions where event_id=eid)
    or exists(select 1 from public.exhibition_workflow_audit_logs where event_id=eid and action='archive_finalized')
    or (select current_archive_version_id from public.events where id=eid) is not null then raise exception '失敗したArchive FINALがVersion/Audit/Currentを部分反映しました。'; end if;
  insert into public.exhibition_caption_english_title_derivations(work_id,source_caption_snapshot_id,version_no,english_title,created_by_identifier,reason)
    values(a,ca,2,'Organizer title A',admin_email,'Phase 10 verification') returning id into derivation_a;
  if exists(select 1 from public.admin_get_exhibition_archive_readiness_v2(actual1) where not ready) or (select count(*) from public.admin_get_exhibition_archive_readiness_v2(actual1))<>2 then raise exception 'Archive readinessがA/Cのready 2件ではありません。'; end if;
  result:=public.admin_finalize_exhibition_archive_v2(actual1,'A1');archive1:=(result->>'archiveVersionId')::uuid;
  if (result->>'versionNo')::integer<>1 or (result->>'itemCount')::integer<>2 then raise exception 'Archive A1集計が不正です。'; end if;
  if (select count(*) from public.exhibition_archive_items where archive_version_id=archive1)<>2
    or not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and work_id=a and display_no=1)
    or not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and work_id=c and display_no=3)
    or exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and work_id=b) then raise exception 'Archive A1のauthoritative setがA/Cではありません。'; end if;
  if not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and work_id=a
    and work_submission_snapshot_id=sa and caption_submission_snapshot_id=ca and effective_english_title='Organizer title A'
    and english_title_provenance='organizer_derivation' and english_title_derivation_id=derivation_a) then raise exception '運営英題のprovenanceが凍結されていません。'; end if;
  if not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and work_id=c
    and work_submission_snapshot_id=sc and caption_submission_snapshot_id is null and caption_exception
    and caption_exception_reason='Captionなしで展示・現場確認' and planned_wall_id=wall1 and actual_wall_id=wall2
    and planned_x_mm=1000 and actual_x_mm=1200) then raise exception 'Caption例外またはPlan/Actual差分が凍結されていません。'; end if;
  if exists(select 1 from public.exhibition_archive_items where archive_version_id=archive1 and (publication_consent or image_state<>'no_image' or public_image_path is not null))
    or coalesce((select jsonb_agg(to_jsonb(x))::text from public.exhibition_archive_items x where archive_version_id=archive1),'') like '%private/%' then raise exception '不同意作品から画像情報がArchiveへ漏れました。'; end if;
  if (select current_archive_version_id from public.events where id=eid) is not null then raise exception 'Archive作成だけでCurrentが自動変更されました。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid) where action_type='archive_switch_available' and snapshot_id=archive1) then raise exception 'Current切替Actionが表示されません。'; end if;
  perform public.admin_set_current_exhibition_archive_v2(archive1,'A1公開');
  if (select current_archive_version_id from public.events where id=eid)<>archive1 or exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid)) then raise exception 'A1 Current切替またはAction解消に失敗しました。'; end if;
  begin update public.events set current_archive_version_id=null where id=eid;raise exception 'Current Archiveを直接変更できました。';exception when others then if sqlerrm='Current Archiveを直接変更できました。' then raise;end if;end;
  begin perform public.admin_finalize_exhibition_archive_v2(actual1,'duplicate');raise exception '同一Actualから重複Archiveを作成できました。';exception when others then if sqlerrm='同一Actualから重複Archiveを作成できました。' then raise;end if;end;
  if (select count(*) from public.exhibition_archive_versions where event_id=eid)<>1 or (select count(*) from public.exhibition_archive_items where archive_version_id=archive1)<>2 then raise exception '重複失敗後のArchiveが部分反映されました。'; end if;
  begin update public.exhibition_archive_items set title_ja='改変' where archive_version_id=archive1 and work_id=a;raise exception 'Archive Itemを変更できました。';exception when others then if sqlerrm='Archive Itemを変更できました。' then raise;end if;end;
  begin update public.exhibition_archive_versions set note='改変' where id=archive1;raise exception 'Archive Versionを変更できました。';exception when others then if sqlerrm='Archive Versionを変更できました。' then raise;end if;end;
  begin delete from public.exhibition_archive_versions where id=archive1;raise exception 'Archive Versionを削除できました。';exception when others then if sqlerrm='Archive Versionを削除できました。' then raise;end if;end;
  begin delete from public.exhibition_archive_items where archive_version_id=archive1;raise exception 'Archive Itemを削除できました。';exception when others then if sqlerrm='Archive Itemを削除できました。' then raise;end if;end;
  select jsonb_build_object('version',(select to_jsonb(x) from public.exhibition_archive_versions x where id=archive1),'items',(select jsonb_agg(to_jsonb(x) order by display_no) from public.exhibition_archive_items x where archive_version_id=archive1)) into archive1_before;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set title='後から変更したWorking Work名' where id=a;
  perform set_config('app.exhibition_work_rpc','off',true);
  update public.exhibition_caption_working_data set display_name='後から変更した作者名',updated_at=now() where work_id=a;
  result:=public.admin_finalize_exhibition_publication_v2(export1,'P2');publication2:=(result->>'publicationVersionId')::uuid;
  response2:=public.submit_exhibition_survey('2099-phase10',repeat('phase10-later-',4),'en','later survey',jsonb_build_array(jsonb_build_object('work_id',c)));
  if jsonb_build_object('version',(select to_jsonb(x) from public.exhibition_archive_versions x where id=archive1),'items',(select jsonb_agg(to_jsonb(x) order by display_no) from public.exhibition_archive_items x where archive_version_id=archive1)) is distinct from archive1_before then raise exception 'Working Data/Publication/Survey追加によりArchive A1が変化しました。'; end if;

  begin perform public.admin_initialize_exhibition_actual_v2(final_id,null,'','bypass');raise exception '理由なし新Versionを作成できました。';exception when others then if sqlerrm='理由なし新Versionを作成できました。' then raise;end if;end;
  result:=public.admin_initialize_exhibition_actual_v2(final_id,actual1,'事実訂正','V2');actual2:=(result->>'actualVersionId')::uuid;
  select id into ib2 from public.exhibition_actual_items where actual_version_id=actual2 and work_id=b;
  perform public.admin_update_exhibition_actual_item_v2(ib2,'exhibited',wall1,500,2000,2,sb,cb,false,'訂正で展示確認');
  perform public.admin_finalize_exhibition_actual_v2(actual2,'訂正確認');
  if (select state from public.exhibition_actual_versions where id=actual1)<>'finalized' or (select correction_of_id from public.exhibition_actual_versions where id=actual2)<>actual1 then raise exception '訂正版がV1を保持していません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid) where action_type='archive_refresh_available' and snapshot_id=actual2) then raise exception 'Actual V2用Archive更新Actionが表示されません。'; end if;
  if jsonb_build_object('version',(select to_jsonb(x) from public.exhibition_archive_versions x where id=archive1),'items',(select jsonb_agg(to_jsonb(x) order by display_no) from public.exhibition_archive_items x where archive_version_id=archive1)) is distinct from archive1_before then raise exception 'Actual V2作成によりArchive A1が変化しました。'; end if;
  result:=public.admin_finalize_exhibition_archive_v2(actual2,'A2');archive2:=(result->>'archiveVersionId')::uuid;
  if (result->>'versionNo')::integer<>2 or (result->>'itemCount')::integer<>3 then raise exception 'Archive A2集計が不正です。'; end if;
  if (select count(*) from public.exhibition_archive_items where archive_version_id=archive2)<>3
    or not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive2 and work_id=b and display_no=2 and source_actual_version_id=actual2)
    or (select count(*) from public.exhibition_archive_items where archive_version_id=archive1)<>2 then raise exception 'Archive A2またはA1履歴保持が不正です。'; end if;
  if not exists(select 1 from public.exhibition_archive_items where archive_version_id=archive2 and work_id=b and caption_submission_snapshot_id=cb
    and effective_english_title='B' and english_title_provenance='member_snapshot' and english_title_derivation_id is null) then raise exception 'Self英題またはCaption Snapshot provenanceが不正です。'; end if;
  if (select current_archive_version_id from public.events where id=eid)<>archive1
    or not exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid) where action_type='archive_switch_available' and snapshot_id=archive2) then raise exception 'A2作成後の明示切替待ち状態が不正です。'; end if;
  perform public.admin_set_current_exhibition_archive_v2(archive2,'A2公開');
  perform public.admin_set_current_exhibition_archive_v2(archive1,'A1へロールバック');
  perform public.admin_set_current_exhibition_archive_v2(archive2,'A2へ復帰');
  if (select current_archive_version_id from public.events where id=eid)<>archive2 or exists(select 1 from public.admin_get_exhibition_archive_actions_v2(eid)) then raise exception 'Current Archiveの切替/復帰に失敗しました。'; end if;
  if jsonb_build_object('version',(select to_jsonb(x) from public.exhibition_archive_versions x where id=archive1),'items',(select jsonb_agg(to_jsonb(x) order by display_no) from public.exhibition_archive_items x where archive_version_id=archive1)) is distinct from archive1_before then raise exception 'Current切替によりArchive A1が変化しました。'; end if;
  if (select jsonb_agg(to_jsonb(i) order by display_no) from public.exhibition_layout_finalization_items i where finalization_id=final_id) is distinct from plan_before
    or (select to_jsonb(x) from public.exhibition_export_versions x where id=export1) is distinct from export_before
    or (select to_jsonb(x) from public.exhibition_publication_versions x where id=publication1) is distinct from publication_before
    or (select to_jsonb(x) from public.exhibition_survey_responses x where id=response1) is distinct from survey_before then raise exception 'ArchiveがPlan/Export/Publication/Survey履歴を変更しました。'; end if;
  if (select count(*) from public.exhibition_workflow_audit_logs where event_id=v.eid and action='archive_finalized')<>2
    or (select count(*) from public.exhibition_workflow_audit_logs where event_id=v.eid and action='current_archive_switched')<>4 then raise exception 'Archive Audit件数が不正です。'; end if;

  -- Legacy Archiveは従来表のまま読み書きでき、v2 Actual/Archiveを要求されない。
  insert into public.archive_exhibitions(exhibition_key,title,published) values('__phase10_legacy__','Legacy Archive',true) returning id into legacy_archive;
  insert into public.archive_works(exhibition_id,owner_member_id,display_no,title,published) values(legacy_archive,mid,'1','Legacy Work',true);
  if not exists(select 1 from public.archive_exhibitions le join public.archive_works lw on lw.exhibition_id=le.id where le.id=legacy_archive and lw.title='Legacy Work') then raise exception 'Legacy Archiveを読み取れません。'; end if;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__phase10_legacy_event__','Phase 10 Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email)
  returning id into legacy_event;
  if (select exhibition_workflow_version from public.events where id=legacy_event)<>1
    or exists(select 1 from public.exhibition_actual_versions where event_id=legacy_event)
    or exists(select 1 from public.exhibition_archive_versions where event_id=legacy_event)
    or exists(select 1 from public.admin_get_exhibition_archive_actions_v2(legacy_event)) then raise exception 'v1 EventがActual/v2 Archiveを要求または生成されました。'; end if;
end $$;

-- 一般部員は内部Archiveを操作・列挙できない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase10_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_finalize_exhibition_archive_v2(gen_random_uuid(),'');raise exception 'MemberがArchiveを作成できました。';exception when others then if sqlerrm='MemberがArchiveを作成できました。' then raise;end if;end;
  begin perform public.admin_set_current_exhibition_archive_v2(gen_random_uuid(),'');raise exception 'MemberがCurrent Archiveを切替できました。';exception when others then if sqlerrm='MemberがCurrent Archiveを切替できました。' then raise;end if;end;
  begin update public.exhibition_archive_versions set note='member mutation';raise exception 'MemberがArchiveを変更できました。';exception when others then if sqlerrm='MemberがArchiveを変更できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_archive_versions) or exists(select 1 from public.exhibition_archive_items) then raise exception 'Memberが内部Archive履歴を列挙できました。'; end if;
end $$;
reset role;

-- AnonymousにもAdmin API/Internal Archiveを公開しない。
select set_config('request.jwt.claims',jsonb_build_object('role','anon')::text,true);
set local role anon;
do $$ begin
  begin perform public.admin_get_exhibition_archive_actions_v2(null);raise exception 'AnonymousがArchive APIを実行できました。';exception when others then if sqlerrm='AnonymousがArchive APIを実行できました。' then raise;end if;end;
  begin perform 1 from public.exhibition_archive_versions;raise exception 'Anonymousが内部Archiveを列挙できました。';exception when others then if sqlerrm='Anonymousが内部Archiveを列挙できました。' then raise;end if;end;
end $$;
reset role;

rollback;
