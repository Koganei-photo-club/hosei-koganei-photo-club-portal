-- Workflow v2 Draft rescue management RPCs.
-- Submission/resubmission execution is intentionally not enabled here.

create or replace function public.admin_create_exhibition_draft_rescue_campaign_v1(
  p_event_id uuid,p_ends_at timestamptz,p_reason text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare event_row public.events%rowtype; campaign_row public.exhibition_draft_rescue_campaigns%rowtype;
  actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  select * into event_row from public.events where id=p_event_id and genre='exhibition' and exhibition_workflow_version=2 for update;
  if event_row.id is null then raise exception 'Workflow v2写真展が見つかりません。'; end if;
  if p_ends_at is null or p_ends_at<=now() then raise exception '救済キャンペーン終了日時は未来に設定してください。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '救済キャンペーンの理由は必須です。'; end if;
  insert into public.exhibition_draft_rescue_campaigns(event_id,state,ends_at,reason,created_by_identifier)
  values(p_event_id,'enabled',p_ends_at,trim(p_reason),actor) returning * into campaign_row;
  perform private.write_exhibition_workflow_audit(p_event_id,'draft_rescue_campaign',campaign_row.id,
    'draft_rescue_campaign_created','admin',actor,p_reason,'{}',to_jsonb(campaign_row));
  return to_jsonb(campaign_row);
end;$$;

create or replace function public.admin_set_exhibition_draft_rescue_campaign_state_v1(
  p_campaign_id uuid,p_state text,p_reason text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old_row public.exhibition_draft_rescue_campaigns%rowtype; new_row public.exhibition_draft_rescue_campaigns%rowtype;
  actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  if p_state not in ('enabled','disabled','completed') then raise exception 'キャンペーン状態が不正です。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '状態変更理由は必須です。'; end if;
  select * into old_row from public.exhibition_draft_rescue_campaigns where id=p_campaign_id for update;
  if old_row.id is null then raise exception '救済キャンペーンが見つかりません。'; end if;
  if old_row.state='completed' and p_state<>'completed' then raise exception '完了済みキャンペーンは再開できません。'; end if;
  if p_state='enabled' and now()>=old_row.ends_at then raise exception '終了日時を過ぎたキャンペーンは有効化できません。'; end if;
  update public.exhibition_draft_rescue_campaigns set state=p_state,
    disabled_by_identifier=case when p_state='enabled' then null else actor end,
    disabled_at=case when p_state='enabled' then null else now() end,updated_at=now()
  where id=old_row.id returning * into new_row;
  perform private.write_exhibition_workflow_audit(old_row.event_id,'draft_rescue_campaign',old_row.id,
    'draft_rescue_campaign_state_changed','admin',actor,p_reason,to_jsonb(old_row),to_jsonb(new_row));
  return to_jsonb(new_row);
end;$$;

create or replace function public.admin_set_exhibition_draft_rescue_member_window_v1(
  p_campaign_id uuid,p_member_id uuid,p_deadline timestamptz,p_reason text
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare campaign_row public.exhibition_draft_rescue_campaigns%rowtype; member_row public.members%rowtype;
  old_row public.exhibition_draft_rescue_member_windows%rowtype; new_row public.exhibition_draft_rescue_member_windows%rowtype;
  actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  select * into campaign_row from public.exhibition_draft_rescue_campaigns where id=p_campaign_id for update;
  if campaign_row.id is null or campaign_row.state<>'enabled' or now()>=campaign_row.ends_at then raise exception '有効な救済キャンペーンがありません。'; end if;
  select * into member_row from public.members where id=p_member_id and active;
  if member_row.id is null then raise exception '有効な部員が見つかりません。'; end if;
  if p_deadline is null or p_deadline<=now() or p_deadline>campaign_row.ends_at then raise exception '部員期限は現在より後、キャンペーン終了以前に設定してください。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '期限設定理由は必須です。'; end if;
  select * into old_row from public.exhibition_draft_rescue_member_windows
  where campaign_id=p_campaign_id and member_id=p_member_id and state='active' for update;
  if old_row.id is null then
    insert into public.exhibition_draft_rescue_member_windows(campaign_id,event_id,member_id,deadline,state,reason,created_by_identifier,updated_by_identifier)
    values(campaign_row.id,campaign_row.event_id,p_member_id,p_deadline,'active',trim(p_reason),actor,actor) returning * into new_row;
  else
    update public.exhibition_draft_rescue_member_windows set deadline=p_deadline,reason=trim(p_reason),updated_by_identifier=actor,updated_at=now()
    where id=old_row.id returning * into new_row;
  end if;
  perform private.write_exhibition_workflow_audit(campaign_row.event_id,'draft_rescue_member_window',new_row.id,
    case when old_row.id is null then 'draft_rescue_member_window_created' else 'draft_rescue_member_window_updated' end,
    'admin',actor,p_reason,case when old_row.id is null then '{}'::jsonb else to_jsonb(old_row) end,to_jsonb(new_row));
  return to_jsonb(new_row);
end;$$;

create or replace function public.admin_authorize_exhibition_draft_rescue_target_v1(
  p_campaign_id uuid,p_target_type text,p_work_id uuid,p_rescue_mode text,p_reason text,
  p_member_intent_confirmed boolean default false,p_member_confirmation_method text default null,
  p_member_confirmed_at timestamptz default null,p_smartphone_agreement_definition_id uuid default null,
  p_smartphone_agreement_content_hash text default null,p_smartphone_agreed_at timestamptz default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare campaign_row public.exhibition_draft_rescue_campaigns%rowtype; window_row public.exhibition_draft_rescue_member_windows%rowtype;
  target_row public.exhibition_draft_rescue_targets%rowtype; prior_row public.exhibition_draft_rescue_targets%rowtype;
  event_id_value uuid; member_id_value uuid; work_state text; application_state_value text;
  definition_row public.exhibition_smartphone_agreement_definitions%rowtype; actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  if p_target_type not in ('regular_work','smartphone_work') or p_rescue_mode not in ('member_resubmit','admin_proxy_submit') then raise exception '救済対象または救済方式が不正です。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '救済許可の理由は必須です。'; end if;
  select * into campaign_row from public.exhibition_draft_rescue_campaigns where id=p_campaign_id for update;
  if campaign_row.id is null or campaign_row.state<>'enabled' or now()>=campaign_row.ends_at then raise exception '有効な救済キャンペーンがありません。'; end if;
  if p_target_type='regular_work' then
    select work_row.event_id,work_row.owner_member_id,work_row.workflow_state,entry_row.application_state
    into event_id_value,member_id_value,work_state,application_state_value
    from public.exhibition_works work_row join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
    where work_row.id=p_work_id for update of work_row;
  else
    select work_row.event_id,work_row.member_id,work_row.workflow_state,entry_row.application_state
    into event_id_value,member_id_value,work_state,application_state_value
    from public.exhibition_smartphone_works work_row join public.exhibition_entries entry_row on entry_row.id=work_row.entry_id
    where work_row.id=p_work_id for update of work_row;
  end if;
  if event_id_value is null or event_id_value<>campaign_row.event_id then raise exception '救済対象作品がキャンペーンと一致しません。'; end if;
  if work_state<>'draft' or application_state_value<>'active' then raise exception '現在DraftかつApplication有効な作品だけを指定できます。'; end if;
  if p_rescue_mode='member_resubmit' then
    select * into window_row from public.exhibition_draft_rescue_member_windows
    where campaign_id=campaign_row.id and member_id=member_id_value and state='active' and now()<deadline for update;
    if window_row.id is null then raise exception '本人再登録用の有効な部員期限がありません。'; end if;
  elsif not coalesce(p_member_intent_confirmed,false) or trim(coalesce(p_member_confirmation_method,''))='' or p_member_confirmed_at is null then
    raise exception '管理者代理登録には本人の提出意思確認記録が必要です。';
  end if;
  if p_target_type='smartphone_work' and p_rescue_mode='admin_proxy_submit' then
    select * into definition_row from public.exhibition_smartphone_agreement_definitions
    where id=p_smartphone_agreement_definition_id and active
      and content_hash=lower(coalesce(p_smartphone_agreement_content_hash,''));
    if definition_row.id is null or p_smartphone_agreed_at is null then raise exception 'スマホ枠代理登録には本人の有効な追加規約同意記録が必要です。'; end if;
  end if;
  select * into prior_row from public.exhibition_draft_rescue_targets
  where ((p_target_type='regular_work' and regular_work_id=p_work_id) or (p_target_type='smartphone_work' and smartphone_work_id=p_work_id))
    and state in ('authorized','processing') for update;
  if prior_row.id is not null then
    if prior_row.campaign_id=p_campaign_id and prior_row.rescue_mode=p_rescue_mode then raise exception 'この作品には同じ救済許可が既にあります。'; end if;
    update public.exhibition_draft_rescue_targets set state='revoked',revoked_at=now() where id=prior_row.id;
    insert into public.exhibition_draft_rescue_attempts(target_id,operator_identifier,operation_type,succeeded)
    values(prior_row.id,actor,'mode_change',true);
  end if;
  insert into public.exhibition_draft_rescue_targets(campaign_id,member_window_id,event_id,member_id,target_type,
    regular_work_id,smartphone_work_id,rescue_mode,state,reason,member_intent_confirmed,member_confirmation_method,
    member_confirmed_at,confirmed_by_identifier,smartphone_agreement_definition_id,smartphone_agreement_content_hash,
    smartphone_agreed_at,created_by_identifier)
  values(campaign_row.id,case when p_rescue_mode='member_resubmit' then window_row.id else null end,event_id_value,member_id_value,
    p_target_type,case when p_target_type='regular_work' then p_work_id else null end,
    case when p_target_type='smartphone_work' then p_work_id else null end,p_rescue_mode,'authorized',trim(p_reason),
    case when p_rescue_mode='admin_proxy_submit' then true else false end,
    case when p_rescue_mode='admin_proxy_submit' then trim(p_member_confirmation_method) else null end,
    case when p_rescue_mode='admin_proxy_submit' then p_member_confirmed_at else null end,
    case when p_rescue_mode='admin_proxy_submit' then actor else null end,
    case when p_target_type='smartphone_work' and p_rescue_mode='admin_proxy_submit' then definition_row.id else null end,
    case when p_target_type='smartphone_work' and p_rescue_mode='admin_proxy_submit' then definition_row.content_hash else null end,
    case when p_target_type='smartphone_work' and p_rescue_mode='admin_proxy_submit' then p_smartphone_agreed_at else null end,actor)
  returning * into target_row;
  insert into public.exhibition_draft_rescue_attempts(target_id,operator_identifier,operation_type,succeeded)
  values(target_row.id,actor,'authorization',true);
  perform private.write_exhibition_workflow_audit(event_id_value,'draft_rescue_target',target_row.id,
    'draft_rescue_target_authorized','admin',actor,p_reason,case when prior_row.id is null then '{}'::jsonb else to_jsonb(prior_row) end,to_jsonb(target_row));
  return to_jsonb(target_row);
end;$$;

create or replace function public.admin_revoke_exhibition_draft_rescue_target_v1(p_target_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old_row public.exhibition_draft_rescue_targets%rowtype; new_row public.exhibition_draft_rescue_targets%rowtype;
  actor text:=private.current_email();
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  if trim(coalesce(p_reason,''))='' then raise exception '取消理由は必須です。'; end if;
  select * into old_row from public.exhibition_draft_rescue_targets where id=p_target_id for update;
  if old_row.id is null or old_row.state not in ('authorized','processing') then raise exception '取消可能な救済許可がありません。'; end if;
  update public.exhibition_draft_rescue_targets set state='revoked',revoked_at=now() where id=old_row.id returning * into new_row;
  insert into public.exhibition_draft_rescue_attempts(target_id,operator_identifier,operation_type,succeeded)
  values(old_row.id,actor,'revocation',true);
  perform private.write_exhibition_workflow_audit(old_row.event_id,'draft_rescue_target',old_row.id,
    'draft_rescue_target_revoked','admin',actor,p_reason,to_jsonb(old_row),to_jsonb(new_row));
  return to_jsonb(new_row);
end;$$;

create or replace function public.admin_get_exhibition_draft_rescue_status_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_exhibition_draft_rescue_operator() then raise exception 'Draft救済の管理権限がありません。'; end if;
  return jsonb_build_object(
    'campaigns',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.exhibition_draft_rescue_campaigns c where c.event_id=p_event_id),'[]'::jsonb),
    'memberWindows',coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at desc) from public.exhibition_draft_rescue_member_windows w where w.event_id=p_event_id),'[]'::jsonb),
    'targets',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.exhibition_draft_rescue_targets t where t.event_id=p_event_id),'[]'::jsonb),
    'attempts',coalesce((select jsonb_agg(to_jsonb(a) order by a.attempted_at desc) from public.exhibition_draft_rescue_attempts a join public.exhibition_draft_rescue_targets t on t.id=a.target_id where t.event_id=p_event_id),'[]'::jsonb)
  );
