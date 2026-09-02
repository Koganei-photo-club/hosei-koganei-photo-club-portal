-- 利用者が選択した原画像のファイル名を、画面表示用として保持する。

alter table public.exhibition_works
  add column if not exists original_file_name text not null default '';

alter table public.exhibition_works
  drop constraint if exists exhibition_works_original_file_name_length;

alter table public.exhibition_works
  add constraint exhibition_works_original_file_name_length
  check (char_length(original_file_name) <= 255);

-- 既存データは元のローカルファイル名を復元できないため、
-- Storage上のファイル名を代替表示用に設定する。
update public.exhibition_works
set original_file_name = regexp_replace(original_image_path, '^.*/', '')
where original_file_name = ''
  and original_image_path is not null;

