-- Workflow v2 Draft rescue submission, proxy submission, and deadline protection.

create or replace function private.exhibition_work_edit_deadline_open(
  p_work public.exhibition_works,p_event public.events
)
returns boolean language sql stable security definer set search_path='' as $$
  select case
    when p_work.workflow_state in ('rejected','reedit_editing') then exists(
      select 1 from public.exhibition_workflow_cases case_row
      where case_row.work_id=p_work.id and case_row.state in ('open','permitted')
        and now()<case_row.individual_deadline
    )
    else now()<p_event.exhibition_work_submission_deadline
      or exists(select 1 from public.exhibition_entries entry_row where entry_row.id=p_work.entry_id
        and entry_row.application_state='active' and entry_row.revival_deadline is not null
        and now()<entry_row.revival_deadline)
      or (p_work.workflow_state='draft'
        and private.current_member_can_use_draft_rescue('regular_work',p_work.id))
  end
$$;

create or replace function private.exhibition_smartphone_edit_deadline_open(
  p_work public.exhibition_smartphone_works,p_event public.events
)
returns boolean language sql stable security definer set search_path='' as $$
  select case
    when p_work.workflow_state in ('rejected','reedit_editing') then exists(
      select 1 from public.exhibition_smartphone_workflow_cases case_row
      where case_row.smartphone_work_id=p_work.id and case_row.state in ('open','permitted')
        and now()<case_row.individual_deadline
    )
    else coalesce(private.exhibition_deadline_is_open(p_work.event_id,'work_submission'),false)
      or exists(select 1 from public.exhibition_entries entry_row where entry_row.id=p_work.entry_id
        and entry_row.application_state='active' and entry_row.revival_deadline is not null
        and now()<entry_row.revival_deadline)
      or (p_work.workflow_state='draft'
        and private.current_member_can_use_draft_rescue('smartphone_work',p_work.id))
  end
$$;

create or replace function private.exhibition_work_is_viable(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.exhibition_works work_row join public.events event_row on event_row.id=work_row.event_id
    where work_row.id=p_work_id and event_row.exhibition_workflow_version=2 and work_row.workflow_state<>'withdrawn' and (
      work_row.workflow_state in ('submitted','accepted','reedit_pending')
      or (work_row.workflow_state='draft' and (
        private.exhibition_work_edit_deadline_open(work_row,event_row)
        or private.exhibition_draft_rescue_protects_work('regular_work',work_row.id)))
      or (work_row.workflow_state in ('rejected','reedit_editing')
        and private.exhibition_work_edit_deadline_open(work_row,event_row))
    )
  )
$$;

create or replace function private.exhibition_smartphone_work_is_viable(p_work_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.exhibition_smartphone_works work_row join public.events event_row on event_row.id=work_row.event_id
    where work_row.id=p_work_id and work_row.workflow_state<>'withdrawn' and (
      work_row.workflow_state in ('submitted','accepted','reedit_pending')
      or (work_row.workflow_state='draft' and (
        private.exhibition_smartphone_edit_deadline_open(work_row,event_row)
        or private.exhibition_draft_rescue_protects_work('smartphone_work',work_row.id)))
      or (work_row.workflow_state in ('rejected','reedit_editing')
        and private.exhibition_smartphone_edit_deadline_open(work_row,event_row))
    )
  )
$$;

create or replace function private.consume_exhibition_draft_rescue_after_submit()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype;
  target_type_value text; work_id_value uuid; actor text:=private.current_email(); actor_type text;
