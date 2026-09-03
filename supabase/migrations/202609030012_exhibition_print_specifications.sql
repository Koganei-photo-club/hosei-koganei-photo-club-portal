-- 展示方向・出展サイズを収集し、新規原画像のStorageファイル名を統一する。

alter table public.exhibition_works
  add column if not exists orientation text not null default '',
  add column if not exists print_size text not null default '',
  add column if not exists print_size_detail text not null default '';

alter table public.exhibition_works
  drop constraint if exists exhibition_works_orientation_check,
  drop constraint if exists exhibition_works_print_size_check,
  drop constraint if exists exhibition_works_print_size_detail_length;

alter table public.exhibition_works
  add constraint exhibition_works_orientation_check
    check (orientation in ('', 'portrait', 'landscape')),
  add constraint exhibition_works_print_size_check
    check (print_size in ('', 'A4', 'A3', 'A2', 'composite', 'other')),
  add constraint exhibition_works_print_size_detail_length
    check (char_length(print_size_detail) <= 500);

create or replace function private.validate_exhibition_work_print_specifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_entry public.exhibition_entries%rowtype;
  target_member public.members%rowtype;
  safe_member_name text;
  file_extension text;
  expected_file_name text;
  actual_file_name text;
  original_path_changed boolean;
begin
  if new.status in ('submitted', 'accepted') then
    if new.orientation not in ('portrait', 'landscape') then
      raise exception '作品の向きを選択してください。';
    end if;
    if new.print_size not in ('A4', 'A3', 'A2', 'composite', 'other') then
      raise exception '出展サイズを選択してください。';
    end if;
    if new.print_size in ('composite', 'other')
      and trim(new.print_size_detail) = '' then
      raise exception '組み写真・その他のサイズ詳細を入力してください。';
    end if;
  end if;

  -- 既存ファイルはそのまま保持し、新規アップロード・差し替え時だけ命名を検証する。
  original_path_changed := tg_op = 'INSERT';
  if tg_op = 'UPDATE' then
    original_path_changed := new.original_image_path is distinct from old.original_image_path;
  end if;

  if new.original_image_path is not null and original_path_changed then
    select * into target_entry
    from public.exhibition_entries entry
    where entry.id = new.entry_id;
    select * into target_member
    from public.members member
    where member.id = target_entry.member_id;

    safe_member_name := trim(regexp_replace(
      target_member.name,
      '[\\/:*?"<>|[:cntrl:]]',
      '_',
      'g'
    ));
    if safe_member_name = '' then
      safe_member_name := target_member.member_no;
    end if;

    actual_file_name := regexp_replace(new.original_image_path, '^.*/', '');
    file_extension := lower(regexp_replace(actual_file_name, '^.*\.', ''));
    expected_file_name := safe_member_name
      || '_作品' || new.sort_order::text
      || '.' || file_extension;

    if actual_file_name <> expected_file_name then
      raise exception '原画像のファイル名は「%」にしてください。', expected_file_name;
    end if;
  end if;

  return new;
end;
$$;

create trigger zzzzz_exhibition_works_validate_print_specifications_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_work_print_specifications();

revoke execute on function private.validate_exhibition_work_print_specifications() from public;
