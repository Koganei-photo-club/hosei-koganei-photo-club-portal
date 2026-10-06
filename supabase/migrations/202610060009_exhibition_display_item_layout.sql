-- Smartphone Phase 2 / Step 2: Display Items in Layout and common numbering.

alter table public.exhibition_placements
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict;
alter table public.exhibition_placements alter column work_id drop not null;
alter table public.exhibition_placements alter column accepted_work_snapshot_id drop not null;
create unique index exhibition_placements_active_display_item_unique
  on public.exhibition_placements(layout_id,display_item_id) where status<>'removed' and display_item_id is not null;
update public.exhibition_placements placement_row
set display_item_id=item_row.id
from public.exhibition_display_items item_row
where placement_row.display_item_id is null and item_row.regular_work_id=placement_row.work_id;

alter table public.exhibition_layout_finalization_items
  add column display_item_id uuid references public.exhibition_display_items(id) on delete restrict,
  add column smartphone_group_version_id uuid references public.exhibition_smartphone_group_versions(id) on delete restrict;
alter table public.exhibition_layout_finalization_items alter column work_id drop not null;
alter table public.exhibition_layout_finalization_items alter column work_submission_snapshot_id drop not null;
alter table public.exhibition_layout_finalization_items add constraint exhibition_layout_finalization_item_source_check check(
  (work_id is not null and work_submission_snapshot_id is not null and smartphone_group_version_id is null)
  or (display_item_id is not null and work_id is null and work_submission_snapshot_id is null and smartphone_group_version_id is not null)
);
create unique index exhibition_layout_finalization_items_display_unique
  on public.exhibition_layout_finalization_items(finalization_id,display_item_id) where display_item_id is not null;

create table public.exhibition_display_item_numbers(
  id uuid primary key default gen_random_uuid(),event_id uuid not null references public.events(id) on delete restrict,
  display_item_id uuid not null unique references public.exhibition_display_items(id) on delete restrict,
  display_no integer not null check(display_no>=1),first_finalization_id uuid references public.exhibition_layout_finalizations(id) on delete restrict,
  assigned_by text not null,assigned_at timestamptz not null default now(),unique(event_id,display_no)
);
insert into public.exhibition_display_item_numbers(event_id,display_item_id,display_no,first_finalization_id,assigned_by,assigned_at)
select number_row.event_id,item_row.id,number_row.display_no,number_row.first_finalization_id,number_row.assigned_by,number_row.assigned_at
from public.exhibition_work_display_numbers number_row join public.exhibition_display_items item_row on item_row.regular_work_id=number_row.work_id
on conflict(display_item_id) do nothing;
create trigger exhibition_display_item_numbers_immutable before update or delete on public.exhibition_display_item_numbers
for each row execute function private.prevent_exhibition_layout_finalization_mutation();

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

create or replace function public.admin_get_exhibition_layout_candidates_v1(p_event_id uuid)
returns table(display_item_id uuid,item_type text,regular_work_id uuid,smartphone_group_id uuid,label text,width_mm numeric,height_mm numeric,
 display_no integer,accepted_work_snapshot_id uuid,preview_image_path text,sort_order integer)
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 return query
 select di.id,di.item_type,di.regular_work_id,di.smartphone_group_id,w.title,s.occupied_width_mm,s.occupied_height_mm,
  n.display_no,w.current_accepted_snapshot_id,w.preview_image_path,w.sort_order
 from public.exhibition_display_items di join public.exhibition_works w on w.id=di.regular_work_id
 join public.exhibition_work_submission_snapshots s on s.id=w.current_accepted_snapshot_id
 left join public.exhibition_display_item_numbers n on n.display_item_id=di.id
 where di.event_id=p_event_id and di.item_type='regular_work' and w.workflow_state='accepted'
 union all
 select di.id,di.item_type,null,g.id,g.display_name,g.width_mm,g.height_mm,n.display_no,null,null,2147483647
 from public.exhibition_display_items di join public.exhibition_smartphone_display_groups g on g.id=di.smartphone_group_id
 left join public.exhibition_display_item_numbers n on n.display_item_id=di.id
 where di.event_id=p_event_id and di.item_type='smartphone_group' and g.width_mm>0 and g.height_mm>0
  and exists(select 1 from public.exhibition_smartphone_works sw where sw.event_id=p_event_id and sw.workflow_state='accepted' and sw.current_accepted_snapshot_id is not null)
 order by 11,1;
end;$$;

