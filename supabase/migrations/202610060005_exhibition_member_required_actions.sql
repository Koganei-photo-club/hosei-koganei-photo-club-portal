-- Member-facing required actions for Workflow v2 Work / Caption / Smartphone Work.
-- The result is derived from authoritative workflow state; no mutable notification rows are stored.

create or replace function public.get_my_exhibition_required_actions_v1()
returns table(
  action_type text,
  event_id uuid,
  event_title text,
  target_type text,
  target_id uuid,
  work_id uuid,
  work_title text,
  smartphone_work_id uuid,
  smartphone_sort_order integer,
  problem_fields text[],
  reason text,
  deadline timestamptz,
  section text,
  priority integer,
  occurred_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  member_uuid uuid := private.current_member_id();
begin
  if member_uuid is null or not private.is_current_member() then
    raise exception '有効な部員登録が必要です。';
  end if;

  return query
  with regular_base as (
    select work_row.*, event_row.title as event_title_value,
      coalesce(accepted_snapshot.title, submitted_snapshot.title, work_row.title, '') as work_title_value
    from public.exhibition_works work_row
    join public.events event_row on event_row.id = work_row.event_id
      and event_row.exhibition_workflow_version = 2
      and event_row.deleted_at is null
    join public.exhibition_entries entry_row on entry_row.id = work_row.entry_id
      and entry_row.member_id = member_uuid
      and entry_row.application_state = 'active'
    left join public.exhibition_work_submission_snapshots accepted_snapshot
      on accepted_snapshot.id = work_row.current_accepted_snapshot_id
    left join public.exhibition_work_submission_snapshots submitted_snapshot
      on submitted_snapshot.id = work_row.current_submission_snapshot_id
    where work_row.owner_member_id = member_uuid
      and work_row.workflow_state <> 'withdrawn'
  ), action_rows as (
    select case_row.case_type,
      case when case_row.case_type = 'correction' then 'regular_work_correction' else 'regular_work_reedit' end as action_name,
      base.event_id, base.event_title_value, 'regular_work'::text as target_kind, base.id as target_uuid,
      base.id as regular_work_uuid, base.work_title_value, null::uuid as smartphone_uuid,
      null::integer as smartphone_order,
      coalesce(review_row.problem_fields, '{}'::text[]) as problem_list,
      case when case_row.case_type = 'correction' then coalesce(review_row.reason, case_row.decision_reason, '')
        else coalesce(nullif(case_row.decision_reason, ''), case_row.request_reason, '') end as action_reason,
      case_row.individual_deadline as action_deadline,
      'work'::text as target_section,
      case when case_row.case_type = 'correction' then 10 else 20 end as action_priority,
      coalesce(case_row.decided_at, case_row.requested_at) as action_occurred_at
    from regular_base base
    join public.exhibition_workflow_cases case_row on case_row.work_id = base.id
    left join public.exhibition_work_reviews review_row on review_row.id = case_row.source_review_id
    where now() < case_row.individual_deadline
      and ((case_row.case_type = 'correction' and case_row.state = 'open' and base.workflow_state = 'rejected')
        or (case_row.case_type = 'reedit' and case_row.state = 'permitted' and base.workflow_state = 'reedit_editing'))

    union all

    select case_row.case_type,
      case when case_row.case_type = 'correction' then 'caption_correction' else 'caption_reedit' end,
      base.event_id, base.event_title_value, 'caption', base.id, base.id, base.work_title_value,
      null::uuid, null::integer, coalesce(review_row.problem_fields, '{}'::text[]),
      case when case_row.case_type = 'correction' then coalesce(review_row.reason, case_row.decision_reason, '')
        else coalesce(nullif(case_row.decision_reason, ''), case_row.request_reason, '') end,
      case_row.individual_deadline, 'caption',
      case when case_row.case_type = 'correction' then 10 else 20 end,
      coalesce(case_row.decided_at, case_row.requested_at)
    from regular_base base
    join public.exhibition_caption_working_data caption_row on caption_row.work_id = base.id
      and caption_row.member_id = member_uuid
    join public.exhibition_caption_workflow_cases case_row on case_row.work_id = base.id
    left join public.exhibition_caption_reviews review_row on review_row.id = case_row.source_review_id
    where now() < case_row.individual_deadline
      and ((case_row.case_type = 'correction' and case_row.state = 'open' and caption_row.state = 'rejected')
        or (case_row.case_type = 'reedit' and case_row.state = 'permitted' and caption_row.state = 'reedit_editing'))

    union all

    select null::text, 'caption_missing', base.event_id, base.event_title_value, 'caption', base.id,
      base.id, base.work_title_value, null::uuid, null::integer, '{}'::text[],
      'キャプションを登録してください。', event_row.exhibition_caption_deadline, 'caption', 40, base.updated_at
    from regular_base base
    join public.events event_row on event_row.id = base.event_id
    left join public.exhibition_caption_working_data caption_row on caption_row.work_id = base.id
    where base.workflow_state = 'accepted'
      and private.exhibition_deadline_is_open(base.event_id, 'caption')
      and caption_row.current_submission_snapshot_id is null
      and caption_row.current_accepted_snapshot_id is null
      and not exists (
        select 1 from public.exhibition_caption_workflow_cases open_case
        where open_case.work_id = base.id and open_case.state in ('pending', 'open', 'permitted')
      )

    union all

    select null::text, 'caption_stale', base.event_id, base.event_title_value, 'caption', base.id,
      base.id, base.work_title_value, null::uuid, null::integer, '{}'::text[],
      '現在の作品内容に合わせてキャプションを再確認してください。', event_row.exhibition_caption_deadline,
      'caption', 30, caption_row.updated_at
    from regular_base base
    join public.events event_row on event_row.id = base.event_id
    join public.exhibition_caption_working_data caption_row on caption_row.work_id = base.id
      and caption_row.member_id = member_uuid
    join public.exhibition_caption_submission_snapshots accepted_caption
      on accepted_caption.id = caption_row.current_accepted_snapshot_id
    left join public.exhibition_caption_submission_snapshots submitted_caption
      on submitted_caption.id = caption_row.current_submission_snapshot_id
    where base.workflow_state = 'accepted'
      and private.exhibition_deadline_is_open(base.event_id, 'caption')
      and accepted_caption.work_submission_snapshot_id is distinct from base.current_accepted_snapshot_id
      and submitted_caption.work_submission_snapshot_id is distinct from base.current_accepted_snapshot_id
      and not exists (
        select 1 from public.exhibition_caption_workflow_cases open_case
        where open_case.work_id = base.id and open_case.state in ('pending', 'open', 'permitted')
      )

    union all

    select case_row.case_type,
      case when case_row.case_type = 'correction' then 'smartphone_work_correction' else 'smartphone_work_reedit' end,
      smartphone_row.event_id, event_row.title, 'smartphone_work', smartphone_row.id,
      null::uuid, ''::text, smartphone_row.id, smartphone_row.sort_order,
      coalesce(review_row.problem_fields, '{}'::text[]),
      case when case_row.case_type = 'correction' then coalesce(review_row.reason, case_row.decision_reason, '')
        else coalesce(nullif(case_row.decision_reason, ''), case_row.request_reason, '') end,
      case_row.individual_deadline, 'smartphone',
      case when case_row.case_type = 'correction' then 10 else 20 end,
      coalesce(case_row.decided_at, case_row.requested_at)
    from public.exhibition_smartphone_works smartphone_row
    join public.events event_row on event_row.id = smartphone_row.event_id
      and event_row.exhibition_workflow_version = 2
      and event_row.deleted_at is null
    join public.exhibition_entries entry_row on entry_row.id = smartphone_row.entry_id
      and entry_row.member_id = member_uuid
      and entry_row.application_state = 'active'
    join public.exhibition_smartphone_workflow_cases case_row
      on case_row.smartphone_work_id = smartphone_row.id
    left join public.exhibition_smartphone_work_reviews review_row on review_row.id = case_row.source_review_id
    where smartphone_row.member_id = member_uuid
      and now() < case_row.individual_deadline
      and ((case_row.case_type = 'correction' and case_row.state = 'open' and smartphone_row.workflow_state = 'rejected')
        or (case_row.case_type = 'reedit' and case_row.state = 'permitted' and smartphone_row.workflow_state = 'reedit_editing'))
  )
  select rows.action_name, rows.event_id, rows.event_title_value, rows.target_kind, rows.target_uuid,
    rows.regular_work_uuid, rows.work_title_value, rows.smartphone_uuid, rows.smartphone_order,
    rows.problem_list, rows.action_reason, rows.action_deadline, rows.target_section,
    rows.action_priority, rows.action_occurred_at
  from action_rows rows
  order by rows.action_priority, rows.action_deadline nulls last, rows.action_occurred_at, rows.target_uuid;
end;
$$;

revoke all on function public.get_my_exhibition_required_actions_v1() from public, anon;
grant execute on function public.get_my_exhibition_required_actions_v1() to authenticated;
