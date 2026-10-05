-- Phase 1 verification. SQL Editorでmigration適用後に実行する。
-- 全変更はROLLBACKされる。Productionデータを永続変更しない。

begin;

do $$
begin
  perform private.validate_exhibition_v2_deadlines(
    now() + interval '1 day', now() + interval '2 days',
    now() + interval '3 days', now() + interval '4 days', true
  );
  begin
    perform private.validate_exhibition_v2_deadlines(
      now() + interval '1 day', now() + interval '1 day',
      now() + interval '3 days', now() + interval '4 days', true
    );
    raise exception '同一時刻の締切が拒否されませんでした。';
  exception when others then
    if sqlerrm = '同一時刻の締切が拒否されませんでした。' then raise; end if;
  end;
  begin
    perform private.validate_exhibition_v2_deadlines(
      now() + interval '2 days', now() + interval '1 day',
      now() + interval '3 days', now() + interval '4 days', true
    );
    raise exception '逆転した締切が拒否されませんでした。';
  exception when others then
    if sqlerrm = '逆転した締切が拒否されませんでした。' then raise; end if;
  end;
end $$;

do $$
declare admin_email text; general_id uuid; v2_id uuid; agreement_id uuid; audit_count integer;
begin
  select email into admin_email from public.admins where active order by created_at limit 1;
  if admin_email is null then raise exception '検証にはactiveなAdminが1件必要です。'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('email', admin_email, 'role', 'authenticated')::text, true);

  insert into public.events(status,published,genre,title,updated_by)
  values('draft',false,'meeting','__phase1_general_test__',admin_email)
  returning id into general_id;
  if (select exhibition_workflow_version from public.events where id=general_id) <> 1 then
    raise exception '一般EventがLegacyとして作成されませんでした。';
  end if;

  insert into public.events(status,published,genre,title,updated_by)
  values('draft',false,'exhibition','__phase1_exhibition_test__',admin_email)
  returning id into v2_id;
  if (select exhibition_workflow_version from public.events where id=v2_id) <> 1 then
    raise exception '新規写真展が明示操作なしにv2化されました。';
  end if;

  begin
    insert into public.events(
      status,published,genre,title,updated_by,exhibition_workflow_version,
      exhibition_application_deadline,exhibition_work_submission_deadline,
      exhibition_revision_deadline,exhibition_caption_deadline
    ) values(
      'draft',false,'exhibition','__phase1_direct_v2_test__',admin_email,2,
      now()+interval '1 day',now()+interval '2 days',
      now()+interval '3 days',now()+interval '4 days'
    );
    raise exception 'Event INSERTからの直接v2化が拒否されませんでした。';
  exception when others then
    if sqlerrm='Event INSERTからの直接v2化が拒否されませんでした。' then raise; end if;
  end;

  perform public.admin_activate_exhibition_workflow_v2(
    v2_id, now()+interval '1 day', now()+interval '2 days',
    now()+interval '3 days', now()+interval '4 days',
    'phase1-test-v1', '検証用同意文', 'Phase 1検証'
  );
  select current_exhibition_agreement_id into agreement_id from public.events
    where id=v2_id and exhibition_workflow_version=2;
  if agreement_id is null then raise exception 'v2またはAgreementが有効化されませんでした。'; end if;
  select count(*) into audit_count from public.exhibition_workflow_audit_logs
    where event_id=v2_id and action='workflow_v2_activated';
  if audit_count<>1 then raise exception '有効化Auditが正しく生成されませんでした。'; end if;

  begin
    perform public.admin_update_exhibition_workflow_deadlines(
      v2_id, now()+interval '12 hours', now()+interval '2 days',
      now()+interval '3 days', now()+interval '4 days', ''
    );
    raise exception '理由なしの締切短縮が拒否されませんでした。';
  exception when others then
    if sqlerrm='理由なしの締切短縮が拒否されませんでした。' then raise; end if;
  end;

  begin
    update public.events set exhibition_caption_deadline=now()+interval '5 days' where id=v2_id;
    raise exception '締切の直接UPDATEが拒否されませんでした。';
  exception when others then
    if sqlerrm='締切の直接UPDATEが拒否されませんでした。' then raise; end if;
  end;

  begin
    update public.events set exhibition_workflow_version=1 where id=v2_id;
    raise exception 'v2からLegacyへの戻しが拒否されませんでした。';
  exception when others then
    if sqlerrm='v2からLegacyへの戻しが拒否されませんでした。' then raise; end if;
  end;
end $$;

-- authenticated AdminはAuditを閲覧できるが、直接の偽造・更新・削除はできない。
set local role authenticated;

do $$
declare test_event_id uuid; visible_count integer;
begin
  select id into test_event_id from public.events where title='__phase1_exhibition_test__' limit 1;
  select count(*) into visible_count from public.exhibition_workflow_audit_logs where event_id=test_event_id;
  if visible_count < 1 then raise exception 'AdminからAuditを閲覧できません。'; end if;

  begin
    insert into public.exhibition_workflow_audit_logs(
      event_id,entity_type,entity_id,action,actor_type,actor_identifier
    ) values(test_event_id,'event',test_event_id,'forged','admin','forged@example.com');
    raise exception 'Auditの直接INSERTが拒否されませんでした。';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.exhibition_workflow_audit_logs set reason='forged' where event_id=test_event_id;
    raise exception 'AuditのUPDATEが拒否されませんでした。';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.exhibition_workflow_audit_logs where event_id=test_event_id;
    raise exception 'AuditのDELETEが拒否されませんでした。';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- Adminではないauthenticated利用者にはAuditが見えない。
select set_config(
  'request.jwt.claims',
  jsonb_build_object('email', '__phase1_non_admin__@example.invalid', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

do $$
begin
  if exists(select 1 from public.exhibition_workflow_audit_logs) then
    raise exception '一般利用者にAuditが公開されています。';
  end if;
end $$;

reset role;

select
  (select count(*) from public.events where genre <> 'exhibition' and exhibition_workflow_version <> 1)=0
    as general_events_remain_legacy,
  (select count(*) from public.events where exhibition_workflow_version=1 and (
    exhibition_application_deadline is not null or exhibition_work_submission_deadline is not null
    or exhibition_revision_deadline is not null or exhibition_caption_deadline is not null
  ))=0 as legacy_deadlines_remain_optional,
  to_regprocedure('public.get_public_exhibition(text)') is not null as public_rpc_preserved,
  to_regprocedure('public.submit_exhibition_survey(text,text,text,text,jsonb)') is not null as survey_rpc_preserved,
  to_regclass('public.exhibition_layouts') is not null as layout_preserved,
  to_regclass('public.archive_works') is not null as archive_preserved,
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='events' and column_name='registration_deadline') as registration_deadline_preserved,
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='exhibition_works' and column_name='display_no') as display_no_preserved;

rollback;
