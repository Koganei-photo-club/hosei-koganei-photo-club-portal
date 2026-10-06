-- Align Smartphone Work deadline handling with the existing regular Work
-- admin-revival semantics. Event deadlines remain unchanged; the exception is
-- scoped to one active Entry and is open only while now() < revival_deadline.

create or replace function private.exhibition_smartphone_edit_deadline_open(
  p_work public.exhibition_smartphone_works,
  p_event public.events
)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select case
    when p_work.workflow_state in ('rejected','reedit_editing') then exists(
      select 1
      from public.exhibition_smartphone_workflow_cases case_row
      where case_row.smartphone_work_id=p_work.id
        and case_row.state in ('open','permitted')
        and now()<case_row.individual_deadline
    )
    else coalesce(private.exhibition_deadline_is_open(p_work.event_id,'work_submission'),false)
      or exists(
        select 1
        from public.exhibition_entries entry_row
        where entry_row.id=p_work.entry_id
          and entry_row.application_state='active'
          and entry_row.revival_deadline is not null
          and now()<entry_row.revival_deadline
      )
  end
$$;

create or replace function public.save_exhibition_smartphone_work_draft_v1(
  p_event_id uuid,p_smartphone_work_id uuid,p_orientation text,p_smartphone_confirmed boolean,
  p_ai_processing_declaration text,p_ai_processing_details text,p_original_image_path text,p_original_sha256 text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; en public.exhibition_entries%rowtype; w public.exhibition_smartphone_works%rowtype;
  mid uuid:=private.current_member_id(); next_slot integer; active_count integer; actor text:=private.current_email();
begin
  if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_event_id::text,0));
  select * into e from public.events where id=p_event_id for update;
  select * into en from public.exhibition_entries where event_id=p_event_id and member_id=mid for update;
  if e.exhibition_workflow_version<>2 or not e.smartphone_exhibition_enabled or e.max_smartphone_works<1
     or en.application_state<>'active' then raise exception 'この写真展で利用可能なスマホ枠Applicationがありません。'; end if;
  if p_smartphone_work_id is null then
    if not coalesce(private.exhibition_deadline_is_open(p_event_id,'work_submission'),false)
       and not (en.revival_deadline is not null and now()<en.revival_deadline) then
      raise exception '作品提出締切を過ぎています。';
    end if;
    select count(*) into active_count from public.exhibition_smartphone_works sw where sw.entry_id=en.id and sw.workflow_state<>'withdrawn';
    if active_count>=e.max_smartphone_works then raise exception 'スマホ枠の出展可能作品数を超えています。'; end if;
    select coalesce(max(sw.sort_order),0)+1 into next_slot from public.exhibition_smartphone_works sw where sw.entry_id=en.id;
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    insert into public.exhibition_smartphone_works(event_id,entry_id,member_id,sort_order,orientation,smartphone_confirmed,
      ai_processing_declaration,ai_processing_details,original_image_path,original_sha256)
    values(p_event_id,en.id,mid,next_slot,nullif(p_orientation,''),coalesce(p_smartphone_confirmed,false),
      nullif(p_ai_processing_declaration,''),trim(coalesce(p_ai_processing_details,'')),p_original_image_path,lower(p_original_sha256)) returning * into w;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_work',w.id,'smartphone_draft_created','member',actor,'','{}',jsonb_build_object('sortOrder',w.sort_order));
  else
    select * into w from public.exhibition_smartphone_works where id=p_smartphone_work_id and event_id=p_event_id and member_id=mid for update;
    if w.id is null or w.workflow_state not in ('draft','rejected','reedit_editing') then raise exception '編集可能なスマホ作品ではありません。'; end if;
    if not private.exhibition_smartphone_edit_deadline_open(w,e) then raise exception '編集期限を過ぎています。'; end if;
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set orientation=nullif(p_orientation,''),smartphone_confirmed=coalesce(p_smartphone_confirmed,false),
      ai_processing_declaration=nullif(p_ai_processing_declaration,''),ai_processing_details=trim(coalesce(p_ai_processing_details,'')),
      original_image_path=p_original_image_path,original_sha256=lower(p_original_sha256) where id=w.id returning * into w;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    perform private.write_exhibition_workflow_audit(p_event_id,'smartphone_work',w.id,'smartphone_draft_updated','member',actor,'','{}',jsonb_build_object('state',w.workflow_state));
  end if;
  return to_jsonb(w);
