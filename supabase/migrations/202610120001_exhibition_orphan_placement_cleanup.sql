-- Allow an administrator to retire a stale placement whose source item is no
-- longer an eligible layout candidate. Creation and editing keep the existing
-- Workflow v2 eligibility checks; finalized layouts remain immutable.
create or replace function private.validate_exhibition_placement()
returns trigger language plpgsql security definer set search_path='' as $$
declare layout_row public.exhibition_layouts%rowtype; wall_row public.exhibition_walls%rowtype; event_row public.events%rowtype;
 item_row public.exhibition_display_items%rowtype; work_row public.exhibition_works%rowtype; group_row public.exhibition_smartphone_display_groups%rowtype;
 snapshot_row public.exhibition_work_submission_snapshots%rowtype;width_value numeric;height_value numeric;
begin
 select * into layout_row from public.exhibition_layouts where id=new.layout_id;select * into wall_row from public.exhibition_walls where id=new.wall_id;
 select * into event_row from public.events where id=layout_row.event_id;
 if layout_row.id is null or wall_row.id is null then raise exception '配置案または壁面が見つかりません。';end if;
 if event_row.exhibition_venue_id is null or wall_row.venue_id<>event_row.exhibition_venue_id then raise exception '写真展会場に属さない壁面は使用できません。';end if;
 if not wall_row.usable and new.status='placed' then raise exception '使用不可の壁面には配置できません。';end if;
 if event_row.exhibition_workflow_version=2 and layout_row.status in('approved','archived') then raise exception '確定・保管済みLayoutは編集できません。';end if;

 -- A withdrawn/rejected source is intentionally absent from the current
 -- candidate list. Permit only the one-way retirement of its old placement.
 if tg_op='UPDATE' and old.status<>'removed' and new.status='removed' then
   if (to_jsonb(new)-'status'-'updated_at')<>(to_jsonb(old)-'status'-'updated_at') then
     raise exception '配置解除時に配置内容は変更できません。';
   end if;
   return new;
 end if;

 if new.display_item_id is null and new.work_id is not null then
   select * into item_row from public.exhibition_display_items where regular_work_id=new.work_id;
   new.display_item_id:=item_row.id;
 else select * into item_row from public.exhibition_display_items where id=new.display_item_id;end if;
 if item_row.id is null or item_row.event_id<>layout_row.event_id then raise exception 'LayoutとDisplay Itemが一致しません。';end if;
 if item_row.item_type='regular_work' then
   if new.work_id is null then new.work_id:=item_row.regular_work_id;end if;
   if new.work_id<>item_row.regular_work_id then raise exception 'Display ItemとRegular Workが一致しません。';end if;
   select * into work_row from public.exhibition_works where id=new.work_id;
   if event_row.exhibition_workflow_version=2 then
    if work_row.workflow_state<>'accepted' or work_row.current_accepted_snapshot_id is null then raise exception '確認済みWorkだけを配置できます。';end if;
    select * into snapshot_row from public.exhibition_work_submission_snapshots where id=work_row.current_accepted_snapshot_id;
    if new.accepted_work_snapshot_id is null then new.accepted_work_snapshot_id:=snapshot_row.id;end if;
    if new.accepted_work_snapshot_id<>snapshot_row.id and not coalesce(private.work_snapshots_physically_equal_v2(new.accepted_work_snapshot_id,snapshot_row.id),false) then
      if coalesce(current_setting('app.exhibition_layout_clone_rpc',true),'')<>'on' then
        raise exception '配置が現在の物理仕様と一致しません。';
      end if;
      select * into snapshot_row from public.exhibition_work_submission_snapshots
      where id=new.accepted_work_snapshot_id and work_id=work_row.id;
      if snapshot_row.id is null then raise exception '複製元PlacementのWork Snapshotが不正です。';end if;
    end if;
    width_value:=snapshot_row.occupied_width_mm;height_value:=snapshot_row.occupied_height_mm;
   else width_value:=work_row.occupied_width_mm;height_value:=work_row.occupied_height_mm;end if;
 else
   if new.work_id is not null or new.accepted_work_snapshot_id is not null then raise exception 'Smartphone Group Placementに個別Workを設定できません。';end if;
   select * into group_row from public.exhibition_smartphone_display_groups where id=item_row.smartphone_group_id;
   if group_row.width_mm is null or group_row.height_mm is null then raise exception 'Smartphone Groupの占有外寸を設定してください。';end if;
   if not exists(select 1 from public.exhibition_smartphone_works sw where sw.event_id=layout_row.event_id and sw.workflow_state='accepted' and sw.current_accepted_snapshot_id is not null) then raise exception 'accepted Smartphone Workがありません。';end if;
   width_value:=group_row.width_mm;height_value:=group_row.height_mm;
 end if;
 if new.status<>'placed' then return new;end if;
 if new.x_mm+width_value>wall_row.width_mm or new.top_from_floor_mm>wall_row.height_mm or new.top_from_floor_mm-height_value<0 then raise exception '展示物が壁面の範囲を超えています。';end if;
 return new;
end;$$;
