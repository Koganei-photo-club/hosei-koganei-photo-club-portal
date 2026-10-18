-- Member-facing Draft rescue action API verification. Fixtures are rolled back.
begin;
do $$
<<v>>
declare operator_email constant text:='takayuki.fujiyoshi.2r@stu.hosei.ac.jp';
  member_email constant text:='__draft_rescue_ui_member__@example.invalid';
  event_id uuid;member_id uuid;agreement_id uuid;agreement_hash text;
  regular_work_id uuid;smartphone_work_id uuid;campaign_id uuid;target_id uuid;result jsonb;
begin
  insert into public.admins(email,name,role_name,active) values(operator_email,'救済UI管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.members(member_no,email,name,grade,active)
  values('member-999195',member_email,'救済UI検証部員','B2',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__draft_rescue_ui__','救済UI検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',operator_email,now()+interval '1 day',3,1,'[{"id":"slot-1","label":"検証枠"}]'::jsonb,operator_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','draft-rescue-ui','Application規約','救済UI検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=3 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  perform public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'救済作品','','','',null,null,null,null,null);
  regular_work_id:=(result->>'id')::uuid;
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,null,false,null,'',null,null);
  smartphone_work_id:=(result->>'id')::uuid;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_draft_rescue_campaign_v1(event_id,now()+interval '3 hours','UI検証');
  campaign_id:=(result->>'id')::uuid;
  perform public.admin_set_exhibition_draft_rescue_member_window_v1(campaign_id,member_id,now()+interval '2 hours','本人期限');
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',regular_work_id,
    'member_resubmit','通常作品の再登録',false,null,null,null,null,null);
  target_id:=(result->>'id')::uuid;
  perform public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'smartphone_work',smartphone_work_id,
    'admin_proxy_submit','代理提出',true,'対面',now(),
    (select id from public.exhibition_smartphone_agreement_definitions where active order by version_no desc limit 1),
    (select content_hash from public.exhibition_smartphone_agreement_definitions where active order by version_no desc limit 1),now());

  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  if (select count(*) from public.get_my_exhibition_draft_rescue_targets_v1(event_id))<>1 then
    raise exception '本人向けAPIがmember_resubmitだけを返していません。';
  end if;
  if not exists(select 1 from public.get_my_exhibition_draft_rescue_targets_v1(event_id) action_row
    where action_row.work_id=regular_work_id and action_row.required_action_type='regular_work_rescue_required'
      and action_row.section='work' and action_row.deadline>now()) then
    raise exception '通常作品のRequired Action情報が不正です。';
  end if;
  if exists(select 1 from public.get_my_exhibition_draft_rescue_targets_v1(event_id) action_row
    where action_row.work_id=smartphone_work_id) then
    raise exception 'admin_proxy_submitが本人向け対応事項へ漏れています。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  perform public.admin_revoke_exhibition_draft_rescue_target_v1(target_id,'表示消滅確認');
  perform set_config('request.jwt.claims',jsonb_build_object('email',member_email,'role','authenticated')::text,true);
  if exists(select 1 from public.get_my_exhibition_draft_rescue_targets_v1(event_id)) then
    raise exception '取消済みTargetが本人向けAPIに残っています。';
  end if;
end $$;
rollback;
