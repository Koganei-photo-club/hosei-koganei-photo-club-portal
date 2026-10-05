-- 写真展Workflow v2 Phase 9: Actual Exhibition Record（Planとは独立した実展示事実）。

create table public.exhibition_actual_versions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  state text not null default 'draft' check(state in ('draft','finalized')),
  source_layout_finalization_id uuid not null references public.exhibition_layout_finalizations(id) on delete restrict,
  correction_of_id uuid references public.exhibition_actual_versions(id) on delete restrict,
  reason text not null default '' check(char_length(reason)<=3000),note text not null default '' check(char_length(note)<=3000),
  created_by text not null,created_at timestamptz not null default now(),
  finalized_by text,finalized_at timestamptz,
  unique(event_id,version_no),
  check((state='draft' and finalized_by is null and finalized_at is null) or
        (state='finalized' and finalized_by is not null and finalized_at is not null)),
  check(correction_of_id is null or trim(reason)<>'')
);
create unique index exhibition_actual_one_draft_per_event on public.exhibition_actual_versions(event_id) where state='draft';

create table public.exhibition_actual_items (
  id uuid primary key default gen_random_uuid(),
  actual_version_id uuid not null references public.exhibition_actual_versions(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  source_layout_item_id uuid not null references public.exhibition_layout_finalization_items(id) on delete restrict,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  display_no integer not null check(display_no>=1),
  work_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  caption_submission_snapshot_id uuid references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  actual_state text not null default 'unconfirmed' check(actual_state in ('unconfirmed','exhibited','not_exhibited')),
  planned_wall_id uuid not null references public.exhibition_walls(id) on delete restrict,
  planned_x_mm numeric(10,2) not null,planned_top_from_floor_mm numeric(10,2) not null,planned_z_order integer not null,
  actual_wall_id uuid references public.exhibition_walls(id) on delete restrict,
  actual_x_mm numeric(10,2),actual_top_from_floor_mm numeric(10,2),actual_z_order integer,
  caption_exception boolean not null default false,
  note text not null default '' check(char_length(note)<=3000),updated_by text not null,updated_at timestamptz not null default now(),
  unique(actual_version_id,work_id),unique(actual_version_id,display_no),unique(actual_version_id,source_layout_item_id),
  check(actual_x_mm is null or actual_x_mm>=0),check(actual_top_from_floor_mm is null or actual_top_from_floor_mm>=0),
  check(actual_z_order is null or actual_z_order>=0),
  check(not caption_exception or trim(note)<>'')
);

create or replace function private.protect_exhibition_actual_history_v2()
returns trigger language plpgsql security definer set search_path='' as $$
declare finalized boolean;
begin
  if tg_table_name='exhibition_actual_versions' then
    if old.state='finalized' then raise exception '確定済みActual Exhibition Recordは変更または削除できません。'; end if;
  else
    select state='finalized' into finalized from public.exhibition_actual_versions where id=old.actual_version_id;
    if finalized then raise exception '確定済みActual Exhibition Itemは変更または削除できません。'; end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
create trigger exhibition_actual_versions_history_immutable before update or delete on public.exhibition_actual_versions
for each row execute function private.protect_exhibition_actual_history_v2();
create trigger exhibition_actual_items_history_immutable before update or delete on public.exhibition_actual_items
for each row execute function private.protect_exhibition_actual_history_v2();

create or replace function public.admin_initialize_exhibition_actual_v2(
  p_layout_finalization_id uuid,p_correction_of_id uuid default null,p_reason text default '',p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare f public.exhibition_layout_finalizations%rowtype;e public.events%rowtype;prior public.exhibition_actual_versions%rowtype;
  actual_id uuid;next_version integer;actor text:=private.current_email();item_count integer;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into f from public.exhibition_layout_finalizations where id=p_layout_finalization_id;
  select * into e from public.events where id=f.event_id for update;
  if f.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2の確定済みLayoutが見つかりません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':actual',0));
  if exists(select 1 from public.exhibition_actual_versions where event_id=e.id and state='draft') then raise exception '編集中のActual Draftが既にあります。'; end if;
  if p_correction_of_id is null and exists(select 1 from public.exhibition_actual_versions where event_id=e.id and state='finalized') then
    raise exception '確定後の新Versionは訂正元Actualと理由を指定してください。';
  end if;
  if p_correction_of_id is not null then
    select * into prior from public.exhibition_actual_versions where id=p_correction_of_id and event_id=e.id and state='finalized';
    if prior.id is null or trim(coalesce(p_reason,''))='' then raise exception '確定済みActualと訂正理由が必要です。'; end if;
    if prior.source_layout_finalization_id<>f.id then raise exception '訂正版は元Actualと同じPlanを基準にしてください。'; end if;
  end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_actual_versions where event_id=e.id;
  insert into public.exhibition_actual_versions(event_id,version_no,source_layout_finalization_id,correction_of_id,reason,note,created_by)
    values(e.id,next_version,f.id,p_correction_of_id,coalesce(p_reason,''),coalesce(p_note,''),actor) returning id into actual_id;
  if prior.id is null then
    insert into public.exhibition_actual_items(actual_version_id,event_id,source_layout_item_id,work_id,display_no,
      work_submission_snapshot_id,caption_submission_snapshot_id,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,
      actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,updated_by)
    select actual_id,e.id,i.id,i.work_id,i.display_no,i.work_submission_snapshot_id,
      (select cs.id from public.exhibition_caption_submission_snapshots cs join public.exhibition_caption_reviews r on r.caption_snapshot_id=cs.id and r.result='accepted'
       where cs.work_id=i.work_id and cs.work_submission_snapshot_id=i.work_submission_snapshot_id
       order by r.reviewed_at desc,cs.version_no desc,cs.id desc limit 1),
      i.wall_id,i.x_mm,i.top_from_floor_mm,i.z_order,i.wall_id,i.x_mm,i.top_from_floor_mm,i.z_order,actor
    from public.exhibition_layout_finalization_items i where i.finalization_id=f.id order by i.viewing_order;
  else
    insert into public.exhibition_actual_items(actual_version_id,event_id,source_layout_item_id,work_id,display_no,
      work_submission_snapshot_id,caption_submission_snapshot_id,actual_state,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,
      actual_wall_id,actual_x_mm,actual_top_from_floor_mm,actual_z_order,caption_exception,note,updated_by)
    select actual_id,event_id,source_layout_item_id,work_id,display_no,work_submission_snapshot_id,caption_submission_snapshot_id,
      actual_state,planned_wall_id,planned_x_mm,planned_top_from_floor_mm,planned_z_order,actual_wall_id,actual_x_mm,
      actual_top_from_floor_mm,actual_z_order,caption_exception,note,actor from public.exhibition_actual_items where actual_version_id=prior.id;
  end if;
  get diagnostics item_count=row_count;
  if item_count=0 then raise exception 'Actual対象のPlan Itemがありません。'; end if;
  perform private.write_exhibition_workflow_audit(e.id,'actual_version',actual_id,
    case when prior.id is null then 'actual_draft_initialized' else 'actual_correction_draft_initialized' end,
    'admin',actor,p_reason,'{}',jsonb_build_object('versionNo',next_version,'sourceLayoutFinalizationId',f.id,'correctionOfId',prior.id,'itemCount',item_count));
  return jsonb_build_object('actualVersionId',actual_id,'versionNo',next_version,'itemCount',item_count,'correctionOfId',prior.id);