begin
  if old.workflow_state<>'draft' or new.workflow_state<>'submitted' then return new; end if;
  target_type_value:=case when tg_table_name='exhibition_works' then 'regular_work' else 'smartphone_work' end;
  work_id_value:=new.id;

  if private.is_current_member() then
    select rescue_target.* into target_row
    from public.exhibition_draft_rescue_targets rescue_target
    join public.exhibition_draft_rescue_campaigns campaign_row on campaign_row.id=rescue_target.campaign_id
    join public.exhibition_draft_rescue_member_windows window_row on window_row.id=rescue_target.member_window_id
    where rescue_target.target_type=target_type_value and rescue_target.rescue_mode='member_resubmit'
      and rescue_target.state='authorized' and rescue_target.member_id=private.current_member_id()
      and ((target_type_value='regular_work' and rescue_target.regular_work_id=work_id_value)
        or (target_type_value='smartphone_work' and rescue_target.smartphone_work_id=work_id_value))
      and campaign_row.state='enabled' and now()<campaign_row.ends_at
      and window_row.state='active' and now()<window_row.deadline
    order by rescue_target.created_at desc,rescue_target.id limit 1;
    actor_type:='member';
  elsif private.is_exhibition_draft_rescue_operator() then
    select rescue_target.* into target_row
    from public.exhibition_draft_rescue_targets rescue_target
    join public.exhibition_draft_rescue_campaigns campaign_row on campaign_row.id=rescue_target.campaign_id
    where rescue_target.target_type=target_type_value and rescue_target.rescue_mode='admin_proxy_submit'
      and rescue_target.state='authorized' and rescue_target.member_intent_confirmed
      and ((target_type_value='regular_work' and rescue_target.regular_work_id=work_id_value)
        or (target_type_value='smartphone_work' and rescue_target.smartphone_work_id=work_id_value))
      and campaign_row.state='enabled' and now()<campaign_row.ends_at
    order by rescue_target.created_at desc,rescue_target.id limit 1;
    actor_type:='admin';
  end if;
  if target_row.id is null then return new; end if;

  update public.exhibition_draft_rescue_targets
  set state='consumed',consumed_at=now(),result_snapshot_id=new.current_submission_snapshot_id
  where id=target_row.id and state='authorized';
  if not found then raise exception '救済許可はすでに使用済みです。'; end if;
  insert into public.exhibition_draft_rescue_attempts(
    target_id,operator_identifier,operation_type,succeeded,result_snapshot_id
  ) values(target_row.id,actor,target_row.rescue_mode,true,new.current_submission_snapshot_id);
  perform private.write_exhibition_workflow_audit(
    target_row.event_id,'draft_rescue_target',target_row.id,'draft_rescue_target_consumed',actor_type,actor,
    target_row.reason,jsonb_build_object('state','authorized'),
    jsonb_build_object('state','consumed','snapshotId',new.current_submission_snapshot_id)
  );
  return new;
end;
$$;

create trigger exhibition_work_consume_draft_rescue_after_submit
after update of workflow_state,current_submission_snapshot_id on public.exhibition_works
for each row execute function private.consume_exhibition_draft_rescue_after_submit();
create trigger exhibition_smartphone_work_consume_draft_rescue_after_submit
after update of workflow_state,current_submission_snapshot_id on public.exhibition_smartphone_works
for each row execute function private.consume_exhibition_draft_rescue_after_submit();

