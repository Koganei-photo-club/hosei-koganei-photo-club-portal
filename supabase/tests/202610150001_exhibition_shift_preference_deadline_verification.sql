-- シフト希望締切が出展申込締切から独立していることを検証する。全データはROLLBACKされる。
begin;
do $$
<<v>>
declare admin_email text;event_id uuid;member_id uuid;result jsonb;
begin
 select admin.email into admin_email from public.admins admin where admin.active order by admin.created_at limit 1;
 if admin_email is null then raise exception '検証にはactive Adminが必要です。';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 insert into public.members(member_no,email,name,grade,active) values('member-999151','__shift_deadline__@example.invalid','シフト締切検証部員','B2',true) returning id into member_id;
 insert into public.membership_years(member_id,fiscal_year,active) values(member_id,private.current_fiscal_year(),true);
 insert into public.events(status,published,genre,title,exhibition_title,starts_at,ends_at,place,contact,registration_deadline,max_works,min_shift_people,shift_slots,updated_by)
 values('saved',true,'exhibition','__shift_deadline_verification__','シフト締切分離検証展',now()+interval '10 days',now()+interval '11 days','検証会場',admin_email,now()+interval '1 day',3,1,'[{"id":"slot-1","label":"検証枠"}]'::jsonb,admin_email) returning id into event_id;
 if (select event.exhibition_shift_preference_deadline from public.events event where event.id=v.event_id) is distinct from (select event.registration_deadline from public.events event where event.id=v.event_id) then raise exception '新規写真展のシフト希望締切初期値が申込締切から継承されません。';end if;
 result:=public.admin_update_exhibition_shift_preference_deadline_v1(event_id,now()+interval '2 days','検証延長');
 if result->>'shiftPreferenceDeadline' is null or not exists(select 1 from public.exhibition_workflow_audit_logs audit where audit.event_id=v.event_id and audit.action='shift_preference_deadline_updated') then raise exception 'シフト希望締切の更新またはAuditが不正です。';end if;
 update public.events set registration_deadline=now()-interval '1 hour' where id=event_id;
 if private.is_available_exhibition_event(event_id) then raise exception '出展申込が再開しています。';end if;
 if not private.exhibition_shift_preference_is_open(event_id) then raise exception '独立したシフト希望受付が開いていません。';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_deadline__@example.invalid','role','authenticated')::text,true);
 perform public.save_my_exhibition_shift_preferences_v1(event_id,'[{"slotId":"slot-1","preference":"preferred","note":""}]'::jsonb);
 if not exists(select 1 from public.exhibition_shift_preferences preference where preference.event_id=v.event_id and preference.member_id=v.member_id) then raise exception '申込締切後に独立したシフト希望を保存できません。';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('email',admin_email,'role','authenticated')::text,true);
 begin update public.events set exhibition_shift_preference_deadline=now()+interval '3 days' where id=event_id;raise exception '専用RPCを介さずシフト希望締切を変更できました。';exception when others then if sqlerrm='専用RPCを介さずシフト希望締切を変更できました。' then raise;end if;end;
 begin perform public.admin_update_exhibition_shift_preference_deadline_v1(event_id,now()+interval '1 day','');raise exception '理由なしでシフト希望締切を短縮できました。';exception when others then if sqlerrm='理由なしでシフト希望締切を短縮できました。' then raise;end if;end;
 perform public.admin_update_exhibition_shift_preference_deadline_v1(event_id,now()-interval '1 minute','受付終了');
 perform set_config('request.jwt.claims',jsonb_build_object('email','__shift_deadline__@example.invalid','role','authenticated')::text,true);
 if (public.get_my_exhibition_shift_workspace_v1(event_id)->>'canSubmitPreferences')::boolean then raise exception '締切後もシフト希望受付が開いています。';end if;
 begin perform public.save_my_exhibition_shift_preferences_v1(event_id,'[]'::jsonb);raise exception '締切後にシフト希望を保存できました。';exception when others then if sqlerrm='締切後にシフト希望を保存できました。' then raise;end if;end;
end $$;
select to_regprocedure('public.admin_update_exhibition_shift_preference_deadline_v1(uuid,timestamptz,text)') is not null as admin_deadline_rpc_ready,to_regprocedure('private.exhibition_shift_preference_is_open(uuid)') is not null as shift_deadline_check_ready;
rollback;
