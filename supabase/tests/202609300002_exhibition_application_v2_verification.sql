-- Phase 2 verification。migration適用後にSQL Editorで実行する。
-- 検証データは最後にすべてROLLBACKされる。

begin;

do $$
declare
  v_admin_email text; v_member1_id uuid; v_member2_id uuid; v_v1_event_id uuid; v_v2_event_id uuid;
  v_v1_entry_id uuid; v_agreement1_id uuid; v_agreement1_hash text; v_agreement2_id uuid; v_agreement2_hash text;
  v_result jsonb; v_entry_id uuid; v_snapshot1_id uuid; v_snapshot2_id uuid; v_original_application_deadline timestamptz;
  v_snapshot_count integer; v_audit_count integer;
begin
  select admin.email into v_admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if v_admin_email is null then raise exception '検証にはactiveなAdminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);

  insert into public.members(member_no,email,name,grade,active)
  values('member-990001','__phase2_member1__@example.invalid','検証 本名','B2',true) returning id into v_member1_id;
  insert into public.members(member_no,email,name,grade,active)
  values('member-990002','__phase2_member2__@example.invalid','別の部員','B3',true) returning id into v_member2_id;
  insert into public.membership_years(member_id,fiscal_year,active)
  values(v_member1_id,private.current_fiscal_year(),true),(v_member2_id,private.current_fiscal_year(),true);

  insert into public.events(
    status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by
  ) values(
    'saved',true,'exhibition','__phase2_v1__','Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email
  ) returning id into v_v1_event_id;

  insert into public.events(
    status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by
  ) values(
    'saved',true,'exhibition','__phase2_v2__','v2検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場',v_admin_email,now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,v_admin_email
  ) returning id into v_v2_event_id;
  perform public.admin_activate_exhibition_workflow_v2(
    v_v2_event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days',
    'phase2-agreement-v1','検証用Application Agreement v1','Phase 2検証'
  );
  select agreement.id,agreement.content_hash into v_agreement1_id,v_agreement1_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v_v2_event_id and agreement.active;

  -- v1ではWork 0件のsubmittedを従来どおり拒否する。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase2_member1__@example.invalid','role','authenticated')::text,true);
  insert into public.exhibition_entries(event_id,member_id,status) values(v_v1_event_id,v_member1_id,'draft') returning id into v_v1_entry_id;
  begin
    update public.exhibition_entries entry set status='submitted' where entry.id=v_v1_entry_id;
    raise exception 'v1 Work 0件提出が拒否されませんでした。';
  exception when others then
    if sqlerrm='v1 Work 0件提出が拒否されませんでした。' then raise; end if;
  end;

  -- Smartphone Phase 1以降、0は「個人枠0点」の有効値。負数は引き続き拒否する。
  perform private.validate_exhibition_application_values(
    (select event from public.events event where event.id=v_v2_event_id),
    (select member from public.members member where member.id=v_member1_id),0,'real_name',''
  );
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,-1,'real_name','', '',v_agreement1_id,v_agreement1_hash);
    raise exception 'planned_work_count負数が拒否されませんでした。';
  exception when others then if sqlerrm='planned_work_count負数が拒否されませんでした。' then raise; end if; end;
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,4,'real_name','', '',v_agreement1_id,v_agreement1_hash);
    raise exception 'max_works超過が拒否されませんでした。';
  exception when others then if sqlerrm='max_works超過が拒否されませんでした。' then raise; end if; end;
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,1,'pseudonym','   ', '',v_agreement1_id,v_agreement1_hash);
    raise exception '空のペンネームが拒否されませんでした。';
  exception when others then if sqlerrm='空のペンネームが拒否されませんでした。' then raise; end if; end;

  -- Agreementなしを拒否する。
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set current_exhibition_agreement_id=null where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,1,'real_name','', '',v_agreement1_id,v_agreement1_hash);
    raise exception 'Agreementなし申込が拒否されませんでした。';
  exception when others then if sqlerrm='Agreementなし申込が拒否されませんでした。' then raise; end if; end;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set current_exhibition_agreement_id=v_agreement1_id where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  -- Agreement更新後、古いID/hashによる申込を拒否する。
  perform set_config('request.jwt.claims',jsonb_build_object('email',v_admin_email,'role','authenticated')::text,true);
  select (public.admin_create_exhibition_agreement_definition(v_v2_event_id,'phase2-agreement-v2','検証用Agreement v2','stale検証')->>'agreementId')::uuid into v_agreement2_id;
  select agreement.content_hash into v_agreement2_hash from public.exhibition_agreement_definitions agreement where agreement.id=v_agreement2_id;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase2_member1__@example.invalid','role','authenticated')::text,true);
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,1,'real_name','', '',v_agreement1_id,v_agreement1_hash);
    raise exception '古いAgreementによる申込が拒否されませんでした。';
  exception when others then if sqlerrm='古いAgreementによる申込が拒否されませんでした。' then raise; end if; end;

  -- deadline時刻ちょうどは締切済み。
  select event.exhibition_application_deadline into v_original_application_deadline from public.events event where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set exhibition_application_deadline=now() where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,1,'real_name','', '',v_agreement2_id,v_agreement2_hash);
    raise exception 'deadline時刻の申込が拒否されませんでした。';
  exception when others then if sqlerrm='deadline時刻の申込が拒否されませんでした。' then raise; end if; end;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set exhibition_application_deadline=now()-interval '1 second' where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);
  begin
    perform public.submit_exhibition_application_v2(v_v2_event_id,1,'real_name','', '',v_agreement2_id,v_agreement2_hash);
    raise exception 'deadline後の申込が拒否されませんでした。';
  exception when others then if sqlerrm='deadline後の申込が拒否されませんでした。' then raise; end if; end;
  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events event set exhibition_application_deadline=v_original_application_deadline where event.id=v_v2_event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  -- Working Dataを下書き保存してもSnapshotは作られない。
  v_result:=public.save_exhibition_application_draft_v2(v_v2_event_id,2,'real_name','改ざん名','下書き');
  v_entry_id:=(v_result->>'entryId')::uuid;
  if exists(select 1 from public.exhibition_application_snapshots snapshot where snapshot.entry_id=v_entry_id) then
    raise exception '下書き保存時にSnapshotが作成されました。';
  end if;

  -- v2は同じEntryを使い、Work 0件で正式Applicationを作成でき、本名はSnapshotへ固定される。
  v_result:=public.submit_exhibition_application_v2(v_v2_event_id,2,'real_name','改ざん名','備考',v_agreement2_id,v_agreement2_hash);
  if (v_result->>'entryId')::uuid<>v_entry_id then raise exception '下書きと正式申込でEntry UUIDが変わりました。'; end if;
  v_snapshot1_id:=(v_result->>'snapshotId')::uuid;
  if exists(select 1 from public.exhibition_works work where work.entry_id=v_entry_id) then raise exception 'v2申込時にWorkが作成されました。'; end if;
  if (select snapshot.display_name_value from public.exhibition_application_snapshots snapshot where snapshot.id=v_snapshot1_id)<>'検証 本名' then
    raise exception '本名がSnapshotへ固定されませんでした。';
  end if;

  -- SnapshotはUPDATE/DELETE不可。
  begin
    update public.exhibition_application_snapshots snapshot set note='改ざん' where snapshot.id=v_snapshot1_id;
    raise exception 'Snapshot UPDATEが拒否されませんでした。';
  exception when others then if sqlerrm='Snapshot UPDATEが拒否されませんでした。' then raise; end if; end;
  begin
    delete from public.exhibition_application_snapshots snapshot where snapshot.id=v_snapshot1_id;
    raise exception 'Snapshot DELETEが拒否されませんでした。';
  exception when others then if sqlerrm='Snapshot DELETEが拒否されませんでした。' then raise; end if; end;

  perform public.update_exhibition_application_working_data_v2(v_v2_event_id,3,'pseudonym','  検証名  ','変更後備考');
  if (select snapshot.display_name_value from public.exhibition_application_snapshots snapshot where snapshot.id=v_snapshot1_id)<>'検証 本名' then
    raise exception 'Working Data変更により過去Snapshotが変化しました。';
  end if;

  v_result:=public.withdraw_exhibition_application_v2(v_v2_event_id,'検証取消');
  if (v_result->>'applicationState')<>'withdrawn' then raise exception 'deadline前withdrawに失敗しました。'; end if;
  v_result:=public.submit_exhibition_application_v2(v_v2_event_id,1,'pseudonym','再申込名','再申込',v_agreement2_id,v_agreement2_hash);
  v_snapshot2_id:=(v_result->>'snapshotId')::uuid;
  if (v_result->>'entryId')::uuid<>v_entry_id then raise exception '再申込でEntry UUIDが変わりました。'; end if;
  if (v_result->>'versionNo')::integer<>2 then raise exception '再申込Snapshot versionが2ではありません。'; end if;
  select count(*) into v_snapshot_count from public.exhibition_application_snapshots snapshot where snapshot.entry_id=v_entry_id;
  if v_snapshot_count<>2 or not exists(select 1 from public.exhibition_application_snapshots snapshot where snapshot.id=v_snapshot1_id) then
    raise exception '過去Snapshotが保持されていません。';
  end if;
  select count(*) into v_audit_count from public.exhibition_workflow_audit_logs audit
    where audit.event_id=v_v2_event_id and audit.action in (
      'application_submitted','application_withdrawn','application_reapplied',
      'planned_work_count_changed','application_display_name_changed','application_note_changed'
    );
  if v_audit_count<6 then raise exception 'Application Auditが不足しています。'; end if;
