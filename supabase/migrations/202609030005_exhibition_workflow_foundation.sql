-- 新規写真展の出展申込・作品・感想・シフト希望を管理する基盤。
-- 写真展そのものの日時、場所、公開状態、出展上限数、シフト枠は public.events を正とする。

create table public.exhibition_entries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete restrict,
  status text not null default 'draft'
    check (status in ('draft', 'submitted', 'withdrawn')),
  note text not null default '',
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, member_id)
);

create table public.exhibition_works (
  -- このIDを恒久的な作品ID（WorkUuid）として利用する。
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.exhibition_entries(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  owner_member_id uuid not null references public.members(id) on delete restrict,
  legacy_work_uuid text unique,
  display_no text not null default '',
  sort_order integer not null default 1 check (sort_order >= 1),
  title text not null default '',
  caption text not null default '',
  note text not null default '',
  status text not null default 'draft'
    check (status in ('draft', 'submitted', 'accepted', 'rejected', 'withdrawn')),
  original_image_path text,
  preview_image_path text,
  public_image_path text,
  public_release boolean not null default false,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entry_id, sort_order)
);

create unique index exhibition_works_display_no_unique
  on public.exhibition_works(event_id, display_no)
  where trim(display_no) <> '';

create table public.exhibition_work_comments (
  id uuid primary key default gen_random_uuid(),
  work_id uuid not null references public.exhibition_works(id) on delete cascade,
  legacy_comment_id text unique,
  comment text not null check (trim(comment) <> ''),
  moderation_status text not null default 'visible'
    check (moderation_status in ('pending', 'visible', 'hidden')),
  visible_to_owner boolean not null default true,
  submitted_at timestamptz not null default now(),
  imported_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.exhibition_overall_comments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  legacy_comment_id text unique,
  comment text not null check (trim(comment) <> ''),
  moderation_status text not null default 'visible'
    check (moderation_status in ('pending', 'visible', 'hidden')),
  submitted_at timestamptz not null default now(),
  imported_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.exhibition_shift_preferences (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete restrict,
  slot_id text not null,
  slot_label text not null,
  preference text not null default 'available'
    check (preference in ('preferred', 'available', 'unavailable')),
  note text not null default '',
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, member_id, slot_id)
);

create or replace function private.is_available_exhibition_event(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.events e
    where e.id = target_event_id
      and e.genre = 'exhibition'
      and e.status = 'saved'
      and e.published
      and e.deleted_at is null
  )
$$;

create or replace function private.current_member_owns_exhibition_entry(target_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.exhibition_entries entry
    where entry.id = target_entry_id
      and entry.member_id = private.current_member_id()
  )
$$;

create or replace function private.current_member_owns_exhibition_work(target_work_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.exhibition_works work
    where work.id = target_work_id
      and work.owner_member_id = private.current_member_id()
  )
$$;

create or replace function private.touch_exhibition_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function private.validate_exhibition_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_genre public.event_genre;
begin
  select e.genre into target_genre
  from public.events e
  where e.id = new.event_id;
  if target_genre is distinct from 'exhibition'::public.event_genre then
    raise exception '対象の予定は写真展ではありません。';
  end if;

  if not private.is_admin() then
    if new.member_id <> private.current_member_id() then
      raise exception '本人以外の出展申込は登録できません。';
    end if;
    if tg_op = 'UPDATE' and (
      new.member_id is distinct from old.member_id
      or new.event_id is distinct from old.event_id
    ) then
      raise exception '出展者と対象写真展は変更できません。';
    end if;
    if not private.is_current_member() then
      raise exception '現在有効な部員のみ出展申込を登録できます。';
    end if;
    if not private.is_available_exhibition_event(new.event_id) then
      raise exception 'この写真展は現在出展を受け付けていません。';
    end if;
  end if;

  if new.status = 'submitted' and new.submitted_at is null then
    new.submitted_at = now();
  elsif new.status = 'draft' then
    new.submitted_at = null;
  end if;
  return new;
end;
$$;

create or replace function private.validate_exhibition_overall_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.events e
    where e.id = new.event_id and e.genre = 'exhibition'
  ) then
    raise exception '対象の予定は写真展ではありません。';
  end if;
  return new;
end;
$$;

create or replace function private.validate_exhibition_work()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_entry public.exhibition_entries%rowtype;
  target_event public.events%rowtype;
  work_count integer;
