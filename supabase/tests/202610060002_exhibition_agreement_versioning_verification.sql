-- Agreement version/history/re-agreement verification. All fixture data is rolled back.
begin;

do $$
<<v>>
declare
  admin_email text; event_id uuid; member1 uuid; member2 uuid; member3 uuid;
  agreement1 uuid; agreement2 uuid; agreement3 uuid; hash1 text; hash2 text; hash3 text;
  snapshot1 uuid; result jsonb; initial_count integer; acceptance_count integer;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'Agreement検証にはactive Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active) values
    ('member-999071','__agreement_member1__@example.invalid','規約部員1','B2',true),
    ('member-999072','__agreement_member2__@example.invalid','規約部員2','B3',true),
    ('member-999073','__agreement_member3__@example.invalid','規約部員3','B1',true);
  select member.id into member1 from public.members member where member.email='__agreement_member1__@example.invalid';
  select member.id into member2 from public.members member where member.email='__agreement_member2__@example.invalid';
  select member.id into member3 from public.members member where member.email='__agreement_member3__@example.invalid';
  insert into public.membership_years(member_id,fiscal_year,active) values
    (member1,private.current_fiscal_year(),true),(member2,private.current_fiscal_year(),true),
    (member3,private.current_fiscal_year(),true);

  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__agreement_versioning__','規約版管理検証展',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',3,1,
    '[{"id":"agreement-slot","label":"検証シフト"}]'::jsonb,admin_email)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','agreement-v1.0','規約本文 v1.0','初回Activation');
  select definition.id,definition.content_hash into agreement1,hash1
    from public.exhibition_agreement_definitions definition
    where definition.event_id=v.event_id and definition.version_no=1;
  select count(*) into initial_count from public.exhibition_agreement_definitions definition where definition.event_id=v.event_id;
  if initial_count<>1 or agreement1 is null then raise exception 'Activationで初期Agreement Versionが1件作成されません。'; end if;

  -- Migration backfillと同じON CONFLICT経路を再実行してもAcceptance履歴は二重化しない。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__agreement_member1__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement1,hash1);
  snapshot1:=(result->>'snapshotId')::uuid;
  insert into public.exhibition_application_agreement_acceptances(
    event_id,entry_id,application_snapshot_id,member_id,agreement_definition_id,
    agreement_version,agreement_hash,acceptance_type,accepted_at,accepted_by_identifier
  ) select snapshot.event_id,snapshot.entry_id,snapshot.id,snapshot.member_id,snapshot.agreement_definition_id,
    snapshot.agreement_version,snapshot.agreement_hash,'application_submission',snapshot.agreed_at,snapshot.submitted_by_identifier
    from public.exhibition_application_snapshots snapshot where snapshot.id=v.snapshot1
    on conflict(application_snapshot_id,agreement_definition_id) do nothing;
  select count(*) into acceptance_count from public.exhibition_application_agreement_acceptances acceptance
    where acceptance.application_snapshot_id=v.snapshot1;
  if acceptance_count<>1 then raise exception '既存Application Acceptanceの履歴化が冪等ではありません。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_revise_exhibition_agreement_v2(event_id,'agreement-v1.1','規約本文 v1.1','条項を明確化',true);
  agreement2:=(result->>'agreementId')::uuid; hash2:=result->>'contentHash';
  if (select event.current_exhibition_agreement_id from public.events event where event.id=v.event_id)<>agreement2
    or (select count(*) from public.exhibition_agreement_definitions definition where definition.event_id=v.event_id)<>2
    or (select definition.content from public.exhibition_agreement_definitions definition where definition.id=v.agreement1)<>'規約本文 v1.0'
    then raise exception 'v1.0→v1.1の版追加または旧版保持が不正です。'; end if;
  begin
    update public.exhibition_agreement_definitions definition set content='改ざん' where definition.id=v.agreement1;
    raise exception '過去Agreement VersionをUPDATEできました。';
  exception when others then if sqlerrm='過去Agreement VersionをUPDATEできました。' then raise; end if; end;
  begin
    delete from public.exhibition_agreement_definitions definition where definition.id=v.agreement1;
    raise exception '過去Agreement VersionをDELETEできました。';
  exception when others then if sqlerrm='過去Agreement VersionをDELETEできました。' then raise; end if; end;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__agreement_member1__@example.invalid','role','authenticated')::text,true);
  result:=public.get_my_exhibition_agreement_status_v2(event_id);
  if not (result->>'agreementStale')::boolean then raise exception '再同意必須の既存Applicationがstaleになりません。'; end if;
  perform public.reagree_exhibition_application_v2(event_id,agreement2,hash2);
  result:=public.get_my_exhibition_agreement_status_v2(event_id);
  if (result->>'agreementStale')::boolean
    or jsonb_array_length(result->'acceptances')<>2
    or (select snapshot.agreement_definition_id from public.exhibition_application_snapshots snapshot where snapshot.id=v.snapshot1)<>agreement1
    then raise exception '再同意履歴または元Application Snapshotの不変性が不正です。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email','__agreement_member2__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement2,hash2);
  if not exists(select 1 from public.exhibition_application_snapshots snapshot
    where snapshot.id=(result->>'snapshotId')::uuid and snapshot.agreement_definition_id=agreement2) then
    raise exception '改定後の新規Applicationがcurrent規約を使用していません。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  result:=public.admin_revise_exhibition_agreement_v2(event_id,'agreement-v1.2','規約本文 v1.2','表記のみ修正',false);
  agreement3:=(result->>'agreementId')::uuid; hash3:=result->>'contentHash';
  perform set_config('request.jwt.claims',jsonb_build_object('email','__agreement_member1__@example.invalid','role','authenticated')::text,true);
  if (public.get_my_exhibition_agreement_status_v2(event_id)->>'agreementStale')::boolean then
    raise exception '再同意不要の改定で既存Applicationがstaleになりました。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__agreement_member3__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement3,hash3);
  if not exists(select 1 from public.exhibition_application_snapshots snapshot
    where snapshot.id=(result->>'snapshotId')::uuid and snapshot.agreement_definition_id=agreement3) then
    raise exception '再同意不要改定後の新規Applicationがcurrent規約を使用していません。'; end if;

  begin
    perform public.admin_revise_exhibition_agreement_v2(event_id,'agreement-v1.3','規約本文','不正操作',false);
    raise exception '一般部員がAgreement Versionを作成できました。';
  exception when others then if sqlerrm='一般部員がAgreement Versionを作成できました。' then raise; end if; end;
  execute 'set local role authenticated';
  if exists(select 1 from public.exhibition_application_agreement_acceptances acceptance where acceptance.member_id<>v.member3)
    then raise exception '一般部員が他人のAgreement同意履歴を閲覧できました。'; end if;
  execute 'reset role';

  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  if jsonb_array_length(public.admin_get_exhibition_agreement_versions_v2(event_id))<>3
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit
      where audit.event_id=v.event_id and audit.action='agreement_version_created'
        and (audit.metadata->>'requireReagreement')::boolean)
    or not exists(select 1 from public.exhibition_workflow_audit_logs audit
      where audit.event_id=v.event_id and audit.action='application_agreement_reagreed')
    then raise exception '管理者履歴表示またはAgreement Auditが不足しています。'; end if;
end $$;

select
  to_regprocedure('public.admin_revise_exhibition_agreement_v2(uuid,text,text,text,boolean)') is not null as revise_rpc_ready,
  to_regprocedure('public.reagree_exhibition_application_v2(uuid,uuid,text)') is not null as reagree_rpc_ready,
  to_regclass('public.exhibition_application_agreement_acceptances') is not null as acceptance_history_ready;

rollback;