end;
$$;

create or replace function public.admin_update_exhibition_actual_item_v2(
  p_item_id uuid,p_actual_state text,p_actual_wall_id uuid,p_actual_x_mm numeric,p_actual_top_from_floor_mm numeric,
  p_actual_z_order integer,p_work_snapshot_id uuid,p_caption_snapshot_id uuid,p_caption_exception boolean default false,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.exhibition_actual_items%rowtype;v public.exhibition_actual_versions%rowtype;e public.events%rowtype;
  ws public.exhibition_work_submission_snapshots%rowtype;cs public.exhibition_caption_submission_snapshots%rowtype;wall public.exhibition_walls%rowtype;
  actor text:=private.current_email();before_state jsonb;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_actual_state not in ('unconfirmed','exhibited','not_exhibited') then raise exception 'Actual状態が不正です。'; end if;
  select * into i from public.exhibition_actual_items where id=p_item_id for update;
  select * into v from public.exhibition_actual_versions where id=i.actual_version_id;
  select * into e from public.events where id=i.event_id;
  if i.id is null or v.state<>'draft' or e.exhibition_workflow_version<>2 then raise exception '編集可能なActual Itemではありません。'; end if;
  select * into ws from public.exhibition_work_submission_snapshots where id=p_work_snapshot_id and work_id=i.work_id and event_id=i.event_id;
  if ws.id is null or (ws.id<>i.work_submission_snapshot_id and not exists(select 1 from public.exhibition_work_reviews r where r.submission_snapshot_id=ws.id and r.result='accepted')) then
    raise exception '実展示Work SnapshotはPlan由来または確認済み履歴から選択してください。';
  end if;
  if p_caption_snapshot_id is not null then
    select * into cs from public.exhibition_caption_submission_snapshots where id=p_caption_snapshot_id and work_id=i.work_id;
    if cs.id is null or cs.work_submission_snapshot_id<>ws.id or not exists(select 1 from public.exhibition_caption_reviews r where r.caption_snapshot_id=cs.id and r.result='accepted') then
      raise exception 'Caption Snapshotが実展示Work Snapshotと一致しないか、確認済みではありません。';
    end if;
  end if;
  if p_actual_state='exhibited' then
    select * into wall from public.exhibition_walls where id=p_actual_wall_id and venue_id=e.exhibition_venue_id and usable;
    if wall.id is null or p_actual_x_mm is null or p_actual_top_from_floor_mm is null or p_actual_z_order is null then raise exception '実展示配置を入力してください。'; end if;
    if p_actual_x_mm<0 or p_actual_top_from_floor_mm<0 or p_actual_z_order<0 or p_actual_x_mm+ws.occupied_width_mm>wall.width_mm
       or p_actual_top_from_floor_mm>wall.height_mm or p_actual_top_from_floor_mm-ws.occupied_height_mm<0 then raise exception '実展示配置が壁面範囲外です。'; end if;
    if p_caption_snapshot_id is null and not coalesce(p_caption_exception,false) then raise exception '対応する確認済みCaptionまたは例外記録が必要です。'; end if;
    if coalesce(p_caption_exception,false) and trim(coalesce(p_note,''))='' then raise exception 'Caption例外理由を入力してください。'; end if;
  end if;
  before_state:=jsonb_build_object('actualState',i.actual_state,'workSnapshotId',i.work_submission_snapshot_id,'captionSnapshotId',i.caption_submission_snapshot_id,
    'wallId',i.actual_wall_id,'xMm',i.actual_x_mm,'topMm',i.actual_top_from_floor_mm,'zOrder',i.actual_z_order);
  update public.exhibition_actual_items set actual_state=p_actual_state,work_submission_snapshot_id=ws.id,
    caption_submission_snapshot_id=p_caption_snapshot_id,actual_wall_id=case when p_actual_state='exhibited' then p_actual_wall_id else null end,
    actual_x_mm=case when p_actual_state='exhibited' then p_actual_x_mm else null end,
    actual_top_from_floor_mm=case when p_actual_state='exhibited' then p_actual_top_from_floor_mm else null end,
    actual_z_order=case when p_actual_state='exhibited' then p_actual_z_order else null end,
    caption_exception=case when p_actual_state='exhibited' then coalesce(p_caption_exception,false) else false end,
    note=coalesce(p_note,''),updated_by=actor,updated_at=now() where id=i.id returning * into i;
  perform private.write_exhibition_workflow_audit(i.event_id,'actual_item',i.id,'actual_item_recorded','admin',actor,p_note,before_state,
    jsonb_build_object('actualState',i.actual_state,'workSnapshotId',i.work_submission_snapshot_id,'captionSnapshotId',i.caption_submission_snapshot_id,
      'wallId',i.actual_wall_id,'xMm',i.actual_x_mm,'topMm',i.actual_top_from_floor_mm,'zOrder',i.actual_z_order));
  return to_jsonb(i);
end;
$$;

create or replace function public.admin_finalize_exhibition_actual_v2(p_actual_version_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_actual_versions%rowtype;e public.events%rowtype;actor text:=private.current_email();exhibited_count integer;not_count integer;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_actual_versions where id=p_actual_version_id for update;
  select * into e from public.events where id=v.event_id for update;
  if v.id is null or v.state<>'draft' or e.exhibition_workflow_version<>2 then raise exception '確定可能なActual Draftではありません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':actual',0));
  if exists(select 1 from public.exhibition_actual_items where actual_version_id=v.id and actual_state='unconfirmed') then raise exception '未確認のActual Itemがあります。'; end if;
  if not exists(select 1 from public.exhibition_actual_items where actual_version_id=v.id) then raise exception 'Actual Itemがありません。'; end if;
  if exists(select 1 from public.exhibition_actual_items i
    left join public.exhibition_layout_finalization_items li on li.id=i.source_layout_item_id
    left join public.exhibition_work_display_numbers n on n.work_id=i.work_id
    left join public.exhibition_work_submission_snapshots ws on ws.id=i.work_submission_snapshot_id
    left join public.exhibition_caption_submission_snapshots cs on cs.id=i.caption_submission_snapshot_id
    left join public.exhibition_walls wall on wall.id=i.actual_wall_id
    where i.actual_version_id=v.id and (i.event_id is distinct from v.event_id
      or li.finalization_id is distinct from v.source_layout_finalization_id or li.work_id is distinct from i.work_id
      or n.display_no is distinct from i.display_no or ws.work_id is distinct from i.work_id or ws.event_id is distinct from i.event_id
      or (i.actual_state='exhibited' and (i.actual_wall_id is null or wall.venue_id<>e.exhibition_venue_id
        or i.actual_x_mm+ws.occupied_width_mm>wall.width_mm or i.actual_top_from_floor_mm>wall.height_mm
        or i.actual_top_from_floor_mm-ws.occupied_height_mm<0
        or (cs.id is not null and (cs.work_id<>i.work_id or cs.work_submission_snapshot_id<>ws.id
          or not exists(select 1 from public.exhibition_caption_reviews r where r.caption_snapshot_id=cs.id and r.result='accepted')))
        or (cs.id is null and not i.caption_exception)
        or (i.caption_exception and trim(i.note)=''))))) then raise exception 'Actual provenanceまたは配置に未解決の問題があります。'; end if;
  select count(*) filter(where actual_state='exhibited'),count(*) filter(where actual_state='not_exhibited') into exhibited_count,not_count
    from public.exhibition_actual_items where actual_version_id=v.id;
  update public.exhibition_actual_versions set state='finalized',finalized_by=actor,finalized_at=now(),
    reason=case when correction_of_id is not null then reason else coalesce(nullif(trim(p_reason),''),reason) end where id=v.id returning * into v;
  perform private.write_exhibition_workflow_audit(e.id,'actual_version',v.id,'actual_finalized','admin',actor,p_reason,'{}',
    jsonb_build_object('versionNo',v.version_no,'sourceLayoutFinalizationId',v.source_layout_finalization_id,'exhibitedCount',exhibited_count,'notExhibitedCount',not_count,'correctionOfId',v.correction_of_id));
  return jsonb_build_object('actualVersionId',v.id,'versionNo',v.version_no,'exhibitedCount',exhibited_count,'notExhibitedCount',not_count);
end;
$$;

create or replace function public.admin_get_exhibition_actual_readiness_v2(p_actual_version_id uuid)
returns table(item_id uuid,work_id uuid,display_no integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if not exists(select 1 from public.exhibition_actual_versions where id=p_actual_version_id and state='draft') then raise exception 'Actual Draftが見つかりません。'; end if;
  return query
  select i.id,i.work_id,i.display_no,cardinality(r.x)=0,coalesce(r.x,'{}'::text[])
  from public.exhibition_actual_items i
  join public.exhibition_actual_versions v on v.id=i.actual_version_id
  join public.events e on e.id=i.event_id
  left join public.exhibition_layout_finalization_items li on li.id=i.source_layout_item_id
  left join public.exhibition_work_display_numbers n on n.work_id=i.work_id
  left join public.exhibition_work_submission_snapshots ws on ws.id=i.work_submission_snapshot_id
  left join public.exhibition_caption_submission_snapshots cs on cs.id=i.caption_submission_snapshot_id
  left join public.exhibition_walls wall on wall.id=i.actual_wall_id
  cross join lateral(select array_remove(array[
    case when i.actual_state='unconfirmed' then 'Actual status is unconfirmed' end,
    case when li.finalization_id is distinct from v.source_layout_finalization_id or li.work_id is distinct from i.work_id then 'Plan provenance mismatch' end,
    case when n.display_no is distinct from i.display_no then 'Display number mismatch' end,
    case when ws.work_id is distinct from i.work_id or ws.event_id is distinct from i.event_id then 'Work Snapshot provenance mismatch' end,
    case when i.actual_state='exhibited' and (wall.id is null or wall.venue_id<>e.exhibition_venue_id) then 'Actual wall is invalid' end,
    case when i.actual_state='exhibited' and (i.actual_x_mm is null or i.actual_top_from_floor_mm is null or i.actual_z_order is null) then 'Actual placement is incomplete' end,
    case when i.actual_state='exhibited' and wall.id is not null and (i.actual_x_mm+ws.occupied_width_mm>wall.width_mm or i.actual_top_from_floor_mm>wall.height_mm or i.actual_top_from_floor_mm-ws.occupied_height_mm<0) then 'Actual placement is outside the wall' end,
    case when i.actual_state='exhibited' and cs.id is null and not i.caption_exception then 'Accepted compatible Caption is missing' end,
    case when i.actual_state='exhibited' and cs.id is not null and (cs.work_id<>i.work_id or cs.work_submission_snapshot_id<>ws.id or not exists(select 1 from public.exhibition_caption_reviews cr where cr.caption_snapshot_id=cs.id and cr.result='accepted')) then 'Caption provenance mismatch' end,
    case when i.actual_state='exhibited' and i.caption_exception and trim(i.note)='' then 'Caption exception reason is missing' end
  ]::text[],null) x) r
  where i.actual_version_id=p_actual_version_id order by i.display_no;
end;
$$;

create or replace function public.admin_discard_exhibition_actual_draft_v2(p_actual_version_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.exhibition_actual_versions%rowtype;actor text:=private.current_email();item_count integer;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception 'Draft破棄理由を入力してください。'; end if;
  select * into v from public.exhibition_actual_versions where id=p_actual_version_id for update;
  if v.id is null or v.state<>'draft' then raise exception '破棄可能なActual Draftではありません。'; end if;
  select count(*) into item_count from public.exhibition_actual_items where actual_version_id=v.id;
  perform private.write_exhibition_workflow_audit(v.event_id,'actual_version',v.id,'actual_draft_discarded','admin',actor,p_reason,
    jsonb_build_object('versionNo',v.version_no,'itemCount',item_count,'sourceLayoutFinalizationId',v.source_layout_finalization_id),'{}');
  delete from public.exhibition_actual_items where actual_version_id=v.id;
  delete from public.exhibition_actual_versions where id=v.id;
  return jsonb_build_object('discarded',true,'actualVersionId',v.id,'itemCount',item_count);
end;
$$;

create or replace function public.admin_get_finalized_exhibition_actual_v2(p_event_id uuid,p_actual_version_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.exhibition_actual_versions%rowtype;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_actual_versions where event_id=p_event_id and state='finalized'
    and (p_actual_version_id is null or id=p_actual_version_id) order by version_no desc limit 1;
  if v.id is null then return null; end if;
  return jsonb_build_object('version',to_jsonb(v),'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.display_no)
    from public.exhibition_actual_items i where i.actual_version_id=v.id and i.actual_state='exhibited'),'[]'::jsonb));
end;
$$;

create or replace function public.admin_get_exhibition_actual_actions_v2(p_event_id uuid default null)
returns table(priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,member_id uuid,member_name text,
  snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,workflow_state text,occurred_at timestamptz,reason text,context jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query
  with eligible as(select e.* from public.events e where e.exhibition_workflow_version=2 and e.deleted_at is null
    and (p_event_id is null or e.id=p_event_id) and (e.starts_at<=now() or e.site_status='ended')),
  latest_final as(select distinct on(finalization.event_id) finalization.* from public.exhibition_layout_finalizations finalization
    order by finalization.event_id,finalization.finalization_version desc,finalization.id desc),
  draft as(select actual.* from public.exhibition_actual_versions actual where actual.state='draft')
  select 25,'organizer_task','actual_record_missing',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,f.id,null::uuid,e.ends_at,
    'not_started',f.finalized_at,'実展示記録が未作成',jsonb_build_object('label','Actual Exhibition Recordを作成してください','layoutFinalizationId',f.id)
  from eligible e join latest_final f on f.event_id=e.id
  where not exists(select 1 from public.exhibition_actual_versions v where v.event_id=e.id)
  union all
  select 10,'review_required','actual_unconfirmed',e.id,e.title,null::uuid,i.work_id,null::uuid,''::text,i.work_submission_snapshot_id,null::uuid,e.ends_at,
    i.actual_state,i.updated_at,'実展示状態が未確認',jsonb_build_object('label','PlanとActualを照合してください','actualVersionId',d.id,'actualItemId',i.id,'displayNo',i.display_no)
  from eligible e join draft d on d.event_id=e.id join public.exhibition_actual_items i on i.actual_version_id=d.id where i.actual_state='unconfirmed'
  union all
  select 20,'organizer_task','actual_finalize_ready',e.id,e.title,null::uuid,null::uuid,null::uuid,''::text,d.id,null::uuid,e.ends_at,
    'ready',d.created_at,'全Actual Itemの状態が確認済み',jsonb_build_object('label','Actual Exhibition RecordをFINAL確定してください','actualVersionId',d.id)
  from eligible e join draft d on d.event_id=e.id
  where not exists(select 1 from public.exhibition_actual_items i where i.actual_version_id=d.id and i.actual_state='unconfirmed');
end;
$$;

alter table public.exhibition_actual_versions enable row level security;
alter table public.exhibition_actual_items enable row level security;
revoke all on public.exhibition_actual_versions,public.exhibition_actual_items from anon,authenticated;
grant select on public.exhibition_actual_versions,public.exhibition_actual_items to authenticated;
create policy exhibition_actual_versions_admin_select on public.exhibition_actual_versions for select to authenticated using(private.is_admin());
create policy exhibition_actual_items_admin_select on public.exhibition_actual_items for select to authenticated using(private.is_admin());

revoke all on function public.admin_initialize_exhibition_actual_v2(uuid,uuid,text,text),
  public.admin_update_exhibition_actual_item_v2(uuid,text,uuid,numeric,numeric,integer,uuid,uuid,boolean,text),
  public.admin_finalize_exhibition_actual_v2(uuid,text),public.admin_discard_exhibition_actual_draft_v2(uuid,text),
  public.admin_get_exhibition_actual_readiness_v2(uuid),public.admin_get_finalized_exhibition_actual_v2(uuid,uuid),
  public.admin_get_exhibition_actual_actions_v2(uuid) from public,anon;
grant execute on function public.admin_initialize_exhibition_actual_v2(uuid,uuid,text,text),
  public.admin_update_exhibition_actual_item_v2(uuid,text,uuid,numeric,numeric,integer,uuid,uuid,boolean,text),
  public.admin_finalize_exhibition_actual_v2(uuid,text),public.admin_discard_exhibition_actual_draft_v2(uuid,text),
  public.admin_get_exhibition_actual_readiness_v2(uuid),public.admin_get_finalized_exhibition_actual_v2(uuid,uuid),
  public.admin_get_exhibition_actual_actions_v2(uuid) to authenticated;
revoke execute on function private.protect_exhibition_actual_history_v2() from public,anon,authenticated;
