-- Smartphone Phase 2 / Step 1: common Display Item identity and immutable
-- Smartphone Group composition. Phase 6-10 tables remain unchanged here.

create table public.exhibition_smartphone_display_groups (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null unique references public.events(id) on delete restrict,
  display_name text not null default 'スマートフォン撮影写真作品'
    check(trim(display_name)<>'' and char_length(display_name)<=200),
  width_mm numeric(10,2),
  height_mm numeric(10,2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((width_mm is null and height_mm is null) or (width_mm>0 and height_mm>0))
);

create table public.exhibition_display_items (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  item_type text not null check(item_type in('regular_work','smartphone_group')),
  regular_work_id uuid unique references public.exhibition_works(id) on delete cascade,
  smartphone_group_id uuid unique references public.exhibition_smartphone_display_groups(id) on delete restrict,
  created_at timestamptz not null default now(),
  check(
    (item_type='regular_work' and regular_work_id is not null and smartphone_group_id is null)
    or (item_type='smartphone_group' and regular_work_id is null and smartphone_group_id is not null)
  )
);

create index exhibition_display_items_event_type_idx
  on public.exhibition_display_items(event_id,item_type);

create table public.exhibition_smartphone_group_versions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.exhibition_smartphone_display_groups(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  version_no integer not null check(version_no>=1),
  created_by text not null,
  created_at timestamptz not null default now(),
  unique(group_id,version_no)
);

create table public.exhibition_smartphone_group_version_items (
  id uuid primary key default gen_random_uuid(),
  group_version_id uuid not null references public.exhibition_smartphone_group_versions(id) on delete restrict,
  smartphone_work_id uuid not null references public.exhibition_smartphone_works(id) on delete restrict,
  smartphone_submission_snapshot_id uuid not null references public.exhibition_smartphone_work_submission_snapshots(id) on delete restrict,
  item_order integer not null check(item_order>=1),
  created_at timestamptz not null default now(),
  unique(group_version_id,smartphone_work_id),
  unique(group_version_id,smartphone_submission_snapshot_id),
  unique(group_version_id,item_order)
);

create or replace function private.touch_exhibition_smartphone_display_group()
returns trigger language plpgsql security definer set search_path='' as $$
begin new.updated_at:=now();return new;end;
$$;
create trigger exhibition_smartphone_display_groups_touch
before update on public.exhibition_smartphone_display_groups
for each row execute function private.touch_exhibition_smartphone_display_group();

create or replace function private.validate_exhibition_display_item()
returns trigger language plpgsql security definer set search_path='' as $$
declare source_event uuid;
begin
  if new.item_type='regular_work' then
    select event_id into source_event from public.exhibition_works where id=new.regular_work_id;
  else
    select event_id into source_event from public.exhibition_smartphone_display_groups where id=new.smartphone_group_id;
  end if;
  if source_event is null or source_event<>new.event_id then
    raise exception 'Display ItemのEventとsourceが一致しません。';
  end if;
  return new;
end;
$$;
create trigger exhibition_display_items_validate
before insert or update on public.exhibition_display_items
for each row execute function private.validate_exhibition_display_item();

create or replace function private.ensure_regular_work_display_item()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.exhibition_display_items(event_id,item_type,regular_work_id)
  values(new.event_id,'regular_work',new.id)
  on conflict(regular_work_id) do nothing;
  return new;
end;
$$;
create trigger exhibition_works_ensure_display_item
after insert on public.exhibition_works
for each row execute function private.ensure_regular_work_display_item();

insert into public.exhibition_display_items(event_id,item_type,regular_work_id)
select work_row.event_id,'regular_work',work_row.id
from public.exhibition_works work_row
on conflict(regular_work_id) do nothing;

create or replace function private.validate_exhibition_smartphone_group_version()
returns trigger language plpgsql security definer set search_path='' as $$
declare group_event uuid;
begin
  select event_id into group_event from public.exhibition_smartphone_display_groups where id=new.group_id;
  if group_event is null or group_event<>new.event_id then
    raise exception 'Smartphone Group VersionのEventがGroupと一致しません。';
  end if;
  return new;
end;
$$;
create trigger exhibition_smartphone_group_versions_validate
before insert on public.exhibition_smartphone_group_versions
for each row execute function private.validate_exhibition_smartphone_group_version();

create or replace function private.validate_exhibition_smartphone_group_version_item()
returns trigger language plpgsql security definer set search_path='' as $$
declare version_event uuid; work_row public.exhibition_smartphone_works%rowtype;
  snapshot_row public.exhibition_smartphone_work_submission_snapshots%rowtype;
begin
  select event_id into version_event from public.exhibition_smartphone_group_versions where id=new.group_version_id;
  select * into work_row from public.exhibition_smartphone_works where id=new.smartphone_work_id;
  select * into snapshot_row from public.exhibition_smartphone_work_submission_snapshots where id=new.smartphone_submission_snapshot_id;
  if version_event is null or work_row.id is null or snapshot_row.id is null
     or work_row.event_id<>version_event or snapshot_row.event_id<>version_event
     or snapshot_row.smartphone_work_id<>work_row.id
     or work_row.workflow_state<>'accepted'
     or work_row.current_accepted_snapshot_id is distinct from snapshot_row.id then
    raise exception 'Group Versionには現在acceptedのSmartphone Snapshotだけを固定できます。';
  end if;
  return new;
end;
$$;
create trigger exhibition_smartphone_group_version_items_validate
before insert on public.exhibition_smartphone_group_version_items
for each row execute function private.validate_exhibition_smartphone_group_version_item();

create or replace function private.prevent_exhibition_smartphone_group_version_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin raise exception 'Smartphone Group Version履歴は変更または削除できません。';end;
$$;
create trigger exhibition_smartphone_group_versions_immutable
before update or delete on public.exhibition_smartphone_group_versions
for each row execute function private.prevent_exhibition_smartphone_group_version_mutation();
create trigger exhibition_smartphone_group_version_items_immutable
before update or delete on public.exhibition_smartphone_group_version_items
for each row execute function private.prevent_exhibition_smartphone_group_version_mutation();

-- 006 intentionally probes this Phase 2 compatibility relation dynamically.
-- A member included in an immutable Group Version is therefore reported as a
-- reset blocker before the FK boundary is reached.
create view public.exhibition_smartphone_display_items as
select distinct version_row.event_id,work_row.member_id
from public.exhibition_smartphone_group_version_items item_row
join public.exhibition_smartphone_group_versions version_row on version_row.id=item_row.group_version_id
join public.exhibition_smartphone_works work_row on work_row.id=item_row.smartphone_work_id;
revoke all on public.exhibition_smartphone_display_items from public,anon,authenticated;

create or replace function public.admin_upsert_exhibition_smartphone_display_group_v1(
  p_event_id uuid,p_display_name text default 'スマートフォン撮影写真作品',
  p_width_mm numeric default null,p_height_mm numeric default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype; group_row public.exhibition_smartphone_display_groups%rowtype;
  display_item_id uuid; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。';end if;
  if trim(coalesce(p_display_name,''))='' then raise exception '集合展示名は必須です。';end if;
  if not ((p_width_mm is null and p_height_mm is null) or (p_width_mm>0 and p_height_mm>0)) then
    raise exception '集合展示寸法は幅・高さの両方を正の値で設定してください。';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('smartphone-display-group:'||p_event_id::text,0));
  select * into event_row from public.events where id=p_event_id for update;
  if event_row.id is null or event_row.genre<>'exhibition' or event_row.exhibition_workflow_version<>2
     or not event_row.smartphone_exhibition_enabled then
    raise exception 'スマホ枠が有効なWorkflow v2写真展ではありません。';
  end if;
  insert into public.exhibition_smartphone_display_groups(event_id,display_name,width_mm,height_mm)
  values(p_event_id,trim(p_display_name),p_width_mm,p_height_mm)
  on conflict(event_id) do update set display_name=excluded.display_name,width_mm=excluded.width_mm,height_mm=excluded.height_mm
  returning * into group_row;
  insert into public.exhibition_display_items(event_id,item_type,smartphone_group_id)
  values(p_event_id,'smartphone_group',group_row.id)
  on conflict(smartphone_group_id) do nothing;
  select id into display_item_id from public.exhibition_display_items where smartphone_group_id=group_row.id;
  perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_display_group',group_row.id,
    'smartphone_display_group_saved','admin',actor,'','{}',
    jsonb_build_object('displayItemId',display_item_id,'displayName',group_row.display_name,'widthMm',group_row.width_mm,'heightMm',group_row.height_mm));
  return jsonb_build_object('group',to_jsonb(group_row),'displayItemId',display_item_id);