create or replace function public.admin_clone_exhibition_layout(p_layout_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare source_layout public.exhibition_layouts%rowtype;cloned public.exhibition_layouts%rowtype;next_version integer;copied integer;actor text:=private.current_email();
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into source_layout from public.exhibition_layouts where id=p_layout_id for share;
 if source_layout.id is null then raise exception '複製元の配置案が見つかりません。';end if;
 select coalesce(max(version_no),0)+1 into next_version from public.exhibition_layouts where event_id=source_layout.event_id and name=source_layout.name;
 insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by,notes) values(source_layout.event_id,source_layout.name,next_version,'draft',false,actor,source_layout.notes) returning * into cloned;
 perform set_config('app.exhibition_layout_clone_rpc','on',true);
 insert into public.exhibition_placements(layout_id,work_id,display_item_id,wall_id,x_mm,top_from_floor_mm,z_order,locked,status,notes,accepted_work_snapshot_id,viewing_order)
 select cloned.id,p.work_id,p.display_item_id,p.wall_id,p.x_mm,p.top_from_floor_mm,p.z_order,false,p.status,p.notes,p.accepted_work_snapshot_id,p.viewing_order
 from public.exhibition_placements p
 join public.events event_row on event_row.id=source_layout.event_id
 left join public.exhibition_display_items item_row on item_row.id=p.display_item_id
 left join public.exhibition_works work_row on work_row.id=p.work_id
 where p.layout_id=source_layout.id and p.status<>'removed'
   and (event_row.exhibition_workflow_version<>2
     or (item_row.item_type='regular_work' and work_row.workflow_state='accepted')
     or (item_row.item_type='smartphone_group' and exists(
       select 1 from public.exhibition_smartphone_works smartphone_work
       where smartphone_work.event_id=source_layout.event_id and smartphone_work.workflow_state='accepted'
         and smartphone_work.current_accepted_snapshot_id is not null
     )));
 get diagnostics copied=row_count;perform set_config('app.exhibition_layout_clone_rpc','off',true);
 return jsonb_build_object('layoutId',cloned.id,'name',cloned.name,'versionNo',cloned.version_no,'copiedPlacements',copied);
end;$$;

