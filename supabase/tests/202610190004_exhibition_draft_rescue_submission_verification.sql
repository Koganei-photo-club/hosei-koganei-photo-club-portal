-- Draft rescue submission and deadline protection verification. Fixtures roll back.
begin;

do $$
<<v>>
declare
  operator_email constant text:='takayuki.fujiyoshi.2r@stu.hosei.ac.jp';
  other_admin_email constant text:='__draft_rescue_submit_admin__@example.invalid';
  emails text[]:=array['__rescue_regular_member__@example.invalid','__rescue_phone_member__@example.invalid',
    '__rescue_regular_proxy__@example.invalid','__rescue_phone_proxy__@example.invalid',
    '__rescue_expired__@example.invalid','__rescue_unprotected__@example.invalid',
    '__rescue_no_image__@example.invalid'];
  members uuid[]:='{}'; entries uuid[]:='{}'; member_id uuid; event_id uuid;
  agreement_id uuid; agreement_hash text; smartphone_agreement_id uuid; smartphone_agreement_hash text;
  campaign_id uuid; window_id uuid; result jsonb; object_path text; i integer;
  regular_member uuid; phone_member uuid; regular_proxy uuid; phone_proxy uuid; expired_work uuid;
  unprotected_work uuid; no_image_work uuid; regular_target uuid; phone_target uuid;
  regular_proxy_target uuid; phone_proxy_target uuid; expired_target uuid; no_image_target uuid;
  regular_snapshot uuid; phone_snapshot uuid;
