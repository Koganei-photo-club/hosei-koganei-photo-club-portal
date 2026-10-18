-- Member My Page: read-only Workflow v2 exhibition history.
-- Regular works are attributed to their owner. Smartphone groups are returned only as
-- participation records; group votes/comments are intentionally not attributed to a member.

create or replace function public.get_my_exhibition_history_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  member_uuid uuid := private.current_member_id();
  regular_items jsonb;
  smartphone_items jsonb;
begin
  if member_uuid is null then
    raise exception '部員登録が必要です。';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'archiveItemId', history.archive_item_id,
    'eventId', history.event_id,
    'eventTitle', history.event_title,
    'exhibitionKey', history.exhibition_key,
    'endedAt', history.ends_at,
    'displayNo', history.display_no,
    'title', history.title_ja,
    'caption', history.description_ja,
    'camera', history.camera,
    'lens', history.lens,
    'film', history.film,
    'imageBucket', history.image_bucket,
    'imagePath', history.image_path,
    'publicationConsent', history.publication_consent,
    'voteCount', history.vote_count,
    'responseCount', history.response_count,
    'favoriteRate', case when history.response_count > 0 then round(history.vote_count::numeric * 100 / history.response_count, 2) else 0 end,
    'comments', history.comments
  ) order by history.ends_at desc nulls last, history.display_no), '[]'::jsonb)
  into regular_items
  from (
    select archive_item.id archive_item_id, event_row.id event_id, event_row.title event_title,
      event_row.exhibition_key, event_row.ends_at, archive_item.display_no, archive_item.title_ja,
      archive_item.description_ja, archive_item.camera, archive_item.lens, archive_item.film,
      'exhibition-originals'::text image_bucket,
      work_snapshot.original_image_path image_path,
      archive_item.publication_consent,
      count(distinct survey_selection.response_id)::integer vote_count,
      (select count(*)::integer from public.exhibition_survey_responses response_row
       where response_row.event_id=event_row.id and response_row.publication_version_id is not null) response_count,
      coalesce(jsonb_agg(survey_selection.comment order by survey_response.submitted_at, survey_selection.id)
        filter(where nullif(trim(survey_selection.comment),'') is not null), '[]'::jsonb) comments
    from public.exhibition_archive_items archive_item
    join public.exhibition_archive_versions archive_version on archive_version.id=archive_item.archive_version_id
    join public.events event_row on event_row.id=archive_item.event_id
      and event_row.current_archive_version_id=archive_version.id
    join public.exhibition_works work_row on work_row.id=archive_item.work_id and work_row.owner_member_id=member_uuid
    join public.exhibition_work_submission_snapshots work_snapshot on work_snapshot.id=archive_item.work_submission_snapshot_id
    left join public.exhibition_survey_selections survey_selection on survey_selection.display_item_id=archive_item.display_item_id
    left join public.exhibition_survey_responses survey_response on survey_response.id=survey_selection.response_id
    where archive_item.display_item_type='regular_work'
    group by archive_item.id,event_row.id,event_row.title,event_row.exhibition_key,event_row.ends_at,
      archive_item.display_no,archive_item.title_ja,archive_item.description_ja,archive_item.camera,
      archive_item.lens,archive_item.film,work_snapshot.original_image_path,
      archive_item.publication_consent
  ) history;

  select coalesce(jsonb_agg(jsonb_build_object(
    'archiveItemId', history.archive_item_id,
    'eventId', history.event_id,
    'eventTitle', history.event_title,
    'exhibitionKey', history.exhibition_key,
    'endedAt', history.ends_at,
    'displayNo', history.display_no,
    'displayName', history.title_ja,
    'workCount', history.smartphone_work_count
  ) order by history.ends_at desc nulls last, history.display_no), '[]'::jsonb)
  into smartphone_items
  from (
    select distinct archive_item.id archive_item_id,event_row.id event_id,event_row.title event_title,
      event_row.exhibition_key,event_row.ends_at,archive_item.display_no,archive_item.title_ja,
      archive_item.smartphone_work_count
    from public.exhibition_archive_items archive_item
    join public.exhibition_archive_versions archive_version on archive_version.id=archive_item.archive_version_id
    join public.events event_row on event_row.id=archive_item.event_id
      and event_row.current_archive_version_id=archive_version.id
    join public.exhibition_smartphone_group_version_items version_item
      on version_item.group_version_id=archive_item.smartphone_group_version_id
    join public.exhibition_smartphone_works smartphone_work
      on smartphone_work.id=version_item.smartphone_work_id and smartphone_work.member_id=member_uuid
    where archive_item.display_item_type='smartphone_group'
  ) history;

  return jsonb_build_object('regularWorks',regular_items,'smartphoneGroups',smartphone_items);
end;
$$;

revoke all on function public.get_my_exhibition_history_v1() from public, anon;
grant execute on function public.get_my_exhibition_history_v1() to authenticated;