end $$;

-- 別MemberからSnapshotを参照できず、直接変更権限もない。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase2_member2__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$
begin
  if exists(select 1 from public.exhibition_entries entry where entry.application_state is not null) then
    raise exception '別MemberにApplication Working Dataが公開されています。';
  end if;
  if exists(select 1 from public.exhibition_application_snapshots) then raise exception '別MemberにSnapshotが公開されています。'; end if;
  begin
    update public.exhibition_application_snapshots set note='改ざん';
    raise exception 'MemberのSnapshot直接UPDATEが拒否されませんでした。';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.exhibition_application_snapshots;
    raise exception 'MemberのSnapshot直接DELETEが拒否されませんでした。';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select
  not exists(select 1 from public.events event where event.title='__phase2_v1__' and event.exhibition_workflow_version<>1) as v1_preserved,
  to_regprocedure('public.get_public_exhibition(text)') is not null as public_rpc_preserved,
  to_regprocedure('public.submit_exhibition_survey(text,text,text,text,jsonb)') is not null as survey_rpc_preserved,
  to_regclass('public.exhibition_layouts') is not null as layout_preserved,
  to_regclass('public.archive_works') is not null as archive_preserved,
  exists(select 1 from information_schema.columns column_info where column_info.table_schema='public' and column_info.table_name='events' and column_info.column_name='registration_deadline') as registration_deadline_preserved,
  exists(select 1 from information_schema.columns column_info where column_info.table_schema='public' and column_info.table_name='exhibition_works' and column_info.column_name='display_no') as display_no_preserved;

rollback;
