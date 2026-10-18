-- Draft rescue management RPC verification. All fixtures are rolled back.
begin;
do $$
<<v>>
declare operator_email constant text:='takayuki.fujiyoshi.2r@stu.hosei.ac.jp';
  other_admin constant text:='__draft_rescue_management_admin__@example.invalid';
  member_email constant text:='__draft_rescue_management_member__@example.invalid';
  event_id uuid;member_id uuid;agreement_id uuid;smartphone_agreement_id uuid;
  agreement_hash text;smartphone_agreement_hash text;regular_work_id uuid;smartphone_work_id uuid;
  campaign_id uuid;window_id uuid;member_target_id uuid;proxy_target_id uuid;result jsonb;
begin
  insert into public.admins(email,name,role_name,active) values(operator_email,'救済管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.admins(email,name,role_name,active) values(other_admin,'指定外管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.members(member_no,email,name,grade,active)
  values('member-999191',member_email,'救済管理検証部員','B2',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__draft_rescue_management__','救済管理検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',operator_email,now()+interval '1 day',3,1,'[{"id":"slot-1","label":"検証枠"}]'::jsonb,operator_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','draft-rescue-management','Application規約','救済管理検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  select id,content_hash into smartphone_agreement_id,smartphone_agreement_hash
  from public.exhibition_smartphone_agreement_definitions where active order by version_no desc limit 1;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'','','','',null,null,null,null,null);
  regular_work_id:=(result->>'id')::uuid;
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  smartphone_work_id:=(result->>'id')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email',other_admin,'role','authenticated')::text,true);
  begin
    perform public.admin_create_exhibition_draft_rescue_campaign_v1(event_id,now()+interval '3 hours','拒否検証');
    raise exception '指定外AdminがCampaignを作成できました。';
  exception when others then if sqlerrm='指定外AdminがCampaignを作成できました。' then raise; end if; end;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_draft_rescue_campaign_v1(event_id,now()+interval '3 hours','期限後Draft救済');
  campaign_id:=(result->>'id')::uuid;
  result:=public.admin_set_exhibition_draft_rescue_member_window_v1(campaign_id,member_id,now()+interval '2 hours','本人再登録期限');
  window_id:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',regular_work_id,
    'member_resubmit','本人再登録',false,null,null,null,null,null);
  member_target_id:=(result->>'id')::uuid;
  if (result->>'member_window_id')::uuid is distinct from window_id then raise exception 'Member TargetにWindowが固定されません。'; end if;
  if not private.exhibition_draft_rescue_protects_work('regular_work',regular_work_id) then raise exception 'Member Targetが有効ではありません。'; end if;

  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'smartphone_work',smartphone_work_id,
    'admin_proxy_submit','本人意思確認済み',true,'対面確認',now(),smartphone_agreement_id,smartphone_agreement_hash,now());
  proxy_target_id:=(result->>'id')::uuid;
  if result->>'member_window_id' is not null then raise exception 'Proxy TargetがMember Windowを参照しています。'; end if;
  if not private.current_operator_can_proxy_submit_draft('smartphone_work',smartphone_work_id) then raise exception 'Proxy Targetが有効ではありません。'; end if;

  result:=public.admin_get_exhibition_draft_rescue_status_v1(event_id);
  if jsonb_array_length(result->'campaigns')<>1 or jsonb_array_length(result->'memberWindows')<>1
     or jsonb_array_length(result->'targets')<>2 or jsonb_array_length(result->'attempts')<>2 then
    raise exception '救済状況の読取結果が不正です。';
  end if;
  perform public.admin_revoke_exhibition_draft_rescue_target_v1(member_target_id,'本人対応不要');
  if private.exhibition_draft_rescue_protects_work('regular_work',regular_work_id) then raise exception '取消Targetが有効です。'; end if;
  if not exists(select 1 from public.exhibition_draft_rescue_attempts a where a.target_id=member_target_id and a.operation_type='revocation') then
    raise exception 'Target取消履歴がありません。';
  end if;
  perform public.admin_set_exhibition_draft_rescue_campaign_state_v1(campaign_id,'disabled','緊急停止');
  if private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone_work_id) then raise exception '無効化CampaignがTargetを保護しています。'; end if;
  perform public.admin_set_exhibition_draft_rescue_campaign_state_v1(campaign_id,'enabled','再開');
  if not private.exhibition_draft_rescue_protects_work('smartphone_work',smartphone_work_id) then raise exception '再開CampaignでProxy Targetが復帰しません。'; end if;
  if not exists(select 1 from public.exhibition_workflow_audit_logs a where a.event_id=v.event_id and a.action='draft_rescue_campaign_created') then
    raise exception '共通AuditへCampaign操作が記録されていません。';
  end if;
end $$;
rollback;