create or replace function public.admin_finalize_exhibition_layout_v2(p_layout_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare l public.exhibition_layouts%rowtype;e public.events%rowtype;p public.exhibition_placements%rowtype;di public.exhibition_display_items%rowtype;
 w public.exhibition_works%rowtype;g public.exhibition_smartphone_display_groups%rowtype;gv jsonb;previous_id uuid;final_id uuid;next_version integer;next_no integer;
 eligible integer;placed integer;actor text:=private.current_email();assigned integer:=0;number_value integer;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into l from public.exhibition_layouts where id=p_layout_id for update;select * into e from public.events where id=l.event_id for update;
 if l.id is null or e.exhibition_workflow_version<>2 or l.status not in('draft','review') then raise exception '確定可能なWorkflow v2 Layoutがありません。';end if;
 perform pg_advisory_xact_lock(hashtextextended(e.id::text,0));
 select count(*) into eligible from public.exhibition_display_items item where item.event_id=e.id and ((item.item_type='regular_work' and exists(select 1 from public.exhibition_works x where x.id=item.regular_work_id and x.workflow_state='accepted')) or (item.item_type='smartphone_group' and exists(select 1 from public.exhibition_smartphone_display_groups x where x.id=item.smartphone_group_id and x.width_mm>0 and x.height_mm>0) and exists(select 1 from public.exhibition_smartphone_works x where x.event_id=e.id and x.workflow_state='accepted' and x.current_accepted_snapshot_id is not null)));
 select count(*) into placed from public.exhibition_placements x where x.layout_id=l.id and x.status='placed';
 if eligible=0 or placed<>eligible or exists(select 1 from public.exhibition_placements x where x.layout_id=l.id and x.status='placed' and (x.display_item_id is null or x.viewing_order is null)) then raise exception '配置可能なDisplay Itemをすべて1回ずつ配置してください。';end if;
 if (select count(distinct x.viewing_order) from public.exhibition_placements x where x.layout_id=l.id and x.status='placed')<>eligible then raise exception '鑑賞順が重複または不足しています。';end if;
 select id into previous_id from public.exhibition_layout_finalizations where event_id=e.id order by finalization_version desc limit 1;select coalesce(max(finalization_version),0)+1 into next_version from public.exhibition_layout_finalizations where event_id=e.id;
 if previous_id is not null and trim(coalesce(p_reason,''))='' then raise exception '再確定理由を入力してください。';end if;
 insert into public.exhibition_layout_finalizations(layout_id,event_id,finalization_version,previous_finalization_id,is_reconfirmation,reason,finalized_by) values(l.id,e.id,next_version,previous_id,previous_id is not null,coalesce(p_reason,''),actor) returning id into final_id;
 select coalesce(max(display_no),0) into next_no from public.exhibition_display_item_numbers where event_id=e.id;
 for p in select * from public.exhibition_placements x where x.layout_id=l.id and x.status='placed' order by x.viewing_order for update loop
  select * into di from public.exhibition_display_items where id=p.display_item_id;
  select display_no into number_value from public.exhibition_display_item_numbers where display_item_id=di.id;
  if number_value is null then next_no:=next_no+1;number_value:=next_no;insert into public.exhibition_display_item_numbers(event_id,display_item_id,display_no,first_finalization_id,assigned_by) values(e.id,di.id,number_value,final_id,actor);assigned:=assigned+1;end if;
  if di.item_type='regular_work' then
   select * into w from public.exhibition_works where id=di.regular_work_id for update;
   if w.workflow_state<>'accepted' or p.accepted_work_snapshot_id is distinct from w.current_accepted_snapshot_id then raise exception 'Accepted Work Snapshotが未確認です。';end if;
   if not exists(select 1 from public.exhibition_work_display_numbers n where n.work_id=w.id) then
    insert into public.exhibition_work_display_numbers(event_id,work_id,display_no,first_finalization_id,assigned_by) values(e.id,w.id,number_value,final_id,actor);
    perform set_config('app.exhibition_work_rpc','on',true);perform set_config('app.exhibition_layout_finalize_rpc','on',true);
    update public.exhibition_works set display_no=number_value::text where id=w.id;
    perform set_config('app.exhibition_layout_finalize_rpc','off',true);perform set_config('app.exhibition_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(e.id,'work',w.id,'display_no_assigned','admin',actor,p_reason,
      jsonb_build_object('displayNo',null),jsonb_build_object('displayNo',number_value,'firstFinalizationId',final_id));
   end if;
   insert into public.exhibition_layout_finalization_items(finalization_id,event_id,display_item_id,work_id,work_submission_snapshot_id,wall_id,viewing_order,display_no,x_mm,top_from_floor_mm,z_order,occupied_width_mm,occupied_height_mm,orientation,print_size,print_size_detail)
   select final_id,e.id,di.id,w.id,s.id,p.wall_id,p.viewing_order,number_value,p.x_mm,p.top_from_floor_mm,p.z_order,s.occupied_width_mm,s.occupied_height_mm,s.orientation,s.print_size,s.print_size_detail from public.exhibition_work_submission_snapshots s where s.id=w.current_accepted_snapshot_id;
  else
   select * into g from public.exhibition_smartphone_display_groups where id=di.smartphone_group_id;
   if g.width_mm is null or g.height_mm is null then raise exception 'Smartphone Groupの占有外寸がありません。';end if;
   gv:=public.admin_create_exhibition_smartphone_group_version_v1(e.id);
   insert into public.exhibition_layout_finalization_items(finalization_id,event_id,display_item_id,smartphone_group_version_id,wall_id,viewing_order,display_no,x_mm,top_from_floor_mm,z_order,occupied_width_mm,occupied_height_mm,orientation,print_size,print_size_detail)
   values(final_id,e.id,di.id,(gv->>'groupVersionId')::uuid,p.wall_id,p.viewing_order,number_value,p.x_mm,p.top_from_floor_mm,p.z_order,g.width_mm,g.height_mm,'group','smartphone_group','');
  end if;
 end loop;
 update public.exhibition_layouts set is_current=false where event_id=e.id and is_current;update public.exhibition_layouts set status='approved',is_current=true,current_finalization_id=final_id where id=l.id;
 perform private.write_exhibition_workflow_audit(e.id,'layout_finalization',final_id,
  case when previous_id is null then 'layout_finalized' else 'layout_reconfirmed' end,'admin',actor,coalesce(p_reason,''),
  case when previous_id is null then '{}'::jsonb else jsonb_build_object('previousFinalizationId',previous_id) end,
  jsonb_build_object('layoutId',l.id,'version',next_version,'assignedDisplayNumbers',assigned,'plannedOnly',true));
 return jsonb_build_object('finalizationId',final_id,'version',next_version,'assignedDisplayNumbers',assigned,'isReconfirmation',previous_id is not null);
end;$$;

create or replace view public.exhibition_smartphone_display_items as
select distinct version_row.event_id,work_row.member_id from public.exhibition_smartphone_group_version_items item_row join public.exhibition_smartphone_group_versions version_row on version_row.id=item_row.group_version_id join public.exhibition_smartphone_works work_row on work_row.id=item_row.smartphone_work_id
union
select distinct layout_row.event_id,work_row.member_id from public.exhibition_placements placement_row join public.exhibition_layouts layout_row on layout_row.id=placement_row.layout_id join public.exhibition_display_items display_row on display_row.id=placement_row.display_item_id join public.exhibition_smartphone_works work_row on work_row.event_id=layout_row.event_id where display_row.item_type='smartphone_group' and placement_row.status<>'removed';
revoke all on public.exhibition_smartphone_display_items from public,anon,authenticated;

alter table public.exhibition_display_item_numbers enable row level security;revoke all on public.exhibition_display_item_numbers from anon,authenticated;grant select on public.exhibition_display_item_numbers to authenticated;
create policy exhibition_display_item_numbers_admin_select on public.exhibition_display_item_numbers for select to authenticated using(private.is_admin());
revoke all on function public.admin_get_exhibition_layout_candidates_v1(uuid) from public,anon;grant execute on function public.admin_get_exhibition_layout_candidates_v1(uuid) to authenticated;
