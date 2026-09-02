-- 写真展作品の原画像とプレビューを非公開Storageで管理する。
-- オブジェクトパスは次の形式に統一する。
--   {event_id}/{owner_member_id}/{work_id}/{file_name}

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'exhibition-originals',
  'exhibition-originals',
  false,
  52428800,
  array[
    'image/jpeg',
    'image/png',
    'image/tiff',
    'image/heic',
    'image/heif'
  ]::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- archive_worksでも使用中の既存バケットを、そのまま新規作品のプレビューにも利用する。
update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[]
where id = 'exhibition-previews';

create or replace function private.current_member_owns_exhibition_object_path(target_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.exhibition_works work
    where work.event_id::text = split_part(target_path, '/', 1)
      and work.owner_member_id::text = split_part(target_path, '/', 2)
      and work.id::text = split_part(target_path, '/', 3)
      and work.owner_member_id = private.current_member_id()
      and split_part(target_path, '/', 4) <> ''
      and split_part(target_path, '/', 5) = ''
  )
$$;

create or replace function private.current_member_can_write_exhibition_object_path(target_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.exhibition_works work
    where work.event_id::text = split_part(target_path, '/', 1)
      and work.owner_member_id::text = split_part(target_path, '/', 2)
      and work.id::text = split_part(target_path, '/', 3)
      and work.owner_member_id = private.current_member_id()
      and split_part(target_path, '/', 4) <> ''
      and split_part(target_path, '/', 5) = ''
      and private.is_current_member()
      and private.is_available_exhibition_event(work.event_id)
  )
$$;

create or replace function private.validate_exhibition_work_image_paths()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_entry public.exhibition_entries%rowtype;
  expected_prefix text;
begin
  select * into target_entry
  from public.exhibition_entries entry
  where entry.id = new.entry_id;

  if target_entry.id is null then
    raise exception '出展申込が見つかりません。';
  end if;

  expected_prefix := target_entry.event_id::text
    || '/' || target_entry.member_id::text
    || '/' || new.id::text || '/';

  if new.original_image_path is not null
    and (
      new.original_image_path not like expected_prefix || '%'
      or split_part(new.original_image_path, '/', 4) = ''
      or split_part(new.original_image_path, '/', 5) <> ''
    )
  then
    raise exception '原画像の保存先が作品情報と一致しません。';
  end if;

  if new.preview_image_path is not null
    and (
      new.preview_image_path not like expected_prefix || '%'
      or split_part(new.preview_image_path, '/', 4) = ''
      or split_part(new.preview_image_path, '/', 5) <> ''
    )
  then
    raise exception 'プレビュー画像の保存先が作品情報と一致しません。';
  end if;

  if new.public_image_path is not null
    and (
      new.public_image_path not like expected_prefix || '%'
      or split_part(new.public_image_path, '/', 4) = ''
      or split_part(new.public_image_path, '/', 5) <> ''
    )
  then
    raise exception '公開用画像の保存先が作品情報と一致しません。';
  end if;

  return new;
end;
$$;

create trigger zz_exhibition_works_validate_image_paths_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_work_image_paths();

-- 原画像：本人と管理者だけが閲覧できる。
create policy exhibition_originals_owner_or_admin_select
on storage.objects for select to authenticated
using (
  bucket_id = 'exhibition-originals'
  and (
    private.is_admin()
    or private.current_member_owns_exhibition_object_path(name)
  )
);

create policy exhibition_originals_owner_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'exhibition-originals'
  and private.current_member_can_write_exhibition_object_path(name)
);

create policy exhibition_originals_owner_update
on storage.objects for update to authenticated
using (
  bucket_id = 'exhibition-originals'
  and private.current_member_can_write_exhibition_object_path(name)
)
with check (
  bucket_id = 'exhibition-originals'
  and private.current_member_can_write_exhibition_object_path(name)
);

create policy exhibition_originals_owner_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'exhibition-originals'
  and private.current_member_can_write_exhibition_object_path(name)
);

create policy exhibition_originals_admin_all
on storage.objects for all to authenticated
using (bucket_id = 'exhibition-originals' and private.is_admin())
with check (bucket_id = 'exhibition-originals' and private.is_admin());

-- プレビュー：既存archive用ポリシーに、新規作品の本人アクセスを追加する。
create policy exhibition_previews_current_owner_select
on storage.objects for select to authenticated
using (
  bucket_id = 'exhibition-previews'
  and private.current_member_owns_exhibition_object_path(name)
);

create policy exhibition_previews_current_owner_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'exhibition-previews'
  and private.current_member_can_write_exhibition_object_path(name)
);

create policy exhibition_previews_current_owner_update
on storage.objects for update to authenticated
using (
  bucket_id = 'exhibition-previews'
  and private.current_member_can_write_exhibition_object_path(name)
)
with check (
  bucket_id = 'exhibition-previews'
  and private.current_member_can_write_exhibition_object_path(name)
);

create policy exhibition_previews_current_owner_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'exhibition-previews'
  and private.current_member_can_write_exhibition_object_path(name)
);

revoke execute on function private.current_member_owns_exhibition_object_path(text) from public;
revoke execute on function private.current_member_can_write_exhibition_object_path(text) from public;
revoke execute on function private.validate_exhibition_work_image_paths() from public;

grant execute on function private.current_member_owns_exhibition_object_path(text) to authenticated;
grant execute on function private.current_member_can_write_exhibition_object_path(text) to authenticated;
