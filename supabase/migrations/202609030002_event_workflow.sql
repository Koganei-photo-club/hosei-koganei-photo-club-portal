create or replace function private.validate_event_configuration()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if trim(new.title) = '' then
    raise exception '予定名は必須です。';
  end if;
  if new.status = 'draft' then
    return new;
  end if;
  if new.starts_at is null or trim(new.place) = '' or trim(new.contact) = '' then
    raise exception '日時、場所、企画幹部の連絡先は必須です。';
  end if;
  if new.ends_at is not null and new.ends_at < new.starts_at then
    raise exception '終了日時は開始日時以降にしてください。';
  end if;
  if new.genre = 'meeting' and new.subtype not in ('shooting', 'dining') then
    raise exception '全体会の種別を選択してください。';
  end if;
  if new.genre = 'camp' and (new.payment_deadline is null or new.fee < 0) then
    raise exception '合宿の費用と支払期限は必須です。';
  end if;
  if new.genre = 'exhibition' and (
    trim(new.exhibition_title) = '' or new.max_works < 1
    or new.min_shift_people < 1 or jsonb_array_length(new.shift_slots) < 1
  ) then
    raise exception '写真展タイトル、出展可能作品数、シフト枠、最低必要人数は必須です。';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_event_configuration_before_write on public.events;
create trigger validate_event_configuration_before_write
before insert or update on public.events
for each row execute function private.validate_event_configuration();

create or replace function public.get_camera_remaining(p_event_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  target public.events%rowtype;
  reserved integer;
begin
  if not private.is_current_member() and not private.is_admin() then
    raise exception '現在有効な部員のみ確認できます。';
  end if;
  select * into target from public.events where id = p_event_id;
  if target.id is null or target.deleted_at is not null or not target.published or target.status <> 'saved' then
    raise exception 'この予定は現在受付していません。';
  end if;
  if not target.camera_enabled then return 0; end if;
  select count(*) into reserved
  from public.event_responses
  where event_id = p_event_id and camera and cancelled_at is null;
  return greatest(0, 3 - reserved);
end;
$$;

revoke all on function public.get_camera_remaining(uuid) from public;
grant execute on function public.get_camera_remaining(uuid) to authenticated;

create or replace function private.validate_event_response()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target public.events%rowtype;
begin
  if new.member_id <> private.current_member_id() and not private.is_admin() then
    raise exception '本人以外の回答は登録できません。';
  end if;
  select * into target from public.events where id=new.event_id;
  if target.id is null or target.deleted_at is not null or not target.published or target.status <> 'saved' then
    raise exception 'この予定は現在受付していません。';
  end if;
  if new.attendance='不参加' then
    new.camera=false;new.disposable_camera=false;new.allergies='';new.other_allergy='';new.agreement=false;new.payment_status='not_required';
    return new;
  end if;
  if target.genre='camp' and not new.agreement then raise exception '合宿の参加条件への同意が必要です。'; end if;
  if (target.genre='camp' or target.subtype='dining') and trim(new.allergies)='' then raise exception 'アレルギー情報を入力してください。'; end if;
  if new.camera then
    perform pg_advisory_xact_lock(hashtextextended(new.event_id::text, 0));
    if not target.camera_enabled then raise exception '貸出カメラは受け付けていません。'; end if;
    if (select count(*) from public.event_responses r where r.event_id=new.event_id and r.camera and r.cancelled_at is null) >= 3 then raise exception '貸出カメラは上限3台に達しました。'; end if;
  end if;
  if new.disposable_camera and not target.disposable_enabled then raise exception '写るんですは受け付けていません。'; end if;
  new.payment_status=case when target.fee>0 then 'unpaid' else 'not_required' end;
  return new;
end;
$$;
