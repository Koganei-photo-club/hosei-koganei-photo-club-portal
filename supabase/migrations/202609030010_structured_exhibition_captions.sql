-- 写真展キャプションを印刷・展示作業で扱いやすい構造へ分割する。

alter table public.exhibition_works
  add column if not exists artist_name text not null default '',
  add column if not exists camera_name text not null default '',
  add column if not exists lens_other text not null default '',
  add column if not exists description text not null default '';

-- 既存の自由記述キャプションはDescriptionへ引き継ぐ。
update public.exhibition_works
set description = caption
where description = '' and caption <> '';

alter table public.exhibition_works
  drop constraint if exists exhibition_works_artist_name_length,
  drop constraint if exists exhibition_works_camera_name_length,
  drop constraint if exists exhibition_works_lens_other_length,
  drop constraint if exists exhibition_works_description_length;

alter table public.exhibition_works
  add constraint exhibition_works_artist_name_length
    check (char_length(artist_name) <= 100),
  add constraint exhibition_works_camera_name_length
    check (char_length(camera_name) <= 200),
  add constraint exhibition_works_lens_other_length
    check (char_length(lens_other) <= 500),
  add constraint exhibition_works_description_length
    check (char_length(description) <= 3000);

create or replace function private.validate_exhibition_work_caption_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('submitted', 'accepted') then
    if trim(new.artist_name) = '' then
      raise exception '作者名・ペンネームを入力してください。';
    end if;
    if trim(new.camera_name) = '' then
      raise exception 'Cameraを入力してください。';
    end if;
  end if;

  -- 旧caption列を参照する既存処理との互換性を維持する。
  new.caption = new.description;
  return new;
end;
$$;

create trigger zzzz_exhibition_works_validate_caption_fields_before_write
before insert or update on public.exhibition_works
for each row execute function private.validate_exhibition_work_caption_fields();

revoke execute on function private.validate_exhibition_work_caption_fields() from public;

