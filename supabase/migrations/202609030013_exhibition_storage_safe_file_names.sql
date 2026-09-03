-- StorageのオブジェクトキーはASCIIに限定し、日本語の管理用ファイル名はダウンロード時に付与する。
create or replace function private.validate_exhibition_work_print_specifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_entry public.exhibition_entries%rowtype;
  target_member public.members%rowtype;
  original_path_changed boolean;
  actual_file_name text;
  file_extension text;
  safe_member_no text;
  expected_file_name text;
begin
  if new.status in ('submitted', 'accepted') then
    if new.orientation not in ('portrait', 'landscape') then
      raise exception '作品の向きを選択してください。';
    end if;
    if new.print_size not in ('A4', 'A3', 'A2', 'composite', 'other') then
      raise exception '出展サイズを選択してください。';
    end if;
    if new.print_size in ('composite', 'other') and trim(new.print_size_detail) = '' then
      raise exception '組み写真・その他のサイズ詳細を入力してください。';
    end if;
  end if;

  original_path_changed := tg_op = 'INSERT';
  if tg_op = 'UPDATE' then
    original_path_changed := new.original_image_path is distinct from old.original_image_path;
  end if;

  if new.original_image_path is not null and original_path_changed then
    select * into target_entry from public.exhibition_entries where id = new.entry_id;
    select * into target_member from public.members where id = target_entry.member_id;
    safe_member_no := regexp_replace(target_member.member_no, '[^A-Za-z0-9_-]', '_', 'g');
    actual_file_name := regexp_replace(new.original_image_path, '^.*/', '');
    file_extension := lower(regexp_replace(actual_file_name, '^.*\.', ''));
    expected_file_name := safe_member_no || '_work-' || new.sort_order::text || '.' || file_extension;
    if actual_file_name <> expected_file_name then
      raise exception '原画像の内部保存名は「%」にしてください。', expected_file_name;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function private.validate_exhibition_work_print_specifications() from public;