begin
  select * into target_entry
  from public.exhibition_entries
  where id = new.entry_id;

  if target_entry.id is null then
    raise exception '出展申込が見つかりません。';
  end if;

  new.event_id = target_entry.event_id;
  new.owner_member_id = target_entry.member_id;

  if not private.is_admin() then
    if target_entry.member_id <> private.current_member_id() then
      raise exception '本人以外の作品は登録できません。';
    end if;
    if not private.is_available_exhibition_event(target_entry.event_id) then
      raise exception 'この写真展は現在作品を受け付けていません。';
    end if;

    if new.status not in ('draft', 'submitted', 'withdrawn') then
      raise exception '作品の審査状態は管理者のみ変更できます。';
    end if;
    if trim(new.display_no) <> ''
      or new.public_release
      or new.public_image_path is not null
      or new.legacy_work_uuid is not null then
      raise exception '作品番号、公開状態、移行情報は管理者のみ設定できます。';
    end if;
    if tg_op = 'UPDATE' and (
      new.owner_member_id is distinct from old.owner_member_id
      or new.event_id is distinct from old.event_id
      or new.entry_id is distinct from old.entry_id
    ) then
      raise exception '作品の所有者、対象写真展、出展申込は変更できません。';
    end if;
  end if;

  select * into target_event
  from public.events
  where id = target_entry.event_id;

  perform pg_advisory_xact_lock(hashtextextended(target_entry.id::text, 0));
  select count(*) into work_count
  from public.exhibition_works work
  where work.entry_id = target_entry.id
    and work.id <> new.id
    and work.status <> 'withdrawn';

  if new.status <> 'withdrawn' and work_count >= target_event.max_works then
    raise exception 'この写真展の出展可能作品数を超えています。';
  end if;

  if new.status = 'submitted' and trim(new.title) = '' then
    raise exception '作品名を入力してください。';
  end if;
  if new.status = 'submitted' and new.submitted_at is null then
    new.submitted_at = now();
  elsif new.status = 'draft' then
    new.submitted_at = null;
  end if;
  return new;
end;
$$;

