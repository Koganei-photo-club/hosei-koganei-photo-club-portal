-- Workflow v2の案内ページ先行公開と、Public Publicationの追加公開情報。
-- 案内ページは安全なEvent情報だけを返し、作品情報はCurrent Publicationだけを正本とする。

alter table public.exhibition_publication_versions
  add column if not exists event_title text not null default '';
alter table public.exhibition_publication_items
  add column if not exists instagram_public_url text,
  add column if not exists ai_processing_declaration text,
  add column if not exists ai_processing_details text not null default '';

create or replace function private.normalize_instagram_public_url(p_value text)
returns text language plpgsql immutable security definer set search_path='' as $$
declare v text:=trim(coalesce(p_value,''));m text[];
begin
  if v='' then return null; end if;
  if v~'^@?[A-Za-z0-9._]{1,30}$' then return 'https://www.instagram.com/'||ltrim(v,'@')||'/'; end if;
  m:=regexp_match(v,'^https://(www\.)?instagram\.com/([A-Za-z0-9._]{1,30})/?$','i');
  if m is not null then return 'https://www.instagram.com/'||m[2]||'/'; end if;
  return null;
end;
$$;

-- 既存Publicationは、migration適用時点の固定元から新規列を一度だけ補完する。
drop trigger if exists exhibition_publication_versions_immutable on public.exhibition_publication_versions;
update public.exhibition_publication_versions publication
set event_title=event.title from public.events event
where event.id=publication.event_id and publication.event_title='';
create trigger exhibition_publication_versions_immutable before update or delete on public.exhibition_publication_versions
for each row execute function private.prevent_exhibition_publication_mutation();

drop trigger if exists exhibition_publication_items_immutable on public.exhibition_publication_items;
update public.exhibition_publication_items publication_item
set instagram_public_url=private.normalize_instagram_public_url(export_item.instagram_qr_info),
    ai_processing_declaration=export_item.ai_processing_declaration,
    ai_processing_details=coalesce(export_item.ai_processing_details,'')
from public.exhibition_export_items export_item
where export_item.id=publication_item.source_export_item_id;
create trigger exhibition_publication_items_immutable before update or delete on public.exhibition_publication_items
for each row execute function private.prevent_exhibition_publication_mutation();

create or replace function private.populate_exhibition_publication_metadata()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='exhibition_publication_versions' then
    select event.title into new.event_title from public.events event where event.id=new.event_id;
    if nullif(trim(new.event_title),'') is null then raise exception 'Publicationへ固定するイベント名がありません。'; end if;
  else
    select private.normalize_instagram_public_url(export_item.instagram_qr_info),export_item.ai_processing_declaration,
      coalesce(export_item.ai_processing_details,'')
    into new.instagram_public_url,new.ai_processing_declaration,new.ai_processing_details
    from public.exhibition_export_items export_item where export_item.id=new.source_export_item_id;
  end if;
  return new;
end;
$$;

create trigger exhibition_publication_versions_metadata before insert on public.exhibition_publication_versions
for each row execute function private.populate_exhibition_publication_metadata();
create trigger exhibition_publication_items_metadata before insert on public.exhibition_publication_items
for each row execute function private.populate_exhibition_publication_metadata();