begin
  insert into public.admins(email,name,role_name,active) values(operator_email,'救済指定管理者','管理者',true)
  on conflict(email) do update set active=true;
  insert into public.admins(email,name,role_name,active) values(other_admin_email,'救済指定外管理者','管理者',true)
  on conflict(email) do update set active=true;
  for i in 1..array_length(emails,1) loop
    insert into public.members(member_no,email,name,grade,active)
    values('member-'||(997900+i)::text,emails[i],'救済提出検証'||i,'B'||least(i,4)::text,true)
    returning id into member_id;
    members:=array_append(members,member_id);
    insert into public.membership_years(member_id,fiscal_year,active)
    values(member_id,private.current_fiscal_year(),true);
  end loop;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('saved',true,'exhibition','__draft_rescue_submission__','救済提出検証展',now()+interval '10 days',
    now()+interval '11 days','検証会場',operator_email,now()+interval '1 day',6,1,
    '[{"id":"rescue","label":"救済検証枠"}]'::jsonb,operator_email) returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',
    now()+interval '3 days',now()+interval '4 days','draft-rescue-submission','Application規約','救済提出検証');
  update public.events set smartphone_exhibition_enabled=true,max_smartphone_works=6 where id=event_id;
  select current_exhibition_agreement_id into agreement_id from public.events where id=event_id;
  select content_hash into agreement_hash from public.exhibition_agreement_definitions where id=agreement_id;
  select id,content_hash into smartphone_agreement_id,smartphone_agreement_hash
  from public.exhibition_smartphone_agreement_definitions where active order by version_no desc limit 1;

  for i in 1..array_length(emails,1) loop
    perform set_config('request.jwt.claims',jsonb_build_object('email',emails[i],'role','authenticated')::text,true);
    result:=public.submit_exhibition_application_v2(event_id,1,'real_name','','',agreement_id,agreement_hash);
    entries:=array_append(entries,(result->>'entryId')::uuid);
  end loop;

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[1],'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'救済通常本人','portrait','A3','',297,420,true,null,null);
  regular_member:=(result->>'id')::uuid;
  object_path:=event_id||'/'||members[1]||'/'||regular_member||'/regular-member.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,regular_member,'救済通常本人','portrait','A3','',297,420,true,object_path,repeat('1',64));

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[2],'role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'portrait',true,'none','',null,null);
  phone_member:=(result->>'id')::uuid;
  object_path:=event_id||'/'||members[2]||'/'||phone_member||'/phone-member.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,members[2],'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone_member,'portrait',true,'none','',object_path,repeat('2',64));

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[3],'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'救済通常代理','landscape','A3','',420,297,false,null,null);
  regular_proxy:=(result->>'id')::uuid;
  object_path:=event_id||'/'||members[3]||'/'||regular_proxy||'/regular-proxy.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,regular_proxy,'救済通常代理','landscape','A3','',420,297,false,object_path,repeat('3',64));

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[4],'role','authenticated')::text,true);
  result:=public.save_exhibition_smartphone_work_draft_v1(event_id,null,'landscape',true,'declared','生成要素を追加',null,null);
  phone_proxy:=(result->>'id')::uuid;
  object_path:=event_id||'/'||members[4]||'/'||phone_proxy||'/phone-proxy.jpg';
  insert into storage.objects(bucket_id,name,owner_id,metadata) values('exhibition-originals',object_path,members[4],'{}');
  perform public.save_exhibition_smartphone_work_draft_v1(event_id,phone_proxy,'landscape',true,'declared','生成要素を追加',object_path,repeat('4',64));

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[5],'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'期限切れ','portrait','A3','',297,420,true,null,null);
  expired_work:=(result->>'id')::uuid;
  object_path:=event_id||'/'||members[5]||'/'||expired_work||'/expired.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',object_path,'{}');
  perform public.save_exhibition_work_draft_v2(event_id,expired_work,'期限切れ','portrait','A3','',297,420,true,object_path,repeat('5',64));

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[6],'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'保護なし','portrait','A3','',297,420,true,null,null);
  unprotected_work:=(result->>'id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[7],'role','authenticated')::text,true);
  result:=public.save_exhibition_work_draft_v2(event_id,null,'画像なし','portrait','A3','',297,420,true,null,null);
  no_image_work:=(result->>'id')::uuid;

  perform set_config('app.exhibition_workflow_rpc','on',true);
  update public.events set exhibition_application_deadline=now()-interval '4 hours',
    exhibition_work_submission_deadline=now()-interval '3 hours',exhibition_revision_deadline=now()-interval '2 hours',
    exhibition_caption_deadline=now()-interval '1 hour' where id=event_id;
  perform set_config('app.exhibition_workflow_rpc','off',true);

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  result:=public.admin_create_exhibition_draft_rescue_campaign_v1(event_id,now()+interval '4 hours','提出救済');
  campaign_id:=(result->>'id')::uuid;
  for i in 1..2 loop
    result:=public.admin_set_exhibition_draft_rescue_member_window_v1(campaign_id,members[i],now()+interval '2 hours','本人期限');
  end loop;
  result:=public.admin_set_exhibition_draft_rescue_member_window_v1(campaign_id,members[5],now()+interval '1 hour','期限切れ化');
  window_id:=(result->>'id')::uuid;
  begin
    perform public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',no_image_work,
      'admin_proxy_submit','本人意思なし',false,null,null,null,null,null);
    raise exception '本人意思確認なしで代理Targetを作成できました。';
  exception when others then if sqlerrm='本人意思確認なしで代理Targetを作成できました。' then raise; end if; end;
  begin
    perform public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'smartphone_work',phone_proxy,
      'admin_proxy_submit','規約同意なし',true,'対面',now(),null,null,null);
    raise exception 'スマホ規約同意なしで代理Targetを作成できました。';
  exception when others then if sqlerrm='スマホ規約同意なしで代理Targetを作成できました。' then raise; end if; end;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',regular_member,
    'member_resubmit','本人通常',false,null,null,null,null,null); regular_target:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'smartphone_work',phone_member,
    'member_resubmit','本人スマホ',false,null,null,null,null,null); phone_target:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',regular_proxy,
    'admin_proxy_submit','代理通常',true,'対面',now(),null,null,null); regular_proxy_target:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'smartphone_work',phone_proxy,
    'admin_proxy_submit','代理スマホ',true,'対面',now(),smartphone_agreement_id,smartphone_agreement_hash,now());
  phone_proxy_target:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',expired_work,
    'member_resubmit','期限切れ',false,null,null,null,null,null); expired_target:=(result->>'id')::uuid;
  result:=public.admin_authorize_exhibition_draft_rescue_target_v1(campaign_id,'regular_work',no_image_work,
    'admin_proxy_submit','画像なし代理',true,'対面',now(),null,null,null); no_image_target:=(result->>'id')::uuid;
  update public.exhibition_draft_rescue_member_windows set created_at=now()-interval '2 minutes',
    deadline=now()-interval '1 minute',updated_at=now() where id=window_id;

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[5],'role','authenticated')::text,true);
  begin
    perform public.submit_exhibition_work_batch_v2(event_id,array[expired_work]);
    raise exception '期限切れ本人救済が提出できました。';
  exception when others then if sqlerrm='期限切れ本人救済が提出できました。' then raise; end if; end;

  perform set_config('request.jwt.claims',jsonb_build_object('email',other_admin_email,'role','authenticated')::text,true);
  begin
    perform public.admin_proxy_submit_regular_draft_rescue_v1(regular_proxy_target);
    raise exception '指定外Adminが代理登録できました。';
  exception when others then if sqlerrm='指定外Adminが代理登録できました。' then raise; end if; end;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  begin
    perform public.admin_proxy_submit_regular_draft_rescue_v1(no_image_target);
    raise exception '画像なし作品を代理登録できました。';
  exception when others then if sqlerrm='画像なし作品を代理登録できました。' then raise; end if; end;

  perform public.admin_process_exhibition_work_deadlines_v2(event_id);
  perform public.admin_process_exhibition_smartphone_deadlines_v1(event_id);
  if exists(select 1 from public.exhibition_works work_row where work_row.id=any(array[regular_member,regular_proxy]) and work_row.workflow_state<>'draft')
     or exists(select 1 from public.exhibition_smartphone_works work_row where work_row.id=any(array[phone_member,phone_proxy]) and work_row.workflow_state<>'draft') then
    raise exception '有効な救済対象Draftが期限処理で変更されました。';
  end if;
  if (select workflow_state from public.exhibition_works where id=unprotected_work)<>'withdrawn'
     or (select application_state from public.exhibition_entries where id=entries[6])<>'auto_cancelled' then
    raise exception '救済対象外DraftまたはApplicationが通常期限処理へ戻っていません。';
  end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[1],'role','authenticated')::text,true);
  result:=public.submit_exhibition_work_batch_v2(event_id,array[regular_member]);
  regular_snapshot:=(select current_submission_snapshot_id from public.exhibition_works where id=regular_member);
  if (select state from public.exhibition_draft_rescue_targets where id=regular_target)<>'consumed' then raise exception '通常作品本人Targetが消費されません。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',emails[2],'role','authenticated')::text,true);
  result:=public.submit_exhibition_smartphone_work_v1(phone_member,smartphone_agreement_id,smartphone_agreement_hash);
  phone_snapshot:=(result->>'snapshotId')::uuid;
  if (select state from public.exhibition_draft_rescue_targets where id=phone_target)<>'consumed' then raise exception 'スマホ作品本人Targetが消費されません。'; end if;

  perform set_config('request.jwt.claims',jsonb_build_object('email',operator_email,'role','authenticated')::text,true);
  perform public.admin_proxy_submit_regular_draft_rescue_v1(regular_proxy_target);
  perform public.admin_proxy_submit_smartphone_draft_rescue_v1(phone_proxy_target);
  if exists(select 1 from public.exhibition_draft_rescue_targets target_row
    where target_row.id=any(array[regular_proxy_target,phone_proxy_target]) and target_row.state<>'consumed') then
    raise exception '代理登録Targetが消費されません。';
  end if;
  begin
    perform public.admin_proxy_submit_regular_draft_rescue_v1(regular_proxy_target);
    raise exception '代理登録を二重実行できました。';
  exception when others then if sqlerrm='代理登録を二重実行できました。' then raise; end if; end;
  if not exists(select 1 from public.exhibition_draft_rescue_attempts attempt_row
    where attempt_row.target_id=regular_proxy_target and attempt_row.operation_type='admin_proxy_submit'
      and attempt_row.succeeded and attempt_row.result_snapshot_id is not null) then
    raise exception '代理登録の成功履歴がありません。';
  end if;
  begin
    update public.exhibition_work_submission_snapshots set title='改変' where id=regular_snapshot;
    raise exception '通常作品Snapshotを変更できました。';
  exception when others then if sqlerrm='通常作品Snapshotを変更できました。' then raise; end if; end;
  begin
    update public.exhibition_smartphone_work_submission_snapshots set orientation='landscape' where id=phone_snapshot;
    raise exception 'スマホ作品Snapshotを変更できました。';
  exception when others then if sqlerrm='スマホ作品Snapshotを変更できました。' then raise; end if; end;
end $$;

rollback;
