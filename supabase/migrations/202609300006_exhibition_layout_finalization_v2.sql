-- 写真展Workflow v2 Phase 6: Layout Plan finalization / display number / reconfirmation。

alter table public.exhibition_placements
  add column if not exists accepted_work_snapshot_id uuid references public.exhibition_work_submission_snapshots(id) on delete restrict,
  add column if not exists viewing_order integer check(viewing_order is null or viewing_order>=1);
create unique index if not exists exhibition_placements_viewing_order_unique
  on public.exhibition_placements(layout_id,viewing_order) where status='placed' and viewing_order is not null;

create table public.exhibition_work_display_numbers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  work_id uuid not null unique references public.exhibition_works(id) on delete restrict,
  display_no integer not null check(display_no>=1),
  first_finalization_id uuid,
  assigned_by text not null,
  assigned_at timestamptz not null default now(),
  unique(event_id,display_no)
);

create table public.exhibition_layout_finalizations (
  id uuid primary key default gen_random_uuid(),
  layout_id uuid not null references public.exhibition_layouts(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  finalization_version integer not null check(finalization_version>=1),
  previous_finalization_id uuid references public.exhibition_layout_finalizations(id) on delete restrict,
  is_reconfirmation boolean not null default false,
  reason text not null default '',
  finalized_by text not null,
  finalized_at timestamptz not null default now(),
  unique(event_id,finalization_version),
  unique(layout_id)
);

create table public.exhibition_layout_finalization_items (
  id uuid primary key default gen_random_uuid(),
  finalization_id uuid not null references public.exhibition_layout_finalizations(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  work_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  wall_id uuid not null references public.exhibition_walls(id) on delete restrict,
  viewing_order integer not null check(viewing_order>=1),
  display_no integer not null check(display_no>=1),
  x_mm numeric(10,2) not null,
  top_from_floor_mm numeric(10,2) not null,
  z_order integer not null,
  occupied_width_mm numeric(10,2) not null check(occupied_width_mm>0),
  occupied_height_mm numeric(10,2) not null check(occupied_height_mm>0),
  orientation text not null,
  print_size text not null,
  print_size_detail text not null default '',
  unique(finalization_id,work_id),
  unique(finalization_id,viewing_order),
  unique(finalization_id,display_no)
);

alter table public.exhibition_layouts
  add column if not exists current_finalization_id uuid references public.exhibition_layout_finalizations(id) on delete restrict;
alter table public.exhibition_work_display_numbers
  add constraint exhibition_display_numbers_first_finalization_fk foreign key(first_finalization_id)
  references public.exhibition_layout_finalizations(id) on delete restrict;

create or replace function private.prevent_exhibition_layout_finalization_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception '確定済みLayout Plan履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_layout_finalizations_immutable before update or delete on public.exhibition_layout_finalizations
for each row execute function private.prevent_exhibition_layout_finalization_mutation();
create trigger exhibition_layout_finalization_items_immutable before update or delete on public.exhibition_layout_finalization_items
for each row execute function private.prevent_exhibition_layout_finalization_mutation();
create trigger exhibition_display_numbers_immutable before update or delete on public.exhibition_work_display_numbers
for each row execute function private.prevent_exhibition_layout_finalization_mutation();

create or replace function private.work_snapshots_physically_equal_v2(p_left uuid,p_right uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select l.orientation=r.orientation and l.print_size=r.print_size and l.print_size_detail=r.print_size_detail
    and l.occupied_width_mm=r.occupied_width_mm and l.occupied_height_mm=r.occupied_height_mm
  from public.exhibition_work_submission_snapshots l,public.exhibition_work_submission_snapshots r
  where l.id=p_left and r.id=p_right and l.work_id=r.work_id
$$;

create or replace function private.layout_requires_physical_reconfirmation_v2(p_event_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.exhibition_layout_finalizations f
    join public.exhibition_layout_finalization_items i on i.finalization_id=f.id
    join public.exhibition_works w on w.id=i.work_id
    where f.id=(select x.id from public.exhibition_layout_finalizations x where x.event_id=p_event_id order by x.finalization_version desc limit 1)
      and w.workflow_state='accepted' and w.current_accepted_snapshot_id is distinct from i.work_submission_snapshot_id
      and not coalesce(private.work_snapshots_physically_equal_v2(w.current_accepted_snapshot_id,i.work_submission_snapshot_id),false)
  ) or exists(
    select 1 from public.exhibition_works w join public.events e on e.id=w.event_id
    where w.event_id=p_event_id and e.exhibition_workflow_version=2 and w.workflow_state='accepted'
      and not exists(
        select 1 from public.exhibition_layout_finalizations f join public.exhibition_layout_finalization_items i on i.finalization_id=f.id
        where f.id=(select x.id from public.exhibition_layout_finalizations x where x.event_id=p_event_id order by x.finalization_version desc limit 1)
          and i.work_id=w.id
      )
  )
$$;

-- v2 PlacementはAccepted Work Snapshotへ固定し、物理寸法もimmutable Snapshotから検証する。
create or replace function private.validate_exhibition_placement()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_layout public.exhibition_layouts%rowtype; target_work public.exhibition_works%rowtype;
  target_wall public.exhibition_walls%rowtype; target_event public.events%rowtype; source public.exhibition_work_submission_snapshots%rowtype;
  width_mm numeric; height_mm numeric;
begin
  select * into target_layout from public.exhibition_layouts where id=new.layout_id;
  select * into target_work from public.exhibition_works where id=new.work_id;
  select * into target_wall from public.exhibition_walls where id=new.wall_id;
  select * into target_event from public.events where id=target_layout.event_id;
  if target_layout.id is null or target_work.id is null or target_wall.id is null then raise exception '配置案、作品、または壁面が見つかりません。'; end if;
  if target_work.event_id<>target_layout.event_id then raise exception '別の写真展の作品は配置できません。'; end if;
  if target_event.exhibition_venue_id is null or target_wall.venue_id<>target_event.exhibition_venue_id then raise exception '写真展会場に属さない壁面は使用できません。'; end if;
  if not target_wall.usable and new.status='placed' then raise exception '使用不可の壁面には配置できません。'; end if;
  if target_event.exhibition_workflow_version=2 then
    if target_layout.status in ('approved','archived') then raise exception '確定・保管済みLayoutは編集できません。'; end if;
    if new.status<>'placed' then return new; end if;
    if target_work.workflow_state<>'accepted' or target_work.current_accepted_snapshot_id is null then raise exception '確認済みWorkだけをv2 Layoutへ配置できます。'; end if;
    select * into source from public.exhibition_work_submission_snapshots where id=target_work.current_accepted_snapshot_id;
    if new.accepted_work_snapshot_id is null then new.accepted_work_snapshot_id:=source.id; end if;
    if new.accepted_work_snapshot_id<>source.id and not coalesce(private.work_snapshots_physically_equal_v2(new.accepted_work_snapshot_id,source.id),false) then
      if coalesce(current_setting('app.exhibition_layout_clone_rpc',true),'')<>'on' then
        raise exception '配置が現在の物理仕様と一致しません。Snapshotを再確認してください。';
      end if;
      select * into source from public.exhibition_work_submission_snapshots
        where id=new.accepted_work_snapshot_id and work_id=target_work.id;
      if source.id is null then raise exception '複製元PlacementのWork Snapshotが不正です。'; end if;
    end if;
    width_mm:=source.occupied_width_mm; height_mm:=source.occupied_height_mm;
  else
    width_mm:=target_work.occupied_width_mm; height_mm:=target_work.occupied_height_mm;
  end if;
  if width_mm is null or height_mm is null then raise exception '作品の占有外寸を入力してください。'; end if;
  if new.x_mm+width_mm>target_wall.width_mm then raise exception '作品が壁面の右端を超えています。'; end if;
  if new.top_from_floor_mm>target_wall.height_mm or new.top_from_floor_mm-height_mm<0 then raise exception '作品が壁面の上下端を超えています。'; end if;
  return new;
end;
$$;

create or replace function private.protect_v2_display_no()
returns trigger language plpgsql security definer set search_path='' as $$
declare version smallint;
begin
  select exhibition_workflow_version into version from public.events where id=new.event_id;
  if version=2 and new.display_no is distinct from old.display_no then
    if trim(coalesce(old.display_no,''))<>'' then raise exception 'Workflow v2のdisplay_noは変更できません。'; end if;
    if coalesce(current_setting('app.exhibition_layout_finalize_rpc',true),'')<>'on' then raise exception 'Workflow v2のdisplay_noはLayout Finalizationでのみ設定できます。'; end if;
  end if;
  return new;
end;
$$;
create trigger zzz_exhibition_works_protect_v2_display_no before update of display_no on public.exhibition_works
for each row execute function private.protect_v2_display_no();

create or replace function public.admin_refresh_exhibition_placement_snapshot_v2(p_placement_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.exhibition_placements%rowtype; w public.exhibition_works%rowtype; l public.exhibition_layouts%rowtype;
  previous_snapshot uuid; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into p from public.exhibition_placements where id=p_placement_id for update;
  select * into l from public.exhibition_layouts where id=p.layout_id;
  select * into w from public.exhibition_works where id=p.work_id;
  if p.id is null or l.status in ('approved','archived') or w.workflow_state<>'accepted' then raise exception 'Snapshot再確認可能なPlacementではありません。'; end if;
  previous_snapshot:=p.accepted_work_snapshot_id;
  update public.exhibition_placements set accepted_work_snapshot_id=w.current_accepted_snapshot_id,updated_at=now() where id=p.id returning * into p;
  perform private.write_exhibition_workflow_audit(w.event_id,'layout_placement',p.id,'layout_placement_snapshot_refreshed','admin',actor,'',
    jsonb_build_object('previousSnapshotId',previous_snapshot),jsonb_build_object('currentSnapshotId',w.current_accepted_snapshot_id));
  return to_jsonb(p);
end;
$$;

-- 既存cloneを拡張し、UUID・座標・順序・基準Snapshotを次版へ引き継ぐ。
create or replace function public.admin_clone_exhibition_layout(p_layout_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare source_layout public.exhibition_layouts%rowtype; cloned public.exhibition_layouts%rowtype; next_version integer; copied integer; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into source_layout from public.exhibition_layouts where id=p_layout_id for share;
  if source_layout.id is null then raise exception '複製元の配置案が見つかりません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(source_layout.event_id::text||':'||source_layout.name,0));
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_layouts where event_id=source_layout.event_id and name=source_layout.name;
  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by,notes)
    values(source_layout.event_id,source_layout.name,next_version,'draft',false,actor,source_layout.notes) returning * into cloned;
  perform set_config('app.exhibition_layout_clone_rpc','on',true);
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,z_order,locked,status,notes,accepted_work_snapshot_id,viewing_order)
    select cloned.id,p.work_id,p.wall_id,p.x_mm,p.top_from_floor_mm,p.z_order,false,p.status,p.notes,p.accepted_work_snapshot_id,p.viewing_order
    from public.exhibition_placements p
    join public.exhibition_works w on w.id=p.work_id
    join public.events e on e.id=source_layout.event_id
    where p.layout_id=source_layout.id and p.status<>'removed'
      and (e.exhibition_workflow_version<>2 or w.workflow_state='accepted');
  get diagnostics copied=row_count;
  perform set_config('app.exhibition_layout_clone_rpc','off',true);
  return jsonb_build_object('layoutId',cloned.id,'name',cloned.name,'versionNo',cloned.version_no,'copiedPlacements',copied);
end;
$$;

-- Legacyの状態変更RPCは維持するが、v2の確定は必ずimmutable Finalization経由に限定する。
create or replace function public.admin_set_exhibition_layout_status(p_layout_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target_layout public.exhibition_layouts%rowtype; target_event public.events%rowtype;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_status not in ('draft','review','approved','archived') then raise exception '配置案の状態が不正です。'; end if;
  select * into target_layout from public.exhibition_layouts where id=p_layout_id for update;
  if target_layout.id is null then raise exception '配置案が見つかりません。'; end if;
  select * into target_event from public.events where id=target_layout.event_id;
  if target_event.exhibition_workflow_version=2 then
    if target_layout.current_finalization_id is not null then
      raise exception '確定済みLayout Planは変更できません。次の版へ複製してください。';
    end if;
    if p_status='approved' then
      raise exception 'Workflow v2の確定にはLayout Finalizationを使用してください。';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(target_layout.event_id::text,0));
  if p_status='approved' then
    update public.exhibition_layouts set is_current=false where event_id=target_layout.event_id and is_current;
    update public.exhibition_layouts set status='approved',is_current=true where id=p_layout_id returning * into target_layout;
  else
    update public.exhibition_layouts set status=p_status,is_current=false where id=p_layout_id returning * into target_layout;
  end if;
  return jsonb_build_object('layoutId',target_layout.id,'status',target_layout.status,
    'isCurrent',target_layout.is_current,'updatedAt',target_layout.updated_at);
end;
$$;

create or replace function public.admin_finalize_exhibition_layout_v2(p_layout_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_layout public.exhibition_layouts%rowtype; v_event public.events%rowtype; v_placement public.exhibition_placements%rowtype;
  v_work public.exhibition_works%rowtype; v_previous_id uuid; v_final_id uuid; v_next_version integer; v_next_display integer;
  v_eligible_count integer; v_placed_count integer; v_actor text:=private.current_email(); v_assigned integer:=0;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select layout.* into v_layout from public.exhibition_layouts layout where layout.id=p_layout_id for update;
  select event.* into v_event from public.events event where event.id=v_layout.event_id for update;
  if v_layout.id is null or v_event.exhibition_workflow_version<>2 then raise exception 'Workflow v2 Layoutが見つかりません。'; end if;
  if v_layout.status not in ('draft','review') then raise exception '下書きまたは確認中のLayoutだけを確定できます。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_event.id::text,0));
  select count(*) into v_eligible_count from public.exhibition_works work_row
    where work_row.event_id=v_event.id and work_row.workflow_state='accepted';
  select count(*) into v_placed_count from public.exhibition_placements placement_row
    where placement_row.layout_id=v_layout.id and placement_row.status='placed';
  if v_eligible_count=0 or v_placed_count<>v_eligible_count then raise exception '確認済みWorkをすべて1回ずつ配置してください。'; end if;
  if exists(select 1 from public.exhibition_placements placement_row
    join public.exhibition_works work_row on work_row.id=placement_row.work_id
    where placement_row.layout_id=v_layout.id and placement_row.status='placed'
      and (placement_row.viewing_order is null or work_row.workflow_state<>'accepted'
        or placement_row.accepted_work_snapshot_id is distinct from work_row.current_accepted_snapshot_id)) then
    raise exception '鑑賞順またはAccepted Work Snapshotが未確認のPlacementがあります。';
  end if;
  if (select count(distinct placement_row.viewing_order) from public.exhibition_placements placement_row
      where placement_row.layout_id=v_layout.id and placement_row.status='placed')<>v_eligible_count then raise exception '鑑賞順が重複または不足しています。'; end if;
  select finalization.id into v_previous_id from public.exhibition_layout_finalizations finalization
    where finalization.event_id=v_event.id order by finalization.finalization_version desc limit 1;
  select coalesce(max(finalization.finalization_version),0)+1 into v_next_version
    from public.exhibition_layout_finalizations finalization where finalization.event_id=v_event.id;
  if v_previous_id is not null and trim(coalesce(p_reason,''))='' then raise exception '再確定理由を入力してください。'; end if;
  insert into public.exhibition_layout_finalizations(layout_id,event_id,finalization_version,previous_finalization_id,is_reconfirmation,reason,finalized_by)
    values(v_layout.id,v_event.id,v_next_version,v_previous_id,v_previous_id is not null,coalesce(p_reason,''),v_actor) returning id into v_final_id;
  select coalesce(max(display_number.display_no),0) into v_next_display
    from public.exhibition_work_display_numbers display_number where display_number.event_id=v_event.id;
  for v_placement in select placement_row.* from public.exhibition_placements placement_row
    where placement_row.layout_id=v_layout.id and placement_row.status='placed'
    order by placement_row.viewing_order for update
  loop
    select work_row.* into v_work from public.exhibition_works work_row where work_row.id=v_placement.work_id for update;
    if not exists(select 1 from public.exhibition_work_display_numbers display_number where display_number.work_id=v_work.id) then
      v_next_display:=v_next_display+1;
      insert into public.exhibition_work_display_numbers(event_id,work_id,display_no,first_finalization_id,assigned_by)
        values(v_event.id,v_work.id,v_next_display,v_final_id,v_actor);
      perform set_config('app.exhibition_work_rpc','on',true);
      perform set_config('app.exhibition_layout_finalize_rpc','on',true);
      update public.exhibition_works work_row set display_no=v_next_display::text,updated_at=now() where work_row.id=v_work.id;
      perform set_config('app.exhibition_layout_finalize_rpc','off',true);
      perform set_config('app.exhibition_work_rpc','off',true);
      perform private.write_exhibition_workflow_audit(v_event.id,'work',v_work.id,'display_no_assigned','admin',v_actor,p_reason,
        jsonb_build_object('displayNo',null),jsonb_build_object('displayNo',v_next_display,'firstFinalizationId',v_final_id));
      v_assigned:=v_assigned+1;
    end if;
    insert into public.exhibition_layout_finalization_items(finalization_id,event_id,work_id,work_submission_snapshot_id,wall_id,
      viewing_order,display_no,x_mm,top_from_floor_mm,z_order,occupied_width_mm,occupied_height_mm,orientation,print_size,print_size_detail)
    select v_final_id,v_event.id,v_work.id,snapshot.id,v_placement.wall_id,v_placement.viewing_order,display_number.display_no,
      v_placement.x_mm,v_placement.top_from_floor_mm,v_placement.z_order,snapshot.occupied_width_mm,snapshot.occupied_height_mm,
      snapshot.orientation,snapshot.print_size,snapshot.print_size_detail
    from public.exhibition_work_submission_snapshots snapshot
    join public.exhibition_work_display_numbers display_number on display_number.work_id=v_work.id
    where snapshot.id=v_work.current_accepted_snapshot_id;
  end loop;
  update public.exhibition_layouts layout set is_current=false where layout.event_id=v_event.id and layout.is_current;
  update public.exhibition_layouts layout set status='approved',is_current=true,current_finalization_id=v_final_id where layout.id=v_layout.id;
  perform private.write_exhibition_workflow_audit(v_event.id,'layout_finalization',v_final_id,
    case when v_previous_id is null then 'layout_finalized' else 'layout_reconfirmed' end,'admin',v_actor,p_reason,'{}',
    jsonb_build_object('layoutId',v_layout.id,'version',v_next_version,'assignedDisplayNumbers',v_assigned,'plannedOnly',true));
  return jsonb_build_object('finalizationId',v_final_id,'version',v_next_version,'assignedDisplayNumbers',v_assigned,'isReconfirmation',v_previous_id is not null);
end;
$$;

create or replace function public.admin_get_exhibition_layout_actions_v2(p_event_id uuid default null)
returns table(
  priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,
  member_id uuid,member_name text,snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,
  workflow_state text,occurred_at timestamptz,reason text,context jsonb
)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query
  with eligible as (
    select w.*,e.title event_title,en.id entry_uuid,m.name member_name_value
    from public.exhibition_works w join public.events e on e.id=w.event_id and e.exhibition_workflow_version=2
    join public.exhibition_entries en on en.id=w.entry_id join public.members m on m.id=w.owner_member_id
    where w.workflow_state='accepted' and (p_event_id is null or e.id=p_event_id)
  ), latest_layout as (
    select distinct on(layout.event_id) layout.* from public.exhibition_layouts layout
    where layout.status<>'archived'
    order by layout.event_id,layout.is_current desc,layout.updated_at desc,layout.version_no desc,layout.id desc
  ), latest_editable_layout as (
    select distinct on(layout.event_id) layout.* from public.exhibition_layouts layout
    where layout.status in ('draft','review')
    order by layout.event_id,layout.updated_at desc,layout.version_no desc,layout.id desc
  ), latest_final as (
    select distinct on(finalization.event_id) finalization.* from public.exhibition_layout_finalizations finalization
    order by finalization.event_id,finalization.finalization_version desc
  )
  select 35,'organizer_task','layout_unplaced',w.event_id,w.event_title,w.entry_uuid,w.id,w.owner_member_id,w.member_name_value,
    w.current_accepted_snapshot_id,null::uuid,null::timestamptz,w.workflow_state,w.updated_at,'確認済みWorkがLayout Planへ未配置',
    jsonb_build_object('label','確認済みWorkをLayout Planへ配置してください','layoutId',l.id)
  from eligible w left join latest_layout l on l.event_id=w.event_id
  where l.id is null or not exists(select 1 from public.exhibition_placements p where p.layout_id=l.id and p.work_id=w.id and p.status='placed')
  union all
  select 5,'deadline_attention','layout_reconfirmation_required',w.event_id,w.event_title,w.entry_uuid,w.id,w.owner_member_id,w.member_name_value,
    w.current_accepted_snapshot_id,null::uuid,null::timestamptz,w.workflow_state,w.updated_at,'確定後に物理仕様または対象Workが変更',
    jsonb_build_object('label','確定済みLayout Planの再確認が必要です','previousFinalizationId',f.id)
  from eligible w join latest_final f on f.event_id=w.event_id
  where not exists(select 1 from public.exhibition_layout_finalization_items i where i.finalization_id=f.id and i.work_id=w.id)
     or exists(select 1 from public.exhibition_layout_finalization_items i where i.finalization_id=f.id and i.work_id=w.id
       and i.work_submission_snapshot_id is distinct from w.current_accepted_snapshot_id
       and not coalesce(private.work_snapshots_physically_equal_v2(i.work_submission_snapshot_id,w.current_accepted_snapshot_id),false))
  union all
  select 15,'organizer_task','layout_placement_snapshot_stale',w.event_id,w.event_title,w.entry_uuid,w.id,w.owner_member_id,w.member_name_value,
    w.current_accepted_snapshot_id,null::uuid,null::timestamptz,w.workflow_state,p.updated_at,'Placementの物理Snapshotが古い',
    jsonb_build_object('label','Placementを現在の物理仕様へ再確認してください','layoutId',l.id,'placementId',p.id)
  from eligible w join latest_editable_layout l on l.event_id=w.event_id join public.exhibition_placements p on p.layout_id=l.id and p.work_id=w.id and p.status='placed'
  where p.accepted_work_snapshot_id is distinct from w.current_accepted_snapshot_id
    and not coalesce(private.work_snapshots_physically_equal_v2(p.accepted_work_snapshot_id,w.current_accepted_snapshot_id),false);
end;
$$;

alter table public.exhibition_layout_finalizations enable row level security;
alter table public.exhibition_layout_finalization_items enable row level security;
alter table public.exhibition_work_display_numbers enable row level security;
revoke all on public.exhibition_layout_finalizations,public.exhibition_layout_finalization_items,public.exhibition_work_display_numbers from anon,authenticated;
grant select on public.exhibition_layout_finalizations,public.exhibition_layout_finalization_items,public.exhibition_work_display_numbers to authenticated;
create policy layout_finalizations_admin_select on public.exhibition_layout_finalizations for select to authenticated using(private.is_admin());
create policy layout_finalization_items_admin_select on public.exhibition_layout_finalization_items for select to authenticated using(private.is_admin());
create policy display_numbers_admin_select on public.exhibition_work_display_numbers for select to authenticated using(private.is_admin());

revoke all on function public.admin_refresh_exhibition_placement_snapshot_v2(uuid),public.admin_finalize_exhibition_layout_v2(uuid,text),
  public.admin_get_exhibition_layout_actions_v2(uuid),public.admin_set_exhibition_layout_status(uuid,text) from public,anon;
grant execute on function public.admin_refresh_exhibition_placement_snapshot_v2(uuid),public.admin_finalize_exhibition_layout_v2(uuid,text),
  public.admin_get_exhibition_layout_actions_v2(uuid),public.admin_set_exhibition_layout_status(uuid,text) to authenticated;
