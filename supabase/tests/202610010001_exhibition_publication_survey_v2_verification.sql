-- Phase 8 immutable Publication / UUID Survey verification。全変更はROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text;member_id uuid;event_id uuid;entry_id uuid;venue_id uuid;wall_id uuid;layout_id uuid;
  a uuid;b uuid;wa uuid;wb uuid;ca uuid;cb uuid;export1 uuid;export2 uuid;publication1 uuid;publication2 uuid;response1 uuid;
  agreement_id uuid;agreement_hash text;path_a text;path_b text;
  result jsonb;public_data jsonb;p1_before jsonb;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values('member-998001','__phase8_member__@example.invalid','Phase 8','B4',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase8_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Wall',1,5000,3000) returning id into wall_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id,exhibition_key,
    site_title,site_title_en,site_description,site_description_en,place_en,dm_image_path,site_status,survey_enabled,survey_opens_at,survey_closes_at)
  values('saved',true,'exhibition','__phase8_v2__','Phase 8',now()+interval '10 days',now()+interval '11 days','検証会場',admin_email,
    now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id,'2099-phase8',
    '公開展','Public Exhibition','説明','Description','Venue','2099-phase8/dm.webp','draft',true,
    now()-interval '1 hour',now()+interval '1 hour') returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase8','Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.event_id and agreement.active;

  -- Application / Work / Captionは実運用と同じv2 RPC経路で構築する。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase8_member__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,2,'real_name','','',agreement_id,agreement_hash);
  entry_id:=(result->>'entryId')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'A','portrait','A3','',297,420,true,null,null);
  a:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'B','landscape','A3','',420,297,false,null,null);
  b:=(result->>'id')::uuid;
  path_a:=event_id::text||'/'||member_id::text||'/'||a::text||'/original.jpg';
  path_b:=event_id::text||'/'||member_id::text||'/'||b::text||'/original.jpg';
  insert into storage.objects(bucket_id,name,metadata) values
    ('exhibition-originals',path_a,'{"mimetype":"image/jpeg"}'),
    ('exhibition-originals',path_b,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,a,'A','portrait','A3','',297,420,true,path_a,repeat('a',64));
  perform public.save_exhibition_work_draft_v2(event_id,b,'B','landscape','A3','',420,297,false,path_b,repeat('b',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[a,b]);
  select work.current_submission_snapshot_id into wa from public.exhibition_works work where work.id=a;
  select work.current_submission_snapshot_id into wb from public.exhibition_works work where work.id=b;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(wa,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(wb,'accepted','{}','',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase8_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A','self','Work A','digital','','Camera A','','','provided','説明A','','none','',null);
  result:=public.submit_exhibition_caption_v2(a);ca:=(result->>'snapshotId')::uuid;
  perform public.save_exhibition_caption_draft_v2(b,'作者B','self','Work B','film','','Camera B','','Film B','provided','説明B','','none','',null);
  result:=public.submit_exhibition_caption_v2(b);cb:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(ca,'accepted','{}','',null);
  perform public.admin_review_exhibition_caption_v2(cb,'accepted','{}','',null);
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(event_id,'Main',1,'draft',true,admin_email) returning id into layout_id;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order) values
    (layout_id,a,wall_id,0,2000,1),(layout_id,b,wall_id,500,2000,2);
  perform public.admin_finalize_exhibition_layout_v2(layout_id,'phase8');
  result:=public.admin_finalize_exhibition_export_v2(event_id,'Export V1');export1:=(result->>'exportVersionId')::uuid;
  if not exists(select 1 from public.admin_get_exhibition_publication_actions_v2(event_id) action where action.action_type='publication_refresh_available') then raise exception 'Publication Actionが表示されません。'; end if;

  -- consent=trueの公開派生画像がない間はPublicationを拒否。Bの不同意は阻害しない。
  if not exists(select 1 from public.admin_get_exhibition_publication_readiness_v2(export1) readiness where readiness.work_id=a and not readiness.ready and 'Approved public derivative image is missing'=any(readiness.reasons)) then raise exception '公開画像不足blockがありません。'; end if;
  begin perform public.admin_finalize_exhibition_publication_v2(export1,'invalid');raise exception '不完全ExportからPublicationを作成できました。';exception when others then if sqlerrm='不完全ExportからPublicationを作成できました。' then raise;end if;end;
  begin perform public.admin_set_exhibition_public_image_v2(a,'private/original-a');raise exception 'Public Storageにないpathを登録できました。';exception when others then if sqlerrm='Public Storageにないpathを登録できました。' then raise;end if;end;
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-public',event_id::text||'/'||member_id::text||'/'||a::text||'/public.webp','{"mimetype":"image/webp"}');
  perform public.admin_set_exhibition_public_image_v2(a,event_id::text||'/'||member_id::text||'/'||a::text||'/public.webp');
  if exists(select 1 from public.admin_get_exhibition_publication_readiness_v2(export1) readiness where not readiness.ready) then raise exception 'Publication readinessが解消されません。'; end if;
  result:=public.admin_finalize_exhibition_publication_v2(export1,'P1');publication1:=(result->>'publicationVersionId')::uuid;
  if not exists(select 1 from public.exhibition_publication_versions publication where publication.id=publication1 and publication.source_export_version_id=export1 and publication.published_by=admin_email and publication.published_at is not null) then raise exception 'Publication source/publisher provenanceが不正です。'; end if;
  if not exists(select 1 from public.exhibition_publication_items item where item.publication_version_id=publication1 and item.work_id=a and item.display_no=1 and item.image_state='public_image' and item.public_image_path is not null and item.english_title_provenance='member_snapshot') then raise exception 'A公開画像・display_no・英語title provenanceが固定されません。'; end if;
  if not exists(select 1 from public.exhibition_publication_items item where item.publication_version_id=publication1 and item.work_id=b and item.display_no=2 and item.image_state='no_image' and item.public_image_path is null and item.source_export_item_id is not null and item.work_submission_snapshot_id=wb and item.caption_submission_snapshot_id=cb) then raise exception 'B NO IMAGEまたはprovenanceが不正です。'; end if;
  select jsonb_agg(to_jsonb(item) order by item.public_order) into p1_before from public.exhibition_publication_items item where item.publication_version_id=publication1;
  perform public.admin_set_current_exhibition_publication_v2(publication1,'P1公開');
  begin
    update public.events event set current_publication_version_id=null where event.id=v.event_id;
    raise exception 'Current Publication pointerを直接変更できました。';
  exception when others then
    if sqlerrm='Current Publication pointerを直接変更できました。' then raise; end if;
  end;
  public_data:=public.get_public_exhibition('2099-phase8');
  if jsonb_array_length(public_data->'works')<>2 then raise exception 'NO IMAGE Workが公開datasetから欠落しました。'; end if;
  if (select x->>'publicImagePath' from jsonb_array_elements(public_data->'works')x where x->>'workUuid'=b::text) is not null then raise exception 'Bの画像pathが公開されました。'; end if;
  if public_data::text like '%private/original-b%' then raise exception 'Bのoriginal pathが公開されました。'; end if;

  -- Current Work上の公開派生画像を変更しても、公開済みP1は再解釈されない。
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-public',event_id::text||'/'||member_id::text||'/'||a::text||'/public-v2.webp','{"mimetype":"image/webp"}');
  perform public.admin_set_exhibition_public_image_v2(a,event_id::text||'/'||member_id::text||'/'||a::text||'/public-v2.webp');
  public_data:=public.get_public_exhibition('2099-phase8');
  if (select x->>'publicImagePath' from jsonb_array_elements(public_data->'works')x where x->>'workUuid'=a::text)
     <>event_id::text||'/'||member_id::text||'/'||a::text||'/public.webp' then raise exception 'Working Data変更でP1公開画像が変化しました。'; end if;

  begin perform public.submit_exhibition_survey('2099-phase8',repeat('display-no-',4),'ja','invalid',jsonb_build_array(jsonb_build_object('work_id','1')));raise exception 'display_noをSurvey identityとして使用できました。';exception when others then if sqlerrm='display_noをSurvey identityとして使用できました。' then raise;end if;end;
  response1:=public.submit_exhibition_survey('2099-phase8',repeat('token-phase8-',4),'ja','全体感想',
    jsonb_build_array(jsonb_build_object('work_id',a,'comment','A'),jsonb_build_object('work_id',b,'comment','B')));
  if not exists(select 1 from public.exhibition_survey_responses response where response.id=response1 and response.publication_version_id=publication1 and response.workflow_version=2 and response.respondent_hash=encode(extensions.digest(repeat('token-phase8-',4),'sha256'),'hex') and char_length(response.respondent_hash)=64) then raise exception 'Survey provenance/hashが不正です。'; end if;
  if (select count(*) from public.exhibition_survey_selections selection where selection.response_id=response1 and selection.work_id in(a,b))<>2 then raise exception 'UUID selectionsが保存されません。'; end if;
  begin perform public.submit_exhibition_survey('2099-phase8',repeat('token-phase8-',4),'ja','duplicate',jsonb_build_array(jsonb_build_object('work_id',a)));raise exception '重複回答できました。';exception when unique_violation then null;end;

  -- 新しいExport/PublicationはP1/R1を書き換えない。pointerだけ切替可能。
  result:=public.admin_finalize_exhibition_export_v2(event_id,'Export V2');export2:=(result->>'exportVersionId')::uuid;
  result:=public.admin_finalize_exhibition_publication_v2(export2,'P2');publication2:=(result->>'publicationVersionId')::uuid;
  if exists(select 1 from public.admin_get_exhibition_publication_actions_v2(event_id) action where action.action_type='publication_refresh_available') then raise exception 'Publication作成後もActionが残っています。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_publication_actions_v2(event_id) action where action.action_type='publication_switch_available') then raise exception 'Current切替Actionが表示されません。'; end if;
  if (public.get_public_exhibition('2099-phase8')->>'publicationVersionId')<>publication1::text then raise exception '未公開P2がCurrent切替前に露出しました。'; end if;
  perform public.admin_set_current_exhibition_publication_v2(publication2,'P2公開');
  if exists(select 1 from public.admin_get_exhibition_publication_actions_v2(event_id)) then raise exception 'Current切替後もPublication Actionが残っています。'; end if;
  if (select event.current_publication_version_id from public.events event where event.id=v.event_id)<>publication2 then raise exception 'Current pointerがP2ではありません。'; end if;
  if (select jsonb_agg(to_jsonb(item) order by item.public_order) from public.exhibition_publication_items item where item.publication_version_id=publication1) is distinct from p1_before then raise exception 'P2作成でP1が変化しました。'; end if;
  if (select response.publication_version_id from public.exhibition_survey_responses response where response.id=response1)<>publication1 then raise exception 'P2切替でR1 provenanceが変化しました。'; end if;
  begin update public.exhibition_publication_versions publication set note='改変' where publication.id=publication1;raise exception 'Publication Versionを変更できました。';exception when others then if sqlerrm='Publication Versionを変更できました。' then raise;end if;end;
  begin update public.exhibition_publication_items item set title_ja='改変' where item.publication_version_id=publication1;raise exception 'Publication Itemを変更できました。';exception when others then if sqlerrm='Publication Itemを変更できました。' then raise;end if;end;
  if (select count(*) from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action in('public_publication_finalized','current_publication_switched'))<>4 then raise exception 'Publication Auditが不足しています。'; end if;
end $$;

-- 一般部員は作成・切替不可、anonは安全な公開RPCとSurveyのみ。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase8_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_finalize_exhibition_publication_v2(gen_random_uuid(),'forged');raise exception 'MemberがPublicationを作成できました。';exception when others then if sqlerrm='MemberがPublicationを作成できました。' then raise;end if;end;
  begin perform public.admin_set_current_exhibition_publication_v2(gen_random_uuid(),'forged');raise exception 'MemberがCurrentを変更できました。';exception when others then if sqlerrm='MemberがCurrentを変更できました。' then raise;end if;end;
  if exists(select 1 from public.exhibition_publication_items) then raise exception 'MemberがPublication Itemsを列挙できました。'; end if;
end $$;
reset role;

set local role anon;
do $$ declare d jsonb;begin
  d:=public.get_public_exhibition('2099-phase8');
  if d is null or d->>'publicationVersionNo'<>'2' then raise exception 'anonがCurrent Publicationを取得できません。'; end if;
  if d::text like '%private/original%' or d::text like '%caption_submission_snapshot_id%' then raise exception '公開RPCにprivate provenanceが露出しました。'; end if;
  if not exists(select 1 from jsonb_array_elements(d->'works') work where work->>'imageState'='no_image' and work->'publicImagePath'='null'::jsonb) then
    raise exception 'anon公開RPCでNO IMAGE境界を確認できません。';
  end if;
  begin
    perform 1 from public.exhibition_export_items limit 1;
    raise exception 'anonがExport Itemを直接参照できました。';
  exception
    when insufficient_privilege then null;
    when others then raise;
  end;
  begin
    perform 1 from public.exhibition_publication_items limit 1;
    raise exception 'anonがPublication Itemを直接参照できました。';
  exception
    when insufficient_privilege then null;
    when others then raise;
  end;
end $$;
reset role;

-- Legacy行・v1 discriminatorは変更されない。
do $$ declare legacy_count integer;begin
  select count(*) into legacy_count from public.exhibition_survey_responses response where response.workflow_version=1;
  if exists(select 1 from public.exhibition_survey_responses response where response.workflow_version=1 and response.publication_version_id is not null) then raise exception 'Legacy responseへPublicationが付与されました。'; end if;
end $$;

rollback;
