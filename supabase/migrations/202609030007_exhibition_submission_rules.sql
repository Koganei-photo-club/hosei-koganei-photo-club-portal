-- 出展申込を提出済みにする際の必須条件をデータベース側でも保証する。

create or replace function private.validate_exhibition_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_genre public.event_genre;
  active_work_count integer;
  incomplete_work_count integer;
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

  if new.status = 'submitted' then
    -- 新規INSERT時には作品を先に紐付けられないため、提出確定はUPDATEでのみ行う。
    if tg_op = 'INSERT' then
      raise exception '出展申込を下書きとして作成してから作品を登録してください。';
    end if;

    select
      count(*) filter (where work.status <> 'withdrawn'),
      count(*) filter (
        where work.status <> 'withdrawn'
          and (
            work.status not in ('submitted', 'accepted')
            or trim(work.title) = ''
            or work.original_image_path is null
          )
      )
    into active_work_count, incomplete_work_count
    from public.exhibition_works work
    where work.entry_id = new.id;

    if active_work_count < 1 then
      raise exception '提出する作品を1件以上登録してください。';
    end if;
    if incomplete_work_count > 0 then
      raise exception '作品名と原画像を登録し、すべての作品を提出済みにしてください。';
    end if;
    if new.submitted_at is null then
      new.submitted_at = now();
    end if;
  elsif new.status = 'draft' then
    new.submitted_at = null;
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

  if new.status = 'submitted' then
    if trim(new.title) = '' then
      raise exception '作品名を入力してください。';
    end if;
    if new.original_image_path is null then
      raise exception '原画像を登録してください。';
    end if;
    if new.submitted_at is null then
      new.submitted_at = now();
    end if;
  elsif new.status = 'draft' then
    new.submitted_at = null;
  end if;
  return new;
end;
$$;
