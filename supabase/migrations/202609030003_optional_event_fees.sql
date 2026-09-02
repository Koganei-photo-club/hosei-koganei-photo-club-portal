alter table public.events
  add column if not exists fee_enabled boolean not null default false,
  add column if not exists payment_deadline_enabled boolean not null default false;

update public.events
set fee_enabled = fee > 0 or payment_deadline is not null,
    payment_deadline_enabled = payment_deadline is not null;

alter table public.events
  drop constraint if exists events_payment_deadline_requires_fee;
alter table public.events
  add constraint events_payment_deadline_requires_fee
  check (not payment_deadline_enabled or fee_enabled);

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

  if not (new.genre = 'camp' or (new.genre = 'meeting' and new.subtype = 'dining')) then
    new.fee_enabled = false;
    new.payment_deadline_enabled = false;
  end if;
  if not new.fee_enabled then
    new.fee = 0;
    new.payment_deadline_enabled = false;
    new.payment_deadline = null;
  elsif not new.payment_deadline_enabled then
    new.payment_deadline = null;
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
  if new.fee_enabled and new.fee < 0 then
    raise exception '費用を確認してください。';
  end if;
  if new.payment_deadline_enabled and new.payment_deadline is null then
    raise exception '支払期限を入力してください。';
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
