-- 全体会・合宿の任意定員と参加可能学年。

alter table public.events
  add column if not exists participant_limit integer,
  add column if not exists eligible_grades text[] not null default '{}'::text[];

alter table public.events
  drop constraint if exists events_participant_limit_check,
  drop constraint if exists events_eligible_grades_check;

alter table public.events
  add constraint events_participant_limit_check
    check (participant_limit is null or participant_limit > 0),
  add constraint events_eligible_grades_check check (
    array_position(eligible_grades, null) is null
    and array_position(eligible_grades, '') is null
  );

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
  if new.attendance = '不参加' then
    new.camera = false;
    new.disposable_camera = false;
    new.allergies = '';
    new.other_allergy = '';
    new.agreement = false;
    new.payment_status = 'not_required';
    return new;
  end if;

  -- 定員とカメラ台数を、同じ予定単位のロック内で確定する。
  perform pg_advisory_xact_lock(hashtextextended(new.event_id::text, 0));

  select upper(trim(member.grade)) into member_grade
  from public.members member
  where member.id = new.member_id and member.active;
  if member_grade is null then
    raise exception '有効な部員情報を確認できません。';
  end if;
  if cardinality(target.eligible_grades) > 0
     and not member_grade = any(target.eligible_grades) then
    raise exception 'この予定は%の部員を参加対象としていません。', member_grade;
  end if;

  if target.participant_limit is not null then
    select count(*) into participant_count
    from public.event_responses response
    where response.event_id = new.event_id
      and response.attendance = '参加'
      and response.cancelled_at is null;
    if participant_count >= target.participant_limit then
      raise exception 'この予定は定員%名に達しています。', target.participant_limit;
    end if;
  end if;

  if target.genre = 'camp' and not new.agreement then
    raise exception '合宿の参加条件への同意が必要です。';
  end if;
  if (target.genre = 'camp' or target.subtype = 'dining')
     and trim(new.allergies) = '' then
    raise exception 'アレルギー情報を入力してください。';
  end if;
  if new.camera then
    if not target.camera_enabled then
      raise exception '貸出カメラは受け付けていません。';
    end if;
    if (
      select count(*) from public.event_responses response
      where response.event_id = new.event_id
        and response.camera and response.cancelled_at is null
    ) >= 3 then
      raise exception '貸出カメラは上限3台に達しました。';
    end if;
  end if;
  if new.disposable_camera and not target.disposable_enabled then
    raise exception '写るんですは受け付けていません。';
  end if;
  new.payment_status = case
    when target.fee > 0 then 'unpaid'
    else 'not_required'
  end;
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
  select count(*) into participant_count
  from public.event_responses response
  where response.event_id = p_event_id
    and response.attendance = '参加'
    and response.cancelled_at is null;
  grade_eligible := cardinality(target.eligible_grades) = 0
    or member_grade = any(target.eligible_grades);
  return jsonb_build_object(
    'participantLimit', target.participant_limit,
    'participantCount', participant_count,
    'remaining', case when target.participant_limit is null then null
      else greatest(0, target.participant_limit - participant_count) end,
    'eligibleGrades', target.eligible_grades,
    'memberGrade', member_grade,
    'gradeEligible', grade_eligible,
    'canParticipate', grade_eligible and (
      target.participant_limit is null
      or participant_count < target.participant_limit
    )
  );
end;
$$;

revoke all on function public.get_event_availability(uuid) from public, anon;
grant execute on function public.get_event_availability(uuid) to authenticated;

select
  (
    select count(*) = 2 from information_schema.columns
    where table_schema = 'public' and table_name = 'events'
      and column_name in ('participant_limit', 'eligible_grades')
  ) as participation_limit_fields_ready,
  to_regprocedure('public.get_event_availability(uuid)') is not null
    as availability_api_ready;
