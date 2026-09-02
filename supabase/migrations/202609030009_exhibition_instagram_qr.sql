-- 作品ごとに任意のInstagram QRコードを登録できるようにする。
-- QR画像は非公開の exhibition-previews バケットへ保存する。

alter table public.exhibition_works
  add column if not exists instagram_qr_path text,
  add column if not exists instagram_qr_file_name text not null default '';

alter table public.exhibition_works
  drop constraint if exists exhibition_works_instagram_qr_file_name_length;

alter table public.exhibition_works
  add constraint exhibition_works_instagram_qr_file_name_length
  check (char_length(instagram_qr_file_name) <= 255);

create or replace function private.validate_exhibition_work_instagram_qr_path()
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

  if new.instagram_qr_path is not null
    and (
      new.instagram_qr_path not like expected_prefix || '%'
      or split_part(new.instagram_qr_path, '/', 4) = ''
      or split_part(new.instagram_qr_path, '/', 5) <> ''
    )
  then
    raise exception 'Instagram QRコードの保存先が作品情報と一致しません。';
  end if;

  if new.instagram_qr_path is null then
    new.instagram_qr_file_name = '';
  end if;

  return new;
end;
$$;

create trigger zzz_exhibition_works_validate_instagram_qr_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_work_instagram_qr_path();

revoke execute on function private.validate_exhibition_work_instagram_qr_path() from public;

