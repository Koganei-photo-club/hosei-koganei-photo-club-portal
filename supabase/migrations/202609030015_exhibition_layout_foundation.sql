-- 写真展の会場・壁面・作品占有外寸・配置案を統合ポータルで管理する基盤。

create table public.exhibition_venues (
  id uuid primary key default gen_random_uuid(),
  name text not null check (trim(name) <> '' and char_length(name) <= 100),
  address text not null default '' check (char_length(address) <= 500),
  contact_name text not null default '' check (char_length(contact_name) <= 100),
  contact_info text not null default '' check (char_length(contact_info) <= 500),
  status text not null default 'active' check (status in ('active', 'inactive')),
  notes text not null default '' check (char_length(notes) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.exhibition_walls (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.exhibition_venues(id) on delete restrict,
  name text not null check (trim(name) <> '' and char_length(name) <= 100),
  display_order integer not null default 1 check (display_order >= 1),
  width_mm numeric(10,2) not null check (width_mm > 0),
  height_mm numeric(10,2) not null check (height_mm > 0),
  background_color text not null default '#FFFFFF'
    check (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  usable boolean not null default true,
  notes text not null default '' check (char_length(notes) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, display_order)
);

alter table public.events
  add column exhibition_venue_id uuid references public.exhibition_venues(id) on delete restrict;

alter table public.exhibition_works
  add column occupied_width_mm numeric(10,2) check (occupied_width_mm > 0),
  add column occupied_height_mm numeric(10,2) check (occupied_height_mm > 0);

-- 単写真は用紙外寸を初期値とする。組み写真・その他は管理者が占有外寸を入力する。
update public.exhibition_works
set occupied_width_mm = case
      when print_size = 'A4' and orientation = 'portrait' then 210
      when print_size = 'A4' and orientation = 'landscape' then 297
      when print_size = 'A3' and orientation = 'portrait' then 297
      when print_size = 'A3' and orientation = 'landscape' then 420
      when print_size = 'A2' and orientation = 'portrait' then 420
      when print_size = 'A2' and orientation = 'landscape' then 594
      else occupied_width_mm
    end,
    occupied_height_mm = case
      when print_size = 'A4' and orientation = 'portrait' then 297
      when print_size = 'A4' and orientation = 'landscape' then 210
      when print_size = 'A3' and orientation = 'portrait' then 420
      when print_size = 'A3' and orientation = 'landscape' then 297
      when print_size = 'A2' and orientation = 'portrait' then 594
      when print_size = 'A2' and orientation = 'landscape' then 420
      else occupied_height_mm
    end;

create or replace function private.set_exhibition_work_default_dimensions()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.occupied_width_mm is null or new.occupied_height_mm is null
    or (tg_op = 'UPDATE' and (
      new.print_size is distinct from old.print_size
      or new.orientation is distinct from old.orientation
    )) then
    if new.print_size = 'A4' then
      new.occupied_width_mm := case when new.orientation = 'landscape' then 297 else 210 end;
      new.occupied_height_mm := case when new.orientation = 'landscape' then 210 else 297 end;
    elsif new.print_size = 'A3' then
      new.occupied_width_mm := case when new.orientation = 'landscape' then 420 else 297 end;
      new.occupied_height_mm := case when new.orientation = 'landscape' then 297 else 420 end;
    elsif new.print_size = 'A2' then
      new.occupied_width_mm := case when new.orientation = 'landscape' then 594 else 420 end;
      new.occupied_height_mm := case when new.orientation = 'landscape' then 420 else 594 end;
    elsif tg_op = 'UPDATE' and (
      new.print_size is distinct from old.print_size
      or new.orientation is distinct from old.orientation
    ) then
      new.occupied_width_mm := null;
      new.occupied_height_mm := null;
    end if;
  end if;
  return new;
end;
$$;

create trigger zzzzzz_exhibition_work_default_dimensions_before_write
before insert or update on public.exhibition_works
for each row execute function private.set_exhibition_work_default_dimensions();

create table public.exhibition_layouts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null check (trim(name) <> '' and char_length(name) <= 100),
  version_no integer not null default 1 check (version_no >= 1),
  status text not null default 'draft'
    check (status in ('draft', 'review', 'approved', 'archived')),
  is_current boolean not null default false,
  created_by text not null default '',
  notes text not null default '' check (char_length(notes) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, name, version_no)
);

create unique index exhibition_layouts_one_current_per_event
  on public.exhibition_layouts(event_id)
  where is_current;

create table public.exhibition_placements (
  id uuid primary key default gen_random_uuid(),
  layout_id uuid not null references public.exhibition_layouts(id) on delete cascade,
  work_id uuid not null references public.exhibition_works(id) on delete restrict,
  wall_id uuid not null references public.exhibition_walls(id) on delete restrict,
  x_mm numeric(10,2) not null default 0 check (x_mm >= 0),
  top_from_floor_mm numeric(10,2) not null check (top_from_floor_mm >= 0),
  z_order integer not null default 0 check (z_order >= 0),
  locked boolean not null default false,
  status text not null default 'placed' check (status in ('placed', 'hidden', 'removed')),
  notes text not null default '' check (char_length(notes) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index exhibition_placements_active_work_unique
  on public.exhibition_placements(layout_id, work_id)
  where status <> 'removed';

create or replace function private.validate_exhibition_placement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_layout public.exhibition_layouts%rowtype;
  target_work public.exhibition_works%rowtype;
  target_wall public.exhibition_walls%rowtype;
  event_venue_id uuid;
begin
  select * into target_layout from public.exhibition_layouts where id = new.layout_id;
  select * into target_work from public.exhibition_works where id = new.work_id;
  select * into target_wall from public.exhibition_walls where id = new.wall_id;
  select exhibition_venue_id into event_venue_id from public.events where id = target_layout.event_id;

  if target_layout.id is null or target_work.id is null or target_wall.id is null then
    raise exception '配置案、作品、または壁面が見つかりません。';
  end if;
  if target_work.event_id <> target_layout.event_id then
    raise exception '別の写真展の作品は配置できません。';
  end if;
  if event_venue_id is null or target_wall.venue_id <> event_venue_id then
    raise exception '写真展会場に属さない壁面は使用できません。';
  end if;
  if not target_wall.usable and new.status = 'placed' then
    raise exception '使用不可の壁面には配置できません。';
  end if;
  if target_work.occupied_width_mm is null or target_work.occupied_height_mm is null then
    raise exception '作品の占有外寸を入力してください。';
  end if;
  if new.x_mm + target_work.occupied_width_mm > target_wall.width_mm then
    raise exception '作品が壁面の右端を超えています。';
  end if;
  if new.top_from_floor_mm > target_wall.height_mm
    or new.top_from_floor_mm - target_work.occupied_height_mm < 0 then
    raise exception '作品が壁面の上下端を超えています。';
  end if;
  return new;
end;
$$;

create trigger exhibition_placements_validate_before_write
before insert or update on public.exhibition_placements
for each row execute function private.validate_exhibition_placement();

create or replace function private.touch_exhibition_layout_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger exhibition_venues_touch_updated_at
before update on public.exhibition_venues
for each row execute function private.touch_exhibition_layout_updated_at();
create trigger exhibition_walls_touch_updated_at
before update on public.exhibition_walls
for each row execute function private.touch_exhibition_layout_updated_at();
create trigger exhibition_layouts_touch_updated_at
before update on public.exhibition_layouts
for each row execute function private.touch_exhibition_layout_updated_at();
create trigger exhibition_placements_touch_updated_at
before update on public.exhibition_placements
for each row execute function private.touch_exhibition_layout_updated_at();

alter table public.exhibition_venues enable row level security;
alter table public.exhibition_walls enable row level security;
alter table public.exhibition_layouts enable row level security;
alter table public.exhibition_placements enable row level security;

revoke all on public.exhibition_venues from anon, authenticated;
revoke all on public.exhibition_walls from anon, authenticated;
revoke all on public.exhibition_layouts from anon, authenticated;
revoke all on public.exhibition_placements from anon, authenticated;
grant select, insert, update, delete on public.exhibition_venues to authenticated;
grant select, insert, update, delete on public.exhibition_walls to authenticated;
grant select, insert, update, delete on public.exhibition_layouts to authenticated;
grant select, insert, update, delete on public.exhibition_placements to authenticated;

create policy exhibition_venues_admin_all on public.exhibition_venues
for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy exhibition_walls_admin_all on public.exhibition_walls
for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy exhibition_layouts_admin_all on public.exhibition_layouts
for all to authenticated using (private.is_admin()) with check (private.is_admin());
create policy exhibition_placements_admin_all on public.exhibition_placements
for all to authenticated using (private.is_admin()) with check (private.is_admin());

create index exhibition_walls_venue_order_idx
  on public.exhibition_walls(venue_id, display_order);
create index exhibition_layouts_event_idx
  on public.exhibition_layouts(event_id, updated_at desc);
create index exhibition_placements_layout_wall_idx
  on public.exhibition_placements(layout_id, wall_id, z_order);

revoke execute on function private.set_exhibition_work_default_dimensions() from public;
revoke execute on function private.validate_exhibition_placement() from public;
revoke execute on function private.touch_exhibition_layout_updated_at() from public;
