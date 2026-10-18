-- Keep the row-level validation aligned with the independently managed shift deadline.
create or replace function private.validate_exhibition_shift_preference()
returns trigger language plpgsql security definer set search_path='' as $$
declare slots jsonb;
begin
  if not private.is_admin() then
    if new.member_id<>private.current_member_id() then raise exception '本人以外のシフト希望は登録できません。'; end if;
    if not private.is_current_member() then raise exception '現在有効な部員のみシフト希望を登録できます。'; end if;
    if not private.exhibition_shift_preference_is_open(new.event_id) then raise exception 'この写真展は現在シフト希望を受け付けていません。'; end if;
  end if;
  select e.shift_slots into slots from public.events e where e.id=new.event_id and e.genre='exhibition';
  if slots is null or not exists(select 1 from jsonb_array_elements(slots) slot where coalesce(slot->>'id',slot#>>'{}')=new.slot_id) then
    raise exception '指定されたシフト枠が見つかりません。';
  end if;
  return new;
end;$$;
revoke execute on function private.validate_exhibition_shift_preference() from public,anon,authenticated;
