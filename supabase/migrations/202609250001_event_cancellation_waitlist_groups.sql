-- 本人・管理者キャンセル、キャンセル待ち、手動通知、班分け。
-- 写真展は班分け対象外。メール送信基盤は接続せず、通知文を管理画面で扱う。

alter table public.events
  add column if not exists self_cancellation_enabled boolean not null default true,
  add column if not exists waitlist_enabled boolean not null default true,
  add column if not exists waitlist_registration_deadline timestamptz,
  add column if not exists waitlist_promotion_deadline timestamptz,
  add column if not exists waitlist_response_final_deadline timestamptz,
  add column if not exists waitlist_response_hours integer not null default 24
    check (waitlist_response_hours between 1 and 168);

alter table public.event_responses
  add column if not exists individual_payment_deadline timestamptz;

create table if not exists public.event_participation_history (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  response_id uuid references public.event_responses(id) on delete set null,
  action text not null,
  actor_type text not null check (actor_type in ('member','admin','system')),
  actor_email text not null default '',
  reason text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create table if not exists public.event_waitlist_entries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  status text not null check (status in ('waiting','withdrawn','offered','accepted','declined','expired')),
  joined_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  resolved_at timestamptz,
  registration_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists event_waitlist_one_active_member_idx
  on public.event_waitlist_entries(event_id, member_id)
  where status in ('waiting','offered');
create index if not exists event_waitlist_fifo_idx
  on public.event_waitlist_entries(event_id, status, joined_at, id);

create table if not exists public.event_waitlist_offers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  waitlist_entry_id uuid not null references public.event_waitlist_entries(id) on delete restrict,
  member_id uuid not null references public.members(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','accepted','declined','expired')),
  offered_at timestamptz not null default now(),
  response_deadline timestamptz not null,
  responded_at timestamptz,
  notification_status text not null default 'manual_pending'
    check (notification_status in ('manual_pending','manual_done')),
  notification_sent_at timestamptz,
  notification_sent_by text not null default '',
  created_at timestamptz not null default now()
);
create unique index if not exists event_waitlist_one_pending_offer_idx
  on public.event_waitlist_offers(event_id, member_id) where status = 'pending';

create table if not exists public.event_group_assignments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null unique references public.events(id) on delete restrict,
  current_version_id uuid,
  published_version_id uuid,
  is_published boolean not null default false,
  created_by text not null default '', updated_by text not null default '',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.event_group_versions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.event_group_assignments(id) on delete cascade,
  version_number integer not null,
  save_type text not null check (save_type in ('draft','saved')),
  group_count integer not null check (group_count > 0),
  groups jsonb not null,
  participant_ids uuid[] not null default '{}',
  created_by text not null default '', created_at timestamptz not null default now(),
  unique(assignment_id, version_number)
);
alter table public.event_group_assignments
  drop constraint if exists event_group_assignments_current_version_fk,
  add constraint event_group_assignments_current_version_fk foreign key(current_version_id) references public.event_group_versions(id),
  drop constraint if exists event_group_assignments_published_version_fk,
  add constraint event_group_assignments_published_version_fk foreign key(published_version_id) references public.event_group_versions(id);
create table if not exists public.event_group_publication_history (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.event_group_assignments(id) on delete cascade,
  version_id uuid references public.event_group_versions(id),
  action text not null check (action in ('published','unpublished')),
  operated_by text not null, operated_at timestamptz not null default now()
);

create or replace function private.event_lock(p_event_id uuid) returns void
language sql volatile security definer set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));
$$;

create or replace function private.event_final_payment_boundary(p_event public.events)
returns timestamptz language sql stable set search_path = '' as $$
  select (((coalesce(p_event.ends_at, p_event.starts_at) at time zone 'Asia/Tokyo')::date + 1)::timestamp
    at time zone 'Asia/Tokyo');
$$;

