-- 写真展の出展申込締切とシフト希望締切を分離する。
alter table public.events add column if not exists exhibition_shift_preference_deadline timestamptz;

-- 適用時点の受付状態を変えないため、既存写真展は従来参照していた値を引き継ぐ。
update public.events set exhibition_shift_preference_deadline=registration_deadline
where genre='exhibition' and exhibition_shift_preference_deadline is null;

comment on column public.events.exhibition_shift_preference_deadline is
 '写真展のシフト希望提出期限。出展申込締切とは独立し、now() < deadline の間だけ提出可能。';

create or replace function private.validate_exhibition_shift_preference_deadline()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.genre='exhibition' then
  if new.exhibition_shift_preference_deadline is null and new.registration_deadline is not null then new.exhibition_shift_preference_deadline:=new.registration_deadline;end if;
  if new.exhibition_shift_preference_deadline is not null and new.starts_at is not null and new.exhibition_shift_preference_deadline>new.starts_at then raise exception 'シフト希望締切は開始日時以前にしてください。';end if;
 end if;
 return new;
end;$$;
create trigger events_validate_exhibition_shift_preference_deadline before insert or update of genre,starts_at,registration_deadline,exhibition_shift_preference_deadline on public.events for each row execute function private.validate_exhibition_shift_preference_deadline();

create or replace function private.protect_exhibition_shift_preference_deadline()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.exhibition_shift_preference_deadline is distinct from old.exhibition_shift_preference_deadline
    and not(old.exhibition_shift_preference_deadline is null and new.exhibition_shift_preference_deadline is not distinct from new.registration_deadline)
    and coalesce(current_setting('app.exhibition_shift_deadline_rpc',true),'')<>'on' then raise exception 'シフト希望締切は専用操作から変更してください。';end if;
 return new;
end;$$;
create trigger zzz_events_protect_exhibition_shift_preference_deadline before update of exhibition_shift_preference_deadline on public.events for each row execute function private.protect_exhibition_shift_preference_deadline();

create or replace function private.exhibition_shift_preference_is_open(p_event_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.events e where e.id=p_event_id and e.genre='exhibition' and e.status='saved' and e.published and e.deleted_at is null and e.exhibition_shift_preference_deadline is not null and now()<e.exhibition_shift_preference_deadline)
$$;

