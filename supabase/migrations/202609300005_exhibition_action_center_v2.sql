-- 写真展Workflow v2 Phase 5: snapshot consistency / Action Center / SYSTEM orchestration。

alter table public.exhibition_caption_submission_snapshots
  add column if not exists work_submission_snapshot_id uuid
    references public.exhibition_work_submission_snapshots(id) on delete restrict;
create index if not exists exhibition_caption_snapshots_work_snapshot_idx
  on public.exhibition_caption_submission_snapshots(work_submission_snapshot_id);

-- Phase 5適用前のCaption履歴は推測backfillしない。以後の正式提出だけ正確なWork Snapshotへ固定する。
create or replace function private.bind_caption_to_current_work_snapshot_v2()
returns trigger language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; source public.exhibition_work_submission_snapshots%rowtype;
begin
  select * into w from public.exhibition_works where id=new.work_id;
  if w.current_accepted_snapshot_id is null or w.workflow_state<>'accepted' then
    raise exception '現在確認済みのWork Submission Snapshotが必要です。';
  end if;
  select * into source from public.exhibition_work_submission_snapshots where id=w.current_accepted_snapshot_id;
  if source.id is null or source.work_id<>new.work_id or source.event_id<>new.event_id
     or source.entry_id<>new.entry_id or source.member_id<>new.member_id then
    raise exception 'Work Submission SnapshotとCaptionの所有関係が一致しません。';
  end if;
  if new.work_submission_snapshot_id is not null and new.work_submission_snapshot_id<>source.id then
    raise exception 'Captionの基準Work Snapshotを任意に指定できません。';
  end if;
  new.work_submission_snapshot_id:=source.id;
  return new;
end;
$$;
create trigger exhibition_caption_bind_work_snapshot_before_insert
before insert on public.exhibition_caption_submission_snapshots
for each row execute function private.bind_caption_to_current_work_snapshot_v2();

