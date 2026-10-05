-- 写真展Workflow v2 Phase 7: immutable administrative Master Export。

create table public.exhibition_export_versions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  export_type text not null default 'master_caption' check(export_type in ('master_caption')),
  layout_finalization_id uuid not null references public.exhibition_layout_finalizations(id) on delete restrict,
  layout_finalization_version integer not null check(layout_finalization_version>=1),
  note text not null default '' check(char_length(note)<=3000),
  created_by text not null,
  created_at timestamptz not null default now(),
  unique(event_id,export_type,version_no)
);

create table public.exhibition_export_items (
  id uuid primary key default gen_random_uuid(),
  export_version_id uuid not null references public.exhibition_export_versions(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  display_no integer not null check(display_no>=1),
  viewing_order integer not null check(viewing_order>=1),
  work_submission_snapshot_id uuid not null references public.exhibition_work_submission_snapshots(id) on delete restrict,
  caption_submission_snapshot_id uuid not null references public.exhibition_caption_submission_snapshots(id) on delete restrict,
  english_title_derivation_id uuid references public.exhibition_caption_english_title_derivations(id) on delete restrict,
  title_ja text not null,
  display_name text not null,
  effective_english_title text not null,
  english_title_mode text not null check(english_title_mode in ('self','organizer')),
  english_title_provenance text not null check(english_title_provenance in ('member_snapshot','organizer_derivation')),
  medium text not null,
  medium_details text not null default '',
  camera text not null default '',
  lens text not null default '',
  film text not null default '',
  description_choice text not null check(description_choice in ('provided','unnecessary')),
  description_ja text not null default '',
  description_en text not null default '',
  instagram_qr_choice text not null check(instagram_qr_choice in ('none','request','provided')),
  instagram_qr_info text not null default '',
  instagram_qr_path text,
  publication_consent boolean not null,
  orientation text not null,
  print_size text not null,
  print_size_detail text not null default '',
  wall_id uuid not null references public.exhibition_walls(id) on delete restrict,
  unique(export_version_id,work_id),
  unique(export_version_id,display_no),
  unique(export_version_id,viewing_order)
);

create or replace function private.prevent_exhibition_export_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'FINAL Export履歴は変更または削除できません。'; end;
$$;
create trigger exhibition_export_versions_immutable before update or delete on public.exhibition_export_versions
for each row execute function private.prevent_exhibition_export_mutation();
create trigger exhibition_export_items_immutable before update or delete on public.exhibition_export_items
for each row execute function private.prevent_exhibition_export_mutation();

-- FINALと同じDB判定をPreviewでも使用する。1 Workにつき理由配列を返す。
create or replace function public.admin_get_exhibition_export_readiness_v2(p_event_id uuid)
returns table(work_id uuid,display_no integer,viewing_order integer,work_snapshot_id uuid,caption_snapshot_id uuid,
  layout_finalization_id uuid,layout_finalization_version integer,ready boolean,reasons text[])
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if not exists(select 1 from public.events where id=p_event_id and exhibition_workflow_version=2) then
    raise exception 'Workflow v2写真展が見つかりません。';
  end if;
  return query
  with latest as (
    select f.* from public.exhibition_layout_finalizations f where f.event_id=p_event_id
    order by f.finalization_version desc limit 1
  ), base as (
    select w.id work_uuid,w.workflow_state,w.current_accepted_snapshot_id,wn.display_no number,
      c.state caption_state,c.current_submission_snapshot_id,c.current_accepted_snapshot_id caption_id,
      cs.work_submission_snapshot_id caption_work_snapshot_id,cs.english_title_mode,cs.member_english_title,
      li.viewing_order,li.work_submission_snapshot_id layout_work_snapshot_id,
      l.id final_id,l.finalization_version final_version,
      d.id derivation_id
    from public.exhibition_works w
    left join public.exhibition_work_display_numbers wn on wn.work_id=w.id
    left join public.exhibition_caption_working_data c on c.work_id=w.id
    left join public.exhibition_caption_submission_snapshots cs on cs.id=c.current_accepted_snapshot_id
    left join latest l on true
    left join public.exhibition_layout_finalization_items li on li.finalization_id=l.id and li.work_id=w.id
    left join lateral (
      select x.id from public.exhibition_caption_english_title_derivations x
      where x.source_caption_snapshot_id=cs.id order by x.version_no desc limit 1
    ) d on true
    where w.event_id=p_event_id and w.workflow_state<>'withdrawn'
  )
  select b.work_uuid,b.number,b.viewing_order,b.current_accepted_snapshot_id,b.caption_id,b.final_id,b.final_version,
    cardinality(r.x)=0,coalesce(r.x,'{}'::text[])
  from base b
  cross join lateral (select array_remove(array[
    case when b.workflow_state<>'accepted' then 'Work not accepted' end,
    case when b.current_accepted_snapshot_id is null then 'No accepted Work Snapshot' end,
    case when b.number is null then 'No display number' end,
    case when b.final_id is null then 'No finalized Layout' end,
    case when b.viewing_order is null then 'Not in current finalized Layout' end,
    case when b.viewing_order is not null and b.layout_work_snapshot_id is distinct from b.current_accepted_snapshot_id
      and not coalesce(private.work_snapshots_physically_equal_v2(b.layout_work_snapshot_id,b.current_accepted_snapshot_id),false)
      then 'Layout requires reconfirmation' end,
    case when b.caption_id is null and b.caption_state is null then 'Caption not submitted' end,
    case when b.caption_id is null and b.caption_state='submitted' then 'Caption awaiting review' end,
    case when b.caption_id is null and b.caption_state='rejected' then 'Caption rejected' end,
    case when b.caption_id is null and b.caption_state is not null and b.caption_state not in ('submitted','rejected') then 'Caption not accepted' end,
    case when b.caption_id is not null and b.caption_state<>'accepted' then 'Caption not accepted' end,
    case when b.caption_id is not null and b.caption_work_snapshot_id is distinct from b.current_accepted_snapshot_id then 'Caption belongs to older Work Snapshot' end,
    case when b.caption_id is not null and b.english_title_mode='self' and trim(coalesce(b.member_english_title,''))='' then 'Member English title missing' end,
    case when b.caption_id is not null and b.english_title_mode='organizer' and b.derivation_id is null then 'Organizer English title missing' end
  ]::text[],null) x) r
  order by b.viewing_order nulls last,b.number nulls last,b.work_uuid;
end;
$$;

create or replace function public.admin_finalize_exhibition_export_v2(p_event_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; f public.exhibition_layout_finalizations%rowtype; row record;
  export_id uuid; next_version integer; actor text:=private.current_email(); item_count integer:=0; blocked integer;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into e from public.events where id=p_event_id for update;
  if e.id is null or e.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||':master_export',0));
  select * into f from public.exhibition_layout_finalizations where event_id=e.id order by finalization_version desc limit 1;
  if f.id is null or private.layout_requires_physical_reconfirmation_v2(e.id) then raise exception '現在のLayout FinalizationはExportに使用できません。'; end if;
  select count(*) into blocked from public.admin_get_exhibition_export_readiness_v2(e.id) where not ready;
  if blocked>0 then raise exception 'FINAL Exportを作成できません。未解決項目: %件',blocked; end if;
  if not exists(select 1 from public.admin_get_exhibition_export_readiness_v2(e.id)) then raise exception 'Export対象Workがありません。'; end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_export_versions where event_id=e.id and export_type='master_caption';
  insert into public.exhibition_export_versions(event_id,version_no,layout_finalization_id,layout_finalization_version,note,created_by)
    values(e.id,next_version,f.id,f.finalization_version,coalesce(p_note,''),actor) returning id into export_id;
  for row in
    select li.*,ws.id current_work_snapshot_id,ws.title title_ja,ws.publication_consent,cs.id caption_id,cs.display_name,cs.english_title_mode,cs.member_english_title,
      cs.medium,cs.medium_details,cs.camera,cs.lens,cs.film,cs.description_choice,cs.description_ja,cs.description_en,
      cs.instagram_qr_choice,cs.instagram_qr_info,cs.instagram_qr_path,d.id derivation_id,d.english_title organizer_title
    from public.exhibition_layout_finalization_items li
    join public.exhibition_works w on w.id=li.work_id and w.workflow_state='accepted'
    join public.exhibition_work_submission_snapshots ws on ws.id=w.current_accepted_snapshot_id
    join public.exhibition_caption_working_data c on c.work_id=w.id and c.state='accepted'
    join public.exhibition_caption_submission_snapshots cs on cs.id=c.current_accepted_snapshot_id and cs.work_submission_snapshot_id=ws.id
    left join lateral (
      select x.* from public.exhibition_caption_english_title_derivations x where x.source_caption_snapshot_id=cs.id order by x.version_no desc limit 1
    ) d on true
    where li.finalization_id=f.id and (li.work_submission_snapshot_id=ws.id
      or coalesce(private.work_snapshots_physically_equal_v2(li.work_submission_snapshot_id,ws.id),false))
    order by li.viewing_order
  loop
    insert into public.exhibition_export_items(export_version_id,event_id,work_id,display_no,viewing_order,
      work_submission_snapshot_id,caption_submission_snapshot_id,english_title_derivation_id,title_ja,display_name,
      effective_english_title,english_title_mode,english_title_provenance,medium,medium_details,camera,lens,film,
      description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,
      publication_consent,orientation,print_size,print_size_detail,wall_id)
    values(export_id,e.id,row.work_id,row.display_no,row.viewing_order,row.current_work_snapshot_id,row.caption_id,row.derivation_id,
      row.title_ja,row.display_name,case when row.english_title_mode='self' then row.member_english_title else row.organizer_title end,
      row.english_title_mode,case when row.english_title_mode='self' then 'member_snapshot' else 'organizer_derivation' end,
      row.medium,row.medium_details,row.camera,row.lens,row.film,row.description_choice,row.description_ja,row.description_en,
      row.instagram_qr_choice,row.instagram_qr_info,row.instagram_qr_path,row.publication_consent,row.orientation,row.print_size,row.print_size_detail,row.wall_id);
    item_count:=item_count+1;
  end loop;
  if item_count<>(select count(*) from public.admin_get_exhibition_export_readiness_v2(e.id)) then raise exception 'Export Item件数が対象Work件数と一致しません。'; end if;
  perform private.write_exhibition_workflow_audit(e.id,'export_version',export_id,'master_export_finalized','admin',actor,p_note,'{}',
    jsonb_build_object('versionNo',next_version,'layoutFinalizationId',f.id,'layoutFinalizationVersion',f.finalization_version,'itemCount',item_count));
  return jsonb_build_object('exportVersionId',export_id,'versionNo',next_version,'itemCount',item_count,'layoutFinalizationId',f.id);
