-- Member-safe Draft rescue UI data. Management data remains behind the existing admin RPC.

create or replace function public.get_my_exhibition_draft_rescue_targets_v1(p_event_id uuid default null)
returns table(
  target_id uuid,event_id uuid,event_title text,target_type text,work_id uuid,
  work_title text,sort_order integer,deadline timestamptz,rescue_mode text,
  required_action_type text,section text,reason text
)
language plpgsql stable security definer set search_path='' as $$
declare member_uuid uuid:=private.current_member_id();
begin
  if member_uuid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  return query
  select target_row.id,target_row.event_id,event_row.title,target_row.target_type,
    case when target_row.target_type='regular_work' then target_row.regular_work_id else target_row.smartphone_work_id end,
    case when target_row.target_type='regular_work' then coalesce(regular_work.title,'') else '' end,
    coalesce(regular_work.sort_order,smartphone_work.sort_order),window_row.deadline,target_row.rescue_mode,
    case when target_row.target_type='regular_work' then 'regular_work_rescue_required' else 'smartphone_work_rescue_required' end,
    case when target_row.target_type='regular_work' then 'work' else 'smartphone' end,target_row.reason
  from public.exhibition_draft_rescue_targets target_row
  join public.exhibition_draft_rescue_campaigns campaign_row on campaign_row.id=target_row.campaign_id
  join public.exhibition_draft_rescue_member_windows window_row on window_row.id=target_row.member_window_id
  join public.events event_row on event_row.id=target_row.event_id and event_row.deleted_at is null
  left join public.exhibition_works regular_work on regular_work.id=target_row.regular_work_id
  left join public.exhibition_smartphone_works smartphone_work on smartphone_work.id=target_row.smartphone_work_id
  where target_row.member_id=member_uuid and target_row.rescue_mode='member_resubmit'
    and target_row.state='authorized' and campaign_row.state='enabled' and now()<campaign_row.ends_at
    and window_row.state='active' and now()<window_row.deadline
    and (p_event_id is null or target_row.event_id=p_event_id)
    and ((target_row.target_type='regular_work' and regular_work.owner_member_id=member_uuid and regular_work.workflow_state='draft')
      or (target_row.target_type='smartphone_work' and smartphone_work.member_id=member_uuid and smartphone_work.workflow_state='draft'))
  order by window_row.deadline,target_row.created_at,target_row.id;
end;
$$;

revoke all on function public.get_my_exhibition_draft_rescue_targets_v1(uuid) from public,anon;
grant execute on function public.get_my_exhibition_draft_rescue_targets_v1(uuid) to authenticated;
