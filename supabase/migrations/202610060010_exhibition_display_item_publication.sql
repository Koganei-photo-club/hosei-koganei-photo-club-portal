-- Smartphone Phase 2 / Step 3: Display Item Export, Publication and Survey.

alter table public.exhibition_export_items
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column display_item_type text check(display_item_type is null or display_item_type in('regular_work','smartphone_group')),
  add column smartphone_group_version_id uuid references public.exhibition_smartphone_group_versions(id) on delete restrict,
  add column smartphone_work_count integer check(smartphone_work_count is null or smartphone_work_count>=1);
alter table public.exhibition_export_items alter column work_id drop not null;
alter table public.exhibition_export_items alter column work_submission_snapshot_id drop not null;
alter table public.exhibition_export_items alter column caption_submission_snapshot_id drop not null;
alter table public.exhibition_export_items add constraint exhibition_export_item_display_source_check check(
  (display_item_type is null and work_id is not null)
  or (display_item_type='regular_work' and display_item_id is not null and work_id is not null
      and smartphone_group_version_id is null and smartphone_work_count is null)
  or (display_item_type='smartphone_group' and display_item_id is not null and work_id is null
      and work_submission_snapshot_id is null and caption_submission_snapshot_id is null
      and smartphone_group_version_id is not null and smartphone_work_count>=1)
);
create unique index exhibition_export_items_display_item_unique
  on public.exhibition_export_items(export_version_id,display_item_id) where display_item_id is not null;

alter table public.exhibition_publication_items
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column display_item_type text check(display_item_type is null or display_item_type in('regular_work','smartphone_group')),
  add column smartphone_group_version_id uuid references public.exhibition_smartphone_group_versions(id) on delete restrict,
  add column smartphone_work_count integer check(smartphone_work_count is null or smartphone_work_count>=1);
alter table public.exhibition_publication_items alter column work_id drop not null;
alter table public.exhibition_publication_items alter column work_submission_snapshot_id drop not null;
alter table public.exhibition_publication_items alter column caption_submission_snapshot_id drop not null;
alter table public.exhibition_publication_items add constraint exhibition_publication_item_display_source_check check(
  (display_item_type is null and work_id is not null)
  or (display_item_type='regular_work' and display_item_id is not null and work_id is not null
      and smartphone_group_version_id is null and smartphone_work_count is null)
  or (display_item_type='smartphone_group' and display_item_id is not null and work_id is null
      and work_submission_snapshot_id is null and caption_submission_snapshot_id is null
      and smartphone_group_version_id is not null and smartphone_work_count>=1
      and publication_consent=false and image_state='no_image' and public_image_path is null)
);
create unique index exhibition_publication_items_display_item_unique
  on public.exhibition_publication_items(publication_version_id,display_item_id) where display_item_id is not null;

alter table public.exhibition_survey_selections add column id uuid default gen_random_uuid();
alter table public.exhibition_survey_selections drop constraint exhibition_survey_selections_pkey;
alter table public.exhibition_survey_selections add primary key(id);
alter table public.exhibition_survey_selections alter column work_id drop not null;
alter table public.exhibition_survey_selections
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column publication_item_id uuid references public.exhibition_publication_items(id) on delete restrict;
alter table public.exhibition_survey_selections add constraint exhibition_survey_selection_source_check check(
  (display_item_id is null and publication_item_id is null and work_id is not null)
  or (display_item_id is not null and publication_item_id is not null)
);
create unique index exhibition_survey_selections_response_work_unique
  on public.exhibition_survey_selections(response_id,work_id) where work_id is not null;
create unique index exhibition_survey_selections_response_display_unique
  on public.exhibition_survey_selections(response_id,display_item_id) where display_item_id is not null;
create index exhibition_survey_selections_display_item_idx on public.exhibition_survey_selections(display_item_id);

