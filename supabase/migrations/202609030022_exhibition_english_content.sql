-- 今後の写真展サイトで、日本語版と英語版を同じ写真展データから提供する。
-- 英語欄はすべて任意。空欄の場合はフロント側で日本語を代替表示する。

alter table public.events
  add column if not exists site_title_en text not null default '',
  add column if not exists site_catchphrase_en text not null default '',
  add column if not exists site_description_en text not null default '',
  add column if not exists place_en text not null default '',
  add column if not exists site_additional_info text not null default '',
  add column if not exists site_additional_info_en text not null default '';

alter table public.exhibition_works
  add column if not exists title_en text not null default '',
  add column if not exists description_en text not null default '';

alter table public.events
  drop constraint if exists events_site_title_en_length,
  drop constraint if exists events_site_catchphrase_en_length,
  drop constraint if exists events_site_description_en_length,
  drop constraint if exists events_place_en_length,
  drop constraint if exists events_site_additional_info_length,
  drop constraint if exists events_site_additional_info_en_length;

alter table public.events
  add constraint events_site_title_en_length
    check (char_length(site_title_en) <= 200),
  add constraint events_site_catchphrase_en_length
    check (char_length(site_catchphrase_en) <= 300),
  add constraint events_site_description_en_length
    check (char_length(site_description_en) <= 5000),
  add constraint events_place_en_length
    check (char_length(place_en) <= 500),
  add constraint events_site_additional_info_length
    check (char_length(site_additional_info) <= 3000),
  add constraint events_site_additional_info_en_length
    check (char_length(site_additional_info_en) <= 3000);

alter table public.exhibition_works
  drop constraint if exists exhibition_works_title_en_length,
  drop constraint if exists exhibition_works_description_en_length;

alter table public.exhibition_works
  add constraint exhibition_works_title_en_length
    check (char_length(title_en) <= 500),
  add constraint exhibition_works_description_en_length
    check (char_length(description_en) <= 3000);

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
    'titleEn', event.site_title_en,
    'catchphrase', event.site_catchphrase,
    'catchphraseEn', event.site_catchphrase_en,
    'description', event.site_description,
    'descriptionEn', event.site_description_en,
    'startsAt', event.starts_at,
    'endsAt', event.ends_at,
    'place', event.place,
    'placeEn', event.place_en,
    'additionalInfo', event.site_additional_info,
    'additionalInfoEn', event.site_additional_info_en,
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
            'titleEn', work.title_en,
            'artist', work.artist_name,
            'camera', work.camera_name,
            'lensOther', work.lens_other,
            'description', work.description,
            'descriptionEn', work.description_en,
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

revoke all on function public.get_public_exhibition(text) from public;
grant execute on function public.get_public_exhibition(text) to anon, authenticated;

select
  (
    select count(*) = 6
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'events'
      and column_name in (
        'site_title_en', 'site_catchphrase_en', 'site_description_en',
        'place_en', 'site_additional_info', 'site_additional_info_en'
      )
  ) as exhibition_english_fields_ready,
  (
    select count(*) = 2
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'exhibition_works'
      and column_name in ('title_en', 'description_en')
  ) as work_english_fields_ready,
  to_regprocedure('public.get_public_exhibition(text)') is not null
    as bilingual_public_api_ready;
