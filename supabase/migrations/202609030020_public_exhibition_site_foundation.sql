-- 統合ポータルを正本として、新規写真展の一般公開ページを管理する基盤。
-- 既存の写真展サイト・旧アンケートには影響しない。

alter table public.events
  add column if not exists exhibition_key text,
  add column if not exists site_title text not null default '',
  add column if not exists site_catchphrase text not null default '',
  add column if not exists site_description text not null default '',
  add column if not exists dm_image_path text,
  add column if not exists site_status text not null default 'draft',
  add column if not exists site_published_at timestamptz,
  add column if not exists site_ended_at timestamptz,
  add column if not exists survey_opens_at timestamptz,
  add column if not exists survey_closes_at timestamptz;

alter table public.events
  drop constraint if exists events_exhibition_key_format,
  drop constraint if exists events_site_status_check,
  drop constraint if exists events_site_title_length,
  drop constraint if exists events_site_catchphrase_length,
  drop constraint if exists events_site_description_length,
  drop constraint if exists events_dm_image_path_length,
  drop constraint if exists events_survey_period_check;

alter table public.events
  add constraint events_exhibition_key_format check (
    exhibition_key is null
    or (
      genre = 'exhibition'
      and exhibition_key ~ '^[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*$'
    )
  ),
  add constraint events_site_status_check
    check (site_status in ('draft', 'published', 'ended')),
  add constraint events_site_title_length check (char_length(site_title) <= 200),
  add constraint events_site_catchphrase_length check (char_length(site_catchphrase) <= 300),
  add constraint events_site_description_length check (char_length(site_description) <= 5000),
  add constraint events_dm_image_path_length
    check (dm_image_path is null or char_length(dm_image_path) <= 1000),
  add constraint events_survey_period_check check (
    survey_opens_at is null
    or survey_closes_at is null
    or survey_opens_at < survey_closes_at
  );

create unique index if not exists events_exhibition_key_unique
  on public.events(exhibition_key)
  where exhibition_key is not null;

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'exhibition-public',
  'exhibition-public',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists exhibition_public_admin_insert on storage.objects;
create policy exhibition_public_admin_insert
on storage.objects for insert to authenticated
with check (bucket_id = 'exhibition-public' and private.is_admin());

drop policy if exists exhibition_public_admin_update on storage.objects;
create policy exhibition_public_admin_update
on storage.objects for update to authenticated
using (bucket_id = 'exhibition-public' and private.is_admin())
with check (bucket_id = 'exhibition-public' and private.is_admin());

drop policy if exists exhibition_public_admin_delete on storage.objects;
create policy exhibition_public_admin_delete
on storage.objects for delete to authenticated
using (bucket_id = 'exhibition-public' and private.is_admin());