end;
$$;

create or replace function public.admin_get_exhibition_export_v2(p_export_version_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.exhibition_export_versions%rowtype;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_export_versions where id=p_export_version_id;
  if v.id is null then raise exception 'Export Versionが見つかりません。'; end if;
  return jsonb_build_object('version',to_jsonb(v),'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.viewing_order)
    from public.exhibition_export_items i where i.export_version_id=v.id),'[]'::jsonb));
end;
$$;

create or replace function private.exhibition_csv_cell_v2(p_value text)
returns text language sql immutable security definer set search_path='' as $$
  select '"'||replace(coalesce(p_value,''),'"','""')||'"'
$$;

create or replace function public.admin_get_exhibition_export_csv_v2(p_export_version_id uuid)
returns text language plpgsql stable security definer set search_path='' as $$
declare v public.exhibition_export_versions%rowtype; body text;
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into v from public.exhibition_export_versions where id=p_export_version_id;
  if v.id is null then raise exception 'Export Versionが見つかりません。'; end if;
  select string_agg(array_to_string(array[
    private.exhibition_csv_cell_v2(i.work_id::text),private.exhibition_csv_cell_v2(i.display_no::text),private.exhibition_csv_cell_v2(i.viewing_order::text),
    private.exhibition_csv_cell_v2(i.work_submission_snapshot_id::text),private.exhibition_csv_cell_v2(i.caption_submission_snapshot_id::text),private.exhibition_csv_cell_v2(v.layout_finalization_id::text),
    private.exhibition_csv_cell_v2(i.title_ja),private.exhibition_csv_cell_v2(i.display_name),private.exhibition_csv_cell_v2(i.effective_english_title),
    private.exhibition_csv_cell_v2(i.english_title_mode),private.exhibition_csv_cell_v2(i.english_title_provenance),private.exhibition_csv_cell_v2(i.medium),
    private.exhibition_csv_cell_v2(i.medium_details),private.exhibition_csv_cell_v2(i.camera),private.exhibition_csv_cell_v2(i.lens),private.exhibition_csv_cell_v2(i.film),
    private.exhibition_csv_cell_v2(i.description_choice),private.exhibition_csv_cell_v2(i.description_ja),private.exhibition_csv_cell_v2(i.description_en),
    private.exhibition_csv_cell_v2(i.instagram_qr_choice),private.exhibition_csv_cell_v2(i.instagram_qr_info),private.exhibition_csv_cell_v2(i.instagram_qr_path),
    private.exhibition_csv_cell_v2(i.publication_consent::text),private.exhibition_csv_cell_v2(i.orientation),private.exhibition_csv_cell_v2(i.print_size),
    private.exhibition_csv_cell_v2(i.print_size_detail),private.exhibition_csv_cell_v2(i.wall_id::text)
  ],','),E'\r\n' order by i.viewing_order) into body from public.exhibition_export_items i where i.export_version_id=v.id;
  return E'\uFEFFwork_uuid,display_no,viewing_order,work_snapshot_uuid,caption_snapshot_uuid,layout_finalization_uuid,title_ja,display_name,effective_english_title,english_title_mode,english_title_provenance,medium,medium_details,camera,lens,film,description_choice,description_ja,description_en,instagram_qr_choice,instagram_qr_info,instagram_qr_path,publication_consent,orientation,print_size,print_size_detail,wall_uuid\r\n'||coalesce(body,'');