create or replace function private.create_next_waitlist_offer(p_event_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare e public.events%rowtype; w public.event_waitlist_entries%rowtype; offer_id uuid;
  confirmed integer; reserved integer; deadline timestamptz;
begin
  select * into e from public.events where id=p_event_id;
  if e.id is null or e.participant_limit is null or not e.waitlist_enabled
     or e.waitlist_promotion_deadline is null or now()>e.waitlist_promotion_deadline then return null; end if;
  select count(*) into confirmed from public.event_responses r
    where r.event_id=p_event_id and r.attendance='参加' and r.cancelled_at is null;
  select count(*) into reserved from public.event_waitlist_offers o
    where o.event_id=p_event_id and o.status='pending' and o.response_deadline>=now();
  if confirmed+reserved>=e.participant_limit then return null; end if;
  select * into w from public.event_waitlist_entries
    where event_id=p_event_id and status='waiting' order by joined_at,id for update skip locked limit 1;
  if w.id is null then return null; end if;
  deadline:=least(now()+make_interval(hours=>e.waitlist_response_hours),e.waitlist_response_final_deadline);
  if deadline<=now() then return null; end if;
  update public.event_waitlist_entries set status='offered' where id=w.id;
  insert into public.event_waitlist_offers(event_id,waitlist_entry_id,member_id,response_deadline)
    values(p_event_id,w.id,w.member_id,deadline) returning id into offer_id;
  insert into public.event_participation_history(event_id,member_id,action,actor_type,reason,metadata)
    values(p_event_id,w.member_id,'waitlist_offered','system','空席発生による繰上げ',jsonb_build_object('offerId',offer_id,'responseDeadline',deadline));
  return offer_id;
end $$;

create or replace function private.validate_event_response()
returns trigger language plpgsql security definer set search_path='' as $$
declare target public.events%rowtype; member_grade text; participant_count integer;
  offer_accept boolean:=coalesce(current_setting('app.waitlist_offer_accept',true),'')='on';
begin
  if new.member_id<>private.current_member_id() and not private.is_admin() then raise exception '本人以外の回答は登録できません。'; end if;
  select * into target from public.events where id=new.event_id;
  if target.id is null or target.deleted_at is not null or not target.published or target.status<>'saved' then raise exception 'この予定は現在受付していません。'; end if;
  if not offer_accept and not private.is_admin() and (target.registration_deadline is null or now()>target.registration_deadline) then raise exception '申込受付は終了しました。'; end if;
  if new.attendance='不参加' then new.camera=false;new.disposable_camera=false;new.allergies='';new.other_allergy='';new.agreement=false;new.payment_status='not_required';return new; end if;
  perform private.event_lock(new.event_id);
  select upper(trim(m.grade)) into member_grade from public.members m where m.id=new.member_id and m.active;
  if member_grade is null then raise exception '有効な部員情報を確認できません。'; end if;
  if cardinality(target.eligible_grades)>0 and not member_grade=any(target.eligible_grades) then raise exception 'この予定は%の部員を参加対象としていません。',member_grade; end if;
  if target.participant_limit is not null then select count(*) into participant_count from public.event_responses r where r.event_id=new.event_id and r.attendance='参加' and r.cancelled_at is null;
    if participant_count>=target.participant_limit then raise exception 'この予定は定員%名に達しています。',target.participant_limit; end if; end if;
  if target.genre='camp' and not new.agreement and not offer_accept then raise exception '合宿の参加条件への同意が必要です。'; end if;
  if (target.genre='camp' or target.subtype='dining') and trim(new.allergies)='' and not offer_accept then raise exception 'アレルギー情報を入力してください。'; end if;
  if new.camera and not target.camera_enabled then raise exception '貸出カメラは受け付けていません。'; end if;
  if new.disposable_camera and not target.disposable_enabled then raise exception '写るんですは受け付けていません。'; end if;
  new.payment_status:=case when target.fee_enabled and target.fee>0 then 'unpaid' else 'not_required' end; return new;
end $$;

create or replace function public.submit_event_response(p_event_id uuid,p_attendance text,p_line_name text,
  p_camera boolean default false,p_disposable_camera boolean default false,p_allergies text default '',
  p_other_allergy text default '',p_note text default '',p_agreement boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; mid uuid; cnt integer; rid uuid;
begin
  mid:=private.current_member_id(); if mid is null or not private.is_current_member() then raise exception '有効な部員登録が必要です。'; end if;
  perform private.event_lock(p_event_id); select * into e from public.events where id=p_event_id;
  if e.id is null or e.deleted_at is not null or not e.published or e.status<>'saved' or now()>e.registration_deadline then raise exception '申込受付は終了しました。'; end if;
  if exists(select 1 from public.event_responses where event_id=p_event_id and member_id=mid) then raise exception 'この予定には回答済みです。'; end if;
  if p_attendance='参加' and e.participant_limit is not null then
    select count(*) into cnt from public.event_responses where event_id=p_event_id and attendance='参加' and cancelled_at is null;
    cnt:=cnt+(select count(*) from public.event_waitlist_offers where event_id=p_event_id and status='pending' and response_deadline>=now());
    if cnt>=e.participant_limit then raise exception 'この予定は定員に達しています。キャンセル待ちをご利用ください。'; end if;
  end if;
  insert into public.event_responses(event_id,member_id,line_name,attendance,camera,disposable_camera,allergies,other_allergy,note,agreement,payment_status)
  values(p_event_id,mid,p_line_name,p_attendance,p_camera,p_disposable_camera,p_allergies,p_other_allergy,p_note,p_agreement,'not_required') returning id into rid;
  if p_attendance='参加' then insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email)
    values(p_event_id,mid,rid,'joined','member',private.current_email()); end if;
  return jsonb_build_object('responseId',rid);
end $$;

create or replace function public.cancel_my_event_participation(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; r public.event_responses%rowtype; mid uuid;
begin mid:=private.current_member_id(); perform private.event_lock(p_event_id); select * into e from public.events where id=p_event_id;
  if not e.self_cancellation_enabled or e.registration_deadline is null or now()>e.registration_deadline then raise exception '現在は本人キャンセルできません。'; end if;
  select * into r from public.event_responses where event_id=p_event_id and member_id=mid and attendance='参加' and cancelled_at is null for update;
  if r.id is null then raise exception '有効な参加回答がありません。'; end if;
  update public.event_responses set cancelled_at=now() where id=r.id;
  insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email) values(p_event_id,mid,r.id,'self_cancelled','member',private.current_email());
  perform private.create_next_waitlist_offer(p_event_id); return jsonb_build_object('cancelled',true); end $$;

create or replace function public.admin_cancel_event_participation(p_response_id uuid,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.event_responses%rowtype;
begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  select * into r from public.event_responses where id=p_response_id; if r.id is null then raise exception '回答がありません。'; end if;
  perform private.event_lock(r.event_id); if r.cancelled_at is null then
    update public.event_responses set cancelled_at=now() where id=r.id;
    insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email,reason) values(r.event_id,r.member_id,r.id,'admin_cancelled','admin',private.current_email(),coalesce(p_reason,''));
    perform private.create_next_waitlist_offer(r.event_id); end if; return jsonb_build_object('cancelled',true); end $$;

create or replace function public.join_event_waitlist(p_event_id uuid,p_registration_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; mid uuid; wid uuid; occupied integer;
begin mid:=private.current_member_id(); perform private.event_lock(p_event_id); select * into e from public.events where id=p_event_id;
  if mid is null or e.id is null or e.participant_limit is null or not e.waitlist_enabled or e.waitlist_registration_deadline is null or now()>e.waitlist_registration_deadline then raise exception 'キャンセル待ちは受け付けていません。'; end if;
  if exists(select 1 from public.event_responses where event_id=p_event_id and member_id=mid and attendance='参加' and cancelled_at is null) then raise exception 'すでに参加中です。'; end if;
  -- offer承諾時に締切後でも安全にUPDATEできるよう、回答行を先に確保する。
  select count(*) into occupied from public.event_responses where event_id=p_event_id and attendance='参加' and cancelled_at is null;
  occupied:=occupied+(select count(*) from public.event_waitlist_offers where event_id=p_event_id and status='pending' and response_deadline>=now());
  if occupied<e.participant_limit then raise exception '現在空席があります。通常の参加申込を行ってください。'; end if;
  if (e.genre='camp' or e.subtype='dining') and trim(coalesce(p_registration_data->>'allergies',''))='' then raise exception 'アレルギー情報が必要です。'; end if;
  if e.genre='camp' and coalesce((p_registration_data->>'agreement')::boolean,false)=false then raise exception '合宿の参加条件への同意が必要です。'; end if;
  insert into public.event_waitlist_entries(event_id,member_id,status,registration_data) values(p_event_id,mid,'waiting',p_registration_data) returning id into wid;
  insert into public.event_participation_history(event_id,member_id,action,actor_type,actor_email) values(p_event_id,mid,'waitlist_joined','member',private.current_email());
  return jsonb_build_object('waitlistEntryId',wid); end $$;

create or replace function public.withdraw_event_waitlist(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare mid uuid:=private.current_member_id(); wid uuid;
begin perform private.event_lock(p_event_id); update public.event_waitlist_entries set status='withdrawn',withdrawn_at=now(),resolved_at=now()
  where event_id=p_event_id and member_id=mid and status='waiting' returning id into wid;
  if wid is null then raise exception '取消可能なキャンセル待ちがありません。'; end if;
  insert into public.event_participation_history(event_id,member_id,action,actor_type,actor_email) values(p_event_id,mid,'waitlist_withdrawn','member',private.current_email());
  return jsonb_build_object('withdrawn',true); end $$;

create or replace function public.request_event_rejoin(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.events%rowtype; r public.event_responses%rowtype; mid uuid:=private.current_member_id(); occupied integer; wid uuid;
begin perform private.event_lock(p_event_id); select * into e from public.events where id=p_event_id;
  select * into r from public.event_responses where event_id=p_event_id and member_id=mid for update;
  if r.id is null or r.cancelled_at is null then raise exception '再参加対象の回答がありません。'; end if;
  if r.payment_updated_by='system:payment-deadline' then raise exception '支払期限超過後の再参加は幹部へ申請してください。'; end if;
  if e.waitlist_registration_deadline is null or now()>e.waitlist_registration_deadline then raise exception '再参加受付は終了しました。'; end if;
  select count(*) into occupied from public.event_responses where event_id=p_event_id and attendance='参加' and cancelled_at is null;
  occupied:=occupied+(select count(*) from public.event_waitlist_offers where event_id=p_event_id and status='pending' and response_deadline>=now());
  if e.participant_limit is null or occupied<e.participant_limit then
    update public.event_responses set cancelled_at=null,payment_status=case when e.fee_enabled and e.fee>0 then 'unpaid' else 'not_required' end where id=r.id;
    insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email) values(p_event_id,mid,r.id,'rejoined','member',private.current_email());
    return jsonb_build_object('state','joined');
  end if;
  if not e.waitlist_enabled then raise exception '現在満員で、キャンセル待ちは利用できません。'; end if;
  insert into public.event_waitlist_entries(event_id,member_id,status,registration_data) values(p_event_id,mid,'waiting',jsonb_build_object('lineName',r.line_name,'allergies',r.allergies,'otherAllergy',r.other_allergy,'note',r.note,'agreement',r.agreement)) returning id into wid;
  insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email) values(p_event_id,mid,r.id,'rejoin_waitlisted','member',private.current_email());
  return jsonb_build_object('state','waiting','waitlistEntryId',wid); end $$;

create or replace function public.respond_waitlist_offer(p_offer_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.event_waitlist_offers%rowtype; e public.events%rowtype; w public.event_waitlist_entries%rowtype; rid uuid; boundary timestamptz;
begin select * into o from public.event_waitlist_offers where id=p_offer_id and member_id=private.current_member_id(); if o.id is null then raise exception '繰上げ案内がありません。'; end if;
  perform private.event_lock(o.event_id); select * into o from public.event_waitlist_offers where id=p_offer_id for update;
  if o.status<>'pending' or now()>o.response_deadline then raise exception 'この案内の回答期限は終了しました。'; end if;
  if p_accept then select * into e from public.events where id=o.event_id; select * into w from public.event_waitlist_entries where id=o.waitlist_entry_id; boundary:=private.event_final_payment_boundary(e);
    select id into rid from public.event_responses where event_id=o.event_id and member_id=o.member_id;
    if rid is null then perform set_config('app.waitlist_offer_accept','on',true);
      insert into public.event_responses(event_id,member_id,line_name,attendance,allergies,other_allergy,note,agreement,payment_status,individual_payment_deadline)
      select o.event_id,o.member_id,coalesce(nullif(w.registration_data->>'lineName',''),m.line_name),'参加',coalesce(w.registration_data->>'allergies',''),coalesce(w.registration_data->>'otherAllergy',''),coalesce(w.registration_data->>'note',''),coalesce((w.registration_data->>'agreement')::boolean,false),case when e.fee_enabled and e.fee>0 then 'unpaid' else 'not_required' end,
      case when e.fee_enabled and e.fee>0 then least(now()+interval '7 days',boundary) end from public.members m where m.id=o.member_id returning id into rid;
    else update public.event_responses set attendance='参加',cancelled_at=null,payment_status=case when e.fee_enabled and e.fee>0 then 'unpaid' else 'not_required' end,
      individual_payment_deadline=case when e.fee_enabled and e.fee>0 then least(now()+interval '7 days',boundary) end where id=rid; end if;
    update public.event_waitlist_offers set status='accepted',responded_at=now() where id=o.id;
    update public.event_waitlist_entries set status='accepted',resolved_at=now() where id=o.waitlist_entry_id;
    insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,actor_email) values(o.event_id,o.member_id,rid,'waitlist_accepted','member',private.current_email());
  else update public.event_waitlist_offers set status='declined',responded_at=now() where id=o.id;
    update public.event_waitlist_entries set status='declined',resolved_at=now() where id=o.waitlist_entry_id;
    insert into public.event_participation_history(event_id,member_id,action,actor_type,actor_email) values(o.event_id,o.member_id,'waitlist_declined','member',private.current_email()); perform private.create_next_waitlist_offer(o.event_id); end if;
  return jsonb_build_object('accepted',p_accept); end $$;

create or replace function public.process_expired_waitlist_offers()
returns integer language plpgsql security definer set search_path='' as $$
declare o record; n integer:=0;
begin for o in select id,event_id,waitlist_entry_id,member_id from public.event_waitlist_offers where status='pending' and response_deadline<now() order by response_deadline loop
  perform private.event_lock(o.event_id); update public.event_waitlist_offers set status='expired',responded_at=now() where id=o.id and status='pending'; if found then n:=n+1;
    update public.event_waitlist_entries set status='expired',resolved_at=now() where id=o.waitlist_entry_id;
    insert into public.event_participation_history(event_id,member_id,action,actor_type,reason) values(o.event_id,o.member_id,'waitlist_expired','system','回答期限超過'); perform private.create_next_waitlist_offer(o.event_id); end if; end loop; return n; end $$;

create or replace function public.get_my_event_state(p_event_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('response',coalesce((select to_jsonb(r) from public.event_responses r where r.event_id=p_event_id and r.member_id=private.current_member_id()),'null'::jsonb),
    'waitlist',coalesce((select to_jsonb(w) from public.event_waitlist_entries w where w.event_id=p_event_id and w.member_id=private.current_member_id() order by w.created_at desc limit 1),'null'::jsonb),
    'offer',coalesce((select to_jsonb(o) from public.event_waitlist_offers o where o.event_id=p_event_id and o.member_id=private.current_member_id() and o.status='pending' order by o.created_at desc limit 1),'null'::jsonb));
$$;

create or replace function public.get_event_availability(p_event_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e public.events%rowtype; grade text; confirmed integer; reserved integer; occupied integer; eligible boolean; reg_open boolean; wait_open boolean;
begin
  if not private.is_current_member() and not private.is_admin() then raise exception '現在有効な部員のみ確認できます。'; end if;
  select * into e from public.events where id=p_event_id;
  if e.id is null or e.deleted_at is not null or not e.published or e.status<>'saved' then raise exception 'この予定は現在受付していません。'; end if;
  select upper(trim(m.grade)) into grade from public.members m where m.id=private.current_member_id() and m.active;
  select count(*) into confirmed from public.event_responses r where r.event_id=p_event_id and r.attendance='参加' and r.cancelled_at is null;
  select count(*) into reserved from public.event_waitlist_offers o where o.event_id=p_event_id and o.status='pending' and o.response_deadline>=now();
  occupied:=confirmed+reserved; eligible:=cardinality(e.eligible_grades)=0 or grade=any(e.eligible_grades);
  reg_open:=e.registration_deadline is not null and now()<=e.registration_deadline;
  wait_open:=e.participant_limit is not null and e.waitlist_enabled and e.waitlist_registration_deadline is not null and now()<=e.waitlist_registration_deadline;
  return jsonb_build_object('participantLimit',e.participant_limit,'participantCount',confirmed,'confirmedCount',confirmed,'reservedCount',reserved,'occupiedCount',occupied,
    'remaining',case when e.participant_limit is null then null else greatest(0,e.participant_limit-occupied) end,'eligibleGrades',e.eligible_grades,'memberGrade',grade,
    'gradeEligible',eligible,'registrationOpen',reg_open,'registrationDeadline',e.registration_deadline,'isFull',e.participant_limit is not null and occupied>=e.participant_limit,
    'waitlistEnabled',e.participant_limit is not null and e.waitlist_enabled,'waitlistRegistrationOpen',wait_open,'waitlistRegistrationDeadline',e.waitlist_registration_deadline,
    'canParticipate',reg_open and eligible and (e.participant_limit is null or occupied<e.participant_limit),'canJoinWaitlist',eligible and wait_open and occupied>=e.participant_limit);
end $$;

create or replace function public.set_event_payment_status(p_response_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.event_responses%rowtype; e public.events%rowtype;
begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
  if p_status not in ('unpaid','paid') then raise exception '支払い状態は未払い・支払い済みのみ変更できます。参加取消は専用操作を使用してください。'; end if;
  select * into r from public.event_responses where id=p_response_id; select * into e from public.events where id=r.event_id;
  if r.id is null or r.attendance<>'参加' or r.cancelled_at is not null or not e.fee_enabled or e.fee<=0 then raise exception 'この回答は支払い管理の対象ではありません。'; end if;
  update public.event_responses set payment_status=p_status,payment_updated_at=now(),payment_updated_by=private.current_email() where id=r.id returning * into r;
  return jsonb_build_object('responseId',r.id,'paymentStatus',r.payment_status,'cancelledAt',r.cancelled_at,'updatedAt',r.payment_updated_at,'updatedBy',r.payment_updated_by); end $$;

create or replace function public.apply_overdue_payment_cancellations()
returns integer language plpgsql security definer set search_path='' as $$
declare r record; n integer:=0;
begin
  if private.current_email()='' and current_user not in ('postgres','supabase_admin') then raise exception 'ログインが必要です。'; end if;
  for r in select response.id,response.event_id,response.member_id from public.event_responses response join public.events event on event.id=response.event_id
    where response.attendance='参加' and response.payment_status='unpaid' and response.cancelled_at is null
      and coalesce(response.individual_payment_deadline,case when event.payment_deadline_enabled then event.payment_deadline end)<now()
  loop
    perform private.event_lock(r.event_id);
    update public.event_responses set payment_status='cancelled',cancelled_at=now(),payment_updated_at=now(),payment_updated_by='system:payment-deadline' where id=r.id and cancelled_at is null;
    if found then n:=n+1; insert into public.event_participation_history(event_id,member_id,response_id,action,actor_type,reason)
      values(r.event_id,r.member_id,r.id,'payment_overdue_cancelled','system','支払期限超過'); perform private.create_next_waitlist_offer(r.event_id); end if;
  end loop; return n;
end $$;

create or replace function public.mark_waitlist_offer_notified(p_offer_id uuid) returns void
language plpgsql security definer set search_path='' as $$ begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if;
 update public.event_waitlist_offers set notification_status='manual_done',notification_sent_at=now(),notification_sent_by=private.current_email() where id=p_offer_id; end $$;

create or replace function public.save_event_group_version(p_event_id uuid,p_save_type text,p_groups jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.event_group_assignments%rowtype; e public.events%rowtype; v uuid; vn integer; ids uuid[]; expected_ids uuid[]; leaders_missing integer; unique_count integer; end_boundary timestamptz;
begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if; if p_save_type not in('draft','saved') then raise exception '保存種別が不正です。'; end if;
 select * into e from public.events where id=p_event_id; if e.genre='exhibition' then raise exception '写真展は班分け対象外です。'; end if;
 end_boundary:=case when e.ends_at is not null then e.ends_at else ((((e.starts_at at time zone 'Asia/Tokyo')::date+3)::timestamp) at time zone 'Asia/Tokyo') end;
 if end_boundary is null or now()>=end_boundary then raise exception 'イベント終了後は班分けを編集できません。'; end if;
 if jsonb_typeof(p_groups)<>'array' or jsonb_array_length(p_groups)<1 then raise exception '班を1つ以上設定してください。'; end if;
 insert into public.event_group_assignments(event_id,created_by,updated_by) values(p_event_id,private.current_email(),private.current_email()) on conflict(event_id) do update set updated_by=excluded.updated_by,updated_at=now() returning * into a;
 select coalesce(max(version_number),0)+1 into vn from public.event_group_versions where assignment_id=a.id;
 select array_agg((m->>'memberId')::uuid),count(*) filter(where nullif(g->>'leaderId','') is null) into ids,leaders_missing
 from jsonb_array_elements(p_groups) g cross join lateral jsonb_array_elements(g->'members') m;
 select count(distinct value) into unique_count from unnest(ids) value;
 if unique_count<>cardinality(ids) then raise exception '同じ部員が複数の班に所属しています。'; end if;
 select array_agg(r.member_id order by r.member_id) into expected_ids from public.event_responses r where r.event_id=p_event_id and r.attendance='参加' and r.cancelled_at is null;
 if (select array_agg(value order by value) from unnest(ids) value) is distinct from expected_ids then raise exception '現在の正式参加者に未配置または余分な部員がいます。'; end if;
 if exists(select 1 from jsonb_array_elements(p_groups) g where jsonb_array_length(g->'members')=0 or (nullif(g->>'leaderId','') is not null and not exists(select 1 from jsonb_array_elements(g->'members') m where m->>'memberId'=g->>'leaderId'))) then raise exception '空の班、または班に所属しない班長があります。'; end if;
 if p_save_type='saved' and leaders_missing>0 then raise exception '班長未設定の班があります。'; end if;
 insert into public.event_group_versions(assignment_id,version_number,save_type,group_count,groups,participant_ids,created_by)
 values(a.id,vn,p_save_type,jsonb_array_length(p_groups),p_groups,coalesce(ids,'{}'),private.current_email()) returning id into v;
 update public.event_group_assignments set current_version_id=v,updated_by=private.current_email(),updated_at=now() where id=a.id;
 return jsonb_build_object('versionId',v,'versionNumber',vn); end $$;

create or replace function public.publish_event_group_version(p_version_id uuid) returns void
language plpgsql security definer set search_path='' as $$ declare v public.event_group_versions%rowtype; a public.event_group_assignments%rowtype; e public.events%rowtype; current_ids uuid[]; end_boundary timestamptz;
begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if; select * into v from public.event_group_versions where id=p_version_id; if v.save_type<>'saved' then raise exception '保存済み版のみ公開できます。'; end if;
 select * into a from public.event_group_assignments where id=v.assignment_id; select * into e from public.events where id=a.event_id;
 end_boundary:=case when e.ends_at is not null then e.ends_at else ((((e.starts_at at time zone 'Asia/Tokyo')::date+3)::timestamp) at time zone 'Asia/Tokyo') end;
 if end_boundary is null or now()>=end_boundary then raise exception 'イベント終了後は班分けを公開できません。'; end if;
 select array_agg(r.member_id order by r.member_id) into current_ids from public.event_responses r where r.event_id=e.id and r.attendance='参加' and r.cancelled_at is null;
 if (select array_agg(value order by value) from unnest(v.participant_ids) value) is distinct from current_ids then raise exception '保存後に参加状況が変更されています。再生成または再保存してください。'; end if;
 update public.event_group_assignments set published_version_id=v.id,is_published=true,updated_by=private.current_email(),updated_at=now() where id=a.id;
 insert into public.event_group_publication_history(assignment_id,version_id,action,operated_by) values(a.id,v.id,'published',private.current_email()); end $$;

create or replace function public.unpublish_event_groups(p_event_id uuid) returns void language plpgsql security definer set search_path='' as $$ declare aid uuid;
begin if not private.is_admin() then raise exception '管理者権限がありません。'; end if; update public.event_group_assignments set is_published=false,updated_by=private.current_email(),updated_at=now() where event_id=p_event_id returning id into aid;
 if aid is not null then insert into public.event_group_publication_history(assignment_id,version_id,action,operated_by) select id,published_version_id,'unpublished',private.current_email() from public.event_group_assignments where id=aid; end if; end $$;

create or replace function public.get_published_event_groups(p_event_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$ declare result jsonb;
begin if not exists(select 1 from public.event_responses where event_id=p_event_id and member_id=private.current_member_id() and attendance='参加') and not private.is_admin() then return null; end if;
 select jsonb_build_object('versionId',v.id,'versionNumber',v.version_number,'publishedAt',(select max(h.operated_at) from public.event_group_publication_history h where h.assignment_id=a.id and h.version_id=v.id and h.action='published'),'groups',v.groups)
 into result from public.event_group_assignments a join public.event_group_versions v on v.id=a.published_version_id where a.event_id=p_event_id and a.is_published; return result; end $$;

alter table public.event_participation_history enable row level security;
alter table public.event_waitlist_entries enable row level security;
alter table public.event_waitlist_offers enable row level security;
alter table public.event_group_assignments enable row level security;
alter table public.event_group_versions enable row level security;
alter table public.event_group_publication_history enable row level security;
grant select on public.event_participation_history,public.event_waitlist_entries,public.event_waitlist_offers,public.event_group_assignments,public.event_group_versions,public.event_group_publication_history to authenticated;
create policy participation_history_admin on public.event_participation_history for select to authenticated using(private.is_admin());
create policy waitlist_self_admin on public.event_waitlist_entries for select to authenticated using(member_id=private.current_member_id() or private.is_admin());
create policy offers_self_admin on public.event_waitlist_offers for select to authenticated using(member_id=private.current_member_id() or private.is_admin());
create policy group_assignments_admin on public.event_group_assignments for select to authenticated using(private.is_admin());
create policy group_versions_admin on public.event_group_versions for select to authenticated using(private.is_admin());
create policy group_history_admin on public.event_group_publication_history for select to authenticated using(private.is_admin());

revoke all on function public.submit_event_response(uuid,text,text,boolean,boolean,text,text,text,boolean),public.cancel_my_event_participation(uuid),public.admin_cancel_event_participation(uuid,text),public.join_event_waitlist(uuid,jsonb),public.withdraw_event_waitlist(uuid),public.request_event_rejoin(uuid),public.respond_waitlist_offer(uuid,boolean),public.process_expired_waitlist_offers(),public.get_my_event_state(uuid),public.mark_waitlist_offer_notified(uuid),public.save_event_group_version(uuid,text,jsonb),public.publish_event_group_version(uuid),public.unpublish_event_groups(uuid),public.get_published_event_groups(uuid) from public,anon;
grant execute on function public.submit_event_response(uuid,text,text,boolean,boolean,text,text,text,boolean),public.cancel_my_event_participation(uuid),public.admin_cancel_event_participation(uuid,text),public.join_event_waitlist(uuid,jsonb),public.withdraw_event_waitlist(uuid),public.request_event_rejoin(uuid),public.respond_waitlist_offer(uuid,boolean),public.process_expired_waitlist_offers(),public.get_my_event_state(uuid),public.mark_waitlist_offer_notified(uuid),public.save_event_group_version(uuid,text,jsonb),public.publish_event_group_version(uuid),public.unpublish_event_groups(uuid),public.get_published_event_groups(uuid) to authenticated;

-- Supabase Cronが有効なら、期限切れofferを毎分処理する。重複ジョブは作らない。
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') and not exists(select 1 from cron.job where jobname='expire-event-waitlist-offers') then
    perform cron.schedule('expire-event-waitlist-offers','* * * * *','select public.process_expired_waitlist_offers();');
  end if;
exception when undefined_table then null; end $$;

select to_regprocedure('public.cancel_my_event_participation(uuid)') is not null as cancellation_ready,
       to_regprocedure('public.join_event_waitlist(uuid,jsonb)') is not null as waitlist_ready,
       to_regprocedure('public.save_event_group_version(uuid,text,jsonb)') is not null as grouping_ready;