end;
$$;

create or replace function public.admin_process_exhibition_smartphone_deadlines_v1(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.exhibition_smartphone_works%rowtype; withdrawn_count integer:=0; expired_count integer:=0;
begin
  if not private.is_admin() and coalesce(auth.role()::text,'')<>'service_role' then raise exception '管理者またはSYSTEM実行権限がありません。'; end if;
  for w in
    select smartphone_row.*
    from public.exhibition_smartphone_works smartphone_row
    join public.events event_row on event_row.id=smartphone_row.event_id
    join public.exhibition_entries entry_row on entry_row.id=smartphone_row.entry_id
    where smartphone_row.event_id=p_event_id
      and smartphone_row.workflow_state='draft'
      and now()>=event_row.exhibition_work_submission_deadline
      and not (entry_row.application_state='active' and entry_row.revival_deadline is not null and now()<entry_row.revival_deadline)
    for update of smartphone_row
  loop
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now() where id=w.id;
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    withdrawn_count:=withdrawn_count+1;
    perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,'system_deadline_smartphone_withdrawn','system','system',
      case when exists(select 1 from public.exhibition_entries entry_row where entry_row.id=w.entry_id and entry_row.revival_deadline is not null)
        then 'revival_deadline' else 'work_submission_deadline' end,'{}','{}');
    perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'smartphone_deadline_no_viable_work');
  end loop;
  for w in
    select smartphone_row.* from public.exhibition_smartphone_works smartphone_row
    join public.exhibition_smartphone_workflow_cases case_row on case_row.smartphone_work_id=smartphone_row.id
    where smartphone_row.event_id=p_event_id and case_row.state in ('open','permitted') and case_row.individual_deadline<=now()
    for update of smartphone_row
  loop
    update public.exhibition_smartphone_workflow_cases set state='expired',closed_at=now()
      where smartphone_work_id=w.id and state in ('open','permitted') and individual_deadline<=now();
    perform set_config('app.exhibition_smartphone_work_rpc','on',true);
    update public.exhibition_smartphone_works set workflow_state='withdrawn',withdrawn_at=now()
      where id=w.id and workflow_state in ('rejected','reedit_editing');
    perform set_config('app.exhibition_smartphone_work_rpc','off',true);
    if found then
      expired_count:=expired_count+1;
      perform private.write_exhibition_workflow_audit(w.event_id,'smartphone_work',w.id,
        'system_smartphone_case_deadline_withdrawn','system','system','individual_deadline_expired','{}','{}');
      perform private.auto_cancel_v2_entry_if_no_viable(w.entry_id,'smartphone_case_deadline_no_viable_work');
    end if;
  end loop;
  return jsonb_build_object('draftSmartphoneWorksWithdrawn',withdrawn_count,'smartphoneCasesExpired',expired_count);
end;
$$;

revoke all on function public.save_exhibition_smartphone_work_draft_v1(uuid,uuid,text,boolean,text,text,text,text) from public,anon;
revoke all on function public.admin_process_exhibition_smartphone_deadlines_v1(uuid) from public,anon;
grant execute on function public.save_exhibition_smartphone_work_draft_v1(uuid,uuid,text,boolean,text,text,text,text) to authenticated;
grant execute on function public.admin_process_exhibition_smartphone_deadlines_v1(uuid) to authenticated,service_role;
revoke execute on function private.exhibition_smartphone_edit_deadline_open(public.exhibition_smartphone_works,public.events) from public,anon,authenticated;
