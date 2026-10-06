-- Smartphone Phase 2 / Step 4: Display Item Actual and immutable Archive.

alter table public.exhibition_actual_items
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column display_item_type text check(display_item_type is null or display_item_type in('regular_work','smartphone_group')),
  add column smartphone_group_version_id uuid references public.exhibition_smartphone_group_versions(id) on delete restrict,
  add column smartphone_work_count integer check(smartphone_work_count is null or smartphone_work_count>=1),
  add column occupied_width_mm numeric(10,2),
  add column occupied_height_mm numeric(10,2);
update public.exhibition_actual_items actual_item set
  display_item_id=layout_item.display_item_id,
  display_item_type='regular_work',
  occupied_width_mm=layout_item.occupied_width_mm,
  occupied_height_mm=layout_item.occupied_height_mm
from public.exhibition_layout_finalization_items layout_item
where layout_item.id=actual_item.source_layout_item_id;
alter table public.exhibition_actual_items
  alter column work_id drop not null,
  alter column work_submission_snapshot_id drop not null,
  add constraint exhibition_actual_item_display_source_check check(
    (display_item_type is null and display_item_id is null and work_id is not null and work_submission_snapshot_id is not null)
    or
    (display_item_type='regular_work' and display_item_id is not null and work_id is not null
      and work_submission_snapshot_id is not null and smartphone_group_version_id is null and smartphone_work_count is null)
    or
    (display_item_type='smartphone_group' and display_item_id is not null and work_id is null
      and work_submission_snapshot_id is null and caption_submission_snapshot_id is null
      and smartphone_group_version_id is not null and smartphone_work_count>=1 and not caption_exception)
  );
create unique index exhibition_actual_items_display_unique on public.exhibition_actual_items(actual_version_id,display_item_id);

alter table public.exhibition_archive_items
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column display_item_type text check(display_item_type is null or display_item_type in('regular_work','smartphone_group')),
  add column smartphone_group_version_id uuid references public.exhibition_smartphone_group_versions(id) on delete restrict,
  add column smartphone_work_count integer check(smartphone_work_count is null or smartphone_work_count>=1),
  add column occupied_width_mm numeric(10,2),
  add column occupied_height_mm numeric(10,2);
update public.exhibition_archive_items archive_item set
  display_item_id=actual_item.display_item_id,
  display_item_type='regular_work',
  occupied_width_mm=layout_item.occupied_width_mm,
  occupied_height_mm=layout_item.occupied_height_mm
from public.exhibition_actual_items actual_item
join public.exhibition_layout_finalization_items layout_item on layout_item.id=actual_item.source_layout_item_id
where actual_item.id=archive_item.source_actual_item_id;
alter table public.exhibition_archive_items
  alter column work_id drop not null,
  alter column work_submission_snapshot_id drop not null,
  add constraint exhibition_archive_item_display_source_check check(
    (display_item_type is null and display_item_id is null and work_id is not null and work_submission_snapshot_id is not null)
    or
    (display_item_type='regular_work' and display_item_id is not null and work_id is not null
      and work_submission_snapshot_id is not null and smartphone_group_version_id is null and smartphone_work_count is null)
    or
    (display_item_type='smartphone_group' and display_item_id is not null and work_id is null
      and work_submission_snapshot_id is null and caption_submission_snapshot_id is null
      and smartphone_group_version_id is not null and smartphone_work_count>=1 and not caption_exception
      and image_state='no_image' and public_image_path is null and not publication_consent)
  );
create unique index exhibition_archive_items_display_unique on public.exhibition_archive_items(archive_version_id,display_item_id);