-- Readiness keeps its historical signature; smartphone_group rows use work_id=NULL.
create or replace function public.admin_get_exhibition_export_readiness_v2(p_event_id uuid)
returns table(work_id uuid,display_no integer,viewing_order integer,work_snapshot_id uuid,caption_snapshot_id uuid,
  layout_finalization_id uuid,layout_finalization_version integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。';end if;
  if not exists(select 1 from public.events where id=p_event_id and exhibition_workflow_version=2) then raise exception 'Workflow v2写真展が見つかりません。';end if;
  return query
  with latest as(select finalization.* from public.exhibition_layout_finalizations finalization where finalization.event_id=p_event_id order by finalization.finalization_version desc limit 1),
  regular_base as(
   select work_row.id work_uuid,work_row.workflow_state,work_row.current_accepted_snapshot_id,number_row.display_no,
    caption_data.state caption_state,caption_data.current_accepted_snapshot_id caption_id,
    caption_snapshot.work_submission_snapshot_id caption_work_snapshot_id,caption_snapshot.english_title_mode,caption_snapshot.member_english_title,
    final_item.viewing_order,final_item.work_submission_snapshot_id layout_work_snapshot_id,
    latest.id final_id,latest.finalization_version final_version,derivation.id derivation_id
   from public.exhibition_works work_row
   left join public.exhibition_work_display_numbers number_row on number_row.work_id=work_row.id
   left join public.exhibition_caption_working_data caption_data on caption_data.work_id=work_row.id
   left join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=caption_data.current_accepted_snapshot_id
   left join latest on true
   left join public.exhibition_layout_finalization_items final_item on final_item.finalization_id=latest.id and final_item.work_id=work_row.id
   left join lateral(select derivation_row.id from public.exhibition_caption_english_title_derivations derivation_row
    where derivation_row.source_caption_snapshot_id=caption_snapshot.id order by derivation_row.version_no desc limit 1) derivation on true
   where work_row.event_id=p_event_id and work_row.workflow_state<>'withdrawn'
  )
  select base.work_uuid,base.display_no,base.viewing_order,base.current_accepted_snapshot_id,base.caption_id,base.final_id,base.final_version,
   cardinality(reason_row.reasons)=0,coalesce(reason_row.reasons,'{}'::text[])
  from regular_base base cross join lateral(select array_remove(array[
   case when base.workflow_state<>'accepted' then 'Work not accepted' end,
   case when base.current_accepted_snapshot_id is null then 'No accepted Work Snapshot' end,
   case when base.display_no is null then 'No display number' end,
   case when base.final_id is null then 'No finalized Layout' end,
   case when base.viewing_order is null then 'Not in current finalized Layout' end,
   case when base.viewing_order is not null and base.layout_work_snapshot_id is distinct from base.current_accepted_snapshot_id
    and not coalesce(private.work_snapshots_physically_equal_v2(base.layout_work_snapshot_id,base.current_accepted_snapshot_id),false) then 'Layout requires reconfirmation' end,
   case when base.caption_id is null and base.caption_state is null then 'Caption not submitted' end,
   case when base.caption_id is null and base.caption_state='submitted' then 'Caption awaiting review' end,
   case when base.caption_id is null and base.caption_state='rejected' then 'Caption rejected' end,
   case when base.caption_id is null and base.caption_state is not null and base.caption_state not in('submitted','rejected') then 'Caption not accepted' end,
   case when base.caption_id is not null and base.caption_state<>'accepted' then 'Caption not accepted' end,
   case when base.caption_id is not null and base.caption_work_snapshot_id is distinct from base.current_accepted_snapshot_id then 'Caption belongs to older Work Snapshot' end,
   case when base.caption_id is not null and base.english_title_mode='self' and trim(coalesce(base.member_english_title,''))='' then 'Member English title missing' end,
   case when base.caption_id is not null and base.english_title_mode='organizer' and base.derivation_id is null then 'Organizer English title missing' end
  ]::text[],null) reasons) reason_row
  union all
  select null::uuid,final_item.display_no,final_item.viewing_order,null::uuid,null::uuid,latest.id,latest.finalization_version,
    cardinality(reason_row.reasons)=0,coalesce(reason_row.reasons,'{}'::text[])
  from latest join public.exhibition_layout_finalization_items final_item on final_item.finalization_id=latest.id
  join public.exhibition_display_items display_item on display_item.id=final_item.display_item_id and display_item.item_type='smartphone_group'
  left join public.exhibition_smartphone_group_versions group_version on group_version.id=final_item.smartphone_group_version_id
  cross join lateral(select array_remove(array[
    case when group_version.id is null or group_version.group_id<>display_item.smartphone_group_id or group_version.event_id<>p_event_id then 'Smartphone Group Version mismatch' end,
    case when not exists(select 1 from public.exhibition_smartphone_group_version_items version_item where version_item.group_version_id=group_version.id) then 'Smartphone Group is empty' end,
    case when final_item.occupied_width_mm<=0 or final_item.occupied_height_mm<=0 then 'Smartphone Group dimensions missing' end
  ]::text[],null) reasons) reason_row
  order by 3,2,1 nulls last;
end;$$;

create or replace function public.admin_finalize_exhibition_export_v2(p_event_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;finalization_row public.exhibition_layout_finalizations%rowtype;
  export_id uuid;next_version integer;actor text:=private.current_email();item_count integer;blocked integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into event_row from public.events where id=p_event_id for update;
 if event_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。';end if;
 perform pg_advisory_xact_lock(hashtextextended(event_row.id::text||':master_export',0));
 select * into finalization_row from public.exhibition_layout_finalizations where event_id=event_row.id order by finalization_version desc limit 1;
 if finalization_row.id is null or private.layout_requires_physical_reconfirmation_v2(event_row.id) then raise exception '現在のLayout FinalizationはExportに使用できません。';end if;
 select count(*) into blocked from public.admin_get_exhibition_export_readiness_v2(event_row.id) where not ready;
 if blocked>0 then raise exception 'FINAL Exportを作成できません。未解決項目: %件',blocked;end if;
 if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(event_row.id)) then raise exception 'Export対象Display Itemがありません。';end if;
 select coalesce(max(version_no),0)+1 into next_version from public.exhibition_export_versions where event_id=event_row.id and export_type='master_caption';
 insert into public.exhibition_export_versions(event_id,version_no,layout_finalization_id,layout_finalization_version,note,created_by)
 values(event_row.id,next_version,finalization_row.id,finalization_row.finalization_version,coalesce(p_note,''),actor) returning id into export_id;

 insert into public.exhibition_export_items(export_version_id,event_id,display_item_id,display_item_type,work_id,display_no,viewing_order,
  work_submission_snapshot_id,caption_submission_snapshot_id,english_title_derivation_id,title_ja,display_name,effective_english_title,
  english_title_mode,english_title_provenance,medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,
  instagram_qr_choice,instagram_qr_info,instagram_qr_path,publication_consent,orientation,print_size,print_size_detail,wall_id)
 select export_id,event_row.id,display_item.id,'regular_work',work_row.id,final_item.display_no,final_item.viewing_order,
  work_snapshot.id,caption_snapshot.id,derivation.id,work_snapshot.title,caption_snapshot.display_name,
  case when caption_snapshot.english_title_mode='self' then caption_snapshot.member_english_title else derivation.english_title end,
  caption_snapshot.english_title_mode,case when caption_snapshot.english_title_mode='self' then 'member_snapshot' else 'organizer_derivation' end,
  caption_snapshot.medium,caption_snapshot.medium_details,caption_snapshot.camera,caption_snapshot.lens,caption_snapshot.film,
  caption_snapshot.description_choice,caption_snapshot.description_ja,caption_snapshot.description_en,caption_snapshot.instagram_qr_choice,
  caption_snapshot.instagram_qr_info,caption_snapshot.instagram_qr_path,work_snapshot.publication_consent,work_snapshot.orientation,
  work_snapshot.print_size,work_snapshot.print_size_detail,final_item.wall_id
 from public.exhibition_layout_finalization_items final_item
 join public.exhibition_display_items display_item on display_item.id=final_item.display_item_id and display_item.item_type='regular_work'
 join public.exhibition_works work_row on work_row.id=display_item.regular_work_id and work_row.workflow_state='accepted'
 join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=work_row.current_accepted_snapshot_id
 join public.exhibition_caption_working_data caption_data on caption_data.work_id=work_row.id and caption_data.state='accepted'
 join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=caption_data.current_accepted_snapshot_id and caption_snapshot.work_submission_snapshot_id=work_snapshot.id
 left join lateral(select derivation_row.* from public.exhibition_caption_english_title_derivations derivation_row
   where derivation_row.source_caption_snapshot_id=caption_snapshot.id order by derivation_row.version_no desc limit 1) derivation on true
 where final_item.finalization_id=finalization_row.id
   and (final_item.work_submission_snapshot_id=work_snapshot.id or coalesce(private.work_snapshots_physically_equal_v2(final_item.work_submission_snapshot_id,work_snapshot.id),false));

 insert into public.exhibition_export_items(export_version_id,event_id,display_item_id,display_item_type,smartphone_group_version_id,
  smartphone_work_count,work_id,display_no,viewing_order,work_submission_snapshot_id,caption_submission_snapshot_id,
  title_ja,display_name,effective_english_title,english_title_mode,english_title_provenance,medium,medium_details,camera,lens,film,
  description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,publication_consent,orientation,print_size,print_size_detail,wall_id)
 select export_id,event_row.id,final_item.display_item_id,'smartphone_group',final_item.smartphone_group_version_id,
  (select count(*) from public.exhibition_smartphone_group_version_items version_item where version_item.group_version_id=final_item.smartphone_group_version_id),
  null,final_item.display_no,final_item.viewing_order,null,null,'スマートフォン撮影写真作品','匿名','',
  'self','member_snapshot','smartphone','2L判集合展示','','','','unnecessary','','','none','',false,
  'group','smartphone_group','',final_item.wall_id
 from public.exhibition_layout_finalization_items final_item
 join public.exhibition_display_items display_item on display_item.id=final_item.display_item_id and display_item.item_type='smartphone_group'
 where final_item.finalization_id=finalization_row.id;

 select count(*) into item_count from public.exhibition_export_items where export_version_id=export_id;
 if item_count<>(select count(*) from public.admin_get_exhibition_export_readiness_v2(event_row.id)) then raise exception 'Export Item件数が対象Display Item件数と一致しません。';end if;
 perform private.write_exhibition_workflow_audit(event_row.id,'export_version',export_id,'master_export_finalized','admin',actor,p_note,'{}',
  jsonb_build_object('versionNo',next_version,'layoutFinalizationId',finalization_row.id,'layoutFinalizationVersion',finalization_row.finalization_version,'itemCount',item_count));
 return jsonb_build_object('exportVersionId',export_id,'versionNo',next_version,'itemCount',item_count,'layoutFinalizationId',finalization_row.id);
end;$$;

create or replace function public.admin_get_exhibition_publication_readiness_v2(p_export_version_id uuid)
returns table(work_id uuid,display_no integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
declare export_row public.exhibition_export_versions%rowtype;event_row public.events%rowtype;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into export_row from public.exhibition_export_versions where id=p_export_version_id;
 select * into event_row from public.events where id=export_row.event_id;
 if export_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Exportが見つかりません。';end if;
 return query
 select item.work_id,item.display_no,cardinality(reason_row.reasons)=0,coalesce(reason_row.reasons,'{}'::text[])
 from public.exhibition_export_items item
 left join public.exhibition_works work_row on work_row.id=item.work_id
 left join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=item.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=item.caption_submission_snapshot_id
 left join public.exhibition_caption_working_data caption_data on caption_data.work_id=work_row.id
 left join public.exhibition_smartphone_group_versions group_version on group_version.id=item.smartphone_group_version_id
 cross join lateral(select array_remove(array[
   case when item.event_id<>export_row.event_id then 'Export provenance event mismatch' end,
   case when item.display_item_type='regular_work' and (work_snapshot.work_id<>item.work_id or caption_snapshot.work_id<>item.work_id) then 'Export snapshot provenance mismatch' end,
   case when item.display_item_type='regular_work' and work_row.workflow_state<>'accepted' then 'Work is no longer accepted' end,
   case when item.display_item_type='regular_work' and item.work_submission_snapshot_id is distinct from work_row.current_accepted_snapshot_id then 'A newer Work Export is required' end,
   case when item.display_item_type='regular_work' and caption_data.state is distinct from 'accepted' then 'Caption is no longer accepted' end,
   case when item.display_item_type='regular_work' and item.caption_submission_snapshot_id is distinct from caption_data.current_accepted_snapshot_id then 'A newer Caption Export is required' end,
   case when item.display_item_type='regular_work' and item.publication_consent and (not work_row.public_release or work_row.public_image_path is null) then 'Approved public derivative image is missing' end,
   case when item.display_item_type='regular_work' and (trim(item.title_ja)='' or trim(item.display_name)='' or trim(item.effective_english_title)='') then 'Required public caption value is missing' end,
   case when item.display_item_type='smartphone_group' and (group_version.id is null or group_version.event_id<>export_row.event_id or item.smartphone_work_count<1) then 'Smartphone Group provenance mismatch' end
 ]::text[],null) reasons) reason_row
 where item.export_version_id=export_row.id order by item.viewing_order;
end;$$;

create or replace function public.admin_finalize_exhibition_publication_v2(p_export_version_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare export_row public.exhibition_export_versions%rowtype;event_row public.events%rowtype;publication_id uuid;next_version integer;
 actor text:=private.current_email();blocked integer;item_count integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into export_row from public.exhibition_export_versions where id=p_export_version_id;
 select * into event_row from public.events where id=export_row.event_id for update;
 if export_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Exportが見つかりません。';end if;
 if nullif(trim(event_row.exhibition_key),'') is null or nullif(trim(event_row.site_title),'') is null
  or nullif(trim(event_row.site_description),'') is null or nullif(trim(event_row.place),'') is null or nullif(trim(event_row.dm_image_path),'') is null then
  raise exception '公開サイト基本情報またはDM画像が不足しています。';end if;
 perform pg_advisory_xact_lock(hashtextextended(event_row.id::text||':publication',0));
 select count(*) into blocked from public.admin_get_exhibition_publication_readiness_v2(export_row.id) where not ready;
 if blocked>0 then raise exception 'Public Publicationを作成できません。未解決項目: %件',blocked;end if;
 select count(*) into item_count from public.exhibition_export_items where export_version_id=export_row.id;
 if item_count=0 then raise exception 'Publication対象がありません。';end if;
 select coalesce(max(version_no),0)+1 into next_version from public.exhibition_publication_versions where event_id=event_row.id;
 insert into public.exhibition_publication_versions(event_id,version_no,source_export_version_id,source_layout_finalization_id,
  site_title,site_title_en,site_catchphrase,site_catchphrase_en,site_description,site_description_en,place,place_en,
  site_additional_info,site_additional_info_en,starts_at,ends_at,dm_image_path,note,created_by,published_by)
 values(event_row.id,next_version,export_row.id,export_row.layout_finalization_id,event_row.site_title,event_row.site_title_en,
  event_row.site_catchphrase,event_row.site_catchphrase_en,event_row.site_description,event_row.site_description_en,event_row.place,event_row.place_en,
  event_row.site_additional_info,event_row.site_additional_info_en,event_row.starts_at,event_row.ends_at,event_row.dm_image_path,coalesce(p_note,''),actor,actor)
 returning id into publication_id;
 insert into public.exhibition_publication_items(publication_version_id,source_export_item_id,event_id,display_item_id,display_item_type,
  smartphone_group_version_id,smartphone_work_count,work_id,display_no,public_order,work_submission_snapshot_id,caption_submission_snapshot_id,
  title_ja,display_name,effective_english_title,english_title_provenance,medium,medium_details,camera,lens,film,description_choice,
  description_ja,description_en,instagram_qr_choice,instagram_qr_info,publication_consent,image_state,public_image_path)
 select publication_id,item.id,event_row.id,item.display_item_id,item.display_item_type,item.smartphone_group_version_id,item.smartphone_work_count,
  item.work_id,item.display_no,item.viewing_order,item.work_submission_snapshot_id,item.caption_submission_snapshot_id,item.title_ja,item.display_name,
  item.effective_english_title,item.english_title_provenance,item.medium,item.medium_details,item.camera,item.lens,item.film,item.description_choice,
  item.description_ja,item.description_en,item.instagram_qr_choice,item.instagram_qr_info,item.publication_consent,
  case when item.display_item_type='smartphone_group' or not item.publication_consent then 'no_image' else 'public_image' end,
  case when item.display_item_type='regular_work' and item.publication_consent then work_row.public_image_path else null end
 from public.exhibition_export_items item left join public.exhibition_works work_row on work_row.id=item.work_id
 where item.export_version_id=export_row.id order by item.viewing_order;
 perform private.write_exhibition_workflow_audit(event_row.id,'publication_version',publication_id,'public_publication_finalized','admin',actor,p_note,'{}',
  jsonb_build_object('versionNo',next_version,'sourceExportVersionId',export_row.id,'layoutFinalizationId',export_row.layout_finalization_id,'itemCount',item_count));
 return jsonb_build_object('publicationVersionId',publication_id,'versionNo',next_version,'itemCount',item_count);
end;$$;

create or replace function public.get_public_exhibition(p_exhibition_key text)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when event_row.exhibition_workflow_version=2 and publication_row.id is not null then
  jsonb_build_object('exhibitionKey',event_row.exhibition_key,'publicationAvailable',true,
   'publicationVersionId',publication_row.id,'publicationVersionNo',publication_row.version_no,'eventName',publication_row.event_title,
   'title',publication_row.site_title,'titleEn',publication_row.site_title_en,'catchphrase',publication_row.site_catchphrase,'catchphraseEn',publication_row.site_catchphrase_en,
   'description',publication_row.site_description,'descriptionEn',publication_row.site_description_en,'startsAt',publication_row.starts_at,'endsAt',publication_row.ends_at,
   'place',publication_row.place,'placeEn',publication_row.place_en,'additionalInfo',publication_row.site_additional_info,'additionalInfoEn',publication_row.site_additional_info_en,
   'dmImagePath',publication_row.dm_image_path,'siteStatus',event_row.site_status,'surveyOpensAt',event_row.survey_opens_at,'surveyClosesAt',event_row.survey_closes_at,
   'works',case when event_row.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object(
    'displayItemUuid',item.display_item_id,'displayItemType',coalesce(item.display_item_type,'regular_work'),
    'workUuid',case when item.display_item_type='smartphone_group' then null else item.work_id end,
    'displayNo',item.display_no,'title',item.title_ja,'titleEn',item.effective_english_title,
    'artist',case when item.display_item_type='smartphone_group' then '' else item.display_name end,
    'camera',case when item.display_item_type='smartphone_group' then '' else item.camera end,
    'lensOther',case when item.display_item_type='smartphone_group' then '' else concat_ws(' / ',nullif(item.lens,''),nullif(item.film,''),nullif(item.medium_details,'')) end,
    'description',case when item.display_item_type='smartphone_group' then 'スマートフォンで撮影された写真を2L判で集合展示しています。' when item.description_choice='provided' then item.description_ja else '' end,
    'descriptionEn',case when item.display_item_type='smartphone_group' then 'A collective display of photographs taken with smartphones and printed at 2L size.' when item.description_choice='provided' then item.description_en else '' end,
    'medium',item.medium,'smartphoneWorkCount',case when item.display_item_type='smartphone_group' then item.smartphone_work_count else null end,
    'instagramUrl',case when item.display_item_type='smartphone_group' then null else item.instagram_public_url end,
    'aiProcessingDeclaration',case when item.display_item_type='smartphone_group' then null else item.ai_processing_declaration end,
    'aiProcessingDetails',case when item.display_item_type='smartphone_group' then '' else item.ai_processing_details end,
    'imagePublic',item.image_state='public_image','imageState',item.image_state,
    'publicImagePath',case when item.image_state='public_image' then item.public_image_path else null end
   ) order by item.public_order) from public.exhibition_publication_items item where item.publication_version_id=publication_row.id),'[]'::jsonb) else '[]'::jsonb end)
 when event_row.exhibition_workflow_version=2 then
  jsonb_build_object('exhibitionKey',event_row.exhibition_key,'publicationAvailable',false,
   'publicationVersionId',null,'publicationVersionNo',null,'eventName',event_row.title,
   'title',event_row.site_title,'titleEn',event_row.site_title_en,'catchphrase',event_row.site_catchphrase,'catchphraseEn',event_row.site_catchphrase_en,
   'description',event_row.site_description,'descriptionEn',event_row.site_description_en,'startsAt',event_row.starts_at,'endsAt',event_row.ends_at,
   'place',event_row.place,'placeEn',event_row.place_en,'additionalInfo',event_row.site_additional_info,'additionalInfoEn',event_row.site_additional_info_en,
   'dmImagePath',event_row.dm_image_path,'siteStatus',event_row.site_status,'surveyOpensAt',event_row.survey_opens_at,'surveyClosesAt',event_row.survey_closes_at,'works','[]'::jsonb)
 else jsonb_build_object('exhibitionKey',event_row.exhibition_key,'publicationAvailable',false,'eventName',event_row.title,
  'title',event_row.site_title,'titleEn',event_row.site_title_en,
  'catchphrase',event_row.site_catchphrase,'catchphraseEn',event_row.site_catchphrase_en,'description',event_row.site_description,'descriptionEn',event_row.site_description_en,
  'startsAt',event_row.starts_at,'endsAt',event_row.ends_at,'place',event_row.place,'placeEn',event_row.place_en,
  'additionalInfo',event_row.site_additional_info,'additionalInfoEn',event_row.site_additional_info_en,'dmImagePath',event_row.dm_image_path,'siteStatus',event_row.site_status,
  'surveyOpensAt',event_row.survey_opens_at,'surveyClosesAt',event_row.survey_closes_at,
  'works',case when event_row.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object('workUuid',work_row.id,'displayNo',work_row.display_no,
   'title',work_row.title,'titleEn',work_row.title_en,'artist',work_row.artist_name,'camera',work_row.camera_name,'lensOther',work_row.lens_other,
   'description',work_row.description,'descriptionEn',work_row.description_en,'imagePublic',work_row.publication_consent,
   'imageState',case when work_row.publication_consent then 'public_image' else 'no_image' end,
   'publicImagePath',case when work_row.publication_consent and work_row.public_release then work_row.public_image_path else null end)
   order by case when work_row.display_no~'^[0-9]+$' then work_row.display_no::integer else 2147483647 end,work_row.display_no)
   from public.exhibition_works work_row where work_row.event_id=event_row.id and work_row.status='accepted'),'[]'::jsonb) else '[]'::jsonb end) end
 from public.events event_row left join public.exhibition_publication_versions publication_row on publication_row.id=event_row.current_publication_version_id
 where event_row.exhibition_key=p_exhibition_key and event_row.genre='exhibition' and event_row.status='saved' and event_row.deleted_at is null
  and event_row.site_status in('published','ended')