end;
$$;

create or replace function public.admin_create_exhibition_smartphone_group_version_v1(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare group_row public.exhibition_smartphone_display_groups%rowtype; latest_version public.exhibition_smartphone_group_versions%rowtype;
  new_version_id uuid; next_version integer; accepted_count integer; actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者権限がありません。';end if;
  perform pg_advisory_xact_lock(hashtextextended('smartphone-group-version:'||p_event_id::text,0));
  select * into group_row from public.exhibition_smartphone_display_groups where event_id=p_event_id for update;
  if group_row.id is null then raise exception 'Smartphone Display Groupを先に作成してください。';end if;
  select count(*) into accepted_count from public.exhibition_smartphone_works work_row
    where work_row.event_id=p_event_id and work_row.workflow_state='accepted' and work_row.current_accepted_snapshot_id is not null;
  if accepted_count=0 then raise exception 'accepted Smartphone WorkがないためGroup Versionを作成できません。';end if;
  select * into latest_version from public.exhibition_smartphone_group_versions
    where group_id=group_row.id order by version_no desc limit 1;
  if latest_version.id is not null
     and (select count(*) from public.exhibition_smartphone_group_version_items item_row where item_row.group_version_id=latest_version.id)=accepted_count
     and not exists(
       select 1 from public.exhibition_smartphone_works work_row
       where work_row.event_id=p_event_id and work_row.workflow_state='accepted' and work_row.current_accepted_snapshot_id is not null
         and not exists(select 1 from public.exhibition_smartphone_group_version_items item_row
           where item_row.group_version_id=latest_version.id and item_row.smartphone_work_id=work_row.id
             and item_row.smartphone_submission_snapshot_id=work_row.current_accepted_snapshot_id)
     ) then
    return jsonb_build_object('groupVersionId',latest_version.id,'versionNo',latest_version.version_no,
      'itemCount',accepted_count,'reused',true);
  end if;
  select coalesce(max(version_no),0)+1 into next_version from public.exhibition_smartphone_group_versions where group_id=group_row.id;
  insert into public.exhibition_smartphone_group_versions(group_id,event_id,version_no,created_by)
  values(group_row.id,p_event_id,next_version,actor) returning id into new_version_id;
  insert into public.exhibition_smartphone_group_version_items(group_version_id,smartphone_work_id,smartphone_submission_snapshot_id,item_order)
  select new_version_id,work_row.id,work_row.current_accepted_snapshot_id,
    row_number() over(order by work_row.sort_order,work_row.id)::integer
  from public.exhibition_smartphone_works work_row
  where work_row.event_id=p_event_id and work_row.workflow_state='accepted' and work_row.current_accepted_snapshot_id is not null
  order by work_row.sort_order,work_row.id;
  perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_group_version',new_version_id,
    'smartphone_group_version_created','admin',actor,'','{}',jsonb_build_object('versionNo',next_version,'itemCount',accepted_count));
  return jsonb_build_object('groupVersionId',new_version_id,'versionNo',next_version,'itemCount',accepted_count,'reused',false);