end;
$$;

create or replace function public.admin_get_exhibition_export_actions_v2(p_event_id uuid default null)
returns table(priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,
  member_id uuid,member_name text,snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,
  workflow_state text,occurred_at timestamptz,reason text,context jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query
  with target as (
    select e.*,f.id final_id from public.events e
    join lateral (select x.id from public.exhibition_layout_finalizations x where x.event_id=e.id order by x.finalization_version desc limit 1) f on true
    where e.exhibition_workflow_version=2 and (p_event_id is null or e.id=p_event_id)
  ), state as (
    select t.id,t.title,t.final_id,count(*) filter(where not r.ready) blocked,count(*) total
    from target t cross join lateral public.admin_get_exhibition_export_readiness_v2(t.id) r group by t.id,t.title,t.final_id
  )
  select 25,'organizer_task','master_export_blocked',s.id,s.title,null::uuid,null::uuid,null::uuid,''::text,null::uuid,null::uuid,
    null::timestamptz,'blocked',now(),'FINAL Master Exportに未解決項目があります',
    jsonb_build_object('label','Master Export readinessを確認してください','blockedCount',s.blocked,'totalCount',s.total)
  from state s where s.blocked>0
  union all
  select 45,'organizer_task','master_export_refresh_available',s.id,s.title,null::uuid,null::uuid,null::uuid,''::text,null::uuid,null::uuid,
    null::timestamptz,'ready',now(),'現在の確定データに対応するExportがありません',
    jsonb_build_object('label','FINAL Master Exportを作成できます','totalCount',s.total)
  from state s where s.blocked=0 and not exists(
    select 1 from public.exhibition_export_versions v where v.event_id=s.id and v.layout_finalization_id=s.final_id
      and not exists(select 1 from public.exhibition_export_items i join public.exhibition_works w on w.id=i.work_id
        join public.exhibition_caption_working_data c on c.work_id=w.id
        where i.export_version_id=v.id and (i.work_submission_snapshot_id is distinct from w.current_accepted_snapshot_id
          or i.caption_submission_snapshot_id is distinct from c.current_accepted_snapshot_id))
  );
end;
$$;

alter table public.exhibition_export_versions enable row level security;
alter table public.exhibition_export_items enable row level security;
revoke all on public.exhibition_export_versions,public.exhibition_export_items from anon,authenticated;
grant select on public.exhibition_export_versions,public.exhibition_export_items to authenticated;
create policy exhibition_export_versions_admin_select on public.exhibition_export_versions for select to authenticated using(private.is_admin());
create policy exhibition_export_items_admin_select on public.exhibition_export_items for select to authenticated using(private.is_admin());

revoke all on function public.admin_get_exhibition_export_readiness_v2(uuid),public.admin_finalize_exhibition_export_v2(uuid,text),
  public.admin_get_exhibition_export_v2(uuid),public.admin_get_exhibition_export_csv_v2(uuid),public.admin_get_exhibition_export_actions_v2(uuid) from public,anon;
grant execute on function public.admin_get_exhibition_export_readiness_v2(uuid),public.admin_finalize_exhibition_export_v2(uuid,text),
  public.admin_get_exhibition_export_v2(uuid),public.admin_get_exhibition_export_csv_v2(uuid),public.admin_get_exhibition_export_actions_v2(uuid) to authenticated;
revoke execute on function private.prevent_exhibition_export_mutation(),private.exhibition_csv_cell_v2(text) from public,anon,authenticated;
