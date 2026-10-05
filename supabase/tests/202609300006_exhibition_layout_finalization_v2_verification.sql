-- Phase 6 Layout Finalization verification。全変更はROLLBACKされる。
begin;

do $$
<<v>>
declare
  admin_email text; member_id uuid; event_id uuid; entry_id uuid; venue_id uuid; wall_id uuid; layout1 uuid; layout2 uuid; layout3 uuid;
  a uuid; b uuid; c uuid; d uuid; pending uuid; a1 uuid; a2 uuid; b1 uuid; c1 uuid; d1 uuid;
  cap1 uuid; cap2 uuid; final1 uuid; final2 uuid; final3 uuid; placement_a uuid; result jsonb; audit_count integer;
  agreement_id uuid; agreement_hash text; path_a text; path_b text; path_c text; path_pending text; path_d text;
begin
  select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
  if admin_email is null then raise exception 'active Adminが必要です。'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  insert into public.members(member_no,email,name,grade,active) values('member-996001','__phase6_member__@example.invalid','Phase 6検証','B3',true) returning id into member_id;
  insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
  insert into public.exhibition_venues(name) values('__phase6_venue__') returning id into venue_id;
  insert into public.exhibition_walls(venue_id,name,display_order,width_mm,height_mm) values(venue_id,'Wall',1,5000,3000) returning id into wall_id;
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by,exhibition_venue_id)
  values('saved',true,'exhibition','__phase6_v2__','Phase 6',now()+interval '10 days',now()+interval '11 days',
    '検証会場',admin_email,now()+interval '1 day',10,1,'[{"id":"test","label":"test"}]'::jsonb,admin_email,venue_id)
  returning id into event_id;
  perform public.admin_activate_exhibition_workflow_v2(event_id,now()+interval '1 day',now()+interval '2 days',now()+interval '3 days',now()+interval '4 days','phase6','Agreement','検証');
  select agreement.id,agreement.content_hash into agreement_id,agreement_hash
    from public.exhibition_agreement_definitions agreement where agreement.event_id=v.event_id and agreement.active;
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  result:=public.submit_exhibition_application_v2(event_id,5,'real_name','','',agreement_id,agreement_hash);
  entry_id:=(result->>'entryId')::uuid;

  -- A/B/Cは正式提出後にaccepted、Pendingはsubmittedのままにする。
  result:=public.save_exhibition_work_draft_v2(event_id,null,'A','portrait','A3','',297,420,true,null,null); a:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'B','landscape','A3','',420,297,true,null,null); b:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'C','portrait','A3','',297,420,true,null,null); c:=(result->>'id')::uuid;
  result:=public.save_exhibition_work_draft_v2(event_id,null,'Pending','portrait','A3','',297,420,true,null,null); pending:=(result->>'id')::uuid;
  path_a:=event_id::text||'/'||member_id::text||'/'||a::text||'/a.jpg';
  path_b:=event_id::text||'/'||member_id::text||'/'||b::text||'/b.jpg';
  path_c:=event_id::text||'/'||member_id::text||'/'||c::text||'/c.jpg';
  path_pending:=event_id::text||'/'||member_id::text||'/'||pending::text||'/pending.jpg';
  insert into storage.objects(bucket_id,name,metadata) values
    ('exhibition-originals',path_a,'{"mimetype":"image/jpeg"}'),
    ('exhibition-originals',path_b,'{"mimetype":"image/jpeg"}'),
    ('exhibition-originals',path_c,'{"mimetype":"image/jpeg"}'),
    ('exhibition-originals',path_pending,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,a,'A','portrait','A3','',297,420,true,path_a,repeat('a',64));
  perform public.save_exhibition_work_draft_v2(event_id,b,'B','landscape','A3','',420,297,true,path_b,repeat('b',64));
  perform public.save_exhibition_work_draft_v2(event_id,c,'C','portrait','A3','',297,420,true,path_c,repeat('c',64));
  perform public.save_exhibition_work_draft_v2(event_id,pending,'Pending','portrait','A3','',297,420,true,path_pending,repeat('f',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[a,b,c,pending]);
  select work.current_submission_snapshot_id into a1 from public.exhibition_works work where work.id=a;
  select work.current_submission_snapshot_id into b1 from public.exhibition_works work where work.id=b;
  select work.current_submission_snapshot_id into c1 from public.exhibition_works work where work.id=c;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(a1,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(b1,'accepted','{}','',null);
  perform public.admin_review_exhibition_work_v2(c1,'accepted','{}','',null);

  insert into public.exhibition_layouts(event_id,name,version_no,status,is_current,created_by) values(event_id,'Main',1,'draft',true,admin_email) returning id into layout1;
  -- nonaccepted Workはv2 Placementへ入らない。
  begin insert into public.exhibition_placements(layout_id,work_id,wall_id,top_from_floor_mm,viewing_order) values(layout1,pending,wall_id,2000,4);
    raise exception 'nonaccepted Workを配置できました。'; exception when others then if sqlerrm='nonaccepted Workを配置できました。' then raise; end if; end;
  -- B,A,Cの明示順。
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order) values
    (layout1,b,wall_id,0,2000,1),(layout1,a,wall_id,600,2000,2),(layout1,c,wall_id,1200,2000,3);
  select placement.id into placement_a from public.exhibition_placements placement where placement.layout_id=layout1 and placement.work_id=a;
  if (select placement.accepted_work_snapshot_id from public.exhibition_placements placement where placement.id=placement_a) is distinct from a1 then raise exception 'PlacementがA1を参照していません。'; end if;
  -- 順序不足では確定全体がrollbackされ、採番も残らない。
  update public.exhibition_placements placement set viewing_order=null where placement.layout_id=layout1 and placement.work_id=c;
  begin perform public.admin_finalize_exhibition_layout_v2(layout1,'invalid'); raise exception '鑑賞順不足で確定できました。';
    exception when others then if sqlerrm='鑑賞順不足で確定できました。' then raise; end if; end;
  if exists(select 1 from public.exhibition_layout_finalizations finalization where finalization.layout_id=layout1)
    or exists(select 1 from public.exhibition_work_display_numbers display_number where display_number.event_id=v.event_id) then raise exception '失敗した確定が原子的にrollbackされませんでした。'; end if;
  update public.exhibition_placements placement set viewing_order=3 where placement.layout_id=layout1 and placement.work_id=c;
  -- Captionは未作成でも物理Layoutを確定可能。
  result:=public.admin_finalize_exhibition_layout_v2(layout1,'初回'); final1:=(result->>'finalizationId')::uuid;
  if (select work.display_no from public.exhibition_works work where work.id=b)<>'1' or (select work.display_no from public.exhibition_works work where work.id=a)<>'2' or (select work.display_no from public.exhibition_works work where work.id=c)<>'3' then raise exception '鑑賞順からdisplay_noが割り当てられませんでした。'; end if;
  if (select count(distinct item.display_no) from public.exhibition_layout_finalization_items item where item.finalization_id=final1)<>3 then raise exception 'display_noが一意ではありません。'; end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.work_id=a and item.work_submission_snapshot_id=a1)
     or not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.work_id=b and item.work_submission_snapshot_id=b1)
     or not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.work_id=c and item.work_submission_snapshot_id=c1)
  then raise exception '初回確定がexact Accepted Work Snapshotを参照していません。'; end if;
  begin update public.exhibition_layout_finalization_items item set x_mm=99 where item.finalization_id=final1; raise exception '確定履歴を変更できました。'; exception when others then if sqlerrm='確定履歴を変更できました。' then raise; end if; end;
  begin update public.exhibition_works work set display_no='99' where work.id=a; raise exception 'v2 display_noを変更できました。'; exception when others then if sqlerrm='v2 display_noを変更できました。' then raise; end if; end;
  begin perform public.admin_set_exhibition_layout_status(layout1,'draft'); raise exception '確定済みv2 Layoutを下書きへ戻せました。'; exception when others then if sqlerrm='確定済みv2 Layoutを下書きへ戻せました。' then raise; end if; end;

  -- titleのみのA2は物理再確認不要。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_work_reedit_v2(a,'作品名のみ変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2((result->>'caseId')::uuid,true,'検証',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(event_id,a,'A title only','portrait','A3','',297,420,true,path_a,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[a]);
  select work.current_submission_snapshot_id into a2 from public.exhibition_works work where work.id=a;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(a2,'accepted','{}','',null);
  if private.layout_requires_physical_reconfirmation_v2(event_id) then raise exception 'title-only変更で物理再確認が必要になりました。'; end if;
  -- Captionのみの変更も物理Layoutへ影響しない。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A','organizer','','digital','','Camera','','','unnecessary','','','none','',null);
  result:=public.submit_exhibition_caption_v2(a); cap1:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(cap1,'accepted','{}','',null);
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_caption_reedit_v2(a,'Captionのみ変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_caption_reedit_v2((result->>'caseId')::uuid,true,'検証',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_caption_draft_v2(a,'作者A','organizer','','digital','','Camera','','','provided','Caption only','','none','',null);
  result:=public.submit_exhibition_caption_v2(a); cap2:=(result->>'snapshotId')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_caption_v2(cap2,'accepted','{}','',null);
  if private.layout_requires_physical_reconfirmation_v2(event_id) then raise exception 'Caption-only変更で物理再確認が必要になりました。'; end if;
  -- A3を物理変更Snapshotとして正式提出・確認するとattention。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  result:=public.request_exhibition_work_reedit_v2(a,'物理仕様変更');
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_decide_exhibition_work_reedit_v2((result->>'caseId')::uuid,true,'検証',now()+interval '1 day');
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  perform public.save_exhibition_work_draft_v2(event_id,a,'A physical','landscape','A3','',420,297,true,path_a,repeat('a',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[a]);
  select work.current_submission_snapshot_id into a2 from public.exhibition_works work where work.id=a;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(a2,'accepted','{}','',null);
  if not private.layout_requires_physical_reconfirmation_v2(event_id) then raise exception '物理変更が検出されません。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_layout_actions_v2(event_id) action where action.action_type='layout_reconfirmation_required' and action.work_id=a) then raise exception 'Action CenterにLayout注意がありません。'; end if;
  result:=public.admin_clone_exhibition_layout(layout1); layout2:=(result->>'layoutId')::uuid;
  select placement.id into placement_a from public.exhibition_placements placement where placement.layout_id=layout2 and placement.work_id=a;
  perform public.admin_refresh_exhibition_placement_snapshot_v2(placement_a);
  update public.exhibition_placements placement set x_mm=650 where placement.id=placement_a;
  result:=public.admin_finalize_exhibition_layout_v2(layout2,'A物理仕様変更'); final2:=(result->>'finalizationId')::uuid;
  if (select work.display_no from public.exhibition_works work where work.id=a)<>'2' or (select work.display_no from public.exhibition_works work where work.id=b)<>'1' or (select work.display_no from public.exhibition_works work where work.id=c)<>'3' then raise exception '再確定で既存番号が変わりました。'; end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final1 and item.work_id=a and item.work_submission_snapshot_id=a1) then raise exception 'A1確定履歴が失われました。'; end if;
  if not exists(select 1 from public.exhibition_layout_finalization_items item where item.finalization_id=final2 and item.work_id=a and item.work_submission_snapshot_id=a2) then raise exception 'A2再確定履歴がありません。'; end if;

  -- Dは新UUID・新番号。旧番号を継承・再利用しない。
  perform set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
  result:=public.start_exhibition_work_replacement_v2(a); d:=(result->>'replacementWorkId')::uuid;
  path_d:=event_id::text||'/'||member_id::text||'/'||d::text||'/d.jpg';
  insert into storage.objects(bucket_id,name,metadata) values('exhibition-originals',path_d,'{"mimetype":"image/jpeg"}');
  perform public.save_exhibition_work_draft_v2(event_id,d,'D','portrait','A3','',297,420,true,path_d,repeat('f',64));
  perform public.submit_exhibition_work_batch_v2(event_id,array[d]);
  select work.current_submission_snapshot_id into d1 from public.exhibition_works work where work.id=d;
  perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
  perform public.admin_review_exhibition_work_v2(d1,'accepted','{}','',null);
  if (select work.display_no from public.exhibition_works work where work.id=d)<>'' then raise exception 'Dが既存番号を継承しました。'; end if;
  if not exists(select 1 from public.admin_get_exhibition_layout_actions_v2(event_id) action where action.action_type in ('layout_unplaced','layout_reconfirmation_required') and action.work_id=d) then raise exception '新規DのLayout attentionがありません。'; end if;
  result:=public.admin_clone_exhibition_layout(layout2); layout3:=(result->>'layoutId')::uuid;
  if exists(select 1 from public.exhibition_placements placement where placement.layout_id=layout3 and placement.work_id=a) then raise exception 'withdrawn旧Workが次版へ複製されました。'; end if;
  insert into public.exhibition_placements(layout_id,work_id,wall_id,x_mm,top_from_floor_mm,viewing_order) values(layout3,d,wall_id,1800,2000,4);
  result:=public.admin_finalize_exhibition_layout_v2(layout3,'D追加'); final3:=(result->>'finalizationId')::uuid;
  if (select work.display_no from public.exhibition_works work where work.id=d)<>'4' or (select work.display_no from public.exhibition_works work where work.id=a)<>'2' then raise exception 'D追加で番号履歴が壊れました。'; end if;
  if exists(select 1 from public.admin_get_exhibition_layout_actions_v2(event_id) action where action.work_id=d and action.action_type in ('layout_unplaced','layout_reconfirmation_required')) then raise exception 'D確定後もattentionが残っています。'; end if;
  select count(*) into audit_count from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action in ('layout_finalized','layout_reconfirmed');
  if audit_count<>3 then raise exception 'Layout finalization Auditが不足しています。'; end if;
  if (select count(*) from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='display_no_assigned')<>4 then raise exception 'display_no採番Auditが不足しています。'; end if;
end $$;

-- MemberはFinalization・履歴変更不可。
select set_config('request.jwt.claims',jsonb_build_object('email','__phase6_member__@example.invalid','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  begin perform public.admin_finalize_exhibition_layout_v2(gen_random_uuid(),'forged'); raise exception 'MemberがLayoutを確定できました。'; exception when others then if sqlerrm='MemberがLayoutを確定できました。' then raise; end if; end;
  begin update public.exhibition_layout_finalization_items item set display_no=999; raise exception 'Memberが確定履歴を変更できました。'; exception when insufficient_privilege then null; end;
  update public.exhibition_placements placement set x_mm=placement.x_mm+1;
  if found then raise exception 'MemberがPlacementを変更できました。'; end if;
end $$;
reset role;

-- v1 display_noは従来どおりPhase 6 triggerの対象外。
select set_config('request.jwt.claims',jsonb_build_object('email',(select admin.email from public.admins admin where admin.active order by admin.created_at limit 1),'role','authenticated')::text,true);
do $$ declare eid uuid; mid uuid; enid uuid; wid uuid;
begin
  select member.id into mid from public.members member where member.email='__phase6_member__@example.invalid';
  insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,
    registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
  values('draft',false,'exhibition','__phase6_v1__','Phase 6 Legacy検証',now()+interval '10 days',now()+interval '11 days',
    '検証会場','test',now()+interval '1 day',3,1,'[{"id":"test","label":"test"}]'::jsonb,'test')
  returning id into eid;
  insert into public.exhibition_entries(event_id,member_id,status) values(eid,mid,'draft') returning id into enid;
  insert into public.exhibition_works(entry_id,event_id,owner_member_id,sort_order,title,status) values(enid,eid,mid,1,'Legacy','draft') returning id into wid;
  update public.exhibition_works work set display_no='L-1' where work.id=wid;
  if (select work.display_no from public.exhibition_works work where work.id=wid)<>'L-1' then raise exception 'v1採番が壊れました。'; end if;
end $$;

rollback;