create or replace function private.caption_pair_is_current_v2(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select w.current_accepted_snapshot_id is not null
    and c.current_accepted_snapshot_id is not null
    and s.work_submission_snapshot_id=w.current_accepted_snapshot_id
  from public.exhibition_works w
  left join public.exhibition_caption_working_data c on c.work_id=w.id
  left join public.exhibition_caption_submission_snapshots s on s.id=c.current_accepted_snapshot_id
  where w.id=p_work_id and w.workflow_state='accepted'
$$;

create or replace function public.start_stale_exhibition_caption_resubmission_v2(p_work_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_works%rowtype; c public.exhibition_caption_working_data%rowtype; actor text:=private.current_email();
begin
  select * into w from public.exhibition_works where id=p_work_id and owner_member_id=private.current_member_id() for update;
  select * into c from public.exhibition_caption_working_data where work_id=w.id for update;
  if w.id is null or w.workflow_state<>'accepted' or c.current_accepted_snapshot_id is null
     or coalesce(private.caption_pair_is_current_v2(w.id),false) then
    raise exception '現在のWorkに対する再確認が必要なCaptionではありません。';
  end if;
  if not coalesce(private.exhibition_deadline_is_open(w.event_id,'caption'),false) then raise exception 'Caption締切を過ぎています。'; end if;
  if exists(select 1 from public.exhibition_caption_workflow_cases where work_id=w.id and state in ('pending','open','permitted')) then
    raise exception '未完了のCaption Caseがあります。';
  end if;
  update public.exhibition_caption_working_data set state='draft',updated_at=now() where work_id=w.id;
  perform private.write_exhibition_workflow_audit(w.event_id,'caption_working_data',w.id,'stale_caption_resubmission_started',
    'member',actor,'current_work_snapshot_changed',jsonb_build_object('acceptedCaptionSnapshotId',c.current_accepted_snapshot_id),
    jsonb_build_object('currentWorkSnapshotId',w.current_accepted_snapshot_id));
  return jsonb_build_object('workId',w.id,'state','draft','workSnapshotId',w.current_accepted_snapshot_id);
end;
$$;

create or replace function public.admin_get_exhibition_action_center_v2(p_event_id uuid default null)
returns table(
  priority integer,category text,action_type text,event_id uuid,event_title text,entry_id uuid,work_id uuid,
  member_id uuid,member_name text,snapshot_id uuid,case_id uuid,relevant_deadline timestamptz,
  workflow_state text,occurred_at timestamptz,reason text,context jsonb
)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  return query
  with base as (
    select w.*,e.title event_title,e.exhibition_caption_deadline,en.id entry_uuid,m.name member_name_value
    from public.exhibition_works w join public.events e on e.id=w.event_id and e.exhibition_workflow_version=2
    join public.exhibition_entries en on en.id=w.entry_id join public.members m on m.id=w.owner_member_id
    where (p_event_id is null or e.id=p_event_id) and w.workflow_state<>'withdrawn'
  ), actions(p,c,a,event_id,event_title,entry_uuid,id,owner_member_id,member_name_value,snapshot_id,case_id,relevant_deadline,workflow_state,occurred_at,reason,x) as (
    select 10 p,'review_required' c,'work_review' a,b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      b.current_submission_snapshot_id,null::uuid,null::timestamptz,b.workflow_state,b.submitted_at,''::text,
      jsonb_build_object('label','Workの確認が必要です') x from base b where b.workflow_state='submitted'
    union all
    select 5,'deadline_attention','application_exception',e.id,e.title,en.id,null::uuid,en.member_id,m.name,
      en.current_application_snapshot_id,null::uuid,en.revival_deadline,en.application_state,en.work_auto_cancelled_at,
      coalesce(en.work_auto_cancel_cause,'自動取消'),jsonb_build_object('label','Applicationが自動取消されています。必要に応じて救済判断をしてください')
      from public.exhibition_entries en join public.events e on e.id=en.event_id and e.exhibition_workflow_version=2
      join public.members m on m.id=en.member_id
      where en.application_state='auto_cancelled' and (p_event_id is null or e.id=p_event_id)
    union all
    select 20,'decision_required','work_reedit_decision',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      wc.source_submission_snapshot_id,wc.id,wc.individual_deadline,b.workflow_state,wc.requested_at,wc.request_reason,
      jsonb_build_object('label','Work再編集申請の判断が必要です') from base b join public.exhibition_workflow_cases wc on wc.work_id=b.id where wc.case_type='reedit' and wc.state='pending'
    union all
    select 50,'member_action_pending',case when wc.case_type='correction' then 'work_correction_pending' else 'work_reedit_resubmission_pending' end,
      b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,wc.source_submission_snapshot_id,wc.id,wc.individual_deadline,
      b.workflow_state,wc.decided_at,coalesce(wc.decision_reason,wc.request_reason),jsonb_build_object('label','部員のWork修正・再提出待ち')
      from base b join public.exhibition_workflow_cases wc on wc.work_id=b.id where wc.state in ('open','permitted')
    union all
    select 5,'deadline_attention','work_case_due',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      wc.source_submission_snapshot_id,wc.id,wc.individual_deadline,b.workflow_state,wc.requested_at,'個別期限到達',jsonb_build_object('label','Work期限処理が必要です')
      from base b join public.exhibition_workflow_cases wc on wc.work_id=b.id where wc.state in ('open','permitted') and wc.individual_deadline<=now()
    union all
    select 30,'member_action_pending',case when c.current_accepted_snapshot_id is null then 'caption_missing' else 'caption_stale' end,
      b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,c.current_accepted_snapshot_id,null::uuid,b.exhibition_caption_deadline,
      coalesce(c.state,'not_started'),coalesce(c.updated_at,b.updated_at),case when c.current_accepted_snapshot_id is null then 'Caption未提出・未確認' else '現在のWork Snapshotに対応するCaptionがありません' end,
      jsonb_build_object('label',case when c.current_accepted_snapshot_id is null then 'Caption提出待ち' else 'Captionは履歴として有効ですが、現在のWorkに対して古くなっています' end,
        'currentWorkSnapshotId',b.current_accepted_snapshot_id,'acceptedCaptionSnapshotId',c.current_accepted_snapshot_id)
      from base b left join public.exhibition_caption_working_data c on c.work_id=b.id
      left join public.exhibition_caption_submission_snapshots cs on cs.id=c.current_accepted_snapshot_id
      left join public.exhibition_caption_submission_snapshots submitted_cs on submitted_cs.id=c.current_submission_snapshot_id
      where b.workflow_state='accepted' and (
        (c.current_accepted_snapshot_id is null and c.current_submission_snapshot_id is null)
        or (c.current_accepted_snapshot_id is not null
          and cs.work_submission_snapshot_id is distinct from b.current_accepted_snapshot_id
          and submitted_cs.work_submission_snapshot_id is distinct from b.current_accepted_snapshot_id)
      )
    union all
    select 10,'review_required','caption_review',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      c.current_submission_snapshot_id,null::uuid,b.exhibition_caption_deadline,c.state,c.updated_at,'',jsonb_build_object('label','Captionの確認が必要です')
      from base b join public.exhibition_caption_working_data c on c.work_id=b.id where c.state='submitted'
    union all
    select 20,'decision_required','caption_reedit_decision',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      cc.source_caption_snapshot_id,cc.id,cc.individual_deadline,c.state,cc.requested_at,cc.request_reason,jsonb_build_object('label','Caption再編集申請の判断が必要です')
      from base b join public.exhibition_caption_working_data c on c.work_id=b.id join public.exhibition_caption_workflow_cases cc on cc.work_id=b.id
      where cc.case_type='reedit' and cc.state='pending'
    union all
    select 50,'member_action_pending',case when cc.case_type='correction' then 'caption_correction_pending' else 'caption_reedit_resubmission_pending' end,
      b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,cc.source_caption_snapshot_id,cc.id,cc.individual_deadline,
      c.state,cc.decided_at,coalesce(cc.decision_reason,cc.request_reason),jsonb_build_object('label','部員のCaption修正・再提出待ち')
      from base b join public.exhibition_caption_working_data c on c.work_id=b.id join public.exhibition_caption_workflow_cases cc on cc.work_id=b.id
      where cc.state in ('open','permitted')
    union all
    select 5,'deadline_attention','caption_case_due',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      cc.source_caption_snapshot_id,cc.id,cc.individual_deadline,c.state,cc.requested_at,'個別期限到達',jsonb_build_object('label','Caption期限処理が必要です')
      from base b join public.exhibition_caption_working_data c on c.work_id=b.id join public.exhibition_caption_workflow_cases cc on cc.work_id=b.id
      where cc.state in ('open','permitted') and cc.individual_deadline<=now()
    union all
    select 40,'organizer_task','organizer_english_title',b.event_id,b.event_title,b.entry_uuid,b.id,b.owner_member_id,b.member_name_value,
      c.current_accepted_snapshot_id,null::uuid,null::timestamptz,c.state,cs.submitted_at,'主催者英語作品名が未作成',jsonb_build_object('label','主催者英語作品名を作成してください')
      from base b join public.exhibition_caption_working_data c on c.work_id=b.id
      join public.exhibition_caption_submission_snapshots cs on cs.id=c.current_accepted_snapshot_id
      where c.state='accepted' and cs.work_submission_snapshot_id=b.current_accepted_snapshot_id and cs.english_title_mode='organizer'
        and not exists(select 1 from public.exhibition_caption_english_title_derivations d where d.source_caption_snapshot_id=cs.id)
  )
  select a.p,a.c,a.a,a.event_id,a.event_title,a.entry_uuid,a.id,a.owner_member_id,a.member_name_value,
    a.snapshot_id,a.case_id,a.relevant_deadline,a.workflow_state,a.occurred_at,a.reason,a.x
  from actions a order by a.p,a.occurred_at nulls last;
end;
$$;

create or replace function public.admin_process_due_exhibition_workflows_v2(p_event_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; work_result jsonb; caption_result jsonb; results jsonb:='[]'; actor_type text; actor text;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  actor_type:=case when coalesce(auth.role()::text,'')='service_role' then 'system' else 'admin' end;
  actor:=case when actor_type='system' then 'system' else private.current_email() end;
  for e in select event.* from public.events event
    where event.exhibition_workflow_version=2 and event.deleted_at is null
      and (p_event_id is null or event.id=p_event_id)
    order by event.id
  loop
    perform pg_advisory_xact_lock(hashtextextended(e.id::text,0));
    work_result:=public.admin_process_exhibition_work_deadlines_v2(e.id);
    caption_result:=public.admin_process_exhibition_caption_deadlines_v2(e.id);
    results:=results||jsonb_build_array(jsonb_build_object('eventId',e.id,'work',work_result,'caption',caption_result));
  end loop;
  return jsonb_build_object('processedAt',now(),'actorType',actor_type,'actor',actor,'events',results);
end;
$$;

revoke all on function private.bind_caption_to_current_work_snapshot_v2(),private.caption_pair_is_current_v2(uuid) from public,anon,authenticated;
revoke all on function public.start_stale_exhibition_caption_resubmission_v2(uuid),
  public.admin_get_exhibition_action_center_v2(uuid),public.admin_process_due_exhibition_workflows_v2(uuid) from public,anon;
grant execute on function public.start_stale_exhibition_caption_resubmission_v2(uuid),
  public.admin_get_exhibition_action_center_v2(uuid),public.admin_process_due_exhibition_workflows_v2(uuid) to authenticated;
grant execute on function public.admin_process_due_exhibition_workflows_v2(uuid) to service_role;