end;
$$;

alter table public.exhibition_display_items enable row level security;
alter table public.exhibition_smartphone_display_groups enable row level security;
alter table public.exhibition_smartphone_group_versions enable row level security;
alter table public.exhibition_smartphone_group_version_items enable row level security;
revoke all on public.exhibition_display_items,public.exhibition_smartphone_display_groups,
  public.exhibition_smartphone_group_versions,public.exhibition_smartphone_group_version_items from anon,authenticated;
grant select on public.exhibition_display_items,public.exhibition_smartphone_display_groups,
  public.exhibition_smartphone_group_versions,public.exhibition_smartphone_group_version_items to authenticated;
create policy exhibition_display_items_admin_select on public.exhibition_display_items for select to authenticated using(private.is_admin());
create policy exhibition_smartphone_display_groups_admin_select on public.exhibition_smartphone_display_groups for select to authenticated using(private.is_admin());
create policy exhibition_smartphone_group_versions_admin_select on public.exhibition_smartphone_group_versions for select to authenticated using(private.is_admin());
create policy exhibition_smartphone_group_version_items_admin_select on public.exhibition_smartphone_group_version_items for select to authenticated using(private.is_admin());

revoke all on function public.admin_upsert_exhibition_smartphone_display_group_v1(uuid,text,numeric,numeric),
  public.admin_create_exhibition_smartphone_group_version_v1(uuid) from public,anon;
grant execute on function public.admin_upsert_exhibition_smartphone_display_group_v1(uuid,text,numeric,numeric),
  public.admin_create_exhibition_smartphone_group_version_v1(uuid) to authenticated;
revoke execute on function private.touch_exhibition_smartphone_display_group(),private.validate_exhibition_display_item(),
  private.ensure_regular_work_display_item(),private.validate_exhibition_smartphone_group_version(),
  private.validate_exhibition_smartphone_group_version_item(),private.prevent_exhibition_smartphone_group_version_mutation()
  from public,anon,authenticated;