end;$$;

revoke all on function public.admin_create_exhibition_draft_rescue_campaign_v1(uuid,timestamptz,text),
  public.admin_set_exhibition_draft_rescue_campaign_state_v1(uuid,text,text),
  public.admin_set_exhibition_draft_rescue_member_window_v1(uuid,uuid,timestamptz,text),
  public.admin_authorize_exhibition_draft_rescue_target_v1(uuid,text,uuid,text,text,boolean,text,timestamptz,uuid,text,timestamptz),
  public.admin_revoke_exhibition_draft_rescue_target_v1(uuid,text),
  public.admin_get_exhibition_draft_rescue_status_v1(uuid) from public,anon;
grant execute on function public.admin_create_exhibition_draft_rescue_campaign_v1(uuid,timestamptz,text),
  public.admin_set_exhibition_draft_rescue_campaign_state_v1(uuid,text,text),
  public.admin_set_exhibition_draft_rescue_member_window_v1(uuid,uuid,timestamptz,text),
  public.admin_authorize_exhibition_draft_rescue_target_v1(uuid,text,uuid,text,text,boolean,text,timestamptz,uuid,text,timestamptz),
  public.admin_revoke_exhibition_draft_rescue_target_v1(uuid,text),
  public.admin_get_exhibition_draft_rescue_status_v1(uuid) to authenticated;