$$;

create or replace function public.submit_exhibition_survey(p_exhibition_key text,p_respondent_token text,p_language text,p_overall_comment text,p_selections jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;response_id uuid;selection_count integer;distinct_count integer;invalid_count integer;respondent_hash text;
begin
 if char_length(coalesce(p_respondent_token,''))<32 or char_length(p_respondent_token)>200 then raise exception 'invalid respondent token' using errcode='22023';end if;
 if p_language not in('ja','en') or jsonb_typeof(p_selections)<>'array' then raise exception 'invalid request' using errcode='22023';end if;
 if char_length(coalesce(p_overall_comment,''))>2000 then raise exception 'overall comment is too long' using errcode='22023';end if;
 select * into event_row from public.events where exhibition_key=p_exhibition_key and genre='exhibition' and status='saved' and deleted_at is null for share;
 if event_row.id is null then raise exception 'unknown exhibition' using errcode='22023';end if;
 if event_row.site_status<>'published' or not event_row.survey_enabled or event_row.survey_opens_at is null or event_row.survey_closes_at is null
  or now()<event_row.survey_opens_at or now()>event_row.survey_closes_at then raise exception 'survey is closed' using errcode='55000';end if;
 if event_row.exhibition_workflow_version=2 then
  select count(*),count(distinct coalesce(item->>'display_item_id',item->>'work_id')) into selection_count,distinct_count from jsonb_array_elements(p_selections)item;
 else select count(*),count(distinct item->>'work_id') into selection_count,distinct_count from jsonb_array_elements(p_selections)item;end if;
 if selection_count<1 or selection_count>3 or selection_count<>distinct_count then raise exception 'select between one and three distinct works' using errcode='22023';end if;
 if event_row.exhibition_workflow_version=2 then
  if event_row.current_publication_version_id is null then raise exception 'publication is unavailable' using errcode='55000';end if;
  select count(*) into invalid_count from jsonb_array_elements(p_selections)item
  left join public.exhibition_publication_items publication_item on publication_item.publication_version_id=event_row.current_publication_version_id
   and publication_item.display_item_id::text=coalesce(item->>'display_item_id',
     (select display_item.id::text from public.exhibition_display_items display_item where display_item.regular_work_id::text=item->>'work_id'))
  where publication_item.id is null or char_length(coalesce(item->>'comment',''))>1000;
 else
  select count(*) into invalid_count from jsonb_array_elements(p_selections)item left join public.exhibition_works work_row on work_row.id::text=item->>'work_id'
  where work_row.id is null or work_row.event_id<>event_row.id or work_row.status<>'accepted' or nullif(trim(work_row.display_no),'') is null or char_length(coalesce(item->>'comment',''))>1000;
 end if;
 if invalid_count>0 then raise exception 'invalid work or comment' using errcode='22023';end if;
 respondent_hash:=encode(extensions.digest(p_respondent_token,'sha256'),'hex');
 insert into public.exhibition_survey_responses(event_id,respondent_hash,response_language,overall_comment,publication_version_id,workflow_version)
 values(event_row.id,respondent_hash,p_language,coalesce(p_overall_comment,''),case when event_row.exhibition_workflow_version=2 then event_row.current_publication_version_id else null end,
  case when event_row.exhibition_workflow_version=2 then 2 else 1 end) returning id into response_id;
 if event_row.exhibition_workflow_version=2 then
  insert into public.exhibition_survey_selections(response_id,work_id,display_item_id,publication_item_id,comment,position)
  select response_id,publication_item.work_id,publication_item.display_item_id,publication_item.id,coalesce(item->>'comment',''),ordinality::smallint
  from jsonb_array_elements(p_selections) with ordinality as selection(item,ordinality)
  join public.exhibition_publication_items publication_item on publication_item.publication_version_id=event_row.current_publication_version_id
   and publication_item.display_item_id::text=coalesce(item->>'display_item_id',
    (select display_item.id::text from public.exhibition_display_items display_item where display_item.regular_work_id::text=item->>'work_id'));
 else
  insert into public.exhibition_survey_selections(response_id,work_id,comment,position)
  select response_id,(item->>'work_id')::uuid,coalesce(item->>'comment',''),ordinality::smallint from jsonb_array_elements(p_selections) with ordinality as selection(item,ordinality);
 end if;
 return response_id;
end;$$;

-- The existing compatibility view is intentionally private and now also records
-- members whose immutable Group Version has reached Export/Publication/Survey.
create or replace view public.exhibition_smartphone_display_items as
select distinct version_row.event_id,work_row.member_id
from public.exhibition_smartphone_group_version_items version_item
join public.exhibition_smartphone_group_versions version_row on version_row.id=version_item.group_version_id
join public.exhibition_smartphone_works work_row on work_row.id=version_item.smartphone_work_id
union
select distinct layout_row.event_id,work_row.member_id
from public.exhibition_placements placement_row join public.exhibition_layouts layout_row on layout_row.id=placement_row.layout_id
join public.exhibition_display_items display_item on display_item.id=placement_row.display_item_id
join public.exhibition_smartphone_works work_row on work_row.event_id=layout_row.event_id
where display_item.item_type='smartphone_group' and placement_row.status<>'removed';
revoke all on public.exhibition_smartphone_display_items from public,anon,authenticated;