create or replace function public.admin_proxy_submit_regular_draft_rescue_v1(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype; effective_row public.exhibition_draft_rescue_targets%rowtype;
  work_row public.exhibition_works%rowtype; snapshot_row public.exhibition_work_submission_snapshots%rowtype;
  batch_id uuid; next_version integer; actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の代理登録権限がありません。'; end if;
  select * into target_row from public.exhibition_draft_rescue_targets where id=p_target_id for update;
  if target_row.id is null or target_row.target_type<>'regular_work' or target_row.rescue_mode<>'admin_proxy_submit'
     or target_row.state<>'authorized' then raise exception '有効な通常作品代理登録Targetではありません。'; end if;
  select effective.* into effective_row from private.get_effective_exhibition_draft_rescue_target(
    'regular_work',target_row.regular_work_id,'admin_proxy_submit') effective;
  if effective_row.id is distinct from target_row.id then raise exception '通常作品の代理登録期限または許可が無効です。'; end if;
  select * into work_row from public.exhibition_works where id=target_row.regular_work_id for update;
  if work_row.workflow_state<>'draft' then raise exception '対象作品はDraftではありません。'; end if;
  perform private.validate_v2_work_values(work_row);
  select coalesce(max(snapshot.version_no),0)+1 into next_version
  from public.exhibition_work_submission_snapshots snapshot where snapshot.work_id=work_row.id;
  insert into public.exhibition_work_submission_batches(event_id,entry_id,member_id,submitted_by_identifier)
  values(work_row.event_id,work_row.entry_id,work_row.owner_member_id,actor) returning id into batch_id;
  insert into public.exhibition_work_submission_snapshots(
    batch_id,work_id,entry_id,event_id,member_id,version_no,original_image_path,original_sha256,title,
    orientation,print_size,print_size_detail,occupied_width_mm,occupied_height_mm,publication_consent,
    submitted_by_member_id,submitted_by_identifier
  ) values(
    batch_id,work_row.id,work_row.entry_id,work_row.event_id,work_row.owner_member_id,next_version,
    work_row.original_image_path,work_row.original_sha256,trim(work_row.title),work_row.orientation,
    work_row.print_size,work_row.print_size_detail,work_row.occupied_width_mm,work_row.occupied_height_mm,
    work_row.publication_consent,work_row.owner_member_id,actor
  ) returning * into snapshot_row;
  perform set_config('app.exhibition_work_rpc','on',true);
  update public.exhibition_works set workflow_state='submitted',status='submitted',
    current_submission_snapshot_id=snapshot_row.id,submitted_at=now(),updated_at=now()
  where id=work_row.id;
  if work_row.replacement_for_work_id is not null then
    update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now()
    where id=work_row.replacement_for_work_id;
  end if;
  perform set_config('app.exhibition_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(
    work_row.event_id,'work_submission_snapshot',snapshot_row.id,'work_proxy_submitted','admin',actor,
    target_row.reason,'{}',jsonb_build_object('workId',work_row.id,'batchId',batch_id,'versionNo',next_version,
      'memberConfirmedAt',target_row.member_confirmed_at)
  );
  return jsonb_build_object('targetId',target_row.id,'workId',work_row.id,'batchId',batch_id,
    'snapshotId',snapshot_row.id,'versionNo',next_version,'state','submitted');
end;
$$;

create or replace function public.admin_proxy_submit_smartphone_draft_rescue_v1(p_target_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target_row public.exhibition_draft_rescue_targets%rowtype; effective_row public.exhibition_draft_rescue_targets%rowtype;
  work_row public.exhibition_smartphone_works%rowtype; definition_row public.exhibition_smartphone_agreement_definitions%rowtype;
  snapshot_id uuid; next_version integer; actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の代理登録権限がありません。'; end if;
  select * into target_row from public.exhibition_draft_rescue_targets where id=p_target_id for update;
  if target_row.id is null or target_row.target_type<>'smartphone_work' or target_row.rescue_mode<>'admin_proxy_submit'
     or target_row.state<>'authorized' then raise exception '有効なスマホ作品代理登録Targetではありません。'; end if;
  select effective.* into effective_row from private.get_effective_exhibition_draft_rescue_target(
    'smartphone_work',target_row.smartphone_work_id,'admin_proxy_submit') effective;
  if effective_row.id is distinct from target_row.id then raise exception 'スマホ作品の代理登録期限または許可が無効です。'; end if;
  select * into work_row from public.exhibition_smartphone_works where id=target_row.smartphone_work_id for update;
  if work_row.workflow_state<>'draft' then raise exception '対象作品はDraftではありません。'; end if;
  if work_row.original_image_path is null or work_row.original_sha256 is null then raise exception '原画像とSHA-256 hashが必要です。'; end if;
  if split_part(work_row.original_image_path,'/',1)<>work_row.event_id::text
     or split_part(work_row.original_image_path,'/',2)<>work_row.member_id::text
     or split_part(work_row.original_image_path,'/',3)<>work_row.id::text
     or split_part(work_row.original_image_path,'/',4)='' or split_part(work_row.original_image_path,'/',5)<>'' then
    raise exception '原画像のStorage pathがこのスマホ作品に属していません。';
  end if;
  if not exists(select 1 from storage.objects object_row where object_row.bucket_id='exhibition-originals'
    and object_row.name=work_row.original_image_path) then raise exception '原画像がStorageに見つかりません。'; end if;
  if work_row.orientation not in ('portrait','landscape') or not work_row.smartphone_confirmed then
    raise exception '作品の向きとスマートフォン撮影確認が必要です。';
  end if;
  if work_row.ai_processing_declaration not in ('none','declared')
     or (work_row.ai_processing_declaration='declared' and trim(work_row.ai_processing_details)='') then
    raise exception 'AI生成・合成等の申告を正しく入力してください。';
  end if;
  select * into definition_row from public.exhibition_smartphone_agreement_definitions
  where id=target_row.smartphone_agreement_definition_id and active
    and content_hash=target_row.smartphone_agreement_content_hash;
  if definition_row.id is null or target_row.smartphone_agreed_at is null then
    raise exception '本人による現在有効なスマホ枠追加規約への同意記録が必要です。';
  end if;
  select coalesce(max(snapshot.version_no),0)+1 into next_version
  from public.exhibition_smartphone_work_submission_snapshots snapshot where snapshot.smartphone_work_id=work_row.id;
  insert into public.exhibition_smartphone_work_submission_snapshots(
    smartphone_work_id,event_id,entry_id,member_id,version_no,previous_snapshot_id,original_image_path,
    original_sha256,orientation,smartphone_confirmed,ai_processing_declaration,ai_processing_details,
    agreement_definition_id,agreement_version,agreement_reference,agreement_content_hash,agreed_at,
    submitted_by_identifier
  ) values(
    work_row.id,work_row.event_id,work_row.entry_id,work_row.member_id,next_version,
    work_row.current_submission_snapshot_id,work_row.original_image_path,work_row.original_sha256,
    work_row.orientation,true,work_row.ai_processing_declaration,work_row.ai_processing_details,
    definition_row.id,definition_row.version_no,definition_row.reference_key,definition_row.content_hash,
    target_row.smartphone_agreed_at,actor
  ) returning id into snapshot_id;
  perform set_config('app.exhibition_smartphone_work_rpc','on',true);
  update public.exhibition_smartphone_works set workflow_state='submitted',current_submission_snapshot_id=snapshot_id,
    submitted_at=now(),updated_at=now() where id=work_row.id;
  perform set_config('app.exhibition_smartphone_work_rpc','off',true);
  perform private.write_exhibition_workflow_audit(
    work_row.event_id,'smartphone_work_submission_snapshot',snapshot_id,'smartphone_proxy_submitted','admin',actor,
    target_row.reason,'{}',jsonb_build_object('smartphoneWorkId',work_row.id,'versionNo',next_version,
      'agreementVersion',definition_row.version_no,'agreementHash',definition_row.content_hash,
      'memberAgreedAt',target_row.smartphone_agreed_at,'memberConfirmedAt',target_row.member_confirmed_at)
  );
  return jsonb_build_object('targetId',target_row.id,'smartphoneWorkId',work_row.id,
    'snapshotId',snapshot_id,'versionNo',next_version,'state','submitted');
end;
$$;

create or replace function public.admin_process_exhibition_smartphone_deadlines_v1(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare work_row public.exhibition_smartphone_works%rowtype; withdrawn_count integer:=0; expired_count integer:=0;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  for work_row in select smartphone_row.* from public.exhibition_smartphone_works smartphone_row
    join public.events event_row on event_row.id=smartphone_row.event_id
    join public.exhibition_entries entry_row on entry_row.id=smartphone_row.entry_id
    where smartphone_row.event_id=p_event_id and smartphone_row.workflow_state='draft'
      and now()>=event_row.exhibition_work_submission_deadline
      and not (entry_row.application_state='active' and entry_row.revival_deadline is not null and now()<entry_row.revival_deadline)
      and not private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone_row.id)
    for update of smartphone_row
  loop
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now(),updated_at=now() where id=work_row.id;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    withdrawn_count:=withdrawn_count+1;
    perform private.write_exhibition_workflow_audit(work_row.event_id,'smartphone_work',work_row.id,
      'system_deadline_smartphone_withdrawn','system','system','work_submission_deadline','{}','{}');
    perform private.auto_cancel_v2_entry_if_no_viable(work_row.entry_id,'smartphone_deadline_no_viable_work');
  end loop;
  for work_row in select smartphone_row.* from public.exhibition_smartphone_works smartphone_row
    join public.exhibition_smartphone_workflow_cases case_row on case_row.smartphone_work_id=smartphone_row.id
    where smartphone_row.event_id=p_event_id and case_row.state in ('open','permitted')
      and case_row.individual_deadline<=now() for update of smartphone_row
  loop
    update public.exhibition_smartphone_workflow_cases set state='expired',closed_at=now()
      where smartphone_work_id=work_row.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now(),updated_at=now()
      where id=work_row.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    if found then
      expired_count:=expired_count+1;
      perform private.write_exhibition_workflow_audit(work_row.event_id,'smartphone_work',work_row.id,
        'system_smartphone_case_deadline_withdrawn','system','system','individual_deadline_expired','{}','{}');
      perform private.auto_cancel_v2_entry_if_no_viable(work_row.entry_id,'smartphone_case_deadline_no_viable_work');
    end if;
  end loop;
  return jsonb_build_object('draftSmartphoneWorksWithdrawn',withdrawn_count,'smartphoneCasesExpired',expired_count);
end;
$$;

-- The latest regular deadline processor is preserved, adding only per-Work rescue exclusions.
create or replace function public.admin_process_exhibition_work_deadlines_v2(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype; work_row public.exhibition_works%rowtype; entry_row public.exhibition_entries%rowtype;
  work_withdrawn integer:=0; entries_cancelled integer:=0; cases_expired integer:=0; first_processing boolean;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into event_row from public.events where id=p_event_id for update;
  if event_row.id is null or event_row.exhibition_workflow_version<>2 then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  if now()>=event_row.exhibition_work_submission_deadline then
    first_processing:=private.mark_exhibition_deadline_processed(p_event_id,'work_submission',
      event_row.exhibition_work_submission_deadline,jsonb_build_object('processor','admin_rpc'));
    for work_row in select candidate.* from public.exhibition_works candidate
      join public.exhibition_entries owner_entry on owner_entry.id=candidate.entry_id
      where candidate.event_id=p_event_id and candidate.workflow_state='draft'
        and not (owner_entry.revival_deadline is not null and now()<owner_entry.revival_deadline)
        and not private.exhibition_draft_rescue_protects_work('regular_work',candidate.id)
      for update of candidate
    loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=work_row.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'system_deadline_work_withdrawn',
        'system','system','work_submission_deadline','{}','{}');
    end loop;
    for entry_row in select entry_candidate.* from public.exhibition_entries entry_candidate
      where entry_candidate.event_id=p_event_id and entry_candidate.application_state='active'
        and not (entry_candidate.revival_deadline is not null and now()<entry_candidate.revival_deadline)
      for update of entry_candidate
    loop
      if private.auto_cancel_v2_entry_if_no_viable(entry_row.id,'zero_viable_work_at_submission_deadline') then
        entries_cancelled:=entries_cancelled+1;
      end if;
    end loop;
  end if;
  for work_row in select candidate.* from public.exhibition_works candidate
    join public.exhibition_workflow_cases case_row on case_row.work_id=candidate.id
    where candidate.event_id=p_event_id and case_row.state in ('open','permitted')
      and case_row.individual_deadline<=now() for update of candidate
  loop
    update public.exhibition_workflow_cases set state='expired',closed_at=now()
    where work_id=work_row.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_work_rpc','on',true);
    update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now()
    where id=work_row.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_work_rpc','off',true);
    if found then
      cases_expired:=cases_expired+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'system_case_deadline_withdrawn',
        'system','system','individual_deadline_expired','{}','{}');
      perform private.auto_cancel_v2_entry_if_no_viable(work_row.entry_id,'case_deadline_no_viable_work');
    end if;
  end loop;
  for entry_row in select entry_candidate.* from public.exhibition_entries entry_candidate
    where entry_candidate.event_id=p_event_id and entry_candidate.application_state='active'
      and entry_candidate.revival_deadline is not null and entry_candidate.revival_deadline<=now()
    for update of entry_candidate
  loop
    for work_row in select candidate.* from public.exhibition_works candidate
      where candidate.entry_id=entry_row.id and candidate.workflow_state='draft'
        and not private.exhibition_draft_rescue_protects_work('regular_work',candidate.id)
      for update of candidate
    loop
      perform set_config('app.exhibition_work_rpc','on',true);
      update public.exhibition_works set workflow_state='withdrawn',status='withdrawn',updated_at=now() where id=work_row.id;
      perform set_config('app.exhibition_work_rpc','off',true);
      work_withdrawn:=work_withdrawn+1;
      perform private.write_exhibition_workflow_audit(p_event_id,'work',work_row.id,'system_deadline_work_withdrawn',
        'system','system','revival_deadline','{}','{}');
    end loop;
    if private.auto_cancel_v2_entry_if_no_viable(entry_row.id,'revival_deadline_expired') then entries_cancelled:=entries_cancelled+1; end if;
  end loop;
  return jsonb_build_object('draftWorksWithdrawn',work_withdrawn,'casesExpired',cases_expired,
    'entriesAutoCancelled',entries_cancelled);
end;
$$;

revoke all on function public.admin_proxy_submit_regular_draft_rescue_v1(uuid),
  public.admin_proxy_submit_smartphone_draft_rescue_v1(uuid) from public,anon;
grant execute on function public.admin_proxy_submit_regular_draft_rescue_v1(uuid),
  public.admin_proxy_submit_smartphone_draft_rescue_v1(uuid) to authenticated;
revoke execute on function private.consume_exhibition_draft_rescue_after_submit() from public,anon,authenticated;