create or replace function public.admin_update_exhibition_shift_preference_deadline_v1(p_event_id uuid,p_deadline timestamptz,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.events%rowtype;actor text:=private.current_email();shortened boolean;
begin
 if not private.is_admin() then raise exception '管理者権限がありません。';end if;
 select * into target from public.events where id=p_event_id and genre='exhibition' and deleted_at is null for update;
 if target.id is null then raise exception '写真展が見つかりません。';end if;
 if p_deadline is null then raise exception 'シフト希望締切を入力してください。';end if;
 if target.starts_at is not null and p_deadline>target.starts_at then raise exception 'シフト希望締切は開始日時以前にしてください。';end if;
 shortened:=target.exhibition_shift_preference_deadline is not null and p_deadline<target.exhibition_shift_preference_deadline;
 if shortened and trim(coalesce(p_reason,''))='' then raise exception 'シフト希望締切を短縮する場合は理由が必須です。';end if;
 perform set_config('app.exhibition_shift_deadline_rpc','on',true);
 update public.events set exhibition_shift_preference_deadline=p_deadline,updated_at=now(),updated_by=actor where id=target.id;
 perform set_config('app.exhibition_shift_deadline_rpc','off',true);
 perform private.write_exhibition_workflow_audit(target.id,'event',target.id,'shift_preference_deadline_updated','admin',actor,p_reason,
  jsonb_build_object('shiftPreferenceDeadline',target.exhibition_shift_preference_deadline),jsonb_build_object('shiftPreferenceDeadline',p_deadline),jsonb_build_object('shortened',shortened));
 return jsonb_build_object('eventId',target.id,'shiftPreferenceDeadline',p_deadline,'shortened',shortened);
end;$$;

create or replace function public.save_my_exhibition_shift_preferences_v1(p_event_id uuid,p_preferences jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();item jsonb;slot jsonb;count_saved integer:=0;
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 if not private.exhibition_shift_preference_is_open(p_event_id) then raise exception 'この写真展は現在シフト希望を受け付けていません。';end if;
 if jsonb_typeof(coalesce(p_preferences,'[]'::jsonb))<>'array' then raise exception 'シフト希望の形式が不正です。';end if;
 delete from public.exhibition_shift_preferences where event_id=p_event_id and member_id=mid;
 for item in select value from jsonb_array_elements(coalesce(p_preferences,'[]'::jsonb)) loop
  if item->>'preference' not in('preferred','available','unavailable') then raise exception '希望区分が不正です。';end if;
  select value into slot from jsonb_array_elements((select shift_slots from public.events where id=p_event_id)) where coalesce(value->>'id',value#>>'{}')=item->>'slotId';
  if slot is null then raise exception '指定されたシフト枠が見つかりません。';end if;
  insert into public.exhibition_shift_preferences(event_id,member_id,slot_id,slot_label,preference,note) values(p_event_id,mid,item->>'slotId',coalesce(slot->>'label',slot#>>'{}'),item->>'preference',left(coalesce(item->>'note',''),1000));count_saved:=count_saved+1;
 end loop;
 return jsonb_build_object('eventId',p_event_id,'savedCount',count_saved);
end;$$;

create or replace function public.get_my_exhibition_shift_workspace_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare mid uuid:=private.current_member_id();e public.events%rowtype;v public.exhibition_shift_schedule_versions%rowtype;
begin
 if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。';end if;
 select * into e from public.events where id=p_event_id and genre='exhibition' and deleted_at is null;
 if e.id is null or e.status<>'saved' or not(private.exhibition_shift_preference_is_open(e.id) or exists(select 1 from public.exhibition_entries x where x.event_id=e.id and x.member_id=mid) or exists(select 1 from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid) or exists(select 1 from public.exhibition_shift_schedule_assignments a where a.schedule_version_id=e.current_exhibition_shift_schedule_version_id and a.member_id=mid)) then raise exception '対象の写真展を確認できません。';end if;
 select * into v from public.exhibition_shift_schedule_versions where id=e.current_exhibition_shift_schedule_version_id and state='published';
 return jsonb_build_object('eventId',e.id,'slots',e.shift_slots,'shiftPreferenceDeadline',e.exhibition_shift_preference_deadline,'canSubmitPreferences',private.exhibition_shift_preference_is_open(e.id),'preferences',coalesce((select jsonb_agg(to_jsonb(p) order by p.slot_label) from public.exhibition_shift_preferences p where p.event_id=e.id and p.member_id=mid),'[]'::jsonb),'publishedVersion',case when v.id is null then null else jsonb_build_object('id',v.id,'versionNo',v.version_no,'publishedAt',v.published_at) end,'assignments',coalesce((select jsonb_agg(jsonb_build_object('slotId',a.slot_id,'slotLabel',a.slot_label,'memberId',a.member_id,'memberName',m.name,'isMine',a.member_id=mid) order by a.slot_label,m.name) from public.exhibition_shift_schedule_assignments a join public.members m on m.id=a.member_id where a.schedule_version_id=v.id),'[]'::jsonb));
end;$$;

create or replace function public.admin_get_exhibition_shift_workspace_v1(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e public.events%rowtype;
begin if not private.is_admin() then raise exception '管理者権限がありません。';end if;select * into e from public.events where id=p_event_id and genre='exhibition';if e.id is null then raise exception '写真展が見つかりません。';end if;
 return jsonb_build_object('eventId',e.id,'slots',e.shift_slots,'minimumPeople',e.min_shift_people,'shiftPreferenceDeadline',e.exhibition_shift_preference_deadline,'shiftPreferencesOpen',private.exhibition_shift_preference_is_open(e.id),'currentPublishedVersionId',e.current_exhibition_shift_schedule_version_id,'preferences',coalesce((select jsonb_agg(jsonb_build_object('slotId',p.slot_id,'slotLabel',p.slot_label,'preference',p.preference,'note',p.note,'memberId',p.member_id,'memberName',m.name) order by p.slot_label,m.name) from public.exhibition_shift_preferences p join public.members m on m.id=p.member_id where p.event_id=e.id),'[]'::jsonb),'members',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'memberNo',m.member_no,'grade',m.grade) order by m.name) from public.members m where private.member_is_current_for_exhibition_shift(m.id)),'[]'::jsonb),'versions',coalesce((select jsonb_agg(to_jsonb(v) order by v.version_no desc) from public.exhibition_shift_schedule_versions v where v.event_id=e.id),'[]'::jsonb),'assignments',coalesce((select jsonb_agg(jsonb_build_object('versionId',a.schedule_version_id,'slotId',a.slot_id,'slotLabel',a.slot_label,'memberId',a.member_id,'memberName',m.name,'source',a.assignment_source) order by a.slot_label,m.name) from public.exhibition_shift_schedule_assignments a join public.members m on m.id=a.member_id where a.event_id=e.id),'[]'::jsonb));end;$$;

revoke all on function public.admin_update_exhibition_shift_preference_deadline_v1(uuid,timestamptz,text) from public,anon;
grant execute on function public.admin_update_exhibition_shift_preference_deadline_v1(uuid,timestamptz,text) to authenticated;
revoke execute on function private.validate_exhibition_shift_preference_deadline(),private.protect_exhibition_shift_preference_deadline(),private.exhibition_shift_preference_is_open(uuid) from public,anon,authenticated;