create or replace function public.admin_publish_exhibition_guide_v2(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype;actor text:=private.current_email();
begin
  if not private.is_admin() then raise exception '管理者のみ写真展案内ページを公開できます。'; end if;
  select * into event_row from public.events event where event.id=p_event_id for update;
  if event_row.id is null or event_row.genre<>'exhibition' or event_row.exhibition_workflow_version<>2 or event_row.deleted_at is not null then
    raise exception '対象のWorkflow v2写真展が見つかりません。';
  end if;
  if event_row.status<>'saved' then raise exception '下書きの写真展は案内ページを公開できません。'; end if;
  if nullif(trim(event_row.exhibition_key),'') is null or nullif(trim(event_row.site_title),'') is null
     or nullif(trim(event_row.site_description),'') is null or nullif(trim(event_row.place),'') is null
     or event_row.starts_at is null or event_row.ends_at is null then
    raise exception '写真展キー、サイト用タイトル、紹介文、日時、場所を設定してください。';
  end if;
  update public.events set site_status='published',site_published_at=coalesce(site_published_at,now()),site_ended_at=null,
    updated_at=now(),updated_by=actor where id=event_row.id;
  perform private.write_exhibition_workflow_audit(event_row.id,'event',event_row.id,'public_guide_published','admin',actor,'','{}',
    jsonb_build_object('exhibitionKey',event_row.exhibition_key,'hasCurrentPublication',event_row.current_publication_version_id is not null));
  return jsonb_build_object('eventId',event_row.id,'exhibitionKey',event_row.exhibition_key,'siteStatus','published',
    'hasCurrentPublication',event_row.current_publication_version_id is not null);
end;
$$;

create or replace function public.get_public_exhibition(p_exhibition_key text)
returns jsonb language sql stable security definer set search_path='' as $$
  select case
  when event.exhibition_workflow_version=2 and publication.id is not null then
    jsonb_build_object('exhibitionKey',event.exhibition_key,'publicationAvailable',true,
      'publicationVersionId',publication.id,'publicationVersionNo',publication.version_no,
      'eventName',publication.event_title,'title',publication.site_title,'titleEn',publication.site_title_en,
      'catchphrase',publication.site_catchphrase,'catchphraseEn',publication.site_catchphrase_en,
      'description',publication.site_description,'descriptionEn',publication.site_description_en,
      'startsAt',publication.starts_at,'endsAt',publication.ends_at,'place',publication.place,'placeEn',publication.place_en,
      'additionalInfo',publication.site_additional_info,'additionalInfoEn',publication.site_additional_info_en,
      'dmImagePath',publication.dm_image_path,'siteStatus',event.site_status,
      'surveyOpensAt',event.survey_opens_at,'surveyClosesAt',event.survey_closes_at,
      'works',case when event.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object(
        'workUuid',item.work_id,'displayNo',item.display_no,'title',item.title_ja,'titleEn',item.effective_english_title,
        'artist',item.display_name,'camera',item.camera,
        'lensOther',concat_ws(' / ',nullif(item.lens,''),nullif(item.film,''),nullif(item.medium_details,'')),
        'description',case when item.description_choice='provided' then item.description_ja else '' end,
        'descriptionEn',case when item.description_choice='provided' then item.description_en else '' end,
        'medium',item.medium,'instagramUrl',item.instagram_public_url,
        'aiProcessingDeclaration',item.ai_processing_declaration,'aiProcessingDetails',item.ai_processing_details,
        'imagePublic',item.image_state='public_image','imageState',item.image_state,
        'publicImagePath',case when item.image_state='public_image' then item.public_image_path else null end
      ) order by item.public_order) from public.exhibition_publication_items item
        where item.publication_version_id=publication.id),'[]'::jsonb) else '[]'::jsonb end)
  when event.exhibition_workflow_version=2 then
    jsonb_build_object('exhibitionKey',event.exhibition_key,'publicationAvailable',false,
      'publicationVersionId',null,'publicationVersionNo',null,'eventName',event.title,
      'title',event.site_title,'titleEn',event.site_title_en,'catchphrase',event.site_catchphrase,'catchphraseEn',event.site_catchphrase_en,
      'description',event.site_description,'descriptionEn',event.site_description_en,
      'startsAt',event.starts_at,'endsAt',event.ends_at,'place',event.place,'placeEn',event.place_en,
      'additionalInfo',event.site_additional_info,'additionalInfoEn',event.site_additional_info_en,
      'dmImagePath',event.dm_image_path,'siteStatus',event.site_status,
      'surveyOpensAt',event.survey_opens_at,'surveyClosesAt',event.survey_closes_at,'works','[]'::jsonb)
  else
    jsonb_build_object('exhibitionKey',event.exhibition_key,'publicationAvailable',false,'eventName',event.title,
      'title',event.site_title,'titleEn',event.site_title_en,'catchphrase',event.site_catchphrase,'catchphraseEn',event.site_catchphrase_en,
      'description',event.site_description,'descriptionEn',event.site_description_en,
      'startsAt',event.starts_at,'endsAt',event.ends_at,'place',event.place,'placeEn',event.place_en,
      'additionalInfo',event.site_additional_info,'additionalInfoEn',event.site_additional_info_en,
      'dmImagePath',event.dm_image_path,'siteStatus',event.site_status,
      'surveyOpensAt',event.survey_opens_at,'surveyClosesAt',event.survey_closes_at,
      'works',case when event.site_status='published' then coalesce((select jsonb_agg(jsonb_build_object(
        'workUuid',work.id,'displayNo',work.display_no,'title',work.title,'titleEn',work.title_en,
        'artist',work.artist_name,'camera',work.camera_name,'lensOther',work.lens_other,
        'description',work.description,'descriptionEn',work.description_en,'imagePublic',work.publication_consent,
        'imageState',case when work.publication_consent then 'public_image' else 'no_image' end,
        'publicImagePath',case when work.publication_consent and work.public_release then work.public_image_path else null end)
        order by case when work.display_no~'^[0-9]+$' then work.display_no::integer else 2147483647 end,work.display_no)
        from public.exhibition_works work where work.event_id=event.id and work.status='accepted'),'[]'::jsonb) else '[]'::jsonb end)
  end
  from public.events event
  left join public.exhibition_publication_versions publication on publication.id=event.current_publication_version_id
  where event.exhibition_key=p_exhibition_key and event.genre='exhibition' and event.status='saved'
    and event.deleted_at is null and event.site_status in('published','ended')
$$;

revoke execute on function private.normalize_instagram_public_url(text),private.populate_exhibition_publication_metadata() from public,anon,authenticated;
revoke all on function public.admin_publish_exhibition_guide_v2(uuid) from public,anon;
grant execute on function public.admin_publish_exhibition_guide_v2(uuid) to authenticated;
