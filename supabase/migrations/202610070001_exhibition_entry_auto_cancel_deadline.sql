-- Keep Workflow v2 Applications active while the global Work submission
-- window (or an entry-scoped admin revival window) is still open.  The
-- existing viability helpers remain authoritative for Regular/Smartphone
-- correction and re-edit paths.

create or replace function private.auto_cancel_v2_entry_if_no_viable(p_entry_id uuid,p_cause text)
returns boolean language plpgsql security definer set search_path='' as $$
declare
  target public.exhibition_entries%rowtype;
  target_event public.events%rowtype;
begin
  select * into target from public.exhibition_entries where id=p_entry_id for update;
  if target.id is null or target.application_state<>'active' then return false; end if;

  select * into target_event from public.events where id=target.event_id;
  if target_event.exhibition_workflow_version<>2 then return false; end if;

  -- A temporary zero-work state is valid until the submission deadline.
  if target_event.exhibition_work_submission_deadline is null
     or now()<target_event.exhibition_work_submission_deadline then
    return false;
  end if;

  -- An admin revival is an entry-scoped continuation of the submission
  -- window.  Its viable draft may not exist yet, so protect the window itself.
  if target.revival_deadline is not null and now()<target.revival_deadline then
    return false;
  end if;

  if exists(
       select 1 from public.exhibition_works work_row
       where work_row.entry_id=p_entry_id
         and private.exhibition_work_is_viable(work_row.id)
     )
     or exists(
       select 1 from public.exhibition_smartphone_works smartphone_row
       where smartphone_row.entry_id=p_entry_id
         and private.exhibition_smartphone_work_is_viable(smartphone_row.id)
     ) then
    return false;
  end if;

  perform set_config('app.exhibition_application_rpc','on',true);
  update public.exhibition_entries
  set application_state='auto_cancelled',status='withdrawn',
    work_auto_cancelled_at=now(),work_auto_cancel_cause=p_cause,application_updated_at=now()
  where id=p_entry_id;
  perform set_config('app.exhibition_application_rpc','off',true);

  perform private.write_exhibition_workflow_audit(
    target.event_id,'application',target.id,'entry_auto_cancelled','system','system',p_cause,
    jsonb_build_object('applicationState','active'),
    jsonb_build_object('applicationState','auto_cancelled')
  );
  return true;
end;
$$;

-- Re-evaluate every active Entry when the global deadline processor runs.
-- Restricting this to Entries without any historical Submission Snapshot left
-- submitted-then-withdrawn Entries active forever after the deadline.
create or replace function public.admin_process_exhibition_work_deadlines_v2(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  event_row public.events%rowtype;
  work_row public.exhibition_works%rowtype;
  entry_row public.exhibition_entries%rowtype;
  work_withdrawn integer:=0;
  entries_cancelled integer:=0;
  cases_expired integer:=0;
  first_processing boolean;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then
    raise exception '管理者またはSYSTEM実行権限がありません。';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into event_row from public.events where id=p_event_id for update;
  if event_row.id is null or event_row.exhibition_workflow_version<>2 then
    raise exception 'Workflow v2写真展が見つかりません。';
  end if;

  if now()>=event_row.exhibition_work_submission_deadline then
    first_processing:=private.mark_exhibition_deadline_processed(
      p_event_id,'work_submission',event_row.exhibition_work_submission_deadline,
      jsonb_build_object('processor','admin_rpc')
    );
    for work_row in
      select candidate.*
      from public.exhibition_works candidate
      join public.exhibition_entries owner_entry on owner_entry.id=candidate.entry_id
      where candidate.event_id=p_event_id and candidate.workflow_state='draft'
        and not (owner_entry.revival_deadline is not null and now()<owner_entry.revival_deadline)
      for update of candidate
    loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works
      set workflow_state='withdrawn',status='withdrawn',updated_at=now()
      where id=work_row.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(
        p_event_id,'work',work_row.id,'system_deadline_work_withdrawn',
        'system','system','work_submission_deadline','{}','{}'
      );
    end loop;

    for entry_row in
      select entry_candidate.*
      from public.exhibition_entries entry_candidate
      where entry_candidate.event_id=p_event_id
        and entry_candidate.application_state='active'
        and not (entry_candidate.revival_deadline is not null and now()<entry_candidate.revival_deadline)
      for update of entry_candidate
    loop
      if private.auto_cancel_v2_entry_if_no_viable(
        entry_row.id,'zero_viable_work_at_submission_deadline'
      ) then
        entries_cancelled:=entries_cancelled+1;
      end if;
    end loop;
  end if;

  for work_row in
    select candidate.*
    from public.exhibition_works candidate
    join public.exhibition_workflow_cases case_row on case_row.work_id=candidate.id
    where candidate.event_id=p_event_id
      and case_row.state in ('open','permitted')
      and case_row.individual_deadline<=now()
    for update of candidate
  loop
    update public.exhibition_workflow_cases
    set state='expired',closed_at=now()
    where work_id=work_row.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works
    set workflow_state='withdrawn',status='withdrawn',updated_at=now()
    where id=work_row.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_work_rpc','off',true);
    if found then
      cases_expired:=cases_expired+1;
      perform private.write_exhibition_workflow_audit(
        p_event_id,'work',work_row.id,'system_case_deadline_withdrawn',
        'system','system','individual_deadline_expired','{}','{}'
      );
      perform private.auto_cancel_v2_entry_if_no_viable(
        work_row.entry_id,'case_deadline_no_viable_work'
      );
    end if;
  end loop;

  for entry_row in
    select entry_candidate.*
    from public.exhibition_entries entry_candidate
    where entry_candidate.event_id=p_event_id
      and entry_candidate.application_state='active'
      and entry_candidate.revival_deadline is not null
      and entry_candidate.revival_deadline<=now()
    for update of entry_candidate
  loop
    for work_row in
      select candidate.* from public.exhibition_works candidate
      where candidate.entry_id=entry_row.id and candidate.workflow_state='draft'
      for update of candidate
    loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works
      set workflow_state='withdrawn',status='withdrawn',updated_at=now()
      where id=work_row.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(
        p_event_id,'work',work_row.id,'system_deadline_work_withdrawn',
        'system','system','revival_deadline','{}','{}'
      );
    end loop;
    if private.auto_cancel_v2_entry_if_no_viable(entry_row.id,'revival_deadline_expired') then
      entries_cancelled:=entries_cancelled+1;
      perform private.write_exhibition_workflow_audit(
        p_event_id,'application',entry_row.id,'entry_revival_expired',
        'system','system','revival_deadline_expired','{}','{}'
      );
    end if;
  end loop;

  return jsonb_build_object(
    'draftWorksWithdrawn',work_withdrawn,
    'casesExpired',cases_expired,
    'entriesAutoCancelled',entries_cancelled
  );
end;
$$;

revoke execute on function private.auto_cancel_v2_entry_if_no_viable(uuid,text)
  from public,anon,authenticated;