create or replace function private.validate_exhibition_shift_preference()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  slots jsonb;
begin
  if not private.is_admin() then
    if new.member_id <> private.current_member_id() then
      raise exception '本人以外のシフト希望は登録できません。';
    end if;
    if not private.is_current_member() then
      raise exception '現在有効な部員のみシフト希望を登録できます。';
    end if;
    if not private.is_available_exhibition_event(new.event_id) then
      raise exception 'この写真展は現在シフト希望を受け付けていません。';
    end if;
  end if;

  select e.shift_slots into slots
  from public.events e
  where e.id = new.event_id and e.genre = 'exhibition';

  if slots is null or not exists (
    select 1
    from jsonb_array_elements(slots) slot
    where coalesce(slot->>'id', slot #>> '{}') = new.slot_id
  ) then
    raise exception '指定されたシフト枠が見つかりません。';
  end if;
  return new;
end;
$$;

create trigger exhibition_entries_validate_before_write
before insert or update on public.exhibition_entries
for each row execute function private.validate_exhibition_entry();

create trigger exhibition_entries_touch_updated_at
before update on public.exhibition_entries
for each row execute function private.touch_exhibition_updated_at();

create trigger exhibition_works_validate_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_work();

create trigger exhibition_works_touch_updated_at
before update on public.exhibition_works
for each row execute function private.touch_exhibition_updated_at();

create trigger exhibition_shift_preferences_validate_before_write
before insert or update on public.exhibition_shift_preferences
for each row execute function private.validate_exhibition_shift_preference();

create trigger exhibition_shift_preferences_touch_updated_at
before update on public.exhibition_shift_preferences
for each row execute function private.touch_exhibition_updated_at();

create trigger exhibition_overall_comments_validate_before_write
before insert or update on public.exhibition_overall_comments
for each row execute function private.validate_exhibition_overall_comment();

alter table public.exhibition_entries enable row level security;
alter table public.exhibition_works enable row level security;
alter table public.exhibition_work_comments enable row level security;
alter table public.exhibition_overall_comments enable row level security;
alter table public.exhibition_shift_preferences enable row level security;

revoke all on public.exhibition_entries from anon;
revoke all on public.exhibition_works from anon;
revoke all on public.exhibition_work_comments from anon;
revoke all on public.exhibition_overall_comments from anon;
revoke all on public.exhibition_shift_preferences from anon;

grant select, insert, update, delete on public.exhibition_entries to authenticated;
grant select, insert, update, delete on public.exhibition_works to authenticated;
grant select, insert, update, delete on public.exhibition_shift_preferences to authenticated;
grant select, insert, update, delete on public.exhibition_work_comments to authenticated;
grant select, insert, update, delete on public.exhibition_overall_comments to authenticated;

create policy exhibition_entries_self_or_admin_select
on public.exhibition_entries for select to authenticated
using (member_id = private.current_member_id() or private.is_admin());

create policy exhibition_entries_self_insert
on public.exhibition_entries for insert to authenticated
with check (
  member_id = private.current_member_id()
  and private.is_current_member()
  and private.is_available_exhibition_event(event_id)
);

create policy exhibition_entries_self_update
on public.exhibition_entries for update to authenticated
using (member_id = private.current_member_id() and private.is_current_member())
with check (member_id = private.current_member_id() and private.is_current_member());

create policy exhibition_entries_admin_all
on public.exhibition_entries for all to authenticated
using (private.is_admin()) with check (private.is_admin());

create policy exhibition_works_self_or_admin_select
on public.exhibition_works for select to authenticated
using (owner_member_id = private.current_member_id() or private.is_admin());

create policy exhibition_works_self_insert
on public.exhibition_works for insert to authenticated
with check (
  owner_member_id = private.current_member_id()
  and private.current_member_owns_exhibition_entry(entry_id)
  and private.is_current_member()
);

create policy exhibition_works_self_update
on public.exhibition_works for update to authenticated
using (owner_member_id = private.current_member_id() and private.is_current_member())
with check (owner_member_id = private.current_member_id() and private.is_current_member());

create policy exhibition_works_self_delete
on public.exhibition_works for delete to authenticated
using (
  owner_member_id = private.current_member_id()
  and private.is_current_member()
  and private.is_available_exhibition_event(event_id)
  and status = 'draft'
);

create policy exhibition_works_admin_all
on public.exhibition_works for all to authenticated
using (private.is_admin()) with check (private.is_admin());

create policy exhibition_work_comments_owner_or_admin_select
on public.exhibition_work_comments for select to authenticated
using (
  private.is_admin()
  or (
    visible_to_owner
    and moderation_status = 'visible'
    and private.current_member_owns_exhibition_work(work_id)
  )
);

create policy exhibition_work_comments_admin_write
on public.exhibition_work_comments for all to authenticated
using (private.is_admin()) with check (private.is_admin());

create policy exhibition_overall_comments_admin_all
on public.exhibition_overall_comments for all to authenticated
using (private.is_admin()) with check (private.is_admin());

create policy exhibition_shift_preferences_self_or_admin_select
on public.exhibition_shift_preferences for select to authenticated
using (member_id = private.current_member_id() or private.is_admin());

create policy exhibition_shift_preferences_self_insert
on public.exhibition_shift_preferences for insert to authenticated
with check (
  member_id = private.current_member_id()
  and private.is_current_member()
  and private.is_available_exhibition_event(event_id)
);

create policy exhibition_shift_preferences_self_update
on public.exhibition_shift_preferences for update to authenticated
using (member_id = private.current_member_id() and private.is_current_member())
with check (member_id = private.current_member_id() and private.is_current_member());

create policy exhibition_shift_preferences_self_delete
on public.exhibition_shift_preferences for delete to authenticated
using (
  member_id = private.current_member_id()
  and private.is_current_member()
  and private.is_available_exhibition_event(event_id)
);

create policy exhibition_shift_preferences_admin_all
on public.exhibition_shift_preferences for all to authenticated
using (private.is_admin()) with check (private.is_admin());

create index exhibition_entries_member_event_idx
  on public.exhibition_entries(member_id, event_id);
create index exhibition_works_owner_event_idx
  on public.exhibition_works(owner_member_id, event_id);
create index exhibition_works_entry_idx
  on public.exhibition_works(entry_id, sort_order);
create index exhibition_work_comments_work_idx
  on public.exhibition_work_comments(work_id, submitted_at);
create index exhibition_overall_comments_event_idx
  on public.exhibition_overall_comments(event_id, submitted_at);
create index exhibition_shift_preferences_member_event_idx
  on public.exhibition_shift_preferences(member_id, event_id);

revoke execute on function private.is_available_exhibition_event(uuid) from public;
revoke execute on function private.current_member_owns_exhibition_entry(uuid) from public;
revoke execute on function private.current_member_owns_exhibition_work(uuid) from public;
revoke execute on function private.touch_exhibition_updated_at() from public;
revoke execute on function private.validate_exhibition_entry() from public;
revoke execute on function private.validate_exhibition_work() from public;
revoke execute on function private.validate_exhibition_shift_preference() from public;
revoke execute on function private.validate_exhibition_overall_comment() from public;

grant execute on function private.is_available_exhibition_event(uuid) to authenticated;
grant execute on function private.current_member_owns_exhibition_entry(uuid) to authenticated;
grant execute on function private.current_member_owns_exhibition_work(uuid) to authenticated;