create or replace function public.admin_initialize_exhibition_actual_v2(
  p_layout_finalization_id uuid,p_correction_of_id uuid default null,p_reason text default '',p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare final_row public.exhibition_layout_finalizations%rowtype;event_row public.events%rowtype;prior_row public.exhibition_actual_versions%rowtype;
 actual_id uuid;next_version integer;actor text:=private.current_email();item_count integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into final_row from public.exhibition_layout_finalizations where id=p_layout_finalization_id;
 select * into event_row from public.events where id=final_row.event_id for update;
 if final_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2の確定済みLayoutが見つかりません。';end if;
 perform pg_advisory_xact_lock(hashtextextended(event_row.id::text||':actual',0));
 if exists(select 1 from public.exhibition_actual_versions version_row where version_row.event_id=event_row.id and version_row.state='draft') then raise exception '編集中のActual Draftが既にあります。';end if;
 if p_correction_of_id is null and exists(select 1 from public.exhibition_actual_versions version_row where version_row.event_id=event_row.id and version_row.state='finalized') then raise exception '確定後の新Versionは訂正元Actualと理由を指定してください。';end if;
 if p_correction_of_id is not null then
  select * into prior_row from public.exhibition_actual_versions version_row where version_row.id=p_correction_of_id and version_row.event_id=event_row.id and version_row.state='finalized';
  if prior_row.id is null or trim(coalesce(p_reason,''))='' then raise exception '確定済みActualと訂正理由が必要です。';end if;
  if prior_row.source_layout_finalization_id<>final_row.id then raise exception '訂正版は元Actualと同じPlanを基準にしてください。';end if;
 end if;
 select coalesce(max(version_row.version_no),0)+1 into next_version from public.exhibition_actual_versions version_row where version_row.event_id=event_row.id;
 insert into public.exhibition_actual_versions(event_id,version_no,source_layout_finalization_id,correction_of_id,reason,note,created_by)
 values(event_row.id,next_version,final_row.id,p_correction_of_id,coalesce(p_reason,''),coalesce(p_note,''),actor) returning id into actual_id;
 if prior_row.id is null then
  insert into public.exhibition_actual_items(actual_version_id,event_id,source_layout_item_id,display_item_id,display_item_type,
   smartphone_group_version_id,smartphone_work_count,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,
   planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,
   occupied_width_mm,occupied_height_mm,updated_by)
  select actual_id,event_row.id,layout_item.id,layout_item.display_item_id,display_item.item_type,
   layout_item.smartphone_group_version_id,case when display_item.item_type='smartphone_group' then
    (select count(*) from public.exhibition_smartphone_group_version_items version_item where version_item.group_version_id=layout_item.smartphone_group_version_id) else null end,
   layout_item.work_id,layout_item.display_no,layout_item.work_submission_snapshot_id,
   case when display_item.item_type='regular_work' then (select caption_snapshot.id from public.exhibition_caption_submission_snapshots caption_snapshot
    join public.exhibition_caption_reviews review_row on review_row.caption_snapshot_id=caption_snapshot.id and review_row.result='accepted'
    where caption_snapshot.work_id=layout_item.work_id and caption_snapshot.work_submission_snapshot_id=layout_item.work_submission_snapshot_id
    order by review_row.reviewed_at desc,caption_snapshot.version_no desc,caption_snapshot.id desc limit 1) else null end,
   layout_item.wall_id,layout_item.x_mm,layout_item.top_from_floor_mm,layout_item.z_order,
   layout_item.wall_id,layout_item.x_mm,layout_item.top_from_floor_mm,layout_item.z_order,
   layout_item.occupied_width_mm,layout_item.occupied_height_mm,actor
  from public.exhibition_layout_finalization_items layout_item
  join public.exhibition_display_items display_item on display_item.id=layout_item.display_item_id
  where layout_item.finalization_id=final_row.id order by layout_item.viewing_order;
 else
  insert into public.exhibition_actual_items(actual_version_id,event_id,source_layout_item_id,display_item_id,display_item_type,
   smartphone_group_version_id,smartphone_work_count,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,actual_state,
   planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,
   occupied_width_mm,occupied_height_mm,caption_exception,note,updated_by)
  select actual_id,item.event_id,item.source_layout_item_id,item.display_item_id,item.display_item_type,item.smartphone_group_version_id,
   item.smartphone_work_count,item.work_id,item.display_no,item.work_submission_snapshot_id,item.caption_submission_snapshot_id,item.actual_state,
   item.planned_wall_id,item.planned_x_mm,item.planned_top_from_floor_mm,item.planned_z_order,item.actual_wall_id,item.actual_x_mm,
   item.actual_top_from_floor_mm,item.actual_z_order,item.occupied_width_mm,item.occupied_height_mm,item.caption_exception,item.note,actor
  from public.exhibition_actual_items item where item.actual_version_id=prior_row.id;
 end if;
 get diagnostics item_count=row_count;if item_count=0 then raise exception 'Actual対象のPlan Itemがありません。';end if;
 perform private.write_exhibition_workflow_audit(event_row.id,'actual_version',actual_id,case when prior_row.id is null then 'actual_draft_initialized' else 'actual_correction_draft_initialized' end,
  'admin',actor,p_reason,'{}',jsonb_build_object('versionNo',next_version,'sourceLayoutFinalizationId',final_row.id,'correctionOfId',prior_row.id,'itemCount',item_count));
 return jsonb_build_object('actualVersionId',actual_id,'versionNo',next_version,'itemCount',item_count,'correctionOfId',prior_row.id);
end;$$;

create or replace function public.admin_update_exhibition_actual_item_v2(
 p_item_id uuid,p_actual_state text,p_actual_wall_id uuid,p_actual_x_mm numeric,p_actual_top_from_floor_mm numeric,p_actual_z_order integer,
 p_work_snapshot_id uuid,p_caption_snapshot_id uuid,p_caption_exception boolean default false,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare item_row public.exhibition_actual_items%rowtype;version_row public.exhibition_actual_versions%rowtype;event_row public.events%rowtype;
 work_snapshot public.exhibition_work_submission_snapshots%rowtype;caption_snapshot public.exhibition_caption_submission_snapshots%rowtype;
 wall_row public.exhibition_walls%rowtype;actor text:=private.current_email();before_state jsonb;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 if p_actual_state not in('unconfirmed','exhibited','not_exhibited') then raise exception 'Actual状態が不正です。';end if;
 select * into item_row from public.exhibition_actual_items item where item.id=p_item_id for update;
 select * into version_row from public.exhibition_actual_versions version where version.id=item_row.actual_version_id;
 select * into event_row from public.events event where event.id=item_row.event_id;
 if item_row.id is null or version_row.state<>'draft' or event_row.exhibition_workflow_version<>2 then raise exception '編集可能なActual Itemではありません。';end if;
 if item_row.display_item_type='regular_work' then
  select * into work_snapshot from public.exhibition_work_submission_snapshots snapshot where snapshot.id=p_work_snapshot_id and snapshot.work_id=item_row.work_id and snapshot.event_id=item_row.event_id;
  if work_snapshot.id is null or (work_snapshot.id<>item_row.work_submission_snapshot_id and not exists(select 1 from public.exhibition_work_reviews review_row where review_row.submission_snapshot_id=work_snapshot.id and review_row.result='accepted')) then raise exception '実展示Work SnapshotはPlan由来または確認済み履歴から選択してください。';end if;
  if p_caption_snapshot_id is not null then
   select * into caption_snapshot from public.exhibition_caption_submission_snapshots snapshot where snapshot.id=p_caption_snapshot_id and snapshot.work_id=item_row.work_id;
   if caption_snapshot.id is null or caption_snapshot.work_submission_snapshot_id<>work_snapshot.id or not exists(select 1 from public.exhibition_caption_reviews review_row where review_row.caption_snapshot_id=caption_snapshot.id and review_row.result='accepted') then raise exception 'Caption Snapshotが実展示Work Snapshotと一致しないか、確認済みではありません。';end if;
  end if;
 else
  if p_work_snapshot_id is not null or p_caption_snapshot_id is not null or coalesce(p_caption_exception,false) then raise exception 'Smartphone Groupに個別Work/Captionを設定できません。';end if;
 end if;
 if p_actual_state='exhibited' then
  select * into wall_row from public.exhibition_walls wall where wall.id=p_actual_wall_id and wall.venue_id=event_row.exhibition_venue_id and wall.usable;
  if wall_row.id is null or p_actual_x_mm is null or p_actual_top_from_floor_mm is null or p_actual_z_order is null then raise exception '実展示配置を入力してください。';end if;
  if p_actual_x_mm<0 or p_actual_top_from_floor_mm<0 or p_actual_z_order<0 or p_actual_x_mm+item_row.occupied_width_mm>wall_row.width_mm
   or p_actual_top_from_floor_mm>wall_row.height_mm or p_actual_top_from_floor_mm-item_row.occupied_height_mm<0 then raise exception '実展示配置が壁面範囲外です。';end if;
  if item_row.display_item_type='regular_work' and p_caption_snapshot_id is null and not coalesce(p_caption_exception,false) then raise exception '対応する確認済みCaptionまたは例外記録が必要です。';end if;
  if item_row.display_item_type='regular_work' and coalesce(p_caption_exception,false) and trim(coalesce(p_note,''))='' then raise exception 'Caption例外理由を入力してください。';end if;
 end if;
 before_state:=jsonb_build_object('actualState',item_row.actual_state,'workSnapshotId',item_row.work_submission_snapshot_id,'captionSnapshotId',item_row.caption_submission_snapshot_id,'wallId',item_row.actual_wall_id,'xMm',item_row.actual_x_mm,'topMm',item_row.actual_top_from_floor_mm,'zOrder',item_row.actual_z_order);
 update public.exhibition_actual_items set actual_state=p_actual_state,
  work_submission_snapshot_id=case when item_row.display_item_type='regular_work' then work_snapshot.id else null end,
  caption_submission_snapshot_id=case when item_row.display_item_type='regular_work' then p_caption_snapshot_id else null end,
  actual_wall_id=case when p_actual_state='exhibited' then p_actual_wall_id else null end,
  actual_x_mm=case when p_actual_state='exhibited' then p_actual_x_mm else null end,
  actual_top_from_floor_mm=case when p_actual_state='exhibited' then p_actual_top_from_floor_mm else null end,
  actual_z_order=case when p_actual_state='exhibited' then p_actual_z_order else null end,
  caption_exception=case when p_actual_state='exhibited' and item_row.display_item_type='regular_work' then coalesce(p_caption_exception,false) else false end,
  note=coalesce(p_note,''),updated_by=actor,updated_at=now() where id=item_row.id returning * into item_row;
 perform private.write_exhibition_workflow_audit(item_row.event_id,'actual_item',item_row.id,'actual_item_recorded','admin',actor,p_note,before_state,
  jsonb_build_object('actualState',item_row.actual_state,'displayItemId',item_row.display_item_id,'wallId',item_row.actual_wall_id,'xMm',item_row.actual_x_mm,'topMm',item_row.actual_top_from_floor_mm,'zOrder',item_row.actual_z_order));
 return to_jsonb(item_row);
end;$$;

create or replace function public.admin_get_exhibition_actual_readiness_v2(p_actual_version_id uuid)
returns table(item_id uuid,work_id uuid,display_no integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 if not exists(select 1 from public.exhibition_actual_versions version_row where version_row.id=p_actual_version_id and version_row.state='draft') then raise exception 'Actual Draftが見つかりません。';end if;
 return query select item.id,item.work_id,item.display_no,cardinality(reason_row.reasons)=0,coalesce(reason_row.reasons,'{}'::text[])
 from public.exhibition_actual_items item
 join public.exhibition_actual_versions version_row on version_row.id=item.actual_version_id
 join public.events event_row on event_row.id=item.event_id
 left join public.exhibition_layout_finalization_items layout_item on layout_item.id=item.source_layout_item_id
 left join public.exhibition_display_item_numbers number_row on number_row.display_item_id=item.display_item_id
 left join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=item.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=item.caption_submission_snapshot_id
 left join public.exhibition_smartphone_group_versions group_version on group_version.id=item.smartphone_group_version_id
 left join public.exhibition_walls wall_row on wall_row.id=item.actual_wall_id
 cross join lateral(select array_remove(array[
  case when item.actual_state='unconfirmed' then 'Actual status is unconfirmed' end,
  case when layout_item.finalization_id is distinct from version_row.source_layout_finalization_id or layout_item.display_item_id is distinct from item.display_item_id then 'Plan provenance mismatch' end,
  case when number_row.display_no is distinct from item.display_no then 'Display number mismatch' end,
  case when item.display_item_type='regular_work' and (work_snapshot.work_id is distinct from item.work_id or work_snapshot.event_id is distinct from item.event_id) then 'Work Snapshot provenance mismatch' end,
  case when item.display_item_type='smartphone_group' and (group_version.id is null or group_version.id is distinct from layout_item.smartphone_group_version_id or group_version.event_id<>item.event_id or item.smartphone_work_count<1) then 'Smartphone Group provenance mismatch' end,
  case when item.actual_state='exhibited' and (wall_row.id is null or wall_row.venue_id<>event_row.exhibition_venue_id) then 'Actual wall is invalid' end,
  case when item.actual_state='exhibited' and (item.actual_x_mm is null or item.actual_top_from_floor_mm is null or item.actual_z_order is null) then 'Actual placement is incomplete' end,
  case when item.actual_state='exhibited' and wall_row.id is not null and (item.actual_x_mm+item.occupied_width_mm>wall_row.width_mm or item.actual_top_from_floor_mm>wall_row.height_mm or item.actual_top_from_floor_mm-item.occupied_height_mm<0) then 'Actual placement is outside the wall' end,
  case when item.display_item_type='regular_work' and item.actual_state='exhibited' and caption_snapshot.id is null and not item.caption_exception then 'Accepted compatible Caption is missing' end,
  case when item.display_item_type='regular_work' and item.actual_state='exhibited' and caption_snapshot.id is not null and (caption_snapshot.work_id<>item.work_id or caption_snapshot.work_submission_snapshot_id<>work_snapshot.id or not exists(select 1 from public.exhibition_caption_reviews review_row where review_row.caption_snapshot_id=caption_snapshot.id and review_row.result='accepted')) then 'Caption provenance mismatch' end,
  case when item.display_item_type='regular_work' and item.actual_state='exhibited' and item.caption_exception and trim(item.note)='' then 'Caption exception reason is missing' end
 ]::text[],null) reasons) reason_row
 where item.actual_version_id=p_actual_version_id order by item.display_no;
end;$$;

create or replace function public.admin_finalize_exhibition_actual_v2(p_actual_version_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare version_row public.exhibition_actual_versions%rowtype;event_row public.events%rowtype;actor text:=private.current_email();exhibited_count integer;not_count integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into version_row from public.exhibition_actual_versions version where version.id=p_actual_version_id for update;
 select * into event_row from public.events event where event.id=version_row.event_id for update;
 if version_row.id is null or version_row.state<>'draft' or event_row.exhibition_workflow_version<>2 then raise exception '確定可能なActual Draftではありません。';end if;
 perform pg_advisory_xact_lock(hashtextextended(event_row.id::text||':actual',0));
 if not exists(select 1 from public.exhibition_actual_items item where item.actual_version_id=version_row.id) then raise exception 'Actual Itemがありません。';end if;
 if exists(select 1 from public.admin_get_exhibition_actual_readiness_v2(version_row.id) readiness where not readiness.ready) then raise exception 'Actual provenanceまたは配置に未解決の問題があります。';end if;
 select count(*) filter(where item.actual_state='exhibited'),count(*) filter(where item.actual_state='not_exhibited') into exhibited_count,not_count from public.exhibition_actual_items item where item.actual_version_id=version_row.id;
 update public.exhibition_actual_versions set state='finalized',finalized_by=actor,finalized_at=now(),reason=case when correction_of_id is not null then reason else coalesce(nullif(trim(p_reason),''),reason) end where id=version_row.id returning * into version_row;
 perform private.write_exhibition_workflow_audit(event_row.id,'actual_version',version_row.id,'actual_finalized','admin',actor,p_reason,'{}',jsonb_build_object('versionNo',version_row.version_no,'sourceLayoutFinalizationId',version_row.source_layout_finalization_id,'exhibitedCount',exhibited_count,'notExhibitedCount',not_count,'correctionOfId',version_row.correction_of_id));
 return jsonb_build_object('actualVersionId',version_row.id,'versionNo',version_row.version_no,'exhibitedCount',exhibited_count,'notExhibitedCount',not_count);
end;$$;

create or replace function public.admin_get_exhibition_archive_readiness_v2(p_actual_version_id uuid)
returns table(item_id uuid,work_id uuid,display_no integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 if not exists(select 1 from public.exhibition_actual_versions version_row join public.events event_row on event_row.id=version_row.event_id where version_row.id=p_actual_version_id and version_row.state='finalized' and event_row.exhibition_workflow_version=2) then raise exception '確定済みWorkflow v2 Actualが見つかりません。';end if;
 return query select item.id,item.work_id,item.display_no,cardinality(reason_row.reasons)=0,coalesce(reason_row.reasons,'{}'::text[])
 from public.exhibition_actual_items item
 left join public.exhibition_display_item_numbers number_row on number_row.display_item_id=item.display_item_id
 left join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=item.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=item.caption_submission_snapshot_id
 left join public.exhibition_smartphone_group_versions group_version on group_version.id=item.smartphone_group_version_id
 cross join lateral(select array_remove(array[
  case when number_row.display_no is distinct from item.display_no then 'Display number mismatch' end,
  case when item.display_item_type='regular_work' and (work_snapshot.work_id is distinct from item.work_id or work_snapshot.event_id is distinct from item.event_id) then 'Work Snapshot provenance mismatch' end,
  case when item.display_item_type='regular_work' and not item.caption_exception and (caption_snapshot.id is null or caption_snapshot.work_id<>item.work_id or caption_snapshot.work_submission_snapshot_id<>work_snapshot.id or not exists(select 1 from public.exhibition_caption_reviews review_row where review_row.caption_snapshot_id=caption_snapshot.id and review_row.result='accepted')) then 'Caption provenance mismatch' end,
  case when item.display_item_type='regular_work' and item.caption_exception and (caption_snapshot.id is not null or trim(item.note)='') then 'Caption exception is invalid' end,
  case when item.display_item_type='regular_work' and caption_snapshot.english_title_mode='organizer' and not exists(select 1 from public.exhibition_caption_english_title_derivations derivation where derivation.source_caption_snapshot_id=caption_snapshot.id) then 'Organizer English title derivation is missing' end,
  case when item.display_item_type='smartphone_group' and (group_version.id is null or group_version.event_id<>item.event_id or item.smartphone_work_count<1) then 'Smartphone Group provenance mismatch' end,
  case when item.actual_wall_id is null or item.actual_x_mm is null or item.actual_top_from_floor_mm is null or item.actual_z_order is null then 'Actual placement is missing' end
 ]::text[],null) reasons) reason_row
 where item.actual_version_id=p_actual_version_id and item.actual_state='exhibited' order by item.display_no;
end;$$;

create or replace function public.admin_finalize_exhibition_archive_v2(p_actual_version_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare version_row public.exhibition_actual_versions%rowtype;event_row public.events%rowtype;archive_id uuid;next_version integer;actor text:=private.current_email();blocked integer;item_count integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into version_row from public.exhibition_actual_versions version where version.id=p_actual_version_id for share;
 select * into event_row from public.events event where event.id=version_row.event_id for update;
 if version_row.id is null or version_row.state<>'finalized' or event_row.exhibition_workflow_version<>2 then raise exception '確定済みWorkflow v2 Actualが必要です。';end if;
 if exists(select 1 from public.exhibition_archive_versions archive where archive.source_actual_version_id=version_row.id) then raise exception 'このActualのArchiveは作成済みです。';end if;
 perform pg_advisory_xact_lock(hashtextextended(event_row.id::text||':archive',0));
 select count(*) into blocked from public.admin_get_exhibition_archive_readiness_v2(version_row.id) readiness where not readiness.ready;
 if blocked>0 then raise exception 'Archiveを作成できません。未解決項目: %件',blocked;end if;
 select count(*) into item_count from public.exhibition_actual_items item where item.actual_version_id=version_row.id and item.actual_state='exhibited';
 if item_count=0 then raise exception '実展示作品がありません。';end if;
 select coalesce(max(archive.version_no),0)+1 into next_version from public.exhibition_archive_versions archive where archive.event_id=event_row.id;
 insert into public.exhibition_archive_versions(event_id,version_no,source_actual_version_id,note,created_by,finalized_by) values(event_row.id,next_version,version_row.id,coalesce(p_note,''),actor,actor) returning id into archive_id;
 insert into public.exhibition_archive_items(archive_version_id,event_id,source_actual_item_id,source_actual_version_id,source_layout_finalization_id,
  display_item_id,display_item_type,smartphone_group_version_id,smartphone_work_count,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,
  caption_exception,caption_exception_reason,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,
  occupied_width_mm,occupied_height_mm,title_ja,display_name,english_title_mode,effective_english_title,english_title_provenance,english_title_derivation_id,
  medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,publication_consent,image_state,public_image_path)
 select archive_id,event_row.id,item.id,version_row.id,version_row.source_layout_finalization_id,item.display_item_id,item.display_item_type,
  item.smartphone_group_version_id,item.smartphone_work_count,item.work_id,item.display_no,item.work_submission_snapshot_id,item.caption_submission_snapshot_id,
  item.caption_exception,case when item.caption_exception then item.note else '' end,item.planned_wall_id,item.planned_x_mm,item.planned_top_from_floor_mm,item.planned_z_order,
  item.actual_wall_id,item.actual_x_mm,item.actual_top_from_floor_mm,item.actual_z_order,item.occupied_width_mm,item.occupied_height_mm,
  case when item.display_item_type='smartphone_group' then 'スマートフォン撮影写真作品' else work_snapshot.title end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.display_name,'') end,
  case when item.display_item_type='smartphone_group' then null else caption_snapshot.english_title_mode end,
  case when item.display_item_type='smartphone_group' then '' when caption_snapshot.english_title_mode='self' then caption_snapshot.member_english_title when caption_snapshot.english_title_mode='organizer' then derivation.english_title else '' end,
  case when item.display_item_type='smartphone_group' then 'smartphone_group' when caption_snapshot.english_title_mode='self' then 'member_snapshot' when caption_snapshot.english_title_mode='organizer' then 'organizer_derivation' else 'caption_exception' end,
  case when item.display_item_type='smartphone_group' then null else derivation.id end,
  case when item.display_item_type='smartphone_group' then 'smartphone_group' else coalesce(caption_snapshot.medium,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.medium_details,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.camera,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.lens,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.film,'') end,
  case when item.display_item_type='smartphone_group' then 'none' else coalesce(caption_snapshot.description_choice,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.description_ja,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.description_en,'') end,
  case when item.display_item_type='smartphone_group' then 'none' else coalesce(caption_snapshot.instagram_qr_choice,'') end,
  case when item.display_item_type='smartphone_group' then '' else coalesce(caption_snapshot.instagram_qr_info,'') end,
  case when item.display_item_type='smartphone_group' then false else coalesce(work_snapshot.publication_consent,false) end,
  case when item.display_item_type='regular_work' and work_snapshot.publication_consent and public_image.public_image_path is not null then 'public_image' else 'no_image' end,
  case when item.display_item_type='regular_work' and work_snapshot.publication_consent then public_image.public_image_path else null end
 from public.exhibition_actual_items item
 left join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=item.work_submission_snapshot_id
 left join public.exhibition_caption_submission_snapshots caption_snapshot on caption_snapshot.id=item.caption_submission_snapshot_id
 left join lateral(select derivation_row.* from public.exhibition_caption_english_title_derivations derivation_row where derivation_row.source_caption_snapshot_id=caption_snapshot.id order by derivation_row.version_no desc limit 1) derivation on true
 left join lateral(select publication_item.public_image_path from public.exhibition_publication_items publication_item
  join public.exhibition_publication_versions publication_version on publication_version.id=publication_item.publication_version_id
  where publication_item.work_id=item.work_id and publication_item.work_submission_snapshot_id=item.work_submission_snapshot_id
   and publication_item.caption_submission_snapshot_id is not distinct from item.caption_submission_snapshot_id and publication_item.image_state='public_image'
  order by publication_version.version_no desc limit 1) public_image on true
 where item.actual_version_id=version_row.id and item.actual_state='exhibited' order by item.display_no;
 perform private.write_exhibition_workflow_audit(event_row.id,'archive_version',archive_id,'archive_finalized','admin',actor,p_note,'{}',jsonb_build_object('versionNo',next_version,'sourceActualVersionId',version_row.id,'itemCount',item_count));
 return jsonb_build_object('archiveVersionId',archive_id,'versionNo',next_version,'itemCount',item_count);
end;$$;

-- The maintenance compatibility view remains private; reaching a Group Version,
-- Actual, or Archive continues to block destructive smoke-test reset.
create or replace view public.exhibition_smartphone_display_items as
select distinct version_row.event_id,work_row.member_id
from public.exhibition_smartphone_group_version_items version_item
join public.exhibition_smartphone_group_versions version_row on version_row.id=version_item.group_version_id
join public.exhibition_smartphone_works work_row on work_row.id=version_item.smartphone_work_id
union
select distinct actual_item.event_id,work_row.member_id
from public.exhibition_actual_items actual_item
join public.exhibition_smartphone_group_version_items version_item on version_item.group_version_id=actual_item.smartphone_group_version_id
join public.exhibition_smartphone_works work_row on work_row.id=version_item.smartphone_work_id
union
select distinct archive_item.event_id,work_row.member_id
from public.exhibition_archive_items archive_item
join public.exhibition_smartphone_group_version_items version_item on version_item.group_version_id=archive_item.smartphone_group_version_id
join public.exhibition_smartphone_works work_row on work_row.id=version_item.smartphone_work_id;
revoke all on public.exhibition_smartphone_display_items from public,anon,authenticated;