create or replace function public.admin_publish_exhibition_site(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.events%rowtype;
  active_work_count integer;
  invalid_work_count integer;
begin
  if not private.is_admin() then
    raise exception '管理者のみ写真展サイトを公開できます。';
  end if;

  select * into target from public.events where id = p_event_id for update;
  if target.id is null or target.genre <> 'exhibition' or target.deleted_at is not null then
    raise exception '対象の写真展が見つかりません。';
  end if;
  if target.status <> 'saved' then
    raise exception '下書きの写真展は公開できません。';
  end if;
  if nullif(trim(target.exhibition_key), '') is null then
    raise exception '写真展キーを入力してください。';
  end if;
  if nullif(trim(target.site_title), '') is null
     or nullif(trim(target.site_description), '') is null
     or nullif(trim(target.place), '') is null
     or target.starts_at is null
     or target.ends_at is null
     or target.dm_image_path is null then
    raise exception 'サイト用タイトル、紹介文、日時、場所、DM画像をすべて設定してください。';
  end if;

  select count(*) into active_work_count
  from public.exhibition_works work
  where work.event_id = target.id and work.status <> 'withdrawn';
  if active_work_count = 0 then
    raise exception '公開対象の作品がありません。';
  end if;

  select count(*) into invalid_work_count
  from public.exhibition_works work
  where work.event_id = target.id
    and work.status <> 'withdrawn'
    and (
      work.status <> 'accepted'
      or nullif(trim(work.display_no), '') is null
      or work.publication_consent is null
      or (
        work.publication_consent
        and (
          not work.public_release
          or work.public_image_path is null
        )
      )
    );
  if invalid_work_count > 0 then
    raise exception '公開条件を満たしていない作品が%点あります。作品確認、作品番号、掲載可否、公開用画像を確認してください。', invalid_work_count;
  end if;

  update public.events
  set site_status = 'published',
      site_published_at = coalesce(site_published_at, now()),
      site_ended_at = null,
      updated_at = now(),
      updated_by = private.current_email()
  where id = target.id;

  return jsonb_build_object(
    'ok', true,
    'eventId', target.id,
    'exhibitionKey', target.exhibition_key,
    'workCount', active_work_count,
    'siteStatus', 'published'
  );
end;
$$;

create or replace function public.admin_end_exhibition_site(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.events%rowtype;
begin
  if not private.is_admin() then
    raise exception '管理者のみ写真展サイトの公開を終了できます。';
  end if;
  select * into target from public.events where id = p_event_id for update;
  if target.id is null or target.genre <> 'exhibition' then
    raise exception '対象の写真展が見つかりません。';
  end if;
  if target.site_status <> 'published' then
    raise exception '公開中の写真展のみ公開を終了できます。';
  end if;
  update public.events
  set site_status = 'ended',
      site_ended_at = now(),
      updated_at = now(),
      updated_by = private.current_email()
  where id = target.id;
  return jsonb_build_object(
    'ok', true,
    'eventId', target.id,
    'exhibitionKey', target.exhibition_key,
    'siteStatus', 'ended'
  );
end;
$$;

create or replace function public.get_public_exhibition(p_exhibition_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'exhibitionKey', event.exhibition_key,
    'title', event.site_title,
    'catchphrase', event.site_catchphrase,
    'description', event.site_description,
    'startsAt', event.starts_at,
    'endsAt', event.ends_at,
    'place', event.place,
    'contact', event.contact,
    'dmImagePath', event.dm_image_path,
    'siteStatus', event.site_status,
    'surveyOpensAt', event.survey_opens_at,
    'surveyClosesAt', event.survey_closes_at,
    'works', case
      when event.site_status = 'published' then coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'workUuid', work.id,
            'displayNo', work.display_no,
            'title', work.title,
            'artist', work.artist_name,
            'camera', work.camera_name,
            'lensOther', work.lens_other,
            'description', work.description,
            'imagePublic', work.publication_consent,
            'publicImagePath', case
              when work.publication_consent and work.public_release
                then work.public_image_path
              else null
            end
          ) order by
            case when work.display_no ~ '^[0-9]+$' then work.display_no::integer else 2147483647 end,
            work.display_no
        )
        from public.exhibition_works work
        where work.event_id = event.id
          and work.status = 'accepted'
      ), '[]'::jsonb)
      else '[]'::jsonb
    end
  )
  from public.events event
  where event.exhibition_key = p_exhibition_key
    and event.genre = 'exhibition'
    and event.status = 'saved'
    and event.deleted_at is null
    and event.site_status in ('published', 'ended');
$$;

revoke all on function public.admin_publish_exhibition_site(uuid) from public, anon;
revoke all on function public.admin_end_exhibition_site(uuid) from public, anon;
grant execute on function public.admin_publish_exhibition_site(uuid) to authenticated;
grant execute on function public.admin_end_exhibition_site(uuid) to authenticated;

revoke all on function public.get_public_exhibition(text) from public;
grant execute on function public.get_public_exhibition(text) to anon, authenticated;

select
  (
    select count(*) = 10
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'events'
      and column_name in (
        'exhibition_key', 'site_title', 'site_catchphrase',
        'site_description', 'dm_image_path', 'site_status',
        'site_published_at', 'site_ended_at',
        'survey_opens_at', 'survey_closes_at'
      )
  ) as event_columns_ready,
  exists (
    select 1 from storage.buckets where id = 'exhibition-public' and public
  ) as public_bucket_ready,
  to_regprocedure('public.admin_publish_exhibition_site(uuid)') is not null
    as publish_function_ready,
  to_regprocedure('public.admin_end_exhibition_site(uuid)') is not null
    as end_function_ready,
  to_regprocedure('public.get_public_exhibition(text)') is not null
    as public_api_ready;
