-- 全体会・合宿・写真展に共通の申込締切。

alter table public.events
  add column if not exists registration_deadline timestamptz;

alter table public.events
  drop constraint if exists events_registration_deadline_check;
alter table public.events
  add constraint events_registration_deadline_check check (
    registration_deadline is null
    or starts_at is null
    or registration_deadline <= starts_at
  );

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
  if new.status = 'draft' then return new; end if;
  if new.starts_at is null or trim(new.place) = '' or trim(new.contact) = '' then
    raise exception '日時、場所、企画幹部の連絡先は必須です。';
  end if;
  if new.registration_deadline is null then
    raise exception '申込締切は必須です。';
  end if;
  if new.registration_deadline > new.starts_at then
    raise exception '申込締切は開始日時以前にしてください。';
  end if;
  if new.ends_at is not null and new.ends_at < new.starts_at then
    raise exception '終了日時は開始日時以降にしてください。';
  end if;
  if new.genre = 'meeting' and new.subtype not in ('shooting', 'dining') then
    raise exception '全体会の種別を選択してください。';
  end if;
  if new.fee_enabled and new.fee < 0 then raise exception '費用を確認してください。'; end if;
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

create or replace function private.is_available_exhibition_event(target_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.events e
    where e.id = target_event_id
      and e.genre = 'exhibition' and e.status = 'saved' and e.published
      and e.deleted_at is null and e.registration_deadline is not null
      and now() <= e.registration_deadline
  )
$$;

create or replace function private.validate_event_response()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.events%rowtype;
  member_grade text;
  participant_count integer;
begin
  if new.member_id <> private.current_member_id() and not private.is_admin() then
    raise exception '本人以外の回答は登録できません。';
  end if;
  select * into target from public.events where id = new.event_id;
  if target.id is null or target.deleted_at is not null
     or not target.published or target.status <> 'saved' then
    raise exception 'この予定は現在受付していません。';
  end if;
  if not private.is_admin() and (
    target.registration_deadline is null or now() > target.registration_deadline
  ) then
    raise exception '申込受付は終了しました。';
  end if;
  if new.attendance = '不参加' then
    new.camera = false; new.disposable_camera = false; new.allergies = '';
    new.other_allergy = ''; new.agreement = false; new.payment_status = 'not_required';
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.event_id::text, 0));
  select upper(trim(member.grade)) into member_grade
  from public.members member where member.id = new.member_id and member.active;
  if member_grade is null then raise exception '有効な部員情報を確認できません。'; end if;
  if cardinality(target.eligible_grades) > 0
     and not member_grade = any(target.eligible_grades) then
    raise exception 'この予定は%の部員を参加対象としていません。', member_grade;
  end if;
  if target.participant_limit is not null then
    select count(*) into participant_count from public.event_responses response
    where response.event_id = new.event_id and response.attendance = '参加'
      and response.cancelled_at is null;
    if participant_count >= target.participant_limit then
      raise exception 'この予定は定員%名に達しています。', target.participant_limit;
    end if;
  end if;
  if target.genre = 'camp' and not new.agreement then
    raise exception '合宿の参加条件への同意が必要です。';
  end if;
  if (target.genre = 'camp' or target.subtype = 'dining') and trim(new.allergies) = '' then
    raise exception 'アレルギー情報を入力してください。';
  end if;
  if new.camera then
    if not target.camera_enabled then raise exception '貸出カメラは受け付けていません。'; end if;
    if (select count(*) from public.event_responses response
        where response.event_id = new.event_id and response.camera
          and response.cancelled_at is null) >= 3 then
      raise exception '貸出カメラは上限3台に達しました。';
    end if;
  end if;
  if new.disposable_camera and not target.disposable_enabled then
    raise exception '写るんですは受け付けていません。';
  end if;
  new.payment_status = case when target.fee > 0 then 'unpaid' else 'not_required' end;
  return new;
end;
$$;

create or replace function public.get_event_availability(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target public.events%rowtype;
  member_grade text;
  participant_count integer;
  grade_eligible boolean;
  registration_open boolean;
begin
  if not private.is_current_member() and not private.is_admin() then
    raise exception '現在有効な部員のみ確認できます。';
  end if;
  select * into target from public.events where id = p_event_id;
  if target.id is null or target.deleted_at is not null
     or not target.published or target.status <> 'saved' then
    raise exception 'この予定は現在受付していません。';
  end if;
  select upper(trim(member.grade)) into member_grade
  from public.members member
  where member.id = private.current_member_id() and member.active;
  select count(*) into participant_count from public.event_responses response
  where response.event_id = p_event_id and response.attendance = '参加'
    and response.cancelled_at is null;
  grade_eligible := cardinality(target.eligible_grades) = 0
    or member_grade = any(target.eligible_grades);
  registration_open := target.registration_deadline is not null
    and now() <= target.registration_deadline;
  return jsonb_build_object(
    'participantLimit', target.participant_limit,
    'participantCount', participant_count,
    'remaining', case when target.participant_limit is null then null
      else greatest(0, target.participant_limit - participant_count) end,
    'eligibleGrades', target.eligible_grades,
    'memberGrade', member_grade,
    'gradeEligible', grade_eligible,
    'registrationOpen', registration_open,
    'registrationDeadline', target.registration_deadline,
    'canParticipate', registration_open and grade_eligible and (
      target.participant_limit is null or participant_count < target.participant_limit
    )
  );
end;
$$;

revoke all on function public.get_event_availability(uuid) from public, anon;
grant execute on function public.get_event_availability(uuid) to authenticated;

select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'events'
      and column_name = 'registration_deadline'
  ) as registration_deadline_ready,
  to_regprocedure('public.get_event_availability(uuid)') is not null
    as availability_api_ready;
